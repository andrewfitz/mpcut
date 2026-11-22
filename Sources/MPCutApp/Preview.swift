import AppKit
import AVFoundation
import Combine
import CoreImage
import CoreFoundation
import Metal
import MPCutCore
import SwiftUI
import VideoToolbox

struct PreviewRange: Equatable, Sendable {
    let url: URL
    let exactStart: RationalTime
    let exactEnd: RationalTime
    var isAudioOnly = false
    var audioOrigin: RationalTime?
    var usesMP3GaplessClock = false
    var audioTrack: Int?

    var start: Double { exactStart.seconds }
    var end: Double { exactEnd.seconds }
}

extension PreviewRange {
    init(media: MediaInfo, from: RationalTime, to: RationalTime) {
        self.init(url: media.url, exactStart: from, exactEnd: to, isAudioOnly: !media.hasVideo,
                  audioOrigin: media.hasVideo ? nil : media.origin,
                  usesMP3GaplessClock: !media.hasVideo && media.format.split(separator: ",").contains("mp3"))
    }
}

func previewOffsets(_ ranges: [PreviewRange]) -> (offsets: [Double], duration: Double) {
    var end = RationalTime.zero
    let offsets = ranges.map { range in
        defer { end = end + (range.exactEnd - range.exactStart) }
        return end.seconds
    }
    return (offsets, end.seconds)
}

func previewShuttleRate(_ rate: Float, direction: Int) -> Float {
    let sign: Float = direction < 0 ? -1 : 1
    let speed = rate * sign
    return sign * ([Float(1), 2, 4, 8].first { $0 > speed } ?? 8)
}

func previewAudioGain(volume: Float, muted: Bool) -> Float {
    muted ? 0 : min(max(volume, 0), 1)
}

private struct PreviewFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

func previewTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
}

func previewTime(_ time: RationalTime) -> CMTime {
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

final class HardwareFrames: @unchecked Sendable {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let origin: CMTime
    private let transform: CGAffineTransform
    private let hasMultipleDescriptions: Bool
    private var sessionFormat: CMFormatDescription?
    private let mapping: CMTimeMapping
    private let generator: AVSampleBufferGenerator
    private var session: VTDecompressionSession?
    private var cursor: AVSampleCursor?
    private var frames: [PreviewFrame] = []
    private let frameLock = NSLock()
    private var requestedPicture: CMTime = .invalid
    private var decodeError: OSStatus = noErr

    init(url: URL) throws {
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let video = asset.tracks(withMediaType: .video)
        guard video.count == 1, let track = video.first else {
            throw PreviewFailure("macOS could not open a single preview video track in \(url.lastPathComponent).")
        }
        let descriptions = track.formatDescriptions
        guard !descriptions.isEmpty else {
            throw PreviewFailure("The video track has no format description in \(url.lastPathComponent).")
        }
        let mapping = try nativeVideoMapping(track.segments, url: url)
        // An edit may start between pictures. AVFoundation then exposes preroll at a
        // negative presentation time while the editor's index starts at the first kept picture.
        guard track.makeSampleCursor(presentationTimeStamp: mapping.source.start)?.presentationTimeStamp == mapping.source.start else {
            throw PreviewFailure("The video edit in \(url.lastPathComponent) is not aligned to an indexed picture.")
        }
        self.track = track
        hasMultipleDescriptions = descriptions.count > 1
        self.mapping = mapping
        generator = AVSampleBufferGenerator(asset: asset, timebase: nil)
        origin = mapping.target.start
        transform = track.preferredTransform
    }

    func indexedFrame(at time: RationalTime, cancelled: () -> Bool) throws -> PreviewFrame? {
        guard let result = try frame(at: time.seconds, cancelled: cancelled),
              result.time - origin == previewTime(time) else { return nil }
        return result
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    // Keep one small decoder ready for a return to the previous camera. A
    // large format or an unusually deep reorder queue retains metadata only.
    func park(keepingSession: Bool) {
        if keepingSession, let sessionFormat {
            let dimensions = CMVideoFormatDescriptionGetDimensions(sessionFormat)
            let keepsFewPictures = frameLock.withLock {
                decodeError == noErr && frames.count <= 4
                    && frames.allSatisfy { CVPixelBufferGetDataSize($0.buffer) <= 8 * 1024 * 1024 }
            }
            if Int64(dimensions.width) * Int64(dimensions.height) <= 1920 * 1080, keepsFewPictures { return }
        }
        releaseSession()
    }

    private func releaseSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        sessionFormat = nil
        cursor = nil
        frameLock.withLock {
            frames.removeAll()
            decodeError = noErr
            requestedPicture = .invalid
        }
    }

    /// Later pictures of the group can be predicted from the rejected one. Dropping the session
    /// makes the next request decode again from its own keyframe.
    private func decodeFailure(_ status: OSStatus) -> PreviewFailure {
        releaseSession()
        return PreviewFailure("Hardware video decoding failed for \(asset.url.lastPathComponent) (\(status)).")
    }

    private func reset(at start: AVSampleCursor, requesting picture: CMTime) throws {
        releaseSession()
        frameLock.withLock { requestedPicture = picture }
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
                    // Keep later pictures that arrive first in decode order.
                    if time >= decoder.requestedPicture {
                        decoder.frames.append(PreviewFrame(buffer: pixelBuffer, time: time, transform: decoder.transform))
                    }
                }
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let format = start.copyCurrentSampleFormatDescription()
        sessionFormat = format
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
        let (request, cached) = frameLock.withLock {
            (requestedPicture, decodeError == noErr ? frames.first { $0.time == desiredTime } : nil)
        }
        if let cached {
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
                try reset(at: sync, requesting: desiredTime)
            }
        }
        frameLock.withLock {
            requestedPicture = desiredTime
            frames.removeAll { $0.time < desiredTime }
        }
        while !cancelled() {
            frameLock.lock()
            let matching = frames.first { $0.time == desiredTime }
            let error = decodeError
            frameLock.unlock()
            if error != noErr { throw decodeFailure(error) }
            if let matching { return matching }
            guard let cursor else { return nil }
            if hasMultipleDescriptions, let format = sessionFormat,
               !CFEqual(cursor.copyCurrentSampleFormatDescription(), format) {
                guard cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue, let previous = session,
                      VTDecompressionSessionFinishDelayedFrames(previous) == noErr,
                      VTDecompressionSessionWaitForAsynchronousFrames(previous) == noErr else {
                    throw PreviewFailure("The video changes format between random-access pictures.")
                }
                if let delayed = frameLock.withLock({ frames.first { $0.time == desiredTime } }) { return delayed }
                try reset(at: cursor, requesting: desiredTime)
            }
            guard let session else { return nil }
            let sample = try generator.makeSampleBuffer(for: AVSampleBufferRequest(start: cursor))
            // The serial decode queue owns this session. Synchronous output avoids
            // draining the whole session after each packet.
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample, flags: [],
                frameRefcon: nil, infoFlagsOut: nil
            )
            if status != noErr { throw decodeFailure(status) }
            if cursor.stepInDecodeOrder(byCount: 1) == 0 {
                self.cursor = nil
                let finishStatus = VTDecompressionSessionFinishDelayedFrames(session)
                let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
                guard finishStatus == noErr, waitStatus == noErr else {
                    throw decodeFailure(finishStatus == noErr ? waitStatus : finishStatus)
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

// Accessed only on the owning decode queue. The end is part of the key:
// the same timestamp at an exclusive trim boundary can show a different frame.
struct ScrubFrameCache {
    private struct Entry {
        let time: Double
        let end: Double?
        let frame: PreviewFrame
        let bytes: Int
    }

    private var entries: [Entry] = []
    private var bytes = 0
    private var source: URL?

    mutating func frame(url: URL, at time: Double, before end: Double?,
                        decode: () throws -> PreviewFrame?) rethrows -> PreviewFrame? {
        if source != url {
            entries.removeAll(keepingCapacity: true)
            bytes = 0
            source = url
        }
        if let hit = entries.last(where: { $0.time == time && $0.end == end }) { return hit.frame }
        guard let frame = try decode() else { return nil }
        let size = CVPixelBufferGetDataSize(frame.buffer)
        let budget = 48 * 1024 * 1024
        guard size > 0, size <= budget else { return frame }
        while entries.count >= 8 || bytes + size > budget {
            bytes -= entries.removeFirst().bytes
        }
        entries.append(Entry(time: time, end: end, frame: frame, bytes: size))
        bytes += size
        return frame
    }
}

private final class DecodeRequests: @unchecked Sendable {
    let queue: DispatchQueue
    private let lock = NSLock()
    private var generation = 0
    private var decoder: HardwareFrames?
    private var decoderURL: URL?
    private var recent = ScrubFrameCache()

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

    func releaseDecoder() {
        queue.async {
            self.decoder = nil
            self.decoderURL = nil
            self.recent = ScrubFrameCache()
        }
    }

    func frame(url: URL, time: Double, before end: Double?, scrubbing: Bool, cancelled: () -> Bool) throws -> PreviewFrame? {
        guard !cancelled() else { return nil }
        if decoderURL != url || decoder == nil {
            decoder = try HardwareFrames(url: url)
            decoderURL = url
        }
        if !scrubbing { return try decoder?.frame(at: time, before: end, cancelled: cancelled) }
        return try recent.frame(url: url, at: time, before: end) {
            try decoder?.frame(at: time, before: end, cancelled: cancelled)
        }
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

// The serial queue owns the decoders. Retain the successful route for successive
// thumbnails of a source, including segments created by splitting the same clip.
private final class ThumbnailDecoder: @unchecked Sendable {
    let queue = DispatchQueue(label: "mpcut.preview.thumbnails", qos: .utility, autoreleaseFrequency: .workItem)
    private static let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "MPCut Filmstrip"]
        guard let device = MTLCreateSystemDefaultDevice() else { return CIContext(options: options) }
        return CIContext(mtlDevice: device, options: options)
    }()
    private var sourceID: UUID?
    private var native: HardwareFrames?
    private var fallback = FFPreviewReader(videoOnly: true)

    func image(source: UUID, url: URL, time: Double, size: CGSize, request: ThumbnailRequest) -> CGImage? {
        guard !request.isCancelled else { return nil }
        if sourceID != source {
            native = try? HardwareFrames(url: url)
            fallback = FFPreviewReader(videoOnly: true)
            sourceID = source
        }
        var frame = try? native?.frame(at: time) { request.isCancelled }
        if frame == nil && !request.isCancelled {
            frame = try? fallback.perform(cancelled: { request.isCancelled }) {
                try fallback.seek(url: url, to: time)
                return try fallback.still(at: time) { request.isCancelled }
            }
            if frame != nil { native = nil }
        }
        guard let frame, !request.isCancelled else { return nil }
        let pixels = CIImage(cvPixelBuffer: frame.buffer).transformed(by: frame.displayTransform)
        let scale = min(size.width / pixels.extent.width, size.height / pixels.extent.height, 1)
        let scaled = pixels.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return Self.context.createCGImage(scaled, from: scaled.extent)
    }
}

@MainActor
final class SequencePreview: ObservableObject {
    @Published private(set) var time: Double = 0
    @Published private(set) var playbackRate: Float = 0
    @Published private(set) var forwardSpeed: PlaybackSpeed = .normal
    private var playbackScreen: NSScreen? {
        surfaces.allObjects.compactMap { $0.window?.screen }.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }
    }

    func selectPlaybackSpeed(_ speed: PlaybackSpeed) {
        forwardSpeed = speed
        if isPlaying { startPlayback(at: speed.rawValue) }
    }

    var isPlaying: Bool { playbackRate != 0 }
    @Published private(set) var issue: String?
    // Damaged audio stops one decoding pass. Seeking or playing again may get past it.
    // A damaged picture leaves one position without a picture. Playback resumes at the next keyframe.
    private var issueAllowsRetry = false
    var hasBlockingIssue: Bool { issue != nil && !issueAllowsRetry }
    @Published private(set) var audioWarning: String?

    @Published var volume: Float = 1 {
        didSet {
            updateGain()
            if let preferences, preferences.volume != volume { preferences.volume = volume }
        }
    }
    @Published var isMuted = false {
        didSet {
            updateGain()
            if let preferences, preferences.isMuted != isMuted { preferences.isMuted = isMuted }
        }
    }
    @Published var scrubSoundEnabled = true {
        didSet {
            if !scrubSoundEnabled { scrubAudio.stop() }
            if let preferences, preferences.scrubSoundEnabled != scrubSoundEnabled {
                preferences.scrubSoundEnabled = scrubSoundEnabled
            }
        }
    }
    private let preferences: EditorPreferences?
    private var preferenceObservation: AnyCancellable?
    private let scrubAudio: ScrubAudioPlayer
    private let reverseAudio: ReverseAudioPlayer
    private var scrubPicture: (source: URL, pts: Double, end: Double)?
    private var scrubRangeIndex: Int?

    private func updateGain() {
        let gain = previewAudioGain(volume: volume, muted: isMuted)
        audioPlayer?.volume = gain
        fallback?.setGain(gain)
        reverseAudio.gain = gain
        scrubAudio.gain = gain
        if gain == 0 { scrubAudio.stop() }
    }

    private let requests = DecodeRequests(label: "mpcut.preview.video", qos: .userInteractive)
    private var audioPlayer: AVPlayer?
    private(set) var ranges: [PreviewRange] = []
    private var offsets: [Double] = []
    private var duration = 0.0
    private var playable = false
    private var readyForTransport: Bool {
        frame != nil || (canPlayWithoutPicture && fallback != nil)
            || (ranges.first?.isAudioOnly == true && (playable || fallback != nil))
    }
    // The position has no picture to show. The fallback transport can still play on from it.
    private var canPlayWithoutPicture = false
    private var audioEnd = 0.0
    private var usingAudioClock = false
    private var loading: Task<Void, Never>?
    private var observedAudioItem: NSKeyValueObservation?
    private var ticker: PreviewDisplayTicker?
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
    var displayedFrameTime: CMTime? { frame?.time }
    private var thumbnails = ThumbnailDecoder()
    private let tileWriter = FilmstripTileWriter()
    private let surfaces = NSHashTable<PreviewSurface>.weakObjects()

    init(reverseAudioEngine: AVAudioEngine? = nil, scrubAudioEngine: AVAudioEngine? = nil,
         preferences: EditorPreferences? = nil) {
        self.preferences = preferences
        reverseAudio = ReverseAudioPlayer(engine: reverseAudioEngine)
        scrubAudio = ScrubAudioPlayer(engine: scrubAudioEngine)
        guard let preferences else { return }
        volume = preferences.volume
        isMuted = preferences.isMuted
        scrubSoundEnabled = preferences.scrubSoundEnabled
        updateGain()
        preferenceObservation = preferences.observeChanges { [weak self, weak preferences] change in
            guard let self, let preferences else { return }
            switch change {
            case .volume where volume != preferences.volume:
                volume = preferences.volume
            case .isMuted where isMuted != preferences.isMuted:
                isMuted = preferences.isMuted
            case .scrubSoundEnabled where scrubSoundEnabled != preferences.scrubSoundEnabled:
                scrubSoundEnabled = preferences.scrubSoundEnabled
            default:
                break
            }
        }
    }

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
        issueAllowsRetry = false
        canPlayWithoutPicture = false
        audioWarning = nil
        clearPicture()
        removeAudioItem()
        guard !ranges.isEmpty else {
            audioPlayer = nil
            requests.releaseDecoder()
            thumbnails = ThumbnailDecoder()
            return
        }

        // Read Xing/LAME delay and padding on the same clock used by the index
        // and copy export. One transport owns the full sequence across joins.
        if ranges.contains(where: \.usesMP3GaplessClock) {
            startFallback()
            return
        }
        renderTimeline(immediate: true)
        loading = Task { [weak self] in
            do {
                let composition = try await Self.makeAudioComposition(ranges)
                let audioEnd = try await composition.load(.duration).seconds
                guard let self, !Task.isCancelled, self.fallback == nil else { return }
                if audioEnd.isFinite && audioEnd > 0 {
                    self.audioEnd = audioEnd
                    let item = AVPlayerItem(asset: composition)
                    let player = self.audioPlayer ?? AVPlayer()
                    player.volume = previewAudioGain(volume: self.volume, muted: self.isMuted)
                    self.audioPlayer = player
                    player.replaceCurrentItem(with: item)
                    self.observedAudioItem = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                        guard item.status == .failed else { return }
                        let message = item.error?.localizedDescription ?? "The source audio could not be played."
                        Task { @MainActor in
                            guard let self, self.audioPlayer?.currentItem === item else { return }
                            self.startFallback(nativeIssue: message)
                        }
                    }
                    if self.playbackRate < 0 { self.startReverseAudio() }
                    else if self.scrubRangeIndex == nil { self.seekAudio() }
                }
                if self.audioEnd == 0 { self.audioPlayer = nil }
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
            var audio = try await asset.loadTracks(withMediaType: .audio)
            let origin: CMTime
            if range.isAudioOnly {
                var earliest: CMTime?
                for track in audio {
                    let start = try await track.load(.timeRange).start
                    earliest = earliest.map { min($0, start) } ?? start
                }
                guard let earliest else {
                    throw PreviewFailure("macOS could not read audio in \(range.url.lastPathComponent).")
                }
                origin = earliest
            } else {
                guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                    throw PreviewFailure("macOS cannot read preview tracks in \(range.url.lastPathComponent).")
                }
                origin = try nativeVideoMapping(try await video.load(.segments), url: range.url).target.start
            }
            if let index = range.audioTrack ?? (range.isAudioOnly ? 0 : nil) {
                guard audio.indices.contains(index) else {
                    throw PreviewFailure("macOS could not read the selected audio track in \(range.url.lastPathComponent).")
                }
                audio = [audio[index]]
            }
            for _ in tracks.count..<max(tracks.count, audio.count) {
                guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw PreviewFailure("Could not create an audio track for preview.")
                }
                tracks.append(target)
            }
            let sourceRange = CMTimeRange(start: origin + previewTime(range.exactStart),
                                          end: origin + previewTime(range.exactEnd))
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
        audioPlayer?.currentItem?.cancelPendingSeeks()
        audioPlayer?.replaceCurrentItem(with: nil)
    }

    private func seekAudio() {
        audioSeekGeneration += 1
        let generation = audioSeekGeneration
        audioPlayer?.pause()
        usingAudioClock = audioPlayer != nil && time < audioEnd
        audioSeeking = usingAudioClock
        guard usingAudioClock, let audioPlayer else {
            audioPlayer?.currentItem?.cancelPendingSeeks()
            return
        }
        audioPlayer.seek(to: previewTime(time), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.audioSeekGeneration == generation else { return }
                self.audioSeeking = false
                if !finished {
                    self.startFallback(nativeIssue: "The source audio could not seek to this position.")
                } else if self.playbackRate > 0 {
                    self.audioPlayer?.rate = self.playbackRate
                }
            }
        }
    }

    private func startFallback(nativeIssue: String? = nil) {
        guard fallback == nil else { return }
        let priorRate = playbackRate
        pause()
        loading?.cancel()
        _ = requests.next()
        requests.releaseDecoder()
        rendering = false
        removeAudioItem()
        audioPlayer = nil
        let generation = sequenceGeneration
        let alternative = WebSequencePlayback(ranges: ranges, screen: { [weak self] in self?.playbackScreen }, onFrame: { [weak self] frame in
            guard let self, self.sequenceGeneration == generation else { return }
            if self.issue != nil { self.issue = nil }
            self.issueAllowsRetry = false
            self.canPlayWithoutPicture = false
            self.frame = frame
            self.surfaces.allObjects.forEach { $0.display(frame) }
        }, onTime: { [weak self] position in
            guard let self, self.sequenceGeneration == generation else { return }
            let time = min(max(0, position), self.duration)
            if self.time != time { self.time = time }
            if self.playbackRate > 0 && self.time >= self.duration {
                self.pause()
            }
        }, onIssue: { [weak self] error in
            guard let self, self.sequenceGeneration == generation else { return }
            self.clearPicture()
            self.canPlayWithoutPicture = error == WebSequencePlayback.damagedPicture
            self.issueAllowsRetry = error == WebSequencePlayback.undecodableAudio || self.canPlayWithoutPicture
            self.issue = nativeIssue.map { "\(error) \($0)" } ?? error
            self.pause()
        }, onAudioWarning: { [weak self] message in
            guard let self, self.sequenceGeneration == generation else { return }
            self.audioWarning = message
        }, onGap: { [weak self] in
            guard let self, self.sequenceGeneration == generation else { return }
            self.clearPicture()
            self.canPlayWithoutPicture = true
            self.issue = nil
            self.issueAllowsRetry = false
        })
        alternative.setGain(isMuted ? 0 : volume)
        fallback = alternative
        if let auditionPosition {
            alternative.audition(url: auditionPosition.url, at: auditionPosition.time)
        } else {
            alternative.seek(to: time)
        }
        if priorRate != 0 {
            startPlayback(at: priorRate)
        }
    }

    func pause() {
        if auditionPosition != nil { scrubAudio.stop() }
        endScrub()
        if playbackRate < 0, let position = reverseAudio.position { time = min(time, position) }
        reverseAudio.stop()
        fallback?.pause()
        audioPlayer?.pause()
        ticker?.cancel()
        ticker = nil
        playbackRate = 0
    }

    func audition(_ range: PreviewRange, at sourceTime: Double, sourceDuration: Double? = nil, reverse: Bool = false) {
        if !range.isAudioOnly || auditionPosition?.url != range.url || isPlaying { pause() }
        auditionPosition = (range.url, sourceTime)
        if range.isAudioOnly {
            // A handle can be dragged into previously excluded material. Use the
            // source clock here even when playback currently has a composition.
            if scrubSoundEnabled, !isMuted, volume > 0, let end = sourceDuration, end > 0,
               let request = ScrubAudioRequest(source: range.url, composition: nil, position: sourceTime,
                                               bounds: 0..<end, reverse: reverse, audioOrigin: range.audioOrigin,
                                               audioTrack: range.audioTrack) {
                scrubAudio.submit(request)
            }
            return
        }
        if let fallback {
            fallback.audition(url: range.url, at: sourceTime)
        } else {
            render(url: range.url, time: sourceTime)
        }
    }

    func scrub(to position: Double, rangeIndex: Int, sourceFrame: Double) {
        guard ranges.indices.contains(rangeIndex) else { return }
        let range = ranges[rangeIndex]
        let start = offsets[rangeIndex]
        let end = rangeIndex + 1 < offsets.count ? offsets[rangeIndex + 1] : duration
        let target = min(max(position, start), end)
        let reverse = target < time
        if scrubRangeIndex == nil {
            pause()
            audioSeekGeneration += 1
            audioPlayer?.currentItem?.cancelPendingSeeks()
        } else if scrubRangeIndex != rangeIndex {
            scrubAudio.stop()
        }
        scrubRangeIndex = rangeIndex
        auditionPosition = nil
        time = target
        if !range.isAudioOnly && (scrubPicture?.source != range.url || scrubPicture?.pts != sourceFrame || scrubPicture?.end != range.end) {
            scrubPicture = (range.url, sourceFrame, range.end)
            if let fallback { fallback.audition(url: range.url, at: sourceFrame, before: range.end) }
            else { render(url: range.url, time: sourceFrame, before: range.end) }
        }
        guard scrubSoundEnabled, !isMuted, volume > 0 else { return }
        let composition = audioPlayer?.currentItem?.asset
        guard composition != nil || fallback != nil else { return }
        let point = composition == nil ? min(range.end, range.start + (target - start)) : target
        let bounds = composition == nil ? range.start..<range.end : start..<end
        if let request = ScrubAudioRequest(source: range.url, composition: composition,
                                           position: point, bounds: bounds, reverse: reverse, audioOrigin: range.audioOrigin,
                                           audioTrack: range.audioTrack) {
            scrubAudio.submit(request)
        }
    }

    func endScrub() {
        guard scrubRangeIndex != nil else { return }
        stopScrub()
        fallback?.park(at: time)
        if audioEnd > 0 { seekAudio() }
    }

    private func stopScrub() {
        scrubRangeIndex = nil
        scrubPicture = nil
        scrubAudio.stop()
    }

    private func clearRetryableIssue() {
        guard issueAllowsRetry else { return }
        issueAllowsRetry = false
        issue = nil
    }

    func seek(to time: Double) {
        guard time.isFinite else { return }
        clearRetryableIssue()
        if scrubRangeIndex != nil || auditionPosition != nil { stopScrub() }
        auditionPosition = nil
        self.time = min(max(time, 0), duration)
        clockStart = .now
        startTime = self.time
        if playbackRate < 0 { startReverseAudio() }
        if let fallback {
            fallback.seek(to: self.time)
            return
        }
        if playbackRate >= 0 && audioEnd > 0 {
            seekAudio()
        }
        renderTimeline(immediate: true)
    }

    func togglePlayback() {
        if isPlaying {
            pause()
            return
        }
        clearRetryableIssue()
        if readyForTransport && issue == nil {
            if time >= duration { seek(to: 0) }
            startPlayback(at: forwardSpeed.rawValue)
        }
    }

    func shuttle(_ direction: Int) {
        clearRetryableIssue()
        startPlayback(at: previewShuttleRate(playbackRate, direction: direction))
    }

    private func startPlayback(at rate: Float) {
        guard readyForTransport, issue == nil, rate != playbackRate, duration > 0 else { return }
        if (rate > 0 && time >= duration) || (rate < 0 && time <= 0) {
            pause()
            return
        }
        guard rate < 0 || fallback != nil || playable else { return }
        endScrub()
        if auditionPosition != nil { seek(to: time) }

        // Adjust an active forward stream in place, retaining its decoded audio.
        if rate > 0, playbackRate > 0 {
            playbackRate = rate
            startTime = time
            clockStart = .now
            if let fallback { fallback.play(rate: rate) }
            else if usingAudioClock && !audioSeeking { audioPlayer?.rate = rate }
            return
        }

        pause()
        playbackRate = rate
        startTime = time
        clockStart = .now
        if let fallback, rate > 0 {
            fallback.park(at: time)
            fallback.play(rate: rate)
            return
        }
        if rate > 0, audioEnd > 0 { seekAudio() }
        if rate < 0 { startReverseAudio() }
        ticker = PreviewDisplayTicker(screen: playbackScreen) { [weak self] in self?.tick() }
    }

    private func startReverseAudio() {
        let composition = audioPlayer?.currentItem?.asset
        guard composition != nil || fallback != nil else { return }
        let timeline = ReverseAudioTimeline(ranges: ranges, offsets: offsets, composition: composition)
        reverseAudio.start(timeline, at: time, speed: Int(-playbackRate))
    }

    private func tick() {
        let elapsed = clockStart.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let clock = startTime + seconds * Double(playbackRate)
        if playbackRate < 0 {
            reverseAudio.tick()
            if let position = reverseAudio.position {
                time = min(time, position)
                // Preserve continuity if the output device becomes unavailable.
                startTime = time
                clockStart = .now
            } else {
                time = max(0, clock)
            }
            if time == 0 {
                pause()
                seek(to: 0)
            } else if let fallback, ranges.first?.isAudioOnly != true {
                fallback.displayStill(at: time)
            } else {
                renderTimeline(immediate: false)
            }
            return
        }
        guard !audioSeeking else { return }
        let next = usingAudioClock ? (audioPlayer?.currentTime().seconds ?? clock) : clock
        guard next.isFinite else { return }
        let position = min(max(time, next), duration)
        if position != time { time = position }
        if audioPlayer?.currentItem?.status == .failed {
            startFallback(nativeIssue: audioPlayer?.currentItem?.error?.localizedDescription ?? "The source audio could not be played.")
            return
        }
        if usingAudioClock && next >= audioEnd {
            // A composition omits empty trailing edits from its duration.
            // Continue on the host clock through the sequence's silent tail.
            usingAudioClock = false
            audioPlayer?.pause()
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
        guard immediate || !rendering, !offsets.isEmpty else { return }
        let index = max(0, offsets.lowerBound { $0 > time } - 1)
        let range = ranges[index]
        guard !range.isAudioOnly else { return }
        let sourceTime = time == duration ? range.end
            : min(range.end, range.start + (time - offsets[index]))
        render(url: range.url, time: sourceTime, before: range.end, scrubbing: immediate)
    }

    private func render(url: URL, time: Double, before end: Double? = nil, scrubbing: Bool = true) {
        let serial = requests.next()
        rendering = true
        let requests = requests
        requests.queue.async { [weak self] in
            guard requests.current(serial) else { return }
            let result = Result {
                try requests.frame(url: url, time: time, before: end, scrubbing: scrubbing) { !requests.current(serial) }
            }
            Task { @MainActor in
                guard let self, requests.current(serial) else { return }
                self.rendering = false
                switch result {
                case .success(let frame?):
                    if self.displayedURL != url || self.frame?.time != frame.time {
                        self.displayedURL = url
                        self.frame = frame
                        self.surfaces.allObjects.forEach { $0.display(frame) }
                    }
                case .success(nil):
                    self.startFallback(nativeIssue: "The source produced no picture at this position.")
                case .failure(let error):
                    self.startFallback(nativeIssue: error.localizedDescription)
                }
            }
        }
    }

    func thumbnail(source: UUID, url: URL, at time: Double, size: CGSize,
                   saved: (AnalysisSidecar, FilmstripTileKey)? = nil,
                   cacheEnabled: @escaping @Sendable () -> Bool = { true },
                   preserveAlpha: Bool = false, onRender: (CGImage) -> Void = { _ in }) async -> CGImage? {
        guard !Task.isCancelled, size.width > 0, size.height > 0 else { return nil }
        let request = ThumbnailRequest()
        let thumbnails = thumbnails
        let tileWriter = tileWriter
        let result: (image: CGImage?, restored: Bool) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                thumbnails.queue.async {
                    let skipCache: @Sendable () -> Bool = { request.isCancelled || !cacheEnabled() }
                    if let (sidecar, key) = saved, let image = key.image(in: sidecar, cancelled: skipCache), !skipCache() {
                        continuation.resume(returning: (image, true))
                        return
                    }
                    let image = thumbnails.image(source: source, url: url, time: time, size: size, request: request)
                    if let image, let (sidecar, key) = saved, !skipCache() {
                        tileWriter.submit(image, key: key, sidecar: sidecar, preserveAlpha: preserveAlpha,
                                          cancelled: skipCache)
                    }
                    continuation.resume(returning: (image, false))
                }
            }
        } onCancel: {
            request.cancel()
        }
        guard !Task.isCancelled, let image = result.image else { return nil }
        if !result.restored { onRender(image) }
        return image
    }

    fileprivate func attach(_ surface: PreviewSurface) {
        surfaces.add(surface)
        if let frame { surface.display(frame) }
    }

    private func clearPicture() {
        displayedURL = nil
        frame = nil
        surfaces.allObjects.forEach { $0.clear() }
    }

    fileprivate func detach(_ surface: PreviewSurface) {
        surfaces.remove(surface)
    }
}

final class PreviewSurface: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var cachedFormat: CMVideoFormatDescription?
    private var pictureTransform = CGAffineTransform.identity
    var windowChanged: ((PreviewSurface) -> Void)?
    private(set) var displayedFrameTime: CMTime?

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clear() }
        windowChanged?(self)
    }

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

    func clear() {
        displayedFrameTime = nil
        cachedFormat = nil
        displayLayer.flushAndRemoveImage()
    }

    func display(_ frame: PreviewFrame) {
        if pictureTransform != frame.displayTransform {
            pictureTransform = frame.displayTransform
            layoutPicture()
        }
        if cachedFormat.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: frame.buffer) }) != true {
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.buffer,
                                                               formatDescriptionOut: &format) == noErr else { return }
            cachedFormat = format
        }
        guard let format = cachedFormat else { return }
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
        displayedFrameTime = frame.time
    }
}

struct PreviewView: NSViewRepresentable {
    let preview: SequencePreview

    func makeNSView(context: Context) -> PreviewSurface {
        let surface = PreviewSurface(frame: .zero)
        surface.windowChanged = { [weak preview] surface in
            if surface.window == nil { preview?.detach(surface) }
            else { preview?.attach(surface) }
        }
        return surface
    }

    func updateNSView(_ nsView: PreviewSurface, context: Context) {}
}
