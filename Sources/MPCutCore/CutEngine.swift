import Darwin
import Foundation
import PacketWriter

public struct CutEngine: Sendable {
    private let cancelled: (@Sendable () -> Bool)?

    private let smartTrim: Bool
    private let useSidecar: Bool
    let tracks: ExportTracks
    let audioStream: Int?
    let audioTrackOrdinal: Int?
    /// The picture is one lane of a multicam program. The later mux adds nothing from the camera file.
    private let stagesPicture: Bool

    /// Select an audio track by absolute stream index, or by zero-based position among each source’s audio tracks.
    public init(cancelled: (@Sendable () -> Bool)? = nil, smartTrim: Bool = false, useSidecar: Bool = true,
                tracks: ExportTracks = .all, audioStream: Int? = nil, audioTrackOrdinal: Int? = nil) {
        self.tracks = tracks
        self.audioStream = audioStream
        self.audioTrackOrdinal = audioTrackOrdinal
        self.smartTrim = smartTrim && tracks == .all
        self.useSidecar = useSidecar
        self.cancelled = cancelled
        stagesPicture = false
    }

    init(multicamSmartPicture: Bool, cancelled: (@Sendable () -> Bool)?) {
        tracks = .video
        audioStream = nil
        audioTrackOrdinal = nil
        smartTrim = multicamSmartPicture
        useSidecar = true
        self.cancelled = cancelled
        stagesPicture = true
    }

    /// Read a complete editing index if one was saved alongside the source.
    public func cachedIndex(_ file: URL, progress: ((Double) -> Void)? = nil) throws -> MediaInfo? {
        try cachedIndex(file, expectedIdentity: nil, progress: progress)
    }

    package func cachedIndex(_ file: URL, expectedIdentity: SourceIdentity?,
                             progress: ((Double) -> Void)? = nil) throws -> MediaInfo? {
        try checkCancellation()
        return try cachedMedia(file.standardizedFileURL, detail: .full, expectedIdentity: expectedIdentity, progress: progress)
    }

    /// Report metadata and mux eligibility. Sample indexes may be omitted.
    public func inspectSummary(_ file: URL) throws -> MediaInfo {
        try checkCancellation()
        if let cached = try cachedMedia(file.standardizedFileURL, detail: .summary) { return cached }
        guard file.isFileURL else { throw CutError(code: "invalid_input", message: "Choose a local media file.") }
        return try inspect(file, keyframes: false)
    }

    /// An exact audio analysis clock, including presented MOV edits when present.
    /// A validated sidecar can supply this without reading the packet or picture index.
    public func inspectForAudioAnalysis(_ file: URL) throws -> MediaInfo {
        try checkCancellation()
        guard file.isFileURL else { throw CutError(code: "invalid_input", message: "Choose a local media file.") }
        let source = file.standardizedFileURL
        if let cached = try cachedMedia(source, detail: .analysis) { return cached }
        return try inspectFresh(source, keyframes: false, audioAnalysis: true)
    }

    private func cachedMedia(_ file: URL, detail: SidecarIndexDetail,
                             expectedIdentity: SourceIdentity? = nil, progress: ((Double) -> Void)? = nil) throws -> MediaInfo? {
        guard useSidecar, AnalysisSidecar.readsEnabled, file.isFileURL,
              !AnalysisSidecar.isExcluded(file, in: AnalysisSidecar.excludedSources)
        else { return nil }
        guard let sidecar = try? AnalysisSidecar(source: file) else { return nil }
        let identity = sidecar.identity
        if let expectedIdentity, !expectedIdentity.matchesSnapshot(identity) {
            throw CutError(code: "source_changed", message: "The source changed while opening the clip.")
        }
        let media = try sidecar.loadIndex(detail: detail, progress: progress, cancelled: cancelled ?? { false })
        try checkCancellation()
        guard identity.isCurrentSnapshot(at: file) else {
            throw CutError(code: "source_changed", message: "The source changed while loading its index.")
        }
        return media
    }

    public func inspect(_ file: URL, keyframes: Bool = false, matchingPreview: MediaInfo? = nil, progress: ((Double) -> Void)? = nil) throws -> MediaInfo {
        try inspect(file, keyframes: keyframes, expectedIdentity: matchingPreview?.identity.forPreviewHandoff(), progress: progress)
    }

    package func inspect(_ file: URL, keyframes: Bool, expectedIdentity: SourceIdentity?,
                         progress: ((Double) -> Void)? = nil) throws -> MediaInfo {
        try checkCancellation()
        guard file.isFileURL else {
            throw CutError(code: "invalid_input", message: "Choose a local media file.")
        }
        let url = file.standardizedFileURL
        var restoredFraction = 0.0
        let cacheProgress = progress.map { update in
            { (fraction: Double) in
                restoredFraction = max(restoredFraction, fraction)
                update(restoredFraction)
            }
        }
        if let cached = try cachedMedia(url, detail: keyframes ? .full : .audio,
                                        expectedIdentity: expectedIdentity, progress: cacheProgress) {
            return cached
        }
        // If a later section failed validation, continue from the work already reported.
        let scanProgress = progress.map { update in
            { (fraction: Double) in update(restoredFraction + (1 - restoredFraction) * fraction) }
        }
        return try inspectFresh(url, keyframes: keyframes, expectedIdentity: expectedIdentity, progress: scanProgress)
    }

    /// Continue an import after a cache miss. The editor may publish a provisional clip before this call.
    package func inspectFresh(_ file: URL, keyframes: Bool, expectedIdentity: SourceIdentity? = nil,
                              progress: ((Double) -> Void)? = nil, audioAnalysis: Bool = false,
                              allowAutomaticSave: @escaping () -> Bool = { true }) throws -> MediaInfo {
        try checkCancellation()
        guard file.isFileURL else { throw CutError(code: "invalid_input", message: "Choose a local media file.") }
        let url = file.standardizedFileURL
        let persist = useSidecar && AnalysisSidecar.readsEnabled && AnalysisSidecar.automaticWritesEnabled
            && !AnalysisSidecar.isExcluded(url, in: AnalysisSidecar.excludedSources) && allowAutomaticSave()
        let scanShare = persist ? 0.98 : 1.0
        let media = try Probe.read(url, keyframes: keyframes || persist, audioAnalysis: audioAnalysis, expectedIdentity: expectedIdentity,
                                   progress: progress.map { update in { update($0 * scanShare) } }, cancelled: cancelled)
        if persist, media.hasFullEditIndex, allowAutomaticSave() {
            let check = { [cancelled] in cancelled?() == true || !allowAutomaticSave() }
            AnalysisSidecar(media: media).saveAutomatically(try AnalysisSidecar.indexSections(for: media,
                progress: { progress?(scanShare + (0.999 - scanShare) * $0) }, cancelled: check), cancelled: check)
            try verifyIdentity(url, identity: media.identity)
        }
        try checkCancellation()
        progress?(1)
        return keyframes || media.frames.isEmpty ? media : media.omittingFrames()
    }

    /// Container metadata for early playback. Exact edit times require inspection.
    public func inspectForPreview(_ file: URL) throws -> MediaInfo {
        try checkCancellation()
        guard file.isFileURL else {
            throw CutError(code: "invalid_input", message: "Choose a local media file.")
        }
        let url = file.standardizedFileURL
        if let cached = try cachedMedia(url, detail: .preview) { return cached }
        return try Probe.read(url, keyframes: false, previewOnly: true, cancelled: cancelled)
    }

    public func checkCompatibility(_ media: MediaInfo, with reference: MediaInfo) throws {
        try checkCompatibility(media, with: reference, reencodingAudio: nil)
    }

    package func checkPictureCompatibility(_ media: MediaInfo, with reference: MediaInfo,
                                           omittingContentLight: Bool = false) throws {
        try checkCompatibility(media, with: reference, reencodingAudio: .removeAudio,
                               omittingContentLight: omittingContentLight)
    }

    func checkCompatibility(_ media: MediaInfo, with reference: MediaInfo, reencodingAudio: ReencodeAudio?,
                            omittingContentLight: Bool = false) throws {
        if reencodingAudio == .auto {
            do {
                try checkCompatibility(media, with: reference)
            } catch {
                // Automatic audio falls back to conversion if exact copy cannot be verified.
                try checkCompatibility(media, with: reference, reencodingAudio: .aac)
            }
            return
        }

        func match<Value: Equatable>(_ label: String, _ present: Value, _ expected: Value) throws {
            guard present == expected else {
                throw CutError(code: "incompatible_clip",
                               message: "Clip \(label) is \(present). The sequence requires \(expected).")
            }
        }

        func matchMetadata(_ label: String, _ actual: Data, _ expected: Data) throws {
            guard actual == expected else {
                throw CutError(code: "incompatible_clip", message: "Clip \(label) differs from the sequence.")
            }
        }

        func configuration(_ stream: StreamInfo) -> Data {
            var bytes = stream.configuration
            if stream.codec == "flac" {
                bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                    mpcut_normalize_flac_streaminfo(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
                }
            }
            return bytes
        }

        do {
            try match("media type", media.hasVideo ? "video" : "audio", reference.hasVideo ? "video" : "audio")
        } catch let issue as CutError {
            throw issue.because(.joinMediaType)
        }
        if let presentVideo = media.videoStream, let referenceVideo = reference.videoStream {
            try match("video codec", presentVideo.codec, referenceVideo.codec)
            try match("coded dimensions", "\(presentVideo.width)×\(presentVideo.height)",
                      "\(referenceVideo.width)×\(referenceVideo.height)")
            try match("display dimensions", "\(presentVideo.displayWidth)×\(presentVideo.displayHeight)",
                      "\(referenceVideo.displayWidth)×\(referenceVideo.displayHeight)")
            try match("orientation", presentVideo.rotation, referenceVideo.rotation)
            try match("pixel aspect ratio", presentVideo.sampleAspectRatio, referenceVideo.sampleAspectRatio)
            try match("video profile", presentVideo.profile, referenceVideo.profile)
            try match("frame rate", presentVideo.frameRate, referenceVideo.frameRate)
            try match("bit depth", presentVideo.bitDepth, referenceVideo.bitDepth)
            try match("pixel format", presentVideo.pixelFormat, referenceVideo.pixelFormat)
            try match("field order", presentVideo.fieldOrder, referenceVideo.fieldOrder)
            try match("chroma location", presentVideo.chromaLocation, referenceVideo.chromaLocation)
            try match("alpha depth", presentVideo.alphaBits, referenceVideo.alphaBits)
            try match("additional video layers", presentVideo.hasAdditionalVideoLayers, referenceVideo.hasAdditionalVideoLayers)
            try match("color primaries", presentVideo.colorPrimaries, referenceVideo.colorPrimaries)
            try match("transfer function", presentVideo.colorTransfer, referenceVideo.colorTransfer)
            try match("color matrix", presentVideo.colorMatrix, referenceVideo.colorMatrix)
            try match("color range", presentVideo.colorRange, referenceVideo.colorRange)
            try matchMetadata("video side data",
                              omittingContentLight ? presentVideo.metadataWithoutContentLight : presentVideo.codecMetadata,
                              omittingContentLight ? referenceVideo.metadataWithoutContentLight : referenceVideo.codecMetadata)
            try matchMetadata("video codec configuration", presentVideo.configuration, referenceVideo.configuration)
        }

        if reencodingAudio == .removeAudio { return }
        let convertsAudio = reencodingAudio == .aac || reencodingAudio == .pcm
        if !convertsAudio {
            func layout(_ media: MediaInfo) -> [String] {
                media.streams.filter { media.hasVideo || $0.kind == "audio" }.map { "\($0.kind)/\($0.kind == "data" ? $0.codecTag : $0.codec)" }
            }
            try match("track layout", layout(media), layout(reference))
        }
        try match("audio track count", media.audio.count, reference.audio.count)
        for (position, pair) in zip(media.audio, reference.audio).enumerated() {
            let (present, expected) = (pair.0.stream, pair.1.stream)
            let label = "audio track \(position + 1)"
            // With parallel soundtracks the first clip's labels apply to the entire export.
            if media.audio.count > 1 {
                try match("\(label) language", present.language, expected.language)
                guard present.disposition == expected.disposition else {
                    throw CutError(code: "incompatible_clip", message: "Clip \(label) has a different playback role.")
                }
            }
            if !convertsAudio {
                try match("\(label) codec", present.codec, expected.codec)
                try match("\(label) profile", present.profile, expected.profile)
            }
            try match("\(label) sample rate", present.sampleRate, expected.sampleRate)
            try match("\(label) channel count", present.channels, expected.channels)
            if convertsAudio {
                try match("\(label) channel layout", audioLayout(present), audioLayout(expected))
                continue
            }
            // Containers describe one layout in different words (MP4 "2 channels", MOV "stereo" for the same AAC track).
            try match("\(label) channel layout", present.canonicalChannelLayout, expected.canonicalChannelLayout)
            try matchMetadata("\(label) codec configuration", configuration(present), configuration(expected))
            try matchMetadata("\(label) side data", present.codecMetadata, expected.codecMetadata)
        }
    }

    public func suggestedContainers(for original: MediaInfo) -> [String] {
        guard let media = try? selectedMedia(original), media.copyIssue == nil else { return [] }
        if !media.hasVideo {
            return supportedMuxContainers(preferredAudioContainers(media), for: media)
        }
        let sources = Set(media.format.split(separator: ","))
        let original = media.url.pathExtension.lowercased()
        let aliases: [(demuxer: String, extensions: [String])] = [
            ("mov", ["mov", "mp4", "m4v", "3gp", "3g2"]),
            ("matroska", ["mkv", "webm"]),
            ("mpegts", ["ts", "m2ts", "mts"]),
            ("avi", ["avi"]),
            ("mxf", ["mxf"]),
            ("nut", ["nut"]),
            ("flv", ["flv"]),
            ("asf", ["asf", "wmv"]),
            ("ogg", ["ogg", "ogv"])
        ]
        let sourceFormats = aliases.filter { sources.contains(Substring($0.demuxer)) }
        let ownExtension = sourceFormats.contains { $0.extensions.contains(original) } ? [original] : []
        var probeOrder = ownExtension + sourceFormats.compactMap { $0.extensions.first }
        if media.video.codec == "prores" {
            probeOrder.append(contentsOf: ["mov", "mkv"])
        } else {
            probeOrder.append(contentsOf: ["mkv", "mp4", "mov", "webm"])
        }

        var considered: Set<String> = []
        let candidates = probeOrder.filter { container in
            !container.isEmpty && considered.insert(container).inserted &&
                (!media.video.multipleDescriptions || ["mov", "mp4", "m4v"].contains(container)) &&
                media.audio.allSatisfy { $0.presentationEdits.isEmpty || supportsAACEdits($0.stream, container: container) }
        }
        return supportedMuxContainers(candidates, for: media)
    }

    public func validBoundaries(in media: MediaInfo, start: Bool, first: Bool = true,
                                last: Bool = true, container: String? = nil) -> [RationalTime] {
        guard let media = try? selectedMedia(media) else { return [] }
        if !media.hasVideo { return audioPacketBoundaries(media, starting: start) }
        let effectiveContainer = container ?? suggestedContainers(for: media).first
            ?? media.url.pathExtension.lowercased()
        return (try? boundarySet(in: media, start: start, first: first, last: last, container: effectiveContainer,
                                 recordRejections: false).times) ?? []
    }

    public func linkedAudioBoundaryIssue(in media: MediaInfo, at time: RationalTime, start: Bool,
                                         first: Bool, last: Bool, container: String) -> CutError? {
        guard media.hasVideo else { return nil }
        do {
            let boundaries = try boundarySet(in: media, start: start, first: first, last: last, container: container)
            guard boundaries.rejected[time] != nil else { return nil }
            _ = try select(time, from: boundaries, snap: .exact, segment: 1,
                           field: start ? "from" : "to", includeSuggestions: false, eligible: { _ in true })
            return nil
        } catch let issue as CutError {
            return issue
        } catch {
            return nil
        }
    }

    public func resolve(_ clips: [ClipRequest], output: URL? = nil, snap: SnapMode = .exact,
                        media: [URL: MediaInfo] = [:], container requestedContainer: String? = nil) throws -> ResolvedEdit {
        var boundaries = BoundaryCache()
        return try resolve(clips, output: output, snap: snap, media: media, container: requestedContainer,
                           boundaries: &boundaries)
    }

    // A batch shares this cache across requests made with the same engine and source indexes.
    func resolve(_ clips: [ClipRequest], output: URL? = nil, snap: SnapMode,
                 media: [URL: MediaInfo], container requestedContainer: String?,
                 boundaries: inout BoundaryCache) throws -> ResolvedEdit {
        guard !clips.isEmpty else {
            throw CutError(code: "empty_edit", message: "Add at least one clip before exporting.")
        }
        if let output {
            try checkDestination(output)
        }

        var indexed = media
        var uniqueMedia: [MediaInfo] = []
        var firstOccurrence: [URL: Int] = [:]
        var sequence: [MediaInfo] = []
        for (index, clip) in clips.enumerated() {
            try checkCancellation()
            let file = clip.file.standardizedFileURL
            if let first = firstOccurrence[file] {
                sequence.append(sequence[first - 1])
                continue
            }
            let info: MediaInfo
            do {
                let original: MediaInfo
                if let cached = indexed[file], cached.url == file, cached.hasFullEditIndex {
                    try verifyIdentity(file, identity: cached.identity)
                    original = cached
                } else {
                    original = try inspect(file, keyframes: true)
                    indexed[file] = original
                }
                info = try selectedMedia(original)
                if let issue = info.copyIssue {
                    throw CutError(code: "unsupported_tracks", message: issue)
                }
                if let reference = sequence.first {
                    try checkCompatibility(info, with: reference)
                }
            } catch let issue as CutError {
                if issue.code == "cancelled" { throw issue }
                throw CutError(code: issue.code, message: issue.message, segment: index + 1,
                               boundary: issue.boundary, nearest: issue.nearest, track: issue.track).because(issue.reason)
            }
            firstOccurrence[file] = index + 1
            uniqueMedia.append(info)
            sequence.append(info)
        }

        let extensionFromPath = output?.pathExtension.lowercased() ?? ""
        let explicit = requestedContainer?.lowercased()
            ?? (extensionFromPath.isEmpty ? nil : extensionFromPath)
        if let explicit {
            guard explicit.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }),
                  !explicit.isEmpty, extensionFromPath.isEmpty || extensionFromPath == explicit else {
                throw CutError(code: "unsupported_container", message: "The container must match the destination extension.")
            }
            for info in uniqueMedia {
                try checkCancellation()
                if info.videoStream?.multipleDescriptions == true && !["mov", "mp4", "m4v"].contains(explicit) {
                    throw CutError(code: "unsupported_container",
                                   message: "This source uses multiple video sample descriptions and requires MOV or MP4 output.",
                                   segment: firstOccurrence[info.url]).because(.sourceMultipleDescriptions)
                }
                if let issue = cachedMuxIssue(info, container: explicit, cache: &boundaries) {
                    throw CutError(code: "unsupported_container", message: issue,
                                   segment: firstOccurrence[info.url])
                }
            }
            return try deliveredPicture(resolveSequence(clips, sequence: sequence, uniqueMedia: uniqueMedia,
                                                        container: explicit, snap: snap, boundaries: &boundaries),
                                        source: indexed[sequence[0].url])
        }

        var defaultFailure: CutError?
        let original = indexed[sequence[0].url] ?? sequence[0]
        let key = muxKey(original)
        let supported: [String]
        if let cached = boundaries.suggestedContainers[original.url]?[key] {
            supported = cached
        } else {
            supported = suggestedContainers(for: original)
            boundaries.suggestedContainers[original.url, default: [:]][key] = supported
        }
        for candidate in editContainers(supported, for: original, clips: clips) {
            try checkCancellation()
            if !uniqueMedia.dropFirst().allSatisfy({
                ($0.videoStream?.multipleDescriptions != true || ["mov", "mp4", "m4v"].contains(candidate))
                    && cachedMuxIssue($0, container: candidate, cache: &boundaries) == nil
            }) {
                continue
            }
            let resolved: ResolvedEdit
            do {
                resolved = try resolveSequence(clips, sequence: sequence, uniqueMedia: uniqueMedia,
                                               container: candidate, snap: snap, boundaries: &boundaries)
            } catch let error as CutError {
                if error.code == "cancelled" || error.code == "source_changed" { throw error }
                if defaultFailure == nil { defaultFailure = error }
                continue
            }
            return try deliveredPicture(resolved, source: original)
        }
        throw defaultFailure ?? CutError(code: "unsupported_container",
                                         message: "No available container can carry every clip.")
    }

    /// A picture-only export that a person asked for keeps what describes the picture: the source’s chapters, and its
    /// MOV timecode track when the container and the ranges can hold it. Timecode that cannot be kept is left behind
    /// with a stated reason, as it was before picture-only exports carried it at all.
    private func deliveredPicture(_ resolved: ResolvedEdit, source: MediaInfo?) throws -> ResolvedEdit {
        guard tracks == .video, !stagesPicture, resolved.tracks == .video else { return resolved }
        var edit = resolved
        edit.deliversPicture = true
        if let track = source?.streams.first(where: { $0.kind == "data" && $0.codecTag == "tmcd" }) {
            do {
                try checkTimecode(edit.segments, duration: edit.duration, container: edit.container, track: track.index,
                                  pictureOnly: true)
                edit.keepsTimecode = true
            } catch let issue as CutError where issue.code == "unsupported_timecode" {
                edit.timecodeIssue = issue.message
            }
        }
        return edit
    }

    private func resolveSequence(_ clips: [ClipRequest], sequence: [MediaInfo], uniqueMedia: [MediaInfo],
                                 container: String, snap: SnapMode, boundaries: inout BoundaryCache) throws -> ResolvedEdit {
        if !sequence[0].hasVideo {
            return try resolveAudioRanges(clips, sequence: sequence, uniqueMedia: uniqueMedia,
                                          container: container, snap: snap)
        }
        do {
            return try resolveRanges(clips, sequence: sequence, uniqueMedia: uniqueMedia,
                                     container: container, snap: snap, includeSuggestions: true, boundaries: &boundaries)
        } catch let failure as CutError {
            guard let segment = failure.segment, clips.indices.contains(segment - 1),
                  let field = failure.boundary, field == "from" || field == "to",
                  let options = failure.nearest, !options.isEmpty else { throw failure }

            let original = clips[segment - 1]
            var verified: [(time: RationalTime, edit: ResolvedEdit)] = []
            // Options that fix this boundary but stop at another unsafe boundary in the request.
            var acceptable: [RationalTime] = []
            for option in options {
                try checkCancellation()
                var replacement = clips
                replacement[segment - 1] = ClipRequest(file: original.file,
                                                       from: field == "from" ? option : original.from,
                                                       to: field == "to" ? option : original.to)
                do {
                    let candidate = try resolveRanges(replacement, sequence: sequence, uniqueMedia: uniqueMedia,
                                                      container: container, snap: snap, includeSuggestions: false,
                                                      boundaries: &boundaries)
                    verified.append((option, candidate))
                    acceptable.append(option)
                } catch let error as CutError where error.code == "cancelled" || error.code == "source_changed" {
                    throw error
                } catch let error as CutError {
                    // Keep an option that only stops at a requested boundary that is unsafe on its own,
                    // whatever this option is. Join and continuity failures can depend on this option.
                    guard error.code == "unsafe_boundary", let other = error.segment, clips.indices.contains(other - 1),
                          let side = error.boundary, side == "from" || side == "to",
                          other != segment || side != field else { continue }
                    let info = sequence[other - 1]
                    let requested = side == "from" ? clips[other - 1].from ?? .zero : clips[other - 1].to ?? info.duration
                    // Merged ranges report errors by clip index, but their edge rules follow the merged position.
                    let merged = effectiveRanges(replacement, sequence: sequence, container: container)
                    let group = merged.firstIndex { ($0.startIndex...$0.endIndex).contains(other) }
                    let times = try cachedBoundaries(in: info, start: side == "from", first: group == 0,
                                                     last: group == merged.count - 1, container: container,
                                                     cache: &boundaries).times
                    let position = times.lowerBound { $0 >= requested }
                    if position == times.endIndex || times[position] != requested {
                        acceptable.append(option)
                    }
                } catch {
                    continue
                }
            }
            if snap == .nearest, let first = verified.first {
                guard let last = verified.last, first.time != last.time else { return first.edit }
                let requested = field == "from" ? original.from ?? .zero : original.to ?? sequence[segment - 1].duration
                return requested.isCloserToEarlier(first.time, than: last.time) ? first.edit : last.edit
            }
            throw CutError(code: failure.code, message: failure.message, segment: segment, boundary: field,
                           nearest: acceptable, track: failure.track).because(failure.reason)
        }
    }

    /// Contiguous ranges from the same file are one range: a split that removes nothing is a seam on the timeline,
    /// not a cut in the media. Every mode and container plans them as the unsplit range, so the seam needs no
    /// verified boundary and the copy is the one the unsplit range would give.
    public func coalescesAdjacentRanges(in media: MediaInfo, container: String) -> Bool { true }

    private typealias EffectiveRange = (startIndex: Int, endIndex: Int, clip: ClipRequest, info: MediaInfo)

    /// Requested clips after merging contiguous ranges that share decoder state. Indices are one-based.
    private func effectiveRanges(_ clips: [ClipRequest], sequence: [MediaInfo], container: String) -> [EffectiveRange] {
        var effective: [EffectiveRange] = []
        for (offset, pair) in zip(clips, sequence).enumerated() {
            let (request, info) = pair
            let index = offset + 1
            if coalescesAdjacentRanges(in: info, container: container),
               let previous = effective.last, previous.info.url == info.url,
               let seam = previous.clip.to, request.from == seam,
               (previous.clip.from ?? .zero) < seam, seam < (request.to ?? info.duration) {
                effective[effective.count - 1].clip = ClipRequest(file: info.url, from: previous.clip.from, to: request.to)
                effective[effective.count - 1].endIndex = index
            } else {
                effective.append((index, index, request, info))
            }
        }
        return effective
    }

    private func resolveRanges(_ clips: [ClipRequest], sequence: [MediaInfo], uniqueMedia: [MediaInfo],
                               container: String, snap: SnapMode, includeSuggestions: Bool,
                               boundaries: inout BoundaryCache) throws -> ResolvedEdit {
        let effective = effectiveRanges(clips, sequence: sequence, container: container)

        var segments: [ResolvedSegment] = []
        var silentAACSegments: [Int: Int] = [:]
        var audibleAACTracks: Set<Int> = []
        var layerNotes: [String] = []
        var lastVideoDTS: RationalTime?
        let needsMatroskaDTS = uniqueMedia.contains { $0.video.reconstructedDTS }
        let canScheduleVideo = needsMatroskaDTS || (smartTrim && ["mov", "mp4", "m4v"].contains(container)
            && ["h264", "hevc"].contains(sequence[0].video.codec))
        var videoFrameRanges: [Range<Int>] = []
        if canScheduleVideo { videoFrameRanges.reserveCapacity(effective.count) }
        var decodeOverlap = false
        var duration = RationalTime.zero
        for (offset, request) in effective.enumerated() {
            try checkCancellation()
            let (index, endIndex, clip, info) = request
            let first = offset == 0
            let last = offset == effective.count - 1
            let requestedFrom = clip.from ?? .zero
            let requestedTo = clip.to ?? info.duration
            if let audio = info.audio.first(where: {
                !$0.presentationEdits.isEmpty && !supportsAACEdits($0.stream, container: container)
            }) {
                throw CutError(code: "unsupported_container",
                               message: "AAC track \(audio.stream.index) needs MOV or MP4 to preserve its presentation edits.",
                               segment: index, track: audio.stream.index)
            }
            guard requestedFrom < requestedTo else {
                throw CutError(code: "invalid_range", message: "The end must be later than the start.",
                               segment: index)
            }
            guard requestedFrom >= .zero, requestedTo <= info.duration else {
                throw CutError(code: "invalid_range", message: "Choose a nonempty range within the clip.",
                               segment: requestedFrom < .zero ? index : endIndex)
            }

            let startCandidates = try cachedBoundaries(in: info, start: true, first: first, last: last,
                                                       container: container, cache: &boundaries)
            let endCandidates = try cachedBoundaries(in: info, start: false, first: first, last: last,
                                                     container: container, cache: &boundaries)
            let from = try select(requestedFrom, from: startCandidates, snap: snap, segment: index,
                                  field: "from", includeSuggestions: includeSuggestions, eligible: { $0 < requestedTo })
            let to = try select(requestedTo, from: endCandidates, snap: snap, segment: endIndex,
                                field: "to", includeSuggestions: includeSuggestions, eligible: { $0 > from })
            // Smart Trim would have encoded these edges for a picture of one layer. Say why the cut moved instead.
            if from != requestedFrom || to != requestedTo, let note = startCandidates.layerNote ?? endCandidates.layerNote,
               !layerNotes.contains(note) {
                layerNotes.append(note)
            }
            let end = try duration.adding(to.subtracting(from))
            let sourceStart = try info.origin.adding(from)
            _ = try info.origin.adding(to)
            _ = try duration.subtracting(sourceStart)
            let lower = info.frames.lowerBound { $0.time >= from }
            let upper = info.frames.lowerBound { $0.time >= to }
            let retainedFrames = info.frames[lower..<upper]
            if canScheduleVideo { videoFrameRanges.append(retainedFrames.indices) }
            guard let lastFrame = retainedFrames.last else {
                throw CutError(code: "invalid_range", message: "The range does not contain a video frame.", segment: index)
            }
            let matroska = ["mkv", "webm"].contains(container)
            if !matroska, retainedFrames.contains(where: { $0.dts == nil }) {
                throw CutError(code: "unsupported_container",
                               message: "The selected range has missing video decode timestamps that this container requires.",
                               segment: index)
            }
            if matroska || effective.count > 1 {
                let shift = try duration.subtracting(from)
                let millisecond = RationalTime(numerator: 1, denominator: 1_000)
                var minimumDTS: RationalTime?
                var maximumDTS: RationalTime?
                for (frameIndex, frame) in retainedFrames.enumerated() {
                    if frameIndex.isMultiple(of: 1_024) { try checkCancellation() }
                    if matroska && frame.duration < millisecond {
                        // The Matroska and WebM muxers use a millisecond packet clock.
                        let pts = try frame.time.adding(shift)
                        let frameEnd = try pts.adding(frame.duration)
                        guard try frameEnd.roundedToSamples(1_000) > pts.roundedToSamples(1_000) else {
                            throw CutError(code: "unsupported_container",
                                           message: "The output clock cannot represent a video packet at \(frame.time).",
                                           segment: index, track: info.video.index)
                        }
                    }
                    guard effective.count > 1, let dts = frame.dts else { continue }
                    minimumDTS = min(minimumDTS ?? dts, dts)
                    maximumDTS = max(maximumDTS ?? dts, dts)
                }
                if let minimum = minimumDTS, let previous = lastVideoDTS,
                   try minimum.adding(shift) <= previous {
                    if canScheduleVideo {
                        decodeOverlap = true
                    } else {
                        throw CutError(code: "unsafe_boundary", message: "The video decode timestamps overlap at this join.",
                                       segment: index, boundary: "from", nearest: includeSuggestions
                                           ? neighboringBoundaries(around: from, in: startCandidates.times, eligible: { $0 < to })
                                           : nil).because(.joinVideoDTSOverlap)
                    }
                }
                lastVideoDTS = try maximumDTS.map { try $0.adding(shift) } ?? lastVideoDTS
            }
            let whole = first && last && from == .zero && to == info.duration
            let movieOrigin = whole && ["mov", "mp4", "m4v", "3gp", "3g2"].contains(container)
                ? min(.zero, info.audio.lazy.map { $0.stream.hasDeclaredStart ? $0.stream.start : $0.start }.min() ?? .zero)
                : .zero
            let trackStart = try duration.subtracting(movieOrigin)
            let trackEnd = try end.subtracting(movieOrigin)
            let tracks: [ResolvedTrack]
            do {
                tracks = try trackWindows(info, from: from, to: to, outputStart: trackStart, outputEnd: trackEnd,
                                          first: first, last: last, whole: whole, container: container, segment: index,
                                          silentAACSegments: &silentAACSegments, audibleAACTracks: &audibleAACTracks)
            } catch let error as CutError where error.code == "unsafe_boundary" {
                if error.boundary == "from" {
                    let choices = includeSuggestions
                        ? neighboringBoundaries(around: from, in: startCandidates.times, eligible: { $0 < to })
                        : nil
                    throw CutError(code: error.code, message: error.message, segment: index,
                                   boundary: error.boundary, nearest: choices, track: error.track).because(error.reason)
                }
                if error.boundary == "to" {
                    let choices = includeSuggestions
                        ? neighboringBoundaries(around: to, in: endCandidates.times, eligible: { $0 > from })
                        : nil
                    throw CutError(code: error.code, message: error.message, segment: endIndex,
                                   boundary: error.boundary, nearest: choices, track: error.track).because(error.reason)
                }
                throw error
            }
            let edges = smartTrim && smartTrimEligible(in: info, container: container)
                ? try smartTrimEdges(frames: info.frames, kept: lower..<upper, from: from, to: to,
                                     sourceEnd: info.duration, codec: info.video.codec, segment: index)
                : []
            segments.append(ResolvedSegment(file: info.url, from: from, to: to, outputStart: trackStart,
                                            tracks: tracks, sourceOrigin: info.origin, lastVideoFrame: lastFrame.time,
                                            reachesEnd: to == info.duration,
                                            multipleDescriptions: info.video.multipleDescriptions,
                                            sourceClipIndex: index - 1,
                                            sourceClipSeams: clips[(index - 1)..<(endIndex - 1)].compactMap(\.to),
                                            encodedEdges: edges.isEmpty ? nil : edges))
            duration = end
        }

        if canScheduleVideo && (needsMatroskaDTS || decodeOverlap || segments.contains(where: { $0.encodedEdges != nil })) {
            var delay = RationalTime.zero
            for (index, request) in effective.enumerated() {
                let frames = request.info.frames
                let segment = segments[index]
                let kept = frames[videoFrameRanges[index]]
                var decodeTimes = kept.compactMap(\.dts)
                guard decodeTimes.count == kept.count else {
                    throw CutError(code: "unsupported_container", message: "Missing video decode timestamps.", segment: request.startIndex)
                }
                decodeTimes.sort()
                // Leave at least the source decoder's lead at every retained packet slot,
                // including reordered B pictures. Replacing an edge sorts its PTS within
                // those slots. Sorted PTS remain at or after the corresponding sorted DTS.
                var presentationTimes: [RationalTime] = []
                presentationTimes.reserveCapacity(kept.count)
                for (position, pair) in zip(kept, decodeTimes).enumerated() {
                    if position.isMultiple(of: 1_024) { try checkCancellation() }
                    let (picture, dts) = pair
                    delay = max(delay, try picture.time.subtracting(dts))
                    presentationTimes.append(try segment.outputStart.adding(picture.time.subtracting(segment.from)))
                }
                segments[index].videoDecodeTimes = presentationTimes
                try checkCancellation()
            }
            for index in segments.indices {
                if delay != .zero {
                    try segments[index].videoDecodeTimes.withUnsafeMutableBufferPointer { times in
                        for position in times.indices {
                            if position.isMultiple(of: 1_024) { try checkCancellation() }
                            times[position] = try times[position].subtracting(delay)
                        }
                    }
                }
                try checkCancellation()
            }
        }

        for position in silentAACSegments.keys.sorted() where !audibleAACTracks.contains(position) {
            let segment = silentAACSegments[position]!
            let track = sequence[segment - 1].audio[position].stream.index
            throw CutError(code: "unsafe_boundary", message: "AAC track \(track) has no audible samples in the selected ranges.",
                           segment: segment, track: track).because(.cutAACCoverage)
        }
        if let track = sequence[0].streams.first(where: { $0.kind == "data" && $0.codecTag == "tmcd" }) {
            try checkTimecode(segments, duration: duration, container: container, track: track.index)
        }
        var smartTrimNotes: [String] = []
        if segments.contains(where: { $0.encodedEdges != nil }) {
            smartTrimNotes = try checkSmartTrim(segments, clips: effective.map(\.startIndex))
        }
        smartTrimNotes += layerNotes
        for info in uniqueMedia {
            try verifyIdentity(info.url, identity: info.identity)
        }
        var edit = ResolvedEdit(segments: segments, duration: duration, container: container,
                                identities: Dictionary(uniqueKeysWithValues: uniqueMedia.map { ($0.url, $0.identity) }), tracks: tracks)
        edit.smartTrimNotes = smartTrimNotes
        edit.noteAudioJoins(zip(segments, effective).map { AudioJoinNotes.Range(segment: $0, media: $1.info) })
        return edit
    }

    public func export(_ edit: ResolvedEdit, to output: URL,
                       progress: ((Double) -> Bool)? = nil) throws {
        try export(edit, to: output, audioOnly: false, progress: progress)
    }

    func export(_ edit: ResolvedEdit, to output: URL, audioOnly: Bool, programAudio: Bool = false,
                progress: ((Double) -> Bool)? = nil) throws {
        try checkCancellation()
        try checkDestination(output)
        guard output.pathExtension.isEmpty || output.pathExtension.lowercased() == edit.container,
              !edit.segments.isEmpty else {
            throw CutError(code: "invalid_output", message: "The destination must match the resolved edit’s container.")
        }

        for (source, identity) in edit.identities {
            try verifyIdentity(source, identity: identity)
        }
        let destination = output.standardizedFileURL
        let folder = destination.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".mpcut-\(UUID().uuidString)", isDirectory: true)
        let partial = staging.appendingPathComponent("movie").appendingPathExtension(edit.container)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let bridge = ExportProgress { fraction in
            self.cancelled?() != true && (progress?(fraction) ?? true)
        }
        var diagnostic = [CChar](repeating: 0, count: 2048)
        let diagnosticCapacity = diagnostic.count
        let result = try withNativeSegments(edit.segments, useAudioStreamOverride: programAudio || edit.usesPerSourceAudioStream) { buffer in
            withExtendedLifetime(bridge) {
                let selection = programAudio ? Int32(MPCUT_TRACKS_PROGRAM_AUDIO)
                    : audioOnly ? Int32(MPCUT_TRACKS_LINKED_AUDIO) : nativeSelection(edit)
                return edit.stillMasteringDisplay.withUnsafeBufferPointer { mastering in
                    mpcut_write(buffer.baseAddress, buffer.count, partial.path, selection,
                                Int32(edit.audioStream ?? -1), mastering.isEmpty ? nil : mastering.baseAddress,
                                ExportProgress.callback, Unmanaged.passUnretained(bridge).toOpaque(),
                                &diagnostic, diagnosticCapacity)
                }
            }
        }
        if result == 2 { throw cancellationError }
        if result != 0 {
            throw CutError(code: "write_failed", message: String(cString: diagnostic))
        }
        if edit.segments.count == 1, let tracks = edit.segments.first?.tracks,
           tracks.contains(where: { $0.opusPreSkip != nil }) {
            let ends = try tracks.filter { !audioOnly || $0.kind == "audio" }.sorted { $0.index < $1.index }.map { try $0.outputEnd.roundedToSamples(1_000_000_000) }
            guard mpcut_set_matroska_durations(partial.path, ends, ends.count) == 0 else {
                throw CutError(code: "write_failed", message: "Could not finalize the Opus trim’s presentation duration.")
            }
        }
        try checkCancellation()
        for (source, identity) in edit.identities {
            try verifyIdentity(source, identity: identity)
        }
        try checkCancellation()
        let failure = try MediaExportPublication.publish(from: partial, to: destination)
        guard failure == 0 else {
            if failure == EEXIST { throw destinationExists }
            throw CutError(code: "write_failed", message: String(cString: strerror(failure)))
        }
    }

    /// The selection the writer is given for a file a person keeps. A delivered picture is told apart from a staged
    /// picture lane, which carries neither chapters nor timecode.
    private func nativeSelection(_ edit: ResolvedEdit) -> Int32 {
        guard edit.tracks == .video, edit.deliversPicture else { return edit.tracks.native }
        return Int32(edit.keepsTimecode ? MPCUT_TRACKS_DELIVERED_VIDEO_TIMECODE : MPCUT_TRACKS_DELIVERED_VIDEO)
    }

    /// What a packet copy of this edit leaves behind, one sentence each: what its Smart Trim edges lose, found when
    /// the edit was planned, cover art or chapters that the container cannot store, chapters that have no place on the
    /// output timeline, timecode a picture-only copy cannot keep, and HEVC that has to keep an 'hev1' description.
    /// Only file headers are read, except, for HEVC from a source without MOV sample entries copied into MOV or MP4,
    /// the video packets from the start of each source to its latest range start and those of the copied ranges. A
    /// staged picture (a multicam program's lane) reports only the 'hev1' description. A source that cannot be opened
    /// reports nothing here; the export itself reports it.
    public func copyOmissions(_ edit: ResolvedEdit) -> [String] {
        var omissions = edit.smartTrimNotes + edit.audioJoinNotes
        if let issue = edit.timecodeIssue {
            omissions.append("The timecode track is not copied. \(issue)")
        }
        // Room for every note: the writer stops adding notes once the buffer is full.
        var notes = [CChar](repeating: 0, count: 65_536)
        let capacity = notes.count
        let selection = nativeSelection(edit)
        let status = try? withNativeSegments(edit.segments, useAudioStreamOverride: edit.usesPerSourceAudioStream) { buffer in
            mpcut_copy_omissions(buffer.baseAddress, buffer.count, "movie.\(edit.container)", selection,
                                 Int32(edit.audioStream ?? -1), &notes, capacity)
        }
        guard status == 0 else { return omissions }
        return omissions + String(cString: notes).split(separator: "\n").map(String.init)
    }

    /// The refusals a Smart Trim export would otherwise meet only while writing: copied samples whose in-band
    /// parameter sets the rewritten sample entry cannot keep, and edge pictures carrying metadata a re-encode drops.
    /// `clips` gives the first clip number of each segment. Returns what the edges lose without a refusal, one
    /// sentence each: the film grain a player would synthesize on the pictures they replace.
    private func checkSmartTrim(_ segments: [ResolvedSegment], clips: [Int]) throws -> [String] {
        let bridge = ExportProgress { _ in self.cancelled?() != true }
        var failedSegment = 0
        var diagnostic = [CChar](repeating: 0, count: 2048)
        let capacity = diagnostic.count
        // Room for a note on every edge: the writer stops adding notes once the buffer is full.
        var notes = [CChar](repeating: 0, count: 65_536)
        let notesCapacity = notes.count
        let result = try withNativeSegments(segments) { buffer in
            withExtendedLifetime(bridge) {
                mpcut_check_smart_trim(buffer.baseAddress, buffer.count, &failedSegment, ExportProgress.callback,
                                       Unmanaged.passUnretained(bridge).toOpaque(), &diagnostic, capacity,
                                       &notes, notesCapacity)
            }
        }
        if result == 2 { throw cancellationError }
        guard result == 0 else {
            throw CutError(code: "unsupported_format", message: String(cString: diagnostic),
                           segment: clips.indices.contains(failedSegment - 1) ? clips[failedSegment - 1] : nil)
                .because(.sourceSmartIneligible)
        }
        return String(cString: notes).split(separator: "\n").map(String.init)
    }

    /// The same check for camera footage whose Smart Trim edges a still program plans itself, so its dry run refuses
    /// what its export would. `segment` is the one-based camera span reported in a refusal.
    func checkSmartTrim(_ media: MediaInfo, from: RationalTime, to: RationalTime, edges: [EncodedEdge],
                        segment: Int) throws -> [String] {
        guard !edges.isEmpty else { return [] }
        let range = ResolvedSegment(file: media.url, from: from, to: to, outputStart: .zero, tracks: [],
                                    sourceOrigin: media.origin, reachesEnd: to == media.duration, encodedEdges: edges)
        return try checkSmartTrim([range], clips: [segment])
    }

    private func checkTimecode(_ segments: [ResolvedSegment], duration: RationalTime,
                               container: String, track: Int, pictureOnly: Bool = false) throws {
        let bridge = ExportProgress { _ in self.cancelled?() != true }
        let nativeDuration = MPCutTime(numerator: duration.numerator, denominator: duration.denominator)
        var failedSegment = 0
        var diagnostic = [CChar](repeating: 0, count: 2048)
        let capacity = diagnostic.count
        let result = try withNativeSegments(segments) { buffer in
            withExtendedLifetime(bridge) {
                (pictureOnly ? mpcut_check_video_timecode : mpcut_check_timecode)(
                    buffer.baseAddress, buffer.count, nativeDuration, "movie.\(container)",
                    &failedSegment, ExportProgress.callback, Unmanaged.passUnretained(bridge).toOpaque(),
                    &diagnostic, capacity)
            }
        }
        if result == 2 { throw cancellationError }
        guard result == 0 else {
            throw CutError(code: "unsupported_timecode", message: String(cString: diagnostic),
                           segment: failedSegment == 0 ? nil : failedSegment, track: track)
        }
    }

    private func withNativeSegments<Result>(_ segments: [ResolvedSegment], useAudioStreamOverride: Bool = false,
                                            body: (UnsafeBufferPointer<MPCutSegment>) -> Result) throws -> Result {
        let paths = segments.map { segment in
            segment.file.withUnsafeFileSystemRepresentation { path in path.flatMap { strdup($0) } }
        }
        defer { paths.forEach { free($0) } }
        guard paths.allSatisfy({ $0 != nil }) else {
            throw CutError(code: "write_failed", message: "Could not allocate the source file paths.")
        }
        // Only a single continuous range can use a track-wide OpusHead pre-skip.
        let tracks = segments.count == 1 ? segments[0].tracks : []
        var preSkips: [Int32] = []
        for track in tracks {
            guard let skip = track.opusPreSkip else { continue }
            if preSkips.count <= track.index {
                preSkips.append(contentsOf: repeatElement(-1, count: track.index + 1 - preSkips.count))
            }
            preSkips[track.index] = skip
        }
        func nativeTime(_ time: RationalTime) -> MPCutTime {
            MPCutTime(numerator: time.numerator, denominator: time.denominator)
        }
        func nativeEdge(_ edge: EncodedEdge?) -> MPCutEdgeRange {
            guard let edge else { return MPCutEdgeRange() }
            return MPCutEdgeRange(from: nativeTime(edge.from), to: nativeTime(edge.to),
                                  frame_count: edge.frameCount, decode_from: nativeTime(edge.decodeFrom),
                                  target_bit_rate: edge.targetBitRate ?? 0)
        }

        let schedule = segments.flatMap { $0.videoDecodeTimes.map(nativeTime) }
        return schedule.withUnsafeBufferPointer { ticks in
            preSkips.withUnsafeBufferPointer { skips in
                var cursor = 0
                let native = zip(segments, paths).map { segment, path in
                    let count = segment.videoDecodeTimes.count
                    let start = count == 0 ? nil : ticks.baseAddress?.advanced(by: cursor)
                    cursor += count
                    return MPCutSegment(path: UnsafePointer(path), start: nativeTime(segment.wholeAudioOrigin == nil ? segment.from : .zero),
                                        end: nativeTime(segment.wholeAudioOrigin == nil ? segment.to : segment.duration),
                                        last_video_frame: segment.lastVideoFrame.map(nativeTime) ?? MPCutTime(),
                                        reaches_end: segment.reachesEnd ? 1 : 0,
                                        opus_pre_skip: skips.baseAddress, opus_track_count: skips.count,
                                        head_edge: nativeEdge(segment.encodedEdges?.first(where: { $0.from == segment.from })),
                                        tail_edge: nativeEdge(segment.encodedEdges?.last(where: { $0.from != segment.from })),
                                        multiple_descriptions: segment.multipleDescriptions ? 1 : 0,
                                        generated_still: segment.generatedStill ? 1 : 0,
                                        video_dts: start, video_dts_count: count,
                                        source_origin: (segment.wholeAudioOrigin ?? segment.sourceOrigin).map(nativeTime) ?? MPCutTime(),
                                        output_start: nativeTime(segment.outputStart),
                                        audio_stream_override: useAudioStreamOverride && segment.tracks.count == 1 && segment.tracks[0].kind == "audio"
                                            ? UInt32(segment.tracks[0].index) + 1 : 0,
                                        mp3_anchor: segment.tracks.first?.mp3Anchor?.native ?? MPCutMP3Anchor())
                }
                return native.withUnsafeBufferPointer(body)
            }
        }
    }

    func verifyIdentity(_ source: URL, identity: SourceIdentity) throws {
        guard identity.isCurrentSnapshot(at: source) else {
            throw CutError(code: "source_changed", message: "The source changed since inspection: \(source.lastPathComponent)")
        }
    }

    private func singlePacketOpusMuxIssue(_ media: MediaInfo, container: String) -> String? {
        // A single Matroska packet cannot preserve both Opus preskip and tail padding
        // through the muxer's timestamp adjustment. Ogg granule positions retain both.
        if ["mka", "mkv", "webm"].contains(container),
           let track = media.audio.first(where: { audio in
               guard audio.stream.codec == "opus", audio.packets.count == 1,
                     let packet = audio.packets.first else { return false }
               return (packet.skipSamples > 0 || audio.stream.initialPadding > 0) && packet.discardSamples > 0
           }) {
            return "Matroska cannot preserve both leading and trailing trim in the single packet on Opus track \(track.stream.index). Use Ogg Opus for this soundtrack."
        }
        return nil
    }

    private func muxSelection(_ media: MediaInfo) -> (paddedOpus: Int32, tracks: Int32, audioStream: Int32) {
        let paddedOpus = media.audio.first { audio in
            guard matroskaAudioCodec(audio, media: media) == "Opus" else { return false }
            if audio.packets.last?.discardSamples ?? 0 > 0 { return true }
            // MOV derives leading trim from packet PTS. Matroska's CodecDelay
            // can represent samples between ticks of the packet clock.
            let clock = audio.stream.timeBase
            guard clock > .zero else { return true }
            let delay = RationalTime(numerator: Int64(audio.stream.initialPadding), denominator: 48_000)
            let ticks = try? delay.multiplied(by: RationalTime(numerator: clock.denominator, denominator: clock.numerator))
            return ticks?.denominator != 1
        }
        let selection: ExportTracks = media.hasVideo ? tracks : .audio
        let selectedStream = audioTrackOrdinal == nil ? audioStream : media.streams.first?.index
        return (Int32(paddedOpus?.stream.index ?? -1), selection.native, Int32(selectedStream ?? -1))
    }

    private func supportedMuxContainers(_ containers: [String], for media: MediaInfo) -> [String] {
        let eligible = containers.filter { singlePacketOpusMuxIssue(media, container: $0) == nil && audioCodecContainerIssue(media, container: $0) == nil }
        if let reported = media.reportedContainers { return eligible.filter { reported.contains($0) } }
        let candidates = media.hasVideo ? eligible : eligible.filter { audioContainerIssue(media, container: $0) == nil }
        guard !candidates.isEmpty else { return [] }
        let paths = candidates.map { strdup("movie.\($0)") }
        defer { paths.forEach { free($0) } }
        guard paths.allSatisfy({ $0 != nil }) else { return candidates.filter { muxIssue(media, container: $0) == nil } }
        let outputPaths = paths.map { $0.map { UnsafePointer($0) } }
        let selection = muxSelection(media)
        var supported = [UInt8](repeating: 0, count: candidates.count)
        mpcut_check_muxes(media.url.path, outputPaths, outputPaths.count,
                          selection.paddedOpus, selection.tracks, selection.audioStream, &supported)
        return zip(candidates, supported).compactMap { container, accepted in accepted != 0 ? container : nil }
    }

    func muxIssue(_ media: MediaInfo, container: String) -> String? {
        if let issue = singlePacketOpusMuxIssue(media, container: container) { return issue }
        if let issue = audioCodecContainerIssue(media, container: container) { return issue }
        if !media.hasVideo, let issue = audioContainerIssue(media, container: container) { return issue }
        let selection = muxSelection(media)
        var diagnostic = [CChar](repeating: 0, count: 2048)
        let capacity = diagnostic.count
        let result = mpcut_check_mux(media.url.path, "movie.\(container)", selection.paddedOpus,
                                     selection.tracks, selection.audioStream, &diagnostic, capacity)
        return result == 0 ? nil : String(cString: diagnostic)
    }

    private var cancellationError: CutError {
        CutError(code: "cancelled", message: "The operation was cancelled.")
    }

    private func validateMP3Crop(_ audio: AudioIndex, in media: MediaInfo, from: RationalTime, to: RationalTime,
                                segment: Int) throws -> MP3Anchor? {
        let stream = audio.stream
        let start = try media.origin.adding(from).roundedToSamples(stream.sampleRate)
        // Seek before all frames that Xing can hide as decoder preroll.
        let preroll = Int64(MPCUT_MP3_MAX_SKIP)
        var lo = 0, hi = audio.mp3Anchors.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if start >= preroll && audio.mp3Anchors[mid].sample <= start - preroll {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let anchor = lo > 0 ? audio.mp3Anchors[lo - 1] : nil
        let end = try media.origin.adding(to).roundedToSamples(stream.sampleRate)
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        let bridge = ExportProgress { _ in self.cancelled?() != true }
        let result = withExtendedLifetime(bridge) {
            mpcut_check_mp3_crop(media.url.path, Int32(stream.index), start, end, anchor?.native ?? MPCutMP3Anchor(), ExportProgress.callback,
                                 Unmanaged.passUnretained(bridge).toOpaque(), &error, capacity)
        }
        if result == 2 { throw cancellationError }
        try checkCancellation()
        guard result == 0 else {
            throw CutError(code: "unsafe_boundary", message: String(cString: error), segment: segment, track: stream.index)
                .because(.cutMP3Crop)
        }
        return anchor
    }

    func checkCancellation() throws {
        if cancelled?() == true { throw cancellationError }
    }

    private var destinationExists: CutError {
        CutError(code: "output_exists", message: "A file already exists at the destination.")
    }

    package func checkDestination(_ url: URL, plannedSubfolder: URL? = nil) throws {
        guard url.isFileURL, !url.hasDirectoryPath else {
            throw CutError(code: "invalid_output", message: "Choose a local destination file.")
        }
        let destination = url.standardizedFileURL
        var status = stat()
        if lstat(destination.path, &status) == 0 { throw destinationExists }
        let failure = errno
        var parent = destination.deletingLastPathComponent()
        if failure == ENOENT, parent == plannedSubfolder?.standardizedFileURL,
           lstat(parent.path, &status) != 0, errno == ENOENT {
            // The child will be created at write time. Ask the same filesystem about this
            // filename in its existing parent. A file of that name there is unrelated.
            parent = parent.deletingLastPathComponent()
            let probe = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: false)
            guard lstat(probe.path, &status) == 0 || errno == ENOENT else {
                throw CutError(code: "invalid_output", message: "The export filename is unavailable.")
            }
        }
        guard failure == ENOENT, stat(parent.path, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              access(parent.path, W_OK | X_OK) == 0 else {
            throw CutError(code: "invalid_output", message: "The destination folder is unavailable.")
        }
    }
}

private final class ExportProgress {
    let shouldContinue: (Double) -> Bool

    static let callback: MPCutProgress = { context, fraction in
        guard let context else { return 0 }
        let bridge = Unmanaged<ExportProgress>.fromOpaque(context).takeUnretainedValue()
        return bridge.shouldContinue(fraction) ? 0 : 1
    }

    init(_ shouldContinue: @escaping (Double) -> Bool) {
        self.shouldContinue = shouldContinue
    }
}

extension Array {
    package func lowerBound(where isAtOrAboveBoundary: (Element) -> Bool) -> Int {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if isAtOrAboveBoundary(self[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}

extension CutEngine {
    struct BoundaryCache {
        fileprivate var sources: [URL: [BoundaryKey: Boundaries]] = [:]
        // Mux eligibility depends on the source and selected tracks. Range-specific
        // checks still run for every edit, and every use verifies the source identity.
        fileprivate var suggestedContainers: [URL: [MuxKey: [String]]] = [:]
        fileprivate var muxIssues: [URL: [MuxKey: [String: String?]]] = [:]

        mutating func discard(_ url: URL) {
            sources.removeValue(forKey: url)
            suggestedContainers.removeValue(forKey: url)
            muxIssues.removeValue(forKey: url)
        }
    }

    fileprivate struct MuxKey: Hashable {
        let identity: SourceIdentity
        let tracks: ExportTracks
        let audioStream: Int?
        let audioTrackOrdinal: Int?
    }

    fileprivate struct BoundaryKey: Hashable {
        let container: String
        let start: Bool
        let first: Bool
        let last: Bool
    }

    fileprivate struct Boundaries {
        var times: [RationalTime]
        var rejected: [RationalTime: (track: Int, reason: String?)]
        /// True when Smart Trim accepts every frame, so a refused time is off the frame grid.
        var frameAccurate = false
        /// The first frame time, when the source cannot be copied from its beginning.
        var unsafeStart: RationalTime?
        /// Why Smart Trim cuts this source only where every picture layer starts (`smartTrimLayerNote`).
        var layerNote: String?
    }
}

private extension CutEngine {
    func muxKey(_ media: MediaInfo) -> MuxKey {
        MuxKey(identity: media.identity, tracks: tracks, audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal)
    }

    func cachedMuxIssue(_ media: MediaInfo, container: String, cache: inout BoundaryCache) -> String? {
        let key = muxKey(media)
        if let checked = cache.muxIssues[media.url]?[key]?[container] { return checked }
        let issue = muxIssue(media, container: container)
        cache.muxIssues[media.url, default: [:]][key, default: [:]].updateValue(issue, forKey: container)
        return issue
    }

    func cachedBoundaries(in media: MediaInfo, start: Bool, first: Bool, last: Bool,
                          container: String, cache: inout BoundaryCache) throws -> Boundaries {
        let key = BoundaryKey(container: container, start: start, first: first, last: last)
        if let existing = cache.sources[media.url]?[key] { return existing }
        let resolved = try boundarySet(in: media, start: start, first: first, last: last, container: container)
        cache.sources[media.url, default: [:]][key] = resolved
        return resolved
    }

    func boundarySet(in media: MediaInfo, start: Bool, first: Bool, last: Bool,
                     container: String, recordRejections: Bool = true) throws -> Boundaries {
        let frameAccurate = smartTrim && smartTrimEligible(in: media, container: container)
        // The index is already in presentation order, including for sources with B pictures.
        var candidates: [RationalTime] = []
        if frameAccurate || media.video.codec == "prores" { candidates.reserveCapacity(media.frames.count) }
        if start && media.sourceStartSafe, let first = media.frames.first, first.time >= .zero {
            candidates.append(first.time)
        }
        for (index, frame) in media.frames.enumerated() {
            if index.isMultiple(of: 1_024) { try checkCancellation() }
            guard frameAccurate || (start ? frame.canStart : frame.canEnd) else { continue }
            if frame.time > .zero && frame.time < media.duration && candidates.last != frame.time {
                candidates.append(frame.time)
            }
        }
        if !start && media.duration > .zero { candidates.append(media.duration) }
        var rejected: [RationalTime: (track: Int, reason: String?)] = [:]
        for audio in media.audio {
            let track = audio.stream
            var reason: String?
            let accepts: (RationalTime) -> Bool
            let matroskaCodec = matroskaAudioCodec(audio, media: media)
            if let codec = matroskaCodec, start ? !first : !last {
                accepts = { _ in false }
                reason = "\(codec) track \(track.index) requires continuous decoder state across this join. "
                    + "Keep a single continuous range from the source beginning."
            } else if track.isPCM || supportsAACEdits(track, container: container) {
                accepts = { candidate in
                    if first && last && candidate == (start ? .zero : media.duration) { return true }
                    if track.isPCM && !audio.pcmContinuity { return false }
                    if start {
                        return candidate < audio.end && ((track.isPCM && first) || audio.start <= candidate)
                    }
                    if track.isPCM && last { return audio.start < candidate }
                    if candidate <= audio.end { return audio.start < candidate }
                    guard track.sampleRate > 0 else { return false }
                    let sample = RationalTime(numerator: 1, denominator: Int64(track.sampleRate))
                    return (try? audio.end.adding(sample)).map { candidate <= $0 } ?? false
                }
            } else if first && last && supportsOpusTrim(audio, media: media, container: container) {
                let window = audio.opusWindow
                accepts = { candidate in
                    if start && candidate == .zero || !start && candidate == media.duration { return true }
                    guard let sample = try? media.origin.adding(candidate).roundedToSamples(48_000) else { return false }
                    if start { return window?.preSkip(at: sample) != nil }
                    return window?.containsEnd(sample) == true
                }
            } else if start {
                accepts = { first && $0 == .zero }
                if let codec = matroskaCodec {
                    reason = "\(codec) track \(track.index) requires its original decoder start. Keep the source beginning."
                }
            } else {
                var packetEdges = Set<RationalTime>()
                packetEdges.reserveCapacity(audio.packets.count)
                for (index, packet) in audio.packets.enumerated() {
                    if index.isMultiple(of: 1_024) { try checkCancellation() }
                    packetEdges.insert(packet.time)
                }
                accepts = { (last && $0 == media.duration) || packetEdges.contains($0) }
            }
            var index = 0
            try candidates.removeAll { candidate in
                if index.isMultiple(of: 1_024) { try checkCancellation() }
                index += 1
                if accepts(candidate) { return false }
                if recordRejections { rejected[candidate] = (track.index, reason) }
                return true
            }
        }
        return Boundaries(times: candidates, rejected: rejected, frameAccurate: frameAccurate,
                          unsafeStart: start && !media.sourceStartSafe ? media.frames.first?.time ?? .zero : nil,
                          layerNote: smartTrim ? smartTrimLayerNote(in: media) : nil)
    }

    func select(_ requested: RationalTime, from boundaries: Boundaries, snap: SnapMode,
                segment: Int, field: String, includeSuggestions: Bool,
                eligible: (RationalTime) -> Bool) throws -> RationalTime {
        let times = boundaries.times
        let index = times.lowerBound { $0 >= requested }
        if index < times.endIndex, times[index] == requested, eligible(requested) { return requested }

        let choices = includeSuggestions || snap == .nearest
            ? neighboringBoundaries(around: requested, in: times, eligible: eligible) : []
        if snap == .nearest {
            switch choices.count {
            case 1:
                return choices[0]
            case 2:
                let earlier = choices[0]
                let later = choices[1]
                return requested.isCloserToEarlier(earlier, than: later) ? earlier : later
            default: break
            }
        }

        let edge = field == "from" ? "start" : "end"
        let reason: String
        let rejection = boundaries.rejected[requested]
        if let rejection {
            reason = rejection.reason
                ?? "The picture and audio track \(rejection.track) do not share a verified \(edge) boundary at \(requested)."
        } else if let note = boundaries.layerNote, !boundaries.frameAccurate {
            reason = "There is no verified video \(edge) boundary at \(requested). " + note
        } else {
            reason = "There is no verified video \(edge) boundary at \(requested)."
        }
        let factor: TierFactorID
        if let rejection {
            factor = rejection.reason == nil ? .cutAudioPacket : .joinDecoderHistory
        } else if let first = boundaries.unsafeStart, requested <= first {
            factor = .sourceStartUnsafe
        } else if boundaries.frameAccurate {
            factor = .cutOffFrame
        } else {
            factor = field == "from" ? .cutVideoStart : .cutVideoEnd
        }
        throw CutError(code: "unsafe_boundary", message: reason, segment: segment, boundary: field,
                       nearest: choices, track: rejection?.track).because(factor)
    }

    func neighboringBoundaries(around time: RationalTime, in times: [RationalTime],
                               eligible: (RationalTime) -> Bool) -> [RationalTime] {
        let index = times.lowerBound { $0 >= time }
        let before = times[..<index].reversed().first(where: eligible)
        let after = times[index...].first(where: { $0 > time && eligible($0) })
        return [before, after].compactMap { $0 }
    }

}

extension CutEngine {
    func trackWindows(_ media: MediaInfo, from: RationalTime, to: RationalTime,
                      outputStart: RationalTime, outputEnd: RationalTime, first: Bool, last: Bool,
                      whole: Bool, container: String, segment: Int,
                      silentAACSegments: inout [Int: Int], audibleAACTracks: inout Set<Int>) throws -> [ResolvedTrack] {
        var tracks: [ResolvedTrack] = []
        if let video = media.videoStream {
            tracks.append(ResolvedTrack(index: video.index, kind: "video", sourceStart: from, sourceEnd: to,
                                        outputStart: outputStart, outputEnd: outputEnd))
        }
        let reachesAudioEnd = to == media.duration && (media.hasVideo || preservesAudioEnd(media))
        // Output audio tracks are matched by position. Absolute stream indexes can
        // change between files when a selection omits picture or auxiliary streams.
        for (position, audio) in media.audio.enumerated() {
            let track = audio.stream
            var mp3Anchor: MP3Anchor?
            var opusPreSkip: Int32?
            // Reopened crops can contain multiple full packets of hidden decoder history.
            if supportsOpusTrim(audio, media: media, container: container), let packet = audio.packets.first,
               track.initialPadding >= packet.decodedSamples, packet.decodedSamples > 0,
               track.initialPadding <= 65_535, first, last {
                opusPreSkip = Int32(track.initialPadding)
            }
            let sourceStart: RationalTime
            let sourceEnd: RationalTime
            let trackOutputStart: RationalTime
            let trackOutputEnd: RationalTime
            if whole {
                if !audio.presentationEdits.isEmpty && !audio.presentationEdits.contains(where: \.isAudible) {
                    throw CutError(code: "unsafe_boundary", message: "AAC track \(track.index) has no audible samples.",
                                   segment: segment, track: track.index).because(.cutAACCoverage)
                }
                if supportsOpusTrim(audio, media: media, container: container),
                   let window = audio.opusWindow, window.complete {
                    // Preserve the audible end of a cropped final packet when remuxing the entire track.
                    opusPreSkip = Int32(window.initialPadding)
                    sourceStart = try RationalTime(numerator: window.start, denominator: 48_000).subtracting(media.origin)
                    sourceEnd = try RationalTime(numerator: window.end, denominator: 48_000).subtracting(media.origin)
                } else {
                    let span = media.hasVideo ? audio.start...audio.end : try audio.audibleBounds(origin: media.origin)
                    sourceStart = span.lowerBound
                    sourceEnd = span.upperBound
                }
                trackOutputStart = try outputStart.adding(sourceStart)
                trackOutputEnd = try outputStart.adding(sourceEnd)
                if track.codec == "aac" { audibleAACTracks.insert(position) }
            } else if first && last && supportsMP3Crop(track, media: media, container: container) {
                mp3Anchor = try validateMP3Crop(audio, in: media, from: from, to: to, segment: segment)
                sourceStart = from
                sourceEnd = to
                trackOutputStart = outputStart
                trackOutputEnd = outputEnd
            } else if first && last && supportsOpusTrim(audio, media: media, container: container) {
                guard let window = audio.opusWindow, !reachesAudioEnd || window.complete else {
                    throw CutError(code: "unsafe_boundary", message: "Opus track \(track.index) has discontinuous packet timing.",
                                   segment: segment, boundary: "to", track: track.index).because(.cutOpusWindow)
                }
                let endSample = reachesAudioEnd ? window.end : try media.origin.adding(to).roundedToSamples(48_000)
                guard window.containsEnd(endSample) else {
                    throw CutError(code: "unsafe_boundary", message: "Opus track \(track.index) cannot preserve the requested end.",
                                   segment: segment, boundary: "to", track: track.index).because(.cutOpusWindow)
                }
                let startSample = from == .zero ? window.start : try media.origin.adding(from).roundedToSamples(48_000)
                if from != .zero {
                    guard let skip = window.preSkip(at: startSample), startSample < endSample else {
                        throw CutError(code: "unsafe_boundary", message: "Opus track \(track.index) cannot preserve the requested start.",
                                       segment: segment, boundary: "from", track: track.index).because(.cutOpusWindow)
                    }
                    opusPreSkip = skip
                } else {
                    // A tail-only crop also needs its WebM duration corrected for the final packet's padding.
                    opusPreSkip = Int32(window.initialPadding)
                }
                sourceStart = try RationalTime(numerator: startSample, denominator: 48_000).subtracting(media.origin)
                sourceEnd = try RationalTime(numerator: endSample, denominator: 48_000).subtracting(media.origin)
                trackOutputStart = try outputStart.adding(sourceStart.subtracting(from))
                trackOutputEnd = try outputStart.adding(sourceEnd.subtracting(from))
            } else if track.isPCM || supportsAACEdits(track, container: container) {
                let sampleRate = track.sampleRate
                guard sampleRate > 0 else {
                    throw CutError(code: "unsupported_tracks", message: "The audio sample rate is unavailable.",
                                   segment: segment, track: track.index)
                }
                if track.isPCM {
                    let ticksPerSample = try track.timeBase.multiplied(by: RationalTime(numerator: Int64(sampleRate)))
                    if !media.hasVideo && ["mka", "mkv", "webm"].contains(container) {
                        throw CutError(code: "unsupported_container",
                                       message: "Matroska uses a millisecond clock. Choose WAV, AIFF, CAF or MOV for an exact PCM cut.")
                    }
                    guard ticksPerSample.numerator == 1, container == "mov" || !media.hasVideo, audio.pcmContinuity else {
                        throw CutError(code: "unsupported_tracks",
                                       message: "Track \(track.index) needs a sample-accurate PCM clock for this edit.",
                                       segment: segment, track: track.index).because(.cutPCMSampleClock)
                    }
                }
                let startSample = try outputStart.roundedToSamples(sampleRate)
                let endSample = try outputEnd.roundedToSamples(sampleRate)
                let sourceSample = try media.origin.adding(from).roundedToSamples(sampleRate)
                let absoluteTrackStart = try media.origin.adding(audio.start).roundedToSamples(sampleRate)
                let absoluteTrackEnd = try media.origin.adding(audio.end).roundedToSamples(sampleRate)
                let (length, lengthOverflow) = endSample.subtractingReportingOverflow(startSample)
                let (wantedEnd, endOverflow) = sourceSample.addingReportingOverflow(length)
                let (excess, excessOverflow) = wantedEnd.subtractingReportingOverflow(absoluteTrackEnd)
                let allowsLeadingOffset = track.isPCM && first
                let allowsTrailingOffset = track.isPCM && last
                guard !lengthOverflow, !endOverflow, !excessOverflow, length > 0,
                      allowsLeadingOffset || sourceSample >= absoluteTrackStart,
                      allowsTrailingOffset || excess <= 1,
                      max(sourceSample, absoluteTrackStart) < min(wantedEnd, absoluteTrackEnd) else {
                    throw CutError(code: "unsafe_boundary", message: "Audio track \(track.index) does not cover the requested sample interval.",
                                   segment: segment, boundary: sourceSample < absoluteTrackStart ? "from" : "to",
                                   track: track.index).because(track.isPCM ? .cutPCMSampleClock : .cutAACCoverage)
                }
                if supportsAACEdits(track, container: container) {
                    if try checkAACCoverage(audio, origin: media.origin, start: sourceSample,
                                            end: wantedEnd, segment: segment) {
                        audibleAACTracks.insert(position)
                    } else if silentAACSegments[position] == nil {
                        silentAACSegments[position] = segment
                    }
                }
                var sourceAnchor = sourceSample
                let actualEnd = min(wantedEnd, absoluteTrackEnd)
                if track.isPCM && excess == 1 {
                    let declaredStart = try media.origin.adding(track.start).roundedToSamples(sampleRate)
                    let declaredEnd = try media.origin.adding(track.start).adding(track.duration).roundedToSamples(sampleRate)
                    if sourceSample > max(declaredStart, absoluteTrackStart), actualEnd == declaredEnd {
                        sourceAnchor -= 1
                    } else if !allowsTrailingOffset {
                        throw CutError(code: "unsafe_boundary", message: "PCM track \(track.index) cannot cover this cut after sample rounding.",
                                       segment: segment, boundary: "to", track: track.index).because(.cutPCMSampleClock)
                    }
                }
                let firstSample = max(sourceAnchor, absoluteTrackStart)
                sourceStart = try RationalTime(numerator: firstSample, denominator: Int64(sampleRate))
                    .subtracting(media.origin)
                sourceEnd = try RationalTime(numerator: actualEnd, denominator: Int64(sampleRate))
                    .subtracting(media.origin)
                let clock = Int64(sampleRate)
                let outputAnchor = RationalTime(numerator: startSample, denominator: clock)
                let sourceAnchorTime = RationalTime(numerator: sourceAnchor, denominator: clock)
                trackOutputStart = try outputAnchor.adding(
                    RationalTime(numerator: firstSample, denominator: clock).subtracting(sourceAnchorTime)
                )
                trackOutputEnd = try outputAnchor.adding(
                    RationalTime(numerator: actualEnd, denominator: clock).subtracting(sourceAnchorTime)
                )
            } else {
                let keepLeading = first && from == .zero
                let keepTrailing = last && reachesAudioEnd
                var audibleStart: RationalTime?
                var audibleEnd: RationalTime?
                let lower = keepLeading ? 0 : audio.packets.lowerBound { $0.time >= from }
                let upper = keepTrailing ? audio.packets.count : audio.packets.lowerBound { $0.time >= to }
                for (index, packet) in audio.packets[lower..<upper].enumerated() {
                    if index.isMultiple(of: 1_024) { try checkCancellation() }
                    let packetEnd = try packet.time.adding(packet.duration)
                    if !keepTrailing && (packetEnd > to || packet.discardSamples > 0) {
                        throw CutError(code: "unsafe_boundary", message: "The end crosses a compressed audio packet or its padding.",
                                       segment: segment, boundary: "to", track: track.index).because(.cutAudioPacket)
                    }
                    if !keepLeading && packet.skipSamples > 0 {
                        throw CutError(code: "unsafe_boundary", message: "The start crosses compressed audio priming.",
                                       segment: segment, boundary: "from", track: track.index).because(.cutAudioPriming)
                    }
                    // The first Vorbis packet initializes the overlap window but yields no PCM.
                    if track.codec == "vorbis" && lower == 0 && index == 0 { continue }
                    guard track.sampleRate > 0 else { continue }
                    let clock = Int64(track.sampleRate)
                    let start = try packet.time.adding(RationalTime(numerator: Int64(packet.skipSamples), denominator: clock))
                    let decodedDuration = packet.decodedSamples > 0
                        ? RationalTime(numerator: Int64(packet.decodedSamples), denominator: clock) : packet.duration
                    let audiblePacketEnd = try packet.time.adding(decodedDuration)
                        .subtracting(RationalTime(numerator: Int64(packet.discardSamples), denominator: clock))
                    let end = min(packetEnd, audiblePacketEnd)
                    if start < end {
                        audibleStart = min(audibleStart ?? start, start)
                        audibleEnd = max(audibleEnd ?? end, end)
                    }
                }
                guard let audibleStart, let audibleEnd, max(audibleStart, audio.start) < min(audibleEnd, audio.end) else {
                    throw CutError(code: "unsafe_boundary", message: "The range contains no audible compressed audio packets.",
                                   segment: segment, boundary: "to", track: track.index).because(.cutAudioPacket)
                }
                sourceStart = max(audibleStart, audio.start)
                sourceEnd = min(audibleEnd, audio.end)
                trackOutputStart = try outputStart.adding(sourceStart.subtracting(from))
                trackOutputEnd = try outputStart.adding(sourceEnd.subtracting(from))
            }
            tracks.append(ResolvedTrack(index: track.index, kind: "audio", sourceStart: sourceStart,
                                        sourceEnd: sourceEnd, outputStart: trackOutputStart,
                                        outputEnd: trackOutputEnd, mp3Anchor: mp3Anchor, opusPreSkip: opusPreSkip))
        }
        return tracks
    }

    func checkAACCoverage(_ audio: AudioIndex, origin: RationalTime, start: Int64, end: Int64,
                          segment: Int) throws -> Bool {
        let rate = audio.stream.sampleRate
        func discontinuity(_ covered: Int64) -> CutError {
            CutError(code: "unsafe_boundary",
                     message: "AAC track \(audio.stream.index) has discontinuous or invalid timing around this cut.",
                     segment: segment, boundary: covered == start ? "from" : "to", track: audio.stream.index)
                .because(.cutAACCoverage)
        }
        if !audio.presentationEdits.isEmpty {
            var covered = start
            var audible = false
            let lower = audio.presentationEdits.lowerBound { $0.samples.upperBound > start }
            for index in lower..<audio.presentationEdits.count {
                if index.isMultiple(of: 1_024) { try checkCancellation() }
                let edit = audio.presentationEdits[index]
                guard edit.samples.lowerBound <= covered else { throw discontinuity(covered) }
                audible = audible || edit.isAudible
                covered = edit.samples.upperBound
                if covered >= end || (index == audio.presentationEdits.count - 1 && covered == end - 1) {
                    return audible
                }
            }
            throw discontinuity(covered)
        }
        let (prerollStart, prerollOverflow) = start.subtractingReportingOverflow(2_048)
        var nextSample: Int64?
        var covered = start
        let prerollTime = try RationalTime(numerator: prerollOverflow ? start : prerollStart,
                                          denominator: Int64(rate)).subtracting(origin)
        let lower = max(0, audio.packets.lowerBound { $0.time >= prerollTime } - 1)
        for (index, packet) in audio.packets[lower...].enumerated() {
            if index.isMultiple(of: 1_024) { try checkCancellation() }
            let first = try origin.adding(packet.time).roundedToSamples(rate)
            if first >= end { break }
            let length = packet.decodedSamples > 0 ? Int64(packet.decodedSamples)
                : try packet.duration.roundedToSamples(rate)
            let (last, overflow) = first.addingReportingOverflow(length)
            guard !overflow else { throw discontinuity(covered) }
            if !prerollOverflow && last <= prerollStart { continue }
            guard packet.dts == packet.time, length > 0, nextSample == nil || nextSample == first else {
                throw discontinuity(covered)
            }
            nextSample = last
            let audibleFirst = first + min(length, Int64(packet.skipSamples))
            let audibleEnd = last - min(length, Int64(packet.discardSamples))
            if audibleFirst < audibleEnd && audibleEnd > start {
                guard audibleFirst <= covered else { throw discontinuity(covered) }
                covered = max(covered, audibleEnd)
            }
        }
        guard covered > start, covered >= end - 1 else { throw discontinuity(covered) }
        return true
    }
}

extension CutEngine {
    /// Every cut of a picture timeline that this engine does not accept as requested, without stopping at the first.
    /// The planner's verdict decides whether the timeline is written. This lists the cuts for people, up to `limit`,
    /// with the boundary sets and the selection the planner itself uses, in the container it reports its failure for.
    func boundaryIssues(_ clips: [ClipRequest], media: [URL: MediaInfo], boundaries: inout BoundaryCache,
                        limit: Int) -> (issues: [CutError], total: Int, container: String?) {
        var sequence: [MediaInfo] = []
        for clip in clips {
            let file = clip.file.standardizedFileURL
            guard let cached = media[file], cached.url == file, cached.hasFullEditIndex,
                  let info = try? selectedMedia(cached), info.copyIssue == nil, info.hasVideo else { return ([], 0, nil) }
            sequence.append(info)
        }
        guard let first = sequence.first else { return ([], 0, nil) }
        let original = media[first.url] ?? first
        let key = muxKey(original)
        let supported = boundaries.suggestedContainers[original.url]?[key] ?? suggestedContainers(for: original)
        boundaries.suggestedContainers[original.url, default: [:]][key] = supported
        guard let container = editContainers(supported, for: original, clips: clips).first else { return ([], 0, nil) }
        let effective = effectiveRanges(clips, sequence: sequence, container: container)
        var issues: [CutError] = []
        var total = 0
        for (offset, range) in effective.enumerated() {
            if cancelled?() == true { break }
            let (index, endIndex, clip, info) = range
            let from = clip.from ?? .zero, to = clip.to ?? info.duration
            guard from >= .zero, from < to, to <= info.duration else { continue }
            for start in [true, false] {
                do {
                    let set = try cachedBoundaries(in: info, start: start, first: offset == 0, last: offset == effective.count - 1,
                                                   container: container, cache: &boundaries)
                    _ = try select(start ? from : to, from: set, snap: .exact, segment: start ? index : endIndex,
                                   field: start ? "from" : "to", includeSuggestions: total < limit,
                                   eligible: { start ? $0 < to : $0 > from })
                } catch let issue as CutError where issue.code == "unsafe_boundary" {
                    total += 1
                    if issues.count < limit { issues.append(issue) }
                } catch {
                    return (issues, total, container)
                }
            }
        }
        return (issues, total, container)
    }
}
