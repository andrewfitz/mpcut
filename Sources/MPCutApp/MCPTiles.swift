import Foundation
import MPCutCore

extension ProjectSessions {
    func mcpTiles(tool: String, arguments: [String: Any], session: ProjectSession,
                  checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        let prefix = "tiles_editor_"
        guard tool.hasPrefix(prefix) else { return nil }
        let operation = String(tool.dropFirst(prefix.count))
        let request = try MCPTilesRequest(arguments)
        let revision = session.mcpRevision
        let mediaRevision = session.multicam.transcriptMediaRevision
        let revisionToken = "\(session.mcpHandle)/\(revision)/\(mediaRevision)"
        let project = session.transcript.project
        let savedDocument = session.isMulticam ? session.multicam.projectURL : session.editor.projectURL
        let draftDocument = session.isMulticam ? session.multicam.draft.url : session.editor.draft.url
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(session.id.uuidString + ".cut")
        let document = savedDocument ?? draftDocument ?? fallback
        let mutates = !["inspect", "preview", "feeds_list", "feeds_inspect", "angles_plan", "angles_render",
                        "angles_verify", "export_isos", "switches_propose", "layout_list"].contains(operation)
            && (operation != "reconcile" || (arguments["apply"] as? Bool ?? false))
            && (operation != "scan" || (arguments["accept"] as? Bool ?? false))
        if mutates {
            guard let expected = arguments["expected_revision"] as? Int else {
                throw MCPCommandError("invalid_arguments", "Supply expected_revision for a Tiles edit.")
            }
            guard expected == revision else {
                throw MCPCommandError("stale_revision", "The project changed. Read the current editor state and retry.")
            }
        }

        let indexes: [@Sendable () throws -> TranscriptIndex]
        if operation == "switches_propose" {
            guard session.isMulticam else {
                throw MCPCommandError("invalid_target", "This operation requires an open multicam project.")
            }
            let ids = (arguments["attachment_id"] as? String).map { [$0] } ?? project.transcripts.attachments.map(\.id)
            indexes = try ids.map { try session.transcript.prepareIndex(attachmentID: $0, clocks: [.source, .group]) }
        } else {
            indexes = []
        }
        let sidecarWork = session.sidecarWork
        let useSidecar = session.isMulticam ? session.multicam.useAnalysisSidecars : session.editor.useAnalysisSidecars
        let progress = MCPLiveOutputProgress()
        let execute: @Sendable () throws -> MCPTilesWork.Result = {
            try MCPTilesWork.run(operation, request: request, project: project, document: document,
                                 revisionToken: revisionToken, indexes: indexes, progress: progress, useSidecar: useSidecar)
        }
        func finish(_ result: MCPTilesWork.Result) throws -> [String: Any] {
            try checkAccess()
            if operation == "switches_propose" || operation == "switches_accept" {
                guard session.multicam.transcriptMediaRevision == mediaRevision else {
                    throw MCPCommandError("stale_tile_switch", "The recording changed. Propose switches again.")
                }
            }
            return try session.finishTiles(result, operation: operation, input: project, revision: revision)
        }
        let dryRun = arguments["dry_run"] as? Bool ?? false
        if operation == "scan" || operation == "angles_render" || (operation == "export_isos" && !dryRun) {
            let receipt = try mcpAnalysisJobs.reserve(session: session, kind: "tiles_" + operation)
            let endWork = receipt.cleanup.begin()
            let work = sidecarWork.detached(priority: .userInitiated, operation: execute)
            receipt.cancelNative = { work.cancel() }
            receipt.nativeProgress = { progress.snapshot["progress"] as? Double }
            Task {
                defer { endWork() }
                do {
                    let result = try await work.value
                    if receipt.cancellationRequested {
                        let partial = try JSONSerialization.jsonObject(with: result.response)
                        receipt.finish("cancelled", detail: ["result": partial])
                    } else {
                        let detail = try finish(result)
                        if operation == "scan", detail["state"] as? String == "incomplete" {
                            receipt.finish("failed", detail: ["result": detail, "code": "incomplete_scan",
                                "error": "The scan has incomplete coverage. Resume from the returned scan or checkpoint."])
                        } else {
                            receipt.finish((detail["status"] as? String) == "needs_review" ? "needs_review" : "succeeded",
                                           detail: ["result": detail])
                        }
                    }
                } catch {
                    if receipt.cancellationRequested || error is CancellationError {
                        receipt.finish("cancelled")
                    } else {
                        let code = (error as? MCPCommandError)?.code ?? (error as? CutError)?.code ?? "operation_failed"
                        receipt.finish("failed", detail: ["error": error.localizedDescription, "code": code])
                    }
                }
            }
            return receipt.snapshot
        }

        let work = sidecarWork.detached(priority: .userInitiated, operation: execute)
        let result = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
        return try finish(result)
    }
}

private extension ProjectSession {
    func finishTiles(_ result: MCPTilesWork.Result, operation: String, input project: CutProject,
                     revision: Int) throws -> [String: Any] {
        guard mcpRevision == revision else {
            throw MCPCommandError("stale_revision", "The project changed. Read the current editor state and retry.")
        }
        if let identity = result.source, !identity.snapshot.isCurrentSnapshot(at: identity.url) {
            throw MCPCommandError("source_changed", "The recording changed. Review the current recording and retry.")
        }
        guard result.response.count < MCPSocket.limit - 4096 else {
            throw MCPCommandError("result_too_large", "The Tiles response is too large for local control. Query a shorter source range.")
        }
        var response = try JSONSerialization.jsonObject(with: result.response) as? [String: Any] ?? [:]
        if let update = result.update, update != project {
            guard mcpCanEditStills else {
                throw MCPCommandError("editor_busy", "Finish the current edit or close the dialog.")
            }
            var participantOnly = project
            participantOnly.participants = update.participants
            switch (project, update) {
            case (_, .multicam(let next)) where operation == "angles_use":
                try commitFeedAngles(next, action: result.action, expectedRevision: revision)
            case _ where update == participantOnly:
                try commitParticipants(update.participants, action: result.action)
            case (.multicam, .multicam(let next)):
                guard multicam.edit(result.action, { $0 = next }) else {
                    throw MCPCommandError("editor_busy", "The multicam project is unavailable for editing.")
                }
            case (.sequence, .sequence), (.sequence, .stillSequence), (.stillSequence, .stillSequence):
                var edit = update
                edit.transcripts = .init()
                try editor.applyStillProject(edit, action: result.action, installsParticipants: true)
            default:
                throw MCPCommandError("invalid_target", "This operation requires an open multicam project.")
            }
        }
        response["revision"] = mcpRevision
        response["project_handle"] = mcpHandle
        return response
    }
}

private struct MCPTilesRequest: Sendable {
    private let data: Data

    init(_ values: [String: Any]) throws {
        data = try JSONSerialization.data(withJSONObject: values)
    }

    func values() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

}

private enum MCPTilesWork {
    struct Result: Sendable {
        let response: Data
        let update: CutProject?
        let action: String
        let source: CheckedSource?

        init(_ response: some Encodable, update: CutProject? = nil, action: String = "", source: CheckedSource? = nil) throws {
            self.response = try MCPSchemas.encodeResult(response)
            self.update = update
            self.action = action
            self.source = source
        }
    }

    struct CheckedSource: Sendable {
        let url: URL
        let snapshot: SourceIdentity

        init(_ url: URL) throws {
            self.url = url
            self.snapshot = try SourceIdentity(url)
        }
    }

    struct Input {
        let values: [String: Any]

        func optional<Value>(_ key: String, as: Value.Type = Value.self) throws -> Value? {
            guard let value = values[key] else { return nil }
            guard let value = value as? Value else { throw invalid("Invalid \(key).") }
            return value
        }

        func required<Value>(_ key: String, as: Value.Type = Value.self) throws -> Value {
            guard let value = try optional(key, as: Value.self) else { throw invalid("Supply \(key).") }
            return value
        }

        func flag(_ key: String) throws -> Bool { try optional(key) ?? false }

        func time(_ key: String) throws -> RationalTime? {
            try optional(key, as: String.self).map(RationalTime.init(parsing:))
        }

        func range() throws -> MulticamRange? {
            switch (try time("from"), try time("to")) {
            case (nil, nil): return nil
            case (let from?, let to?) where from >= .zero && from < to: return .init(from: from, to: to)
            default: throw invalid("Supply from and to as a nonempty source-time range.")
            }
        }

        func url(_ key: String) throws -> URL? {
            try optional(key, as: String.self).map {
                guard $0.hasPrefix("/"), !$0.utf8.contains(0) else { throw invalid("Supply an absolute path for \(key).") }
                return URL(fileURLWithPath: $0).standardizedFileURL
            }
        }

        func decode<Value: Decodable>(_ key: String, as: Value.Type = Value.self) throws -> Value? {
            guard let raw = values[key] else { return nil }
            let data = try JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed)
            do { return try JSONDecoder().decode(Value.self, from: data) }
            catch { throw invalid("Invalid \(key). \(error.localizedDescription)") }
        }

        func invalid(_ message: String) -> MCPCommandError { MCPCommandError("invalid_arguments", message) }
    }

    static func run(_ operation: String, request: MCPTilesRequest, project: CutProject,
                    document: URL, revisionToken: String, indexes: [@Sendable () throws -> TranscriptIndex],
                    progress: MCPLiveOutputProgress, useSidecar: Bool) throws -> Result {
        let input = Input(values: try request.values())
        switch operation {
        case "scan":
            return try scan(input, project: project, document: document, progress: progress, useSidecar: useSidecar)
        case "inspect", "preview", "feeds_list", "feeds_inspect":
            return try review(operation, input, project: project, document: document, useSidecar: useSidecar)
        case "feeds_add":
            var updated = project
            let id = try updated.participants.addFeed(name: input.optional("name", as: String.self))
            try updated.validate()
            return try Result(FeedEditReceipt(operationCount: 1, feedID: id), update: updated, action: "Add Feed")
        case "link", "feeds_rename", "feeds_mic", "feeds_voice", "feeds_prefer", "feeds_merge", "feeds_split":
            return try editFeeds(operation, input, project: project)
        case "accept", "reconcile":
            return try accept(input, project: project, document: document, reconcile: operation == "reconcile",
                              useSidecar: useSidecar)
        case "angles_plan", "angles_render", "angles_verify", "export_isos":
            return try delivery(operation, input, project: project, document: document, progress: progress)
        case "angles_use", "switches_propose", "switches_accept":
            return try angles(operation, input, project: project, document: document, revisionToken: revisionToken,
                              indexes: indexes, useSidecar: useSidecar)
        case "layout_set", "layout_list":
            return try layout(operation, input, project: project, document: document)
        case "box_add", "box_set", "tile_split", "tile_screen_share", "grid_correct", "feeds_confirm", "feeds_treatment":
            return try editTiles(operation, input, project: project, document: document)
        default:
            throw MCPCommandError("unsupported_tool", "This editor does not support tiles_editor_\(operation).")
        }
    }

    static func sourceID(_ input: Input, project: CutProject, scanned: Bool = true) throws -> String {
        let ids: [String]
        if scanned {
            ids = project.participants.sources.map(\.sourceID)
        } else {
            switch project {
            case .multicam(let project): ids = project.pictureSources.filter { $0.feedAngle == nil }.map(\.id)
            case .sequence, .stillSequence: ids = Array(Set(project.sequenceClips?.map(\.file) ?? [])).sorted()
            }
        }
        if let id = try input.optional("source_id", as: String.self) {
            guard ids.contains(id) else { throw MCPCommandError("unknown_source", "Unknown picture source \(id).") }
            return id
        }
        guard let id = ids.first else {
            throw MCPCommandError("unknown_source", "This project has no eligible picture sources.")
        }
        guard ids.count == 1 else {
            throw input.invalid("Supply source_id to choose a recording. Available IDs: \(ids.sorted().joined(separator: ", ")).")
        }
        return id
    }

    static func sourceURL(_ id: String, project: CutProject, document: URL) throws -> URL {
        let path: String
        if case .multicam(let multicam) = project {
            guard let source = multicam.pictureSources.first(where: { $0.id == id }) else {
                throw MCPCommandError("invalid_target", "Unknown picture source \(id).")
            }
            path = source.file
        } else {
            path = id
        }
        return try CutProject.checkedMediaURL(path, relativeTo: document)
    }

    static func scan(_ input: Input, project: CutProject, document: URL, progress: MCPLiveOutputProgress,
                     useSidecar: Bool) throws -> Result {
        let id = try sourceID(input, project: project, scanned: false)
        let source = try CheckedSource(sourceURL(id, project: project, document: document))
        let store = TilesPendingReviewStore(project: document, recordingID: id)
        let output = try input.url("output")
        let resumeFile = try input.url("resume_file")
        let resume = try input.flag("resume")
        guard !resume || resumeFile == nil else {
            throw input.invalid("Use resume for the latest saved scan, or choose resume_file.")
        }
        let partial: ParticipantScanResult?
        if let resumeFile {
            partial = try readScan(resumeFile)
        } else if resume, let output {
            guard FileManager.default.fileExists(atPath: output.appendingPathExtension("checkpoints")
                .appendingPathComponent("manifest.json").path) else {
                throw input.invalid("Choose the output of an interrupted scan with a checkpoint.")
            }
            partial = nil
        } else if resume {
            guard let scan = try store.load(recording: source.url)?.0, scan.state == .paused || scan.state == .incomplete else {
                throw input.invalid("This recording has no paused or incomplete scan to resume.")
            }
            partial = scan
        } else {
            partial = nil
        }
        let backend: ParticipantBackendMode
        switch try input.optional("backend", as: String.self) {
        case "auto": backend = .automatic
        case "cpu-only": backend = .cpu
        case "gpu-required": backend = .gpuRequired
        case nil: backend = partial?.configuration.backend ?? .automatic
        default: throw input.invalid("Choose backend auto, cpu-only or gpu-required.")
        }
        let sampling: ParticipantSampling
        switch try input.optional("sampling", as: String.self) {
        case "adaptive": sampling = .adaptive
        case "every-frame": sampling = .everyFrame
        case "sparse": sampling = .sparse
        case nil: sampling = partial?.configuration.sampling ?? .adaptive
        default: throw input.invalid("Choose sampling adaptive, every-frame or sparse.")
        }
        let layout: ParticipantFeedLayout
        let gallery = try input.optional("gallery_grid", as: String.self)
        let feedLayout = try input.optional("feed_layout", as: String.self)
        if let gallery {
            guard feedLayout == nil, let parsed = ParticipantFeedLayout(galleryGrid: gallery) else {
                throw input.invalid("Choose a gallery grid as COLSxROWS, without feed_layout.")
            }
            layout = parsed
        } else if let specified = feedLayout {
            guard let parsed = ParticipantFeedLayout(feedLayout: specified) else {
                throw input.invalid("Choose feed layout auto or a grid specified as COLSxROWS.")
            }
            layout = parsed
        } else {
            layout = partial?.configuration.feedLayout ?? .meeting
        }
        let noSidecar = try input.flag("no_sidecar")
        var options = try ParticipantScanOptions(backend: backend, sampling: sampling,
                                                 includeScenes: input.optional("include_scenes") ?? partial?.configuration.includeScenes ?? false,
                                                 useSidecar: useSidecar && !noSidecar, feedLayout: layout)
        if let output {
            guard output.pathExtension.lowercased() == "json" else {
                throw input.invalid("Choose a new .json destination for the scan.")
            }
            try project.validateDestination(output, relativeTo: document)
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw MCPCommandError("output_exists", "Choose a new scan destination.")
            }
            if !options.includeScenes {
                options.checkpointDirectory = output.appendingPathExtension("checkpoints")
            }
        }
        let hints = try merging(countHints(input), into: partial?.countHints)
        var scan = try ParticipantAnalysis.scanWithStatus(source.url, options: options, resuming: partial) { status in
            progress.update(min(0.99, Double(status.percent) / 100))
        }
        scan.countHints = hints
        let finished = scan.state == .completed || scan.state == .upToDate
        var updated: CutProject?
        if !Task.isCancelled, finished, try input.flag("accept") {
            var next = project
            try acceptScan(scan, in: &next, sourceID: id, document: document, hints: hints)
            updated = next
        }
        let analysisFile: URL?
        let checkpointDirectory: URL?
        if let output {
            let checkpoint = options.checkpointDirectory
            let journal = checkpoint?.appendingPathComponent("manifest.json")
            let hasJournal = journal.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            if scan.state != .paused || !hasJournal {
                try writeScan(scan, to: output)
                analysisFile = output
                checkpointDirectory = nil
                ParticipantAnalysis.discardCheckpoint(for: scan, directory: checkpoint)
            } else {
                analysisFile = nil
                checkpointDirectory = checkpoint
            }
        } else {
            analysisFile = try store.save(scan, adoptingCountHints: true)
            checkpointDirectory = nil
        }
        let review = TilesReview(scan: scan, countHints: hints).report(issuesOnly: true)
        return try Result(ScanReceipt(analysisFile: analysisFile?.path, checkpointDirectory: checkpointDirectory?.path,
                                      state: scan.state, sourceID: id,
                                      source: scan.source, counts: review.counts, coverage: review.coverage,
                                      issues: review.issues.filter { $0.kind == .countMismatch }, reviewIssueCount: review.issues.count),
                          update: updated, action: "Accept Tiles", source: source)
    }

    struct ScanReceipt: Encodable {
        let schemaVersion = 1
        let analysisFile: String?
        var checkpointDirectory: String? = nil
        let state: ParticipantScanResult.State
        let sourceID: String
        let source: ParticipantScanSource
        let counts: TilesCounts
        let coverage: [ParticipantCoverage]
        let issues: [TilesIssue]
        let reviewIssueCount: Int

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", analysisFile = "analysis_file", sourceID = "source_id"
            case checkpointDirectory = "checkpoint_directory"
            case state, source, counts, coverage, issues
            case reviewIssueCount = "review_issue_count"
        }
    }

    static func readScan(_ url: URL) throws -> ParticipantScanResult {
        let data = try ClipEditCSV.readListData(url, kind: "Tile scan", maximumBytes: 1024 * 1024 * 1024,
                                                cancelled: { Task.isCancelled })
        if let issue = jsonInputIssue(data) {
            throw MCPCommandError("invalid_json", "The tile scan " + issue + ".")
        }
        return try JSONDecoder().decode(ParticipantScanResult.self, from: data)
    }

    static func accept(_ input: Input, project: CutProject, document: URL, reconcile: Bool, useSidecar: Bool) throws -> Result {
        let path = try input.url("analysis_file")
        let hints = try countHints(input)
        let clear = try input.flag("clear_count_hints")
        guard !clear || hints == nil else { throw input.invalid("Use clear_count_hints without count values.") }
        guard path != nil || (!reconcile && (hints != nil || clear)) else {
            throw input.invalid(reconcile ? "Supply analysis_file." : "Supply analysis_file, count values or clear_count_hints.")
        }
        let id = try sourceID(input, project: project, scanned: reconcile || path == nil)
        var next = project
        guard let path else {
            let previous = project.participants.sources.first { $0.sourceID == id }?.countHints
            try next.participants.setTileCountHints(sourceID: id, hints: clear ? nil : merging(hints, into: previous))
            let review = TilesReview(project: next, sourceID: id, document: document, useSidecar: useSidecar,
                                     cancelled: { Task.isCancelled })
            return try Result(EditReceipt(operationCount: next == project ? 0 : 1, reviewIssueCount: review.issues.count),
                              update: next, action: "Edit Tile Count Hints")
        }
        let source = try CheckedSource(sourceURL(id, project: project, document: document))
        let scan = try readScan(path)
        if reconcile {
            let apply = try input.flag("apply")
            let token = try input.optional("review", as: String.self)
            guard apply == (token != nil) else { throw input.invalid("Use apply with the token from the reconciliation report.") }
            if let token {
                try next.applyReviewedParticipantReconciliation(scan, sourceID: id, relativeTo: document,
                                                                token: token, cancelled: { Task.isCancelled })
                return try Result(EditReceipt(operationCount: next == project ? 0 : 1), update: next,
                                  action: "Reconcile Tiles", source: source)
            }
            let report = try project.participantReconciliation(scan, sourceID: id, relativeTo: document,
                                                               cancelled: { Task.isCancelled })
            return try Result(ReconciliationReceipt(report: report, review: report.reviewToken(for: scan)), source: source)
        }
        try acceptScan(scan, in: &next, sourceID: id, document: document, hints: hints, clear: clear)
        let review = TilesReview(project: next, sourceID: id, document: document, useSidecar: useSidecar,
                                 cancelled: { Task.isCancelled }).report(issuesOnly: true)
        return try Result(ScanReceipt(analysisFile: path.path, state: scan.state, sourceID: id,
                                      source: scan.source, counts: review.counts, coverage: review.coverage,
                                      issues: review.issues.filter { $0.kind == .countMismatch }, reviewIssueCount: review.issues.count),
                          update: next, action: "Accept Tiles", source: source)
    }
}

private extension MCPTilesWork {
    struct ReconciliationReceipt: Encodable {
        let report: ParticipantReconciliation
        let review: String

        enum CodingKeys: String, CodingKey {
            case review, sourceID = "source_id", sourceChanged = "source_changed"
            case retainedCopiedGeometry = "retained_copied_geometry", removedTileIDs = "removed_tile_ids"
            case affectedFeedIDs = "affected_feed_ids", affectedTreatmentIDs = "affected_treatment_ids"
            case affectedBindingIDs = "affected_binding_ids", affectedPresentationIDs = "affected_presentation_ids"
            case removedPreferenceCount = "removed_preference_count"
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(review, forKey: .review)
            try values.encode(report.sourceID, forKey: .sourceID)
            try values.encode(report.sourceChanged, forKey: .sourceChanged)
            try values.encode(report.retainedCopiedGeometry, forKey: .retainedCopiedGeometry)
            try values.encode(report.removedAppearanceIDs, forKey: .removedTileIDs)
            try values.encode(report.affectedParticipantIDs, forKey: .affectedFeedIDs)
            try values.encode(report.affectedRedactionIDs, forKey: .affectedTreatmentIDs)
            try values.encode(report.affectedBindingIDs, forKey: .affectedBindingIDs)
            try values.encode(report.affectedPresentationIDs, forKey: .affectedPresentationIDs)
            try values.encode(report.removedOverrideCount, forKey: .removedPreferenceCount)
        }
    }

    struct EditReceipt: Encodable {
        let operationCount: Int
        var reviewIssueCount: Int?
        var tileID: String?
        var feedID: String?
        var grid: ParticipantGridCorrection?

        enum CodingKeys: String, CodingKey {
            case operationCount = "operation_count", tileID = "tile_id", feedID = "feed_id", grid
            case reviewIssueCount = "review_issue_count"
        }
    }

    static func editTiles(_ operation: String, _ input: Input, project: CutProject, document: URL) throws -> Result {
        let id = try sourceID(input, project: project, scanned: operation != "box_add")
        let checksSource = ["box_add", "feeds_confirm", "grid_correct"].contains(operation)
        let source = checksSource ? try CheckedSource(sourceURL(id, project: project, document: document)) : nil
        var next = project
        var tileID: String?
        var feedID: String?
        var grid: ParticipantGridCorrection?
        let action: String
        switch operation {
        case "box_add":
            let tile = try input.optional("tile_id", as: String.self) ?? UUID().uuidString.lowercased()
            try next.addTileBox(sourceID: id, document: document, appearance: .init(
                id: tile, participantID: input.optional("feed_id"), range: requiredRange(input), bounds: tileBounds(input)))
            tileID = tile
            action = "Add Tile Box"
        case "box_set":
            let tile = try input.required("tile_id", as: String.self)
            let range = try requiredRange(input)
            try next.participants.correctBounds(sourceID: id, appearanceID: tile, bounds: tileBounds(input), range: range)
            if let feed = try input.optional("feed_id", as: String.self) {
                try next.participants.linkAppearance(sourceID: id, appearanceID: tile, participantID: feed, range: range)
            }
            tileID = tile
            action = "Correct Tile Box"
        case "tile_split":
            let tile = try input.required("tile_id", as: String.self)
            let newTile = try input.optional("new_tile_id", as: String.self) ?? UUID().uuidString.lowercased()
            guard let at = try input.time("at") else { throw input.invalid("Supply at.") }
            try next.participants.splitAppearance(sourceID: id, appearanceID: tile, at: at, newAppearanceID: newTile)
            tileID = newTile
            action = "Split Tile"
        case "tile_screen_share":
            let tile = try input.required("tile_id", as: String.self)
            let range = try input.range() ?? tileRange(project, sourceID: id, tileID: tile)
            feedID = try next.participants.setScreenShare(sourceID: id, appearanceID: tile, range: range)
            tileID = tile
            action = "Mark Screen Share"
        case "grid_correct":
            let value = try input.required("grid", as: String.self)
            guard case .fixed(let columns, let rows) = ParticipantFeedLayout(feedLayout: value) else {
                throw input.invalid("Supply a grid as COLSxROWS with one to 64 cells.")
            }
            grid = try next.correctTileGrid(sourceID: id, document: document, range: requiredRange(input),
                                            columns: Int(columns), rows: Int(rows), cancelled: { Task.isCancelled })
            action = "Correct Tile Grid"
        case "feeds_confirm":
            try next.confirmParticipantPrivacy(sourceID: id, participantID: input.required("feed_id"),
                                               range: input.range(), relativeTo: document)
            action = "Confirm Feed"
        case "feeds_treatment":
            let raw = try input.required("treatment", as: String.self)
            let mode = ParticipantFeedTreatment.Mode(rawValue: raw)
            guard raw == "none" || mode != nil else { throw input.invalid("Choose none, blur, cover or remove.") }
            guard input.values["color"] == nil || mode == .cover else { throw input.invalid("Use color with cover.") }
            let color = try rgb(input, key: "color", allowInteger: true) ?? 0
            next = try next.settingFeedTreatment(feedID: input.required("feed_id"),
                                                 treatment: mode.map { .init(mode: $0, color: color) })
            action = "Change Feed Treatment"
        default:
            throw input.invalid("Unknown tile edit.")
        }
        return try Result(EditReceipt(operationCount: next == project ? 0 : 1, tileID: tileID, feedID: feedID, grid: grid),
                          update: next, action: action, source: source)
    }

    static func tileBounds(_ input: Input) throws -> ParticipantBounds {
        if let text = input.values["bounds"] as? String {
            let fields = text.split(separator: ",", omittingEmptySubsequences: false)
            let values = fields.compactMap { Double($0) }
            guard fields.count == 4, values.count == 4, values.allSatisfy(\.isFinite) else {
                throw input.invalid("Supply normalized bounds as X,Y,WIDTH,HEIGHT.")
            }
            return .init(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        guard let bounds: ParticipantBounds = try input.decode("bounds") else { throw input.invalid("Supply bounds.") }
        return bounds
    }

    static func requiredRange(_ input: Input) throws -> MulticamRange {
        guard let range = try input.range() else { throw input.invalid("Supply both from and to.") }
        return range
    }

    static func tileRange(_ project: CutProject, sourceID: String, tileID: String) throws -> MulticamRange {
        let appearances = project.participants.sources.first { $0.sourceID == sourceID }?.appearances
            .filter { $0.id == tileID } ?? []
        guard let from = appearances.map(\.range.from).min(), let to = appearances.map(\.range.to).max() else {
            throw MCPCommandError("unknown_tile", "No tile has the requested ID on the selected recording.")
        }
        return .init(from: from, to: to)
    }
}

private extension MCPTilesWork {
    static func writeScan(_ scan: ParticipantScanResult, to output: URL) throws {
        let stage = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stage) }
        try Data().write(to: stage, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: stage)
        defer { try? handle.close() }
        try scan.writeJSON(pretty: false) { data in try handle.write(contentsOf: data) }
        try handle.synchronize()
        try FileManager.default.linkItem(at: stage, to: output)
    }

    struct DeliveryReceipt: Encodable {
        let schemaVersion = 1
        let status: String
        let sourceID: String
        let issues: [TilesISOIssue]
        let warnings: [TilesISOIssue]
        let suggestedNextTool: String
        var output: String?
        var manifestPath: String?
        var projectPath: String?
    }

    static func delivery(_ operation: String, _ input: Input, project: CutProject, document: URL,
                         progress: MCPLiveOutputProgress) throws -> Result {
        let cancelled: @Sendable () -> Bool = { Task.isCancelled }
        if operation == "angles_verify" {
            guard let output = try input.url("output") else { throw input.invalid("Supply output.") }
            return try Result(TilesISODelivery.verify(output, cancelled: cancelled))
        }
        let plan: TilesISOPlan
        if let saved = try input.url("plan") {
            guard Set(input.values.keys).isSubset(of: ["project_handle", "expected_revision", "operation_id", "plan", "output", "resume"]) else {
                throw input.invalid("Use plan with output or resume.")
            }
            let data = try ClipEditCSV.readListData(saved, kind: "ISO plan", cancelled: cancelled)
            if let issue = jsonInputIssue(data) {
                throw MCPCommandError("invalid_json", "The ISO plan " + issue + ".")
            }
            let savedPlan = try JSONDecoder().decode(TilesISOPlan.self, from: data)
            plan = savedPlan.requiresReview
                ? try TilesISODelivery.validatedPlan(savedPlan, project: project, document: document, cancelled: cancelled)
                : savedPlan
        } else {
            let id = try sourceID(input, project: project)
            let ids = try selectedFeeds(input)
            let width: Int?
            let height: Int?
            if let size = try input.optional("size", as: String.self) {
                let dimensions = size.lowercased().split(separator: "x", omittingEmptySubsequences: false)
                guard dimensions.count == 2, let w = Int(dimensions[0]), let h = Int(dimensions[1]),
                      [w, h].allSatisfy({ (2...8192).contains($0) && $0.isMultiple(of: 2) }) else {
                    throw input.invalid("Choose an even WIDTHxHEIGHT between 2 and 8192.")
                }
                width = w
                height = h
            } else {
                width = nil
                height = nil
            }
            let framing: ParticipantSlotFraming
            if let fit = try input.optional("fit", as: String.self) {
                guard let value = ParticipantSlotFraming(rawValue: fit) else { throw input.invalid("Invalid fit.") }
                framing = value
            } else {
                framing = .fit
            }
            let gapColor = try rgb(input, key: "gap_color")
            let cameraOff = try input.optional("camera_off", as: String.self)
            let uncertainty = try input.optional("on_uncertain", as: String.self)
            plan = try TilesISODelivery.plan(project: project, document: document, sourceID: id, feedIDs: ids, range: input.range(),
                                            width: width, height: height, frameRate: input.time("frame_rate"),
                                            gapColor: gapColor, framing: framing, keepCameraOff: cameraOff != "blank",
                                            blankUncertain: uncertainty == "blank",
                                            audio: .init(meetingMix: !input.flag("no_meeting_mix"),
                                                         includeISOs: !input.flag("no_isos")), cancelled: cancelled)
        }
        if operation == "angles_plan" {
            if let output = try input.url("output") {
                guard output.pathExtension.lowercased() == "json" else {
                    throw input.invalid("Choose a new .json destination for the plan.")
                }
                try project.validateDestination(output, relativeTo: document)
                try JSONEncoder().encode(plan).write(to: output, options: .withoutOverwriting)
            }
            return try Result(plan)
        }
        if plan.requiresReview {
            return try Result(DeliveryReceipt(status: "needs_review", sourceID: plan.sourceID,
                                              issues: plan.issues.filter(\.blocking), warnings: plan.issues.filter { !$0.blocking },
                                              suggestedNextTool: "tiles_editor_inspect"))
        }
        if try input.flag("dry_run") { return try Result(plan) }
        guard let output = try input.url("output") else { throw input.invalid("Supply output.") }
        let manifest = try TilesISODelivery.render(plan, project: project, document: document, to: output, cancelled: cancelled) {
            progress.update($0)
            return !Task.isCancelled
        }
        return try Result(DeliveryReceipt(status: "completed", sourceID: plan.sourceID, issues: [],
                                          warnings: manifest.issues, suggestedNextTool: "tiles_editor_angles_verify",
                                          output: output.path, manifestPath: output.appendingPathComponent("manifest.json").path,
                                          projectPath: output.appendingPathComponent("multicam.cut").path))
    }

    static func selectedFeeds(_ input: Input) throws -> [String]? {
        let ids: [String]?
        if let feed = input.values["feed_id"] as? String { ids = [feed] }
        else { ids = try input.optional("feed_id") }
        let all = try input.flag("all")
        if let ids, ids.isEmpty || Set(ids).count != ids.count || all {
            throw input.invalid("Supply all or distinct feed IDs.")
        }
        return ids
    }

    struct AngleReceipt: Encodable {
        let operationCount: Int
        let angles: [MulticamSource]

        enum CodingKeys: String, CodingKey { case operationCount = "operation_count", angles }
    }

    struct SwitchReceipt: Encodable {
        let projectRevision: String
        let links: [TileSpeakerAngle]
        let proposals: [TileSwitchProposal]
    }

    static func angles(_ operation: String, _ input: Input, project: CutProject, document: URL, revisionToken: String,
                       indexes: [@Sendable () throws -> TranscriptIndex], useSidecar: Bool) throws -> Result {
        let cancelled: @Sendable () -> Bool = { Task.isCancelled }
        if operation == "angles_use" {
            let feeds = try selectedFeeds(input)
            let all = try input.flag("all")
            guard all || feeds != nil else { throw input.invalid("Choose all or one or more feed IDs.") }
            let clipID = try input.optional("clip_id", as: String.self)
            let clipSource = clipID.flatMap { id in project.sequenceClips?.first { $0.id == id }?.file }
            let explicitSource = try input.optional("source_id", as: String.self)
            let source = try explicitSource ?? clipSource ?? sourceID(input, project: project)
            let updated = try TileFeedAngles.usingFeeds(in: project, document: document, sourceID: source,
                                                       feedIDs: feeds ?? [], clipID: clipID, useSidecar: useSidecar,
                                                       cancelled: cancelled)
            let next = CutProject.multicam(updated)
            return try Result(AngleReceipt(operationCount: next == project ? 0 : 1,
                                           angles: updated.angles.filter { $0.feedAngle != nil }),
                              update: next, action: "Use Feeds as Multicam Angles")
        }
        guard case .multicam(var multicam) = project else {
            throw MCPCommandError("invalid_target", "This operation requires an open multicam project.")
        }
        switch operation {
        case "switches_propose":
            let loaded = try indexes.map { try $0() }
            guard !loaded.isEmpty else { throw MCPCommandError("transcript_attachment_missing", "No matching transcript attachment.") }
            let mappings = try input.optional("voice_angle", as: [String].self) ?? []
            multicam = try TileSwitches.applyingVoiceOverrides(mappings, in: multicam, indexes: loaded)
            let proposals = try TileSwitches.propose(in: multicam, document: document, indexes: loaded,
                                                     minimumHold: input.time("minimum_hold") ?? .init(numerator: 1),
                                                     revision: revisionToken, useSidecar: useSidecar, cancelled: cancelled)
            return try Result(SwitchReceipt(projectRevision: revisionToken, links: TileSwitches.links(in: multicam, indexes: loaded),
                                            proposals: proposals))
        case "switches_accept":
            guard let proposal: TileSwitchProposal = try input.decode("proposal") else { throw input.invalid("Supply proposal.") }
            let updated = try TileSwitches.accepting(proposal, in: multicam, revision: revisionToken)
            return try Result(EditReceipt(operationCount: updated == multicam ? 0 : 1), update: .multicam(updated),
                              action: "Take \(proposal.angleID) on Dialogue")
        default:
            throw input.invalid("Unknown angle operation.")
        }
    }
}

private extension MCPTilesWork {
    struct LayoutReport: Encodable {
        let layouts: [TileLayoutListing]
    }

    static func layout(_ operation: String, _ input: Input, project: CutProject, document: URL) throws -> Result {
        let clipID = try input.optional("clip_id", as: String.self)
        let source = try input.optional("source_id", as: String.self)
        let available = project.tileLayoutListings
        if case .multicam = project {
            guard clipID == nil, source == nil else {
                throw input.invalid("Group and occurrence layouts apply to the whole multicam project.")
            }
        } else {
            if let clipID, !available.contains(where: { $0.clipID == clipID }) {
                throw MCPCommandError("unknown_clip", "No sequence clip has the requested ID.")
            }
            if let source, !available.contains(where: { $0.sourceID == source }) {
                throw MCPCommandError("unknown_source", "No sequence clip uses the requested source.")
            }
        }
        let entries = available.filter { (clipID == nil || $0.clipID == clipID) && (source == nil || $0.sourceID == source) }

        if operation == "layout_list" { return try Result(LayoutReport(layouts: entries)) }
        let occurrence = try input.optional("occurrence_id", as: String.self)
        let group = try input.flag("group")
        guard [clipID != nil, occurrence != nil, group].filter({ $0 }).count == 1 else {
            throw input.invalid("Address one layout scope with clip_id, occurrence_id or group.")
        }
        let entry: TileLayoutListing?
        let scope: TileLayoutScope
        if let clipID {
            scope = .clip(clipID)
            entry = entries.first { $0.clipID == clipID }
        } else if let occurrence {
            scope = .occurrence(occurrence)
            entry = entries.first { $0.occurrenceID == occurrence }
        } else {
            scope = .group
            entry = entries.first { $0.clock == "group" && $0.occurrenceID == nil }
        }
        guard let entry else { throw input.invalid("The layout scope is unavailable in this project.") }
        let range = try input.range() ?? entry.range
        let name = try input.required("layout", as: String.self)
        guard let layout = ParticipantShotLayout(rawValue: name == "side-by-side" ? "pair" : name) else {
            throw input.invalid("Choose original, arranged, solo, side-by-side or grid.")
        }
        let feeds = try selectedFeeds(input) ?? []
        let explicit: [ParticipantSlot]
        if let raw = try? input.optional("slot", as: [String].self) {
            explicit = try raw.map {
                let data = Data($0.utf8)
                if let issue = jsonInputIssue(data) { throw input.invalid("The slot " + issue + ".") }
                return try JSONDecoder().decode(ParticipantSlot.self, from: data)
            }
        } else {
            explicit = try input.decode("slot") ?? []
        }
        guard feeds.isEmpty || explicit.isEmpty else { throw input.invalid("Choose either feed_id or slot.") }
        let slots = explicit.isEmpty ? feeds.map { ParticipantSlot(id: $0) } : explicit
        guard layout != .original || slots.isEmpty else { throw input.invalid("Choose Original without feeds or slots.") }
        let span = layout == .original && occurrence == nil
            ? nil : try TileLayoutSpan(range: range, layout: layout, slots: slots, compact: input.flag("compact"))
        let next = try project.settingTileLayout(scope: scope, range: range, layout: span, relativeTo: document)
        return try Result(EditReceipt(operationCount: next == project ? 0 : 1), update: next, action: "Set Tile Layout")
    }

    static func rgb(_ input: Input, key: String, allowInteger: Bool = false) throws -> UInt32? {
        guard let raw = input.values[key] else { return nil }
        if allowInteger, let integer = raw as? UInt32, integer <= 0xFFFFFF { return integer }
        if var text = raw as? String {
            text = text.lowercased()
            if text.hasPrefix("#") { text.removeFirst() }
            if text.hasPrefix("0x") { text.removeFirst(2) }
            if (allowInteger ? (1...6).contains(text.count) : text.count == 6),
               let rgb = UInt32(text, radix: 16) { return rgb }
        }
        throw input.invalid("Supply \(key) as an RRGGBB color.")
    }
}

private extension MCPTilesWork {
    struct FeedList: Encodable {
        let schemaVersion = 1
        let sourceID: String
        let counts: TilesCounts
        let feeds: [TilesFeed]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", sourceID = "source_id", counts, feeds
        }
    }

    struct PreviewReceipt: Encodable {
        let schemaVersion = 1
        let sourceID: String
        let sourceTime: RationalTime?
        let issueID: String?
        let output: String
        let space = "source"
        let untreated = true

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", sourceID = "source_id", sourceTime = "source_time"
            case issueID = "issue_id", output, space, untreated
        }
    }

    static func review(_ operation: String, _ input: Input, project: CutProject, document: URL, useSidecar: Bool) throws -> Result {
        let model: TilesReview
        let scan = try input.url("analysis_file").map { try readScan($0) }
        if let scan {
            guard input.values["source_id"] == nil else { throw input.invalid("Choose analysis_file or a project source.") }
            model = .init(scan: scan)
        } else {
            let requested = try input.optional("source_id", as: String.self)
            let scanned = operation != "inspect"
                || project.participants.sources.contains { requested == nil || requested == $0.sourceID }
            model = try .init(project: project, sourceID: sourceID(input, project: project, scanned: scanned), document: document,
                              useSidecar: useSidecar, cancelled: { Task.isCancelled })
        }
        if let clock = try input.optional("clock", as: String.self), clock != "source" {
            throw input.invalid("Choose source time for recording tiles.")
        }
        switch operation {
        case "feeds_list":
            return try Result(FeedList(sourceID: model.sourceID, counts: model.counts, feeds: model.feeds))
        case "feeds_inspect":
            return try Result(model.feed(id: input.required("feed_id")))
        case "inspect":
            let at = try input.time("at")
            guard at.map({ $0 >= .zero }) != false else { throw input.invalid("Choose a nonnegative source time.") }
            let range = try input.range()
            let changes = try input.flag("layout_changes")
            let issues = try input.flag("issues")
            guard (at == nil || range == nil), !(issues && changes) else {
                throw input.invalid("Choose a single time or range and a single report type.")
            }
            if let rule: ParticipantMarkerRule = try input.decode("rule") {
                guard changes else { throw input.invalid("Apply a marker rule to layout changes.") }
                return try Result(model.layoutMarkers(rule: rule, at: at, range: range))
            }
            return try Result(model.report(at: at, range: range, issuesOnly: issues, changesOnly: changes))
        case "preview":
            guard let output = try input.url("output") else { throw input.invalid("Supply output.") }
            try project.validateDestination(output, relativeTo: document)
            if let file = model.mediaURL, file.standardizedFileURL == output {
                throw input.invalid("Choose an output separate from the recording.")
            }
            let at = try input.time("at")
            let issueID = try input.optional("issue_id", as: String.self)
            guard (at != nil) != (issueID != nil) else { throw input.invalid("Supply at or issue_id.") }
            let sourceTime: RationalTime?
            if let at {
                try model.writePreview(at: at, to: output, cancelled: { Task.isCancelled })
                sourceTime = at
            } else {
                guard let issue = model.issues.first(where: { $0.id == issueID }), issue.sourceTime != nil else {
                    throw input.invalid("Choose an issue with a source time.")
                }
                try model.writePreview(issue: issue, to: output, cancelled: { Task.isCancelled })
                sourceTime = issue.sourceTime
            }
            return try Result(PreviewReceipt(sourceID: model.sourceID, sourceTime: sourceTime,
                                             issueID: issueID, output: output.path))
        default:
            throw input.invalid("Unknown Tiles review.")
        }
    }

    static func countHints(_ input: Input) throws -> TilesCountHints? {
        let expected = try input.optional("expected_feeds", as: Int.self)
        let maximum = try input.optional("max_visible_tiles", as: Int.self)
        guard expected.map({ $0 > 0 }) ?? true, maximum.map({ $0 > 0 }) ?? true else {
            throw input.invalid("Use positive counts for the review hints.")
        }
        guard expected != nil || maximum != nil else { return nil }
        return .init(expectedFeeds: expected, maxVisibleTiles: maximum)
    }

    static func acceptScan(_ scan: ParticipantScanResult, in next: inout CutProject,
                           sourceID: String, document: URL, hints: TilesCountHints?, clear: Bool = false) throws {
        let previous = next.participants.sources.first { $0.sourceID == sourceID }
        try next.acceptParticipantAnalysis(scan, sourceID: sourceID, relativeTo: document, cancelled: { Task.isCancelled })
        try next.participants.setTileCountHints(sourceID: sourceID,
            hints: clear ? nil : merging(hints, into: previous == nil ? scan.countHints : previous?.countHints))
    }

    static func merging(_ hints: TilesCountHints?, into previous: TilesCountHints?) -> TilesCountHints? {
        hints?.overriding(previous) ?? previous
    }
}

private extension MCPTilesWork {
    struct FeedEditReceipt: Encodable {
        let schemaVersion = 1
        let operationCount: Int
        var tileID: String?
        var feedID: String?
        var conflicts: [String] = []

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", operationCount = "operation_count", tileID = "tile_id", feedID = "feed_id", conflicts
        }
    }

    static func editFeeds(_ operation: String, _ input: Input, project: CutProject) throws -> Result {
        let source = try sourceID(input, project: project)
        let feed = try input.optional("feed_id", as: String.self)
        let tile = try input.optional("tile_id", as: String.self)
        let clear = try input.flag("clear")
        var next = project
        var resultingFeed = feed
        var conflicts: [String] = []
        let action: String
        if operation == "link" {
            guard let tile, (feed != nil) != clear else { throw input.invalid("Supply a tile_id and either feed_id or clear.") }
            let range = try input.range() ?? tileRange(project, sourceID: source, tileID: tile)
            try next.participants.linkAppearance(sourceID: source, appearanceID: tile, participantID: feed, range: range)
            action = "Link Tile"
        } else {
            guard let feed, let index = project.participants.people.firstIndex(where: { $0.id == feed }) else {
                throw MCPCommandError("unknown_feed", "Choose an existing feed ID.")
            }
            switch operation {
            case "feeds_rename":
                try next.participants.renameFeed(feed, name: input.required("name"))
                action = "Rename Feed"
            case "feeds_mic":
                try next.participants.setFeedMicrophone(feed, binding: microphone(input, clear: clear))
                action = "Set Feed Microphone"
            case "feeds_voice":
                let attachment = try input.optional("attachment_id", as: String.self)
                let speaker = try input.optional("speaker_id", as: String.self) ?? input.optional("track_id", as: String.self)
                if clear, speaker == nil {
                    try next.participants.setFeedVoice(feed, attachmentID: attachment, speakerID: nil)
                } else if !clear, let attachment, let speaker {
                    try next.participants.setFeedVoice(feed, attachmentID: attachment, speakerID: speaker)
                } else {
                    throw input.invalid("Choose attachment_id and speaker_id, or clear.")
                }
                action = "Set Feed Voice"
            case "feeds_prefer":
                guard (tile != nil) != clear else { throw input.invalid("Choose tile_id or clear.") }
                let range: MulticamRange
                if let specified = try input.range() { range = specified }
                else if let tile { range = try tileRange(project, sourceID: source, tileID: tile) }
                else {
                    let end = project.participants.sources.first { $0.sourceID == source }?.appearances.map(\.range.to).max()
                    range = .init(from: .zero, to: end ?? .zero)
                }
                try next.participants.preferTile(sourceID: source, feedID: feed, tileID: tile, range: range)
                action = "Prefer Feed Tile"
            case "feeds_merge":
                let target = try input.required("into_feed_id", as: String.self)
                conflicts = try next.mergeTileFeeds(feed, into: target)
                resultingFeed = target
                action = "Merge Feeds"
            case "feeds_split":
                guard let tile else { throw input.invalid("Supply tile_id.") }
                let id = try input.optional("new_feed_id", as: String.self) ?? UUID().uuidString.lowercased()
                let range = try input.range() ?? tileRange(project, sourceID: source, tileID: tile)
                let name = try input.optional("name", as: String.self) ?? project.participants.people[index].name + " (split)"
                try next.participants.splitFeed(feed, sourceID: source, tileID: tile, range: range, newFeedID: id, name: name)
                resultingFeed = id
                action = "Split Feed"
            default:
                throw input.invalid("Unknown feed edit.")
            }
        }
        try next.validate()
        return try Result(FeedEditReceipt(operationCount: next == project ? 0 : 1, tileID: tile,
                                          feedID: resultingFeed, conflicts: conflicts), update: next, action: action)
    }

    static func microphone(_ input: Input, clear: Bool) throws -> ParticipantAudioBinding? {
        let micID = try input.optional("mic_id", as: String.self)
        let stream = try input.optional("audio_stream_index", as: Int.self)
        let binding = try input.decode("binding", as: ParticipantAudioBinding.self)
        if clear {
            guard micID == nil, stream == nil, binding == nil else { throw input.invalid("Use clear without an audio binding.") }
            return nil
        }
        if let binding {
            guard micID == nil, stream == nil else { throw input.invalid("Use binding or mic_id, without combining them.") }
            return binding
        }
        guard let micID else { throw input.invalid("Supply mic_id, binding or clear.") }
        return stream.map { .init(selection: .init(source: micID, stream: $0)) } ?? .init(laneID: micID)
    }
}
