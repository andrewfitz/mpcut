import Darwin
import Foundation
import PacketWriter

public struct CutEngine: Sendable {
    private let cancelled: (@Sendable () -> Bool)?

    public init(cancelled: (@Sendable () -> Bool)? = nil) {
        self.cancelled = cancelled
    }

    public func inspect(_ file: URL, keyframes: Bool = false) throws -> MediaInfo {
        try checkCancellation()
        guard file.isFileURL else {
            throw CutError(code: "invalid_input", message: "Choose a local video file.")
        }
        return try Probe.read(file.standardizedFileURL, keyframes: keyframes, cancelled: cancelled)
    }

    public func checkCompatibility(_ media: MediaInfo, with reference: MediaInfo) throws {
        let presentVideo = media.video
        let referenceVideo = reference.video

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
        try match("alpha depth", presentVideo.alphaBits, referenceVideo.alphaBits)
        try match("color primaries", presentVideo.colorPrimaries, referenceVideo.colorPrimaries)
        try match("transfer function", presentVideo.colorTransfer, referenceVideo.colorTransfer)
        try match("color matrix", presentVideo.colorMatrix, referenceVideo.colorMatrix)
        try match("color range", presentVideo.colorRange, referenceVideo.colorRange)
        try matchMetadata("video side data", presentVideo.codecMetadata, referenceVideo.codecMetadata)
        try matchMetadata("video codec configuration", presentVideo.configuration, referenceVideo.configuration)

        func layout(_ media: MediaInfo) -> [String] {
            media.streams.map { "\($0.kind)/\($0.kind == "data" ? $0.codecTag : $0.codec)" }
        }
        try match("track layout", layout(media), layout(reference))
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
            try match("\(label) codec", present.codec, expected.codec)
            try match("\(label) profile", present.profile, expected.profile)
            try match("\(label) sample rate", present.sampleRate, expected.sampleRate)
            try match("\(label) channel count", present.channels, expected.channels)
            try match("\(label) channel layout", present.channelLayout, expected.channelLayout)
            try matchMetadata("\(label) codec configuration", present.configuration, expected.configuration)
            try matchMetadata("\(label) side data", present.codecMetadata, expected.codecMetadata)
        }
    }

    public func suggestedContainers(for media: MediaInfo) -> [String] {
        guard media.copyIssue == nil else { return [] }
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
        return probeOrder.filter { container in
            !container.isEmpty && considered.insert(container).inserted &&
                media.audio.allSatisfy { $0.presentationEdits.isEmpty || supportsAACEdits($0.stream, container: container) } &&
                muxIssue(media.url, container: container) == nil
        }
    }

    public func validBoundaries(in media: MediaInfo, start: Bool, first: Bool = true,
                                last: Bool = true, container: String? = nil) -> [RationalTime] {
        let effectiveContainer = container ?? suggestedContainers(for: media).first
            ?? media.url.pathExtension.lowercased()
        return boundarySet(in: media, start: start, first: first, last: last, container: effectiveContainer).times
    }

    public func resolve(_ clips: [ClipRequest], output: URL? = nil, snap: SnapMode = .exact,
                        media: [URL: MediaInfo] = [:], container requestedContainer: String? = nil) throws -> ResolvedEdit {
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
            let info: MediaInfo
            do {
                if let cached = indexed[file], cached.url == file, !cached.frames.isEmpty {
                    if firstOccurrence[file] == nil {
                        try verifyIdentity(file, identity: cached.identity)
                    }
                    info = cached
                } else {
                    info = try inspect(file, keyframes: true)
                    indexed[file] = info
                }
                if let issue = info.copyIssue {
                    throw CutError(code: "unsupported_tracks", message: issue)
                }
                if firstOccurrence[file] == nil, let reference = sequence.first {
                    try checkCompatibility(info, with: reference)
                }
            } catch let issue as CutError {
                if issue.code == "cancelled" { throw issue }
                throw CutError(code: issue.code, message: issue.message, segment: index + 1,
                               boundary: issue.boundary, nearest: issue.nearest, track: issue.track)
            }
            if firstOccurrence[file] == nil {
                firstOccurrence[file] = index + 1
                uniqueMedia.append(info)
            }
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
                if let issue = muxIssue(info.url, container: explicit) {
                    throw CutError(code: "unsupported_container", message: issue,
                                   segment: firstOccurrence[info.url])
                }
            }
            return try resolveSequence(clips, sequence: sequence, uniqueMedia: uniqueMedia,
                                       container: explicit, snap: snap)
        }

        var defaultFailure: CutError?
        for candidate in suggestedContainers(for: sequence[0]) {
            try checkCancellation()
            if !uniqueMedia.dropFirst().allSatisfy({ muxIssue($0.url, container: candidate) == nil }) {
                continue
            }
            do {
                return try resolveSequence(clips, sequence: sequence, uniqueMedia: uniqueMedia,
                                           container: candidate, snap: snap)
            } catch let error as CutError {
                if error.code == "cancelled" || error.code == "source_changed" { throw error }
                if defaultFailure == nil { defaultFailure = error }
            }
        }
        throw defaultFailure ?? CutError(code: "unsupported_container",
                                         message: "No available container can carry every clip.")
    }

    private func resolveSequence(_ clips: [ClipRequest], sequence: [MediaInfo], uniqueMedia: [MediaInfo],
                                 container: String, snap: SnapMode) throws -> ResolvedEdit {
        var boundaries: [BoundaryKey: Boundaries] = [:]
        do {
            return try resolveRanges(clips, sequence: sequence, uniqueMedia: uniqueMedia,
                                     container: container, snap: snap, includeSuggestions: true, boundaries: &boundaries)
        } catch let failure as CutError {
            guard let segment = failure.segment, clips.indices.contains(segment - 1),
                  let field = failure.boundary, field == "from" || field == "to",
                  let options = failure.nearest, !options.isEmpty else { throw failure }

            let original = clips[segment - 1]
            var verified: [(time: RationalTime, edit: ResolvedEdit)] = []
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
                } catch let error as CutError where error.code == "cancelled" || error.code == "source_changed" {
                    throw error
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
                           nearest: verified.map(\.time), track: failure.track)
        }
    }

    private func resolveRanges(_ clips: [ClipRequest], sequence: [MediaInfo], uniqueMedia: [MediaInfo],
                               container: String, snap: SnapMode, includeSuggestions: Bool,
                               boundaries: inout [BoundaryKey: Boundaries]) throws -> ResolvedEdit {
        let requests = zip(clips, sequence).enumerated().map { ($0.offset + 1, $0.element.0, $0.element.1) }
        var effective: [(startIndex: Int, endIndex: Int, clip: ClipRequest, info: MediaInfo)] = []
        for (index, request, info) in requests {
            let mayCoalesce = container == "webm" || (container == "mkv" &&
                info.audio.contains(where: { matroskaAudioCodec($0, media: info) != nil }))
            if mayCoalesce,
               let previous = effective.last, previous.info.url == info.url,
               let seam = previous.clip.to, request.from == seam,
               (previous.clip.from ?? .zero) < seam, seam < (request.to ?? info.duration) {
                effective[effective.count - 1].clip = ClipRequest(file: info.url, from: previous.clip.from, to: request.to)
                effective[effective.count - 1].endIndex = index
            } else {
                effective.append((index, index, request, info))
            }
        }

        var segments: [ResolvedSegment] = []
        var silentAACSegments: [Int: Int] = [:]
        var audibleAACTracks: Set<Int> = []
        var lastVideoDTS: RationalTime?
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

            let startCandidates = cachedBoundaries(in: info, start: true, first: first, last: last,
                                                   container: container, cache: &boundaries)
            let endCandidates = cachedBoundaries(in: info, start: false, first: first, last: last,
                                                 container: container, cache: &boundaries)
            let from = try select(requestedFrom, from: startCandidates, snap: snap, segment: index,
                                  field: "from", includeSuggestions: includeSuggestions, eligible: { $0 < requestedTo })
            let to = try select(requestedTo, from: endCandidates, snap: snap, segment: endIndex,
                                field: "to", includeSuggestions: includeSuggestions, eligible: { $0 > from })
            let end = try duration.adding(to.subtracting(from))
            let sourceStart = try info.origin.adding(from)
            _ = try info.origin.adding(to)
            _ = try duration.subtracting(sourceStart)
            let lower = info.frames.lowerBound { $0.time >= from }
            let upper = info.frames.lowerBound { $0.time >= to }
            let retainedFrames = info.frames[lower..<upper]
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
                    throw CutError(code: "unsafe_boundary", message: "The video decode timestamps overlap at this join.",
                                   segment: index, boundary: "from",
                                   nearest: includeSuggestions
                                       ? neighboringBoundaries(around: from, in: startCandidates.times, eligible: { $0 < to })
                                       : nil)
                }
                lastVideoDTS = try maximumDTS.map { try $0.adding(shift) } ?? lastVideoDTS
            }
            let whole = first && last && from == .zero && to == info.duration
            let movieOrigin = whole && ["mov", "mp4", "m4v", "3gp", "3g2"].contains(container)
                ? min(.zero, info.audio.lazy.filter { $0.stream.hasDeclaredStart }.map { $0.stream.start }.min() ?? .zero)
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
                                   boundary: error.boundary, nearest: choices, track: error.track)
                }
                if error.boundary == "to" {
                    let choices = includeSuggestions
                        ? neighboringBoundaries(around: to, in: endCandidates.times, eligible: { $0 > from })
                        : nil
                    throw CutError(code: error.code, message: error.message, segment: endIndex,
                                   boundary: error.boundary, nearest: choices, track: error.track)
                }
                throw error
            }
            segments.append(ResolvedSegment(file: info.url, from: from, to: to, outputStart: trackStart,
                                            tracks: tracks, lastVideoFrame: lastFrame.time, reachesEnd: to == info.duration))
            duration = end
        }

        for track in silentAACSegments.keys.sorted() where !audibleAACTracks.contains(track) {
            throw CutError(code: "unsafe_boundary", message: "AAC track \(track) has no audible samples in the selected ranges.",
                           segment: silentAACSegments[track], track: track)
        }
        if let track = sequence[0].streams.first(where: { $0.kind == "data" && $0.codecTag == "tmcd" }) {
            try checkTimecode(segments, duration: duration, container: container, track: track.index)
        }
        for info in uniqueMedia {
            try verifyIdentity(info.url, identity: info.identity)
        }
        return ResolvedEdit(segments: segments, duration: duration, container: container,
                            identities: Dictionary(uniqueKeysWithValues: uniqueMedia.map { ($0.url, $0.identity) }))
    }

    public func export(_ edit: ResolvedEdit, to output: URL,
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
        let result = try withNativeSegments(edit.segments) { buffer in
            withExtendedLifetime(bridge) {
                mpcut_write(buffer.baseAddress, buffer.count, partial.path, ExportProgress.callback,
                            Unmanaged.passUnretained(bridge).toOpaque(), &diagnostic, diagnosticCapacity)
            }
        }
        if result == 2 { throw cancellationError }
        if result != 0 {
            throw CutError(code: "write_failed", message: String(cString: diagnostic))
        }
        try checkCancellation()
        for (source, identity) in edit.identities {
            try verifyIdentity(source, identity: identity)
        }
        guard renamex_np(partial.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw destinationExists }
            throw CutError(code: "write_failed", message: String(cString: strerror(errno)))
        }
    }

    private func checkTimecode(_ segments: [ResolvedSegment], duration: RationalTime,
                               container: String, track: Int) throws {
        let bridge = ExportProgress { _ in self.cancelled?() != true }
        let nativeDuration = MPCutTime(numerator: duration.numerator, denominator: duration.denominator)
        var failedSegment = 0
        var diagnostic = [CChar](repeating: 0, count: 2048)
        let capacity = diagnostic.count
        let result = try withNativeSegments(segments) { buffer in
            withExtendedLifetime(bridge) {
                mpcut_check_timecode(buffer.baseAddress, buffer.count, nativeDuration, "movie.\(container)",
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

    private func withNativeSegments<Result>(_ segments: [ResolvedSegment],
                                            body: (UnsafeBufferPointer<MPCutSegment>) -> Result) throws -> Result {
        let paths = segments.map { segment in
            segment.file.withUnsafeFileSystemRepresentation { path in path.flatMap { strdup($0) } }
        }
        defer { paths.forEach { free($0) } }
        guard paths.allSatisfy({ $0 != nil }) else {
            throw CutError(code: "write_failed", message: "Could not allocate the source file paths.")
        }
        let native = zip(segments, paths).map { segment, path in
            MPCutSegment(path: UnsafePointer(path),
                         start: MPCutTime(numerator: segment.from.numerator, denominator: segment.from.denominator),
                         end: MPCutTime(numerator: segment.to.numerator, denominator: segment.to.denominator),
                         last_video_frame: MPCutTime(numerator: segment.lastVideoFrame?.numerator ?? 0,
                                                      denominator: segment.lastVideoFrame?.denominator ?? 0),
                         reaches_end: segment.reachesEnd ? 1 : 0)
        }
        return native.withUnsafeBufferPointer(body)
    }

    private func verifyIdentity(_ source: URL, identity: SourceIdentity) throws {
        guard (try? SourceIdentity(source)) == identity else {
            throw CutError(code: "source_changed", message: "The source changed since inspection: \(source.lastPathComponent)")
        }
    }

    private func muxIssue(_ input: URL, container: String) -> String? {
        var diagnostic = [CChar](repeating: 0, count: 2048)
        let capacity = diagnostic.count
        let result = mpcut_check_mux(input.path, "movie.\(container)", &diagnostic, capacity)
        return result == 0 ? nil : String(cString: diagnostic)
    }

    private var cancellationError: CutError {
        CutError(code: "cancelled", message: "The operation was cancelled.")
    }

    private func checkCancellation() throws {
        if cancelled?() == true { throw cancellationError }
    }

    private var destinationExists: CutError {
        CutError(code: "output_exists", message: "A file already exists at the destination.")
    }

    private func checkDestination(_ url: URL) throws {
        guard url.isFileURL, !url.hasDirectoryPath else {
            throw CutError(code: "invalid_output", message: "Choose a local destination file.")
        }
        let destination = url.standardizedFileURL
        var status = stat()
        if lstat(destination.path, &status) == 0 { throw destinationExists }
        let failure = errno
        guard failure == ENOENT,
              stat(destination.deletingLastPathComponent().path, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
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

private extension Array {
    func lowerBound(where isAtOrAboveBoundary: (Element) -> Bool) -> Int {
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

private extension CutEngine {
    struct BoundaryKey: Hashable {
        let url: URL
        let start: Bool
        let first: Bool
        let last: Bool
    }

    struct Boundaries {
        var times: [RationalTime]
        var rejected: [RationalTime: (track: Int, reason: String?)]
    }

    func cachedBoundaries(in media: MediaInfo, start: Bool, first: Bool, last: Bool,
                          container: String, cache: inout [BoundaryKey: Boundaries]) -> Boundaries {
        let key = BoundaryKey(url: media.url, start: start, first: first, last: last)
        if let existing = cache[key] { return existing }
        let resolved = boundarySet(in: media, start: start, first: first, last: last, container: container)
        cache[key] = resolved
        return resolved
    }

    func boundarySet(in media: MediaInfo, start: Bool, first: Bool, last: Bool,
                     container: String) -> Boundaries {
        var candidates = Set(media.frames.filter { start ? $0.canStart : $0.canEnd }.map(\.time))
        candidates = candidates.filter { .zero < $0 && $0 < media.duration }
        if start && media.sourceStartSafe { candidates.insert(.zero) }
        if !start && media.duration > .zero { candidates.insert(media.duration) }
        var rejected: [RationalTime: (track: Int, reason: String?)] = [:]
        for audio in media.audio {
            let track = audio.stream
            let before = candidates
            var reason: String?
            let matroskaCodec = matroskaAudioCodec(audio, media: media)
            if let codec = matroskaCodec, start ? !first : !last {
                candidates.removeAll()
                reason = "\(codec) track \(track.index) requires continuous decoder state across this join. "
                    + "Keep a single continuous range from the source beginning."
            } else if track.isPCM || supportsAACEdits(track, container: container) {
                candidates = candidates.filter { candidate in
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
            } else if !start && first && last && supportsOpusPrefix(audio, media: media, container: container) {
                let window = opusPrefixWindow(audio, origin: media.origin)
                candidates = candidates.filter { candidate in
                    if candidate == media.duration { return true }
                    guard let sample = try? media.origin.adding(candidate).roundedToSamples(48_000) else { return false }
                    return window?.containsEnd(sample) == true
                }
            } else if start {
                candidates = candidates.filter { first && $0 == .zero }
                if let codec = matroskaCodec {
                    reason = "\(codec) track \(track.index) requires its original decoder start. Keep the source beginning."
                }
            } else {
                let packetEdges = Set(audio.packets.map(\.time))
                candidates = candidates.filter {
                    (last && $0 == media.duration) || packetEdges.contains($0)
                }
            }
            for rejectedTime in before.subtracting(candidates) { rejected[rejectedTime] = (track.index, reason) }
        }
        return Boundaries(times: candidates.sorted(), rejected: rejected)
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

        let reason: String
        let rejection = boundaries.rejected[requested]
        if let rejection {
            reason = rejection.reason
                ?? "The picture and audio track \(rejection.track) do not share a verified \(field) boundary at \(requested)."
        } else {
            reason = "There is no verified video \(field) boundary at \(requested)."
        }
        throw CutError(code: "unsafe_boundary", message: reason, segment: segment, boundary: field,
                       nearest: choices, track: rejection?.track)
    }

    func neighboringBoundaries(around time: RationalTime, in times: [RationalTime],
                               eligible: (RationalTime) -> Bool) -> [RationalTime] {
        let index = times.lowerBound { $0 >= time }
        let before = times[..<index].reversed().first(where: eligible)
        let after = times[index...].first(where: { $0 > time && eligible($0) })
        return [before, after].compactMap { $0 }
    }

    func supportsAACEdits(_ track: StreamInfo, container: String) -> Bool {
        track.codec == "aac" && ["mov", "mp4", "m4v"].contains(container)
    }

    func trackWindows(_ media: MediaInfo, from: RationalTime, to: RationalTime,
                      outputStart: RationalTime, outputEnd: RationalTime, first: Bool, last: Bool,
                      whole: Bool, container: String, segment: Int,
                      silentAACSegments: inout [Int: Int], audibleAACTracks: inout Set<Int>) throws -> [ResolvedTrack] {
        var tracks: [ResolvedTrack] = [
            ResolvedTrack(index: media.video.index, kind: "video", sourceStart: from, sourceEnd: to,
                          outputStart: outputStart, outputEnd: outputEnd)
        ]
        for audio in media.audio {
            let track = audio.stream
            let sourceStart: RationalTime
            let sourceEnd: RationalTime
            let trackOutputStart: RationalTime
            let trackOutputEnd: RationalTime
            if whole {
                if !audio.presentationEdits.isEmpty && !audio.presentationEdits.contains(where: \.isAudible) {
                    throw CutError(code: "unsafe_boundary", message: "AAC track \(track.index) has no audible samples.",
                                   segment: segment, track: track.index)
                }
                if supportsOpusPrefix(audio, media: media, container: container),
                   let window = opusPrefixWindow(audio, origin: media.origin), window.complete {
                    sourceStart = try RationalTime(numerator: window.start, denominator: 48_000).subtracting(media.origin)
                    sourceEnd = try RationalTime(numerator: window.end, denominator: 48_000).subtracting(media.origin)
                } else {
                    sourceStart = audio.start
                    sourceEnd = audio.end
                }
                trackOutputStart = try outputStart.adding(sourceStart)
                trackOutputEnd = try outputStart.adding(sourceEnd)
                if track.codec == "aac" { audibleAACTracks.insert(track.index) }
            } else if first && last && from == .zero && supportsOpusPrefix(audio, media: media, container: container) {
                let endSample = try media.origin.adding(to).roundedToSamples(48_000)
                guard let window = opusPrefixWindow(audio, origin: media.origin), window.containsEnd(endSample) else {
                    throw CutError(code: "unsafe_boundary", message: "Opus track \(track.index) cannot preserve the requested prefix.",
                                   segment: segment, boundary: "to", track: track.index)
                }
                sourceStart = try RationalTime(numerator: window.start, denominator: 48_000).subtracting(media.origin)
                sourceEnd = try RationalTime(numerator: endSample, denominator: 48_000).subtracting(media.origin)
                trackOutputStart = try outputStart.adding(sourceStart)
                trackOutputEnd = try outputStart.adding(sourceEnd)
            } else if track.isPCM || supportsAACEdits(track, container: container) {
                let sampleRate = track.sampleRate
                guard sampleRate > 0 else {
                    throw CutError(code: "unsupported_tracks", message: "The audio sample rate is unavailable.",
                                   segment: segment, track: track.index)
                }
                if track.isPCM {
                    let ticksPerSample = try track.timeBase.multiplied(by: RationalTime(numerator: Int64(sampleRate)))
                    guard ticksPerSample.numerator == 1, container == "mov", audio.pcmContinuity else {
                        throw CutError(code: "unsupported_tracks",
                                       message: "Track \(track.index) needs a sample-accurate PCM clock for this edit.",
                                       segment: segment, track: track.index)
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
                                   track: track.index)
                }
                if supportsAACEdits(track, container: container) {
                    if try checkAACCoverage(audio, origin: media.origin, start: sourceSample,
                                            end: wantedEnd, segment: segment) {
                        audibleAACTracks.insert(track.index)
                    } else if silentAACSegments[track.index] == nil {
                        silentAACSegments[track.index] = segment
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
                                       segment: segment, boundary: "to", track: track.index)
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
                let keepTrailing = last && to == media.duration
                var audibleStart: RationalTime?
                var audibleEnd: RationalTime?
                for (index, packet) in audio.packets.enumerated() {
                    if index.isMultiple(of: 1_024) { try checkCancellation() }
                    if (!keepLeading && packet.time < from) || (!keepTrailing && packet.time >= to) { continue }
                    let packetEnd = try packet.time.adding(packet.duration)
                    if !keepTrailing && (packetEnd > to || packet.discardSamples > 0) {
                        throw CutError(code: "unsafe_boundary", message: "The end crosses a compressed audio packet or its padding.",
                                       segment: segment, boundary: "to", track: track.index)
                    }
                    if !keepLeading && packet.skipSamples > 0 {
                        throw CutError(code: "unsafe_boundary", message: "The start crosses compressed audio priming.",
                                       segment: segment, boundary: "from", track: track.index)
                    }
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
                guard let audibleStart, let audibleEnd else {
                    throw CutError(code: "unsafe_boundary", message: "The range contains no audible compressed audio packets.",
                                   segment: segment, boundary: "to", track: track.index)
                }
                sourceStart = audibleStart
                sourceEnd = audibleEnd
                trackOutputStart = try outputStart.adding(sourceStart.subtracting(from))
                trackOutputEnd = try outputStart.adding(sourceEnd.subtracting(from))
            }
            tracks.append(ResolvedTrack(index: track.index, kind: "audio", sourceStart: sourceStart,
                                        sourceEnd: sourceEnd, outputStart: trackOutputStart,
                                        outputEnd: trackOutputEnd))
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
        }
        if !audio.presentationEdits.isEmpty {
            var covered = start
            var audible = false
            for (index, edit) in audio.presentationEdits.enumerated() {
                if index.isMultiple(of: 1_024) { try checkCancellation() }
                if edit.samples.upperBound <= covered { continue }
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
        for (index, packet) in audio.packets.enumerated() {
            if index.isMultiple(of: 1_024) { try checkCancellation() }
            let first = try origin.adding(packet.time).roundedToSamples(rate)
            let length = packet.decodedSamples > 0 ? Int64(packet.decodedSamples)
                : try packet.duration.roundedToSamples(rate)
            let (last, overflow) = first.addingReportingOverflow(length)
            guard !overflow else { throw discontinuity(covered) }
            if (!prerollOverflow && last <= prerollStart) || first >= end { continue }
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
