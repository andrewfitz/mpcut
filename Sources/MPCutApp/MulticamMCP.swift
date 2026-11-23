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
        guard ["timeline_item_split", "multicam_camera_take", "timeline_playhead_seek", "playback_transport_play", "playback_transport_pause", "history_read", "history_undo", "history_redo",
               "history_state_restore", "multicam_switch_edit", "multicam_source_edit", "multicam_assembly_edit",
               "multicam_program_audio_set", "multicam_group_end_set", "multicam_selection_set", "multicam_preview_control", "multicam_state_read", "multicam_sync_suggest"].contains(tool)
        else { return nil }
        try validateCommit()
        guard let original = project else { throw args.invalid("Open a multicam project.") }
        if tool == "history_read" { return mcpHistory }
        if tool == "multicam_sync_suggest" {
            let revision = mcpRevision
            let generation = mcpGeneration
            let mediaRevision = transcriptMediaRevision
            let report = try await syncSuggestions(for: original, sourceID: arguments["source_id"] as? String,
                                                   referenceSourceID: arguments["reference_source_id"] as? String,
                                                   waveform: !(arguments["metadata_only"] as? Bool ?? false))
            try validateCommit()
            guard revision == mcpRevision, generation == mcpGeneration, mediaRevision == transcriptMediaRevision else {
                throw MCPCommandError("stale_revision", "The multicam project or its media changed during sync analysis.")
            }
            let result = try JSONSerialization.jsonObject(with: MCPSchemas.encodeResult(report))
            return ["revision": revision, "report": result]
        }
        if tool == "multicam_state_read" { return try multicamState(args, project: original) }
        if (tool == "timeline_playhead_seek" || tool == "multicam_selection_set"), arguments["occurrence"] != nil,
           original.assemblyItems?.contains(where: { $0.still != nil }) == true, arguments["expected_revision"] == nil {
            throw MCPCommandError("invalid_arguments", "Supply the revision for this typed assembly occurrence.")
        }
        guard !isBusy, window?.attachedSheet == nil, setup.isEmpty, notice == nil else {
            throw MCPCommandError("editor_busy", "Finish the current multicam operation or dialog.")
        }
        let revisionBeforeCommand = mcpRevision
        var result: [String: Any] = [:]
        switch tool {
        case "timeline_item_split":
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
                      "left": index, "right": index + 1, "history_retained": preferences.historyLimit > 0,
                      "group_time": boundary.description, "occurrences": [index, index + 1]]
        case "multicam_camera_take":
            let target = try args.time("group_time")
            if arguments["occurrence"] != nil {
                let index = try occurrence(args)
                guard let range = assemblyRange(at: index), range.contains(target) else {
                    throw args.invalid("Select a source-backed occurrence containing the requested group time.")
                }
            }
            let angle: String
            if args.values["camera_number"] != nil {
                let number = try args.integer("camera_number")
                guard args.values["angle_id"] == nil, number > 0, original.angles.indices.contains(number - 1) else {
                    throw args.invalid("Supply one valid camera number or angle ID.")
                }
                angle = original.angles[number - 1].id
            } else {
                angle = try args.string("angle_id")
            }
            guard let actual = take(angle, at: target) else {
                if notice != nil { throw nativeEditError }
                throw args.invalid("Use an existing camera and an interior group time or the opening time.")
            }
            result = ["action": "Take Camera", "space": "group", "angle_id": angle, "group_time": actual.description,
                      "group_until": (project?.switches.first { $0.at > actual }?.at ?? original.range.to).description]
        case "timeline_playhead_seek":
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
        case "playback_transport_play", "playback_transport_pause":
            let playing = tool == "playback_transport_play"
            if playing != preview.isPlaying { preview.togglePlayback() }
            result = previewPosition
        case "history_undo", "history_redo", "history_state_restore":
            let destination: Int
            if tool == "history_state_restore" {
                guard try args.string("history_token") == historyToken else {
                    throw MCPCommandError("stale_history", "Read the retained history again.")
                }
                destination = try args.integer("index")
            } else { destination = historyCursor + (tool == "history_undo" ? -1 : 1) }
            guard (0...historyActions.count).contains(destination) else { throw args.invalid("The requested history state is unavailable.") }
            moveToHistoryState(destination)
            result = mcpHistory
        case "multicam_preview_control": result = try changePreview(args, project: original)
        case "multicam_selection_set": result = try changeSelection(args, project: original)
        case "multicam_switch_edit": try editSwitch(args, project: original)
        case "multicam_source_edit":
            if try args.string("action") == "relink" {
                let receipt = try await relinkSource(args, project: original, validateCommit: validateCommit)
                result = ["revision": receipt.revision, "changed": receipt.changed, "history_retained": receipt.historyRetained,
                          "source_id": try args.string("source_id")]
                if receipt.changed { result["action"] = "Relink Source" }
                result["warning"] = receipt.warning
                return result
            }
            if try args.string("action") == "add_recording" {
                let angle = try args.string("angle_id")
                let path = try args.string("path")
                guard path.hasPrefix("/"), !path.contains("\0") else { throw args.invalid("Supply an absolute recording path.") }
                let start = try args.time("group_start")
                result["source_id"] = try await addRecording(to: angle, from: URL(fileURLWithPath: path), at: start,
                                                               validateCommit: validateCommit)
                result["angle_id"] = angle
            } else {
                result = try editSource(args, project: original)
            }
        case "multicam_program_audio_set":
            let mode = try args.string("mode")
            let policy: MulticamAudioPolicy
            let lanes: [MulticamAudioLane]?
            if let list = arguments["lanes"] {
                lanes = try JSONDecoder().decode([MulticamAudioLane].self, from: JSONSerialization.data(withJSONObject: list))
                for lane in lanes ?? [] {
                    if case .recording(let selection) = lane.target {
                        guard media[selection.source]?.audio.contains(where: { $0.stream.index == selection.stream }) == true else {
                            throw args.invalid("Choose an available recording and absolute audio stream index.")
                        }
                    }
                }
            } else { lanes = nil }
            switch mode {
            case "fixed":
                if arguments["source_id"] != nil {
                    policy = try .fixed(audioSelection(args, project: original))
                } else if let saved = original.fixedAudio {
                    policy = .fixed(saved)
                } else {
                    throw args.invalid("Choose a Fixed source and stream.")
                }
            case "follow": policy = .follow
            case "none": policy = .none
            case "mix": policy = .mix
            default: throw args.invalid("Choose fixed, follow, none or mix.")
            }
            guard edit("Change Program Audio", { project in
                if let lanes { project.mixLanes = lanes }
                else if policy == .mix, project.mixLanes.isEmpty { project.mixLanes = project.defaultMixLanes }
                project.audio = policy
            }) else { throw nativeEditError }
        case "multicam_group_end_set":
            let end: RationalTime
            switch try args.string("action") {
            case "set_end": end = try args.time()
            case "extend":
                guard let latest = lastCameraGroupEnd else { throw args.invalid("No indexed camera duration is available.") }
                end = max(latest, original.range.to)
            default: throw args.invalid("Choose set_end or extend.")
            }
            guard edit(nil, { $0.range.to = end }) else { throw nativeEditError }
            result["group_to"] = project?.range.to.description
        case "multicam_assembly_edit": result = try editAssembly(args, project: original)
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
        if !["history_undo", "history_redo", "history_state_restore", "timeline_playhead_seek", "playback_transport_play", "playback_transport_pause", "multicam_preview_control", "multicam_selection_set"].contains(tool) {
            result["history_retained"] = changed && preferences.historyLimit > 0
            if changed, result["action"] == nil { result["action"] = lastEditAction }
        }
        return result
    }

    var historyToken: String { "\(mcpGeneration.uuidString)/\(mcpRevision)/\(historyRevision)/\(historyCursor)" }
    private var mcpHistory: [String: Any] {
        let history = projectHistory
        return ["actions": history.map(\.name), "origins": history.map(\.origin.rawValue), "cursor": historyCursor, "history_token": historyToken,
         "limit": preferences.historyLimit, "revision": mcpRevision]
    }
    private var previewPosition: [String: Any] {
        let output = preview.currentTime()
        let group = groupTime(at: output)
        var value: [String: Any] = ["space": assemblyPreview ? "assembly" : "group", "time": output.description,
                                    "group_time": group.description, "playing": preview.isPlaying,
                                    "rate": preview.playbackRate, "speed": preview.forwardSpeed.rawValue,
                                    "auditioning": preview.isAuditioning]
        let occurrence = assemblyPreview ? occurrenceIndex(at: output) : nil
        value["occurrence"] = occurrence
        if let occurrence, let still = assemblyStill(at: occurrence) {
            value["group_time"] = nil
            value["placement"] = still.id
            value["asset"] = still.assetID
        } else if let interval = interval(at: output) {
            value["angle_id"] = interval.angle
            value["picture_source_id"] = interval.pictureSourceID
        } else {
            value["angle_id"] = project?.selection(at: group)?.angle
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
        let id = try args.string("source_id")
        let stream = try args.integer("audio_stream_index")
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
            var row: [String: Any] = ["index": index, "assembly_from": start.description,
                                      "assembly_to": ends[index].description]
            switch items[index] {
            case .group(let range, let angle):
                row["angle_id"] = angle
                row["type"] = "group"
                row["group_from"] = range.from.description
                row["group_to"] = range.to.description
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
        var state: [String: Any] = ["reference_angle_id": project.referenceAngle, "audio": audio,
                                    "group_from": project.range.from.description, "group_to": project.range.to.description,
                                    "revision": mcpRevision, "offset": offset]
        switch try args.string("section") {
        case "audio":
            let planned = try project.plan()
            let lanes = try project.resolveAudioLanes(plan: planned,
                                                          indexedSources: media.filter { $0.value.hasFullEditIndex },
                                                          unavailableAsGap: true)
            let encode = JSONEncoder()
            state["mix_lanes"] = try JSONSerialization.jsonObject(with: encode.encode(project.mixLanes))
            state["audio_replacements"] = try JSONSerialization.jsonObject(with: encode.encode(project.audioReplacements))
            state["binding_coverage"] = try project.audioReplacements.map { binding -> [String: Any] in
                var entry: [String: Any] = ["id": binding.id]
                if let donor = media[binding.replacement.source], donor.hasFullEditIndex,
                   let track = donor.audio.first(where: { $0.stream.index == binding.replacement.stream }) {
                    let ranges = try MulticamSync.usedReferenceRanges(project: project, reference: binding.original)
                    let coverage = try MulticamSync.replacementCoverage(in: ranges, track: track,
                                                                       relativeOffset: binding.relativeOffset)
                    entry["coverage"] = try JSONSerialization.jsonObject(with: encode.encode(coverage))
                }
                return entry
            }
            state["audio_lanes"] = try JSONSerialization.jsonObject(with: encode.encode(Array(lanes[page(lanes.count)])))
            state["total"] = lanes.count
            if let fixed = project.fixedAudio {
                state["fixed_audio"] = try JSONSerialization.jsonObject(with: encode.encode(fixed))
            }
        case "switch_coverage":
            let report = try cameraCoverage(args.string("angle_id"), at: args.time("group_time"))
            state["switch_coverage"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
        case "sources":
            let sources = project.sources
            let angleIndices = Dictionary(uniqueKeysWithValues: project.angles.enumerated().flatMap { i, angle in
                angle.recordings.map { ($0.id, i) }
            })
            state["total"] = sources.count
            state["sources"] = page(sources.count).map { i -> [String: Any] in
                let source = sources[i]
                let info = media[source.id]
                var item: [String: Any] = ["id": source.id, "file": source.file, "name": source.displayName,
                                           "kind": angleIndices[source.id] == nil ? "audio" : "camera", "offset": source.offset.description,
                                           "available": info != nil, "indexed": info?.hasFullEditIndex == true]
                if let index = angleIndices[source.id] {
                    item["camera_number"] = index + 1
                    item["angle_id"] = project.angles[index].id
                }
                if let coverage = source.coverage {
                    item["group_coverage"] = ["from": coverage.from.description, "to": coverage.to.description]
                }
                item["audio_stream_index"] = source.audioStream
                item["audio_stream_indices"] = info?.audio.map { $0.stream.index } ?? []
                item["audio_streams"] = info?.audio.map { track in
                    ["index": track.stream.index, "label": track.stream.exportLabel,
                     "channel_layout": track.stream.channelLayout, "sample_rate": track.stream.sampleRate] as [String: Any]
                } ?? []
                item["duration"] = info?.duration.description
                item["index_progress"] = latestSourceIndexProgress(source)
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
            if let suggestion = currentEdgeSuggestion {
                state["edge"] = ["range_number": suggestion.edge.range, "boundary": suggestion.edge.boundary,
                                 "group_time": suggestion.edge.at.description, "times": suggestion.times.map(\.description)]
            }
        default: throw args.invalid("Choose sources, switches, switch coverage, suggestions, assembly, stills or audio.")
        }
        if let policy = project.programColorPolicy {
            state["program_color_policy"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy))
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
            let id = try args.string("angle_id")
            guard project.angles.contains(where: { $0.id == id }) else { throw args.invalid("Unknown camera.") }
            changeSwitch(at, angle: id)
        case "audio": try changeSwitch(at, audio: audioSelection(args, project: project))
        case "default_audio": changeSwitch(at, audio: nil)
        default: throw args.invalid("Unknown switch action.")
        }
    }

    private func editSource(_ args: MulticamArguments, project: MulticamProject) throws -> [String: Any] {
        let id = try args.string("source_id")
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
            return ["source_id": id, "group_time": clock.description, "offset": offset.description]
        case "move":
            let direction = try args.direction()
            guard let index = project.angles.firstIndex(where: { $0.id == id }), project.angles.indices.contains(index + direction)
            else { throw args.invalid("Choose a camera that can move in that direction.") }
            moveSource(id, by: direction)
        case "microphone":
            guard project.pictureSources.contains(where: { $0.id == id }) else { throw args.invalid("Select a camera recording.") }
            let stream = args.values["audio_stream_index"] == nil ? nil : try audioSelection(args, project: project).stream
            updateSource(id) { $0.audioStream = stream }
        default: throw args.invalid("Unknown source action.")
        }
        return ["source_id": id]
    }

    private func relinkSource(_ args: MulticamArguments, project: MulticamProject,
                              validateCommit: @escaping @MainActor () throws -> Void) async throws
        -> (revision: Int, changed: Bool, historyRetained: Bool, warning: String?) {
        let id = try args.string("source_id")
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
        case "angle_set", "angle_clear":
            let index = try occurrence(args)
            let angle = try args.string("action") == "angle_set" ? args.string("angle_id") : nil
            guard assemblyRange(at: index) != nil else { throw args.invalid("Choose a source-backed assembly occurrence.") }
            if let angle, !project.angles.contains(where: { $0.id == angle }) { throw args.invalid("Unknown camera.") }
            guard setOccurrenceAngle(index, angle: angle) else { throw nativeEditError }
        case "append":
            let from = try args.time("from"), to = try args.time("to")
            guard project.range.from <= from, from < to, to <= project.range.to else { throw args.invalid("Choose a nonempty group range.") }
            addAssemblyRange(.init(from: from, to: to))
        case "trim":
            let index = try occurrence(args)
            guard args.values["from"] != nil || args.values["to"] != nil else {
                throw args.invalid("Supply a group in or out time to trim.")
            }
            guard let range = assemblyRange(at: index) else { throw args.invalid("Use still_editor_placement_update to resize an inserted still.") }
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
            return ["proposed_seconds": boundary.seconds, "boundary": boundary.description]
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
        case "apply_edge_suggestion":
            guard try applyEdgeSuggestion(args.time("to")) else {
                throw args.invalid("That edge suggestion is no longer available.")
            }
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
        state["mark_space"] = assemblySelection == nil ? "group" : "assembly"
        state["mark_in"] = displayedMarkIn?.description
        state["mark_out"] = displayedMarkOut?.description
        return state
    }

    private func changePreview(_ args: MulticamArguments, project: MulticamProject) throws -> [String: Any] {
        switch try args.string("action") {
        case "group": setAssemblyPreview(false)
        case "assembly": setAssemblyPreview(true)
        case "audition":
            let angle = try args.string("angle_id")
            guard let source = project.pictureSource(for: angle, at: currentGroupTime()), media[source.id] != nil else {
                throw args.invalid("Choose an available camera with a recording at the playhead.")
            }
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
