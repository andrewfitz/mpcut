import Foundation
import MPCutCore

private struct ReviewPosition {
    let media: MediaInfo
    let time: RationalTime
    let exclusiveEnd: Bool
    let metadata: [String: Any]
}

/// Review requests are independent of export jobs. Bound simultaneous decoder allocation.
@MainActor
private enum ReviewDecoders {
    static var active = 0
}

extension ProjectSessions {
    func mcpReviewFrame(arguments: [String: Any], session: ProjectSession,
                        checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any] {
        try checkAccess()
        let time = try (arguments["time"] as? String).map { try RationalTime(parsing: $0) }
        let space = arguments["space"] as? String
        guard (time == nil) == (space == nil) else {
            throw MCPCommandError("invalid_arguments", "Supply time and space together, or omit both for the playhead.")
        }
        guard ReviewDecoders.active < 2 else { throw MCPCommandError("busy", "Two review frames are decoding. Retry when one finishes.") }
        ReviewDecoders.active += 1
        defer { ReviewDecoders.active -= 1 }
        let revision = session.mcpRevision
        let handle = session.mcpHandle
        let position: ReviewPosition
        if session.isMulticam {
            position = try multicamReview(session.multicam, time: time, space: space, angle: arguments["angle"] as? String)
        } else {
            guard arguments["angle"] == nil else { throw MCPCommandError("invalid_target", "Angles apply to multicam projects.") }
            position = try sequenceReview(session.editor, time: time, space: space)
        }
        let media = position.media, requested = position.time, end = position.exclusiveEnd
        let work = Task.detached(priority: .userInitiated) {
            try JPEGExport.reviewFrame(media, at: requested, exclusiveEnd: end, cancelled: { Task.isCancelled })
        }
        let (image, frame) = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
        try checkAccess()
        guard session.mcpHandle == handle, session.mcpRevision == revision else {
            throw MCPCommandError("stale_revision", "The timeline changed. Request the frame again.")
        }
        var result = position.metadata
        result["sourceTime"] = frame.frameTime.description
        result["duration"] = frame.frameDuration.description
        result["width"] = frame.width
        result["height"] = frame.height
        result["jpeg"] = image.base64EncodedString()
        return result
    }

    private func sequenceReview(_ editor: EditorModel, time: RationalTime?, space: String?) throws -> ReviewPosition {
        if let time {
            guard space == "sequence", time >= .zero, time <= editor.mcpDuration, !editor.mcpClipIDs.isEmpty else {
                throw MCPCommandError("invalid_target", "Choose a position on the open sequence.")
            }
            let end = time == editor.mcpDuration
            let i = end ? editor.mcpClipIDs.count - 1 : editor.mcpSequenceOffsets.lowerBound { $0 > time } - 1
            guard editor.mcpClipIDs.indices.contains(i) else { throw MCPCommandError("no_frame", "No occurrence covers this position.") }
            let id = editor.mcpClipIDs[i]
            let range = editor.sequenceClips[i]
            let (source, media) = try editor.mcpReplacementSource(id)
            let sourceTime = try range.from.adding(time.subtracting(editor.mcpSequenceOffsets[i]))
            return ReviewPosition(media: media, time: sourceTime, exclusiveEnd: end,
                                  metadata: ["space": "sequence", "time": time.description, "occurrence": id.uuidString,
                                             "source": source.uuidString])
        }
        guard let source = editor.jpegSourceAtPlayhead, let target = source.frame else {
            throw MCPCommandError("no_frame", "No indexed picture covers the sequence playhead.")
        }
        return ReviewPosition(media: source.media, time: target, exclusiveEnd: false,
                              metadata: ["space": "sequence", "playheadSeconds": editor.playhead, "source": source.id.uuidString])
    }

    private func multicamReview(_ model: MulticamEditorModel, time: RationalTime?, space: String?,
                                angle: String?) throws -> ReviewPosition {
        guard let project = model.project else { throw MCPCommandError("no_frame", "Open a multicam project.") }
        let clock = space ?? (model.assemblyPreview ? "assembly" : "group")
        let group: RationalTime
        let clockTime: RationalTime
        let exclusiveEnd: Bool
        let programAngle: String
        if clock == "group", let time {
            guard project.range.contains(time), let selected = project.selection(at: time) else {
                throw MCPCommandError("invalid_target", "Choose a time within the multicam group.")
            }
            group = time
            clockTime = time
            exclusiveEnd = false
            programAngle = selected.angle
        } else {
            guard time == nil || clock == "assembly" else { throw MCPCommandError("invalid_target", "Choose group or assembly time.") }
            let plan: MulticamPlan
            if time != nil { plan = try project.plan() }
            else if let current = model.mapping { plan = current }
            else { throw MCPCommandError("no_frame", "The program preview is unavailable.") }
            let at = time ?? model.preview.currentTime()
            let position = try MulticamStillPosition.at(at, in: plan)
            guard let active = project.angles.first(where: { $0.id == position.angle }) else {
                throw MCPCommandError("no_frame", "No active camera at this time.")
            }
            group = try position.sourceTime.adding(active.offset)
            clockTime = clock == "group" ? group : at
            exclusiveEnd = position.exclusiveEnd
            programAngle = position.angle
        }
        guard let source = project.angles.first(where: { $0.id == (angle ?? programAngle) }),
              let media = model.media[source.id], media.hasFullEditIndex else {
            throw MCPCommandError("no_frame", "Choose an indexed camera in this project.")
        }
        return try ReviewPosition(media: media, time: group.subtracting(source.offset), exclusiveEnd: exclusiveEnd,
                                  metadata: ["space": clock, "time": clockTime.description, "groupTime": group.description,
                                             "angle": source.id])
    }
}
