import AppKit
import AVFoundation
import CoreImage
import CoreFoundation
import MPCutCore
import SwiftUI
import VideoToolbox

struct PreviewRange: Equatable, Sendable {
    let url: URL
    let exactStart: RationalTime
    let exactEnd: RationalTime

    var start: Double { exactStart.seconds }
    var end: Double { exactEnd.seconds }
}

func previewOffsets(_ ranges: [PreviewRange]) -> (offsets: [Double], duration: Double) {
    var end = RationalTime.zero
    let offsets = ranges.map { range in
        defer { end = end + (range.exactEnd - range.exactStart) }
        return end.seconds
    }
    return (offsets, end.seconds)
}

private struct PreviewFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

private func previewTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
}

private func previewTime(_ time: RationalTime) -> CMTime {
    guard let timescale = CMTimeScale(exactly: time.denominator) else { return previewTime(time.seconds) }
    return CMTime(value: time.numerator, timescale: timescale)
}

struct PreviewFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let time: CMTime
    let transform: CGAffineTransform

    var displayTransform: CGAffineTransform {
        CGAffineTransform(a: transform.a, b: -transform.b, c: -transform.c, d: transform.d, tx: 0, ty: 0)
    }
}

private final class HardwareFrames: @unchecked Sendable {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let origin: CMTime
    private let transform: CGAffineTransform
    private let format: CMFormatDescription
    private let mapping: CMTimeMapping
    private let generator: AVSampleBufferGenerator
    private var session: VTDecompressionSession?
    private var cursor: AVSampleCursor?
    private var frames: [PreviewFrame] = []
    private let frameLock = NSLock()
    private var request: CMTime = .invalid
    private var decodeError: OSStatus = noErr

    init(url: URL) throws {
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let video = asset.tracks(withMediaType: .video)
        guard video.count == 1, let track = video.first else {
            throw PreviewFailure("macOS could not open a single preview video track in \(url.lastPathComponent).")
        }
        let descriptions = track.formatDescriptions
        guard descriptions.count == 1, let description = descriptions.first else {
            throw PreviewFailure("macOS preview requires a single video format in \(url.lastPathComponent).")
        }
        let mapping = try nativeVideoMapping(track.segments, url: url)
        // An edit may start between pictures. AVFoundation then exposes preroll at a
        // negative presentation time while the editor's index starts at the first kept picture.
        guard track.makeSampleCursor(presentationTimeStamp: mapping.source.start)?.presentationTimeStamp == mapping.source.start else {
            throw PreviewFailure("The video edit in \(url.lastPathComponent) is not aligned to an indexed picture.")
        }
        self.track = track
        self.format = description as! CMFormatDescription
        self.mapping = mapping
        generator = AVSampleBufferGenerator(asset: asset, timebase: nil)
        origin = mapping.target.start
        transform = track.preferredTransform
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    private func reset(at start: AVSampleCursor) throws {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        frameLock.withLock {
            frames.removeAll()
            decodeError = noErr
        }
        cursor = start

        let specification = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true
        ] as CFDictionary
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, pixelBuffer, pts, _ in
                guard let refCon else { return }
                let decoder = Unmanaged<HardwareFrames>.fromOpaque(refCon).takeUnretainedValue()
                decoder.frameLock.lock()
                defer { decoder.frameLock.unlock() }
                if status != noErr {
                    decoder.decodeError = status
                } else if let pixelBuffer {
                    let time = CMTimeMapTimeFromRangeToRange(pts, fromRange: decoder.mapping.source, toRange: decoder.mapping.target)
                    decoder.frames.append(PreviewFrame(buffer: pixelBuffer, time: time, transform: decoder.transform))
                }
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: specification, imageBufferAttributes: attributes,
            outputCallback: &callback, decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw PreviewFailure("Hardware video decoding is unavailable for \(asset.url.lastPathComponent) (\(status)).")
        }
        var accelerated: CFTypeRef?
        let propertyStatus = withUnsafeMutablePointer(to: &accelerated) { output in
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  allocator: kCFAllocatorDefault, valueOut: output)
        }
        guard propertyStatus == noErr, (accelerated as? NSNumber)?.boolValue == true else {
            throw PreviewFailure("VideoToolbox did not confirm hardware decoding for \(asset.url.lastPathComponent).")
        }
    }

    func frame(at seconds: Double, before end: Double? = nil, cancelled: () -> Bool) throws -> PreviewFrame? {
        guard !cancelled() else { return nil }
        let target = origin + previewTime(max(0, seconds))
        // Converted frame times can round down by a fraction of a nanosecond.
        let lookup = target + CMTime(value: 1, timescale: 1_000_000_000)
        let mediaTime = CMTimeMapTimeFromRangeToRange(lookup, fromRange: mapping.target, toRange: mapping.source)
        guard let desired = track.makeSampleCursor(presentationTimeStamp: mediaTime) else {
            throw PreviewFailure("The video track in \(asset.url.lastPathComponent) does not provide indexed samples.")
        }
        func isAfterRangeEnd() -> Bool {
            guard let end else { return false }
            return (desired.presentationTimeStamp - mapping.source.start).seconds >= end
        }
        while desired.presentationTimeStamp > mediaTime || isAfterRangeEnd() {
            guard !cancelled() else { return nil }
            if desired.stepInPresentationOrder(byCount: -1) == 0 { break }
        }
        guard !isAfterRangeEnd() else { return nil }
        let desiredTime = CMTimeMapTimeFromRangeToRange(desired.presentationTimeStamp, fromRange: mapping.source, toRange: mapping.target)
        if let cached = frameLock.withLock({ decodeError == noErr ? frames.first { $0.time == desiredTime } : nil }) {
            return cached
        }
        if session == nil || !request.isValid || desiredTime < request || (desiredTime - request).seconds > 0.5 {
            let sync = desired.copy() as! AVSampleCursor
            while !sync.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                guard !cancelled() else { return nil }
                if sync.stepInDecodeOrder(byCount: -1) == 0 { break }
            }
            if session == nil || !request.isValid || desiredTime < request ||
                cursor.map({ sync.decodeTimeStamp > $0.decodeTimeStamp }) ?? true {
                try reset(at: sync)
            }
        }
        request = desiredTime
        guard let session else { return nil }
        while !cancelled() {
            frameLock.lock()
            frames.removeAll { $0.time < desiredTime }
            let matching = frames.first { $0.time == desiredTime }
            let error = decodeError
            frameLock.unlock()
            if error != noErr {
                throw PreviewFailure("Hardware video decoding failed for \(asset.url.lastPathComponent) (\(error)).")
            }
            if let matching { return matching }
            guard let cursor else { return nil }
            let sample = try generator.makeSampleBuffer(for: AVSampleBufferRequest(start: cursor))
            // The serial decode queue owns this session. Synchronous output avoids
            // draining the whole session after each packet.
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample, flags: [],
                frameRefcon: nil, infoFlagsOut: nil
            )
            if status != noErr {
                throw PreviewFailure("Hardware video decoding failed for \(asset.url.lastPathComponent) (\(status)).")
            }
            if cursor.stepInDecodeOrder(byCount: 1) == 0 {
                self.cursor = nil
                let finishStatus = VTDecompressionSessionFinishDelayedFrames(session)
                let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
                guard finishStatus == noErr, waitStatus == noErr else {
                    let status = finishStatus == noErr ? waitStatus : finishStatus
                    throw PreviewFailure("Hardware video decoding failed for \(asset.url.lastPathComponent) (\(status)).")
                }
            }
        }
        return nil
    }
}

private func nativeVideoMapping(_ segments: [AVAssetTrackSegment], url: URL) throws -> CMTimeMapping {
    let edits = segments.filter { !$0.isEmpty }
    guard edits.count == 1, let mapping = edits.first?.timeMapping,
          mapping.source.duration == mapping.target.duration else {
        throw PreviewFailure("macOS preview requires a single continuous video edit in \(url.lastPathComponent).")
    }
    return mapping
}

private final class DecodeRequests: @unchecked Sendable {
    let queue: DispatchQueue
    private let lock = NSLock()
    private var generation = 0
    private var decoder: HardwareFrames?
    private var decoderURL: URL?

    init(label: String, qos: DispatchQoS) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func next() -> Int {
        lock.withLock {
            generation += 1
            return generation
        }
    }

    func current(_ value: Int) -> Bool {
        lock.withLock { generation == value }
    }

    func frame(url: URL, time: Double, before end: Double? = nil, cancelled: () -> Bool) throws -> PreviewFrame? {
        guard !cancelled() else { return nil }
        if decoderURL != url || decoder == nil {
            decoder = try HardwareFrames(url: url)
            decoderURL = url
        }
        return try decoder?.frame(at: time, before: end, cancelled: cancelled)
    }
}

private final class ThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

@MainActor
final class SequencePreview: ObservableObject {
    @Published private(set) var time: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var issue: String?

    private let requests = DecodeRequests(label: "mpcut.preview.video", qos: .userInteractive)
    private let audioPlayer = AVPlayer()
    private var ranges: [PreviewRange] = []
    private var offsets: [Double] = []
    private var duration = 0.0
    private var playable = false
    private var audioEnd = 0.0
    private var usingAudioClock = false
    private var loading: Task<Void, Never>?
    private var observedAudioItem: NSKeyValueObservation?
    private var ticker: Task<Void, Never>?
    private var clockStart = ContinuousClock.now
    private var startTime = 0.0
    private var rendering = false
    private var displayedURL: URL?
    private var fallback: WebSequencePlayback?
    private var sequenceGeneration = 0
    private var audioSeekGeneration = 0
    private var audioSeeking = false
    private var auditionPosition: (url: URL, time: Double)?
    private var frame: PreviewFrame?
    private let thumbnails = DecodeRequests(label: "mpcut.preview.thumbnails", qos: .utility)
    private let thumbnailContext = CIContext()
    private weak var surface: PreviewSurface?

    deinit {
        loading?.cancel()
        ticker?.cancel()
        _ = requests.next()
    }

    func update(_ ranges: [PreviewRange], at time: Double) {
        pause()
        if self.ranges == ranges {
            seek(to: time)
            return
        }

        loading?.cancel()
        fallback = nil
        sequenceGeneration += 1
        _ = requests.next()
        rendering = false
        auditionPosition = nil
        self.ranges = ranges
        (offsets, duration) = previewOffsets(ranges)
        self.time = min(max(time, 0), duration)
        playable = false
        issue = nil
        displayedURL = nil
        frame = nil
        surface?.clear()
        removeAudioItem()
        guard !ranges.isEmpty else { return }

        renderTimeline(immediate: true)
        loading = Task { [weak self] in
            do {
                let composition = try await Self.makeAudioComposition(ranges)
                let audioEnd = try await composition.load(.duration).seconds
                guard let self, !Task.isCancelled, self.fallback == nil else { return }
                if audioEnd.isFinite && audioEnd > 0 {
                    self.audioEnd = audioEnd
                    let item = AVPlayerItem(asset: composition)
                    self.audioPlayer.replaceCurrentItem(with: item)
                    self.observedAudioItem = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                        guard item.status == .failed else { return }
                        let message = item.error?.localizedDescription ?? "The source audio could not be played."
                        Task { @MainActor in
                            guard let self, self.audioPlayer.currentItem === item else { return }
                            self.startFallback(nativeIssue: message)
                        }
                    }
                    self.seekAudio()
                }
                self.playable = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.startFallback(nativeIssue: error.localizedDescription)
            }
        }
    }

    private static func makeAudioComposition(_ ranges: [PreviewRange]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        var tracks: [AVMutableCompositionTrack] = []
        var offset = CMTime.zero
        var assets: [URL: AVURLAsset] = [:]
        for range in ranges {
            try Task.checkCancellation()
            let asset = assets[range.url] ?? AVURLAsset(url: range.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            assets[range.url] = asset
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw PreviewFailure("macOS cannot read preview tracks in \(range.url.lastPathComponent).")
            }
            let videoStart = try nativeVideoMapping(try await video.load(.segments), url: range.url).target.start
            let audio = try await asset.loadTracks(withMediaType: .audio)
            for _ in tracks.count..<max(tracks.count, audio.count) {
                guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw PreviewFailure("Could not create an audio track for preview.")
                }
                tracks.append(target)
            }
            let sourceRange = CMTimeRange(start: videoStart + previewTime(range.exactStart),
                                          end: videoStart + previewTime(range.exactEnd))
            let end = offset + sourceRange.duration
            for (track, target) in zip(audio, tracks) {
                let available = try await track.load(.timeRange)
                let retained = CMTimeRangeGetIntersection(sourceRange, otherRange: available)
                if retained.isValid && retained.duration > .zero {
                    let destination = offset + retained.start - sourceRange.start
                    try target.insertTimeRange(retained, of: track, at: destination)
                }
            }
            for target in tracks {
                let targetEnd = target.timeRange.end
                if targetEnd < end {
                    target.insertEmptyTimeRange(CMTimeRange(start: targetEnd, end: end))
                }
            }
            offset = end
        }
        for track in tracks where track.segments.allSatisfy(\.isEmpty) {
            composition.removeTrack(track)
        }
        return composition
    }

    private func removeAudioItem() {
        audioSeekGeneration += 1
        audioEnd = 0
        usingAudioClock = false
        audioSeeking = false
        observedAudioItem = nil
        audioPlayer.currentItem?.cancelPendingSeeks()
        audioPlayer.replaceCurrentItem(with: nil)
    }

    private func seekAudio() {
        audioSeekGeneration += 1
        let generation = audioSeekGeneration
        audioPlayer.pause()
        usingAudioClock = time < audioEnd
        audioSeeking = usingAudioClock
        guard usingAudioClock else {
            audioPlayer.currentItem?.cancelPendingSeeks()
            return
        }
        audioPlayer.seek(to: previewTime(time), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.audioSeekGeneration == generation else { return }
                self.audioSeeking = false
                if !finished {
                    self.startFallback(nativeIssue: "The source audio could not seek to this position.")
                } else if self.isPlaying {
                    self.audioPlayer.play()
                }
            }
        }
    }

    private func startFallback(nativeIssue: String) {
        guard fallback == nil else { return }
        let wasPlaying = isPlaying
        pause()
        loading?.cancel()
        _ = requests.next()
        rendering = false
        removeAudioItem()
        let generation = sequenceGeneration
        let alternative = WebSequencePlayback(ranges: ranges, onFrame: { [weak self] frame in
            guard let self, self.sequenceGeneration == generation else { return }
            if self.issue != nil { self.issue = nil }
            self.frame = frame
            self.surface?.display(frame)
        }, onTime: { [weak self] position in
            guard let self, self.sequenceGeneration == generation else { return }
            let time = min(max(0, position), self.duration)
            if self.time != time { self.time = time }
            if self.isPlaying && self.time >= self.duration {
                self.pause()
            }
        }, onIssue: { [weak self] error in
            guard let self, self.sequenceGeneration == generation else { return }
            self.issue = "\(error) \(nativeIssue)"
            self.pause()
        })
        fallback = alternative
        if let auditionPosition {
            alternative.audition(url: auditionPosition.url, at: auditionPosition.time)
        } else {
            alternative.seek(to: time)
        }
        if wasPlaying {
            isPlaying = true
            alternative.play()
        }
    }

    func pause() {
        fallback?.pause()
        audioPlayer.pause()
        ticker?.cancel()
        ticker = nil
        isPlaying = false
    }

    func audition(_ range: PreviewRange, at sourceTime: Double) {
        pause()
        auditionPosition = (range.url, sourceTime)
        if let fallback {
            fallback.audition(url: range.url, at: sourceTime)
        } else {
            render(url: range.url, time: sourceTime)
        }
    }

    func seek(to time: Double) {
        guard time.isFinite else { return }
        auditionPosition = nil
        self.time = min(max(time, 0), duration)
        if let fallback {
            fallback.seek(to: self.time)
            return
        }
        clockStart = .now
        startTime = self.time
        if audioEnd > 0 {
            seekAudio()
        }
        renderTimeline(immediate: true)
    }

    func togglePlayback() {
        if isPlaying {
            pause()
            return
        }
        guard frame != nil, issue == nil, duration > 0 else { return }
        if time >= duration || auditionPosition != nil { seek(to: time >= duration ? 0 : time) }
        if let fallback {
            isPlaying = true
            fallback.play()
            return
        }
        guard playable else { return }
        startTime = time
        clockStart = .now
        isPlaying = true
        if usingAudioClock && !audioSeeking { audioPlayer.play() }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard !audioSeeking else { return }
        let elapsed = clockStart.duration(to: .now).components
        let clock = startTime + Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let next = usingAudioClock ? audioPlayer.currentTime().seconds : clock
        guard next.isFinite else { return }
        let position = min(max(time, next), duration)
        if position != time { time = position }
        if audioPlayer.currentItem?.status == .failed {
            startFallback(nativeIssue: audioPlayer.currentItem?.error?.localizedDescription ?? "The source audio could not be played.")
            return
        }
        if usingAudioClock && next >= audioEnd {
            // A composition omits empty trailing edits from its duration.
            // Continue on the host clock through the sequence's silent tail.
            usingAudioClock = false
            audioPlayer.pause()
            startTime = time
            clockStart = .now
        }
        if time >= duration {
            pause()
            renderTimeline(immediate: true)
            return
        }
        renderTimeline(immediate: false)
    }

    private func renderTimeline(immediate: Bool) {
        guard immediate || !rendering,
              let index = offsets.lastIndex(where: { $0 <= time }), ranges.indices.contains(index) else { return }
        let range = ranges[index]
        let sourceTime = time == duration ? range.end
            : min(range.end, range.start + (time - offsets[index]))
        render(url: range.url, time: sourceTime, before: range.end)
    }

    private func render(url: URL, time: Double, before end: Double? = nil) {
        let serial = requests.next()
        rendering = true
        let requests = requests
        requests.queue.async { [weak self] in
            guard requests.current(serial) else { return }
            let result = Result {
                try requests.frame(url: url, time: time, before: end) { !requests.current(serial) }
            }
            Task { @MainActor in
                guard let self, requests.current(serial) else { return }
                self.rendering = false
                switch result {
                case .success(let frame?):
                    if self.displayedURL != url || self.frame?.time != frame.time {
                        self.displayedURL = url
                        self.frame = frame
                        self.surface?.display(frame)
                    }
                case .success(nil):
                    self.startFallback(nativeIssue: "The source produced no picture at this position.")
                case .failure(let error):
                    self.startFallback(nativeIssue: error.localizedDescription)
                }
            }
        }
    }

    func thumbnail(url: URL, at sourceTime: Double, size: CGSize) async -> CGImage? {
        guard !Task.isCancelled, size.width > 0, size.height > 0 else { return nil }
        let context = thumbnailContext
        let request = ThumbnailRequest()
        let thumbnails = thumbnails
        let native: CGImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                thumbnails.queue.async {
                    let image = try? thumbnails.frame(url: url, time: sourceTime) { request.isCancelled }
                    guard !request.isCancelled, let image else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let pixels = CIImage(cvPixelBuffer: image.buffer).transformed(by: image.displayTransform)
                    let scale = min(size.width / pixels.extent.width, size.height / pixels.extent.height, 1)
                    let scaled = pixels.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    continuation.resume(returning: context.createCGImage(scaled, from: scaled.extent))
                }
            }
        } onCancel: {
            request.cancel()
        }
        guard !Task.isCancelled else { return nil }
        if let native { return native }
        return await WebSequencePlayback.thumbnail(url: url, at: sourceTime, size: size)
    }

    fileprivate func attach(_ surface: PreviewSurface) {
        self.surface = surface
        if let frame { surface.display(frame) }
    }
}

final class PreviewSurface: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pictureTransform = CGAffineTransform.identity

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layoutPicture()
    }

    private func layoutPicture() {
        let rotated = abs(pictureTransform.b) > abs(pictureTransform.a)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.bounds = CGRect(origin: .zero, size: rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        displayLayer.setAffineTransform(pictureTransform)
        CATransaction.commit()
    }

    fileprivate func clear() {
        displayLayer.flushAndRemoveImage()
    }

    fileprivate func display(_ frame: PreviewFrame) {
        if pictureTransform != frame.displayTransform {
            pictureTransform = frame.displayTransform
            layoutPicture()
        }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.buffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.buffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample else { return }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(array) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachment,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }
}

struct PreviewView: NSViewRepresentable {
    let preview: SequencePreview

    func makeNSView(context: Context) -> PreviewSurface {
        let surface = PreviewSurface(frame: .zero)
        preview.attach(surface)
        return surface
    }

    func updateNSView(_ nsView: PreviewSurface, context: Context) {}
}
