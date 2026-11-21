import AVFoundation
import FFPreview
import MPCutCore

private func ffTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000_000)
}

private enum FFPreviewError: LocalizedError {
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .decode(let message): return message
        }
    }
}

struct FFPreviewBatch {
    var video: [PreviewFrame] = []
    var audio: [CMSampleBuffer] = []
    var end = false
    var noAudio = false
}

final class FFPreviewReader: @unchecked Sendable {
    private let videoOnly: Bool
    private let audioOnly: Bool
    private var decoder: OpaquePointer?
    private var url: URL?
    private var openedSoundOnly = false
    private var openedAudioTrack: Int?
    private var openedOrigin: RationalTime?
    private var transform = CGAffineTransform.identity
    private var pendingFrame: PreviewFrame?
    private var videoFinished = false
    private var audioFinished = false
    private var cancelled: (() -> Bool)?

    init(videoOnly: Bool = false, audioOnly: Bool = false) {
        self.audioOnly = audioOnly
        self.videoOnly = videoOnly
    }

    deinit { mp_preview_close(decoder) }

    func perform<T>(cancelled: @escaping () -> Bool, _ operation: () throws -> T) rethrows -> T {
        self.cancelled = cancelled
        defer {
            self.cancelled = nil
            if cancelled() {
                mp_preview_close(decoder)
                decoder = nil
                pendingFrame = nil
            }
        }
        return try operation()
    }

    func seek(url: URL, to time: Double, withAudio: Bool = false,
              soundOnlySource: Bool = false, audioOrigin: RationalTime? = nil, audioTrack: Int? = nil) throws {
        let soundOnly = audioOnly || soundOnlySource
        pendingFrame = nil
        videoFinished = soundOnly
        audioFinished = false
        if self.url != url || decoder == nil || openedSoundOnly != soundOnly || openedOrigin != audioOrigin
            || openedAudioTrack != audioTrack {
            mp_preview_close(decoder)
            var error: UnsafePointer<CChar>?
            let context = Unmanaged.passUnretained(self).toOpaque()
            let tracks = soundOnly ? MPPreviewSoundOnly : videoOnly ? MPPreviewPictureOnly : MPPreviewPictureAndSound
            let origin = audioOrigin.map(previewTime) ?? .invalid
            decoder = url.path.withCString {
                mp_preview_open($0, tracks, Int32(clamping: audioTrack ?? -1), origin, { context in
                    guard let context else { return false }
                    let reader = Unmanaged<FFPreviewReader>.fromOpaque(context).takeUnretainedValue()
                    return reader.cancelled?() ?? false
                }, context, &error)
            }
            guard let decoder else { throw failure(error) }
            openedSoundOnly = soundOnly
            openedAudioTrack = audioTrack
            openedOrigin = audioOrigin
            transform = mp_preview_transform(decoder)
            self.url = url
            mp_preview_enable_audio(decoder, withAudio)
            if time == 0 { return }
        } else {
            mp_preview_enable_audio(decoder, withAudio)
        }
        guard mp_preview_seek_timeline(decoder, time) else {
            throw FFPreviewError.decode("FFmpeg could not seek in \(url.lastPathComponent).")
        }
    }

    private func failure(_ message: UnsafePointer<CChar>?) -> FFPreviewError {
        .decode(message.map { String(cString: $0) } ?? "The preview decoder could not open this media.")
    }

    private func read() throws -> (Int32, CMSampleBuffer?) {
        var sample: CMSampleBuffer?
        var error: UnsafePointer<CChar>?
        let kind = mp_preview_next(decoder, &sample, &error)
        if kind < 0 { throw failure(error) }
        return (kind, sample)
    }

    func scrubSamples(url: URL, range: Range<Double>, audioOrigin: RationalTime? = nil,
                      audioTrack: Int? = nil) throws -> [CMSampleBuffer] {
        if audioOnly, self.url == url, openedOrigin == audioOrigin, openedAudioTrack == audioTrack,
           let decoder, !mp_preview_has_audio(decoder), !mp_preview_has_unavailable_audio(decoder) { return [] }
        try seek(url: url, to: range.lowerBound, withAudio: true, audioOrigin: audioOrigin, audioTrack: audioTrack)
        guard let decoder, mp_preview_has_audio(decoder) else { return [] }
        var samples: [CMSampleBuffer] = []
        while !Task.isCancelled && cancelled?() != true {
            let (kind, sample) = try read()
            if kind == MPPreviewEnd.rawValue || !mp_preview_has_audio(decoder) { break }
            guard kind == MPPreviewAudio.rawValue, let sample else { continue }
            let time = sample.presentationTimeStamp.seconds
            if time >= range.upperBound { break }
            if time + sample.duration.seconds > range.lowerBound { samples.append(sample) }
        }
        return samples
    }

    func still(at target: Double, before end: Double = .infinity,
               cancelled: () -> Bool) throws -> PreviewFrame? {
        var preceding: PreviewFrame?
        while !cancelled() {
            let (kind, sample) = try read()
            if kind == MPPreviewEnd.rawValue { return preceding }
            guard kind == MPPreviewVideo.rawValue, let sample,
                  let buffer = sample.imageBuffer else { continue }
            let frame = PreviewFrame(buffer: buffer, time: sample.presentationTimeStamp, transform: transform)
            if frame.time.seconds >= end { return preceding }
            // Mapping a stepped sequence time back to its clip can land a
            // fraction of a nanosecond below the exact presentation timestamp.
            if abs(frame.time.seconds - target) <= 0.000_000_001 { return frame }
            if frame.time.seconds > target { return preceding ?? frame }
            preceding = frame
        }
        return nil
    }

    // Multicam supplies the exact indexed picture timestamp and decodes the
    // active view sequentially until a seek or camera switch.
    func indexedFrame(at target: CMTime, cancelled: () -> Bool) throws -> PreviewFrame? {
        while !cancelled() {
            let (kind, sample) = try read()
            if kind == MPPreviewEnd.rawValue { break }
            guard kind == MPPreviewVideo.rawValue, let sample, let buffer = sample.imageBuffer else { continue }
            if sample.presentationTimeStamp >= target {
                guard sample.presentationTimeStamp == target else { return nil }
                return PreviewFrame(buffer: buffer, time: sample.presentationTimeStamp, transform: transform)
            }
        }
        return nil
    }

    func batch(from target: Double, end: Double, timelineOffset: Double, first: Bool,
               cancelled: () -> Bool) throws -> FFPreviewBatch {
        try batch(from: target, end: end,
                  timelineOffset: CMTime(seconds: timelineOffset, preferredTimescale: 1_000_000_000), first: first,
                  cancelled: cancelled)
    }

    func batch(from target: Double, end: Double, timelineOffset: CMTime, first: Bool,
               cancelled: () -> Bool, audioLimit: Int = 20) throws -> FFPreviewBatch {
        var output = FFPreviewBatch()
        if videoFinished && !mp_preview_has_audio(decoder) {
            output.end = true
            output.noAudio = mp_preview_has_unavailable_audio(decoder)
            return output
        }
        var preceding = first ? pendingFrame : nil
        var needsFirst = first
        // Let the caller process UI events between batches even during long preroll.
        // The preceding frame must survive the batch where seeking reaches its target.
        for _ in 0..<128 {
            if cancelled() { break }
            let (kind, sample) = try read()
            if kind == MPPreviewEnd.rawValue {
                if needsFirst, let preceding { output.video.append(preceding) }
                output.end = true
                break
            }
            guard let sample else { continue }
            let sourceTime = sample.presentationTimeStamp.seconds
            if kind == MPPreviewVideo.rawValue, let image = sample.imageBuffer {
                if sourceTime >= end {
                    videoFinished = true
                    // Audio that stopped before the cut never reports its own end.
                    if sourceTime >= end + 1 { audioFinished = true }
                    if needsFirst, let preceding {
                        output.video.append(preceding)
                        needsFirst = false
                    }
                } else if !videoFinished {
                    let frame = PreviewFrame(buffer: image, time: ffTime(max(sourceTime, target) + timelineOffset.seconds),
                                             transform: transform)
                    if needsFirst && sourceTime < target {
                        preceding = frame
                        continue
                    }
                    if needsFirst {
                        if sourceTime > target + 0.000_001, let preceding { output.video.append(preceding) }
                        needsFirst = false
                    }
                    output.video.append(frame)
                }
            } else if kind == MPPreviewAudio.rawValue {
                if let audio = Self.timelineAudio(sample, target: target, end: end, offset: timelineOffset) {
                    output.audio.append(audio)
                }
                if sourceTime + sample.duration.seconds >= end { audioFinished = true }
            }
            if videoFinished && (audioFinished || !mp_preview_has_audio(decoder)) {
                output.end = true
                break
            }
            if (!needsFirst && output.video.count >= 5) || output.audio.count >= audioLimit { break }
        }
        pendingFrame = needsFirst && !output.end ? preceding : nil
        output.noAudio = mp_preview_has_unavailable_audio(decoder)
        return output
    }

    static func timelineAudio(_ sample: CMSampleBuffer, target: Double, end: Double,
                              offset: CMTime) -> CMSampleBuffer? {
        guard let format = sample.formatDescription,
              let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate,
              rate > 0 else { return nil }
        let source = sample.presentationTimeStamp.seconds
        let count = sample.numSamples
        let duration = Double(count) / rate
        guard source < end, source + duration > target else { return nil }
        let startSample = max(0, Int(((target - source) * rate - 0.001).rounded(.up)))
        let endSample = min(count, Int(((end - source) * rate - 0.001).rounded(.up)))
        guard startSample < endSample else { return nil }
        var clipped: CMSampleBuffer? = sample
        if startSample > 0 || endSample < count {
            guard CMSampleBufferCopySampleBufferForRange(
                allocator: kCFAllocatorDefault, sampleBuffer: sample,
                sampleRange: CFRange(location: startSample, length: endSample - startSample),
                sampleBufferOut: &clipped
            ) == noErr else { return nil }
        }
        guard let clipped else { return nil }
        let sampleOffset = CMTime(value: Int64(startSample), timescale: Int32(rate))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                        presentationTimeStamp: sample.presentationTimeStamp + sampleOffset + offset,
                                        decodeTimeStamp: .invalid)
        var mapped: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: clipped,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &mapped
        )
        return mapped
    }
}

private final class FFPreviewRequests: @unchecked Sendable {
    let queue = DispatchQueue(label: "mpcut.web-preview", qos: .userInitiated, autoreleaseFrequency: .workItem)
    let reader = FFPreviewReader()
    var recent = ScrubFrameCache()
    private let lock = NSLock()
    private var generation = 0

    func next() -> Int {
        lock.withLock {
            generation += 1
            return generation
        }
    }

    func current(_ request: Int) -> Bool {
        lock.withLock { request == generation }
    }
}

@MainActor
final class WebSequencePlayback {
    private let ranges: [PreviewRange]
    private let offsets: [Double]
    private let duration: Double
    private let onFrame: (PreviewFrame) -> Void
    private let onTime: (Double) -> Void
    private let onIssue: (String) -> Void
    private let onAudioWarning: (String?) -> Void

    private let requests = FFPreviewRequests()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private var ticker: Task<Void, Never>?
    private var time = 0.0
    private var rangeIndex = 0
    private var requestedSourceTime = 0.0
    private var generation = 0
    private var openingRange = true
    private var waitingForFirstFrame = true
    private var reachedRangeEnd = false
    private var reading = false
    private var playing = false
    private var playbackRate: Float = 1
    private var renderingStill = false
    private var hasStartedClock = false
    private var lastClockCommand: ContinuousClock.Instant = .now
    private var audioWarning: String?
    private var video: [PreviewFrame] = []
    private var audio: [CMSampleBuffer] = []

    init(ranges: [PreviewRange], onFrame: @escaping (PreviewFrame) -> Void,
         onTime: @escaping (Double) -> Void, onIssue: @escaping (String) -> Void,
         onAudioWarning: @escaping (String?) -> Void) {
        (self.offsets, self.duration) = previewOffsets(ranges)
        self.ranges = ranges
        self.onFrame = onFrame
        self.onTime = onTime
        self.onIssue = onIssue
        self.onAudioWarning = onAudioWarning
        synchronizer.addRenderer(audioRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    deinit {
        ticker?.cancel()
        _ = requests.next()
    }

    /// Raised for one decoding pass. A seek or a new playback request starts another.
    static let undecodableAudio = "The source audio could not be decoded."

    func park(at position: Double) { time = min(max(position, 0), duration) }

    func setGain(_ gain: Float) { audioRenderer.volume = gain }

    func play(rate: Float = 1) {
        guard duration > 0 else { return }
        playbackRate = rate
        if playing {
            if hasStartedClock {
                readClock()
                setClockRate()
            }
            return
        }
        playing = true
        seek(to: time >= duration ? 0 : time)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    func pause() {
        guard playing else { return }
        if hasStartedClock { readClock() }
        playing = false
        ticker?.cancel()
        ticker = nil
        resetRequests()
    }

    func seek(to time: Double) {
        guard time.isFinite, !ranges.isEmpty else { return }
        resetRequests()
        self.time = min(max(time, 0), duration)
        onTime(self.time)
        rangeIndex = max(0, offsets.lowerBound { $0 > self.time } - 1)
        let range = ranges[rangeIndex]
        requestedSourceTime = self.time == duration ? range.end
            : min(range.end, range.start + (self.time - offsets[rangeIndex]))
        if playing {
            fill()
        } else if !range.isAudioOnly {
            still(url: range.url, at: requestedSourceTime, before: range.end)
        }
    }

    func audition(url: URL, at time: Double, before end: Double = .infinity) {
        if playing { pause() } else { resetRequests() }
        if ranges.first(where: { $0.url == url })?.isAudioOnly != true { still(url: url, at: time, before: end) }
    }

    func displayStill(at position: Double) {
        guard !playing, !renderingStill, !ranges.isEmpty else { return }
        park(at: position)
        let index = max(0, offsets.lowerBound { $0 > time } - 1)
        let range = ranges[index]
        guard !range.isAudioOnly else { return }
        let sourceTime = min(range.end, range.start + (time - offsets[index]))
        still(url: range.url, at: sourceTime, before: range.end)
    }

    private func resetRequests() {
        generation = requests.next()
        synchronizer.setRate(0, time: .invalid)
        audioRenderer.flush()
        hasStartedClock = false
        reading = false
        renderingStill = false
        openingRange = true
        waitingForFirstFrame = true
        reachedRangeEnd = false
        video.removeAll()
        audio.removeAll()
    }

    private func still(url: URL, at time: Double, before end: Double = .infinity) {
        renderingStill = true
        let requests = requests
        let generation = generation
        requests.queue.async { [weak self] in
            guard requests.current(generation) else { return }
            let result = Result {
                try requests.reader.perform(cancelled: { !requests.current(generation) }) {
                    // Seek before an exclusive boundary so an indexed key
                    // exactly at the boundary cannot hide the preceding frame.
                    try requests.recent.frame(url: url, at: time, before: end) {
                        let seekTime = time == end ? max(0, time - 0.001) : time
                        try requests.reader.seek(url: url, to: seekTime)
                        return try requests.reader.still(at: time, before: end) { !requests.current(generation) }
                    }
                }
            }
            Task { @MainActor in
                guard let self, requests.current(generation) else { return }
                self.renderingStill = false
                switch result {
                case .success(let frame?): self.onFrame(frame)
                case .success(nil): self.onIssue("The source produced no picture at this position.")
                case .failure(let error): self.onIssue(error.localizedDescription)
                }
            }
        }
    }

    private func fill() {
        guard playing, !reading, !reachedRangeEnd, video.count < 4, audio.count < 20 else { return }
        let requests = requests
        let generation = generation
        let range = ranges[rangeIndex]
        let target = requestedSourceTime
        let offset = offsets[rangeIndex] - range.start
        let open = openingRange
        let first = waitingForFirstFrame && !range.isAudioOnly
        reading = true
        requests.queue.async { [weak self] in
            guard requests.current(generation) else { return }
            let result = Result {
                try requests.reader.perform(cancelled: { !requests.current(generation) }) {
                    if open {
                        try requests.reader.seek(url: range.url, to: target, withAudio: true,
                                                 soundOnlySource: range.isAudioOnly, audioOrigin: range.audioOrigin,
                                                 audioTrack: range.audioTrack)
                    }
                    return try requests.reader.batch(from: target, end: range.end, timelineOffset: offset,
                                                     first: first) { !requests.current(generation) }
                }
            }
            Task { @MainActor in
                guard let self, requests.current(generation) else { return }
                self.reading = false
                self.openingRange = false
                switch result {
                case .success(let batch):
                    if range.isAudioOnly && batch.noAudio {
                        self.pause()
                        self.onIssue(Self.undecodableAudio)
                        return
                    }
                    self.video.append(contentsOf: batch.video)
                    self.audio.append(contentsOf: batch.audio)
                    self.reachedRangeEnd = batch.end
                    if !batch.video.isEmpty { self.waitingForFirstFrame = false }
                    if batch.noAudio {
                        self.reportAudioWarning("Audio preview is unavailable for this clip.")
                    } else if self.audioRenderer.status != .failed {
                        self.reportAudioWarning(nil)
                    }
                    self.tick()
                case .failure(let error):
                    self.pause()
                    self.onIssue(error.localizedDescription)
                }
            }
        }
    }

    private func reportAudioWarning(_ message: String?) {
        guard message != audioWarning else { return }
        audioWarning = message
        onAudioWarning(message)
    }

    private func readClock() {
        let position = synchronizer.currentTime().seconds
        if position.isFinite { time = min(max(time, position), duration) }
    }

    private func setClockRate() {
        // Anchor the rate change at the current position and host timestamp. The
        // synchronizer reports the new rate before the timebase applies it.
        synchronizer.setRate(playbackRate, time: ffTime(time),
                             atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        lastClockCommand = .now
    }

    private func tick() {
        guard playing else { return }
        if !hasStartedClock {
            if let frame = video.first {
                onFrame(frame)
                video.removeFirst()
                setClockRate()
                hasStartedClock = true
            } else if ranges[rangeIndex].isAudioOnly && (!audio.isEmpty || reachedRangeEnd) {
                setClockRate()
                hasStartedClock = true
            } else if reachedRangeEnd {
                pause()
                onIssue("The source produced no picture at this position.")
                return
            } else if audio.count >= 20 {
                // Some containers store a run of audio before their first
                // picture. Start the timeline so the renderer can consume this
                // audio and the bounded demux queue can reach the picture.
                setClockRate()
                hasStartedClock = true
            }
        }
        if hasStartedClock {
            readClock()
            if lastClockCommand.duration(to: .now) >= .milliseconds(150),
               CMTimebaseGetRate(synchronizer.timebase) == 0 {
                // A rate change can leave the timebase stopped even when the
                // cached synchronizer rate is nonzero.
                setClockRate()
            }
            if audioRenderer.status == .failed {
                audio.removeAll()
                reportAudioWarning("Audio preview could not be played.")
            }
            while let sample = audio.first, audioRenderer.isReadyForMoreMediaData,
                  sample.presentationTimeStamp.seconds <= time + 0.30 {
                audioRenderer.enqueue(sample)
                audio.removeFirst()
            }
            if let last = video.lastIndex(where: { $0.time.seconds <= time + 0.004 }) {
                onFrame(video[last])
                video.removeFirst(last + 1)
            }
            onTime(time)
            if time >= duration {
                pause()
                return
            }
            if reachedRangeEnd, rangeIndex + 1 < ranges.count {
                rangeIndex += 1
                requestedSourceTime = ranges[rangeIndex].start
                openingRange = true
                waitingForFirstFrame = true
                reachedRangeEnd = false
            }
        }
        fill()
    }
}
