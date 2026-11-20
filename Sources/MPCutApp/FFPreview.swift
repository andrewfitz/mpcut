import AVFoundation
import FFPreview

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

private struct FFPreviewBatch {
    var video: [PreviewFrame] = []
    var audio: [CMSampleBuffer] = []
    var end = false
    var noAudio = false
}

final class FFPreviewReader: @unchecked Sendable {
    private let videoOnly: Bool
    private var decoder: OpaquePointer?
    private var url: URL?
    private var transform = CGAffineTransform.identity
    private var pendingFrame: PreviewFrame?
    private var videoFinished = false
    private var audioFinished = false
    private var cancelled: (() -> Bool)?

    init(videoOnly: Bool = false) {
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

    func seek(url: URL, to time: Double) throws {
        pendingFrame = nil
        videoFinished = false
        audioFinished = false
        if self.url != url || decoder == nil {
            mp_preview_close(decoder)
            var error: UnsafePointer<CChar>?
            let context = Unmanaged.passUnretained(self).toOpaque()
            decoder = url.path.withCString {
                mp_preview_open($0, videoOnly, { context in
                    guard let context else { return false }
                    let reader = Unmanaged<FFPreviewReader>.fromOpaque(context).takeUnretainedValue()
                    return reader.cancelled?() ?? false
                }, context, &error)
            }
            guard let decoder else { throw failure(error) }
            transform = mp_preview_transform(decoder)
            self.url = url
            if time == 0 { return }
        }
        guard mp_preview_seek(decoder, time) else {
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
            if frame.time.seconds == target { return frame }
            if frame.time.seconds > target + 0.000_001 { return preceding ?? frame }
            preceding = frame
        }
        return nil
    }

    fileprivate func batch(from target: Double, end: Double, timelineOffset: Double, first: Bool,
                           cancelled: () -> Bool) throws -> FFPreviewBatch {
        var output = FFPreviewBatch()
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
                    if needsFirst, let preceding {
                        output.video.append(preceding)
                        needsFirst = false
                    }
                } else if !videoFinished {
                    let frame = PreviewFrame(buffer: image, time: ffTime(max(sourceTime, target) + timelineOffset),
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
            if !needsFirst && (output.video.count >= 5 || output.audio.count >= 20) { break }
            if needsFirst && output.audio.count >= 20 { break }
        }
        pendingFrame = needsFirst && !output.end ? preceding : nil
        output.noAudio = mp_preview_has_unavailable_audio(decoder)
        return output
    }

    private static func timelineAudio(_ sample: CMSampleBuffer, target: Double, end: Double,
                                      offset: Double) -> CMSampleBuffer? {
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
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                        presentationTimeStamp: ffTime(source + Double(startSample) / rate + offset),
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
    private var hasStartedClock = false
    private var audioWarning = false
    private var video: [PreviewFrame] = []
    private var audio: [CMSampleBuffer] = []

    init(ranges: [PreviewRange], onFrame: @escaping (PreviewFrame) -> Void,
         onTime: @escaping (Double) -> Void, onIssue: @escaping (String) -> Void) {
        (self.offsets, self.duration) = previewOffsets(ranges)
        self.ranges = ranges
        self.onFrame = onFrame
        self.onTime = onTime
        self.onIssue = onIssue
        synchronizer.addRenderer(audioRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    deinit {
        ticker?.cancel()
        _ = requests.next()
    }

    func play() {
        guard !playing, duration > 0 else { return }
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
        if hasStartedClock {
            let clock = synchronizer.currentTime().seconds
            if clock.isFinite { time = min(max(time, clock), duration) }
        }
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
        rangeIndex = offsets.lastIndex(where: { $0 <= self.time }) ?? 0
        let range = ranges[rangeIndex]
        requestedSourceTime = self.time == duration ? range.end
            : min(range.end, range.start + (self.time - offsets[rangeIndex]))
        if playing {
            fill()
        } else {
            still(url: range.url, at: requestedSourceTime, before: range.end)
        }
    }

    func audition(url: URL, at time: Double) {
        pause()
        still(url: url, at: time)
    }

    private func resetRequests() {
        generation = requests.next()
        synchronizer.setRate(0, time: .invalid)
        audioRenderer.flush()
        hasStartedClock = false
        reading = false
        openingRange = true
        waitingForFirstFrame = true
        reachedRangeEnd = false
        video.removeAll()
        audio.removeAll()
    }

    private func still(url: URL, at time: Double, before end: Double = .infinity) {
        let requests = requests
        let generation = generation
        requests.queue.async { [weak self] in
            guard requests.current(generation) else { return }
            let result = Result {
                try requests.reader.perform(cancelled: { !requests.current(generation) }) {
                    // Seek before an exclusive boundary so an indexed key
                    // exactly at the boundary cannot hide the preceding frame.
                    let seekTime = time == end ? max(0, time - 0.001) : time
                    try requests.reader.seek(url: url, to: seekTime)
                    return try requests.reader.still(at: time, before: end) { !requests.current(generation) }
                }
            }
            Task { @MainActor in
                guard let self, requests.current(generation) else { return }
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
        let first = waitingForFirstFrame
        reading = true
        requests.queue.async { [weak self] in
            guard requests.current(generation) else { return }
            let result = Result {
                try requests.reader.perform(cancelled: { !requests.current(generation) }) {
                    if open { try requests.reader.seek(url: range.url, to: target) }
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
                    self.video.append(contentsOf: batch.video)
                    self.audio.append(contentsOf: batch.audio)
                    self.reachedRangeEnd = batch.end
                    if !batch.video.isEmpty { self.waitingForFirstFrame = false }
                    if batch.noAudio && !self.audioWarning {
                        self.audioWarning = true
                        self.onIssue("Audio preview: the source audio could not be decoded.")
                    }
                    self.tick()
                case .failure(let error):
                    self.pause()
                    self.onIssue(error.localizedDescription)
                }
            }
        }
    }

    private func tick() {
        guard playing else { return }
        if !hasStartedClock {
            if let frame = video.first {
                onFrame(frame)
                video.removeFirst()
                synchronizer.setRate(1, time: ffTime(time))
                hasStartedClock = true
            } else if reachedRangeEnd {
                pause()
                onIssue("The source produced no picture at this position.")
                return
            } else if audio.count >= 20 {
                // Discard excess preread audio to keep waiting for the picture bounded.
                audio.removeLast(audio.count - 19)
            }
        }
        if hasStartedClock {
            let clock = synchronizer.currentTime().seconds
            if clock.isFinite { time = min(max(time, clock), duration) }
            if audioRenderer.status == .failed {
                audio.removeAll()
                if !audioWarning {
                    audioWarning = true
                    onIssue("Audio preview: the source audio could not be played.")
                }
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
