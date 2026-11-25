import AVFoundation
import Combine
import MPCutCore
import SwiftUI

struct MulticamPicturePosition: Equatable, Sendable {
    let source: String
    let url: URL
    let identity: SourceIdentity
    let origin: RationalTime
    let multicamClockOffset: RationalTime
    let frameTime: RationalTime
    let spanIndex: Int
    var provisional = false

    static func at(_ time: RationalTime, in plan: MulticamPlan, media: [String: MediaInfo]) -> Self? {
        let parkedAtEnd = time == plan.duration
        let index = plan.picture.lowerBound { $0.output.to > time } - (parkedAtEnd ? 1 : 0)
        guard plan.picture.indices.contains(index) else { return nil }
        let span = plan.picture[index]
        guard time >= span.output.from, parkedAtEnd ? time == span.output.to : time < span.output.to,
              let source = media[span.source],
              let relative = try? time.subtracting(span.output.from),
              let local = try? span.input.from.adding(relative) else { return nil }
        return at(local, source: span.source, media: source, spanIndex: index, exclusiveEnd: parkedAtEnd)
    }

    static func at(_ time: RationalTime, source: String, media: MediaInfo, spanIndex: Int,
                   exclusiveEnd: Bool = false) -> Self? {
        guard time >= .zero, exclusiveEnd ? time <= media.duration : time < media.duration else { return nil }
        if !media.hasFullEditIndex, let video = media.videoStream {
            let start = max(.zero, video.start)
            guard time >= start else { return nil }
            if video.duration > .zero, let end = try? video.start.adding(video.duration) {
                guard exclusiveEnd ? time <= end : time < end else { return nil }
            }
            let rate = video.frameRate > .zero ? video.frameRate : RationalTime(numerator: 30)
            let step = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
            // Count frames in exact arithmetic. In floating point 1.16 s × 25 fps
            // is just under 29, which would select the preceding picture.
            let exact = (try? time.subtracting(start)).flatMap { try? $0.multiplied(by: rate) }
                .map { $0.numerator / $0.denominator }
            guard let frame = exact ?? Int64(exactly: (max(0, time.seconds - start.seconds) * rate.seconds).rounded(.down)),
                  let delta = try? step.multiplied(by: RationalTime(numerator: frame)),
                  var requested = try? start.adding(delta) else { return nil }
            if exclusiveEnd, requested >= time {
                guard requested > start, let prior = try? requested.subtracting(step) else { return nil }
                requested = prior
            }
            return Self(source: source, url: media.url, identity: media.identity,
                        origin: media.origin, multicamClockOffset: media.multicamClockOffset,
                        frameTime: requested, spanIndex: spanIndex, provisional: true)
        }
        let index = media.frames.lowerBound { exclusiveEnd ? $0.time >= time : $0.time > time } - 1
        guard index >= 0, index == 0 || media.frames[index - 1].time != media.frames[index].time else { return nil }
        let frame = media.frames[index]
        guard let end = try? frame.time.adding(frame.duration),
              exclusiveEnd ? time <= end : time < end else { return nil }
        return Self(source: source, url: media.url, identity: media.identity,
                    origin: media.origin, multicamClockOffset: media.multicamClockOffset,
                    frameTime: frame.time, spanIndex: spanIndex)
    }

    func following(in plan: MulticamPlan, media: [String: MediaInfo]) -> (picture: Self, startsAt: RationalTime)? {
        guard plan.picture.indices.contains(spanIndex), let sourceMedia = media[source] else { return nil }
        let span = plan.picture[spanIndex]
        let nextFrame = sourceMedia.frames.lowerBound { $0.time > frameTime }
        if sourceMedia.frames.indices.contains(nextFrame) {
            let next = sourceMedia.frames[nextFrame].time
            if next < span.input.to, let elapsed = try? next.subtracting(span.input.from),
               let output = try? span.output.from.adding(elapsed),
               let picture = Self.at(next, source: source, media: sourceMedia, spanIndex: spanIndex) {
                return (picture, output)
            }
        }
        let nextSpan = spanIndex + 1
        guard plan.picture.indices.contains(nextSpan) else { return nil }
        let start = plan.picture[nextSpan].output.from
        return Self.at(start, in: plan, media: media).map { ($0, start) }
    }
}

struct MulticamPreviewAudioSpan: Equatable, Sendable {
    let source: String
    let url: URL
    let identity: SourceIdentity
    let ordinal: Int
    let origin: RationalTime
    let input: Range<RationalTime>
    let output: Range<RationalTime>
    let channels: Int
    let sampleRate: Int
    let sourceExtent: Range<RationalTime>
    let timestampTick: CMTime
    let channelLayout: String
    let presentationTrackID: CMPersistentTrackID?

    init?(span: MulticamSpan, media: [String: MediaInfo]) {
        guard let source = media[span.source], let stream = span.stream,
              let track = source.audio.first(where: { $0.stream.index == stream }),
              let ordinal = source.streams.filter({ $0.kind == "audio" }).firstIndex(where: { $0.index == stream }),
              track.start <= track.end
        else { return nil }
        guard span.input.from < span.input.to, span.output.from < span.output.to else { return nil }
        self.source = span.source
        url = source.url
        identity = source.identity
        origin = source.origin
        self.ordinal = ordinal
        input = span.input.from..<span.input.to
        output = span.output.from..<span.output.to
        channels = track.stream.channels
        sampleRate = track.stream.sampleRate
        sourceExtent = track.start..<track.end
        channelLayout = track.stream.canonicalChannelLayout
        presentationTrackID = source.requiresPresentationAudioAnalysis(stream: stream) ? track.stream.trackID : nil
        timestampTick = presentationTrackID == nil ? previewTime(track.stream.timeBase) : .zero
    }

    /// Convert both clocks independently using the same sample-boundary rounding
    /// as rendered downmix. A kept sub-sample edit uses its nearest source sample.
    func mixerSlice(from start: RationalTime, to end: RationalTime?) throws -> (span: Self, sourceSamples: Int64)? {
        let outputStart = max(start, output.lowerBound)
        let outputEnd = min(end ?? output.upperBound, output.upperBound)
        let outputRate = MulticamProgramMixer.sampleRate
        let firstOutput = try outputStart.roundedToSamples(outputRate)
        let lastOutput = try outputEnd.roundedToSamples(outputRate)
        guard firstOutput < lastOutput, sampleRate > 0 else { return nil }

        let firstSource = try origin.adding(sourceTime(at: outputStart)).roundedToSamples(sampleRate)
        let lastSource = try origin.adding(sourceTime(at: outputEnd)).roundedToSamples(sampleRate)
        let upperSource = try origin.adding(sourceExtent.upperBound).roundedToSamples(sampleRate)
        let lowerSource = try origin.adding(sourceExtent.lowerBound).roundedToSamples(sampleRate)
        guard lowerSource < upperSource else { return nil }
        let nearest = min(max(firstSource, lowerSource), upperSource - 1)
        let sourceStart = try RationalTime(numerator: nearest, denominator: Int64(sampleRate)).subtracting(origin)
        let sourceEndSample = max(nearest + 1, min(lastSource, upperSource))
        let sourceEnd = try RationalTime(numerator: sourceEndSample, denominator: Int64(sampleRate)).subtracting(origin)
        let first = RationalTime(numerator: firstOutput, denominator: Int64(outputRate))
        let last = RationalTime(numerator: lastOutput, denominator: Int64(outputRate))
        return (Self(copying: self, input: sourceStart..<sourceEnd, output: first..<last), sourceEndSample - nearest)
    }

    private init(copying span: Self, input: Range<RationalTime>, output: Range<RationalTime>) {
        source = span.source
        url = span.url
        identity = span.identity
        ordinal = span.ordinal
        origin = span.origin
        self.input = input
        self.output = output
        channels = span.channels
        sampleRate = span.sampleRate
        sourceExtent = span.sourceExtent
        timestampTick = span.timestampTick
        channelLayout = span.channelLayout
        presentationTrackID = span.presentationTrackID
    }

    var reverseRegion: ReverseAudioTimeline.Region {
        let start = ReverseAudioTimeline.frame(output.lowerBound.seconds)
        let end = ReverseAudioTimeline.frame(output.upperBound.seconds)
        return .init(url: url, output: start..<end, source: input.lowerBound.seconds..<input.upperBound.seconds,
                     origin: origin, track: ordinal, presentationTrackID: presentationTrackID)
    }

    func sourceTime(at time: RationalTime) -> RationalTime {
        guard time > output.lowerBound,
              let elapsed = try? time.subtracting(output.lowerBound),
              let sourceTime = try? input.lowerBound.adding(elapsed) else { return input.lowerBound }
        return min(sourceTime, input.upperBound)
    }
}

enum MulticamDecodeError: LocalizedError {
    case picture(URL)
    case audio(URL)

    var errorDescription: String? {
        switch self {
        case .picture(let url): return "Could not decode the indexed picture in \(url.lastPathComponent)."
        case .audio(let url): return "Could not decode the selected audio in \(url.lastPathComponent)."
        }
    }
}

private final class MulticamDecodeQueue: @unchecked Sendable {
    let queue: DispatchQueue
    private let lock = NSLock()
    private var generation = 0

    init(_ name: String) {
        queue = DispatchQueue(label: "mpcut.multicam.\(name)", qos: .userInitiated, autoreleaseFrequency: .workItem)
    }

    func invalidate() -> Int { lock.withLock { generation += 1; return generation } }
    func isCurrent(_ request: Int) -> Bool { lock.withLock { generation == request } }
}

private struct MulticamPictureSource: Hashable, Sendable {
    let url: URL
    let identity: SourceIdentity
}

private final class MulticamPictureDecoder: @unchecked Sendable {
    private struct NativeEntry {
        let source: MulticamPictureSource
        let decoder: HardwareFrames
    }

    let requests = MulticamDecodeQueue("picture")
    let pictureWork = LatestPreviewWork()
    private var reader = FFPreviewReader(videoOnly: true)
    private var source: MulticamPictureSource?
    private var native: HardwareFrames?
    /// Why AVFoundation is not decoding the current camera, which FFmpeg then decodes (ffmpegDecoderNote).
    private var nativeIssue: String?
    private var parked: [NativeEntry] = []
    private var previous: MulticamPicturePosition?
    private var frame: PreviewFrame?

    func invalidate(_ urls: Set<URL>) {
        pictureWork.enqueueMaintenance(on: requests.queue) {
            self.parked.removeAll { urls.contains($0.source.url) }
            if let source = self.source, urls.contains(source.url) {
                self.source = nil
                self.native = nil
                self.reader = FFPreviewReader(videoOnly: true)
                self.previous = nil
                self.frame = nil
            }
        }
    }

    func retainSources(_ sources: Set<MulticamPictureSource>) {
        pictureWork.enqueueMaintenance(on: requests.queue) {
            self.parked.removeAll { !sources.contains($0.source) }
            if let source = self.source, !sources.contains(source) {
                self.source = nil
                self.native = nil
                self.reader = FFPreviewReader(videoOnly: true)
                self.previous = nil
                self.frame = nil
            }
        }
    }

    private func switchSource(to target: MulticamPictureSource) {
        let prior = source.flatMap { source in native.map { NativeEntry(source: source, decoder: $0) } }
        parked.removeAll { $0.source.url == target.url && $0.source != target }
        let reuse = parked.firstIndex(where: { $0.source == target }).map { parked.remove(at: $0).decoder }
        // Keep the most recent camera's session if it fits. Other entries
        // retain the AVFoundation asset and track metadata only.
        parked.last?.decoder.park(keepingSession: false)
        if let prior, prior.source.url != target.url {
            prior.decoder.park(keepingSession: true)
            parked.append(prior)
            if parked.count > 3 { parked.removeFirst() }
        }
        nativeIssue = nil
        if let reuse {
            native = reuse
        } else {
            do { native = try HardwareFrames(url: target.url) } catch {
                native = nil
                nativeIssue = error.localizedDescription
            }
        }
        source = target
        reader = FFPreviewReader(videoOnly: true)
        previous = nil
        frame = nil
    }

    func decode(_ target: MulticamPicturePosition, request: Int) throws -> PreviewFrame? {
        func cancelled() -> Bool { !requests.isCurrent(request) }
        if target == previous, let frame { return frame }
        let key = MulticamPictureSource(url: target.url, identity: target.identity)
        if source != key {
            switchSource(to: key)
        }
        if let native {
            // HardwareFrames measures from the first presentation edit.
            // FFmpeg below uses the origin of the multicam index instead.
            func picture() throws -> PreviewFrame? {
                let time = try target.frameTime.subtracting(target.multicamClockOffset)
                return try target.provisional ? native.frame(at: time.seconds, cancelled: cancelled)
                    : native.indexedFrame(at: time, cancelled: cancelled)
            }
            // A cancelled request can leave the error of a damaged picture for the next request.
            // The decoder starts again at the keyframe after it reports an error.
            var decoded: PreviewFrame?
            do { decoded = try picture() } catch {
                nativeIssue = error.localizedDescription
                decoded = try? picture()
            }
            guard !cancelled() else { return nil }
            if let decoded {
                nativeIssue = nil
                frame = decoded
                previous = target
                return decoded
            }
            if nativeIssue == nil { nativeIssue = "AVFoundation returned no picture at this position." }
            previous = nil
        }
        let nativeRefused = native != nil
        let prior = previous
        previous = nil
        let mustSeek = prior.map {
            $0.url != target.url || $0.origin != target.origin || $0.spanIndex != target.spanIndex
                || $0.multicamClockOffset != target.multicamClockOffset
                || $0.provisional != target.provisional || target.provisional
                || target.frameTime <= $0.frameTime || target.frameTime.seconds - $0.frameTime.seconds > 0.5
        } ?? true
        var decoded = try reader.perform(cancelled: cancelled) {
            if mustSeek {
                try reader.seek(url: target.url, to: max(0, target.frameTime.seconds), audioOrigin: target.origin)
            }
            return try target.provisional ? reader.still(at: target.frameTime.seconds, cancelled: cancelled)
                : reader.indexedFrame(at: previewTime(target.frameTime), cancelled: cancelled)
        }
        guard !cancelled() else { return nil }
        guard decoded != nil else { throw MulticamDecodeError.picture(target.url) }
        // FFmpeg reaches the same VideoToolbox decoder. The viewer's status names the switch and its reason.
        decoded?.decoderNote = ffmpegDecoderNote(nativeIssue)
        // Both decoders refuse a damaged picture. A picture that only the native decoder
        // refuses shows that it cannot read this source.
        if nativeRefused { native = nil }
        previous = target
        frame = decoded
        return decoded
    }
}

/// Serial audio reader. A mapped span is opened only at a seek or a real sound edit.
final class MulticamPreviewAudioDecoder: @unchecked Sendable {
    fileprivate let requests = MulticamDecodeQueue("audio")
    private let preserveChannels: Bool
    private var fallback: FFPreviewReader
    private var program: MulticamProgramAudioReader?

    init(preserveChannels: Bool = false) {
        self.preserveChannels = preserveChannels
        fallback = FFPreviewReader(audioOnly: true, preservesSurround: true, preservesAudioChannels: preserveChannels)
    }

    func read(program timeline: MulticamMixedAudioTimeline, from start: RationalTime, open: Bool,
              cancelled: @escaping () -> Bool) throws -> MulticamProgramAudioBatch {
        if open { program = try MulticamProgramAudioReader(timeline: timeline, from: start) }
        guard let program else { return MulticamProgramAudioBatch(end: true) }
        return try program.read(cancelled: cancelled)
    }
    private var identity: SourceIdentity?
    private var native: AVAssetReader?
    private var nativeOutput: AVAssetReaderOutput?

    func read(span: MulticamPreviewAudioSpan, from start: RationalTime, open: Bool,
              cancelled: @escaping () -> Bool) throws -> FFPreviewBatch {
        if open {
            if identity != span.identity {
                identity = span.identity
                fallback = FFPreviewReader(audioOnly: true, preservesSurround: true, preservesAudioChannels: preserveChannels)
            }
            native?.cancelReading()
            native = nil
            nativeOutput = nil
            if let trackID = span.presentationTrackID {
                try openPresentationReader(span: span, trackID: trackID, from: start)
            }
        }
        let offset = previewTime(span.output.lowerBound) - previewTime(span.input.lowerBound)
        let end = span.input.upperBound.seconds
        if let native, let nativeOutput {
            var batch = FFPreviewBatch()
            let origin = previewTime(span.origin)
            // AVFoundation applies the MOV edit list, including empty edits,
            // before these timestamps are placed on the output clock.
            for _ in 0..<4 where !cancelled() {
                guard let sample = nativeOutput.copyNextSampleBuffer() else {
                    if native.status == .failed {
                        throw native.error ?? MulticamDecodeError.audio(span.url)
                    }
                    batch.end = true
                    break
                }
                if let mapped = FFPreviewReader.timelineAudio(
                    sample, target: start.seconds + origin.seconds, end: end + origin.seconds,
                    offset: offset - origin
                ) {
                    batch.audio.append(mapped)
                }
            }
            return batch
        }

        return try fallback.perform(cancelled: cancelled) {
            if open {
                try fallback.seek(url: span.url, to: start.seconds, withAudio: true,
                                  audioOrigin: span.origin, audioTrack: span.ordinal)
            }
            return try fallback.batch(from: start.seconds, end: end, timelineOffset: offset,
                                      first: false, cancelled: cancelled, audioLimit: 4)
        }
    }

    private func openPresentationReader(span: MulticamPreviewAudioSpan, trackID: CMPersistentTrackID,
                                        from start: RationalTime) throws {
        let asset = AVURLAsset(url: span.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = asset.track(withTrackID: trackID), track.mediaType == .audio else {
            throw MulticamDecodeError.audio(span.url)
        }
        let reader = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false
        ]
        let output: AVAssetReaderOutput
        if preserveChannels || span.channels > 2 {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        } else {
            settings[AVNumberOfChannelsKey] = 2
            output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        }
        let origin = previewTime(span.origin)
        reader.timeRange = CMTimeRange(start: previewTime(start) + origin,
                                       end: previewTime(span.input.upperBound) + origin)
        guard reader.canAdd(output) else { throw MulticamDecodeError.audio(span.url) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MulticamDecodeError.audio(span.url) }
        native = reader
        nativeOutput = output
    }
}

@MainActor
final class MulticamPreview: ObservableObject {
    private static let audioLookahead = 0.65
    @Published private(set) var time: RationalTime = .zero
    @Published private(set) var duration: RationalTime = .zero
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
            if !scrubSoundEnabled { endScrub() }
            if let preferences, preferences.scrubSoundEnabled != scrubSoundEnabled {
                preferences.scrubSoundEnabled = scrubSoundEnabled
            }
        }
    }
    private let preferences: EditorPreferences?
    private var preferenceObserver: AnyCancellable?
    @Published private(set) var issue: String?
    @Published private(set) var pictureIssue: String?
    @Published private(set) var audioIssue: String?
    @Published private(set) var picture: MulticamPicturePosition?
    var displayedFrameTime: CMTime? { frame?.time }

    private var pictureDecoder = MulticamPictureDecoder()
    private var audioDecoder = MulticamPreviewAudioDecoder()
    private var clock: AVSampleBufferRenderSynchronizer?
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var audioFlushObserver: AnyCancellable?
    private let scrubAudio = ScrubAudioPlayer()
    private let reverseAudio: ReverseAudioPlayer
    private var reverseAnchor: RationalTime = .zero
    private var reverseStarted: ContinuousClock.Instant = .now
    private var audio: [MulticamPreviewAudioSpan] = []
    private var mixedAudio: MulticamMixedAudioTimeline?
    private var mixStart: RationalTime?
    private var mixEnd = false
    private var plan: MulticamPlan?
    private var programStills: ProgramPreviewStills?
    private var programTransfer: String?
    private var auditionTransfer: String?
    private let stillPreview = ProgramStillPreview()
    private var showingProgramStill = false
    private var media: [String: MediaInfo] = [:]
    private var ticker: PreviewDisplayTicker?
    private var frame: PreviewFrame?
    private let surfaces = NSHashTable<PreviewSurface>.weakObjects()
    private let participantPreview = ParticipantPreview()
    var participantPreviewCells: AnyPublisher<ParticipantPreviewCells?, Never> { participantPreview.cells.eraseToAnyPublisher() }
    private var desiredPicture: MulticamPicturePosition?
    private var decodingPicture: MulticamPicturePosition?
    private var failedPicture: MulticamPicturePosition?
    private var prefetchedPicture: (position: MulticamPicturePosition, frame: PreviewFrame)?
    private(set) var isAuditioning = false
    private var scrubSpanIndex: Int?
    private var audioIndex = 0
    private var audioStart: RationalTime = .zero
    private var openAudio = true
    private var decodingAudio = false
    private var queuedAudio: [CMSampleBuffer] = []
    private var audioHasPreroll = false

    init(reverseAudioEngine: AVAudioEngine? = nil, preferences: EditorPreferences? = nil) {
        reverseAudio = ReverseAudioPlayer(engine: reverseAudioEngine)
        self.preferences = preferences
        if let preferences {
            volume = preferences.volume
            isMuted = preferences.isMuted
            scrubSoundEnabled = preferences.scrubSoundEnabled
            // A new window starts at the Settings speed. A later change in Settings leaves this window's speed alone.
            forwardSpeed = preferences.playbackSpeed
            updateGain()
            preferenceObserver = preferences.observeChanges { [weak self, weak preferences] change in
                guard let self, let preferences else { return }
                switch change {
                case .volume where self.volume != preferences.volume: self.volume = preferences.volume
                case .isMuted where self.isMuted != preferences.isMuted: self.isMuted = preferences.isMuted
                case .scrubSoundEnabled where self.scrubSoundEnabled != preferences.scrubSoundEnabled:
                    self.scrubSoundEnabled = preferences.scrubSoundEnabled
                default: break
                }
            }
        }
    }

    private func prepareForwardPlayback() {
        guard clock == nil else { return }
        let clock = AVSampleBufferRenderSynchronizer()
        let renderer = AVSampleBufferAudioRenderer()
        renderer.volume = previewAudioGain(volume: volume, muted: isMuted)
        MutedLaunch.mute(renderer)
        clock.addRenderer(renderer)
        clock.delaysRateChangeUntilHasSufficientMediaData = false
        self.clock = clock
        audioRenderer = renderer
        audioFlushObserver = NotificationCenter.default
            .publisher(for: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer)
            .sink { [weak self, weak renderer] _ in
                Task { @MainActor in
                    guard let self, let renderer, self.audioRenderer === renderer, self.playbackRate > 0 else { return }
                    // A rate or audio route change can discard the renderer's queued samples.
                    self.resetAudio(at: self.currentTime(), preserveClock: true)
                    self.tick()
                }
            }
    }

    deinit {
        ticker?.cancel()
        _ = pictureDecoder.requests.invalidate()
        _ = audioDecoder.requests.invalidate()
    }

    private func updateGain() {
        let gain = previewAudioGain(volume: volume, muted: isMuted)
        audioRenderer?.volume = gain
        reverseAudio.gain = gain
        scrubAudio.gain = gain
        if gain == 0 { endScrub() }
    }

    func reset() {
        pause()
        plan = nil
        participantPreview.configure(project: nil, document: nil)
        programStills = nil
        programTransfer = nil
        stillPreview.cancel()
        showingProgramStill = false
        media.removeAll()
        audio.removeAll()
        mixedAudio = nil
        time = .zero
        duration = .zero
        isAuditioning = false
        requestPicture(nil, interrupt: true)
        resetAudio(at: .zero)
        audioFlushObserver = nil
        audioRenderer = nil
        clock = nil
        pictureDecoder = MulticamPictureDecoder()
        audioDecoder = MulticamPreviewAudioDecoder()
    }

    func invalidateMedia(_ urls: Set<URL>) {
        participantPreview.invalidateMedia()
        pause()
        stopProgramStill()
        _ = pictureDecoder.requests.invalidate()
        pictureDecoder.invalidate(urls)
        prefetchedPicture = nil
        requestPicture(nil, interrupt: true)
        resetAudio(at: time)
        audioDecoder = MulticamPreviewAudioDecoder()
    }

    func configure(plan: MulticamPlan, media: [String: MediaInfo], project: CutProject? = nil,
                   document: URL? = nil, audioIsResolved: Bool = false) {
        if participantPreview.configure(project: project, document: document) {
            stillPreview.cancel()
            clearPicture()
        }
        let reference = plan.picture.lazy.compactMap { media[$0.source] }.first { $0.hasVideo }
            ?? media.sorted { $0.key < $1.key }.lazy.map(\.value).first { $0.hasVideo }
        programStills = ProgramPreviewStills(project: project, reference: reference, document: document)
        programTransfer = project?.programColorPolicy?.transfer ?? programStills?.canvas.transfer
        let lanes: [MulticamPlannedAudioLane]
        if !audioIsResolved, case .multicam(let multicam) = project {
            lanes = (try? multicam.resolveAudioLanes(plan: plan, indexedSources: media, unavailableAsGap: true)) ?? []
        } else if audioIsResolved {
            lanes = plan.audioLanes
        } else {
            lanes = (try? plan.resolveAudioLanes(indexedSources: media, unavailableAsGap: true)) ?? []
        }
        let mappedAudio = plan.isMix ? [] : lanes.flatMap { lane in
            lane.spans.compactMap { MulticamPreviewAudioSpan(span: $0, media: media) }
        }
        let mappedMix = plan.isMix && !lanes.isEmpty ? MulticamMixedAudioTimeline(lanes: lanes.map { lane in
            .init(label: lane.label, spans: lane.spans.compactMap { MulticamPreviewAudioSpan(span: $0, media: media) })
        }) : nil
        let position = currentTime()
        if self.plan?.picture != plan.picture {
            prefetchedPicture = nil
            if decodingPicture != desiredPicture {
                _ = pictureDecoder.requests.invalidate()
                decodingPicture = nil
            }
        }
        if media.count != self.media.count || !media.allSatisfy({ id, source in
            self.media[id]?.url == source.url && self.media[id]?.identity == source.identity
        }) {
            let sources = Set(media.values.map { MulticamPictureSource(url: $0.url, identity: $0.identity) })
            pictureDecoder.retainSources(sources)
        }
        self.plan = plan
        self.media = media
        duration = plan.duration
        isAuditioning = false
        endScrub()
        let clamped = min(position, duration)
        if mappedAudio != audio || mappedMix != mixedAudio || clamped != position {
            if mixedAudio != nil, mappedMix == nil {
                _ = audioDecoder.requests.invalidate()
                audioDecoder = MulticamPreviewAudioDecoder()
            }
            audio = mappedAudio
            mixedAudio = mappedMix
            resetAudio(at: clamped, preserveClock: playbackRate > 0 && clamped == position)
            if playbackRate < 0 { startReverseAudio(at: clamped) }
        }
        if time != clamped { time = clamped }
        if (playbackRate > 0 && time >= duration) || (playbackRate < 0 && time <= .zero) { pause() }
        render(at: time, interrupt: true)
    }

    /// Live edits use the output clock directly, even while the active picture is decoding.
    func currentTime() -> RationalTime {
        if playbackRate < 0 {
            let elapsed = reverseStarted.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let position = reverseAudio.position ?? reverseAnchor.seconds + seconds * Double(playbackRate)
            return max(.zero, min(time, Self.rationalTime(previewTime(position)) ?? time))
        }
        guard playbackRate > 0, let clock, clock.rate != 0,
              let position = Self.rationalTime(clock.currentTime()) else { return time }
        return min(duration, max(time, position))
    }

    private static func rationalTime(_ time: CMTime) -> RationalTime? {
        guard time.isNumeric, time.timescale > 0 else { return nil }
        return RationalTime(numerator: time.value, denominator: Int64(time.timescale))
    }

    func seek(to target: RationalTime) {
        let position = min(max(.zero, target), duration)
        isAuditioning = false
        endScrub()
        resetAudio(at: position)
        time = position
        if playbackRate < 0 { startReverseAudio(at: position) }
        render(at: position, interrupt: true)
        if isPlaying { tick() }
    }

    func scrub(to target: RationalTime) {
        let previous = currentTime()
        if isPlaying { pause() }
        let position = min(max(.zero, target), duration)
        isAuditioning = false
        time = position
        render(at: position, interrupt: true)
        guard scrubSoundEnabled, previewAudioGain(volume: volume, muted: isMuted) > 0 else { return }
        if let mixedAudio {
            let reverse = position < previous
            let point = position.seconds
            let window = reverse || position == duration
                ? max(0, point - 0.065)..<point : point..<min(duration.seconds, point + 0.065)
            if !window.isEmpty, mixedAudio.hasAudio(at: window.lowerBound, before: window.upperBound) {
                scrubAudio.submit(mixedAudio, window: window, reverse: reverse)
            } else {
                endScrub()
            }
            return
        }
        let index = audio.lowerBound { $0.output.upperBound > position }
        guard audio.indices.contains(index), audio[index].output.contains(position) else {
            endScrub()
            return
        }
        if scrubSpanIndex != index { endScrub() }
        scrubSpanIndex = index
        let span = audio[index]
        if let request = ScrubAudioRequest(source: span.url, composition: nil,
                                           position: span.sourceTime(at: position).seconds,
                                           bounds: span.input.lowerBound.seconds..<span.input.upperBound.seconds,
                                           reverse: position < previous, audioOrigin: span.origin,
                                           audioTrack: span.ordinal, presentationTrackID: span.presentationTrackID) {
            scrubAudio.submit(request)
        }
    }

    func endScrub() {
        scrubSpanIndex = nil
        scrubAudio.stop()
    }

    func togglePlayback() {
        if isPlaying { pause(); return }
        guard duration > .zero else { return }
        if time >= duration { seek(to: .zero) }
        startPlayback(at: forwardSpeed.rawValue)
    }

    func shuttle(_ direction: Int) {
        startPlayback(at: previewShuttleRate(playbackRate, direction: direction))
    }

    private func startPlayback(at rate: Float) {
        guard duration > .zero, rate != playbackRate else { return }
        let position = currentTime()
        if (rate > 0 && position >= duration) || (rate < 0 && position <= .zero) {
            pause()
            return
        }
        endAudition()
        endScrub()
        if rate > 0, playbackRate > 0, let clock {
            let advancing = clock.rate != 0
            time = position
            playbackRate = rate
            if advancing { clock.setRate(rate, time: previewTime(position)) }
            return
        }

        pause()
        playbackRate = rate
        if rate < 0 {
            startReverseAudio(at: time)
        } else {
            prepareForwardPlayback()
            resetAudio(at: time)
        }
        tick()
        guard isPlaying else { return }
        ticker = PreviewDisplayTicker(screen: playbackScreen) { [weak self] in self?.tick() }
    }

    private func startReverseAudio(at position: RationalTime) {
        reverseAnchor = position
        reverseStarted = .now
        if let mixedAudio, mixedAudio.hasAudio(at: .zero, before: position) {
            reverseAudio.start(ReverseAudioTimeline(mixedAudio: mixedAudio), at: position.seconds, speed: Int(-playbackRate))
            return
        }
        let regions = audio.map(\.reverseRegion)
        if regions.isEmpty {
            reverseAudio.stop()
        } else {
            reverseAudio.start(ReverseAudioTimeline(regions: regions), at: position.seconds, speed: Int(-playbackRate))
        }
    }

    func pause() {
        endScrub()
        guard isPlaying else { return }
        let parked = currentTime()
        ticker?.cancel()
        ticker = nil
        reverseAudio.stop()
        playbackRate = 0
        if time != parked { time = parked }
        resetAudio(at: parked, clearIssue: false)
        render(at: parked, interrupt: true)
    }

    func audition(url: URL, sourceTime: RationalTime, media: MediaInfo) {
        guard !isPlaying else { return }
        stopProgramStill()
        isAuditioning = true
        auditionTransfer = media.videoStream?.colorTransfer
        let target = MulticamPicturePosition.at(sourceTime, source: url.path, media: media, spanIndex: -1)
        requestPicture(target, interrupt: true)
    }

    func endAudition() {
        guard isAuditioning else { return }
        isAuditioning = false
        render(at: time, interrupt: true)
    }

    func attach(_ surface: PreviewSurface) {
        surfaces.add(surface)
        surface.otherMonitorStatus = { [weak self] in
            self?.surfaces.allObjects.first(where: \.isVideoMonitor)?.presentationDescription
        }
        if let frame {
            participantPreview.attach(surface, frame: frame)
        } else if let pictureIssue { surface.unavailable(pictureIssue) }
    }

    fileprivate func detach(_ surface: PreviewSurface) {
        surfaces.remove(surface)
    }

    private func render(at time: RationalTime, interrupt: Bool) {
        guard !isAuditioning else { return }
        if let programStills, let still = programStills.picture(at: time) {
            if !showingProgramStill {
                showingProgramStill = true
                _ = pictureDecoder.requests.invalidate()
                decodingPicture = nil
                desiredPicture = nil
                prefetchedPicture = nil
                failedPicture = nil
            }
            stillPreview.show(still, canvas: programStills.canvas, onPending: {
                clearPicture()
                setPictureIssue(nil)
            }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let frame):
                    self.frame = frame
                    self.participantPreview.display(frame, at: self.time,
                                                sourceID: nil, sourceTime: nil, programStill: true,
                                                on: self.surfaces.allObjects) { [weak self] in self?.surfaces.allObjects ?? [] }
                    self.setPictureIssue(nil)
                case .failure(let error):
                    self.clearPicture()
                    self.setPictureIssue(error.localizedDescription)
                }
            }
            return
        }
        stopProgramStill()
        requestPicture(plan.flatMap { MulticamPicturePosition.at(time, in: $0, media: media) }, interrupt: interrupt)
        guard playbackRate > 0, !interrupt, let plan, let picture, picture == desiredPicture,
              decodingPicture == nil, prefetchedPicture == nil,
              let next = picture.following(in: plan, media: media),
              next.startsAt.seconds - time.seconds <= 0.12 else { return }
        // Decode one upcoming picture while the on-air frame is displayed.
        // A timed edit still takes effect only on the shared output clock.
        decodePicture(next.picture, prefetch: true)
    }

    private func stopProgramStill() {
        guard showingProgramStill else { return }
        showingProgramStill = false
        stillPreview.cancel()
        clearPicture()
        setPictureIssue(nil)
    }

    private func setPictureIssue(_ message: String?) {
        if pictureIssue != message {
            pictureIssue = message
            if frame == nil {
                if let message { surfaces.allObjects.forEach { $0.unavailable(message) } }
                else { surfaces.allObjects.forEach { $0.clear() } }
            }
        }
        if issue != (pictureIssue ?? audioIssue) { issue = pictureIssue ?? audioIssue }
    }

    private func setAudioIssue(_ message: String?) {
        if audioIssue != message { audioIssue = message }
        if issue != (pictureIssue ?? audioIssue) { issue = pictureIssue ?? audioIssue }
    }

    private func requestPicture(_ target: MulticamPicturePosition?, interrupt: Bool) {
        let changedSpan = target?.spanIndex != desiredPicture?.spanIndex || target?.source != desiredPicture?.source
            || target?.url != desiredPicture?.url || target?.origin != desiredPicture?.origin
            || target?.identity != desiredPicture?.identity
            || target?.multicamClockOffset != desiredPicture?.multicamClockOffset
        let changedTarget = target != desiredPicture
        desiredPicture = target
        if changedSpan || (interrupt && changedTarget) {
            if interrupt || decodingPicture != target {
                _ = pictureDecoder.requests.invalidate()
                decodingPicture = nil
            }
            failedPicture = nil
        }
        if changedSpan || target == nil { clearPicture() }
        guard let target else {
            prefetchedPicture = nil
            setPictureIssue(plan == nil ? nil : "No indexed picture covers this position.")
            return
        }
        if let prefetchedPicture, prefetchedPicture.position == target {
            self.prefetchedPicture = nil
            show(prefetchedPicture.frame, at: target)
            return
        }
        if changedTarget { prefetchedPicture = nil }
        if picture == target, let frame {
            let tagged = taggedPicture(frame, at: target)
            if frame.programTransfer != tagged.programTransfer || frame.cameraTransfer != tagged.cameraTransfer {
                show(tagged, at: target)
            } else if participantPreview.enabled {
                displayParticipantPicture(frame, position: target)
            }
            return
        }
        guard decodingPicture == nil, failedPicture != target else { return }
        decodePicture(target, prefetch: false)
    }

    private func taggedPicture(_ decoded: PreviewFrame, at position: MulticamPicturePosition) -> PreviewFrame {
        let transfer = media[position.source]?.videoStream?.colorTransfer
        var frame = decoded
        frame.programTransfer = isAuditioning ? auditionTransfer : programTransfer ?? transfer
        frame.cameraTransfer = isAuditioning ? nil : transfer ?? "unknown"
        return frame
    }

    private func show(_ decoded: PreviewFrame, at position: MulticamPicturePosition) {
        let frame = taggedPicture(decoded, at: position)
        self.frame = frame
        displayParticipantPicture(frame, position: position)
        picture = position
        setPictureIssue(nil)
    }

    func setParticipantSource(_ source: Bool) {
        guard participantPreview.source != source else { return }
        participantPreview.source = source
        guard let frame else { return }
        if !source, participantPreview.enabled {
            for surface in surfaces.allObjects where !surface.isVideoMonitor { surface.clear() }
        }
        if showingProgramStill {
            participantPreview.display(frame, at: time, sourceID: nil, sourceTime: nil, programStill: true,
                                       on: surfaces.allObjects) { [weak self] in self?.surfaces.allObjects ?? [] }
        } else if let picture {
            displayParticipantPicture(frame, position: picture)
        }
    }

    private func displayParticipantPicture(_ frame: PreviewFrame, position: MulticamPicturePosition) {
        participantPreview.display(frame, at: isAuditioning ? nil : time, sourceID: position.source,
                                   sourceTime: position.provisional ? nil : position.frameTime, on: surfaces.allObjects) { [weak self] in
            self?.surfaces.allObjects ?? []
        }
    }

    private func clearPicture() {
        participantPreview.clear()
        if frame != nil { surfaces.allObjects.forEach { $0.clear() } }
        frame = nil
        if picture != nil { picture = nil }
    }

    private func decodePicture(_ target: MulticamPicturePosition, prefetch: Bool) {
        let decoder = pictureDecoder
        let request = decoder.requests.invalidate()
        decodingPicture = target
        decoder.pictureWork.submit(on: decoder.requests.queue) { [weak self] in
            guard decoder.requests.isCurrent(request) else { return }
            let result = Result { try decoder.decode(target, request: request) }
            Task { @MainActor in
                guard let self, decoder.requests.isCurrent(request) else { return }
                self.decodingPicture = nil
                switch result {
                case .success(let frame?):
                    if !prefetch || self.desiredPicture == target {
                        self.show(frame, at: target)
                    } else if self.isPlaying {
                        self.prefetchedPicture = (target, frame)
                    }
                case .success(nil):
                    break
                case .failure(let error):
                    if !prefetch || self.desiredPicture == target {
                        self.failedPicture = target
                        if self.desiredPicture == target { self.clearPicture() }
                        self.setPictureIssue(error.localizedDescription)
                    }
                }
                if !self.isPlaying, let next = self.desiredPicture, next != target {
                    self.requestPicture(next, interrupt: false)
                }
            }
        }
    }

    private func resetAudio(at position: RationalTime, clearIssue: Bool = true, preserveClock: Bool = false) {
        if !preserveClock { clock?.setRate(0, time: previewTime(position)) }
        audioRenderer?.flush()
        _ = audioDecoder.requests.invalidate()
        queuedAudio.removeAll(keepingCapacity: true)
        decodingAudio = false
        audioIndex = audio.lowerBound { $0.output.upperBound > position }
        audioStart = audio.indices.contains(audioIndex) ? audio[audioIndex].sourceTime(at: position) : .zero
        if let mixedAudio {
            audioDecoder = MulticamPreviewAudioDecoder()
            mixStart = mixedAudio.lanes.compactMap { lane in
                let index = lane.spans.lowerBound { $0.output.upperBound > position }
                return lane.spans.indices.contains(index) ? max(position, lane.spans[index].output.lowerBound) : nil
            }.min()
            mixEnd = mixStart == nil
        } else {
            mixStart = nil
            mixEnd = true
        }
        openAudio = true
        audioHasPreroll = false
        if clearIssue { setAudioIssue(nil) }
    }

    private func tick() {
        guard isPlaying else { return }
        if playbackRate < 0 {
            if reverseAudio.position != nil {
                reverseAnchor = currentTime()
                reverseStarted = .now
            }
            reverseAudio.tick()
        }
        let position = currentTime()
        if time != position { time = position }
        render(at: position, interrupt: false)
        if playbackRate < 0 {
            if position <= .zero { pause() }
            return
        }
        if position >= duration { pause(); return }
        guard let clock, let audioRenderer else { return }
        if audioRenderer.status == .failed {
            queuedAudio.removeAll(keepingCapacity: true)
            audioIndex = audio.count
            mixEnd = true
            audioHasPreroll = true
            setAudioIssue(audioRenderer.error?.localizedDescription ?? "Audio preview could not be played.")
        }
        let limit = position.seconds + Self.audioLookahead * Double(playbackRate)
        while let sample = queuedAudio.first, sample.presentationTimeStamp.seconds <= limit,
              audioRenderer.isReadyForMoreMediaData {
            audioRenderer.enqueue(sample)
            queuedAudio.removeFirst()
        }
        let legacyInLookahead = audio.indices.contains(audioIndex) && audio[audioIndex].output.lowerBound.seconds <= limit
        let mixInLookahead = !mixEnd && (mixStart?.seconds ?? .infinity) <= limit
        let audioInLookahead = legacyInLookahead || mixInLookahead
        if clock.rate == 0, audioHasPreroll || !audioInLookahead {
            clock.setRate(playbackRate, time: previewTime(position))
        }
        if audioInLookahead, queuedAudio.isEmpty, !decodingAudio {
            if let mixedAudio, let mixStart {
                decodeMix(mixedAudio, from: mixStart)
            } else {
                decodeAudio()
            }
        }
    }

    private func decodeMix(_ timeline: MulticamMixedAudioTimeline, from start: RationalTime) {
        let decoder = audioDecoder
        let request = decoder.requests.invalidate()
        let open = openAudio
        decodingAudio = true
        decoder.requests.queue.async { [weak self] in
            guard decoder.requests.isCurrent(request) else { return }
            let result = Result {
                try decoder.read(program: timeline, from: start, open: open) { !decoder.requests.isCurrent(request) }
            }
            Task { @MainActor in
                guard let self, decoder.requests.isCurrent(request), self.playbackRate > 0 else { return }
                self.decodingAudio = false
                self.openAudio = false
                switch result {
                case .success(let batch):
                    self.queuedAudio.append(contentsOf: batch.samples)
                    self.mixEnd = batch.end
                    self.audioHasPreroll = self.audioHasPreroll || !batch.samples.isEmpty || batch.end
                    if let issue = batch.issue { self.setAudioIssue(issue) }
                case .failure(let error):
                    self.mixEnd = true
                    self.audioHasPreroll = true
                    self.setAudioIssue(error.localizedDescription)
                }
                self.tick()
            }
        }
    }

    private func decodeAudio() {
        let decoder = audioDecoder
        let request = decoder.requests.invalidate()
        let span = audio[audioIndex]
        let start = audioStart
        let open = openAudio
        decodingAudio = true
        decoder.requests.queue.async { [weak self] in
            guard decoder.requests.isCurrent(request) else { return }
            let result = Result {
                try decoder.read(span: span, from: start, open: open) { !decoder.requests.isCurrent(request) }
            }
            Task { @MainActor in
                guard let self, decoder.requests.isCurrent(request), self.playbackRate > 0 else { return }
                self.decodingAudio = false
                self.openAudio = false
                switch result {
                case .success(let batch):
                    self.queuedAudio.append(contentsOf: batch.audio)
                    self.audioHasPreroll = self.audioHasPreroll || !batch.audio.isEmpty || batch.end
                    if batch.noAudio { self.setAudioIssue(MulticamDecodeError.audio(span.url).localizedDescription) }
                    if batch.end { self.advanceAudio() }
                case .failure(let error):
                    self.setAudioIssue(error.localizedDescription)
                    self.audioHasPreroll = true
                    self.advanceAudio()
                }
                self.tick()
            }
        }
    }

    private func advanceAudio() {
        audioIndex += 1
        openAudio = true
        if audio.indices.contains(audioIndex) { audioStart = audio[audioIndex].input.lowerBound }
    }
}

struct MulticamPreviewView: NSViewRepresentable {
    let preview: MulticamPreview
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
