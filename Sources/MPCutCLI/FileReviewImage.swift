import Foundation
import MPCutCore

struct FileReviewImage: Encodable {
    let clock: String
    let requestedTime: RationalTime
    let width, height: Int
    let jpeg: Data
    var file: String?
    var projectPath: String?
    var sourceTime: RationalTime?
    var frameTime: RationalTime?
    var range: MulticamRange?
    var sourceID: String?
    var placementID: String?
    var assetID: String?
    var generatedGap: Bool?
    var privacyIssues: [ParticipantPrivacyIssue]?
    var privacyIssueCount: Int?

    // At most 16 issue IDs, three frame IDs and one path can occur together.
    // Even at six JSON bytes per input byte, the strings fit alongside 1 MiB
    // of JPEG after base64 encoding in the worker's 1,500,000-byte result limit.
    private static func boundedText(_ value: String?, maximumBytes: Int = 512) -> String? {
        guard let value, value.utf8.count <= maximumBytes else { return nil }
        return value
    }

    init(source: URL, time: RationalTime, frame: JPEGFrame, jpeg: Data) {
        clock = "source"
        requestedTime = time
        width = frame.width
        height = frame.height
        self.jpeg = jpeg
        file = Self.boundedText(source.path, maximumBytes: 4096)
        sourceTime = time
        frameTime = frame.frameTime
        range = MulticamRange(from: frame.clipFrom, to: frame.clipTo)
    }

    init(projectPath: String, clock: String, time: RationalTime, frame: ProgramFrameManifest.Frame,
         jpeg: Data) {
        self.projectPath = Self.boundedText(projectPath, maximumBytes: 4096)
        self.clock = clock
        requestedTime = time
        width = frame.width
        height = frame.height
        self.jpeg = jpeg
        sourceTime = frame.sourceTime
        frameTime = frame.frameTime
        range = frame.outputRange
        sourceID = Self.boundedText(frame.source)
        placementID = Self.boundedText(frame.placementID)
        assetID = Self.boundedText(frame.assetID)
        generatedGap = frame.generatedGap
        if let issues = frame.privacyIssues {
            privacyIssueCount = issues.count
            privacyIssues = issues.prefix(16).filter { Self.boundedText($0.sourceID) != nil }
        }
    }
}

func fileProgramReviewImage(_ project: CutProject, media: CutProjectMedia, projectPath: String, location: URL,
                            time: RationalTime, clock: StillOptions.Clock?, output: URL,
                            documentIdentity: SourceIdentity?, useSidecar: Bool,
                            cancelled: @escaping @Sendable () -> Bool) throws -> FileReviewImage {
    var snapshot = project
    var renderClock = clock
    if clock == .group, case .multicam(var multicam) = project {
        guard multicam.range.contains(time) else {
            throw CutError(code: "invalid_range", message: "Choose a time within the multicam group.")
        }
        if !project.requiresPictureProcessing {
            // The group switch lane is independent of the authored assembly.
            multicam.assemblyItems = nil
            snapshot = .multicam(multicam)
            renderClock = .assembly
        }
    }
    let manifest = try writeProgramFrames(snapshot, media: media, projectPath: projectPath, location: location,
                                          at: [time], clock: renderClock, to: output, preset: .review,
                                          documentIdentity: documentIdentity, useSidecar: useSidecar,
                                          writeManifest: false, cancelled: cancelled)
    defer { try? FileManager.default.removeItem(at: output) }
    guard let frame = manifest.frames.first, (1...640).contains(frame.width), (1...640).contains(frame.height) else {
        throw CutError(code: "invalid_result", message: "The review frame dimensions exceed the review limit.")
    }
    let maxBytes = 1 << 20
    let handle = try FileHandle(forReadingFrom: output.appendingPathComponent(frame.file))
    defer { try? handle.close() }
    guard let jpeg = try handle.read(upToCount: maxBytes + 1), !jpeg.isEmpty, jpeg.count <= maxBytes else {
        throw CutError(code: "invalid_result", message: "The review image exceeds the review byte limit.")
    }
    return FileReviewImage(projectPath: projectPath, clock: clock?.rawValue ?? manifest.clock, time: time,
                           frame: frame, jpeg: jpeg)
}
