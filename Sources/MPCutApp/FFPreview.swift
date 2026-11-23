import AppKit
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
    var partialAudio = false
    var hasPictureGap = false
}

final class FFPreviewReader: @unchecked Sendable {
    private let videoOnly: Bool
    private let preservesSurround: Bool
    private let preservesAudioChannels: Bool
    private let audioOnly: Bool
    private var decoder: OpaquePointer?
    private var url: URL?
    private var openedSoundOnly = false
    private var openedPictureOnly = false
    private var openedAudioTrack: Int?
    private var openedOrigin: RationalTime?
    private var transform = CGAffineTransform.identity
    private var pendingFrame: (frame: PreviewFrame, sourceEnd: Double)?
    private var videoFinished = false
    private var audioFinished = false
    private var cancelled: (() -> Bool)?

    init(videoOnly: Bool = false, audioOnly: Bool = false, preservesSurround: Bool = false,
         preservesAudioChannels: Bool = false) {
        self.preservesSurround = preservesSurround
        self.preservesAudioChannels = preservesAudioChannels
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
        func open() throws {
            mp_preview_close(decoder)
            var error: UnsafePointer<CChar>?
            let context = Unmanaged.passUnretained(self).toOpaque()
            openedPictureOnly = !soundOnly && (videoOnly || !withAudio)
            let tracks = soundOnly ? MPPreviewSoundOnly : openedPictureOnly ? MPPreviewPictureOnly : MPPreviewPictureAndSound
            let origin = audioOrigin.map(previewTime) ?? .invalid
            decoder = url.path.withCString {
                mp_preview_open($0, tracks, Int32(clamping: audioTrack ?? -1), origin, { context in
                    guard let context else { return false }
                    let reader = Unmanaged<FFPreviewReader>.fromOpaque(context).takeUnretainedValue()
                    return reader.cancelled?() ?? false
                }, context, &error)
            }
            guard let decoder else { throw failure(error) }
            if preservesSurround { mp_preview_preserve_surround(decoder) }
            if preservesAudioChannels { mp_preview_preserve_audio_channels(decoder) }
            openedSoundOnly = soundOnly
            openedAudioTrack = audioTrack
            openedOrigin = audioOrigin
            transform = mp_preview_transform(decoder)
            self.url = url
            mp_preview_enable_audio(decoder, withAudio)
        }
        if self.url != url || decoder == nil || openedSoundOnly != soundOnly || openedOrigin != audioOrigin
            || openedAudioTrack != audioTrack || (withAudio && !videoOnly && openedPictureOnly) {
            try open()
            if time == 0 { return }
        } else {
            mp_preview_enable_audio(decoder, withAudio)
        }
        if !mp_preview_seek_timeline(decoder, time) {
            // A backward seek before the first indexed keyframe can fail after moving
            // the demux cursor. Reopen to include the first picture and any leading audio.
            guard cancelled?() != true else { throw CancellationError() }
            try open()
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

    private func readPicture() throws -> (kind: Int32, image: CVPixelBuffer?, pts: CMTime, duration: CMTime) {
        var image: CVPixelBuffer?
        var pts = CMTime.invalid
        var duration = CMTime.invalid
        var error: UnsafePointer<CChar>?
        let kind = mp_preview_next_picture(decoder, &image, &pts, &duration, &error)
        if kind < 0 { throw failure(error) }
        return (kind, image, pts, duration)
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

    func still(at target: Double, before end: Double = .infinity, nearbyKeyframe: Bool = false,
               cancelled: () -> Bool) throws -> PreviewFrame? {
        var preceding: PreviewFrame?
        var precedingEnd = -Double.infinity
        // After a damaged picture the decoder resumes at the next keyframe. The pictures in
        // between are missing, and no picture from another position may stand in for them.
        func missing() -> Bool {
            guard mp_preview_met_damage(decoder) else { return false }
            if target == end, precedingEnd >= end { return false }
            return !precedingEnd.isFinite || precedingEnd <= target
        }
        while !cancelled() {
            let (kind, image, pts, duration) = try readPicture()
            if kind == MPPreviewEnd.rawValue {
                if missing() { throw FFPreviewError.decode(WebSequencePlayback.damagedPicture) }
                guard let preceding else {
                    throw FFPreviewError.decode("The source produced no picture at this position.")
                }
                return preceding
            }
            guard let image else { continue }
            let frame = PreviewFrame(buffer: image, time: pts, transform: transform)
            if nearbyKeyframe, !mp_preview_met_damage(decoder), frame.time.seconds >= target - 8,
               frame.time.seconds <= target, frame.time.seconds < end { return frame }
            if frame.time.seconds > target + 0.000_000_001, missing() {
                throw FFPreviewError.decode(WebSequencePlayback.damagedPicture)
            }
            if frame.time.seconds >= end { return preceding }
            // Mapping a stepped sequence time back to its clip can land a
            // fraction of a nanosecond below the exact presentation timestamp.
            if abs(frame.time.seconds - target) <= 0.000_000_001 { return frame }
            if frame.time.seconds > target { return preceding }
            preceding = frame
            precedingEnd = frame.time.seconds + duration.seconds
        }
        return nil
    }

    // Multicam supplies the exact indexed picture timestamp and decodes the
    // active view sequentially until a seek or camera switch.
    func indexedFrame(at target: CMTime, cancelled: () -> Bool) throws -> PreviewFrame? {
        while !cancelled() {
            let (kind, image, pts, _) = try readPicture()
            if kind == MPPreviewEnd.rawValue { break }
            guard let image else { continue }
            if pts >= target {
                guard pts == target else { return nil }
                return PreviewFrame(buffer: image, time: pts, transform: transform)
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
        func appendPreroll() {
            guard let preceding, !mp_preview_met_damage(decoder) || target < preceding.sourceEnd else { return }
            output.video.append(preceding.frame)
        }
        // Let the caller process UI events between batches even during long preroll.
        // The preceding frame must survive the batch where seeking reaches its target.
        for _ in 0..<128 {
            if cancelled() { break }
            let (kind, sample) = try read()
            if kind == MPPreviewEnd.rawValue {
                if needsFirst { appendPreroll() }
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
                    if needsFirst {
                        appendPreroll()
                        output.hasPictureGap = output.video.isEmpty
                        needsFirst = false
                    }
                } else if !videoFinished {
                    let frame = PreviewFrame(buffer: image, time: ffTime(max(sourceTime, target) + timelineOffset.seconds),
                                             transform: transform)
                    if needsFirst && sourceTime < target {
                        preceding = (frame, sourceTime + sample.duration.seconds)
                        continue
                    }
                    if needsFirst {
                        if sourceTime > target + 0.000_001 { appendPreroll() }
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
        if mp_preview_has_unavailable_audio(decoder) {
            output.partialAudio = mp_preview_has_audio(decoder)
            output.noAudio = !output.partialAudio
        }
        output.hasPictureGap = output.hasPictureGap || mp_preview_met_damage(decoder)
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
    let reader = FFPreviewReader(preservesSurround: true)
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
    private let screen: () -> NSScreen?
    private let ranges: [PreviewRange]
    private let offsets: [Double]
    private let duration: Double
    private let onFrame: (PreviewFrame) -> Void
    private let separatesPicture: Bool
    private let onTime: (Double) -> Void
    private let onIssue: (String) -> Void
    private let onGap: () -> Void
    private let onAudioWarning: (String?) -> Void

    private let requests = FFPreviewRequests()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private var ticker: PreviewDisplayTicker?
    private var time = 0.0
    private var rangeIndex = 0
    private var requestedSourceTime = 0.0
    private var generation = 0
    private var openingRange = true
    private var waitingForFirstFrame = true
    private var reachedRangeEnd = false
    private var startsWithoutPicture = false
    private var reading = false
    private var playing = false
    private var playbackRate: Float = 1
    private var renderingStill = false
    private var hasStartedClock = false
    private var lastClockCommand: ContinuousClock.Instant = .now
    private var audioWarning: String?
    private var pictureGaps: [Double] = []
    private var video: [PreviewFrame] = []
    private var audio: [CMSampleBuffer] = []

    init(ranges: [PreviewRange], screen: @escaping () -> NSScreen? = { nil }, onFrame: @escaping (PreviewFrame) -> Void,
         onTime: @escaping (Double) -> Void, onIssue: @escaping (String) -> Void,
         onAudioWarning: @escaping (String?) -> Void, onGap: @escaping () -> Void = {},
         separatesPicture: Bool = false) {
        (self.offsets, self.duration) = previewOffsets(ranges)
        self.screen = screen
        self.ranges = ranges
        self.onFrame = onFrame
        self.separatesPicture = separatesPicture
        self.onTime = onTime
        self.onIssue = onIssue
        self.onGap = onGap
        self.onAudioWarning = onAudioWarning
        synchronizer.addRenderer(audioRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    deinit {
        ticker?.cancel()
        _ = requests.next()
    }

    /// Raised for one decoding pass. A seek or a new playback request starts another.
    nonisolated static let undecodableAudio = "The source audio could not be decoded."
    /// Raised for one position. Playback resumes at the next keyframe.
    nonisolated static let damagedPicture = "The picture at this position is damaged and could not be decoded."

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
        ticker = PreviewDisplayTicker(screen: screen()) { [weak self] in self?.tick() }
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
        } else if !range.isAudioOnly && range.unavailablePicture == nil && !separatesPicture {
            still(url: range.url, at: requestedSourceTime, before: range.end, transfer: range.programTransfer)
        }
    }

    func audition(url: URL, at time: Double, before end: Double = .infinity, transfer: String? = nil) {
        if playing { pause() } else { resetRequests() }
        let sourceTransfer = ranges.first(where: { $0.url == url && !$0.isAudioOnly })?.programTransfer
        still(url: url, at: time, before: end, transfer: transfer ?? sourceTransfer)
    }

    func cancelStill() {
        if renderingStill { resetRequests() }
    }

    func displayStill(at position: Double) {
        guard !playing, !renderingStill, !ranges.isEmpty else { return }
        park(at: position)
        let index = max(0, offsets.lowerBound { $0 > time } - 1)
        let range = ranges[index]
        guard !range.isAudioOnly, range.unavailablePicture == nil, !separatesPicture else { return }
        let sourceTime = min(range.end, range.start + (time - offsets[index]))
        still(url: range.url, at: sourceTime, before: range.end, transfer: range.programTransfer)
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
        startsWithoutPicture = false
        pictureGaps.removeAll()
        video.removeAll()
        audio.removeAll()
    }

    private func still(url: URL, at time: Double, before end: Double, transfer: String?) {
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
                case .success(let frame?): self.onFrame(frame.tagged(transfer: transfer, cameraTransfer: transfer ?? "unknown"))
                case .success(nil): self.onGap()
                case .failure(let error): self.onIssue(error.localizedDescription)
                }
            }
        }
    }

    private func fill() {
        guard playing, !reading, !reachedRangeEnd, audio.count < 20 else { return }
        // At 240 fps even a single 60 Hz refresh can consume 32 pictures at 8×.
        // Keep two refresh intervals available while bounding decoded picture memory.
        if let last = video.last, video.count >= 4 {
            let frameBytes = max(1, CVPixelBufferGetDataSize(last.buffer))
            guard video.count < min(96, 64 * 1024 * 1024 / frameBytes),
                  last.time.seconds < time + Double(playbackRate) / 30 else { return }
        }
        let requests = requests
        let generation = generation
        let range = ranges[rangeIndex]
        if range.isSilentInsert {
            reachedRangeEnd = true
            return
        }
        let target = requestedSourceTime
        let offset = offsets[rangeIndex] - range.start
        let open = openingRange
        let soundOnly = separatesPicture || range.isAudioOnly || range.unavailablePicture != nil
        let first = waitingForFirstFrame && !soundOnly
        reading = true
        requests.queue.async { [weak self] in
            guard requests.current(generation) else { return }
            let result = Result {
                try requests.reader.perform(cancelled: { !requests.current(generation) }) {
                    if open {
                        try requests.reader.seek(url: range.url, to: target, withAudio: true,
                                                 soundOnlySource: soundOnly, audioOrigin: range.audioOrigin,
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
                    if range.isAudioOnly && batch.noAudio && !self.separatesPicture {
                        self.pause()
                        self.onIssue(Self.undecodableAudio)
                        return
                    }
                    self.video.append(contentsOf: batch.video.map {
                        $0.tagged(transfer: range.programTransfer, cameraTransfer: range.programTransfer ?? "unknown")
                    })
                    self.audio.append(contentsOf: batch.audio)
                    self.reachedRangeEnd = batch.end
                    if batch.hasPictureGap && self.waitingForFirstFrame { self.startsWithoutPicture = true }
                    let rangeStart = target + offset
                    if first, batch.video.first.map({ $0.time.seconds > rangeStart + 0.000_001 }) ?? (batch.end && batch.hasPictureGap) {
                        self.pictureGaps.append(rangeStart)
                    }
                    if !batch.video.isEmpty { self.waitingForFirstFrame = false }
                    if batch.noAudio {
                        self.reportAudioWarning("Audio preview is unavailable for this clip.")
                    } else if batch.partialAudio {
                        self.reportAudioWarning("Some audio tracks are unavailable for preview.")
                    } else if self.audioRenderer.status != .failed {
                        self.reportAudioWarning(nil)
                    }
                    if self.hasStartedClock { self.fill() } else { self.tick() }
                case .failure(let error):
                    if self.separatesPicture {
                        self.reachedRangeEnd = true
                        self.reportAudioWarning(error.localizedDescription)
                        self.tick()
                    } else {
                        self.pause()
                        self.onIssue(error.localizedDescription)
                    }
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
            if !video.isEmpty || startsWithoutPicture {
                setClockRate()
                hasStartedClock = true
            } else if (separatesPicture || ranges[rangeIndex].isAudioOnly || ranges[rangeIndex].unavailablePicture != nil)
                        && (!audio.isEmpty || reachedRangeEnd) {
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
                  sample.presentationTimeStamp.seconds <= time + 0.30 * Double(playbackRate) {
                audioRenderer.enqueue(sample)
                audio.removeFirst()
            }
            // Do not leave the preceding clip on screen through a new clip's leading gap.
            if let lastGap = pictureGaps.lastIndex(where: { $0 <= time }) {
                let start = pictureGaps[lastGap]
                pictureGaps.removeFirst(lastGap + 1)
                video.removeAll { $0.time.seconds < start }
                onGap()
            }
            if let last = video.lastIndex(where: { $0.time.seconds <= time }) {
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
