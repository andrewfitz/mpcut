import Darwin
import Foundation
import MPCutCore

@MainActor
final class MCPTranscriptPlans {
    private struct Entry {
        let owner: String
        let plan: TranscriptEditPlan
        let expires: ContinuousClock.Instant
    }

    private var entries: [UUID: Entry] = [:]

    func add(_ plan: TranscriptEditPlan, owner: String) throws -> UUID {
        prune()
        guard entries.count < 16 else {
            throw MCPCommandError("jobs_busy", "Review or discard outstanding transcript plans before creating another.")
        }
        let id = UUID()
        entries[id] = Entry(owner: owner, plan: plan, expires: .now + .seconds(600))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            self?.prune()
        }
        return id
    }

    func get(_ id: UUID, owner: String) throws -> TranscriptEditPlan {
        prune()
        guard let entry = entries[id], entry.owner == owner else {
            throw MCPCommandError("stale_transcript_plan", "Review the edit again in this project.")
        }
        return entry.plan
    }

    func remove(_ id: UUID) { entries.removeValue(forKey: id) }
    func remove(owner: String) {
        let window = owner.prefix(while: { $0 != "/" }) + "/"
        entries = entries.filter { !$0.value.owner.hasPrefix(window) }
    }
    func removeAll() { entries.removeAll() }

    private func prune() {
        let now = ContinuousClock.now
        entries = entries.filter { $0.value.expires > now }
    }
}

private struct MCPTranscriptArguments {
    let fields: [String: Any]

    var action = ""
    var attachmentID: String? { fields["attachment_id"] as? String }
    var offset: Int { fields["offset"] as? Int ?? 0 }
    var limit: Int { fields["limit"] as? Int ?? 50 }
    var space: TranscriptSpace { (fields["space"] as? String).flatMap(TranscriptSpace.init(rawValue:)) ?? .currentCut }
    var filter: TranscriptFilter {
        TranscriptFilter(speakerID: fields["speaker_id"] as? String,
                         sourceID: fields["source_id"] as? String, trackID: fields["track_id"] as? String,
                         assemblyIndex: fields["assembly_index"] as? Int, clipID: fields["clip_id"] as? String,
                         file: fields["file"] as? String,
                         includeInferred: fields["include_inferred"] as? Bool ?? false,
                         laneID: fields["lane_id"] as? String)
    }

    func string(_ key: String) throws -> String {
        guard let value = fields[key] as? String, !value.isEmpty, !value.utf8.contains(0) else {
            throw MCPCommandError("invalid_arguments", "Supply \(key).")
        }
        return value
    }

    func path(_ key: String) throws -> URL {
        let value = try string(key)
        guard value.hasPrefix("/") else { throw MCPCommandError("invalid_arguments", "Supply an absolute path for \(key).") }
        return URL(fileURLWithPath: value)
    }

    func id(_ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try string(key)) else {
            throw MCPCommandError("invalid_arguments", "Supply a UUID in \(key).")
        }
        return id
    }

    func decode<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
        guard let value = fields[key] else { throw MCPCommandError("invalid_arguments", "Supply \(key).") }
        do {
            let normalized = try normalize(value, key: key)
            return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: normalized, options: .fragmentsAllowed))
        } catch {
            throw MCPCommandError("invalid_arguments", "Invalid \(key). \(error)")
        }
    }

    private func normalize(_ value: Any, key: String) throws -> Any {
        try TranscriptRequestJSON.normalize(value, key: key)
    }

    func page<T: Encodable>(_ items: [T]) throws -> [String: Any] {
        try boundedPage { limit in
            let rows = Array(items.dropFirst(offset).prefix(limit))
            var page: [String: Any] = ["items": try transcriptMCPJSON(rows), "total": items.count]
            if offset < items.count && offset + rows.count < items.count { page["next_offset"] = offset + rows.count }
            return page
        }
    }

    func boundedPage(_ build: (Int) throws -> [String: Any]) throws -> [String: Any] {
        var requested = limit
        while true {
            let page = try build(requested)
            let bytes = try JSONSerialization.data(withJSONObject: page)
            if bytes.count <= 1_000_000 { return page }
            guard requested > 1 else {
                throw MCPCommandError("transcript_item_too_large", "An item exceeds the live response budget. Export the transcript or read it through a file job.")
            }
            requested /= 2
        }
    }
}

private func transcriptMCPJSON<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
}

private func transcriptMCPObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    guard let result = try transcriptMCPJSON(value) as? [String: Any] else {
        throw MCPCommandError("invalid_result", "The transcript operation did not produce an object.")
    }
    return result
}

private func prepareTranscriptMCP<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    let task = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        return try work()
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Keep one merged index per open project. The attachment indexes themselves
/// already live in the controller's cache, including when there is just one.
final class MCPTranscriptProjectIndexCache: @unchecked Sendable {
    private struct Entry {
        let identities: [TranscriptIndex.CacheIdentity]
        let space: TranscriptSpace
        let index: TranscriptProjectIndex
    }

    private let lock = NSLock()
    private var entry: Entry?

    func index(for indexes: [TranscriptIndex], space: TranscriptSpace) -> TranscriptProjectIndex {
        guard indexes.count > 1 else { return TranscriptProjectIndex(indexes: indexes, space: space) }
        let identities = indexes.map(\.cacheIdentity)
        return lock.withLock {
            if let entry, entry.space == space, entry.identities.count == identities.count,
               zip(entry.identities, identities).allSatisfy({ $0 === $1 }) {
                return entry.index
            }
            let index = TranscriptProjectIndex(indexes: indexes, space: space)
            entry = Entry(identities: identities, space: space, index: index)
            return index
        }
    }
}

private struct TranscriptMCPJobSummary: Encodable {
    let jobID: UUID
    let attemptID: UUID?
    let state: TranscriptJobState
    let updatedAt: Date?
    let attached: Bool
    let savedAttachment: Bool

    private enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case attemptID = "attempt_id"
        case state
        case updatedAt = "updated_at"
        case attached
        case savedAttachment = "saved_attachment"
    }

    init(_ record: TranscriptJobRecord, attached: Bool, preparing: Bool = false) {
        jobID = record.id
        attemptID = preparing ? nil : record.preparationID
        state = preparing ? .preparing : record.state
        updatedAt = preparing ? nil : record.updatedAt
        savedAttachment = !preparing && record.attached
        self.attached = !preparing && attached
    }
}

private struct TranscriptMCPJobTrack: Encodable {
    let sessionID: String?
    let fingerprint: String?
    let track: TranscriptLaneReadout<TranscriptJobTrack>

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case fingerprint
        case track
    }

    init(_ track: TranscriptJobTrack, session: TranscriptJobSession? = nil, lane: TranscriptLaneMetadata? = nil) {
        self.sessionID = session?.id
        self.fingerprint = session?.fingerprint
        var track = track
        track.audio = nil
        track.result = nil
        track.activity = nil
        self.track = .init(track, lane: lane)
    }
}

private struct TranscriptMCPBinding: Encodable {
    let trackID: String
    let sourceStatus: TranscriptBindingStatus
    let binding: TranscriptBinding?

    private enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case sourceStatus = "source_status"
        case binding
    }
}

private struct TranscriptMCPAttachment: Encodable {
    let id: String
    let asset: TranscriptAsset
    let assetStatus: TranscriptAssetStatus
    let resultID: String
    let importOrigin: RationalTime?
    let fingerprint: String?
    let bindingCount: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case asset
        case assetStatus = "asset_status"
        case resultID = "result_id"
        case importOrigin = "import_origin"
        case fingerprint
        case bindingCount = "binding_count"
    }

    init(_ item: TranscriptAttachment, context: URL) {
        id = item.id
        asset = item.asset
        assetStatus = TranscriptStore.assetStatus(item.asset, relativeTo: context)
        resultID = item.resultID
        importOrigin = item.importOrigin
        fingerprint = item.fingerprint
        bindingCount = item.bindings.count
    }
}

private struct TranscriptMCPScriptBeat: Encodable {
    let beat: Int
    let text: String
    let status: TranscriptScriptStatus
    let candidateCount: Int
    let qualifierCount: Int
    let approximateSearch: Bool

    private enum CodingKeys: String, CodingKey {
        case beat
        case text
        case status
        case candidateCount = "candidate_count"
        case qualifierCount = "qualifier_count"
        case approximateSearch = "approximate_search"
    }
}

private struct TranscriptMCPQualifier: Encodable {
    let qualifier: Int
    let text: String
    let presentCount: Int
    let absentCount: Int

    private enum CodingKeys: String, CodingKey {
        case qualifier
        case text
        case presentCount = "present_count"
        case absentCount = "absent_count"
    }
}

private func transcriptMCPJob(_ record: TranscriptJobRecord, attached: Bool, arguments: MCPTranscriptArguments) throws -> [String: Any] {
    var result = try transcriptMCPObject(TranscriptMCPJobSummary(record, attached: attached))
    let tracks = record.sessions.flatMap { session in
        session.tracks.map { TranscriptMCPJobTrack($0, session: session) }
    }
    result["policy"] = record.policy.rawValue
    result["message"] = record.message.map { String($0.prefix(4096)) }
    result["warning_count"] = record.warnings.count
    result["recognition_duration_seconds"] = record.sessions.reduce(0) { $0 + $1.recognitionDurationSeconds }
    let page = if arguments.action == "warnings" { try arguments.page(record.warnings) }
        else { try arguments.page(tracks) }
    result.merge(page, uniquingKeysWith: { old, _ in old })
    return result
}

extension ProjectSessions {
    func mcpTranscript(tool: String, arguments: [String: Any], session: ProjectSession,
                       checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        switch tool {
        case "transcript_editor_attachments_list":
            return try await mcpReadTranscript(.init(fields: arguments, action: "inspect"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_words_read":
            return try await mcpReadTranscript(.init(fields: arguments, action: "read"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_words_search":
            return try await mcpReadTranscript(.init(fields: arguments, action: "search"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_occurrences_locate":
            return try await mcpReadTranscript(.init(fields: arguments, action: "locate"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_attachment_tracks_list":
            return try await mcpReadTranscript(.init(fields: arguments, action: "tracks"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_speakers_list":
            return try await mcpReadTranscript(.init(fields: arguments, action: "speakers"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_word_evidence_read":
            return try await mcpReadTranscript(.init(fields: arguments, action: "evidence"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_track_activity_read":
            return try await mcpReadTranscript(.init(fields: arguments, action: "activity"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_coverage_read":
            return try await mcpReadTranscript(.init(fields: arguments, action: "coverage"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_occurrence_seek":
            return try await mcpReadTranscript(.init(fields: arguments, action: "seek"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_takes_compare":
            return try await mcpReadTranscript(.init(fields: arguments, action: "compare"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_edits_suggest":
            return try await mcpReadTranscript(.init(fields: arguments, action: "suggest"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_word_candidates_list":
            return try await mcpReadTranscript(.init(fields: arguments, action: "candidates"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_authored_changes_list":
            return try await mcpReadTranscript(.init(fields: arguments, action: "authored"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_bindings_list":
            return try await mcpReadTranscript(.init(fields: arguments, action: "bindings"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_script_align":
            return try await mcpReadTranscript(.init(fields: arguments, action: "align-script"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_script_candidates_list":
            return try await mcpReadTranscript(.init(fields: arguments, action: "script-candidates"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_script_qualifiers_list":
            return try await mcpReadTranscript(.init(fields: arguments, action: "script-qualifiers"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_selection_resolve":
            return try await mcpEditTranscript(.init(fields: arguments, action: "select"), session: session, checkAccess: checkAccess)
        case "transcript_editor_selection_mark":
            return try await mcpEditTranscript(.init(fields: arguments, action: "mark"), session: session, checkAccess: checkAccess)
        case "transcript_editor_edit_plan":
            return try await mcpEditTranscript(.init(fields: arguments, action: "plan"), session: session, checkAccess: checkAccess)
        case "transcript_editor_edit_apply":
            return try await mcpEditTranscript(.init(fields: arguments, action: "apply"), session: session, checkAccess: checkAccess)
        case "transcript_editor_excerpt_queue":
            return try await mcpEditTranscript(.init(fields: arguments, action: "queue"), session: session, checkAccess: checkAccess)
        case "transcript_editor_plan_discard":
            return try await mcpEditTranscript(.init(fields: arguments, action: "discard"), session: session, checkAccess: checkAccess)
        case "transcript_editor_words_correct":
            return try await mcpEditTranscript(.init(fields: arguments, action: "correct"), session: session, checkAccess: checkAccess)
        case "transcript_editor_excerpt_save":
            return try await mcpEditTranscript(.init(fields: arguments, action: "save-excerpt"), session: session, checkAccess: checkAccess)
        case "transcript_editor_attachment_import":
            return try mcpManageTranscript(.init(fields: arguments, action: "import"), session: session, checkAccess: checkAccess)
        case "transcript_editor_attachment_bind":
            return try mcpManageTranscript(.init(fields: arguments, action: "bind"), session: session, checkAccess: checkAccess)
        case "transcript_editor_attachment_detach":
            return try mcpManageTranscript(.init(fields: arguments, action: "detach"), session: session, checkAccess: checkAccess)
        case "transcript_editor_attachment_export":
            return try mcpManageTranscript(.init(fields: arguments, action: "export"), session: session, checkAccess: checkAccess)
        case "transcript_provider_capabilities_read":
            return try await mcpTranscriptJob(.init(fields: arguments, action: "capabilities"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_tracks_list":
            return try await mcpTranscriptJob(.init(fields: arguments, action: "tracks"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_job_start":
            return try await mcpTranscriptJob(.init(fields: arguments, action: "start"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_jobs_list":
            return try await mcpTranscriptJob(.init(fields: arguments, action: "list"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_job_status_read":
            return try await mcpTranscriptJob(.init(fields: arguments, action: "status"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_job_warnings_list":
            return try await mcpTranscriptJob(.init(fields: arguments, action: "warnings"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_job_cancel":
            return try await mcpTranscriptJob(.init(fields: arguments, action: "cancel"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_job_retry":
            return try await mcpTranscriptJob(.init(fields: arguments, action: "retry"), controller: session.transcript, checkAccess: checkAccess)
        case "transcript_editor_job_reconcile":
            return try await mcpTranscriptJob(.init(fields: arguments, action: "reconcile"), controller: session.transcript, checkAccess: checkAccess)
        default: return nil
        }
    }

    private func mcpReadTranscript(_ a: MCPTranscriptArguments, controller: LiveTranscriptController,
                                   checkAccess: @MainActor () throws -> Void) async throws -> [String: Any] {
        let state = controller.state
        let attachment = try transcriptAttachment(a, controller: controller)
        let clockRevision = controller.timelineRevision
        let scopedActions = ["read", "search", "locate", "compare", "align-script", "script-candidates", "script-qualifiers",
                             "suggest", "coverage"]
        let aggregate = a.attachmentID == nil && a.fields["result_id"] == nil
            && state.attachments.count > 1 && scopedActions.contains(a.action)
        let selected = aggregate ? state.attachments : (attachment.map { [$0] } ?? [])
        var result: [String: Any] = ["transcript_revision": state.revision, "space": a.space.rawValue]
        if scopedActions.contains(a.action) {
            result["attachment_results"] = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.resultID) })
        }
        if !aggregate {
            result["result_id"] = attachment?.resultID
            result["attachment_id"] = attachment?.id
        }
        if a.action == "inspect" {
            let scoped = a.attachmentID != nil || a.fields["result_id"] != nil
            let list = scoped ? attachment.map { [$0] } ?? [] : state.attachments
            var page: [String: Any] = ["items": [], "total": list.count]
            if a.offset < list.count {
                let context = try controller.assetContext()
                page = try a.boundedPage { limit in
                    let rows = list.dropFirst(a.offset).prefix(limit).map { TranscriptMCPAttachment($0, context: context) }
                    var page: [String: Any] = ["items": try transcriptMCPJSON(rows), "total": list.count]
                    let nextOffset = a.offset + rows.count
                    if nextOffset < list.count { page["next_offset"] = nextOffset }
                    return page
                }
            }
            result.merge(page, uniquingKeysWith: { old, _ in old })
            return result
        }
        if ["tracks", "bindings", "evidence", "activity", "candidates"].contains(a.action) {
            guard state.attachments.count < 2 || a.attachmentID != nil || a.fields["result_id"] != nil else {
                throw MCPCommandError("transcript_attachment_required", "Choose the attachment that owns the requested evidence.")
            }
            let document = try controller.document(attachmentID: attachment?.id)
            let page: [String: Any]
            switch a.action {
            case "bindings":
                let context = try controller.assetContext()
                let project = controller.project
                let bindings = Dictionary(uniqueKeysWithValues: (attachment?.bindings ?? []).map { ($0.trackID, $0) })
                page = try a.boundedPage { limit in
                    let items = document.tracks.dropFirst(a.offset).prefix(limit).map { track in
                        let binding = bindings[track.id]
                        return TranscriptMCPBinding(trackID: track.id,
                                                    sourceStatus: binding?.sourceStatus(in: project, relativeTo: context) ?? .unbound,
                                                    binding: binding)
                    }
                    var page: [String: Any] = ["items": try transcriptMCPJSON(items), "total": document.tracks.count]
                    let end = a.offset + items.count
                    if end < document.tracks.count { page["next_offset"] = end }
                    return page
                }
            case "tracks":
                let project = controller.project
                let laneID = a.filter.laneID
                page = try a.page(document.tracks.compactMap { entry -> TranscriptLaneReadout<TranscriptTrack>? in
                    let lane = project.transcriptLane(for: entry, attachment: attachment)
                    guard laneID == nil || lane?.id == laneID else { return nil }
                    var track = entry
                    track.activity = []
                    track.words = nil
                    track.speakers = nil
                    return .init(track, lane: lane)
                })
            case "evidence", "candidates":
                let id = try a.string("word_id")
                let projection = try await controller.indexedTranscript(attachmentID: attachment?.id)
                try checkAccess()
                guard controller.timelineRevision == clockRevision, controller.state.revision == state.revision else {
                    throw MCPCommandError("stale_transcript_plan", "The timeline or attached transcripts changed during the read.")
                }
                let local = projection.locate(wordID: id, space: .source).first
                result["stale_matches"] = local?.staleMatches ?? false
                if let word = document.words.first(where: { $0.id == id }) {
                    page = try a.action == "evidence" ? a.page(word.observations) : a.page(word.candidateTrackIDs ?? [])
                } else if let local {
                    page = try a.action == "evidence"
                        ? a.page(local.observations.isEmpty ? [local.observation].compactMap { $0 } : local.observations)
                        : a.page(local.candidateTrackIDs)
                } else {
                    throw MCPCommandError("transcript_word_unavailable", "The transcript word or cue is unavailable.")
                }
            default:
                let id = try a.string("track_id")
                guard let track = document.tracks.first(where: { $0.id == id }) else {
                    throw MCPCommandError("transcript_track_unavailable", "The transcript track is unavailable.")
                }
                page = try a.page(track.activity)
            }
            result.merge(page, uniquingKeysWith: { old, _ in old })
            return result
        }
        if ["speakers", "authored"].contains(a.action), state.attachments.count > 1,
           a.attachmentID == nil, a.fields["result_id"] == nil {
            throw MCPCommandError("transcript_attachment_required", "Choose the attachment that owns these records.")
        }
        guard !selected.isEmpty else { throw MCPCommandError("missing_transcript", "Choose an attached transcript.") }
        let space = a.space
        func validateRead() throws {
            try checkAccess()
            guard controller.timelineRevision == clockRevision, controller.state.revision == state.revision else {
                throw MCPCommandError("stale_transcript_plan", "The timeline or attached transcripts changed during the read. Refresh the project and retry.")
            }
        }
        if a.action == "coverage", space != .currentCut {
            let builders = try selected.map { try controller.prepareCoverageIndex(attachmentID: $0.id) }
            let filter = a.filter
            let offset = a.offset
            let limit = a.limit
            let trackOffset = a.fields["track_offset"] as? Int ?? 0
            let trackLimit = a.fields["track_limit"] as? Int ?? limit
            let bytes = try await prepareTranscriptMCP {
                let indexes = try builders.map { try $0() }
                let project = TranscriptProjectIndex(indexes: indexes, space: space)
                let args = MCPTranscriptArguments(fields: ["limit": max(limit, trackLimit)])
                let page = try args.boundedPage { cap in
                    let coverage = try project.inputCoverage(filter: filter, offset: offset, limit: min(limit, cap),
                                                             trackOffset: trackOffset, trackLimit: min(trackLimit, cap))
                    var value = try transcriptMCPObject(coverage.gaps)
                    value["tracks"] = try transcriptMCPJSON(coverage.tracks)
                    return value
                }
                return try JSONSerialization.data(withJSONObject: page)
            }
            try validateRead()
            guard let page = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw MCPCommandError("invalid_result", "Transcript coverage did not return a page.")
            }
            result["coverage_available"] = true
            result.merge(page, uniquingKeysWith: { old, _ in old })
            return result
        }
        var fetched: [TranscriptIndex] = []
        for entry in selected {
            fetched.append(try await controller.indexedTranscript(attachmentID: entry.id))
        }
        let indexes = fetched
        let cache = controller.mcpProjectIndexCache
        let index = try await prepareTranscriptMCP { cache.index(for: indexes, space: space) }
        let page: [String: Any]
        switch a.action {
        case "read":
            if let id = a.fields["occurrence_id"] as? String {
                page = try a.page(index.occurrence(id: id, filter: a.filter).map { [$0] } ?? [])
            } else {
                page = try a.boundedPage { limit in
                    try transcriptMCPObject(index.read(filter: a.filter, offset: a.offset, limit: limit))
                }
            }
        case "search":
            guard a.fields["occurrence_id"] == nil else {
                throw MCPCommandError("invalid_arguments", "Use clip_id or assembly_index to filter phrase search, or locate for an exact occurrence ID.")
            }
            let query = try a.string("query")
            page = try a.boundedPage { limit in
                try transcriptMCPObject(index.search(query, filter: a.filter, offset: a.offset, limit: limit))
            }
        case "locate":
            if let id = a.fields["occurrence_id"] as? String {
                let occurrence = index.occurrence(id: id, filter: a.filter)
                let wordID = a.fields["word_id"] as? String
                page = try a.page(occurrence.flatMap { wordID == nil || wordID == $0.wordID ? [$0] : nil } ?? [])
            } else {
                page = try a.page(index.locate(wordID: a.string("word_id"), filter: a.filter))
            }
        case "coverage":
            result["coverage_available"] = true
            let laneID = a.filter.laneID
            let gaps = try await prepareTranscriptMCP { index.gaps.filter { laneID == nil || $0.laneID == laneID } }
            page = try a.page(gaps)
        case "speakers":
            let project = controller.project
            let laneID = a.filter.laneID
            let speakers = try await prepareTranscriptMCP {
                indexes.flatMap { $0.transcriptSpeakerReadouts(project: project, laneID: laneID) }
            }
            page = try a.page(speakers)
        case "authored":
            page = try a.page(indexes.flatMap(\.authoredReview))
        case "seek":
            let id = try a.string("occurrence_id")
            guard let occurrence = index.occurrence(id: id) else {
                throw MCPCommandError("transcript_occurrence_unavailable", "Locate the occurrence in the requested space and current revision.")
            }
            try validateRead()
            try controller.seek(occurrence, space: a.space, attachmentID: attachment?.id)
            result["occurrence"] = try transcriptMCPJSON(occurrence)
            return result
        case "compare", "align-script", "script-candidates", "script-qualifiers", "suggest":
            page = try await mcpTranscriptEditorial(a, index: index)
        default:
            throw MCPCommandError("invalid_arguments", "Unknown transcript read action.")
        }
        try validateRead()
        result.merge(page, uniquingKeysWith: { old, _ in old })
        return result
    }

    private func mcpTranscriptEditorial(_ a: MCPTranscriptArguments, index: TranscriptProjectIndex) async throws -> [String: Any] {
        let action = a.action
        let filter = a.filter
        let offset = a.offset
        let limit = a.limit
        let query = a.fields["query"] as? String ?? ""
        let script = a.fields["script"] as? String ?? ""
        let selectedBeat = a.fields["beat"] as? Int ?? 0
        let qualifier = a.fields["qualifier"] as? Int
        let contextWords = a.fields["context_words"] as? Int ?? 8
        let fillerTerms = a.fields["filler_terms"] as? [String] ?? []
        let bytes = try await prepareTranscriptMCP {
            let words = index.readAll(filter: filter)
            let args = MCPTranscriptArguments(fields: ["offset": offset, "limit": limit])
            let page: [String: Any]
            switch action {
            case "compare":
                page = try args.page(TranscriptEditorial.compare(query, words: words, contextWords: contextWords))
            case "suggest":
                page = try args.page(TranscriptEditorial.suggest(words: words, fillerTerms: fillerTerms))
            default:
                if action == "align-script" {
                    let beats = TranscriptEditorial.alignScriptPage(script, words: words, offset: offset, limit: limit, contextWords: 0)
                    let rows = beats.items.enumerated().map { position, beat in
                        TranscriptMCPScriptBeat(beat: offset + position, text: beat.text, status: beat.status,
                                                candidateCount: beat.candidates.count, qualifierCount: beat.qualifiers.count,
                                                approximateSearch: beat.approximateSearch)
                    }
                    page = try args.boundedPage { limit in
                        let items = Array(rows.prefix(limit))
                        var value: [String: Any] = ["items": try transcriptMCPJSON(items), "total": beats.total]
                        if offset + items.count < beats.total { value["next_offset"] = offset + items.count }
                        return value
                    }
                } else {
                    let context = action == "script-candidates" ? contextWords : 0
                    guard let beat = TranscriptEditorial.alignScriptPage(script, words: words, offset: selectedBeat,
                                                                         limit: 1, contextWords: context).items.first else {
                        throw MCPCommandError("transcript_beat_unavailable", "Choose a beat returned by align-script.")
                    }
                    if action == "script-candidates" {
                        page = try args.page(beat.candidates)
                    } else if let qualifier {
                        guard beat.qualifiers.indices.contains(qualifier) else {
                            throw MCPCommandError("transcript_qualifier_unavailable", "Choose a qualifier returned by script-qualifiers.")
                        }
                        let reason = beat.qualifiers[qualifier]
                        let evidence = reason.presentIn.map { ["occurrence_id": $0, "status": "present"] }
                            + reason.absentFrom.map { ["occurrence_id": $0, "status": "absent"] }
                        page = try args.page(evidence)
                    } else {
                        page = try args.page(beat.qualifiers.enumerated().map { ordinal, reason in
                            TranscriptMCPQualifier(qualifier: ordinal, text: reason.text, presentCount: reason.presentIn.count,
                                                   absentCount: reason.absentFrom.count)
                        })
                    }
                }
            }
            return try JSONSerialization.data(withJSONObject: page)
        }
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw MCPCommandError("invalid_result", "Transcript editorial work did not return a page.")
        }
        return result
    }

    private func transcriptAttachment(_ a: MCPTranscriptArguments, controller: LiveTranscriptController) throws -> TranscriptAttachment? {
        let state = controller.state
        if let expected = a.fields["expected_transcript_revision"] as? Int, UInt64(exactly: expected) != state.revision {
            throw MCPCommandError("stale_transcript_plan", "The transcript changed. Read the current attachment and review the operation again.")
        }
        let attachment: TranscriptAttachment?
        if let id = a.attachmentID {
            attachment = state.attachments.first { $0.id == id }
            guard attachment != nil else { throw MCPCommandError("transcript_unavailable", "The transcript attachment is unavailable.") }
        } else if let expected = a.fields["result_id"] as? String {
            let matches = state.attachments.filter { $0.resultID == expected }
            guard matches.count <= 1 else {
                throw MCPCommandError("transcript_attachment_required", "This result is shared by several attachments. Supply the attachment ID.")
            }
            attachment = matches.first
        } else {
            attachment = state.attachments.first
        }
        if let expected = a.fields["result_id"] as? String, expected != attachment?.resultID {
            throw MCPCommandError("stale_transcript_plan", "The transcript result changed. Read the current attachment and review the operation again.")
        }
        if let expected = a.fields["expected_attachment_results"] as? [String: String] {
            let scoped = a.attachmentID != nil || a.fields["result_id"] != nil
            let visible = scoped ? (attachment.map { [$0] } ?? []) : state.attachments
            guard expected == Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.resultID) }) else {
                throw MCPCommandError("stale_transcript_result", "The set of transcript results changed. Read the project attachments again.")
            }
        }
        return attachment
    }

    /// Word IDs repeat between results, so a selection in a project with several
    /// transcripts has to say which one it reads.
    private func requireTranscriptAttachment(_ a: MCPTranscriptArguments, controller: LiveTranscriptController,
                                             named: [String?]) throws {
        guard controller.state.attachments.count > 1, a.attachmentID == nil, a.fields["result_id"] == nil,
              named.contains(where: { $0 == nil }) else { return }
        throw MCPCommandError("transcript_attachment_required",
                              "Several transcripts are attached. Supply attachment_id, or attachment_id on each selection.")
    }

    private func transcriptSelectionOwner(_ selection: TranscriptWordSelection, controller: LiveTranscriptController) -> String? {
        selection.attachmentID ?? selection.firstOccurrenceID.flatMap { occurrence in
            controller.state.attachments.first { occurrence.hasPrefix("\($0.id.count):\($0.id):") }?.id
        }
    }

    private func mcpManageTranscript(_ a: MCPTranscriptArguments, session: ProjectSession,
                                     checkAccess: () throws -> Void) throws -> [String: Any] {
        let controller = session.transcript
        let attachment = try transcriptAttachment(a, controller: controller)
        let origin: RationalTime? = if let text = a.fields["origin"] as? String {
            try RationalTime(parsing: text)
        } else { nil }
        try checkAccess()
        var result: [String: Any] = [:]
        switch a.action {
        case "import":
            let path = try a.path("path")
            let format: TranscriptFormat = try a.decode("format")
            let bindings: [TranscriptBinding] = a.fields["bindings"] == nil ? [] : try a.decode("bindings")
            let imported = try controller.importTranscript(path, format: format, bindings: bindings, origin: origin,
                                                           replacing: a.attachmentID)
            result["attachment_id"] = imported.id
            result["result_id"] = imported.resultID
            // The caller named the attachment this result supersedes.
            result["replaced"] = a.attachmentID != nil
            result["binding_count"] = imported.bindings.count
        case "bind", "detach":
            let id = try a.string("attachment_id")
            if a.action == "bind" {
                try controller.bind(attachmentID: id, bindings: a.decode("bindings"),
                                    origin: a.fields.keys.contains("origin") ? origin : attachment?.importOrigin)
            } else {
                try controller.detach(attachmentID: id)
            }
            result["attachment_id"] = id
            result["result_id"] = attachment?.resultID
        case "export":
            let output = try a.path("path")
            let format: TranscriptFormat = try a.decode("format")
            let space = a.space
            let aggregate = a.attachmentID == nil && a.fields["result_id"] == nil && controller.state.attachments.count > 1
            let filter = a.filter
            let selected = aggregate ? controller.state.attachments : try [controller.attachment(id: attachment?.id)]
            let builders = try selected.map { try controller.prepareIndex(attachmentID: $0.id) }
            let render: @Sendable () throws -> Data = {
                let indexes = try builders.map { try $0() }
                if let index = indexes.first, indexes.count == 1 {
                    return try TranscriptCodec.encode(index, space: space, format: format, filter: filter)
                }
                return try TranscriptCodec.encode(indexes, space: space, format: format, filter: filter)
            }
            return try mcpOutputJobs.start(owner: session.mcpHandle, revision: controller.timelineRevision) { progress in
                let data = try render()
                let staged = output.deletingLastPathComponent().appendingPathComponent(".mpcut-transcript-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staged) }
                try data.write(to: staged, options: [.withoutOverwriting])
                try Task.checkCancellation()
                let failure = publishExclusively(from: staged, to: output)
                guard failure == 0 else {
                    throw MCPCommandError(failure == EEXIST ? "destination_exists" : "export_failed",
                                          "Could not publish transcript at \(output.path) (\(String(cString: strerror(failure)))).")
                }
                progress.published(output)
                return ["output": output.path, "space": space.rawValue, "format": format.rawValue]
            }
        default:
            throw MCPCommandError("invalid_arguments", "Unknown transcript attachment action.")
        }
        result["transcript_revision"] = controller.state.revision
        return result
    }

    private func mcpEditTranscript(_ a: MCPTranscriptArguments, session: ProjectSession,
                                   checkAccess: @MainActor () throws -> Void) async throws -> [String: Any] {
        let controller = session.transcript
        let attachment = try transcriptAttachment(a, controller: controller)
        let owner = session.mcpHandle
        let scoped = a.attachmentID != nil || a.fields["result_id"] != nil
        var result: [String: Any] = ["transcript_revision": controller.state.revision]
        result["result_id"] = attachment?.resultID
        switch a.action {
        case "select", "mark":
            let selection: TranscriptWordSelection = try a.decode("selection")
            let selectionOwner = transcriptSelectionOwner(selection, controller: controller)
            try requireTranscriptAttachment(a, controller: controller, named: [selectionOwner])
            if scoped, let selectionOwner, selectionOwner != attachment?.id {
                throw MCPCommandError("stale_transcript_plan", "Pin the attachment that owns the named selection.")
            }
            let target = try controller.attachment(id: selectionOwner ?? attachment?.id)
            result["result_id"] = target.resultID
            try checkAccess()
            let resolved = try a.action == "mark"
                ? controller.mark(selection, attachmentID: target.id)
                : controller.select(selection, attachmentID: target.id)
            result["selection"] = try transcriptMCPJSON(resolved)
        case "plan":
            let edit: TranscriptEditRequest = try a.decode("edit")
            try requireTranscriptAttachment(a, controller: controller,
                                            named: (edit.selections + [edit.target].compactMap { $0 })
                                                .map { $0.attachmentID ?? $0.firstOccurrenceID })
            let timelineRevision = controller.timelineRevision
            let transcriptRevision = controller.state.revision
            let work = try controller.preparePlan(edit, attachmentID: attachment?.id)
            let plan = try await prepareTranscriptMCP(work)
            try checkAccess()
            _ = try transcriptAttachment(a, controller: controller)
            guard controller.timelineRevision == timelineRevision, controller.state.revision == transcriptRevision else {
                throw MCPCommandError("stale_transcript_plan", "The project or transcript changed while preparing the edit. Review it again.")
            }
            let details: [String: Any] = [
                "action": plan.action.rawValue,
                "history_action": plan.historyAction,
                "attachment_results": plan.attachmentResults,
                "boundaries": try transcriptMCPJSON(plan.boundaries),
                "selections": try transcriptMCPJSON(plan.selections),
                "affected_speech": try transcriptMCPJSON(Array(plan.affectedSpeech.prefix(32))),
                "affected_speech_count": plan.affectedSpeech.count,
                "unavailable_evidence_attachment_ids": plan.unavailableEvidenceAttachmentIDs,
                "affected_occurrences": plan.affectedOccurrences,
                "previous_duration": try transcriptMCPJSON(plan.previousDuration),
                "duration": try transcriptMCPJSON(plan.duration)
            ]
            result.merge(details, uniquingKeysWith: { old, _ in old })
            result["previous_tier"] = try plan.previousTier.map(transcriptMCPJSON)
            result["tier"] = try plan.tier.map(transcriptMCPJSON)
            result["requested_retained_duration"] = try plan.requestedRetainedDuration.map(transcriptMCPJSON)
            result["retained_duration"] = try plan.retainedDuration.map(transcriptMCPJSON)
            guard try JSONSerialization.data(withJSONObject: result).count <= 1_000_000 else {
                throw MCPCommandError("transcript_plan_too_large", "Review shorter selections in separate plans.")
            }
            result["plan_id"] = try mcpTranscriptPlans.add(plan, owner: owner).uuidString
        case "apply", "queue":
            let id = try a.id("plan_id")
            let plan = try mcpTranscriptPlans.get(id, owner: owner)
            try checkAccess()
            if a.action == "queue" {
                result["queue_id"] = try controller.queue(plan, name: a.string("name")).uuidString
            } else {
                let commit = try controller.apply(plan)
                result["changed"] = commit.undo != nil
            }
            mcpTranscriptPlans.remove(id)
            result["action"] = plan.historyAction
            result["transcript_revision"] = controller.state.revision
        case "discard":
            let id = try a.id("plan_id")
            _ = try mcpTranscriptPlans.get(id, owner: owner)
            mcpTranscriptPlans.remove(id)
            result["discarded"] = true
        case "save-excerpt":
            let id = try a.id("queue_id")
            let output = try a.path("path")
            let save = try controller.prepareExcerptSave(id, to: output)
            try checkAccess()
            return try mcpOutputJobs.start(owner: owner, revision: controller.timelineRevision) { progress in
                try Task.checkCancellation()
                try save()
                progress.published(output)
                return ["output": output.path, "queue_id": id.uuidString]
            }
        case "correct":
            let change: TranscriptAuthoredChange = try a.decode("change")
            let selections: [TranscriptWordSelection]
            if a.fields["selections"] != nil {
                guard a.fields["selection"] == nil else {
                    throw MCPCommandError("invalid_arguments", "Supply selection or selections.")
                }
                selections = try a.decode("selections")
            } else {
                selections = a.fields["selection"] == nil ? [] : [try a.decode("selection")]
            }
            let selectionOwners = selections.map { transcriptSelectionOwner($0, controller: controller) }
            try requireTranscriptAttachment(a, controller: controller, named: selectionOwners.isEmpty ? [nil] : selectionOwners)
            let target = scoped ? attachment?.id : selectionOwners.compactMap { $0 }.first ?? attachment?.id
            guard selectionOwners.allSatisfy({ $0 == nil || $0 == target }) else {
                throw MCPCommandError("transcript_attachment_required", "Record corrections separately for each transcript attachment.")
            }
            let targetAttachment = try controller.attachment(id: target)
            try checkAccess()
            let record = try controller.correct(change, selections: selections, attachmentID: targetAttachment.id)
            result["result_id"] = targetAttachment.resultID
            switch change {
            case .namedSelect: result["action"] = "Name Transcript Select"
            case .pauseProtection: result["action"] = "Protect Transcript Pause"
            default: result["action"] = "Correct Transcript"
            }
            result["record_id"] = record.id
            result["transcript_revision"] = controller.state.revision
        default:
            throw MCPCommandError("invalid_arguments", "Unknown transcript edit action.")
        }
        return result
    }

    private func mcpTranscriptJob(_ a: MCPTranscriptArguments, controller: LiveTranscriptController,
                                  checkAccess: () throws -> Void) async throws -> [String: Any] {
        let attachment = try transcriptAttachment(a, controller: controller)
        switch a.action {
        case "capabilities":
            let data = try await controller.capabilities()
            try checkAccess()
            guard data.count <= 1_000_000,
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPCommandError("invalid_result", "Transcriberrr returned an invalid capabilities response.")
            }
            return result
        case "tracks":
            let options: TranscriptJobOptions = a.fields["options"] == nil ? .init() : try a.decode("options")
            let revision = controller.timelineRevision
            let project = controller.project
            let tracks = try await controller.tracks(options: options)
            try checkAccess()
            guard controller.timelineRevision == revision else {
                throw MCPCommandError("stale_revision", "The project changed while reading tracks. Read the tracks again.")
            }
            let laneID = a.filter.laneID
            var duration = 0.0
            let rows = tracks.compactMap { track -> TranscriptMCPJobTrack? in
                let lane = project.transcriptLane(for: track)
                guard laneID == nil || lane?.id == laneID else { return nil }
                duration += track.recognize ? track.duration.seconds : 0
                return .init(track, lane: lane)
            }
            var result = try a.page(rows)
            result["recognition_duration_seconds"] = duration
            return result
        case "start":
            let options: TranscriptJobOptions = a.fields["options"] == nil ? .init() : try a.decode("options")
            let policy: TranscriptJobPolicy = a.fields["policy"] == nil ? .reuse : try a.decode("policy")
            let operation = try a.id("operation_id")
            // A new job extracts every recording's audio. A helper that is missing or cannot
            // run sessions is reported here, before that work starts.
            if controller.activeJobID != operation, (try? controller.status(operation)) == nil {
                try await controller.checkHelper()
                try checkAccess()
            }
            let id = try controller.start(options: options, operationID: operation, policy: policy,
                                          download: a.fields["download"] as? Bool ?? false)
            return ["job_id": id.uuidString, "state": (try? controller.status(id).state.rawValue) ?? "preparing"]
        case "retry":
            let id = try a.id("job_id")
            try controller.retry(id, download: a.fields["download"] as? Bool ?? false)
            return ["job_id": id.uuidString]
        case "reconcile":
            guard let attachment else { throw MCPCommandError("missing_transcript", "Choose a generated transcript attachment.") }
            try checkAccess()
            let id = try controller.reconcile(attachmentID: attachment.id, download: a.fields["download"] as? Bool ?? false)
            return ["job_id": id.uuidString, "state": "preparing", "attachment_id": attachment.id,
                    "transcript_revision": controller.state.revision]
        case "list":
            return try a.page(controller.jobs().map {
                TranscriptMCPJobSummary($0, attached: controller.isAttached($0),
                                        preparing: isStartingTranscriptAttempt($0, controller: controller))
            })
        case "status", "cancel", "warnings":
            let id = try a.id("job_id")
            let record: TranscriptJobRecord
            do {
                record = try a.action == "cancel" ? controller.cancel(id) : controller.status(id)
            } catch let error as CutError where error.code == "unknown_transcript_job" && controller.activeJobID == id {
                return ["job_id": id.uuidString, "state": a.action == "cancel" ? "cancelling" : "preparing",
                        "items": [], "total": 0, "attached": false]
            }
            if a.action != "cancel", isStartingTranscriptAttempt(record, controller: controller) {
                return ["job_id": id.uuidString, "state": "preparing", "items": [], "total": 0, "attached": false]
            }
            var result = try transcriptMCPJob(record, attached: controller.isAttached(record), arguments: a)
            if controller.job?.id == record.id {
                result["attachment_error"] = controller.jobError.map { String($0.prefix(4096)) }
            }
            return result
        default:
            throw MCPCommandError("invalid_arguments", "Unknown transcript job action.")
        }
    }

    private func isStartingTranscriptAttempt(_ record: TranscriptJobRecord, controller: LiveTranscriptController) -> Bool {
        controller.activeJobID == record.id && controller.job == nil && ![.preparing, .running].contains(record.state)
    }
}
