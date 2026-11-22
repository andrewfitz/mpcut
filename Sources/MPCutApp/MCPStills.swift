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
                case .group(let range): try advance(index, range.to.subtracting(range.from))
                case .still(let insert): try advance(index, insert.duration, insert: insert)
                }
            }
        }
        return rows
    }

    func mcpStillList(location: URL?, offset: Int, limit: Int) throws -> [String: Any] {
        let inserts = stillInserts
        let replacements = stillReplacements
        let placements = inserts.count + replacements.count
        let first = min(offset, placements)
        let last = first + min(limit, placements - first)
        var result: [String: Any] = ["items": [[String: Any]](), "offset": offset, "total": placements]
        if let policy = programColorPolicy { result["programColorPolicy"] = try mcpStillJSON(policy) }
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
                                      "framing": try mcpStillJSON(framing), "visibleDuration": duration.description,
                                      "visibleRanges": ranges.map { ["from": $0.from.description, "to": $0.to.description] },
                                      "visibleClock": multicam ? "assembly" : "sequence"]
            if let asset = assets[assetID] {
                let path = CutProject.mediaURL(asset.file, relativeTo: location ?? URL(fileURLWithPath: "/Untitled.cut")).path
                row["path"] = path
                row["name"] = asset.displayName
                row["offline"] = !FileManager.default.isReadableFile(atPath: path)
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
                    row["authoredFrom"] = occurrence.from.description
                    row["authoredTo"] = occurrence.to.description
                    if multicam { row["occurrence"] = occurrence.index } else { row["occurrence"] = insert.id }
                }
                return row
            }
            let replacement = replacements[i - inserts.count]
            var row = try item(id: replacement.id, assetID: replacement.assetID, operation: "replace",
                               clock: multicam ? "group" : "source", framing: replacement.framing)
            switch replacement.coverage {
            case .group(let range):
                row["authoredFrom"] = range.from.description
                row["authoredTo"] = range.to.description
            case .sequence(let fragments):
                row["fragments"] = fragments.enumerated().map { index, fragment in
                    ["index": index, "documentID": fragment.clipID, "sourceFrom": fragment.range.from.description,
                     "sourceTo": fragment.range.to.description] as [String: Any]
                }
            }
            return row
        }
        return result
    }
}

private func mcpStillJSON(_ value: some Encodable) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
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

    func mcpCommitStill(_ candidate: CutProject, action: String) throws {
        guard mcpCanEditStills else { throw MCPCommandError("editor_busy", "An editable picture timeline is required.") }
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
        let rightID = UUID().uuidString
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
                                     "leftPlacement": card.insert.id, "rightPlacement": right.insert.id,
                                     "historyRetained": mcpRevision != revision && (isMulticam ? multicam.preferences.historyLimit : editor.mcpHistoryLimit) > 0]
        return result
    }
}

extension ProjectSessions {
    func mcpStills(tool: String, arguments: [String: Any], session: ProjectSession,
                   checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        guard ["list_stills", "add_still", "update_still", "remove_still", "relink_still"].contains(tool) else { return nil }
        guard let project = session.mcpStillProject else { throw MCPCommandError("invalid_target", "Open a picture timeline.") }
        if tool == "list_stills" {
            return try project.mcpStillList(location: session.mcpStillLocation, offset: arguments["offset"] as? Int ?? 0,
                                           limit: arguments["limit"] as? Int ?? 50)
        }
        guard session.mcpCanEditStills else { throw MCPCommandError("editor_busy", "An editable picture timeline is required.") }
        let input = MCPStillInput(fields: arguments)
        let revision = session.mcpRevision
        var candidate = project
        var result: [String: Any] = [:]
        let action: String
        switch tool {
        case "add_still":
            let operation = try input.string("operation")
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
            let image = try await input.image()
            try checkAccess()
            let existingAsset = candidate.stillAssets.first { asset in
                let location = session.mcpStillLocation ?? URL(fileURLWithPath: "/Untitled.cut")
                return asset.fingerprint == image.fingerprint && CutProject.mediaURL(asset.file, relativeTo: location) == image.url
            }
            let assetID = existingAsset?.id ?? UUID().uuidString
            let placementID = UUID().uuidString
            let framing = try input.framing(existing: .fit)
            if existingAsset == nil {
                candidate = try candidate.addingStillAsset(.init(id: assetID, file: image.url.path,
                                                                  displayName: image.url.lastPathComponent, fingerprint: image.fingerprint))
            }
            if operation == "insert" {
                let at = try input.requiredTime("at")
                let cadence = try input.time("cadence") ?? session.mcpDefaultStillCadence(at: at)
                guard let cadence else { throw input.invalid("Supply cadence as an exact frame interval for this timeline.") }
                let insert = StillInsert(id: placementID, assetID: assetID, duration: try input.requiredTime("duration"),
                                         cadence: cadence, framing: framing)
                candidate = try candidate.insertingStill(insert, at: session.mcpStillBoundary(at, space: space))
                action = "Insert Still"
            } else {
                candidate = try session.mcpReplacePicture(in: candidate, id: placementID, asset: assetID, framing: framing,
                                                          from: input.requiredTime("from"), to: input.requiredTime("to"))
                action = "Replace Picture"
            }
            result = ["placement": placementID, "asset": assetID]
        case "update_still":
            let id = try input.id("placement")
            if let insert = project.stillInserts.first(where: { $0.id == id }) {
                guard ["from", "to", "clock", "fragmentIndex", "duplicateID", "detachID"].allSatisfy({ arguments[$0] == nil }) else {
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
                let duplicate = arguments["duplicateID"] as? String
                let detached = arguments["detachID"] as? String
                if ["from", "to", "at", "fragmentIndex", "clock", "duplicateID", "detachID"].contains(where: { arguments[$0] != nil }) {
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
                    candidate = try candidate.editingStillReplacement(id: id, fragmentIndex: arguments["fragmentIndex"] as? Int,
                                                                     from: boundary("from"), to: boundary("to"), at: boundary("at"),
                                                                     clock: clock, duplicateID: duplicate, detachID: detached)
                    if !session.isMulticam {
                        try session.editor.validateStillReplacementExtents(candidate, original: replacement)
                    }
                }
                let target = detached ?? duplicate ?? id
                candidate = try candidate.updatingStill(id: target, assetID: asset, framing: framing)
                if target != id { result["originalPlacement"] = id }
                result["placement"] = target
                result["asset"] = asset
            } else {
                throw MCPCommandError("invalid_target", "Read the current still placements and choose an ID.")
            }
            if result["placement"] == nil { result["placement"] = id }
            action = "Update Still"
        case "remove_still":
            let id = try input.id("placement")
            candidate = try project.removingStill(id: id)
            result["placement"] = id
            action = "Delete Still"
        default:
            let id = try input.id("asset")
            guard project.stillAssets.contains(where: { $0.id == id }) else {
                throw MCPCommandError("invalid_target", "Read the current still placements and choose an asset ID.")
            }
            let image = try await input.image()
            try checkAccess()
            candidate = try project.relinkingStillAsset(id, file: image.url.path, fingerprint: image.fingerprint)
            result["asset"] = id
            action = "Relink Still Image"
        }
        try checkAccess()
        guard session.mcpRevision == revision else { throw MCPCommandError("stale_revision", "The project changed during the still edit.") }
        if candidate != project { try session.mcpCommitStill(candidate, action: action) }
        result["action"] = action
        result["changed"] = session.mcpRevision != revision
        result["historyRetained"] = session.mcpRevision != revision && preferences.historyLimit > 0
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

    func framing(existing: StillImageFraming) throws -> StillImageFraming {
        var value = existing
        if let mode = fields["fit"] as? String { value.mode = mode == "fit" ? .fit : .fill }
        if fields["clearCrop"] as? Bool == true {
            guard fields["crop"] == nil else { throw invalid("Choose crop or clearCrop.") }
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

    func image() async throws -> (url: URL, fingerprint: String) {
        let path = try string("path")
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw invalid("Supply an absolute local image path.") }
        let url = URL(fileURLWithPath: path)
        let worker = Task.detached(priority: .userInitiated) {
            let fingerprint = try StillImage.fingerprint(url)
            try Task.checkCancellation()
            _ = try StillImage.inspect(url)
            guard try StillImage.fingerprint(url) == fingerprint else {
                throw CutError(code: "source_changed", message: "The image changed while it was being imported.")
            }
            return (url, fingerprint)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}

private extension ProjectSession {
    func mcpDefaultStillCadence(at target: RationalTime) -> RationalTime? {
        if !isMulticam { return editor.stillCadence }
        let ends = multicam.assemblyRangeEnds
        let index = min(ends.lowerBound { $0 > target }, max(0, ends.count - 1))
        guard let range = multicam.assemblyRange(at: index),
              let elapsed = try? target.subtracting(multicam.assemblyStart(at: index)),
              let group = try? range.from.adding(elapsed) else { return nil }
        return multicam.multicamStillCadence(atGroup: group)
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
