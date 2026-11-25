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
    var assetClockOrigin: RationalTime?
    var usesMP3GaplessClock = false
    var audioTrack: Int?
    var audioTrackIDs: [CMPersistentTrackID]?
    var isSilentInsert = false
    var programTransfer: String?
    var readerRevision = 0
    var unavailablePicture: String?

    var start: Double { exactStart.seconds }
    var end: Double { exactEnd.seconds }
}

extension PreviewRange {
    init(media: MediaInfo, from: RationalTime, to: RationalTime) {
        self.init(url: media.url, exactStart: from, exactEnd: to, isAudioOnly: !media.hasVideo,
                  audioOrigin: media.hasVideo ? nil : media.origin,
                  usesMP3GaplessClock: !media.hasVideo && media.format.split(separator: ",").contains("mp3"))
        programTransfer = media.videoStream?.colorTransfer
        if media.format.split(separator: ",").contains("mov") {
            audioTrackIDs = media.streams.filter { $0.kind == "audio" }.map(\.trackID)
        }
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

struct SequenceSourcePicture: Equatable {
    let url: URL
    let time: RationalTime
    let identity: SourceIdentity?

    init?(url: URL?, pts: CMTime, identity: SourceIdentity?) {
        guard let url, pts.isNumeric, pts.timescale > 0 else { return nil }
        self.url = url
        self.identity = identity
        time = RationalTime(numerator: pts.value, denominator: Int64(pts.timescale))
    }
}

struct PreviewFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let time: CMTime
    let transform: CGAffineTransform
    var programTransfer: String? = nil
    var sourceRendition: String? = nil
    var cameraTransfer: String? = nil
    var sourcePicture: SequenceSourcePicture? = nil
    var timelinePictureTime: RationalTime? = nil
    var privacyCoverNote: String? = nil
    /// Set when FFmpeg decoded this picture in place of AVFoundation: why. The viewer's status says so.
    var decoderNote: String? = nil

    func tagged(transfer: String?, cameraTransfer: String? = nil) -> Self {
        var result = self
        result.programTransfer = transfer ?? programTransfer
        result.cameraTransfer = cameraTransfer ?? self.cameraTransfer
        return result
    }

    var displayTransform: CGAffineTransform {
        CGAffineTransform(a: transform.a, b: -transform.b, c: -transform.c, d: transform.d, tx: 0, ty: 0)
    }
}

final class HardwareFrames: @unchecked Sendable {
    private let asset: AVURLAsset
    private let sourceIdentity: SourceIdentity?
    private let track: AVAssetTrack
    private let origin: CMTime
    private let transform: CGAffineTransform
    private let hasMultipleDescriptions: Bool
    private var sessionFormat: CMFormatDescription?
    private let mapping: CMTimeMapping
    private let generator: AVSampleBufferGenerator
    private var session: VTDecompressionSession?
    private var cursor: AVSampleCursor?
    /// The decode time of the keyframe the session began at.
    private var sessionStart: CMTime = .invalid
    private var frames: [PreviewFrame] = []
    private let frameLock = NSLock()
    private var requestedPicture: CMTime = .invalid
    private var decodeError: OSStatus = noErr

    init(url: URL) throws {
        sourceIdentity = try? SourceIdentity(url)
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
        sessionStart = .invalid
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
        sessionStart = start.decodeTimeStamp

        let format = start.copyCurrentSampleFormatDescription()
        // Photo JPEG MOV uses the native image decoder without a hardware session.
        let isPhotoJPEG = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_JPEG
        let specification: CFDictionary? = isPhotoJPEG ? nil : [
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
                        decoder.frames.append(PreviewFrame(buffer: pixelBuffer, time: time, transform: decoder.transform,
                            sourcePicture: .init(url: decoder.asset.url, pts: time - decoder.origin, identity: decoder.sourceIdentity)))
                    }
                }
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        sessionFormat = format
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: specification, imageBufferAttributes: attributes,
            outputCallback: &callback, decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            let decoder = isPhotoJPEG ? "Photo JPEG" : "Hardware video"
            throw PreviewFailure("\(decoder) decoding is unavailable for \(asset.url.lastPathComponent) (\(status)).")
        }
        if isPhotoJPEG { return }
        var accelerated: CFTypeRef?
        let propertyStatus = withUnsafeMutablePointer(to: &accelerated) { output in
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  allocator: kCFAllocatorDefault, valueOut: output)
        }
        guard propertyStatus == noErr, (accelerated as? NSNumber)?.boolValue == true else {
            throw PreviewFailure("VideoToolbox did not confirm hardware decoding for \(asset.url.lastPathComponent).")
        }
    }

    func frame(at seconds: Double, before end: Double? = nil, nearbyKeyframe: Bool = false,
               cancelled: () -> Bool) throws -> PreviewFrame? {
        guard !cancelled() else { return nil }
        let target = origin + previewTime(max(0, seconds))
        // Converted frame times can round down by a fraction of a nanosecond.
        let lookup = target + CMTime(value: 1, timescale: 1_000_000_000)
        let mediaTime = CMTimeMapTimeFromRangeToRange(lookup, fromRange: mapping.target, toRange: mapping.source)
        guard var desired = track.makeSampleCursor(presentationTimeStamp: mediaTime) else {
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
        if nearbyKeyframe {
            let sync = desired.copy() as! AVSampleCursor
            while !sync.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                if cancelled() { return nil }
                if sync.stepInDecodeOrder(byCount: -1) == 0 { break }
            }
            if sync.presentationTimeStamp >= mapping.source.start { desired = sync }
        }
        let desiredTime = CMTimeMapTimeFromRangeToRange(desired.presentationTimeStamp, fromRange: mapping.source, toRange: mapping.target)
        let (request, cached) = frameLock.withLock {
            (requestedPicture, decodeError == noErr ? frames.first { $0.time == desiredTime } : nil)
        }
        if let cached {
            return cached
        }
        /// A picture rejected in an earlier group, in this request or a cancelled one, does not stop a picture of
        /// a later group: the session starts again at that picture's own keyframe, once.
        func restartsAtOwnKeyframe() throws -> Bool {
            let sync = desired.copy() as! AVSampleCursor
            while !sync.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                if cancelled() { throw CancellationError() }
                if sync.stepInDecodeOrder(byCount: -1) == 0 { break }
            }
            guard sessionStart.isValid, sync.decodeTimeStamp > sessionStart else { return false }
            try reset(at: sync, requesting: desiredTime)
            return true
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
            if error != noErr {
                if try restartsAtOwnKeyframe() { continue }
                throw decodeFailure(error)
            }
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
            if status != noErr {
                if try restartsAtOwnKeyframe() { continue }
                throw decodeFailure(status)
            }
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

/// Coalesces pending picture work on a serial decoder queue. Maintenance
/// seals the current slot so later requests cannot overtake it.
final class LatestPreviewWork: @unchecked Sendable {
    private final class Slot: @unchecked Sendable {
        var work: @Sendable () -> Void

        init(_ work: @escaping @Sendable () -> Void) {
            self.work = work
        }
    }

    private let lock = NSLock()
    private var pending: Slot?

    func submit(on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
        lock.withLock {
            if let pending {
                pending.work = work
                return
            }
            let slot = Slot(work)
            pending = slot
            queue.async {
                let work = self.lock.withLock {
                    if self.pending === slot { self.pending = nil }
                    return slot.work
                }
                work()
            }
        }
    }

    func enqueueMaintenance(on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
        lock.withLock {
            pending = nil
            queue.async(execute: work)
        }
    }
}

/// The viewer status line for a picture FFmpeg decoded (with VideoToolbox) in place of AVFoundation.
func ffmpegDecoderNote(_ reason: String?) -> String {
    "Decoded by FFmpeg with VideoToolbox" + (reason.map { " because AVFoundation could not: \($0)" } ?? ".")
}

private final class DecodeRequests: @unchecked Sendable {
    let queue: DispatchQueue
    let pictureWork = LatestPreviewWork()
    private let lock = NSLock()
    private var generation = 0
    private var decoder: HardwareFrames?
    private var decoderURL: URL?
    private var recent = ScrubFrameCache()
    private var fallback = FFPreviewReader(videoOnly: true)
    private var fallbackURL: URL?
    private var fallbackReason: String?

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
        pictureWork.enqueueMaintenance(on: queue) {
            self.decoder = nil
            self.decoderURL = nil
            self.recent = ScrubFrameCache()
            self.fallback = FFPreviewReader(videoOnly: true)
            self.fallbackURL = nil
            self.fallbackReason = nil
        }
    }

    func frame(url: URL, time: Double, before end: Double?, scrubbing: Bool, pictureOnlyFallback: Bool,
               cancelled: @escaping () -> Bool) throws -> PreviewFrame? {
        guard !cancelled() else { return nil }
        func decode() throws -> PreviewFrame? {
            if !pictureOnlyFallback || fallbackURL != url {
                do {
                    if decoderURL != url || decoder == nil {
                        decoder = try HardwareFrames(url: url)
                        decoderURL = url
                    }
                    if let frame = try decoder?.frame(at: time, before: end, cancelled: cancelled) { return frame }
                    if !pictureOnlyFallback { return nil }
                    fallbackReason = "AVFoundation returned no picture at this position."
                } catch {
                    guard pictureOnlyFallback, !cancelled() else { throw error }
                    fallbackReason = error.localizedDescription
                }
                fallbackURL = url
            }
            let end = end ?? .infinity
            var frame = try fallback.perform(cancelled: cancelled) {
                let seekTime = time == end ? max(0, time - 0.001) : time
                try fallback.seek(url: url, to: seekTime)
                return try fallback.still(at: time, before: end, cancelled: cancelled)
            }
            // The same VideoToolbox decoder, reached through FFmpeg. Say so rather than switch silently.
            frame?.decoderNote = ffmpegDecoderNote(fallbackReason)
            return frame
        }
        if !scrubbing { return try decode() }
        return try recent.frame(url: url, at: time, before: end, decode: decode)
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
    private var triedNative = false
    private var fallback = FFPreviewReader(videoOnly: true)

    func image(source: UUID, url: URL, time: Double, size: CGSize, nearbyKeyframe: Bool,
               useNativeDecoder: Bool, request: ThumbnailRequest) -> CGImage? {
        guard !request.isCancelled else { return nil }
        if sourceID != source {
            native = nil
            triedNative = false
            fallback = FFPreviewReader(videoOnly: true)
            sourceID = source
        }
        if useNativeDecoder && !triedNative {
            triedNative = true
            native = try? HardwareFrames(url: url)
        }
        let deadline = ContinuousClock.now + .milliseconds(350)
        let stop = { request.isCancelled || (nearbyKeyframe && ContinuousClock.now >= deadline) }
        var frame = try? native?.frame(at: time, nearbyKeyframe: nearbyKeyframe, cancelled: stop)
        if frame == nil && !stop() {
            frame = try? fallback.perform(cancelled: stop) {
                try fallback.seek(url: url, to: time)
                return try fallback.still(at: time, nearbyKeyframe: nearbyKeyframe, cancelled: stop)
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
    /// Pictures the FFmpeg preview omitted in this playback pass, and why. Shown beside the picture.
    @Published private(set) var pictureNotice: String?
    /// Why the FFmpeg preview replaced AVFoundation for this sequence, when it did.
    private(set) var fallbackReason: String?
    var usesFallbackDecoder: Bool { fallback != nil }

    /// What the viewer shows about the preview, and which decoder plays it, for project_editor_state_read.
    var mcpState: [String: Any] {
        var state: [String: Any] = ["decoder": usesFallbackDecoder ? "ffmpeg" : "avfoundation",
                                    "blocking": hasBlockingIssue]
        state["issue"] = issue
        state["audio_warning"] = audioWarning
        state["picture_notice"] = pictureNotice
        state["picture_issue"] = programPictureIssue
        state["fallback_reason"] = usesFallbackDecoder ? fallbackReason : nil
        // A paused picture can come from FFmpeg even while AVFoundation plays (DecodeRequests).
        state["picture_decoder_note"] = frame?.decoderNote
        return state
    }

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
    private(set) var hasSoundtrack = false
    var readyForTransport: Bool {
        frame != nil || (canPlayWithoutPicture && fallback != nil)
            || ((hasSoundtrack || currentRange?.isAudioOnly == true) && (playable || fallback != nil))
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
    private var auditionPosition: (range: PreviewRange, time: Double)?
    let sourcePicture = CurrentValueSubject<SequenceSourcePicture?, Never>(nil)
    private var frame: PreviewFrame? {
        didSet {
            if sourcePicture.value != frame?.sourcePicture { sourcePicture.send(frame?.sourcePicture) }
        }
    }
    private let participantPreview = ParticipantPreview()
    var participantPreviewCells: AnyPublisher<ParticipantPreviewCells?, Never> { participantPreview.cells.eraseToAnyPublisher() }
    private var participantOutputTime: RationalTime?
    private var programStills: ProgramPreviewStills?
    private var programTransfer: String?
    private let stillPreview = ProgramStillPreview()
    private var sourceRangeIndices: [Int] = []
    private var showingProgramStill = false
    @Published private(set) var programPictureIssue: String?
    var displayedFrameTime: CMTime? { frame?.time }
    private var thumbnails = ThumbnailDecoder()
    private let tileWriter = FilmstripTileWriter()
    private let surfaces = NSHashTable<PreviewSurface>.weakObjects()

    init(reverseAudio: ReverseAudioPlayer? = nil, scrubAudioEngine: AVAudioEngine? = nil,
         preferences: EditorPreferences? = nil) {
        self.preferences = preferences
        self.reverseAudio = reverseAudio ?? ReverseAudioPlayer()
        scrubAudio = ScrubAudioPlayer(engine: scrubAudioEngine)
        guard let preferences else { return }
        // A new window starts at the Settings speed once. Each window then keeps its own.
        forwardSpeed = preferences.playbackSpeed
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

    func invalidateMedia(alsoFilmstrip: Bool) {
        participantPreview.invalidateMedia()
        _ = requests.next()
        requests.releaseDecoder()
        rendering = false
        stillPreview.cancel()
        showingProgramStill = false
        if alsoFilmstrip { thumbnails = ThumbnailDecoder() }
        clearPicture()
    }

    func update(_ sourceRanges: [PreviewRange], at time: Double, project: CutProject? = nil, reference: MediaInfo? = nil,
                soundtrack: PreviewRange? = nil, document: URL? = nil) {
        if participantPreview.configure(project: project, document: document) {
            stillPreview.cancel()
            clearPicture()
        }
        let programStills = ProgramPreviewStills(project: project, reference: reference)
        var ranges = sourceRanges
        var indices = Array(sourceRanges.indices)
        let hasSoundtrack = soundtrack != nil && programStills != nil
        if let soundtrack, let programStills {
            ranges = [soundtrack]
            let audibleDuration = soundtrack.exactEnd - soundtrack.exactStart
            if audibleDuration < programStills.duration {
                ranges.append(PreviewRange(url: soundtrack.url, exactStart: .zero,
                                           exactEnd: programStills.duration - audibleDuration,
                                           isAudioOnly: true, isSilentInsert: true))
            }
            indices = []
        } else if let project, case .stillSequence(let sequence) = project {
            let items = sequence.items
            var source = sourceRanges.makeIterator()
            var expanded: [PreviewRange] = []
            var sourceIndices: [Int] = []
            for item in items {
                switch item {
                case .source:
                    guard let range = source.next() else { continue }
                    sourceIndices.append(expanded.count)
                    expanded.append(range)
                case .still(let insert):
                    let assetURL = URL(fileURLWithPath: project.stillAssets.first { $0.id == insert.assetID }?.file ?? "/")
                    expanded.append(PreviewRange(url: assetURL, exactStart: .zero, exactEnd: insert.duration,
                                                 isAudioOnly: true, isSilentInsert: true))
                }
            }
            if sourceIndices.count == sourceRanges.count {
                ranges = expanded
                indices = sourceIndices
            }
        }
        self.sourceRangeIndices = indices
        pause()
        let transfer = project?.programColorPolicy?.transfer ?? programStills?.canvas.transfer
        if self.ranges == ranges, self.programStills == programStills, self.programTransfer == transfer,
           self.hasSoundtrack == hasSoundtrack {
            seek(to: time)
            return
        }

        loading?.cancel()
        stillPreview.cancel()
        showingProgramStill = false
        programPictureIssue = nil
        self.programStills = programStills
        self.programTransfer = transfer
        self.hasSoundtrack = hasSoundtrack
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
        pictureNotice = nil
        fallbackReason = nil
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
                if hasSoundtrack && (!audioEnd.isFinite || audioEnd <= 0) {
                    throw PreviewFailure("macOS could not read the soundtrack’s selected audio range.")
                }
                if audioEnd.isFinite && audioEnd > 0 {
                    self.audioEnd = audioEnd
                    let item = AVPlayerItem(asset: composition)
                    let player = self.audioPlayer ?? AVPlayer()
                    player.volume = previewAudioGain(volume: self.volume, muted: self.isMuted)
                    MutedLaunch.mute(player)
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

    static func makeAudioComposition(_ ranges: [PreviewRange]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        var tracks: [AVMutableCompositionTrack] = []
        var offset = CMTime.zero
        var assets: [URL: AVURLAsset] = [:]
        for range in ranges {
            try Task.checkCancellation()
            if range.isSilentInsert {
                let end = offset + previewTime(range.exactEnd - range.exactStart)
                for target in tracks where target.timeRange.end < end {
                    target.insertEmptyTimeRange(CMTimeRange(start: target.timeRange.end, end: end))
                }
                offset = end
                continue
            }
            let asset = assets[range.url] ?? AVURLAsset(url: range.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            assets[range.url] = asset
            var audio = try await asset.loadTracks(withMediaType: .audio)
            let origin: CMTime
            if let explicitOrigin = range.assetClockOrigin {
                origin = previewTime(explicitOrigin)
            } else if range.isAudioOnly {
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
                // AVFoundation can omit a track it cannot decode. MOV track IDs
                // still identify the requested stream if its ordinal shifts.
                let selected: AVAssetTrack?
                if let ids = range.audioTrackIDs {
                    selected = ids.indices.contains(index) ? audio.first { $0.trackID == ids[index] } : nil
                } else {
                    selected = audio.indices.contains(index) ? audio[index] : nil
                }
                guard let selected else {
                    throw PreviewFailure("macOS could not read the selected audio track in \(range.url.lastPathComponent).")
                }
                audio = [selected]
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
        fallbackReason = nativeIssue ?? (ranges.contains(where: \.usesMP3GaplessClock)
            ? "Only the FFmpeg preview reads MP3 gapless timing." : nil)
        let alternative = WebSequencePlayback(ranges: ranges, screen: { [weak self] in self?.playbackScreen }, onFrame: { [weak self] frame in
            guard let self, self.sequenceGeneration == generation,
                  self.auditionPosition != nil || !self.showingProgramStill else { return }
            if self.issue != nil { self.issue = nil }
            self.programPictureIssue = nil
            self.issueAllowsRetry = false
            self.canPlayWithoutPicture = false
            var tagged = frame.tagged(transfer: self.auditionPosition == nil ? self.programTransfer : nil)
            tagged.decoderNote = tagged.decoderNote ?? ffmpegDecoderNote(self.fallbackReason)
            self.frame = tagged
            let clock = self.auditionPosition == nil ? (tagged.timelinePictureTime ?? timelineRationalTime(self.time)) : nil
            self.displayParticipantPicture(tagged, at: clock)
        }, onTime: { [weak self] position in
            guard let self, self.sequenceGeneration == generation else { return }
            let time = min(max(0, position), self.duration)
            if self.time != time { self.time = time }
            if self.auditionPosition == nil {
                if self.programStills != nil || self.currentRange?.isAudioOnly == true {
                    self.renderTimeline(immediate: !self.isPlaying || time == self.duration)
                } else if let reason = self.currentRange?.unavailablePicture {
                    self.reportPictureFailure(reason, independent: true)
                }
            }
            if self.playbackRate > 0 && self.time >= self.duration {
                self.pause()
            }
        }, onIssue: { [weak self] error in
            guard let self, self.sequenceGeneration == generation else { return }
            self.clearPicture()
            self.canPlayWithoutPicture = WebSequencePlayback.omittedPictures.contains(error)
            self.issueAllowsRetry = error == WebSequencePlayback.undecodableAudio || self.canPlayWithoutPicture
            self.issue = nativeIssue.map { "\(error) \($0)" } ?? error
            self.pause()
        }, onAudioWarning: { [weak self] message in
            guard let self, self.sequenceGeneration == generation else { return }
            self.audioWarning = message
        }, onGap: { [weak self] in
            guard let self, self.sequenceGeneration == generation else { return }
            if !self.showingProgramStill { self.clearPicture() }
            self.canPlayWithoutPicture = true
            self.issue = nil
            self.issueAllowsRetry = false
        }, onPictureNotice: { [weak self] message in
            guard let self, self.sequenceGeneration == generation else { return }
            self.pictureNotice = message
        }, separatesPicture: programStills != nil)
        alternative.setGain(isMuted ? 0 : volume)
        fallback = alternative
        if let auditionPosition {
            if !auditionPosition.range.isAudioOnly && auditionPosition.range.unavailablePicture == nil {
                displayAuditionPicture(auditionPosition.range, at: auditionPosition.time)
            }
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
        if playbackRate != 0 { playbackRate = 0 }
    }

    func audition(_ range: PreviewRange, at sourceTime: Double, sourceDuration: Double? = nil, reverse: Bool = false) {
        if !range.isAudioOnly || auditionPosition?.range != range || isPlaying { pause() }
        if showingProgramStill {
            showingProgramStill = false
            stillPreview.cancel()
            programPictureIssue = nil
            clearPicture()
        }
        auditionPosition = (range, sourceTime)
        if let reason = range.unavailablePicture {
            cancelPictureRequest()
            reportPictureFailure(reason, independent: true)
            return
        }
        if range.isAudioOnly {
            clearAudioOnlyPicture()
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
        displayAuditionPicture(range, at: sourceTime)
    }

    private func displayAuditionPicture(_ range: PreviewRange, at sourceTime: Double) {
        if let fallback, programStills == nil {
            fallback.audition(url: range.url, at: sourceTime, transfer: range.programTransfer)
        } else {
            render(url: range.url, time: sourceTime, transfer: range.programTransfer)
        }
    }

    func scrub(to position: Double, rangeIndex sourceIndex: Int, sourceFrame: Double) {
        guard sourceRangeIndices.indices.contains(sourceIndex) else { return }
        scrub(to: position, using: sourceRangeIndices[sourceIndex], sourceFrame: sourceFrame)
    }

    func scrubSoundtrack(to position: Double) {
        guard hasSoundtrack, !offsets.isEmpty else { return }
        let index = max(0, offsets.lowerBound { $0 > position } - 1)
        scrub(to: position, using: index, sourceFrame: 0)
    }

    private func scrub(to position: Double, using rangeIndex: Int, sourceFrame: Double) {
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
        if !showProgramStill(at: target) {
            if let reason = range.unavailablePicture {
                cancelPictureRequest()
                reportPictureFailure(reason, independent: true)
            } else if range.isAudioOnly {
                clearAudioOnlyPicture()
            } else if scrubPicture?.source != range.url || scrubPicture?.pts != sourceFrame || scrubPicture?.end != range.end {
                scrubPicture = (range.url, sourceFrame, range.end)
                if let fallback, programStills == nil {
                    fallback.audition(url: range.url, at: sourceFrame, before: range.end, transfer: range.programTransfer)
                } else {
                    render(url: range.url, time: sourceFrame, before: range.end,
                           transfer: programTransfer ?? range.programTransfer, cameraTransfer: range.programTransfer ?? "unknown", outputTime: target)
                }
            }
        }
        guard scrubSoundEnabled, !isMuted, volume > 0, !range.isSilentInsert else { return }
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
            } else if let fallback, programStills == nil, currentRange?.isAudioOnly == false, currentRange?.unavailablePicture == nil {
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

    private func programStill(at position: Double) -> ProgramPreviewStills.Picture? {
        guard let programStills else { return nil }
        return programStills.picture(at: position)
    }

    @discardableResult
    private func showProgramStill(at position: Double) -> Bool {
        guard let programStills, let still = programStill(at: position) else {
            if showingProgramStill {
                showingProgramStill = false
                stillPreview.cancel()
                programPictureIssue = nil
                scrubPicture = nil
                clearPicture()
            }
            return false
        }
        if !showingProgramStill {
            showingProgramStill = true
            _ = requests.next()
            rendering = false
        }
        stillPreview.show(still, canvas: programStills.canvas, onPending: {
            programPictureIssue = nil
            clearPicture()
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let frame):
                self.programPictureIssue = nil
                self.frame = frame
                self.participantPreview.display(frame, at: timelineRationalTime(self.time),
                                                sourceID: nil, sourceTime: nil, programStill: true,
                                                on: self.surfaces.allObjects) { [weak self] in self?.surfaces.allObjects ?? [] }
            case .failure(let error):
                self.clearPicture()
                self.programPictureIssue = error.localizedDescription
                self.surfaces.allObjects.forEach { $0.unavailable(error.localizedDescription) }
            }
        }
        return true
    }

    private var currentRangeIndex: Int? {
        guard !offsets.isEmpty else { return nil }
        return max(0, offsets.lowerBound { $0 > time } - 1)
    }

    private var currentRange: PreviewRange? {
        currentRangeIndex.map { ranges[$0] }
    }

    private func renderTimeline(immediate: Bool) {
        guard !showProgramStill(at: time), let index = currentRangeIndex else { return }
        let range = ranges[index]
        if let reason = range.unavailablePicture {
            cancelPictureRequest()
            reportPictureFailure(reason, independent: true)
            return
        }
        if range.isAudioOnly {
            clearAudioOnlyPicture()
            return
        }
        guard immediate || !rendering else { return }
        let sourceTime = time == duration ? range.end
            : min(range.end, range.start + (time - offsets[index]))
        render(url: range.url, time: sourceTime, before: range.end, scrubbing: immediate,
               transfer: programTransfer ?? range.programTransfer, cameraTransfer: range.programTransfer ?? "unknown", outputTime: time)
    }

    private func cancelPictureRequest() {
        if rendering {
            _ = requests.next()
            rendering = false
        }
        fallback?.cancelStill()
        scrubPicture = nil
    }

    private func clearAudioOnlyPicture() {
        cancelPictureRequest()
        if frame != nil || programPictureIssue != nil {
            programPictureIssue = nil
            clearPicture()
        }
    }

    private func render(url: URL, time: Double, before end: Double? = nil, scrubbing: Bool = true,
                        transfer: String? = nil, cameraTransfer: String? = nil, outputTime: Double? = nil) {
        let serial = requests.next()
        rendering = true
        let requests = requests
        let independentPicture = programStills != nil
        let programTime = outputTime.flatMap(timelineRationalTime)
        requests.pictureWork.submit(on: requests.queue) { [weak self] in
            guard requests.current(serial) else { return }
            let result = Result {
                try requests.frame(url: url, time: time, before: end, scrubbing: scrubbing,
                                   pictureOnlyFallback: independentPicture) { !requests.current(serial) }
            }
            Task { @MainActor in
                guard let self, requests.current(serial) else { return }
                self.rendering = false
                switch result {
                case .success(let decoded?):
                    let frame = decoded.tagged(transfer: transfer, cameraTransfer: cameraTransfer)
                    if self.programPictureIssue != nil { self.programPictureIssue = nil }
                    if self.displayedURL != url || self.frame?.time != frame.time
                        || self.frame?.buffer !== frame.buffer || self.frame?.programTransfer != frame.programTransfer
                        || self.frame?.cameraTransfer != frame.cameraTransfer {
                        self.displayedURL = url
                        self.frame = frame
                        self.displayParticipantPicture(frame, at: programTime)
                    } else if self.participantPreview.enabled && self.participantOutputTime != programTime {
                        self.displayParticipantPicture(frame, at: programTime)
                    }
                case .success(nil):
                    self.reportPictureFailure("The source produced no picture at this position.", independent: independentPicture)
                case .failure(let error):
                    self.reportPictureFailure(error.localizedDescription, independent: independentPicture)
                }
            }
        }
    }

    private func reportPictureFailure(_ message: String, independent: Bool) {
        if independent {
            guard programPictureIssue != message else { return }
            clearPicture()
            programPictureIssue = message
            surfaces.allObjects.forEach { $0.unavailable(message) }
        } else {
            startFallback(nativeIssue: message)
        }
    }

    func thumbnail(source: UUID, url: URL, at time: Double, size: CGSize,
                   saved: (AnalysisSidecar, FilmstripTileKey)? = nil,
                   nearbyKeyframe: Bool = false,
                   useNativeDecoder: Bool = true,
                   cacheEnabled: @escaping @Sendable () -> Bool = { true },
                   preserveAlpha: Bool = false, onRender: (CGImage) -> Void = { _ in }) async -> CGImage? {
        guard !Task.isCancelled, size.width > 0, size.height > 0 else { return nil }
        let request = ThumbnailRequest()
        let thumbnails = thumbnails
        let tileWriter = tileWriter
        let result: (image: CGImage?, restored: Bool) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                thumbnails.queue.async(qos: nearbyKeyframe ? .userInitiated : .utility, flags: .enforceQoS) {
                    let skipCache: @Sendable () -> Bool = { request.isCancelled || !cacheEnabled() }
                    if let (sidecar, key) = saved, let image = key.image(in: sidecar, cancelled: skipCache), !skipCache() {
                        continuation.resume(returning: (image, true))
                        return
                    }
                    let image = thumbnails.image(source: source, url: url, time: time, size: size,
                                                 nearbyKeyframe: nearbyKeyframe, useNativeDecoder: useNativeDecoder, request: request)
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
        surface.otherMonitorStatus = { [weak self] in
            self?.surfaces.allObjects.first(where: \.isVideoMonitor)?.presentationDescription
        }
        if let frame {
            participantPreview.attach(surface, frame: frame)
        } else if let programPictureIssue { surface.unavailable(programPictureIssue) }
    }

    func setParticipantSource(_ source: Bool) {
        guard participantPreview.source != source else { return }
        participantPreview.source = source
        guard let frame else { return }
        if !source, participantPreview.enabled {
            for surface in surfaces.allObjects where !surface.isVideoMonitor { surface.clear() }
        }
        if showingProgramStill && auditionPosition == nil {
            participantPreview.display(frame, at: timelineRationalTime(time), sourceID: nil, sourceTime: nil,
                                       programStill: true, on: surfaces.allObjects) { [weak self] in self?.surfaces.allObjects ?? [] }
        } else {
            displayParticipantPicture(frame, at: participantOutputTime)
        }
    }

    private func displayParticipantPicture(_ frame: PreviewFrame, at time: RationalTime?) {
        participantOutputTime = time
        participantPreview.display(frame, at: time, sourceID: frame.sourcePicture?.url.path,
                                   sourceTime: frame.sourcePicture?.time, on: surfaces.allObjects) { [weak self] in
            self?.surfaces.allObjects ?? []
        }
    }

    private func clearPicture() {
        participantPreview.clear()
        participantOutputTime = nil
        displayedURL = nil
        frame = nil
        surfaces.allObjects.forEach { $0.clear() }
    }

    fileprivate func detach(_ surface: PreviewSurface) {
        surfaces.remove(surface)
    }
}

struct PreviewView: NSViewRepresentable {
    let preview: SequencePreview
    /// Force SDR and clean feed. Nil keeps the factory values for this surface.
    let preferences: EditorPreferences?
    var isVideoMonitor = false

    func makeNSView(context: Context) -> PreviewSurface {
        let surface = PreviewSurface(frame: .zero)
        surface.setMonitor(isVideoMonitor, preferences: preferences)
        surface.windowChanged = { [weak preview] surface in
            if surface.window == nil { preview?.detach(surface) }
            else { preview?.attach(surface) }
        }
        return surface
    }

    func updateNSView(_ nsView: PreviewSurface, context: Context) {}
}
