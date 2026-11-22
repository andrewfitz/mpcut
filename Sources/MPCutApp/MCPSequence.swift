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

    private func mcpHistory() -> [String: Any] {
        let identity = [String(historyCursor)] + historyEntryIDs.map(\.uuidString)
        let token = Data(SHA256.hash(data: Data(identity.joined(separator: "/").utf8))).base64EncodedString()
        return ["actions": historyActions, "cursor": historyCursor, "historyToken": token,
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
        if tool != "get_history" { try checkLiveAccess() }
        switch tool {
        case "get_history":
            return mcpHistory()
        case "split_at":
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
                    "sequenceTime": outcome.sequenceTime.description, "sourceTime": outcome.sourceTime.description,
                    "left": outcome.left.uuidString, "right": outcome.right.uuidString,
                    "historyRetained": outcome.historyRetained, "revision": outcome.revision]
        case "undo", "redo", "restore_history":
            guard !isBusy, alert == nil, !mcpHasActiveTrim else { throw input.busy() }
            let index: Int
            switch tool {
            case "undo": index = historyCursor - 1
            case "redo": index = historyCursor + 1
            default:
                guard arguments["historyToken"] as? String == mcpHistory()["historyToken"] as? String else {
                    throw MCPFailure(code: "stale_history", message: "Read the current history and select its state again.")
                }
                index = try input.integer("index")
            }
            guard (0...historyActions.count).contains(index) else { throw input.invalid("The history state is unavailable.") }
            return try await withCheckedThrowingContinuation { continuation in
                moveToHistoryState(index, requestCancellation: cancellation, beforeRestore: checkLiveAccess,
                                   completion: { result in continuation.resume(with: result.map { _ in self.mcpHistory() }) })
            }
        case "seek":
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
        case "set_playback":
            guard canNavigate, !mcpHasActiveTrim else { throw input.busy() }
            let playing = try input.bool("playing")
            guard !playing || !preview.hasBlockingIssue else { throw input.invalid("The preview is unavailable.") }
            if preview.isPlaying != playing { preview.togglePlayback() }
        case "sequence_control":
            if let result = try await mcpControl(input, cancellation: cancellation, validateCommit: checkLiveAccess) { return result }
        default:
            return nil
        }
        try mcpCheckNotice()
        var result: [String: Any] = ["revision": mcpRevision, "playheadSeconds": playhead, "playing": preview.isPlaying,
                                     "rate": preview.playbackRate, "forwardSpeed": preview.forwardSpeed.rawValue,
                                     "timelineZoom": timelineZoom, "snap": effectiveSnapTarget.rawValue, "rangeTool": rangeTool]
        if let mcpTrimPreview, let mcpTrimBoundary {
            result["trimPreview"] = mcpTrimPreview.uuidString
            result["sourceTime"] = mcpTrimBoundary.description
        } else if ["trim", "restoreEdge"].contains(arguments["action"] as? String ?? ""),
                  let id = (arguments["occurrence"] as? String).flatMap(UUID.init(uuidString:)),
                  let clip = mcpOccurrence(id) {
            result["sourceTime"] = (arguments["edge"] as? String == "start" ? clip.start : clip.end).description
        }
        result["selectedOccurrence"] = mcpSelectedItemID
        if let markIn { result["markInSeconds"] = markIn }
        if let markOut { result["markOutSeconds"] = markOut }
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
        let continuingTrim = ["previewTrim", "trim", "cancelTrim"].contains(action) && mcpTrimPreview != nil &&
            (input.fields["trimPreview"] as? String).flatMap(UUID.init(uuidString:)) == mcpTrimPreview
        guard canEdit, !mcpHasActiveTrim || continuingTrim else { throw input.busy() }
        if input.fields["trimPreview"] != nil && !continuingTrim { throw input.invalid("This trim preview has ended.") }
        switch action {
        case "select":
            if let id = input.fields["occurrence"] as? String,
               let card = try stillProject.mcpStillOccurrences().first(where: { $0.insert.id == id }),
               timelineClips.indices.contains(card.index), timelineClips[card.index].isStill {
                select(timelineClips[card.index].id)
            } else {
                select(try input.occurrence(in: self))
            }
        case "selectRange", "splitRange", "deleteRange":
            let from = try input.time("from"), to = try input.time("to")
            guard from >= .zero, to > from, to <= mcpDuration else { throw input.invalid("Supply a nonempty sequence range.") }
            selectRange(from.seconds, to.seconds)
            try mcpCheckNotice()
            if action == "splitRange" {
                guard canSplitSelectedRange else { throw input.invalid("Both selection edges are already cuts.") }
                splitSelectedRange()
            } else if action == "deleteRange" {
                guard canActOnRange else { throw input.invalid("The selected range is unavailable.") }
                deleteSelection()
            }
        case "markIn", "markOut":
            let position = try input.position(in: self, occurrence: nil)
            seek(position.seconds)
            if action == "markIn" { setIn() } else { setOut() }
        case "clearMarks": clearMarks()
        case "rangeTool": rangeTool = try input.bool("enabled")
        case "snap":
            guard let target = TimelineSnapTarget(rawValue: try input.string("value")),
                  !isAudioOnly || target == .off || target == .silence else { throw input.invalid("Unsupported snap target.") }
            chooseSnapTarget(target)
        case "copyContainer":
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
        case "cancelTrim":
            guard continuingTrim else { throw input.invalid("Supply the active trim preview token.") }
            cancelMCPTrimPreview()
        case "trim", "previewTrim", "restoreEdge":
            let id = try input.occurrence(in: self)
            guard let clip = mcpOccurrence(id) else { throw input.invalid("Unknown clip.") }
            let edge = try input.edge()
            guard !continuingTrim || mcpTrimMatches(id, edge: edge) else {
                throw input.invalid("Continue the trim on the same clip occurrence and edge.")
            }
            let time = action == "restoreEdge" ? (edge == .start ? .zero : clip.sourceDuration) : try input.time("time")
            guard time >= .zero, time <= clip.sourceDuration else { throw input.invalid("Trim time is outside this source.") }
            let preview = action == "previewTrim" ? mcpTrimPreview ?? UUID() : nil
            guard try await mcpTrim(id, edge: edge, time: time.seconds, preview: preview,
                                    cancellation: cancellation, check: validateCommit) != nil else {
                if continuingTrim { cancelTrim() }
                try mcpCheckNotice()
                throw input.invalid("No valid trim boundary.")
            }
        case "deleteClip":
            deleteClip(try input.occurrence(in: self))
        case "applyCSV":
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
        case "endScrub": preview.endScrub()
        case "zoom":
            let value = try input.number("zoom")
            guard (0...SequenceTimeline.maximumZoom).contains(value) else { throw input.invalid("Unsupported timeline zoom.") }
            timelineZoom = value
        case "fit": timelineZoom = timelineZoom > 0 ? 0 : previousTimelineZoom
        case "thumbnails": largeThumbnails = try input.bool("enabled")
        default: throw input.invalid("Unknown sequence action.")
        }
        return nil
    }
}

private struct SequenceInput {
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
        guard let value = Int(exactly: try number(key)) else { throw invalid("Supply an integer for \(key).") }
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
