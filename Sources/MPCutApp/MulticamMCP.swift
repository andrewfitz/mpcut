import Foundation
import MPCutCore

/// Arguments have already passed MCP schema validation. Check model-dependent limits again
/// here because the GUI and other clients can change availability between requests.
private struct MulticamArguments {
    let values: [String: Any]

    func string(_ key: String) throws -> String {
        guard let value = values[key] as? String else { throw invalid("Supply \(key).") }
        return value
    }

    func time(_ key: String = "time") throws -> RationalTime {
        let text = try string(key)
        do { return try RationalTime(parsing: text) }
        catch { throw invalid("Enter a valid rational time for \(key).") }
    }

    func integer(_ key: String) throws -> Int {
        guard let raw = values[key], let value = mcpInteger(raw) else { throw invalid("Supply an integer for \(key).") }
        return value
    }

    func direction() throws -> Int {
        let value = try integer("direction")
        guard [-1, 1].contains(value) else { throw invalid("Direction must be -1 or 1.") }
        return value
    }

    func invalid(_ message: String) -> MCPCommandError { MCPCommandError("invalid_target", message) }
}

extension MulticamEditorModel {
    func mcpCommand(tool: String, arguments: [String: Any],
                    validateCommit: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        let args = MulticamArguments(values: arguments)
        guard ["split_at", "set_camera_at", "seek", "set_playback", "get_history", "undo", "redo",
               "restore_history", "multicam_switch", "multicam_source", "multicam_assembly",
               "multicam_audio", "multicam_group", "multicam_select", "multicam_preview", "get_multicam"].contains(tool)
        else { return nil }
        try validateCommit()
        guard let original = project else { throw args.invalid("Open a multicam project.") }
        if tool == "get_history" { return mcpHistory }
        if tool == "get_multicam" { return try multicamState(args, project: original) }
        if (tool == "seek" || tool == "multicam_select"), arguments["occurrence"] != nil,
           original.assemblyItems?.contains(where: { $0.still != nil }) == true, arguments["expectedRevision"] == nil {
            throw MCPCommandError("invalid_arguments", "Supply the revision for this typed assembly occurrence.")
        }
        guard !isBusy, window?.attachedSheet == nil, setup.isEmpty, notice == nil else {
            throw MCPCommandError("editor_busy", "Finish the current multicam operation or dialog.")
        }
        let revisionBeforeCommand = mcpRevision
        var result: [String: Any] = [:]
        switch tool {
        case "split_at":
            let index = try occurrence(args)
            let requested = try args.time()
            let space = try args.string("space")
            guard let range = assemblyRange(at: index) else { throw args.invalid("An inserted still has no group time.") }
            let start = assemblyStart(at: index)
            let group: RationalTime
            switch space {
            case "group": group = requested
            case "assembly":
                guard start < requested, requested < assemblyRangeEnds[index] else {
                    throw args.invalid("The time must lie inside the specified assembly occurrence.")
                }
                group = try range.from.adding(requested.subtracting(start))
            default: throw args.invalid("Choose group or assembly time.")
            }
            guard let boundary = occurrenceSplitBoundary(index: index, group: group) else {
                throw args.invalid("No split boundary is available inside this occurrence at that time.")
            }
            let actual = space == "group" ? boundary : try start.adding(boundary.subtracting(range.from))
            guard commitOccurrenceSplit(index: index, at: boundary) else { throw nativeEditError }
            result = ["action": "Split Assembly Range", "space": space, "time": actual.description, "boundary": actual.description,
                      "left": index, "right": index + 1, "historyRetained": preferences.historyLimit > 0,
                      "groupTime": boundary.description, "occurrences": [index, index + 1]]
        case "set_camera_at":
            let target = try args.time()
            if arguments["occurrence"] != nil {
                let index = try occurrence(args)
                guard let range = assemblyRange(at: index), range.contains(target) else {
                    throw args.invalid("Select a source-backed occurrence containing the requested group time.")
                }
            }
            let angle: String
            if args.values["number"] != nil {
                let number = try args.integer("number")
                guard args.values["angle"] == nil, number > 0, original.angles.indices.contains(number - 1) else {
                    throw args.invalid("Supply one valid camera number or angle ID.")
                }
                angle = original.angles[number - 1].id
            } else {
                angle = try args.string("angle")
            }
            guard let actual = take(angle, at: target) else {
                if notice != nil { throw nativeEditError }
                throw args.invalid("Use an existing camera and an interior group time or the opening time.")
            }
            result = ["action": "Switch Camera", "space": "group", "angle": angle, "time": actual.description,
                      "until": (project?.switches.first { $0.at > actual }?.at ?? original.range.to).description]
        case "seek":
            let target = try args.time()
            let index = try args.values["occurrence"].map { _ in try occurrence(args) }
            switch try args.string("space") {
            case "group":
                guard original.range.from <= target, target <= original.range.to else { throw args.invalid("Time outside group.") }
                if let index {
                    guard let range = assemblyRange(at: index) else { throw args.invalid("An inserted still has no group time.") }
                    guard range.contains(target) else { throw args.invalid("Group time is outside the specified assembly occurrence.") }
                    let output = try assemblyStart(at: index).adding(target.subtracting(range.from))
                    seekAssembly(at: output, scrubbing: false)
                } else {
                    setAssemblyPreview(false)
                    seekGroup(target)
                }
            case "assembly":
                guard target >= .zero, let end = assemblyRangeEnds.last, target <= end else { throw args.invalid("Time outside assembly.") }
                if let index {
                    let occurrenceEnd = assemblyRangeEnds[index]
                    guard target >= assemblyStart(at: index),
                          target < occurrenceEnd || (target == end && target == occurrenceEnd) else {
                        throw args.invalid("Assembly time is outside the specified occurrence.")
                    }
                }
                seekAssembly(at: target, scrubbing: false)
            default: throw args.invalid("Choose assembly or group time.")
            }
            result = previewPosition
        case "set_playback":
            guard let playing = arguments["playing"] as? Bool else { throw args.invalid("Supply playing.") }
            if playing != preview.isPlaying { preview.togglePlayback() }
            result = previewPosition
        case "undo", "redo", "restore_history":
            let destination: Int
            if tool == "restore_history" {
                guard try args.string("historyToken") == historyToken else {
                    throw MCPCommandError("stale_history", "Read the retained history again.")
                }
                destination = try args.integer("index")
            } else { destination = historyCursor + (tool == "undo" ? -1 : 1) }
            guard (0...historyActions.count).contains(destination) else { throw args.invalid("The requested history state is unavailable.") }
            moveToHistoryState(destination)
            result = mcpHistory
        case "multicam_preview": result = try changePreview(args, project: original)
        case "multicam_select": result = try changeSelection(args, project: original)
        case "multicam_switch": try editSwitch(args, project: original)
        case "multicam_source":
            if try args.string("action") == "relink" {
                let receipt = try await relinkSource(args, project: original, validateCommit: validateCommit)
                result = ["revision": receipt.revision, "changed": receipt.changed, "historyRetained": receipt.historyRetained,
                          "source": try args.string("source")]
                if receipt.changed { result["action"] = "Relink Source" }
                result["warning"] = receipt.warning
                return result
            }
            result = try editSource(args, project: original)
        case "multicam_audio":
            let policy: MulticamAudioPolicy
            switch try args.string("mode") {
            case "fixed": policy = try .fixed(audioSelection(args, project: original))
            case "follow": policy = .follow
            case "none": policy = .none
            default: throw args.invalid("Choose fixed, follow or none.")
            }
            guard edit(nil, { $0.audio = policy }) else { throw nativeEditError }
        case "multicam_group":
            let end: RationalTime
            switch try args.string("action") {
            case "set_end": end = try args.time()
            case "extend":
                guard let latest = lastCameraGroupEnd else { throw args.invalid("No indexed camera duration is available.") }
                end = max(latest, original.range.to)
            default: throw args.invalid("Choose set_end or extend.")
            }
            guard edit(nil, { $0.range.to = end }) else { throw nativeEditError }
            result["groupTo"] = project?.range.to.description
        case "multicam_assembly": result = try editAssembly(args, project: original)
        default: return nil
        }
        let changed = revisionBeforeCommand != mcpRevision
        if let notice {
            // A draft write can fail after the native timeline transaction committed.
            // Report both outcomes so the client can recover without repeating the edit.
            guard changed else { throw nativeEditError }
            result["warning"] = notice.message
        }
        result["changed"] = changed
        result["revision"] = mcpRevision
        if !["undo", "redo", "restore_history", "seek", "set_playback", "multicam_preview", "multicam_select"].contains(tool) {
            result["historyRetained"] = changed && preferences.historyLimit > 0
            if changed, result["action"] == nil { result["action"] = lastEditAction }
        }
        return result
    }

    private var historyToken: String { "\(mcpGeneration.uuidString)/\(mcpRevision)/\(historyRevision)/\(historyCursor)" }
    private var mcpHistory: [String: Any] {
        ["actions": historyActions, "cursor": historyCursor, "historyToken": historyToken,
         "limit": preferences.historyLimit, "revision": mcpRevision]
    }
    private var previewPosition: [String: Any] {
        let output = preview.currentTime()
        let group = groupTime(at: output)
        var value: [String: Any] = ["space": assemblyPreview ? "assembly" : "group", "time": output.description,
                                    "groupTime": group.description, "playing": preview.isPlaying,
                                    "rate": preview.playbackRate, "speed": preview.forwardSpeed.rawValue,
                                    "auditioning": preview.isAuditioning]
        if assemblyPreview { value["occurrence"] = occurrenceIndex(at: output) }
        if assemblyPreview, let still = assemblyStill(at: occurrenceIndex(at: output)) {
            value["groupTime"] = nil
            value["placement"] = still.id
            value["asset"] = still.assetID
        } else {
            value["angle"] = project?.selection(at: group)?.angle
        }
        return value
    }
    private var nativeEditError: MCPCommandError {
        let message = notice?.message ?? "The multicam editor could not apply the change."
        // Deliver validation failures to the calling host without leaving a modal alert in the editor.
        notice = nil
        return MCPCommandError("edit_failed", message)
    }
    private func occurrence(_ args: MulticamArguments) throws -> Int {
        let index = try args.integer("occurrence")
        guard assemblyItems.indices.contains(index) else { throw args.invalid("Unknown assembly occurrence.") }
        return index
    }
    private func audioSelection(_ args: MulticamArguments, project: MulticamProject) throws -> MulticamAudioSelection {
        let id = try args.string("source")
        let stream = try args.integer("stream")
        guard project.sources.contains(where: { $0.id == id }),
              media[id]?.audio.contains(where: { $0.stream.index == stream }) == true else {
            throw args.invalid("Choose an available audio source and absolute stream index.")
        }
        return MulticamAudioSelection(source: id, stream: stream)
    }
    func mcpAssemblyRows(in indices: Range<Int>) -> [[String: Any]] {
        let items = assemblyItems
        let ends = assemblyRangeEnds
        return indices.map { index in
            let start = index == 0 ? RationalTime.zero : ends[index - 1]
            var row: [String: Any] = ["index": index, "assemblyFrom": start.description,
                                      "assemblyTo": ends[index].description]
            switch items[index] {
            case .group(let range):
                row["type"] = "group"
                row["groupFrom"] = range.from.description
                row["groupTo"] = range.to.description
            case .still(let still):
                row["type"] = "still"
                row["placement"] = still.id
                row["asset"] = still.assetID
            }
            return row
        }
    }

    private func multicamState(_ args: MulticamArguments, project: MulticamProject) throws -> [String: Any] {
        let offset = try args.values["offset"].map { _ in try args.integer("offset") } ?? 0
        let limit = try args.values["limit"].map { _ in try args.integer("limit") } ?? 50
        guard offset >= 0, (1...200).contains(limit) else { throw args.invalid("Use a nonnegative offset and a limit of 1–200.") }
        func page(_ total: Int) -> Range<Int> {
            let start = min(total, offset)
            return start..<(start + min(limit, total - start))
        }
        let audio = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project.audio))
        var state: [String: Any] = ["referenceAngle": project.referenceAngle, "audio": audio,
                                    "groupFrom": project.range.from.description, "groupTo": project.range.to.description,
                                    "revision": mcpRevision, "offset": offset]
        switch try args.string("section") {
        case "sources":
            let sources = project.sources
            state["total"] = sources.count
            state["sources"] = page(sources.count).map { i -> [String: Any] in
                let source = sources[i]
                let info = media[source.id]
                var item: [String: Any] = ["id": source.id, "file": source.file, "name": source.displayName,
                                           "kind": i < project.angles.count ? "camera" : "audio", "offset": source.offset.description,
                                           "available": info != nil, "indexed": info?.hasFullEditIndex == true]
                if i < project.angles.count { item["number"] = i + 1 }
                item["audioStream"] = source.audioStream
                item["audioStreams"] = info?.audio.map { $0.stream.index } ?? []
                item["duration"] = info?.duration.description
                item["indexProgress"] = sourceIndexProgress[source.id]
                item["issue"] = sourceIssues[source.id] ?? sourceIndexIssues[source.id]
                return item
            }
        case "switches":
            state["total"] = project.switches.count
            state["switches"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(project.switches[page(project.switches.count)])))
        case "assembly":
            let total = assemblyItems.count
            guard assemblyRangeEnds.count == total else { throw args.invalid("The assembly timeline is inconsistent.") }
            state["total"] = total
            state["occurrences"] = mcpAssemblyRows(in: page(total))
        case "stills":
            let stills = try CutProject.multicam(project).mcpStillList(location: projectURL, offset: offset, limit: limit)
            state.merge(stills) { _, updated in updated }
        case "suggestions":
            state["total"] = suggestions.count
            state["anchor"] = suggestionAnchor?.description
            state["suggestions"] = suggestions[page(suggestions.count)].map(\.description)
        default: throw args.invalid("Choose sources, switches, suggestions, assembly or stills.")
        }
        if let policy = project.programColorPolicy {
            state["programColorPolicy"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy))
        }
        return state
    }
    private func editSwitch(_ args: MulticamArguments, project: MulticamProject) throws {
        let at = try args.time()
        guard project.switches.contains(where: { $0.at == at }) else { throw args.invalid("There is no switch at that group time.") }
        switch try args.string("action") {
        case "move", "apply_suggestion":
            let to = try args.time("to")
            guard at != project.range.from, to > project.range.from, to < project.range.to else {
                throw args.invalid("Move a non-opening switch inside the group.")
            }
            if args.values["action"] as? String == "apply_suggestion",
               !(suggestionAnchor == at && suggestions.contains(to)) { throw args.invalid("That suggestion is no longer available.") }
            moveSwitch(at, to: to)
        case "delete":
            guard at != project.range.from else { throw args.invalid("The opening switch must remain.") }
            deleteSwitch(at)
        case "angle":
            let id = try args.string("angle")
            guard project.angles.contains(where: { $0.id == id }) else { throw args.invalid("Unknown camera.") }
            changeSwitch(at, angle: id)
        case "audio": try changeSwitch(at, audio: audioSelection(args, project: project))
        case "default_audio": changeSwitch(at, audio: nil)
        default: throw args.invalid("Unknown switch action.")
        }
    }

    private func editSource(_ args: MulticamArguments, project: MulticamProject) throws -> [String: Any] {
        let id = try args.string("source")
        guard project.sources.contains(where: { $0.id == id }) else { throw args.invalid("Unknown multicam source.") }
        switch try args.string("action") {
        case "rename":
            try renameSource(id, to: args.string("name"))
        case "offset":
            let offset = try args.time("offset")
            updateSource(id) { $0.offset = offset }
        case "nudge":
            let clock = try args.values["time"].map { _ in try args.time() } ?? currentGroupTime()
            guard project.range.from <= clock, clock <= project.range.to else { throw args.invalid("Time outside group.") }
            guard let offset = try moveOffset(id, by: args.direction(), at: clock) else {
                if notice != nil { throw nativeEditError }
                throw args.invalid("A frame or audio sample interval is unavailable at this source position.")
            }
            return ["source": id, "groupTime": clock.description, "offset": offset.description]
        case "move":
            let direction = try args.direction()
            guard let index = project.angles.firstIndex(where: { $0.id == id }), project.angles.indices.contains(index + direction)
            else { throw args.invalid("Choose a camera that can move in that direction.") }
            moveSource(id, by: direction)
        case "microphone":
            guard project.angles.contains(where: { $0.id == id }) else { throw args.invalid("Select a camera.") }
            let stream = args.values["stream"] == nil ? nil : try audioSelection(args, project: project).stream
            updateSource(id) { $0.audioStream = stream }
        default: throw args.invalid("Unknown source action.")
        }
        return ["source": id]
    }

    private func relinkSource(_ args: MulticamArguments, project: MulticamProject,
                              validateCommit: @escaping @MainActor () throws -> Void) async throws
        -> (revision: Int, changed: Bool, historyRetained: Bool, warning: String?) {
        let id = try args.string("source")
        guard project.sources.contains(where: { $0.id == id }) else { throw args.invalid("Unknown multicam source.") }
        let path = try args.string("path")
        guard path.hasPrefix("/"), !path.contains("\0") else { throw args.invalid("Supply an absolute replacement file path.") }
        let generation = mcpGeneration
        let revision = mcpRevision
        do {
            return try await relink(id, to: URL(fileURLWithPath: path)) {
                try validateCommit()
                guard self.mcpGeneration == generation else { throw MCPCommandError("project_closed", "The project has closed or changed.") }
                guard self.mcpRevision == revision else {
                    throw MCPCommandError("stale_revision", "Current revision is \(self.mcpRevision). Read the project state again.")
                }
            }
        } catch is CancellationError {
            throw MCPCommandError("cancelled", "Source relink was cancelled.")
        }
    }

    private func editAssembly(_ args: MulticamArguments, project: MulticamProject) throws -> [String: Any] {
        switch try args.string("action") {
        case "append":
            let from = try args.time("from"), to = try args.time("to")
            guard project.range.from <= from, from < to, to <= project.range.to else { throw args.invalid("Choose a nonempty group range.") }
            addAssemblyRange(.init(from: from, to: to))
        case "trim":
            let index = try occurrence(args)
            guard args.values["from"] != nil || args.values["to"] != nil else {
                throw args.invalid("Supply a group in or out time to trim.")
            }
            guard let range = assemblyRange(at: index) else { throw args.invalid("Use update_still to resize an inserted still.") }
            let from = args.values["from"] == nil ? range.from : try args.time("from")
            let to = args.values["to"] == nil ? range.to : try args.time("to")
            guard project.range.from <= from, from < to, to <= project.range.to else { throw args.invalid("Choose a nonempty group range.") }
            changeOccurrence(index, from: from, to: to)
        case "trim_edge", "preview_trim":
            let index = try occurrence(args)
            guard assemblyRange(at: index) != nil else { throw args.invalid("An inserted still has no group edge.") }
            let target = try args.time()
            let edge: TimelineEdge
            switch try args.string("edge") {
            case "start": edge = .start
            case "end": edge = .end
            default: throw args.invalid("Choose start or end.")
            }
            let commit = try args.string("action") == "trim_edge"
            guard project.range.from <= target, target <= project.range.to else { throw args.invalid("Time outside group.") }
            guard let boundary = trimAssemblyOccurrence(index, edge: edge, time: target, commit: commit) else {
                if notice != nil { throw nativeEditError }
                throw args.invalid("No valid trim boundary was available for the requested edge.")
            }
            if commit { return ["boundary": boundary.description] }
            return ["proposedSeconds": boundary.seconds, "boundary": boundary.description]
        case "move":
            let index = try occurrence(args), slot = try args.integer("before")
            guard (0...assemblyItems.count).contains(slot) else { throw args.invalid("Choose an insertion slot in the assembly.") }
            reorderAssemblyOccurrence(index, before: slot)
        case "remove":
            let index = try occurrence(args)
            guard project.assembly != nil || project.assemblyItems != nil else { throw args.invalid("The implicit full group is not an explicit assembly range.") }
            removeOccurrence(index)
        case "split_selection":
            try requireMarkedRange(args)
            guard canSplitSelectedRange else { throw args.invalid("Select a range with an interior edge.") }
            splitSelectedRange()
        case "subtract_selection":
            try requireMarkedRange(args)
            guard canDeleteSelectedRange else { throw args.invalid("Select a removable range that leaves some program material.") }
            deleteSelectedRange()
        default: throw args.invalid("Unknown assembly action.")
        }
        return [:]
    }

    private func requireMarkedRange(_ args: MulticamArguments) throws {
        // Playhead and selection changes intentionally do not increment the document revision.
        let space = try args.string("space")
        let from = try args.time("from")
        let to = try args.time("to")
        let expected = AudioSpan(from: min(from, to), to: max(from, to))
        let current: AudioSpan?
        switch space {
        case "group": current = assemblySelection == nil ? markedGroupSpan : nil
        case "assembly": current = assemblySelection
        default: throw args.invalid("Choose group or assembly time.")
        }
        guard current == expected else {
            throw MCPCommandError("selection_changed", "Read the selected range and clock again.")
        }
    }

    private func changeSelection(_ args: MulticamArguments, project: MulticamProject) throws -> [String: Any] {
        switch try args.string("action") {
        case "switch":
            let time = try args.time()
            guard project.switches.contains(where: { $0.at == time }) else { throw args.invalid("No switch at this time.") }
            selectMarker(time)
        case "occurrence": try selectAssemblyOccurrence(occurrence(args))
        case "group_range", "assembly_range":
            let from = try args.time("from"), to = try args.time("to")
            if args.values["action"] as? String == "group_range" {
                guard project.range.from <= from, from < to, to <= project.range.to else { throw args.invalid("Choose a range inside the group.") }
                selectGroupRange(from, to)
            } else {
                guard .zero <= from, from < to, let end = assemblyRangeEnds.last, to <= end else { throw args.invalid("Choose a range inside the assembly.") }
                selectAssemblyRange(from, to)
            }
        case "mark_in": markIn = markAnalysisTime()
        case "mark_out": markOut = markAnalysisTime()
        case "clear_marks": markIn = nil; markOut = nil; assemblySelection = nil
        case "pointer": rangeTool = false
        case "range_tool": rangeTool = true
        default: throw args.invalid("Unknown selection action.")
        }
        var state = previewPosition
        state["occurrence"] = selectedOccurrence
        state["markSpace"] = assemblySelection == nil ? "group" : "assembly"
        state["markIn"] = displayedMarkIn?.description
        state["markOut"] = displayedMarkOut?.description
        return state
    }

    private func changePreview(_ args: MulticamArguments, project: MulticamProject) throws -> [String: Any] {
        switch try args.string("action") {
        case "group": setAssemblyPreview(false)
        case "assembly": setAssemblyPreview(true)
        case "audition":
            let angle = try args.string("angle")
            guard project.angles.contains(where: { $0.id == angle }), media[angle] != nil else { throw args.invalid("Choose an available camera.") }
            guard !preview.isPlaying else { throw MCPCommandError("editor_busy", "Pause playback to audition a camera.") }
            audition(angle)
        case "program": preview.endAudition()
        case "shuttle": try preview.shuttle(args.direction())
        case "speed":
            guard let rate = args.values["speed"] as? NSNumber, let speed = PlaybackSpeed(rawValue: rate.floatValue) else {
                throw args.invalid("Choose a supported playback speed.")
            }
            preview.selectPlaybackSpeed(speed)
        case "scrub_group", "scrub_assembly":
            let target = try args.time()
            if args.values["action"] as? String == "scrub_group" {
                guard project.range.from <= target, target <= project.range.to else { throw args.invalid("Time outside group.") }
                setAssemblyPreview(false)
                seekTimeline(target)
            } else {
                guard .zero <= target, let end = assemblyRangeEnds.last, target <= end else { throw args.invalid("Time outside assembly.") }
                seekAssembly(at: target, scrubbing: true)
            }
        case "end_scrub": preview.endScrub()
        case "step": try step(args.direction())
        case "step_keyframe", "step_scene", "step_pause":
            let action = try args.string("action")
            let target: TimelineSnapTarget = action == "step_keyframe" ? .keyframes : (action == "step_scene" ? .scenes : .silence)
            guard canStepAnalysis(target) else { throw args.invalid("No indexed navigation boundary is available.") }
            try stepAnalysis(target, direction: args.direction())
        case "start": seekPlaybackBoundary(end: false)
        case "end": seekPlaybackBoundary(end: true)
        case "snap":
            guard let snap = try TimelineSnapTarget(rawValue: args.string("target")) else { throw args.invalid("Unknown snap target.") }
            setAnalysisSnap(snap)
        default: throw args.invalid("Unknown preview action.")
        }
        return previewPosition
    }
}
