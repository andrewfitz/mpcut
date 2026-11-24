import Darwin
import Foundation
import MPCutCore

extension TilesCLI {
    func runDelivery(json: Bool, useSidecar: Bool, interruption: Interruption) throws {
        let request = try request(interruption)
        let cancelled: @Sendable () -> Bool = { !interruption.isActive }
        if operation == .verifyAngles {
            let result = try TilesISODelivery.verify(request.url("output", directory: true), cancelled: cancelled)
            try writeJSON(result, pretty: !json)
            if !result.valid { exit(1) }
            return
        }

        let output = try request.value("output", as: String.self).map {
            try fileURL($0, label: "Output", directory: operation != .planAngles)
        }
        let dryRun = try request.value("dry_run", as: Bool.self) ?? false
        let progress = try request.progress()
        if operation != .planAngles && !dryRun && output == nil {
            throw CLIError("invalid_arguments", "Supply --output with an ISO delivery directory.")
        }
        let inputPlan = try request.value("plan", as: String.self)
        let rawFile = try request.value("file", as: String.self)
        let projectFile = try request.value("project_path", as: String.self)
        let document: URL
        let project: CutProject
        let plan: TilesISOPlan

        if inputPlan != nil {
            guard Set(request.fields.keys).isSubset(of: ["plan", "output", "progress", "resume"]) else {
                throw CLIError("invalid_arguments", "Use --plan with --output, --progress or --resume.")
            }
            let saved = try request.readJSONFile("plan", as: TilesISOPlan.self, label: "ISO plan", cancelled: cancelled)
            document = try fileURL(saved.projectPath, label: "Plan project")
            project = try CutProject.load(from: document)
            // Ready plans are revalidated by render. Review results also need
            // to describe the revision on disk before returning without rendering.
            plan = saved.requiresReview
                ? try TilesISODelivery.validatedPlan(saved, project: project, document: document, cancelled: cancelled)
                : saved
        } else {
            guard (rawFile != nil) != (projectFile != nil) else {
                throw CLIError("invalid_arguments", "Choose one recording or saved project.")
            }
            let settings = try ISOSettings(request)
            var sourceID = try request.value("source_id", as: String.self)
            if let rawFile {
                guard sourceID == nil else { throw CLIError("invalid_arguments", "--source-id requires a saved project.") }
                let recording = try fileURL(rawFile, label: "Recording").resolvingSymlinksInPath()
                guard let output else {
                    throw CLIError("invalid_arguments", "Supply --output to reserve a review project for the recording.")
                }
                (document, project) = try makeReviewProject(recording: recording, delivery: output, request: request,
                    useSidecar: useSidecar, settings: settings, progress: progress, cancelled: cancelled)
                sourceID = recording.path
            } else {
                document = try request.url("project_path")
                project = try CutProject.load(from: document)
            }
            plan = try SidecarLocations.$projectURL.withValue(document) {
                try TilesISODelivery.plan(project: project, document: document, sourceID: sourceID,
                    feedIDs: settings.feedIDs, range: settings.range, width: settings.width, height: settings.height,
                    frameRate: settings.frameRate, gapColor: settings.gapColor, framing: settings.framing,
                    keepCameraOff: settings.cameraOff, blankUncertain: settings.blankUncertain, audio: settings.audio,
                    countHints: settings.countHints, cancelled: cancelled)
            }
        }
        if operation == .planAngles {
            if let output {
                guard output.pathExtension.lowercased() == "json" else {
                    throw CLIError("invalid_arguments", "Choose a new .json plan destination.")
                }
                try project.validateDestination(output, relativeTo: document)
                try writePlan(plan, to: output)
            }
            try writeJSON(plan, pretty: !json)
            return
        }
        if plan.requiresReview {
            let review = ISOResult(status: "needs_review", sourceID: plan.sourceID, sourceFingerprint: plan.sourceFingerprint, reviewProjectPath: document.path,
                issues: plan.issues.filter(\.blocking), warnings: plan.issues.filter { !$0.blocking },
                suggestedNextCommand: ["mpcut", "tiles", "inspect", "--project", document.path,
                                       "--source-id", plan.sourceID, "--issues", "--json"])
            try writeJSON(review, pretty: !json)
            exit(3)
        }
        if dryRun {
            try writeJSON(plan, pretty: !json)
            return
        }
        guard let output else { throw CLIError("invalid_arguments", "Supply --output.") }
        let manifest = try SidecarLocations.$projectURL.withValue(document) {
            try TilesISODelivery.render(plan, project: project, document: document, to: output, cancelled: cancelled) { fraction in
                isoProgress(progress, phase: "rendering", fraction: fraction)
                return interruption.isActive
            }
        }
        try writeJSON(ISOResult(status: "completed", sourceID: plan.sourceID, sourceFingerprint: plan.sourceFingerprint,
            issues: [], warnings: manifest.issues,
            suggestedNextCommand: ["mpcut", "tiles", "angles", "verify", output.path, "--json"],
            output: output.path, manifestPath: output.appendingPathComponent("manifest.json").path,
            projectPath: output.appendingPathComponent("multicam.cut").path), pretty: !json)
    }
}

private struct ISOResult: Encodable {
    let schemaVersion = 1
    let status: String
    let sourceID: String
    let sourceFingerprint: String
    var reviewProjectPath: String? = nil
    let issues: [TilesISOIssue]
    let warnings: [TilesISOIssue]
    let suggestedNextCommand: [String]
    var output: String? = nil
    var manifestPath: String? = nil
    var projectPath: String? = nil

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", status, sourceID = "source_id", sourceFingerprint = "source_fingerprint", issues, warnings, output
        case reviewProjectPath = "review_project_path", suggestedNextCommand = "suggested_next_command"
        case manifestPath = "manifest_path", projectPath = "project_path"
    }
}

private struct ISOSettings {
    let feedIDs: [String]?
    let width: Int?
    let height: Int?
    let range: MulticamRange?
    let frameRate: RationalTime?
    let gapColor: UInt32?
    let framing: ParticipantSlotFraming
    let cameraOff: Bool
    let blankUncertain: Bool
    let audio: ParticipantMulticamAudioRouting
    let countHints: TilesCountHints?

    init(_ request: ParticipantRequest) throws {
        feedIDs = try request.value("feed_id", as: [String].self)
        let all = try request.value("all", as: Bool.self) ?? false
        if all && feedIDs != nil {
            throw CLIError("invalid_arguments", "Choose --all or repeat --feed-id.")
        }
        if let size = try request.value("size", as: String.self) {
            let dimensions = size.lowercased().split(separator: "x", omittingEmptySubsequences: false)
            guard dimensions.count == 2, let w = Int(dimensions[0]), let h = Int(dimensions[1]),
                  [w, h].allSatisfy({ (2...8192).contains($0) && $0.isMultiple(of: 2) }) else {
                throw CLIError("invalid_arguments", "Choose an even --size WIDTHxHEIGHT between 2 and 8192.")
            }
            (width, height) = (w, h)
        } else {
            (width, height) = (nil, nil)
        }
        let from = try request.value("from", as: String.self)
        let to = try request.value("to", as: String.self)
        switch (from, to) {
        case (nil, nil): range = nil
        case let (from?, to?):
            range = try .init(from: RationalTime(parsing: from), to: RationalTime(parsing: to))
        default: throw CLIError("invalid_arguments", "Supply both --from and --to for a source time range.")
        }
        frameRate = try request.value("frame_rate", as: String.self).map { try RationalTime(parsing: $0) }
        if let color = try request.value("gap_color", as: String.self) {
            var digits = color.lowercased()
            if digits.hasPrefix("#") { digits.removeFirst() }
            if digits.hasPrefix("0x") { digits.removeFirst(2) }
            guard digits.count == 6, let rgb = UInt32(digits, radix: 16) else {
                throw CLIError("invalid_arguments", "Use RRGGBB for --gap-color.")
            }
            gapColor = rgb
        } else {
            gapColor = nil
        }
        guard let framing = ParticipantSlotFraming(rawValue: try request.value("fit", as: String.self) ?? "fit") else {
            throw CLIError("invalid_arguments", "Choose --fit fit or fill.")
        }
        self.framing = framing
        switch try request.value("camera_off", as: String.self) ?? "keep" {
        case "keep": cameraOff = true
        case "blank": cameraOff = false
        default: throw CLIError("invalid_arguments", "Choose --camera-off keep or blank.")
        }
        switch try request.value("on_uncertain", as: String.self) ?? "stop" {
        case "stop": blankUncertain = false
        case "blank": blankUncertain = true
        default: throw CLIError("invalid_arguments", "Choose --on-uncertain stop or blank.")
        }
        audio = try .init(meetingMix: !(request.value("no_meeting_mix", as: Bool.self) ?? false),
                          includeISOs: !(request.value("no_isos", as: Bool.self) ?? false))
        let expected = try request.value("expected_feeds", as: Int.self)
        let maximum = try request.value("max_visible_tiles", as: Int.self)
        guard expected.map({ $0 > 0 }) ?? true, maximum.map({ $0 > 0 }) ?? true else {
            throw CLIError("invalid_arguments", "Use positive counts for the review hints.")
        }
        countHints = expected == nil && maximum == nil ? nil : .init(expectedFeeds: expected, maxVisibleTiles: maximum)
    }
}

private func makeReviewProject(recording: URL, delivery: URL, request: ParticipantRequest, useSidecar: Bool,
                               settings: ISOSettings, progress: MediaProgressOutput, cancelled: @escaping @Sendable () -> Bool) throws -> (URL, CutProject) {
    let media = try CutEngine(cancelled: cancelled, useSidecar: useSidecar).inspectSummary(recording)
    guard media.hasVideo, media.duration > .zero else {
        throw CLIError("missing_picture", "Choose a recording with video.")
    }
    var project = CutProject.sequence([.init(id: "recording", file: recording.path, from: .zero, to: media.duration)])
    let reviewDirectory = delivery.deletingLastPathComponent().appendingPathComponent(
        ".\(delivery.lastPathComponent).mpcut-review", isDirectory: true)
    let document = reviewDirectory.appendingPathComponent("review.cut")
    try project.validateDestination(delivery, relativeTo: document, includesContents: true)
    try project.validateDestination(reviewDirectory, relativeTo: document, includesContents: true)
    if mkdir(reviewDirectory.path, 0o700) != 0 && errno != EEXIST {
        throw CutError(code: "invalid_output", message: "Could not create a private ISO review directory.")
    }
    // The separate file lock permits the normal CutProject directory transaction to save here.
    let reviewLock = reviewDirectory.appendingPathComponent(".lock")
    var entry = stat()
    guard lstat(reviewDirectory.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFDIR,
          (entry.st_mode & 0o077) == 0 else {
        throw CutError(code: "invalid_output", message: "Choose a delivery with a private review directory.")
    }
    let lock = open(reviewLock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw CutError(code: "invalid_output", message: "Could not lock the ISO review directory.") }
    defer { close(lock) }
    guard fstat(lock, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        throw CutError(code: "iso_delivery_busy", message: "Another operation is preparing this ISO review project.")
    }
    if lstat(document.path, &entry) == 0 {
        guard entry.st_mode & S_IFMT == S_IFREG else {
            throw CutError(code: "invalid_output", message: "The ISO review project must be a regular file.")
        }
        let existing = try CutProject.load(from: document)
        guard existing.participants.sources.count == 1, existing.participants.sources[0].sourceID == recording.path,
              !existing.participants.needsReconciliation(sourceID: recording.path, mediaURL: recording) else {
            throw CutError(code: "source_changed", message: "Open the existing review project for this delivery or choose a new output.")
        }
        return (document, existing)
    }
    guard errno == ENOENT else { throw CutError(code: "invalid_output", message: "Could not access the ISO review project.") }
    if lstat(delivery.path, &entry) == 0 {
        guard entry.st_mode & S_IFMT == S_IFDIR else {
            throw CutError(code: "invalid_output", message: "Choose a local, nonsymlink ISO delivery folder.")
        }
        guard try FileManager.default.contentsOfDirectory(atPath: delivery.path).isEmpty else {
            throw CutError(code: "invalid_output", message: "Pass the saved review project to resume an existing ISO delivery, or choose a new folder.")
        }
    } else if errno != ENOENT {
        throw CutError(code: "invalid_output", message: "Could not access the ISO delivery folder.")
    }

    let layout: ParticipantFeedLayout
    if let hint = try request.value("gallery_grid", as: String.self) {
        guard request.fields["feed_layout"] == nil, let choice = ParticipantFeedLayout(galleryGrid: hint) else {
            throw CLIError("invalid_arguments", "Choose --gallery-grid COLSxROWS or --feed-layout.")
        }
        layout = choice
    } else if let value = try request.value("feed_layout", as: String.self) {
        guard let choice = ParticipantFeedLayout(feedLayout: value) else {
            throw CLIError("invalid_arguments", "Choose --feed-layout auto or COLSxROWS.")
        }
        layout = choice
    } else {
        layout = .meeting
    }
    let sampling: ParticipantSampling
    switch try request.value("sampling", as: String.self) ?? "adaptive" {
    case "adaptive": sampling = .adaptive
    case "every-frame": sampling = .everyFrame
    case "sparse": sampling = .sparse
    default: throw CLIError("invalid_arguments", "Choose --sampling adaptive, every-frame or sparse.")
    }
    let backend: ParticipantBackendMode
    switch try request.value("backend", as: String.self) ?? "auto" {
    case "auto": backend = .automatic
    case "cpu-only": backend = .cpu
    case "gpu-required": backend = .gpuRequired
    default: throw CLIError("invalid_arguments", "Choose --backend auto, cpu-only or gpu-required.")
    }
    var options = ParticipantScanOptions(backend: backend, sampling: sampling, includeScenes: false,
                                             useSidecar: useSidecar, feedLayout: layout)
    options.checkpointDirectory = reviewDirectory.appendingPathComponent("scan-checkpoint", isDirectory: true)
    let scan = try ParticipantAnalysis.scanWithStatus(recording, options: options, cancelled: cancelled) {
        isoProgress(progress, phase: $0.phase.rawValue, fraction: Double($0.percent) / 100, sourceTime: $0.time)
    }
    guard !cancelled(), scan.state != .paused else { throw CancellationError() }
    try project.acceptParticipantAnalysis(scan, sourceID: recording.path, relativeTo: document, cancelled: cancelled)
    if let hints = settings.countHints {
        var participants = project.participants
        participants.sources[0].countHints = hints
        project.participants = participants
    }
    try project.save(to: document)
    ParticipantAnalysis.discardCheckpoint(for: scan, directory: options.checkpointDirectory)
    return (document, project)
}

private func isoProgress(_ mode: MediaProgressOutput, phase: String, fraction: Double, sourceTime: RationalTime? = nil) {
    switch mode {
    case .none: break
    case .stderr: progressOutput("\(phase) \(Int(fraction * 100))%")
    case .jsonl:
        struct Event: Encodable {
            let event = "progress"
            let phase: String
            let fraction: Double
            let sourceTime: RationalTime?
            private enum CodingKeys: String, CodingKey { case event, phase, fraction, sourceTime = "source_time" }
        }
        if let bytes = try? JSONEncoder().encode(Event(phase: phase, fraction: fraction, sourceTime: sourceTime)) {
            progressOutput(String(decoding: bytes, as: UTF8.self))
        }
    }
}

private func writePlan(_ plan: TilesISOPlan, to output: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let bytes = try encoder.encode(plan)
    let temporary = output.deletingLastPathComponent().appendingPathComponent(".iso-plan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try bytes.write(to: temporary, options: [.withoutOverwriting])
    let result = publishExclusively(from: temporary, to: output)
    guard result == 0 else {
        throw CutError(code: result == EEXIST ? "output_exists" : "write_failed", message: "\(String(cString: strerror(result))).")
    }
}
