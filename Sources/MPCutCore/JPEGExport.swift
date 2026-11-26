import CoreImage
import Darwin
import Foundation
import ImageIO
import MediaProbe
import Metal

public enum JPEGPreset: String, CaseIterable, Sendable, Encodable { case review, full }
public enum JPEGSample: String, CaseIterable, Sendable, Encodable { case first, midpoint }

/// The longest edge of a review-preset picture. Files and the CLI always use the default. A live
/// review request can bind another value around its own render, which reads it on the calling thread.
package enum JPEGReviewSize {
    package static let defaultEdge = 640
    /// Up to a 4K frame at its own size.
    package static let edges = 160...3840
    @TaskLocal package static var maxEdge = defaultEdge
    /// The part of the picture to return, in fractions of its width and height measured from the top left.
    /// A crop keeps the picture's own pixels up to `maxEdge`, so small detail in a large picture stays legible.
    @TaskLocal package static var region: CGRect?
    static let byteLimit = 1_048_576
    static let tooLarge = "The review JPEG exceeds 1 MiB."
    /// One reply carries several pictures within these limits.
    package static let batchFrames = 12
    package static let batchBytes = 2 << 20

    /// A requested long edge, or the default.
    package static func edge(_ requested: Int?) throws -> Int {
        guard let requested else { return defaultEdge }
        guard edges.contains(requested) else {
            throw CutError(code: "invalid_arguments",
                           message: "Choose a max_edge from \(edges.lowerBound) through \(edges.upperBound) pixels.")
        }
        return requested
    }

    /// A crop given as fractions of the picture from its top left.
    package static func region(x: Double, y: Double, width: Double, height: Double) throws -> CGRect {
        guard x >= 0, y >= 0, width >= 0.01, height >= 0.01, x + width <= 1.000001, y + height <= 1.000001 else {
            throw CutError(code: "invalid_arguments",
                           message: "Give region as x, y, width and height in fractions of the picture from its top left: each side at least 0.01, and the box inside the picture.")
        }
        return CGRect(x: x, y: y, width: min(width, 1 - x), height: min(height, 1 - y))
    }

    /// A recording's upright display size.
    package static func nativeSize(of media: MediaInfo) -> (width: Int, height: Int) {
        let video = media.video, rotated = !video.rotation.isMultiple(of: 180)
        return (video.displayWidth > 0 ? video.displayWidth : rotated ? video.height : video.width,
                video.displayHeight > 0 ? video.displayHeight : rotated ? video.width : video.height)
    }

    /// The whole picture's size when the returned one is smaller or is a crop of it, the same way round as
    /// the returned picture. Nil when the reader already has every pixel.
    package static func reduced(from full: (width: Int, height: Int), to width: Int, _ height: Int) -> (width: Int, height: Int)? {
        var native = full
        let landscape = Double(width) / Double(region?.width ?? 1) >= Double(height) / Double(region?.height ?? 1)
        if native.width != native.height, (native.width > native.height) != landscape { native = (native.height, native.width) }
        return region != nil || width != native.width || height != native.height ? native : nil
    }

    /// The decoder may hand back a smaller picture. With a crop it must keep enough pixels for the cropped part.
    static var decodeEdge: Int32 {
        guard let region else { return Int32(maxEdge) }
        return Int32(min(16_384, (Double(maxEdge) / Double(max(region.width, region.height))).rounded(.up)))
    }

    /// The crop within a picture occupying `extent`, whose y axis points up when `flipped`,
    /// and the pixel size that fits the crop's long edge without enlarging it.
    static func fit(_ extent: CGRect, flipped: Bool) -> (crop: CGRect, width: CGFloat, height: CGFloat) {
        let part = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let top = flipped ? 1 - part.maxY : part.minY
        let crop = CGRect(x: extent.minX + part.minX * extent.width, y: extent.minY + top * extent.height,
                          width: part.width * extent.width, height: part.height * extent.height)
        let scale = min(1, CGFloat(maxEdge) / max(crop.width, crop.height))
        return (crop, max(1, (crop.width * scale).rounded()), max(1, (crop.height * scale).rounded()))
    }

    /// Encodes at the review quality, then lower, until the picture fits the inline limit. What a reader
    /// can make out depends on the picture's size far more than its quality, so quality gives way first.
    static func encode(_ make: (Double) throws -> Data?) throws -> Data {
        var smallest: Data?
        for quality in [0.62, 0.45, 0.3, 0.2] {
            guard let data = try make(quality) else { break }
            smallest = data
            if data.count <= byteLimit { break }
        }
        guard let smallest else { throw JPEGRenderer.failure }
        return smallest
    }
}

/// The file format of an exported frame. JPEG is the 8-bit sRGB review rendition. PNG and TIFF are
/// lossless: they keep the decoder's R′G′B′ values unchanged, with 16 bits per channel when the source
/// has more than 8, and embed the profile that describes them (the source's gamut and transfer,
/// including PQ and HLG, which are not tone-mapped).
public enum FrameImageFormat: String, CaseIterable, Sendable, Encodable {
    case jpeg, png, tiff

    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

public enum JPEGSelection: Sendable {
    case scenes
    case sceneReport(SceneReport)
    case nonSilent(stream: Int?, thresholdDB: Double?, minimumPause: Double, maxBlip: Double = AudioWaveform.defaultMaxBlip)
    case audibleRanges(pauses: [AudioSpan], stream: Int, thresholdDB: Double, minimumPause: Double)
    case times([RationalTime])
}

public struct JPEGFrame: Encodable, Sendable {
    public let file: String
    public let rangeNumber: Int
    public let sceneNumber: Int?
    public let view: Int?
    public let viewLabel: String?
    public let viewName: String?
    public let from, to: RationalTime
    /// Frame-aligned covering interval suitable for a clip request.
    public let clipFrom, clipTo: RationalTime
    public let requestedTime, frameTime, frameDuration: RationalTime
    public let framePTS: Int64
    public let width, height: Int
}

public struct JPEGManifest: Encodable, Sendable {
    public let ok = true
    public let schemaVersion = 2
    public let file, outputDirectory, selection: String
    public let sourceStamp: SceneSourceStamp
    public let timeBase, origin, duration: RationalTime
    public let preset: JPEGPreset
    public let sample: JPEGSample?
    public let stream: Int?
    public let thresholdDB, minimumPause: Double?
    public let rangeCount: Int
    public let frames: [JPEGFrame]
    /// Present for PNG and TIFF exports. A JPEG manifest omits it.
    public var format: FrameImageFormat? = nil
    /// What the frames leave out of the source picture, such as its alpha channel. Absent when nothing.
    public var warnings: [String]? = nil

    private enum CodingKeys: String, CodingKey {
        case ok, schemaVersion, file, outputDirectory, selection, sourceStamp, timeBase, origin, duration
        case preset, sample, stream = "detection_audio_stream_index", thresholdDB, rangeCount, frames
        case minimumPause = "min_pause_seconds", format, warnings
    }

    /// Frames are written opaque. PNG and TIFF are chosen to keep the picture whole, so they say what they leave out.
    static func frameWarnings(_ media: MediaInfo, format: FrameImageFormat) -> [String]? {
        guard format != .jpeg, media.video.hasAlpha else { return nil }
        return ["\(format.fileExtension.uppercased()) frames are written without the source's alpha channel."]
    }
}

public struct MulticamJPEGManifest: Encodable, Sendable {
    public let ok = true
    public let schemaVersion = 2
    public let selection = "multicam"
    public let projectPath: String?
    public let outputDirectory: String
    public let preset: JPEGPreset
    public let angles: [MulticamJPEGAngle]
    public let frames: [MulticamJPEGFrame]
    /// Present for PNG and TIFF exports. A JPEG manifest omits it.
    public var format: FrameImageFormat? = nil
}

public struct MulticamJPEGAngle: Encodable, Sendable {
    public let id: String
    public let name: String?
    public let file: String
    public let offset: RationalTime
    public let origin, timeBase: RationalTime?
    public let videoStream: Int?
    public let error: CutError?
    public var warnings: [String]? = nil
    public var additionalRecordings: [MulticamJPEGAngle]? = nil
}

public struct MulticamJPEGFrame: Encodable, Sendable {
    public enum Availability: String, Encodable, Sendable {
        case available, beforeSource = "before_source", afterSource = "after_source", pictureGap = "picture_gap", missingSource = "missing_source", sourceError = "source_error"
    }

    public let requestNumber: Int
    public let groupTime: RationalTime
    public let angleID: String
    public let recordingID: String?
    public let sourceTime: RationalTime
    public let availability: Availability
    public let groupCoverage: AudioSpan?
    public let file: String?
    public let frameTime, frameDuration: RationalTime?
    public let framePTS: Int64?
    public let width, height: Int?
}

private struct JPEGRange {
    let number: Int
    let span: AudioSpan
    var scene: DetectedScene?
    var viewName: String?
    var requestedTime: RationalTime?
}

private struct JPEGPlan {
    let kind: String
    let ranges: [JPEGRange]
    var stream: Int?
    var thresholdDB: Double?
    var minimumPause: Double?
}

final class JPEGControl {
    let cancelled: @Sendable () -> Bool
    init(_ cancelled: @escaping @Sendable () -> Bool) { self.cancelled = cancelled }
    func check() throws {
        if Task.isCancelled || cancelled() { throw CutError(code: "cancelled", message: "Frame export was cancelled.") }
    }
}

public enum JPEGExport {
    public static func writeStill(_ media: MediaInfo, at time: RationalTime, to output: URL,
                                  format: FrameImageFormat = .jpeg,
                                  cancelled: @escaping @Sendable () -> Bool = { false }) throws {
        try writeStill(media, at: time, to: output, replacing: nil, format: format, cancelled: cancelled)
    }

    package static func stillFrameTime(in media: MediaInfo, at time: RationalTime,
                                       exclusiveEnd: Bool = false) throws -> RationalTime {
        let index = media.frames.lowerBound { exclusiveEnd ? $0.time >= time : $0.time > time } - 1
        guard media.hasVideo, time >= .zero, exclusiveEnd ? time <= media.duration : time < media.duration,
              media.frames.indices.contains(index) else {
            throw CutError(code: "no_frame", message: "No indexed picture covers source time \(time).")
        }
        let frame = media.frames[index]
        let end = try frame.time.adding(frame.duration)
        guard exclusiveEnd ? time <= end : time < end else {
            throw CutError(code: "no_frame", message: "No indexed picture covers source time \(time).")
        }
        if index > 0, media.frames[index - 1].time == frame.time {
            throw CutError(code: "ambiguous_frame", message: "More than one picture has the source timestamp \(frame.time).")
        }
        return max(.zero, frame.time)
    }

    package static func writeStill(_ media: MediaInfo, at time: RationalTime, to output: URL,
                                   replacing confirmed: SourceIdentity?, exclusiveEnd: Bool = false,
                                   preset: JPEGPreset = .full, format: FrameImageFormat = .jpeg,
                                   cancelled: @escaping @Sendable () -> Bool) throws {
        let control = JPEGControl(cancelled)
        try control.check()
        guard let sourceIdentity = try? SourceIdentity(media.url), sourceIdentity == media.identity else {
            throw CutError(code: "source_changed", message: "The source changed after indexing.")
        }
        try validateStillDestination(output, source: media.url, sourceIdentity: sourceIdentity, replacing: confirmed)
        if !media.identity.matchesSnapshot(sourceIdentity) {
            // Permissions and hard links can also advance ctime. Reuse the
            // index only if the current stream evidence verifies its inputs.
            let evidence = media.refreshEvidence
            let current = evidence?.hasCompleteProof == true
                ? try? Probe.read(media.url, forcePayload: true, expectedIdentity: sourceIdentity, cancelled: cancelled)
                : nil
            try control.check()
            guard let evidence, current?.refreshEvidence?.verifiesSameFileContents(as: evidence) == true else {
                throw CutError(code: "source_changed", message: "The source changed after indexing.")
            }
        }
        guard media.hasVideo, !media.frames.isEmpty, media.video.timeBase > .zero else {
            throw CutError(code: "no_frame", message: "No indexed picture is available at the playhead.")
        }
        let frameTime = try stillFrameTime(in: media, at: time, exclusiveEnd: exclusiveEnd)
        let plan = try plan(media, .times([frameTime]), useSidecar: false, cancelled: cancelled)
        _ = try render(media, ranges: plan.ranges, sample: .first, preset: preset, format: format, control: control,
                       fileName: { _ in output.lastPathComponent }, progress: { _, _ in }) { jpeg, _ in
            try publishStillJPEG(jpeg, source: media.url, sourceIdentity: sourceIdentity,
                                 to: output, replacing: confirmed, cancelled: cancelled) {
                guard sourceIdentity.isCurrentSnapshot(at: media.url) else {
                    throw CutError(code: "source_changed", message: "The source changed during frame export.")
                }
            }
        }
    }

    package static func publishStillJPEG(_ jpeg: Data, source: URL?, sourceIdentity: SourceIdentity?,
                                         to output: URL, replacing confirmed: SourceIdentity?,
                                         cancelled: @escaping @Sendable () -> Bool,
                                         validate: () throws -> Void) throws {
        let control = JPEGControl(cancelled)
        try control.check()
        try validateStillDestination(output, source: source, sourceIdentity: sourceIdentity, replacing: confirmed)
        let staging = output.deletingLastPathComponent().appendingPathComponent(".mpcut-frame-" + UUID().uuidString)
        try writing("the JPEG file") { try jpeg.write(to: staging, options: .withoutOverwriting) }
        defer { try? FileManager.default.removeItem(at: staging) }
        try validate()
        try control.check()
        try validateStillDestination(output, source: source, sourceIdentity: sourceIdentity, replacing: confirmed)
        let failure: Int32
        if confirmed != nil {
            failure = rename(staging.path, output.path) == 0 ? 0 : errno
        } else {
            failure = publishExclusively(from: staging, to: output)
        }
        guard failure == 0 else {
            let exists = failure == EEXIST || failure == ENOTEMPTY
            throw CutError(code: exists ? "output_exists" : "write_failed",
                           message: exists ? "The JPEG destination already exists." : "Could not publish the JPEG file.")
        }
    }

    package static func validateStillDestination(_ output: URL, source: URL?, sourceIdentity: SourceIdentity?,
                                                 replacing confirmed: SourceIdentity?) throws {
        guard output.isFileURL, output.resolvingSymlinksInPath() != source?.resolvingSymlinksInPath() else {
            throw CutError(code: "invalid_output", message: "Choose a separate JPEG file.")
        }
        var info = stat()
        if lstat(output.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG,
                  let identity = try? SourceIdentity(output), identity != sourceIdentity else {
                throw CutError(code: "invalid_output", message: "Choose a separate, regular JPEG file.")
            }
            guard confirmed?.matchesSnapshot(identity) == true else {
                throw CutError(code: "output_exists", message: "The destination exists and was not confirmed for replacement.")
            }
        } else if errno != ENOENT {
            throw CutError(code: "invalid_output", message: "Choose a JPEG file in an existing output folder.")
        } else if confirmed != nil {
            throw CutError(code: "output_changed", message: "The confirmed JPEG destination changed before export.")
        }
    }

    /// Creates a new directory containing numbered JPEGs and a manifest. A selected time
    /// refers to the picture on screen at that time, including a held VFR picture.
    public static func write(_ media: MediaInfo, to directory: URL, selection: JPEGSelection,
                             sample: JPEGSample = .midpoint, preset: JPEGPreset = .review,
                             format: FrameImageFormat = .jpeg,
                             limit: Int? = nil, useSidecar: Bool = true,
                             cancelled: @escaping @Sendable () -> Bool = { false },
                             progress: @escaping (Int, Int) -> Void = { _, _ in }) throws -> JPEGManifest {
        let control = JPEGControl(cancelled)
        try control.check()
        guard media.hasVideo else { throw CutError(code: "no_video", message: "JPEG frame export requires a video track.") }
        guard !media.frames.isEmpty, media.video.timeBase > .zero else {
            throw CutError(code: "invalid_input", message: "Frame export requires an indexed video.")
        }
        guard limit.map({ $0 > 0 }) ?? true else {
            throw CutError(code: "invalid_range", message: "The frame limit must be positive.")
        }
        if case .times = selection, limit != nil {
            throw CutError(code: "invalid_range", message: "Use the frame limit with scene or non-silent ranges.")
        }
        try checkSource(media)
        return try writeDirectory(to: directory, control: control, validate: { try checkSource(media) }) { staging, destination in
            let plan = try plan(media, selection, useSidecar: useSidecar, cancelled: cancelled)
            let frames = try render(media, ranges: subset(plan.ranges, limit: limit), sample: sample,
                                    preset: preset, format: format, control: control,
                                    fileName: { String(format: "frame-%06ld.", $0 + 1) + format.fileExtension }, progress: progress) { jpeg, name in
                try writing(name) { try jpeg.write(to: staging.appendingPathComponent(name)) }
            }
            return JPEGManifest(file: media.url.path, outputDirectory: destination.path, selection: plan.kind,
                sourceStamp: SceneSourceStamp(media: media), timeBase: media.video.timeBase, origin: media.origin,
                duration: media.duration, preset: preset, sample: plan.kind == "times" ? nil : sample,
                stream: plan.stream, thresholdDB: plan.thresholdDB, minimumPause: plan.minimumPause,
                rangeCount: plan.ranges.count, frames: frames, format: format == .jpeg ? nil : format,
                warnings: JPEGManifest.frameWarnings(media, format: format))
        }
    }

    /// Review each project's camera on the original group clock.
    public static func writeMulticam(project projectURL: URL, at times: [RationalTime], to directory: URL,
                                     preset: JPEGPreset = .review, format: FrameImageFormat = .jpeg,
                                     useSidecar: Bool = true,
                                     cancelled: @escaping @Sendable () -> Bool = { false }) throws -> MulticamJPEGManifest {
        try JPEGControl(cancelled).check()
        let projectURL = projectURL.standardizedFileURL
        let identity: SourceIdentity
        do {
            identity = try SourceIdentity(projectURL)
        } catch {
            // Report a missing or unreadable project as the other project commands do.
            _ = try MulticamProject.load(from: projectURL)
            throw error
        }
        let media = try CutProjectMedia.load(from: projectURL, multicam: true)
        guard case .multicam(let project) = media.project else {
            throw CutError(code: "invalid_multicam_project", message: "Expected a multicam project")
        }
        let exclusions = AnalysisSidecar.excludedSources.union(media.sidecarExclusions(relativeTo: projectURL))
        return try AnalysisSidecar.$excludedSources.withValue(exclusions) {
            try writeMulticam(project, document: projectURL, at: times, to: directory, preset: preset,
                              format: format,
                              useSidecar: useSidecar, documentIdentity: identity, projectMedia: media, cancelled: cancelled)
        }
    }

    /// The editor renders its current decisions, including changes that have not been saved yet.
    package static func writeMulticam(_ project: MulticamProject, document: URL?, at times: [RationalTime],
                                      to directory: URL, preset: JPEGPreset, format: FrameImageFormat = .jpeg,
                                      useSidecar: Bool,
                                      indexedSources: [String: MediaInfo] = [:], documentIdentity: SourceIdentity? = nil,
                                      projectMedia: CutProjectMedia? = nil,
                                      cancelled: @escaping @Sendable () -> Bool) throws -> MulticamJPEGManifest {
        let control = JPEGControl(cancelled)
        try control.check()
        guard !CutProject.multicam(project).requiresPictureProcessing else {
            throw ParticipantProjectExport.unsupported("Program frame export")
        }
        guard !times.isEmpty else { throw CutError(code: "invalid_range", message: "Supply at least one group time.") }
        try project.validate()
        for time in times where !project.range.contains(time) {
            throw CutError(code: "invalid_range", message: "Frame time \(time) is outside the group range.")
        }
        let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar)
        let sourceDirectory = document.map(ProjectFile.directory(of:)) ??
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var identities: [URL: SourceIdentity] = [:]
        if let document, let documentIdentity { identities[document] = documentIdentity }
        return try writeDirectory(to: directory, control: control, validate: {
            for (url, identity) in identities {
                try control.check()
                try engine.verifyIdentity(url, identity: identity)
            }
        }) { staging, destination in
            if let projectMedia {
                try projectMedia.validateDestination(destination, sourceDirectory: sourceDirectory, includesContents: true)
            } else {
                try CutProject.multicam(project).validateDestination(destination, sourceDirectory: sourceDirectory, includesContents: true)
            }
            var angles: [MulticamJPEGAngle] = []
            var byAngle: [[MulticamJPEGFrame]] = []
            for (angleIndex, camera) in project.angles.enumerated() {
                let recordings = camera.recordings
                var rows: [Int: MulticamJPEGFrame] = [:]
                var metadata: [MulticamJPEGAngle] = []
                for angle in recordings {
                    try control.check()
                    let url = project.sourceURL(for: angle, in: sourceDirectory)
                    let sourceTimes = try times.map { time in
                        try control.check()
                        return try time.subtracting(angle.offset)
                    }
                    let media: MediaInfo?
                    let error: CutError?
                    let unavailable: MulticamJPEGFrame.Availability
                    var fileStatus = stat()
                    if stat(url.path, &fileStatus) != 0, errno == ENOENT || errno == ENOTDIR {
                        media = nil
                        error = CutError(code: "missing_source", message: "Camera recording is missing: \(url.path).")
                        unavailable = .missingSource
                    } else {
                        do {
                            let indexed: MediaInfo
                            if let cached = indexedSources[angle.id], cached.url == url {
                                try engine.verifyIdentity(url, identity: cached.identity)
                                indexed = cached.hasFullEditIndex ? cached : try engine.inspectMulticamSource(url)
                            } else {
                                indexed = try engine.inspectMulticamSource(url)
                            }
                            guard indexed.hasVideo, !indexed.frames.isEmpty, indexed.video.timeBase > .zero else {
                                throw CutError(code: "no_video", message: "Camera recording has no indexed pictures.")
                            }
                            media = indexed
                            error = nil
                        } catch let problem as CutError where problem.code != "cancelled" && problem.code != "source_changed" {
                            try control.check()
                            media = nil
                            error = problem
                        }
                        unavailable = .sourceError
                    }
                    metadata.append(MulticamJPEGAngle(id: angle.id, name: angle.name, file: url.path, offset: angle.offset,
                        origin: media?.origin, timeBase: media?.video.timeBase, videoStream: media?.video.index, error: error))

                    var availableIndices: [Int] = []
                    let availability: [MulticamJPEGFrame.Availability]
                    if let media {
                        try engine.verifyIdentity(url, identity: media.identity)
                        identities[url] = media.identity
                        availability = try sourceTimes.enumerated().map { index, sourceTime in
                            try control.check()
                            if angle.coverage?.contains(times[index]) == false { return .pictureGap }
                            if sourceTime < .zero { return .beforeSource }
                            if sourceTime >= media.duration { return .afterSource }
                            guard try frameIndex(in: media, at: sourceTime) != nil else { return .pictureGap }
                            availableIndices.append(index)
                            return .available
                        }
                    } else {
                        availability = Array(repeating: unavailable, count: times.count)
                    }
                    var rendered: [Int: JPEGFrame] = [:]
                    if let media, !availableIndices.isEmpty {
                        metadata[metadata.count - 1].warnings = JPEGManifest.frameWarnings(media, format: format)
                        let plan = try plan(media, .times(availableIndices.map { sourceTimes[$0] }),
                                            useSidecar: useSidecar, cancelled: cancelled)
                        let frames = try render(media, ranges: plan.ranges, sample: .first, preset: preset,
                                                format: format,
                                                control: control, fileName: { index in
                            String(format: "frame-%06ld-angle-%03ld.", availableIndices[index] + 1, angleIndex + 1)
                                + format.fileExtension
                        }, progress: { _, _ in }) { jpeg, name in
                            try writing(name) { try jpeg.write(to: staging.appendingPathComponent(name)) }
                        }
                        rendered = Dictionary(uniqueKeysWithValues: zip(availableIndices, frames))
                    }
                    for index in times.indices where angle.coverage?.contains(times[index]) ?? true {
                        try control.check()
                        let picture = rendered[index]
                        let range = try picture.map {
                            AudioSpan(from: max(project.range.from, angle.coverage?.from ?? project.range.from, try $0.clipFrom.adding(angle.offset)),
                                      to: min(project.range.to, angle.coverage?.to ?? project.range.to, try $0.clipTo.adding(angle.offset)))
                        }
                        rows[index] = MulticamJPEGFrame(requestNumber: index + 1, groupTime: times[index], angleID: camera.id,
                            recordingID: recordings.count > 1 ? angle.id : nil,
                            sourceTime: sourceTimes[index], availability: availability[index], groupCoverage: range,
                            file: picture?.file, frameTime: picture?.frameTime, frameDuration: picture?.frameDuration,
                            framePTS: picture?.framePTS, width: picture?.width, height: picture?.height)
                    }
                }
                if var primary = metadata.first {
                    if metadata.count > 1 { primary.additionalRecordings = Array(metadata.dropFirst()) }
                    angles.append(primary)
                }
                byAngle.append(try times.indices.map { index in
                    try control.check()
                    if let row = rows[index] { return row }
                    return try MulticamJPEGFrame(requestNumber: index + 1, groupTime: times[index], angleID: camera.id,
                        recordingID: nil, sourceTime: times[index].subtracting(camera.offset), availability: .pictureGap,
                        groupCoverage: nil, file: nil, frameTime: nil, frameDuration: nil, framePTS: nil, width: nil, height: nil)
                })
            }
            return MulticamJPEGManifest(projectPath: document?.path, outputDirectory: destination.path, preset: preset,
                angles: angles, frames: times.indices.flatMap { index in byAngle.map { $0[index] } },
                format: format == .jpeg ? nil : format)
        }
    }

    private static func checkSource(_ media: MediaInfo) throws {
        guard media.identity.isCurrentSnapshot(at: media.url) else {
            throw CutError(code: "source_changed", message: "The source changed after indexing.")
        }
    }

    private static func writeDirectory<Manifest: Encodable>(
        to directory: URL, control: JPEGControl, writeManifest: Bool = true, validate: () throws -> Void,
        produce: (URL, URL) throws -> Manifest
    ) throws -> Manifest {
        let destination = directory.standardizedFileURL
        guard directory.isFileURL else {
            throw CutError(code: "invalid_output", message: "Choose a local output folder.")
        }
        var status = stat()
        if lstat(destination.path, &status) == 0 {
            throw CutError(code: "output_exists", message: "The frame export folder already exists.")
        }
        let parent = destination.deletingLastPathComponent()
        guard errno == ENOENT, stat(parent.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw CutError(code: "invalid_output", message: "Choose a new folder in an existing output directory.")
        }
        let staging = parent.appendingPathComponent(".mpcut-frames-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try writing("the frame export folder in \(parent.path)") {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        defer { try? fm.removeItem(at: staging) }

        let manifest = try produce(staging, destination)
        if writeManifest {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let document = try encoder.encode(manifest)
            try writing("manifest.json") { try document.write(to: staging.appendingPathComponent("manifest.json")) }
        }
        try validate()
        try control.check()
        guard chmod(staging.path, try publicationPermissions(0o777)) == 0 else {
            throw CutError(code: "write_failed", message: "Could not publish the frame export folder.")
        }
        let failure = publishExclusively(from: staging, to: destination, isDirectory: true)
        guard failure == 0 else {
            let exists = failure == EEXIST || failure == ENOTEMPTY
            throw CutError(code: exists ? "output_exists" : "write_failed",
                           message: exists ? "The frame export folder already exists." : "Could not publish the frame export folder.")
        }
        return manifest
    }

    /// A file-system fault is a structured write failure, reported without Cocoa's localized text.
    private static func writing<T>(_ item: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CutError {
            throw error
        } catch {
            let fault = error as NSError
            let posix = [fault, fault.userInfo[NSUnderlyingErrorKey] as? NSError]
                .compactMap { $0 }.first { $0.domain == NSPOSIXErrorDomain }
            let reason = posix.map { String(cString: strerror(Int32($0.code))) } ?? "The file system refused the write"
            throw CutError(code: "write_failed", message: "Could not write \(item): \(reason).")
        }
    }

    private static func frameIndex(in media: MediaInfo, at time: RationalTime) throws -> Int? {
        let index = media.frames.lowerBound { $0.time > time } - 1
        guard index >= 0, time < (try media.frames[index].time.adding(media.frames[index].duration)) else {
            return nil
        }
        return index
    }

    private static func render(_ media: MediaInfo, ranges: [JPEGRange], sample: JPEGSample,
                               preset: JPEGPreset, format: FrameImageFormat = .jpeg, control: JPEGControl,
                               fileName: (Int) -> String, progress: (Int, Int) -> Void,
                               write: (Data, String) throws -> Void) throws -> [JPEGFrame] {
        struct Request {
            let range: JPEGRange
            let requested: RationalTime
            let frame: Int
            let clip: AudioSpan
            let position: Int
        }
        let frames = media.frames
        func frame(at time: RationalTime) throws -> Int {
            guard let index = try frameIndex(in: media, at: time) else {
                throw CutError(code: "no_frame", message: "No indexed picture covers source time \(time).")
            }
            return index
        }
        let requests = try ranges.enumerated().map { position, range -> Request in
            try control.check()
            let instant: RationalTime
            if let explicit = range.requestedTime { instant = explicit }
            else if sample == .first { instant = range.span.from }
            else {
                let half = try range.span.to.subtracting(range.span.from).multiplied(by: RationalTime(numerator: 1, denominator: 2))
                instant = try range.span.from.adding(half)
            }
            let index = try frame(at: instant)
            // The packet index and decoder share PTS, but no ordering for equal PTS.
            if index > 0, frames[index - 1].time == frames[index].time {
                throw CutError(code: "ambiguous_frame",
                               message: "More than one picture has the source timestamp \(frames[index].time).")
            }
            let first = try frame(at: range.span.from)
            let last = frames.lowerBound { $0.time >= range.span.to } - 1
            guard last >= first else { throw CutError(code: "invalid_range", message: "An image range has no pictures.") }
            let clip = AudioSpan(from: max(.zero, frames[first].time),
                                 to: min(media.duration, try frames[last].time.adding(frames[last].duration)))
            return Request(range: range, requested: instant, frame: index, clip: clip, position: position)
        }.sorted { $0.frame != $1.frame ? $0.frame < $1.frame : $0.position < $1.position }

        // Decode chronologically so every picture sees its original decoder state.
        // JPEG compression can run independently once each picture has its display transform.
        var ordered = Array<JPEGFrame?>(repeating: nil, count: requests.count)
        var completed = 0
        if !requests.isEmpty {
            let renderer = try JPEGRenderer(media: media, control: control, lossless: format != .jpeg)
            let inverse = RationalTime(numerator: media.video.timeBase.denominator, denominator: media.video.timeBase.numerator)
            func ticks(_ time: RationalTime) throws -> Int64 {
                let pts = try time.adding(media.origin).multiplied(by: inverse)
                guard pts.denominator == 1 else {
                    throw CutError(code: "invalid_frame", message: "A picture does not land on a source timestamp.")
                }
                return pts.numerator
            }
            struct Job {
                var profile: CGColorSpace? = nil
                let picture: CIImage
                let requests: Range<Int>
                let pts: Int64
                /// The source's own JPEG picture and its size, written instead of encoding `picture`.
                var stored: (jpeg: Data, width: Int, height: Int)? = nil
                var width: Int { stored?.width ?? Int(picture.extent.width) }
                var height: Int { stored?.height ?? Int(picture.extent.height) }
            }
            let packets = JPEGPacketCopy(media, preset: preset, format: format, control: control)
            let pixels = Double(max(media.video.width, media.video.displayWidth)) *
                Double(max(media.video.height, media.video.displayHeight))
            // Allow for a decoded surface, a render surface and JPEG scratch space.
            let workers = min(4, ProcessInfo.processInfo.activeProcessorCount,
                              max(1, Int(128 * 1024 * 1024 / max(1, pixels * 16))))
            var previous: Int?
            var next = 0
            while next < requests.count {
                var jobs: [Job] = []
                while jobs.count < workers, next < requests.count {
                    try control.check()
                    let first = next
                    let frame = requests[first].frame
                    let pts = try ticks(frames[frame].time)
                    var seekDTS = Int64.min
                    // Requests advance in frame order. Only the gap since the previous
                    // picture can contain a useful seek point, even on a long recording.
                    let previousTime = previous.map { frames[$0].time.seconds } ?? 0
                    if frames[frame].time.seconds - previousTime > 2 {
                        for key in stride(from: frame, to: previous ?? 0, by: -1) {
                            if key.isMultiple(of: 1_024) { try control.check() }
                            guard frames[key].time.seconds - previousTime > 2 else { break }
                            if frames[key].canStart, let dts = frames[key].dts {
                                seekDTS = try ticks(dts)
                                break
                            }
                        }
                    }
                    var profile: CGColorSpace?
                    let stored = try packets?.picture(at: pts)
                    let picture = try stored != nil ? CIImage.empty() : autoreleasepool { () throws -> CIImage in
                        guard format != .jpeg else {
                            return try renderer.picture(at: pts, seekDTS: seekDTS, preset: preset, clampsLikePreview: true)
                        }
                        let source = try renderer.sourcePicture(at: pts, seekDTS: seekDTS, preset: preset)
                        profile = source.profile
                        return source.image
                    }
                    previous = frame
                    repeat { next += 1 } while next < requests.count && requests[next].frame == frame
                    jobs.append(Job(profile: profile, picture: picture, requests: first..<next, pts: pts,
                                    stored: stored.map { ($0, media.video.width, media.video.height) }))
                }
                try forEachOrderedBatch(count: jobs.count, batchSize: 1, workerLimit: workers, check: control.check, transform: { range in
                    let job = jobs[range.lowerBound]
                    return (job, try autoreleasepool {
                        if let stored = job.stored { return stored.jpeg }
                        guard let profile = job.profile else { return try renderer.encode(job.picture, preset: preset) }
                        return try renderer.encode(job.picture, profile: profile, format: format)
                    })
                }, consume: { job, jpeg in
                    for i in job.requests {
                        try control.check()
                        let req = requests[i], info = frames[req.frame]
                        let name = fileName(req.position)
                        try write(jpeg, name)
                        let r = req.range
                        ordered[req.position] = JPEGFrame(file: name, rangeNumber: r.number, sceneNumber: r.scene?.number,
                            view: r.scene?.view, viewLabel: r.scene?.viewLabel, viewName: r.viewName, from: r.span.from, to: r.span.to,
                            clipFrom: req.clip.from, clipTo: req.clip.to, requestedTime: req.requested,
                            frameTime: info.time, frameDuration: info.duration, framePTS: job.pts,
                            width: job.width, height: job.height)
                        completed += 1
                        progress(completed, requests.count)
                    }
                })
            }
        }
        return ordered.compactMap { $0 }
    }

    private static func subset(_ ranges: [JPEGRange], limit: Int?) -> [JPEGRange] {
        guard let limit, limit < ranges.count else { return ranges }
        if limit == 1 { return [ranges[ranges.count / 2]] }
        return (0..<limit).map { index in
            let fraction = Double(index) / Double(limit - 1)
            return ranges[Int((fraction * Double(ranges.count - 1)).rounded())]
        }
    }

    private static func plan(_ media: MediaInfo, _ selection: JPEGSelection, useSidecar: Bool,
                             cancelled: @escaping @Sendable () -> Bool) throws -> JPEGPlan {
        func fromScenes(_ report: SceneReport) throws -> JPEGPlan {
            guard report.file == media.url.path, report.sourceStamp == SceneSourceStamp(media: media),
                  report.duration == media.duration else {
                throw CutError(code: "source_changed", message: "The scene report belongs to another source or edit clock.")
            }
            var names: [Int: String] = [:]
            for view in report.views { names[view.view] = view.name }
            return JPEGPlan(kind: "scenes", ranges: report.scenes.map {
                JPEGRange(number: $0.number, span: AudioSpan(from: $0.start, to: $0.end), scene: $0, viewName: names[$0.view])
            })
        }
        func fromPauses(_ pauses: [AudioSpan], _ stream: Int, _ threshold: Double, _ minimum: Double) throws -> JPEGPlan {
            var last = RationalTime.zero
            guard media.streams.contains(where: { $0.index == stream && $0.kind == "audio" }),
                  threshold.isFinite, (-120...0).contains(threshold), minimum.isFinite, minimum > 0 else {
                throw CutError(code: "invalid_input", message: "Invalid silence analysis settings for this source.")
            }
            for pause in pauses {
                guard last <= pause.from, pause.from < pause.to, pause.to <= media.duration else {
                    throw CutError(code: "invalid_range", message: "The quiet intervals must be ordered within the source.")
                }
                last = pause.to
            }
            let retained = AudioAnalysis.retained(in: AudioSpan(from: .zero, to: media.duration), removing: pauses)
            return JPEGPlan(kind: "non-silent", ranges: retained.enumerated().map { JPEGRange(number: $0 + 1, span: $1) },
                            stream: stream, thresholdDB: threshold, minimumPause: minimum)
        }
        switch selection {
        case .scenes:
            return try fromScenes(SceneAnalysis.scan(media, useSidecar: useSidecar, cancelled: cancelled))
        case let .sceneReport(report):
            return try fromScenes(report)
        case let .nonSilent(stream, threshold, minimum, maxBlip):
            guard let index = stream ?? media.streams.first(where: { $0.kind == "audio" })?.index else {
                throw CutError(code: "no_audio", message: "The selected source has no audio stream.")
            }
            let result = try AudioAnalysis.silence(media, stream: index, thresholdDB: threshold, minimum: minimum,
                                                   useSidecar: useSidecar,
                                                   cancelled: cancelled)
            return try fromPauses(result.pauses(maxBlip: maxBlip), index, result.thresholdDB, minimum)
        case let .audibleRanges(pauses, index, threshold, minimum):
            return try fromPauses(pauses, index, threshold, minimum)
        case let .times(times):
            guard !times.isEmpty else { throw CutError(code: "invalid_range", message: "Supply at least one frame time.") }
            let control = JPEGControl(cancelled)
            return try JPEGPlan(kind: "times", ranges: times.enumerated().map { i, time in
                try control.check()
                let index = media.frames.lowerBound { $0.time > time } - 1
                guard time >= .zero, time < media.duration, index >= 0 else {
                    throw CutError(code: "invalid_range", message: "Frame time \(time) is outside the visible source.")
                }
                let frame = media.frames[index]
                return JPEGRange(number: i + 1, span: AudioSpan(from: max(.zero, frame.time),
                    to: min(media.duration, try frame.time.adding(frame.duration))), requestedTime: time)
            })
        }
    }
}

final class JPEGRenderer {
    static var failure: CutError { CutError(code: "frame_export_failed", message: "Could not render the selected picture as JPEG.") }
    let reader: OpaquePointer
    let control: JPEGControl
    // A CIContext supports concurrent renders and owns expensive Metal resources.
    // Share it across angles, exported stills and live frame-review requests.
    private static let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "MPCut JPEG Export"]
        guard let device = MTLCreateSystemDefaultDevice() else { return CIContext(options: options) }
        return CIContext(mtlDevice: device, options: options)
    }()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Lossless output renders at 16 bits per channel when the source has more than 8.
    private let deep: Bool

    init(media: MediaInfo, control: JPEGControl, lossless: Bool = false) throws {
        self.control = control
        deep = lossless && media.video.bitDepth > 8
        var error = [CChar](repeating: 0, count: 256)
        let state = Unmanaged.passUnretained(control).toOpaque()
        guard let decoder = mp_jpeg_open(media.url.path, Int32(media.video.index), {
            Unmanaged<JPEGControl>.fromOpaque($0!).takeUnretainedValue().cancelled() ? 1 : 0
        }, state, &error, error.count) else {
            try control.check()
            throw CutError(code: "frame_export_failed", message: "Could not open the picture decoder: " + String(cString: error))
        }
        reader = decoder
        if deep { mp_jpeg_set_deep(decoder, true) }
    }
    deinit { mp_jpeg_close(reader) }

    var displayTransform: CGAffineTransform { mp_jpeg_transform(reader) }

    /// `clampsLikePreview` limits the decoded signal the way the preview does; frame export asks for it.
    func picture(at pts: Int64, seekDTS: Int64, preset: JPEGPreset, toneMapHDR: Bool = true,
                 clampsLikePreview: Bool = false) throws -> CIImage {
        var buffer: CVPixelBuffer?
        var error = [CChar](repeating: 0, count: 256)
        guard mp_jpeg_frame(reader, pts, seekDTS, preset == .review ? JPEGReviewSize.decodeEdge : 0, &buffer, &error, error.count) >= 0,
              let buffer else {
            try control.check()
            throw CutError(code: "frame_export_failed", message: "Could not decode source picture at PTS \(pts): " + String(cString: error))
        }
        // Converting an HDR picture to sRGB without this request can clip it: the upper
        // half of an HLG signal came out flat white. The SDR preview makes the same
        // request, so the JPEG shows the same rendition. SDR pictures are left alone.
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let isHDR = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) ||
            transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        var image = isHDR && toneMapHDR ? CIImage(cvPixelBuffer: buffer, options: [.toneMapHDRtoSDR: true])
            : clampsLikePreview ? Self.clampedSignal(buffer) : CIImage(cvPixelBuffer: buffer)
        let display = mp_jpeg_display_size(reader)
        let natural = CGAffineTransform(scaleX: display.width / image.extent.width,
                                       y: display.height / image.extent.height)
        image = image.transformed(by: natural.concatenating(displayTransform))
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width >= 0.5, extent.height >= 0.5 else { throw Self.failure }
        // Core Image measures up from the bottom edge.
        let (crop, width, height) = preset == .review ? JPEGReviewSize.fit(extent, flipped: true)
            : (extent, max(1, extent.width.rounded()), max(1, extent.height.rounded()))
        // JPEG encodes each dimension in 16 bits.
        guard width <= 65535, height <= 65535 else { throw Self.failure }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let transform = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: width / crop.width, y: height / crop.height))
        return image.transformed(by: transform, highQualityDownsample: true).cropped(to: rect)
    }

    /// Core Animation, which shows the native and the FFmpeg preview, limits each decoded R′G′B′
    /// value to 0...1 before converting color, where Core Image carries it on. They differ where a
    /// picture's values leave its primaries' gamut: BT.709 bars read with BT.601 and SMPTE C
    /// primaries came out up to 11 levels lower in green than the preview (measured on macOS 27).
    private static func clampedSignal(_ buffer: CVPixelBuffer) -> CIImage {
        let tagged = CIImage(cvPixelBuffer: buffer)
        guard let space = tagged.colorSpace,
              let clamped = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
                .applyingFilter("CIColorClamp").matchedToWorkingSpace(from: space) else { return tagged }
        return clamped
    }

    func encode(_ image: CIImage, preset: JPEGPreset) throws -> Data {
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        func make(_ level: Double) -> Data? {
            Self.context.jpegRepresentation(of: image, colorSpace: Self.colorSpace, options: [quality: level])
        }
        guard preset == .review else { return try make(0.95) ?? { throw Self.failure }() }
        return try JPEGReviewSize.encode(make)
    }
}

extension JPEGRenderer {
    // Without a working space Core Image leaves R′G′B′ values as decoded, and a
    // 32-bit float intermediate carries every 16-bit value through the geometry.
    private static let sourceContext: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .workingColorSpace: NSNull(),
                                               .workingFormat: CIFormat.RGBAf, .name: "MPCut Lossless Frame Export"]
        guard let device = MTLCreateSystemDefaultDevice() else { return CIContext(options: options) }
        return CIContext(mtlDevice: device, options: options)
    }()

    /// The decoded picture in display geometry, without tone mapping, and the profile that
    /// describes its values: the color space Core Image reads from the source's color tags.
    func sourcePicture(at pts: Int64, seekDTS: Int64, preset: JPEGPreset) throws -> (image: CIImage, profile: CGColorSpace) {
        var buffer: CVPixelBuffer?
        var error = [CChar](repeating: 0, count: 256)
        guard mp_jpeg_frame(reader, pts, seekDTS, preset == .review ? JPEGReviewSize.decodeEdge : 0, &buffer, &error, error.count) >= 0,
              let buffer else {
            try control.check()
            throw CutError(code: "frame_export_failed", message: "Could not decode source picture at PTS \(pts): " + String(cString: error))
        }
        var image = CIImage(cvPixelBuffer: buffer)
        func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(buffer, key, nil) as? String }
        let primaries = tag(kCVImageBufferColorPrimariesKey), transfer = tag(kCVImageBufferTransferFunctionKey)
        let profile: CGColorSpace
        // Name the two common still-image spaces. Core Image describes them as video profiles.
        if transfer == (kCVImageBufferTransferFunction_sRGB as String),
           primaries == (kCVImageBufferColorPrimaries_P3_D65 as String), let space = CGColorSpace(name: CGColorSpace.displayP3) {
            profile = space
        } else if transfer == (kCVImageBufferTransferFunction_sRGB as String),
                  primaries == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String) {
            profile = StillImage.sRGB
        } else {
            profile = image.colorSpace ?? StillImage.sRGB
        }
        let display = mp_jpeg_display_size(reader)
        let natural = CGAffineTransform(scaleX: display.width / image.extent.width,
                                       y: display.height / image.extent.height)
        let placement = natural.concatenating(displayTransform)
        if !placement.isIdentity { image = image.transformed(by: placement) }
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width >= 0.5, extent.height >= 0.5 else { throw Self.failure }
        let (crop, width, height) = preset == .review ? JPEGReviewSize.fit(extent, flipped: true)
            : (extent, max(1, extent.width.rounded()), max(1, extent.height.rounded()))
        guard width <= 65535, height <= 65535 else { throw Self.failure }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let fit = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: width / crop.width, y: height / crop.height))
        if !fit.isIdentity { image = image.transformed(by: fit, highQualityDownsample: true) }
        return (image.cropped(to: rect), profile)
    }

    func encode(_ image: CIImage, profile: CGColorSpace, format: FrameImageFormat) throws -> Data {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        let rowBytes = width * (deep ? 8 : 4)
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { bytes in
            Self.sourceContext.render(image, toBitmap: bytes.baseAddress!, rowBytes: rowBytes, bounds: image.extent,
                                      format: deep ? .RGBA16 : .RGBA8, colorSpace: nil)
        }
        var layout = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        if deep { layout.formUnion(.byteOrder16Little) }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let picture = CGImage(width: width, height: height, bitsPerComponent: deep ? 16 : 8,
                                    bitsPerPixel: deep ? 64 : 32, bytesPerRow: rowBytes, space: profile,
                                    bitmapInfo: layout, provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent) else { throw Self.failure }
        return try format.encode(picture)
    }
}

/// Writes an MJPEG or Photo JPEG picture as stored when a Full JPEG would only encode it again: same
/// size, no display transform, square pixels and the color a JFIF viewer assumes (full-range BT.601
/// YCbCr shown as sRGB). A picture that is not a standalone baseline JPEG of the whole frame is decoded.
final class JPEGPacketCopy {
    private let packets: OpaquePointer
    private let control: JPEGControl
    private let width: Int32
    private let height: Int32

    init?(_ media: MediaInfo, preset: JPEGPreset, format: FrameImageFormat, control: JPEGControl) {
        let video = media.video
        let unspecified: Set<String> = ["", "unknown", "unspecified", "reserved"]
        let sar = video.sampleAspectRatio
        // The index runs no picture decoder, so an AVI MJPEG stream whose pictures omit Huffman tables has
        // no known layout. Each picture's frame header then decides (mp_jpeg_packets_open).
        let layoutUnknown = video.bitDepth == 0 && unspecified.contains(video.pixelFormat)
            && unspecified.contains(video.colorRange)
        guard preset == .full, format == .jpeg, video.codec == "mjpeg", !video.hasAlpha,
              layoutUnknown || (video.bitDepth == 8 && video.colorRange == "pc"
                                && (video.pixelFormat.hasPrefix("yuvj") || video.pixelFormat == "gray")),
              unspecified.union(["bt470bg", "smpte170m"]).contains(video.colorMatrix),
              unspecified.union(["iec61966-2-1"]).contains(video.colorTransfer),
              unspecified.union(["bt709"]).contains(video.colorPrimaries),
              video.rotation == 0, video.width == video.displayWidth, video.height == video.displayHeight,
              sar.numerator == sar.denominator || sar.numerator == 0,
              ["progressive", "unknown"].contains(video.fieldOrder),
              let width = Int32(exactly: video.width), let height = Int32(exactly: video.height) else { return nil }
        let state = Unmanaged.passUnretained(control).toOpaque()
        guard let packets = mp_jpeg_packets_open(media.url.path, Int32(video.index), layoutUnknown, {
            Unmanaged<JPEGControl>.fromOpaque($0!).takeUnretainedValue().cancelled() ? 1 : 0
        }, state) else { return nil }
        self.packets = packets
        self.control = control
        self.width = width
        self.height = height
    }
    deinit { mp_jpeg_packets_close(packets) }

    /// The stored picture at this presentation time, or nil when it has to be decoded.
    func picture(at pts: Int64) throws -> Data? {
        var data: UnsafeMutablePointer<UInt8>?
        var size = 0
        // A read failure leaves the picture to the decoder, which reports its own errors.
        guard mp_jpeg_packet(packets, pts, width, height, &data, &size) > 0, let data else {
            try control.check()
            return nil
        }
        return Data(bytesNoCopy: data, count: size, deallocator: .free)
    }
}

extension FrameImageFormat {
    /// Writes a PNG or an LZW-compressed TIFF with the image's own depth and profile.
    func encode(_ image: CGImage) throws -> Data {
        let failure = CutError(code: "frame_export_failed", message: "Could not encode the selected picture as \(rawValue.uppercased()).")
        let type = self == .png ? "public.png" : "public.tiff"
        let data = NSMutableData()
        guard self != .jpeg, let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw failure }
        let properties: [CFString: Any] = self == .tiff
            ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw failure }
        return data as Data
    }
}

extension JPEGExport {
    package static func writeProgramFrameDirectory<Manifest: Encodable>(
        to directory: URL, cancelled: @escaping @Sendable () -> Bool, writeManifest: Bool = true,
        validate: () throws -> Void, produce: (URL) throws -> Manifest
    ) throws -> Manifest {
        try writeDirectory(to: directory, control: JPEGControl(cancelled), writeManifest: writeManifest, validate: validate) { staging, _ in
            try produce(staging)
        }
    }

    /// Renders one bounded review image using the same decoder, transforms and frame rules as JPEG export.
    package static func reviewFrame(_ media: MediaInfo, at time: RationalTime, exclusiveEnd: Bool,
                                    preset: JPEGPreset = .review, format: FrameImageFormat = .jpeg,
                                    cancelled: @escaping @Sendable () -> Bool) throws -> (Data, JPEGFrame) {
        let control = JPEGControl(cancelled)
        try control.check()
        try checkSource(media)
        let target = try stillFrameTime(in: media, at: time, exclusiveEnd: exclusiveEnd)
        var bytes: Data?
        let frames = try renderReviewFrames(media, at: [target], preset: preset, format: format, control: control,
                                            fileName: { _ in "review." + format.fileExtension }) { data, _ in
            bytes = data
        }
        guard let bytes, let frame = frames.first else { throw CutError(code: "no_frame", message: "No review frame was available.") }
        return (bytes, frame)
    }

    /// Writes requests in decode order while returning metadata in request order.
    /// Times are source frame starts selected by `stillFrameTime`.
    package static func writeReviewFrames(
        _ media: MediaInfo, at times: [RationalTime], preset: JPEGPreset, format: FrameImageFormat = .jpeg,
        cancelled: @escaping @Sendable () -> Bool, fileName: (Int) -> String,
        write: (Data, String) throws -> Void
    ) throws -> [JPEGFrame] {
        let control = JPEGControl(cancelled)
        try control.check()
        try checkSource(media)
        return try renderReviewFrames(media, at: times, preset: preset, format: format, control: control,
                                      fileName: fileName, write: write)
    }

    private static func renderReviewFrames(
        _ media: MediaInfo, at times: [RationalTime], preset: JPEGPreset, format: FrameImageFormat = .jpeg,
        control: JPEGControl, fileName: (Int) -> String, write: (Data, String) throws -> Void
    ) throws -> [JPEGFrame] {
        let selected = try plan(media, .times(times), useSidecar: false, cancelled: control.cancelled)
        let frames = try render(media, ranges: selected.ranges, sample: .first, preset: preset, format: format,
                                control: control,
                                fileName: fileName, progress: { _, _ in }) { data, name in
            // The review size limit belongs to the JPEG that tools return inline.
            guard format != .jpeg || preset != .review || data.count <= JPEGReviewSize.byteLimit else {
                throw CutError(code: "image_too_large", message: JPEGReviewSize.tooLarge)
            }
            try write(data, name)
        }
        try control.check()
        try checkSource(media)
        return frames
    }
}
