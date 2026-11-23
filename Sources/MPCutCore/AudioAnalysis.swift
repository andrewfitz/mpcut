import AVFoundation
import Foundation
import MediaProbe

public struct AudioSpan: Codable, Equatable, Hashable, Sendable {
    public let from: RationalTime
    public let to: RationalTime

    public init(from: RationalTime, to: RationalTime) {
        self.from = from
        self.to = to
    }
}

/// Source-relative peaks in 20 ms bins. Pages let the UI share completed blocks
/// while the decoder continues, and reduce the cost of zoomed-out drawing.
public struct AudioWaveform: Sendable {
    public static let defaultMaxBlip = 0.06
    public static let rate = Int(MP_PEAK_RATE)
    fileprivate static let pageSize = 256
    fileprivate struct Page: Sendable {
        let samples: [Float]
        let peak: Float
        init(_ samples: [Float]) {
            self.samples = samples
            self.peak = samples.max() ?? -1
        }
    }
    fileprivate var pages: [Page] = []
    public fileprivate(set) var count = 0
    public let duration: RationalTime
    // Only a finished scan is tagged. Partial pages remain useful for display.
    private(set) var sourceIdentity: SourceIdentity?
    private(set) var sourceClock: AudioAnalysisClock?

    init(duration: RationalTime) { self.duration = duration }

    fileprivate mutating func finish(for media: MediaInfo, stream: Int) {
        sourceIdentity = media.identity
        sourceClock = AudioAnalysisClock(media: media, stream: stream)
    }

    /// Use after refresh has verified the result's audio stream and presentation clock.
    package func forRefreshedMedia(_ media: MediaInfo, stream: Int) -> AudioWaveform {
        guard sourceClock == AudioAnalysisClock(media: media, stream: stream) else { return self }
        var result = self
        result.finish(for: media, stream: stream)
        return result
    }

    func matches(_ media: MediaInfo, stream: Int) -> Bool {
        sourceIdentity?.matchesSnapshot(media.identity) == true && sourceClock == AudioAnalysisClock(media: media, stream: stream)
    }

    func peakBytes(checkingCancellation: () throws -> Void) rethrows -> Data {
        // The versioned waveform section stores contiguous IEEE 754 little-endian
        // Float32 samples, including -1 for unobserved bins. All supported Macs
        // use this representation.
        var bytes = Data(capacity: count * MemoryLayout<Float>.stride)
        for page in pages {
            try checkingCancellation()
            page.samples.withUnsafeBytes { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    init?(peakBytes: Data, media: MediaInfo, stream: Int, cancelled: () -> Bool) {
        let stride = MemoryLayout<Float>.stride
        let bins = peakBytes.count / stride
        guard peakBytes.count.isMultiple(of: stride),
              Double(bins) <= ceil(media.duration.seconds * Double(Self.rate)) + 1 else { return nil }
        self.init(duration: media.duration)
        pages.reserveCapacity((bins + Self.pageSize - 1) / Self.pageSize)
        var offset = 0
        while offset < bins {
            if cancelled() { return nil }
            let length = min(bins - offset, Self.pageSize)
            var samples = [Float](repeating: 0, count: length)
            _ = samples.withUnsafeMutableBytes { target in
                peakBytes.copyBytes(to: target, from: offset * stride..<(offset + length) * stride)
            }
            guard samples.allSatisfy({ $0.isFinite && ($0 >= 0 || $0 == -1) }) else { return nil }
            pages.append(Page(samples))
            offset += length
        }
        count = bins
        finish(for: media, stream: stream)
    }

    var syncPeaks: [Float] { pages.flatMap(\.samples) }

    public func peak(from: Double, to: Double) -> Float? {
        guard from.isFinite, to.isFinite, to > from else { return nil }
        // A decimal boundary such as 0.58 s can multiply to just under 29.
        // Keep adjacent columns from borrowing each other's loudest sample.
        func bin(_ time: Double, rounding: FloatingPointRoundingRule) -> Int {
            let position = min(Double(count), max(0, time * Double(Self.rate)))
            let nearest = position.rounded()
            return Int(abs(position - nearest) <= 2 * position.ulp ? nearest : position.rounded(rounding))
        }
        var i = bin(from, rounding: .down)
        let end = bin(to, rounding: .up)
        var maximum: Float = -1
        while i < end {
            let page = pages[i / Self.pageSize]
            let offset = i % Self.pageSize
            let length = min(end - i, page.samples.count - offset)
            if offset == 0 && length == page.samples.count {
                maximum = max(maximum, page.peak)
            } else {
                for value in page.samples[offset..<offset + length] { maximum = max(maximum, value) }
            }
            i += length
        }
        return maximum >= 0 ? maximum : nil
    }

    /// Estimate a threshold from sustained room levels and louder program audio
    /// in this source. Only the cached 20 ms peaks are needed.
    public func automaticThresholdDB(checkingCancellation: () throws -> Void = {}) rethrows -> Double {
        // Work in 200 ms windows. Quartiles keep one click from looking like
        // foreground and keep an isolated dip from looking like room tone.
        let windowSize = Self.rate / 5
        var window: [Float] = []
        window.reserveCapacity(windowSize)
        var program = LevelHistogram()
        var steady = LevelHistogram()
        var gatedWindows = 0
        var sustainedForeground = -120
        func measureWindow() {
            defer { window.removeAll(keepingCapacity: true) }
            guard window.count >= 5 else { return }
            window.sort()
            // Five active bins in a window support a short utterance even
            // when it accounts for much less than 1% of the whole file.
            sustainedForeground = max(sustainedForeground, LevelHistogram.level(window[window.count - 5]))
            let lower = LevelHistogram.level(window[window.count / 4])
            let upper = LevelHistogram.level(window[3 * window.count / 4])
            // Gated or near-digital silence is always quiet. Keep it out of
            // the distribution so it doesn't hide a second, audible room floor.
            if upper > -120 {
                program.add(upper)
                if upper - lower <= 6 { steady.add(upper) }
            } else {
                gatedWindows += 1
            }
        }
        for page in pages {
            try checkingCancellation()
            for sample in page.samples {
                if sample < 0 {
                    measureWindow()
                } else {
                    window.append(sample)
                    if window.count == windowSize { measureWindow() }
                }
            }
        }
        measureWindow()
        guard program.count > 0 else { return -96 }
        let typicalLoud = program.level(atRank: max(1, program.count - program.count / 10))
        let lowBand = steady.level(atRank: max(1, (steady.count + 4) / 5))
        // On a mostly quiet take, use the louder tail to find sparse speech.
        // Otherwise use its ordinary loud level so a shout cannot set the floor.
        let foreground = typicalLoud - lowBand >= 8 ? typicalLoud
            : max(typicalLoud, sustainedForeground)
        let conservative = max(-120, min(gatedWindows > 0 ? -84 : -55, foreground - 12))
        // Use a typical steady background window. A few unusually quiet
        // seconds at the head of a long recording should not dominate it.
        let quietCount = steady.count(atOrBelow: min(lowBand + 3, foreground - 8))
        guard quietCount >= 2 else { return Double(conservative) }
        let room = steady.level(atRank: (quietCount + 1) / 2)
        let upperRoom = steady.level(atRank: quietCount - quietCount / 10)
        // Give the measured background a little headroom. A wide gap up to
        // a loud voice is no reason to consume the tail of a softer word.
        return Double(min(foreground - 5, room + min(9, upperRoom - room + 3)))
    }

    public func pauses(thresholdDB: Double, minimum: Double, maxBlip: Double = Self.defaultMaxBlip,
                       checkingCancellation: () throws -> Void = {}) rethrows -> [AudioSpan] {
        try silenceRuns(thresholdDB: thresholdDB, checkingCancellation: checkingCancellation)
            .pauses(minimum: minimum, maxBlip: maxBlip)
    }

    func silenceRuns(thresholdDB: Double, checkingCancellation: () throws -> Void) rethrows -> SilenceRuns {
        let threshold = Float(pow(10, thresholdDB / 20))
        var quiet: [AudioSpan] = []
        var covered: [AudioSpan] = []
        var quietStart: Int?
        var coveredStart: Int?
        var i = 0

        func appendRun(_ start: Int?, to runs: inout [AudioSpan]) {
            guard let start else { return }
            let from = RationalTime(numerator: Int64(start), denominator: Int64(Self.rate))
            let to = min(duration, RationalTime(numerator: Int64(i), denominator: Int64(Self.rate)))
            if from < to { runs.append(AudioSpan(from: from, to: to)) }
        }

        for page in pages {
            try checkingCancellation()
            for value in page.samples {
                if value >= 0 {
                    if coveredStart == nil { coveredStart = i }
                    if value <= threshold {
                        if quietStart == nil { quietStart = i }
                    } else if quietStart != nil {
                        appendRun(quietStart, to: &quiet)
                        quietStart = nil
                    }
                } else {
                    appendRun(coveredStart, to: &covered)
                    coveredStart = nil
                    appendRun(quietStart, to: &quiet)
                    quietStart = nil
                }
                i += 1
            }
        }
        appendRun(quietStart, to: &quiet)
        appendRun(coveredStart, to: &covered)
        return SilenceRuns(quiet: quiet, covered: covered)
    }

}

/// Unbridged runs let a caller change audio routes before applying pause detection.
struct SilenceRuns: Codable, Sendable {
    let quiet: [AudioSpan]
    let covered: [AudioSpan]

    func pauses(minimum: Double, maxBlip: Double = AudioWaveform.defaultMaxBlip) -> [AudioSpan] {
        // Require uninterrupted quiet on both sides of each measured blip.
        let quietContext = RationalTime(numerator: 8, denominator: Int64(AudioWaveform.rate))
        var result: [AudioSpan] = []
        var first: RationalTime?
        var previous: AudioSpan?
        var coverageIndex = 0

        func emit() {
            guard let from = first, let to = previous?.to,
                  let length = try? to.subtracting(from), length.seconds >= minimum else { return }
            result.append(AudioSpan(from: from, to: to))
        }

        for run in quiet {
            if let last = previous {
                while coverageIndex < covered.count && covered[coverageIndex].to <= last.to {
                    coverageIndex += 1
                }
                let joins = coverageIndex < covered.count && covered[coverageIndex].from <= last.to
                    && covered[coverageIndex].to >= run.from
                    && (try? run.from.subtracting(last.to)).map { $0.seconds <= maxBlip } == true
                    && (try? last.to.subtracting(last.from)).map { $0 >= quietContext } == true
                    && (try? run.to.subtracting(run.from)).map { $0 >= quietContext } == true
                if !joins {
                    emit()
                    first = run.from
                }
            } else {
                first = run.from
            }
            previous = run
        }
        emit()
        return result
    }
}

/// Counts integer dBFS levels without sorting or retaining a file-sized list.
private struct LevelHistogram {
    private var bins = [Int](repeating: 0, count: 121)
    private(set) var count = 0

    static func level(_ amplitude: Float) -> Int {
        let db = 20 * log10(Double(max(amplitude, 0.000001)))
        return Int(min(0, max(-120, db.rounded())))
    }

    mutating func add(_ level: Int) {
        bins[level + 120] += 1
        count += 1
    }

    func count(atOrBelow level: Int) -> Int {
        bins.prefix(max(0, min(bins.count, level + 121))).reduce(0, +)
    }

    func level(atRank rank: Int) -> Int {
        var total = 0
        for (index, frequency) in bins.enumerated() {
            total += frequency
            if total >= rank { return index - 120 }
        }
        return 0
    }
}

private final class PeakCollector {
    var waveform: AudioWaveform
    var pending: [Float] = []
    var lastUpdate = ContinuousClock.now
    let cancelled: () -> Bool
    let update: (AudioWaveform) -> Void
    var failed = false

    init(duration: RationalTime, cancelled: @escaping () -> Bool, update: @escaping (AudioWaveform) -> Void) {
        waveform = AudioWaveform(duration: duration)
        self.cancelled = cancelled
        self.update = update
    }

    func add(bin: Int, peak: Float) {
        guard bin >= 0, !failed else { return }
        // A coarse packet clock can put the first sample of a new packet in
        // the previous page. Retain its peak even if the UI has seen the page.
        if bin < waveform.count {
            let page = bin / AudioWaveform.pageSize
            let offset = bin % AudioWaveform.pageSize
            var samples = waveform.pages[page].samples
            if samples[offset] < peak {
                samples[offset] = peak
                waveform.pages[page] = .init(samples)
            }
            return
        }
        let offset = bin - waveform.count
        if offset < pending.count { pending[offset] = max(pending[offset], peak); return }
        if offset == pending.count && offset < AudioWaveform.pageSize {
            if pending.isEmpty { pending.reserveCapacity(AudioWaveform.pageSize) }
            pending.append(peak)
            return
        }
        while bin >= waveform.count + AudioWaveform.pageSize {
            if cancelled() { failed = true; return }
            pending += repeatElement(-1, count: AudioWaveform.pageSize - pending.count)
            flush()
            if waveform.pages.count == 1 || lastUpdate.duration(to: .now) >= .milliseconds(160) {
                update(waveform)
                lastUpdate = .now
            }
        }
        if pending.isEmpty { pending.reserveCapacity(AudioWaveform.pageSize) }
        let missing = bin - waveform.count - pending.count
        if missing > 0 { pending += repeatElement(-1, count: missing) }
        pending.append(peak)
    }

    func flush() {
        guard !pending.isEmpty else { return }
        waveform.pages.append(.init(pending))
        waveform.count += pending.count
        pending = []
    }
}

private let collectPeak: MPPeakVisit = { context, bin, peak in
    Unmanaged<PeakCollector>.fromOpaque(context!).takeUnretainedValue().add(bin: Int(bin), peak: peak)
}

/// AVFoundation renders the MOV edit list, including repeated AAC media and
/// decoder preroll hidden inside an empty edit. Only presented PCM reaches the
/// same peak reducer used for ordinary audio streams.
func visitPresentedAudio(_ audio: AudioIndex, media: MediaInfo, window: Range<Double>?,
                         duration: RationalTime? = nil, cancelled: () -> Bool, samples: (UnsafePointer<Float>, Int32, Int32, Int32, Double) throws -> Void,
                         silence: (Double, Double) throws -> Void) throws {
    let stream = audio.stream
    func failure(_ reason: String) -> CutError {
        CutError(code: "audio_analysis_failed", message: reason, track: stream.index)
    }
    func checkCancellation() throws {
        if cancelled() { throw CutError(code: "cancelled", message: "Audio analysis was cancelled.") }
    }
    guard let clock = CMTimeScale(exactly: stream.sampleRate), clock > 0,
          let channels = Int32(exactly: stream.channels), channels > 0 else {
        throw failure("The AAC track has an invalid sample rate or channel count.")
    }
    let duration = duration ?? media.duration
    var first = try media.origin.roundedToSamples(stream.sampleRate)
    var last = try media.origin.adding(duration).roundedToSamples(stream.sampleRate)
    if let window {
        // Include the sample under the first pixel, even at sub-sample zoom.
        func clampedSample(_ second: Double, rounding: FloatingPointRoundingRule) -> Int64 {
            let value = ((media.origin.seconds + second) * Double(clock)).rounded(rounding)
            if value >= Double(last) { return last }
            if value <= Double(first) { return first }
            return Int64(value)
        }
        first = clampedSample(window.lowerBound, rounding: .down)
        last = clampedSample(window.upperBound, rounding: .up)
    }
    guard first < last else { return }
    let picture = first..<last
    let edits = audio.presentationEdits.filter { $0.samples.overlaps(picture) }
    guard !edits.isEmpty else { return }

    if edits.contains(where: \.isAudible) {
        try checkCancellation()
        let asset = AVURLAsset(url: media.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = asset.track(withTrackID: stream.trackID), track.mediaType == .audio else {
            throw failure("The AAC track for the presentation edits is unavailable.")
        }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw failure(error.localizedDescription) }
        let start = max(first, edits[0].samples.lowerBound)
        let end = min(last, edits[edits.count - 1].samples.upperBound)
        reader.timeRange = CMTimeRange(start: CMTime(value: start, timescale: clock),
                                       end: CMTime(value: end, timescale: clock))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw failure("Could not configure presented PCM for analysis.") }
        reader.add(output)
        guard reader.startReading() else { throw failure(reader.error?.localizedDescription ?? "Could not read presented audio.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        while let sample = output.copyNextSampleBuffer() {
            try checkCancellation()
            try autoreleasepool {
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds - media.origin.seconds
                guard time.isFinite, let description = CMSampleBufferGetFormatDescription(sample),
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      format.mSampleRate == Double(clock), format.mChannelsPerFrame == stream.channels,
                      format.mBytesPerFrame == MemoryLayout<Float>.size * stream.channels,
                      let frames = Int32(exactly: CMSampleBufferGetNumSamples(sample)) else {
                    throw failure("The AAC reader returned an unexpected PCM format.")
                }
                if frames == 0 { return }
                try sample.withAudioBufferList { list, _ in
                    guard list.count == 1, let data = list[0].mData,
                          Int(list[0].mDataByteSize) >= Int(frames) * Int(format.mBytesPerFrame) else {
                        throw failure("Could not read the presented PCM samples.")
                    }
                    try samples(data.assumingMemoryBound(to: Float.self), frames, channels, clock, time)
                }
            }
        }
        guard reader.status == .completed else { throw failure(reader.error?.localizedDescription ?? "Incomplete AAC presentation.") }
    }
    // A reader can omit empty edits, notably for a wholly silent track.
    // Only declared silence is filled. Time outside these edits stays unknown.
    for edit in edits where !edit.isAudible {
        let from = max(0, Double(edit.samples.lowerBound) / Double(clock) - media.origin.seconds)
        let to = min(duration.seconds, Double(edit.samples.upperBound) / Double(clock) - media.origin.seconds)
        guard from < to else { continue }
        try checkCancellation()
        try silence(from, to)
    }
}

public enum AudioAnalysis {
    public static func roomToneThresholdDB(forPeak peak: Float) -> Double {
        min(0, max(-120, (20 * log10(Double(max(peak, 0.000001))) + 3).rounded(.up)))
    }

    public static func scan(_ media: MediaInfo, stream: Int, useSidecar: Bool = true, cancelled: @escaping () -> Bool = { Task.isCancelled },
                            update: @escaping (AudioWaveform) -> Void = { _ in }) throws -> AudioWaveform {
        guard media.streams.contains(where: { $0.index == stream && $0.kind == "audio" }) else {
            throw CutError(code: "no_audio", message: "Select an available audio stream for analysis.")
        }
        func checkSource() throws {
            guard media.identity.isCurrentSnapshot(at: media.url) else {
                throw CutError(code: "source_changed", message: "The source changed since inspection.")
            }
        }
        try checkSource()
        if cancelled() { throw CutError(code: "cancelled", message: "Audio analysis was cancelled.") }
        if useSidecar, let wave = AnalysisSidecar(media: media).waveform(for: media, stream: stream, cancelled: cancelled) {
            if cancelled() { throw CutError(code: "cancelled", message: "Audio analysis was cancelled.") }
            try checkSource()
            return wave
        }
        let collector = PeakCollector(duration: media.duration, cancelled: cancelled, update: update)
        var decoderFailure: String?
        if let audio = media.audio.first(where: { $0.stream.index == stream && !$0.presentationEdits.isEmpty }) {
            try visitPresentedAudio(audio, media: media, window: nil, cancelled: cancelled) { pcm, frames, channels, rate, start in
                guard mp_float_pcm_peaks(pcm, frames, channels, rate, start, media.duration.seconds, collectPeak,
                                         Unmanaged.passUnretained(collector).toOpaque()) == 0 else {
                    throw CutError(code: "audio_analysis_failed", message: "Could not measure the presented PCM samples.")
                }
            } silence: { from, to in
                for bin in Int(floor(from * Double(AudioWaveform.rate)))..<Int(ceil(to * Double(AudioWaveform.rate))) {
                    if bin.isMultiple(of: AudioWaveform.pageSize), cancelled() {
                        throw CutError(code: "cancelled", message: "Audio analysis was cancelled.")
                    }
                    collector.add(bin: bin, peak: 0)
                }
            }
        } else {
            var error = [CChar](repeating: 0, count: 256)
            // A full audio packet inspection verifies that later blocks cannot return to this interval.
            let ordered = !media.hasProvisionalClock && media.audioIssues[stream] == nil && media.audio.contains { track in
                track.stream.index == stream && (track.stream.isPCM ? track.pcmContinuity : !track.packets.isEmpty)
            }
            let status = mp_audio_peaks(media.url.path, Int32(stream), media.origin.seconds, media.duration.seconds,
                                        ordered ? 1 : 0, {
                Unmanaged<PeakCollector>.fromOpaque($0!).takeUnretainedValue().cancelled() ? 1 : 0
            }, collectPeak, Unmanaged.passUnretained(collector).toOpaque(), &error, error.count)
            if status < 0 { decoderFailure = String(cString: error) }
        }
        if cancelled() { throw CutError(code: "cancelled", message: "Audio analysis was cancelled.") }
        try checkSource()
        if let decoderFailure { throw CutError(code: "audio_analysis_failed", message: decoderFailure) }
        collector.flush()
        collector.waveform.finish(for: media, stream: stream)
        if useSidecar {
            AnalysisSidecar(media: media).saveAutomatically(try AnalysisSidecar.sections(media: media,
                waveforms: [stream: collector.waveform], cancelled: cancelled), cancelled: cancelled)
            if cancelled() { throw CutError(code: "cancelled", message: "Audio analysis was cancelled.") }
            try checkSource()
        }
        return collector.waveform
    }

    /// Round both edges into the removable interior, protecting the requested
    /// padding even when the caller supplies sparse lossless-copy boundaries.
    public static func removal(in pause: AudioSpan, padding: Double, ends: [RationalTime],
                               starts: [RationalTime], clip: AudioSpan? = nil) -> AudioSpan? {
        func partition(_ times: [RationalTime], _ predicate: (Double) -> Bool) -> Int {
            var low = 0, high = times.count
            while low < high {
                let mid = low + (high - low) / 2
                if predicate(times[mid].seconds) { high = mid } else { low = mid + 1 }
            }
            return low
        }
        let from: RationalTime, to: RationalTime
        if padding == 0 && pause.from == clip?.from {
            // Removing a leading pause creates no retained segment on its left.
            from = pause.from
        } else {
            let left = partition(ends) { $0 >= pause.from.seconds + padding - 1e-10 }
            guard left < ends.count else { return nil }
            from = ends[left]
        }
        if padding == 0 && pause.to == clip?.to {
            to = pause.to
        } else {
            let right = partition(starts) { $0 > pause.to.seconds - padding + 1e-10 } - 1
            guard right >= 0 else { return nil }
            to = starts[right]
        }
        guard from < to else { return nil }
        return AudioSpan(from: from, to: to)
    }

    /// The shaded portion of a proposed pause, after cut points have been aligned.
    package static func paddingSpans(in pause: AudioSpan, removal: AudioSpan?, padding: Double) -> [AudioSpan] {
        if let removal { return retained(in: pause, removing: [removal]) }
        let halfDuration = (pause.to.seconds - pause.from.seconds) / 2
        return padding >= halfDuration ? [pause] : []
    }

    public static func retained(in span: AudioSpan, removing cuts: [AudioSpan]) -> [AudioSpan] {
        var cursor = span.from
        var ranges: [AudioSpan] = []
        for cut in cuts {
            let end = min(cut.from, span.to)
            if cursor < end { ranges.append(AudioSpan(from: cursor, to: end)) }
            cursor = max(cursor, cut.to)
        }
        if cursor < span.to { ranges.append(AudioSpan(from: cursor, to: span.to)) }
        return ranges
    }
}
