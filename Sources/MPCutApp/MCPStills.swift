import Foundation
import MPCutCore

struct MCPStillOccurrence {
    let index: Int
    let insert: StillInsert
    let from: RationalTime
    let to: RationalTime
}

extension CutProject {
    var mcpHasStills: Bool { !stillInserts.isEmpty || !stillReplacements.isEmpty }

    func mcpStillOccurrences() throws -> [MCPStillOccurrence] {
        var output = RationalTime.zero
        var rows: [MCPStillOccurrence] = []
        func advance(_ index: Int, _ duration: RationalTime, insert: StillInsert? = nil) throws {
            let end = try output.adding(duration)
            if let insert { rows.append(.init(index: index, insert: insert, from: output, to: end)) }
            output = end
        }
        switch self {
        case .sequence:
            break
        case .stillSequence(let sequence):
            for (index, item) in sequence.items.enumerated() {
                switch item {
                case .source(let clip): try advance(index, clip.to.subtracting(clip.from))
                case .still(let insert): try advance(index, insert.duration, insert: insert)
                }
            }
        case .multicam(let project):
            for (index, item) in (project.assemblyItems ?? []).enumerated() {
                switch item {
                case .group(let range, _, _, _): try advance(index, range.to.subtracting(range.from))
                case .still(let insert): try advance(index, insert.duration, insert: insert)
                }
            }
        }
        return rows
    }

    func mcpStillList(location: URL?, offset: Int, limit: Int) throws -> [String: Any] {
        guard offset >= 0, (1...200).contains(limit) else {
            throw MCPCommandError("invalid_arguments", "Use a nonnegative offset and a limit from 1 through 200.")
        }
        let inserts = stillInserts
        let replacements = stillReplacements
        let placements = inserts.count + replacements.count
        let first = min(offset, placements)
        let last = first + min(limit, placements - first)
        var result: [String: Any] = ["items": [[String: Any]](), "offset": offset, "total": placements]
        if let soundtrack = stillSoundtrack { result["soundtrack"] = try mcpStillJSON(soundtrack) }
        if let policy = programColorPolicy { result["program_color_policy"] = try mcpStillJSON(policy) }
        guard first < last else { return result }
        let visible = Dictionary(grouping: try resolveStills().spans.compactMap { span in
            span.placementID.map { ($0, span.output) }
        }, by: { $0.0 })
        let assets = Dictionary(uniqueKeysWithValues: stillAssets.map { ($0.id, $0) })
        let multicam: Bool
        if case .multicam = self { multicam = true } else { multicam = false }
        let insertRows = try mcpStillOccurrences()
        let insertsByID = Dictionary(uniqueKeysWithValues: insertRows.map { ($0.insert.id, $0) })

        func item(id: String, assetID: String, operation: String, clock: String, framing: StillImageFraming) throws -> [String: Any] {
            let ranges = visible[id, default: []].map { $0.1 }
            let duration = try ranges.reduce(RationalTime.zero) { sum, range in try sum.adding(range.to.subtracting(range.from)) }
            var row: [String: Any] = ["placement": id, "asset": assetID, "operation": operation, "clock": clock,
                                      "framing": try mcpStillJSON(framing), "visible_duration": duration.description,
                                      "visible_ranges": ranges.map { ["from": $0.from.description, "to": $0.to.description] },
                                      "visible_clock": multicam ? "assembly" : "sequence"]
            if let asset = assets[assetID] {
                row["name"] = asset.displayName
                if asset.isGap {
                    row["kind"] = "gap"
                    row["offline"] = false
                } else {
                    let path = CutProject.mediaURL(asset.file, relativeTo: location ?? URL(fileURLWithPath: "/Untitled.cut")).path
                    row["path"] = path
                    row["offline"] = !FileManager.default.isReadableFile(atPath: path)
                }
            }
            return row
        }

        result["items"] = try (first..<last).map { i in
            if i < inserts.count {
                let insert = inserts[i]
                var row = try item(id: insert.id, assetID: insert.assetID, operation: "insert",
                                   clock: multicam ? "assembly" : "sequence", framing: insert.framing)
                row["duration"] = insert.duration.description
                row["cadence"] = insert.cadence.description
                if let occurrence = insertsByID[insert.id] {
                    row["authored_from"] = occurrence.from.description
                    row["authored_to"] = occurrence.to.description
                    if multicam { row["occurrence"] = occurrence.index } else { row["occurrence"] = insert.id }
                }
                return row
            }
            let replacement = replacements[i - inserts.count]
            var row = try item(id: replacement.id, assetID: replacement.assetID, operation: "replace",
                               clock: multicam ? "group" : "source", framing: replacement.framing)
            switch replacement.coverage {
            case .group(let range):
                row["authored_from"] = range.from.description
                row["authored_to"] = range.to.description
            case .sequence(let fragments):
                row["fragments"] = fragments.enumerated().map { index, fragment in
                    ["index": index, "document_id": fragment.clipID, "source_from": fragment.range.from.description,
                     "source_to": fragment.range.to.description] as [String: Any]
                }
            }
            return row
        }
        return result
    }
}

private func mcpStillJSON(_ value: some Encodable) throws -> Any {
    try JSONSerialization.jsonObject(with: MCPSchemas.encodeResult(value))
}

extension ProjectSession {
    var mcpStillProject: CutProject? {
        if isMulticam { return multicam.project.map(CutProject.multicam) }
        return editor.stillProject
    }

    var mcpStillLocation: URL? { isMulticam ? multicam.projectURL : editor.projectURL }

    var mcpCanEditStills: Bool {
        guard window?.attachedSheet == nil else { return false }
        if isMulticam {
            return multicam.project != nil && !multicam.isBusy && multicam.setup.isEmpty && multicam.notice == nil
        }
        return editor.canEdit && !editor.isAudioOnly && !editor.mcpHasActiveTrim
    }

    var mcpCanStartStillTimeline: Bool {
        !isMulticam && editor.isEmpty && editor.stillProject.stillFormat == nil
            && editor.canInsertStill && !editor.mcpHasActiveTrim && !hasLifecycleModal
    }

    func mcpCommitStill(_ candidate: CutProject, action: String) throws {
        guard mcpCanEditStills || (mcpCanStartStillTimeline && candidate.stillFormat != nil) else {
            throw MCPCommandError("editor_busy", "An editable picture timeline is required.")
        }
        if isMulticam {
            guard case .multicam = candidate,
                  multicam.performStillEdit(action, { _ in candidate }) else {
                throw MCPCommandError("edit_failed", multicam.notice?.message ?? "The multicam editor could not apply the still edit.")
            }
        } else {
            try editor.applyStillProject(candidate, action: action)
        }
    }

    func mcpSplitInlineStill(arguments: [String: Any], checkAccess: @MainActor () throws -> Void) throws -> [String: Any]? {
        guard let project = mcpStillProject, !project.stillInserts.isEmpty else { return nil }
        let target = arguments["occurrence"]
        let card = try project.mcpStillOccurrences().first {
            if isMulticam { return target.flatMap(mcpInteger) == $0.index }
            return (target as? String) == $0.insert.id
        }
        guard let card else { return nil }
        guard arguments["space"] as? String == (isMulticam ? "assembly" : "sequence"),
              let text = arguments["time"] as? String else {
            throw MCPCommandError("invalid_target", "Use an output-clock time to split an inserted still.")
        }
        let boundary = try RationalTime(parsing: text)
        guard card.from < boundary, boundary < card.to else {
            throw MCPCommandError("invalid_target", "Choose an interior presentation boundary on the still.")
        }
        let rightID = ProjectIdentifier.make()
        let candidate = try project.splittingStill(id: card.insert.id, at: boundary.subtracting(card.from), newID: rightID)
        let right = try candidate.mcpStillOccurrences().first { $0.insert.id == rightID }
        guard let right else { throw MCPCommandError("invalid_target", "The still could not split at that boundary.") }
        let revision = mcpRevision
        try checkAccess()
        try mcpCommitStill(candidate, action: "Split Still")
        let result: [String: Any] = ["action": "Split Still", "boundary": boundary.description,
                                     "space": isMulticam ? "assembly" : "sequence",
                                     "left": isMulticam ? card.index as Any : card.insert.id,
                                     "right": isMulticam ? right.index as Any : right.insert.id,
                                     "left_placement": card.insert.id, "right_placement": right.insert.id,
                                     "history_retained": mcpRevision != revision && (isMulticam ? multicam.preferences.historyLimit : editor.mcpHistoryLimit) > 0]
        return result
    }
}

extension ProjectSessions {
    func mcpStills(tool: String, arguments: [String: Any], session: ProjectSession,
                   checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        guard ["still_editor_placements_list", "timeline_gap_insert", "still_editor_placement_insert", "still_editor_picture_replace", "still_editor_placement_update", "still_editor_placement_remove", "still_editor_soundtrack_attach", "still_editor_soundtrack_fit", "still_editor_soundtrack_detach", "timeline_clips_space"].contains(tool) else { return nil }
        guard let project = session.mcpStillProject else { throw MCPCommandError("invalid_target", "Open a picture timeline.") }
        if tool == "still_editor_placements_list" {
            return try project.mcpStillList(location: session.mcpStillLocation, offset: arguments["offset"] as? Int ?? 0,
                                           limit: arguments["limit"] as? Int ?? 50)
        }
        let isInsert = tool == "timeline_gap_insert" || tool == "still_editor_placement_insert"
        let startsTimeline = isInsert && session.mcpCanStartStillTimeline
        guard session.mcpCanEditStills || startsTimeline else {
            throw MCPCommandError("editor_busy", "An editable picture timeline is required.")
        }
        let input = MCPStillInput(fields: arguments)
        let initialFormat = try input.initialFormat(required: startsTimeline)
        let revision = session.mcpRevision
        var candidate = project
        var result: [String: Any] = [:]
        let action: String
        var soundtrackMedia: MediaInfo?
        switch tool {
        case "still_editor_soundtrack_attach":
            guard project.stillFormat != nil else { throw input.invalid("Open a still-only project to attach a soundtrack.") }
            let (clip, media) = try await input.soundtrack()
            guard media.identity.isCurrentSnapshot(at: media.url) else {
                throw CutError(code: "source_changed", message: "The soundtrack changed while the recording was being read.")
            }
            candidate = try project.attachingStillSoundtrack(clip)
            if arguments["fit_soundtrack"] as? Bool == true {
                candidate = try candidate.fittingStillToSoundtrack()
            }
            soundtrackMedia = media
            action = "Attach Soundtrack"
        case "still_editor_soundtrack_fit":
            candidate = try project.fittingStillToSoundtrack()
            action = "Fit Image to Soundtrack"
        case "still_editor_soundtrack_detach":
            candidate = try project.attachingStillSoundtrack(nil)
            action = "Detach Soundtrack"
        case "timeline_clips_space":
            guard project.hasSpacingBoundaries else {
                throw MCPCommandError("invalid_target", "Space Clips requires at least two clips or still pictures.")
            }
            let background = arguments["background"] as? String ?? "#000000"
            let duration = try input.time("duration")
            let suppliedCadence = try input.time("cadence")
            // Removing gaps does not create frames and works without an inferred timeline cadence.
            let cadence = suppliedCadence ?? (duration == .zero ? RationalTime(numerator: 1, denominator: 30)
                : session.mcpDefaultStillCadence(at: .zero))
            guard let cadence else {
                throw input.invalid("Supply cadence as an exact frame interval for this timeline.")
            }
            if let duration {
                candidate = try project.spacingClips(duration: duration, cadence: cadence, background: background)
            } else {
                candidate = try project.spacingClipsUsingSourceTiming(cadence: cadence, background: background,
                                                                     relativeTo: session.mcpStillLocation)
            }
            action = "Space Clips"
        case "timeline_gap_insert", "still_editor_placement_insert", "still_editor_picture_replace":
            let operation = tool == "still_editor_picture_replace" ? "replace" : "insert"
            let space = try input.string("space")
            if operation == "insert" {
                guard space == (session.isMulticam ? "assembly" : "sequence"), arguments["from"] == nil, arguments["to"] == nil else {
                    throw input.invalid("Use the output clock with at and duration for an insert.")
                }
            } else {
                guard space == (session.isMulticam ? "group" : "sequence"),
                      ["at", "duration", "cadence"].allSatisfy({ arguments[$0] == nil }) else {
                    throw input.invalid("Use group or sequence bounds for a replacement.")
                }
            }
            let asset: StillAsset
            if tool == "timeline_gap_insert" {
                guard operation == "insert", arguments["path"] == nil else {
                    throw input.invalid("A color gap requires an insert with no image path.")
                }
                asset = candidate.stillAssets.first(where: \.isGap) ?? StillAsset(gapID: ProjectIdentifier.make(avoiding: candidate.stillAssets.map(\.id)))
            } else {
                let image = try await input.image()
                let location = session.mcpStillLocation ?? URL(fileURLWithPath: "/Untitled.cut")
                asset = candidate.stillAssets.first {
                    !$0.isGap && $0.fingerprint == image.fingerprint && CutProject.mediaURL($0.file, relativeTo: location) == image.url
                } ?? StillAsset(id: ProjectIdentifier.make(avoiding: candidate.stillAssets.map(\.id)), file: image.url.path,
                                displayName: image.url.lastPathComponent, fingerprint: image.fingerprint)
            }
            try checkAccess()
            let assetID = asset.id
            let placementID = ProjectIdentifier.make()
            let framing = try input.framing(existing: .fit)
            if let (format, color) = initialFormat {
                guard try input.requiredTime("at") == .zero else {
                    throw input.invalid("Start the still-only timeline at zero.")
                }
                if let interval = try input.time("cadence"), interval != format.cadence {
                    throw input.invalid("Use the initial format cadence for the first still.")
                }
                candidate = try .makeStillTimeline(format: format, asset: asset, placementID: placementID,
                                                  duration: input.requiredTime("duration"), framing: framing,
                                                  colorPolicy: color.policy)
                action = asset.isGap ? "Insert Color Gap" : "Insert Still"
            } else if operation == "insert" {
                candidate = try candidate.addingStillAsset(asset)
                let at = try session.mcpStillBoundary(input.requiredTime("at"), space: space)
                let cadence = try input.time("cadence") ?? session.mcpDefaultStillCadence(at: at)
                guard let cadence else { throw input.invalid("Supply cadence as an exact frame interval for this timeline.") }
                let insert = StillInsert(id: placementID, assetID: assetID, duration: try input.requiredTime("duration"),
                                         cadence: cadence, framing: framing)
                candidate = try candidate.insertingStill(insert, at: at)
                action = asset.isGap ? "Insert Color Gap" : "Insert Still"
            } else {
                candidate = try candidate.addingStillAsset(asset)
                candidate = try session.mcpReplacePicture(in: candidate, id: placementID, asset: assetID, framing: framing,
                                                          from: input.requiredTime("from"), to: input.requiredTime("to"))
                action = "Replace Picture"
            }
            result = ["placement": placementID, "asset": assetID]
        case "still_editor_placement_update":
            let id = try input.id("placement")
            if let insert = project.stillInserts.first(where: { $0.id == id }) {
                guard ["from", "to", "clock", "fragment_index", "duplicate_id", "detach_id"].allSatisfy({ arguments[$0] == nil }) else {
                    throw input.invalid("Use at or duration to edit an insert.")
                }
                let asset = arguments["asset"] as? String ?? insert.assetID
                candidate = try candidate.updatingStill(id: id, assetID: asset, framing: input.framing(existing: insert.framing))
                if let target = try input.time("at") {
                    candidate = try candidate.movingStill(id: id, to: session.mcpStillBoundary(target, space: session.isMulticam ? "assembly" : "sequence"))
                }
                if arguments["duration"] != nil || arguments["cadence"] != nil {
                    candidate = try candidate.resizingStill(id: id, duration: input.time("duration") ?? insert.duration,
                                                            cadence: input.time("cadence") ?? insert.cadence)
                }
                result["asset"] = asset
            } else if let replacement = project.stillReplacements.first(where: { $0.id == id }) {
                guard arguments["duration"] == nil, arguments["cadence"] == nil else {
                    throw input.invalid("Use replacement bounds or a destination to edit replacement coverage.")
                }
                let framing = try input.framing(existing: replacement.framing)
                let asset = arguments["asset"] as? String ?? replacement.assetID
                let duplicate = arguments["duplicate_id"] as? String
                let detached = arguments["detach_id"] as? String
                if ["from", "to", "at", "fragment_index", "clock", "duplicate_id", "detach_id"].contains(where: { arguments[$0] != nil }) {
                    let clock = arguments["clock"] as? String
                    func boundary(_ key: String) throws -> RationalTime? {
                        guard let time = try input.time(key) else { return nil }
                        if clock == "source" { return time }
                        if session.isMulticam, let range = session.multicam.project?.range,
                           time >= range.from, time <= range.to {
                            if time == range.to { return time }
                            return session.multicam.stillReplacementBounds(.init(from: time, to: range.to)).from
                        }
                        if !session.isMulticam { return try session.editor.stillBoundary(at: time.seconds) }
                        return time
                    }
                    candidate = try candidate.editingStillReplacement(id: id, fragmentIndex: arguments["fragment_index"] as? Int,
                                                                     from: boundary("from"), to: boundary("to"), at: boundary("at"),
                                                                     clock: clock, duplicateID: duplicate, detachID: detached)
                    if !session.isMulticam {
                        try session.editor.validateStillReplacementExtents(candidate, original: replacement)
                    }
                }
                let target = detached ?? duplicate ?? id
                candidate = try candidate.updatingStill(id: target, assetID: asset, framing: framing)
                if target != id { result["original_placement"] = id }
                result["placement"] = target
                result["asset"] = asset
            } else {
                throw MCPCommandError("invalid_target", "Read the current still placements and choose an ID.")
            }
            if result["placement"] == nil { result["placement"] = id }
            action = "Update Still"
        case "still_editor_placement_remove":
            let id = try input.id("placement")
            candidate = try project.removingStill(id: id)
            result["placement"] = id
            action = "Delete Still"
        default:
            return nil
        }
        try checkAccess()
        guard session.mcpRevision == revision else { throw MCPCommandError("stale_revision", "The project changed during the still edit.") }
        if candidate != project {
            if let soundtrackMedia { session.editor.cacheStillSoundtrackMedia(soundtrackMedia) }
            try session.mcpCommitStill(candidate, action: action)
        }
        if let soundtrack = candidate.stillSoundtrack { result["soundtrack"] = try mcpStillJSON(soundtrack) }
        result["action"] = action
        result["changed"] = session.mcpRevision != revision
        result["history_retained"] = session.mcpRevision != revision && preferences.historyLimit > 0
        if session.isMulticam, let notice = session.multicam.notice { result["warning"] = notice.message }
        return result
    }
}

private struct MCPStillInput {
    let fields: [String: Any]

    func invalid(_ message: String) -> MCPCommandError { MCPCommandError("invalid_arguments", message) }

    func string(_ key: String) throws -> String {
        guard let value = fields[key] as? String else { throw invalid("Supply \(key).") }
        return value
    }

    func id(_ key: String) throws -> String {
        let id = try string(key)
        guard !id.isEmpty else { throw invalid("Supply an ID for \(key).") }
        return id
    }

    func time(_ key: String) throws -> RationalTime? {
        try (fields[key] as? String).map { try RationalTime(parsing: $0) }
    }

    func requiredTime(_ key: String) throws -> RationalTime { try RationalTime(parsing: string(key)) }

    func initialFormat(required: Bool) throws -> (StillTimelineFormat, StillTimelineFormat.Color)? {
        guard let raw = fields["initial_format"] else {
            if required { throw invalid("Supply initial_format to start a still-only timeline.") }
            return nil
        }
        guard required else { throw invalid("Supply initial_format only for the first still or gap in a blank sequence.") }
        guard var object = raw as? [String: Any] else { throw invalid("Supply a still timeline format object.") }
        let color = object.removeValue(forKey: "color") as? String ?? "sdr"
        guard let interpretation = StillTimelineFormat.Color(rawValue: color) else {
            throw invalid("Choose sdr, pq or hlg for the initial format color.")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let format = try JSONDecoder().decode(StillTimelineFormat.self, from: data)
        try format.validate(color: interpretation.policy)
        return (format, interpretation)
    }

    func framing(existing: StillImageFraming) throws -> StillImageFraming {
        var value = existing
        if let mode = fields["fit"] as? String { value.mode = mode == "fit" ? .fit : .fill }
        if fields["clear_crop"] as? Bool == true {
            guard fields["crop"] == nil else { throw invalid("Choose crop or clear_crop.") }
            value.crop = nil
        }
        if let crop = fields["crop"] as? [String: Any] {
            let input = MCPStillInput(fields: crop)
            value.crop = try .init(x: input.requiredTime("x"), y: input.requiredTime("y"),
                                   width: input.requiredTime("width"), height: input.requiredTime("height"))
        }
        if let background = fields["background"] as? String { value.background = background }
        return value
    }

    func soundtrack() async throws -> (CutSequenceClip, MediaInfo) {
        let path = try string("soundtrack")
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw invalid("Supply an absolute local soundtrack path.") }
        let file = URL(fileURLWithPath: path)
        let stream = fields["audio_stream"].flatMap(mcpInteger)
        let from = try time("from")
        let to = try time("to")
        let worker = Task.detached(priority: .userInitiated) {
            let media = try CutEngine(cancelled: { Task.isCancelled }).inspect(file)
            let clip = try StillSoundtrack.reference(media: media, stream: stream, from: from, to: to)
            try Task.checkCancellation()
            return (clip, media)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    func image() async throws -> (url: URL, fingerprint: String) {
        let path = try string("path")
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw invalid("Supply an absolute local image path.") }
        let url = URL(fileURLWithPath: path)
        let worker = Task.detached(priority: .userInitiated) {
            let fingerprint = try StillImage.inspectAndFingerprint(url, cancelled: { Task.isCancelled }).fingerprint
            try Task.checkCancellation()
            return (url, fingerprint)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}

private extension ProjectSession {
    func mcpDefaultStillCadence(at target: RationalTime) -> RationalTime? {
        isMulticam ? multicam.multicamStillCadence(atAssembly: target) : editor.stillCadence
    }

    func mcpStillBoundary(_ target: RationalTime, space: String) throws -> RationalTime {
        if !isMulticam { return try editor.stillBoundary(at: target.seconds) }
        let duration = try mcpStillProject?.resolveStills().duration ?? .zero
        guard space == "assembly", target >= .zero, target <= duration else {
            throw MCPCommandError("invalid_target", "Choose a time on the assembly.")
        }
        return multicam.snappedAssemblyStillPosition(target)
    }

    func mcpReplacePicture(in project: CutProject, id: String, asset: String, framing: StillImageFraming,
                           from: RationalTime, to: RationalTime) throws -> CutProject {
        guard from < to else { throw MCPCommandError("invalid_target", "Choose a nonempty replacement interval.") }
        if isMulticam {
            guard let group = multicam.project?.range, from >= group.from, to <= group.to else {
                throw MCPCommandError("invalid_target", "Choose a replacement interval inside the group.")
            }
            let range = multicam.stillReplacementBounds(AudioSpan(from: from, to: to))
            return try project.addingStillReplacement(.init(id: id, assetID: asset, framing: framing, coverage: .group(range)))
        }
        return try project.replacingPicture(id: id, assetID: asset, framing: framing,
                                            from: editor.stillBoundary(at: from.seconds), to: editor.stillBoundary(at: to.seconds))
    }
}
