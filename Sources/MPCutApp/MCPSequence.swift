import CoreFoundation
import CryptoKit
import Foundation
import MPCutCore

@MainActor
extension EditorModel {
    var mcpSelectedItemID: String? {
        guard let selectedID else { return nil }
        if let index = timelineClips.firstIndex(where: { $0.id == selectedID && $0.isStill }),
           let card = try? stillProject.mcpStillOccurrences().first(where: { $0.index == index }) {
            return card.insert.id
        }
        return selectedID.uuidString
    }

    var historyToken: String {
        let identity = [mcpGeneration.uuidString, String(historyCursor)] + historyEntryIDs.map(\.uuidString)
        return Data(SHA256.hash(data: Data(identity.joined(separator: "/").utf8))).base64EncodedString()
    }

    private func mcpHistory() -> [String: Any] {
        let history = projectHistory
        return ["actions": history.map(\.name), "origins": history.map(\.origin.rawValue), "cursor": historyCursor, "history_token": historyToken,
                "limit": mcpHistoryLimit, "revision": mcpRevision]
    }

    func mcpCommand(tool: String, arguments: [String: Any],
                    validateCommit: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        let cancellation = EditCancellation()
        return try await withTaskCancellationHandler {
            try await performSequenceCommand(tool: tool, arguments: arguments, cancellation: cancellation) {
                try validateCommit()
                guard !cancellation.isCancelled else { throw MCPFailure(code: "cancelled", message: "The editing request was cancelled.") }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func performSequenceCommand(tool: String, arguments: [String: Any], cancellation: EditCancellation,
                                        validateCommit: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        let input = SequenceInput(fields: arguments)
        let checkLiveAccess: @MainActor () throws -> Void = { [self] in
            try validateCommit()
            guard editorWindow?.attachedSheet == nil else {
                throw MCPFailure(code: "editor_busy", message: "Close the sheet in this project window.")
            }
        }
        if tool != "history_read" { try checkLiveAccess() }
        switch tool {
        case "history_read":
            return mcpHistory()
        case "timeline_item_split":
            guard canEdit, !mcpHasActiveTrim else { throw input.busy() }
            let id = try input.occurrence(in: self)
            let sourceTime = try input.sourcePosition(in: self, occurrence: id)
            let outcome: SplitOutcome = try await withCheckedThrowingContinuation { continuation in
                split(id, atSourceTime: sourceTime, cancellation: cancellation, check: {
                    try checkLiveAccess()
                    guard self.canEdit, !self.mcpHasActiveTrim else { throw input.busy() }
                }, completion: { continuation.resume(with: $0) })
            }
            let boundary = arguments["space"] as? String == "source" ? outcome.sourceTime : outcome.sequenceTime
            return ["action": "Split Clip", "boundary": boundary.description,
                    "sequence_time": outcome.sequenceTime.description, "source_time": outcome.sourceTime.description,
                    "left": outcome.left.uuidString, "right": outcome.right.uuidString,
                    "history_retained": outcome.historyRetained, "revision": outcome.revision]
        case "history_undo", "history_redo", "history_state_restore":
            guard !isBusy, alert == nil, !mcpHasActiveTrim else { throw input.busy() }
            let index: Int
            switch tool {
            case "history_undo": index = historyCursor - 1
            case "history_redo": index = historyCursor + 1
            default:
                guard arguments["history_token"] as? String == mcpHistory()["history_token"] as? String else {
                    throw MCPFailure(code: "stale_history", message: "Read the current history and select its state again.")
                }
                index = try input.integer("index")
            }
            guard (0...historyActions.count).contains(index) else { throw input.invalid("The history state is unavailable.") }
            return try await withCheckedThrowingContinuation { continuation in
                moveToHistoryState(index, requestCancellation: cancellation, beforeRestore: checkLiveAccess,
                                   completion: { result in continuation.resume(with: result.map { _ in self.mcpHistory() }) })
            }
        case "timeline_playhead_seek":
            guard canNavigate, !mcpHasActiveTrim else { throw input.busy() }
            if let id = arguments["occurrence"] as? String,
               let still = try stillProject.mcpStillOccurrences().first(where: { $0.insert.id == id }) {
                let time = try input.time("time")
                guard arguments["space"] as? String == "sequence", still.from <= time,
                      time < still.to || time == still.to && time == mcpDuration else {
                    throw MCPCommandError("invalid_target", "An inserted still has sequence time within its occurrence.")
                }
                seek(time.seconds)
            } else {
                let occurrence = try arguments["occurrence"].map { _ in try input.occurrence(in: self) }
                let position = try input.position(in: self, occurrence: occurrence)
                seek(position.seconds)
            }
        case "playback_transport_play", "playback_transport_pause":
            guard canNavigate, !mcpHasActiveTrim else { throw input.busy() }
            let playing = tool == "playback_transport_play"
            guard !playing || !preview.hasBlockingIssue else { throw input.invalid("The preview is unavailable.") }
            if preview.isPlaying != playing { preview.togglePlayback() }
        case "sequence_clip_edit", "sequence_range_edit", "timeline_selection_set", "playback_transport_control":
            if let result = try await mcpControl(input, cancellation: cancellation, validateCommit: checkLiveAccess) { return result }
        default:
            return nil
        }
        try mcpCheckNotice()
        var result: [String: Any] = ["revision": mcpRevision, "playhead_seconds": playhead, "playing": preview.isPlaying,
                                     "rate": preview.playbackRate, "forward_speed": preview.forwardSpeed.rawValue,
                                     "timeline_zoom": timelineZoom, "snap": effectiveSnapTarget.rawValue, "range_tool": rangeTool]
        if let mcpTrimPreview, let mcpTrimBoundary {
            result["trim_preview"] = mcpTrimPreview.uuidString
            result["source_time"] = mcpTrimBoundary.description
        } else if ["trim", "restore_edge"].contains(arguments["action"] as? String ?? ""),
                  let id = (arguments["occurrence"] as? String).flatMap(UUID.init(uuidString:)),
                  let clip = mcpOccurrence(id) {
            result["source_time"] = (arguments["edge"] as? String == "start" ? clip.start : clip.end).description
        }
        result["selected_occurrence"] = mcpSelectedItemID
        if let markIn { result["mark_in_seconds"] = markIn }
        if let markOut { result["mark_out_seconds"] = markOut }
        return result
    }

    private func mcpCheckNotice() throws {
        if let alert {
            dismissNotice()
            throw MCPFailure(code: "edit_failed", message: alert.message)
        }
    }

    private func mcpControl(_ input: SequenceInput, cancellation: EditCancellation, validateCommit: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        let action = try input.string("action")
        let continuingTrim = ["preview_trim", "trim", "cancel_trim"].contains(action) && mcpTrimPreview != nil &&
            (input.fields["trim_preview"] as? String).flatMap(UUID.init(uuidString:)) == mcpTrimPreview
        guard canEdit, !mcpHasActiveTrim || continuingTrim else { throw input.busy() }
        if input.fields["trim_preview"] != nil && !continuingTrim { throw input.invalid("This trim preview has ended.") }
        switch action {
        case "select":
            if let id = input.fields["occurrence"] as? String,
               let card = try stillProject.mcpStillOccurrences().first(where: { $0.insert.id == id }),
               timelineClips.indices.contains(card.index), timelineClips[card.index].isStill {
                select(timelineClips[card.index].id)
            } else {
                select(try input.occurrence(in: self))
            }
        case "select_range", "split_range", "delete_range":
            let from = try input.time("from"), to = try input.time("to")
            guard from >= .zero, to > from, to <= mcpDuration else { throw input.invalid("Supply a nonempty sequence range.") }
            selectRange(from.seconds, to.seconds)
            try mcpCheckNotice()
            if action == "split_range" {
                guard canSplitSelectedRange else { throw input.invalid("Both selection edges are already cuts.") }
                splitSelectedRange()
            } else if action == "delete_range" {
                guard canActOnRange else { throw input.invalid("The selected range is unavailable.") }
                deleteSelection()
            }
        case "mark_in", "mark_out":
            let position = try input.position(in: self, occurrence: nil)
            seek(position.seconds)
            if action == "mark_in" { setIn() } else { setOut() }
        case "clear_marks": clearMarks()
        case "range_tool": rangeTool = try input.bool("enabled")
        case "snap":
            // Snap to is a shared setting, so an agent changes it only while Settings allows agents to change settings.
            try preferences.checkAgentWrite()
            guard let target = TimelineSnapTarget(rawValue: try input.string("value")),
                  !isAudioOnly || target == .off || target == .playhead || target == .silence else { throw input.invalid("Unsupported snap target.") }
            chooseSnapTarget(target)
        case "copy_container":
            let container = try input.string("value")
            let choices = mcpCopyContainers
            guard choices.contains(container) else {
                throw input.invalid(choices.isEmpty ? "Copy export is unavailable for this sequence."
                    : "Choose a supported copy container (\(choices.joined(separator: ", ")).")
            }
            preferCopyContainer(container)
        case "move":
            let slot = try input.integer("slot")
            guard (0...timelineClips.count).contains(slot) else { throw input.invalid("Invalid insertion slot.") }
            move(try input.occurrence(in: self), to: slot)
        case "cancel_trim":
            guard continuingTrim else { throw input.invalid("Supply the active trim preview token.") }
            cancelMCPTrimPreview()
        case "trim", "preview_trim", "restore_edge":
            let id = try input.occurrence(in: self)
            guard let clip = mcpOccurrence(id) else { throw input.invalid("Unknown clip.") }
            let edge = try input.edge()
            guard !continuingTrim || mcpTrimMatches(id, edge: edge) else {
                throw input.invalid("Continue the trim on the same clip occurrence and edge.")
            }
            let time = action == "restore_edge" ? (edge == .start ? .zero : clip.sourceDuration) : try input.time("time")
            guard time >= .zero, time <= clip.sourceDuration else { throw input.invalid("Trim time is outside this source.") }
            let preview = action == "preview_trim" ? mcpTrimPreview ?? UUID() : nil
            guard try await mcpTrim(id, edge: edge, time: time.seconds, preview: preview,
                                    cancellation: cancellation, check: validateCommit) != nil else {
                if continuingTrim { cancelTrim() }
                try mcpCheckNotice()
                throw input.invalid("No valid trim boundary.")
            }
        case "delete_clip":
            deleteClip(try input.occurrence(in: self))
        case "apply_csv":
            let path = try input.string("path")
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw input.invalid("Supply an absolute CSV path.") }
            let id = try input.occurrence(in: self)
            let baseRevision = mcpRevision
            let revision: Int = try await withCheckedThrowingContinuation { continuation in
                applyClipCSV(URL(fileURLWithPath: path), to: id, requestCancellation: cancellation, beforeCommit: {
                    try validateCommit()
                    guard self.canEdit, !self.mcpHasActiveTrim else { throw input.busy() }
                }, completion: { continuation.resume(with: $0) })
            }
            return ["action": "Apply CSV", "revision": revision, "changed": revision != baseRevision]
        case "step":
            let direction = try input.direction()
            switch try input.string("unit") {
            case "frame": step(direction)
            case "keyframe" where !isAudioOnly: step(direction, keyframes: true)
            case "scene" where canStepScenes: stepScene(direction)
            case "pause" where pauseAnalysisReady && !pausePlan.isEmpty: stepPause(direction)
            default: throw input.invalid("The requested navigation boundary is unavailable.")
            }
        case "shuttle":
            guard !preview.hasBlockingIssue else { throw input.invalid("The preview is unavailable.") }
            preview.shuttle(try input.direction())
        case "speed":
            guard let speed = PlaybackSpeed(rawValue: Float(try input.number("rate"))) else { throw input.invalid("Unsupported playback speed.") }
            preview.selectPlaybackSpeed(speed)
        case "scrub":
            scrub(try input.position(in: self, occurrence: nil).seconds)
        case "end_scrub": preview.endScrub()
        default: throw input.invalid("Unknown sequence action.")
        }
        return nil
    }
}

struct SequenceInput {
    let fields: [String: Any]

    func invalid(_ message: String) -> MCPFailure { MCPFailure(code: "invalid_argument", message: message) }
    func busy() -> MCPFailure { MCPFailure(code: "editor_busy", message: "Finish the current editor operation or gesture.") }
    func string(_ key: String) throws -> String {
        guard let value = fields[key] as? String else { throw invalid("Supply a string for \(key).") }
        return value
    }
    func number(_ key: String) throws -> Double {
        guard let value = fields[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw invalid("Supply a number for \(key).")
        }
        return value.doubleValue
    }
    func integer(_ key: String) throws -> Int {
        guard let value = fields[key].flatMap(mcpInteger) else { throw invalid("Supply an integer for \(key).") }
        return value
    }
    func direction() throws -> Int {
        let value = try integer("direction")
        guard value == -1 || value == 1 else { throw invalid("Use direction -1 or 1.") }
        return value
    }
    func bool(_ key: String) throws -> Bool {
        guard let value = fields[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw invalid("Supply a boolean for \(key).")
        }
        return value.boolValue
    }
    func edge() throws -> TimelineEdge {
        switch try string("edge") {
        case "start": return .start
        case "end": return .end
        default: throw invalid("Choose start or end.")
        }
    }
    func time(_ key: String) throws -> RationalTime { try RationalTime(parsing: string(key)) }

    @MainActor
    func occurrence(in editor: EditorModel) throws -> UUID {
        guard let id = UUID(uuidString: try string("occurrence")), editor.mcpOccurrence(id) != nil else {
            throw invalid("Unknown clip occurrence. Read the current timeline.")
        }
        return id
    }

    @MainActor
    func position(in editor: EditorModel, occurrence: UUID?) throws -> RationalTime {
        let time = try time("time"), space = try string("space")
        if let occurrence, let range = editor.mcpOccurrence(occurrence) {
            let sequenceEnd = try range.offset.adding(range.end.subtracting(range.start))
            switch space {
            case "source" where time >= range.start && time <= range.end:
                return try range.offset.adding(time.subtracting(range.start))
            case "sequence" where time >= range.offset && time <= sequenceEnd:
                return time
            default: throw invalid("The time and coordinate space must match the requested occurrence.")
            }
        }
        guard space == "sequence", time >= .zero, time <= editor.mcpDuration else {
            throw invalid("Use a time on the sequence or specify a clip occurrence for source time.")
        }
        return time
    }

    @MainActor
    func sourcePosition(in editor: EditorModel, occurrence: UUID) throws -> RationalTime {
        guard let range = editor.mcpOccurrence(occurrence) else { throw invalid("Unknown clip occurrence.") }
        let time = try time("time")
        switch try string("space") {
        case "source" where time >= range.start && time <= range.end:
            return time
        case "sequence":
            let end = try range.offset.adding(range.end.subtracting(range.start))
            if time >= range.offset, time <= end {
                return try range.start.adding(time.subtracting(range.offset))
            }
        default: break
        }
        throw invalid("The time and coordinate space must match the requested occurrence.")
    }
}
