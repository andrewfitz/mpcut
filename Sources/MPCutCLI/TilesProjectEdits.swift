import Foundation
import MPCutCore

extension TilesCLI {
    func runTileEdits(json: Bool, useSidecar: Bool, interruption: Interruption) throws {
        let input = try request(interruption)
        let document = try input.url("project_path")
        if operation == .reconcile {
            try reconcileTiles(input, document: document, json: json, interruption: interruption)
            return
        }
        if operation == .listLayouts {
            try listTileLayouts(input, document: document, json: json)
            return
        }
        var tileID: String?
        var feedID: String?
        var grid: ParticipantGridCorrection?
        let receipt = try mutateProject(input, document: document, action: tileEditAction, interruption: interruption) { project in
            if operation == .setLayout {
                try setTileLayout(input, document: document, in: &project)
                return
            }
            let source = try sourceID(in: project, request: input, scannedOnly: operation != .addBox)
            switch operation {
            case .treatFeed:
                try setTileTreatment(input, in: &project)
            case .confirmFeed:
                try project.confirmParticipantPrivacy(sourceID: source,
                    participantID: input.required("feed_id", as: String.self), range: input.tileRange(), relativeTo: document)
            case .addBox:
                let id = try input.value("tile_id", as: String.self) ?? UUID().uuidString.lowercased()
                let range = try requiredTileEditRange(input)
                try project.addTileBox(sourceID: source, document: document, appearance: .init(id: id,
                    participantID: input.value("feed_id", as: String.self), range: range, bounds: tileBounds(input)))
                tileID = id
            case .setBox:
                let id = try input.required("tile_id", as: String.self)
                let range = try requiredTileEditRange(input)
                try project.participants.correctBounds(sourceID: source, appearanceID: id, bounds: tileBounds(input), range: range)
                if let feed = try input.value("feed_id", as: String.self) {
                    try project.participants.linkAppearance(sourceID: source, appearanceID: id, participantID: feed, range: range)
                }
                tileID = id
            case .splitTile:
                let id = try input.required("tile_id", as: String.self)
                let time = try RationalTime(parsing: input.required("at", as: String.self))
                let newID = try input.value("new_tile_id", as: String.self) ?? UUID().uuidString.lowercased()
                try project.participants.splitAppearance(sourceID: source, appearanceID: id, at: time, newAppearanceID: newID)
                tileID = newID
            case .screenShare:
                let id = try input.required("tile_id", as: String.self)
                let range = try input.tileRange() ?? tileTrackRange(in: project, sourceID: source, tileID: id)
                feedID = try project.participants.setScreenShare(sourceID: source, appearanceID: id, range: range)
                tileID = id
            case .correctGrid:
                let value = try input.required("grid", as: String.self)
                guard case .fixed(let columns, let rows) = ParticipantFeedLayout(feedLayout: value) else {
                    throw CLIError("invalid_arguments", "Supply an even grid as COLSxROWS with one to 64 cells.")
                }
                grid = try project.correctTileGrid(sourceID: source, document: document, range: requiredTileEditRange(input),
                    columns: Int(columns), rows: Int(rows), cancelled: { !interruption.isActive })
            default:
                throw CLIError("invalid_arguments", "Unknown tile edit.")
            }
        }
        try writeJSON(TileEditReceipt(projectPath: receipt.projectPath, operationCount: receipt.operationCount,
                                     tileID: tileID, feedID: feedID, grid: grid),
                      pretty: !json, checkCancellation: false)
    }

    private func setTileTreatment(_ input: ParticipantRequest, in project: inout CutProject) throws {
        let feed = try input.required("feed_id", as: String.self)
        let treatment = try input.required("treatment", as: String.self)
        let mode: ParticipantFeedTreatment.Mode?
        switch treatment {
        case "none": mode = nil
        case "blur": mode = .blur
        case "cover": mode = .cover
        case "remove": mode = .remove
        default: throw CLIError("invalid_arguments", "Choose a treatment of none, blur, cover or remove.")
        }
        var color: UInt32 = 0
        if let raw = input.fields["color"] {
            guard mode == .cover else { throw CLIError("invalid_arguments", "Use --color with the cover treatment.") }
            if let hex = raw as? String {
                let digits = hex.hasPrefix("#") ? hex.dropFirst() : hex[...]
                guard !digits.isEmpty, digits.count <= 6, let value = UInt32(digits, radix: 16) else {
                    throw CLIError("invalid_arguments", "Supply --color in RRGGBB hexadecimal.")
                }
                color = value
            } else {
                color = try input.required("color", as: UInt32.self)
            }
        }
        project = try project.settingFeedTreatment(feedID: feed, treatment: mode.map { .init(mode: $0, color: color) })
    }

    private func setTileLayout(_ input: ParticipantRequest, document: URL, in project: inout CutProject) throws {
        let clipID = try input.value("clip_id", as: String.self)
        let occurrence = try input.value("occurrence_id", as: String.self)
        let group = try input.value("group", as: Bool.self) ?? false
        let count = [clipID != nil, occurrence != nil, group].filter { $0 }.count
        guard count == 1 else {
            throw CLIError("invalid_arguments", "Address one layout scope with --clip-id, --occurrence-id or --group.")
        }
        let scope: TileLayoutScope
        let whole: MulticamRange
        if let clipID {
            guard let clip = project.sequenceClips?.first(where: { $0.id == clipID }) else {
                throw CLIError("unknown_clip", "No sequence clip has the requested ID.")
            }
            scope = .clip(clipID)
            whole = .init(from: clip.from, to: clip.to)
        } else {
            guard case .multicam(let multi) = project else {
                throw CLIError("invalid_arguments", "Group and occurrence layouts require a multicam project.")
            }
            if let occurrence {
                let items = multi.assemblyItems ?? [.group(multi.range)]
                guard let index = multi.tileOccurrenceIDs.firstIndex(of: occurrence),
                      let range = items[index].group else {
                    throw CLIError("unknown_occurrence", "No assembly occurrence has the requested ID.")
                }
                scope = .occurrence(occurrence)
                whole = range
            } else {
                scope = .group
                whole = multi.range
            }
        }
        if let source = try input.value("source_id", as: String.self) {
            guard let clipID, project.sequenceClips?.contains(where: { $0.id == clipID && $0.file == source }) == true else {
                throw CLIError("unknown_source", "The selected layout scope does not use the requested source ID.")
            }
        }
        let range = try input.tileRange() ?? whole
        let layoutName = try input.required("layout", as: String.self)
        guard let layout = ParticipantShotLayout(rawValue: layoutName == "side-by-side" ? "pair" : layoutName) else {
            throw CLIError("invalid_arguments", "Choose original, arranged, solo, side-by-side or grid.")
        }
        let feeds = try input.value("feed_id", as: [String].self) ?? []
        let explicit = try tileLayoutSlots(input)
        guard feeds.isEmpty || explicit.isEmpty else {
            throw CLIError("invalid_arguments", "Choose either --feed-id or --slot.")
        }
        let slots = explicit.isEmpty ? feeds.map { ParticipantSlot(id: $0) } : explicit
        if layout == .original, !slots.isEmpty {
            throw CLIError("invalid_arguments", "Choose Original without feeds or slots.")
        }
        let compact = try input.value("compact", as: Bool.self) ?? false
        let span = layout == .original && occurrence == nil
            ? nil : TileLayoutSpan(range: range, layout: layout, slots: slots, compact: compact)
        project = try project.settingTileLayout(scope: scope, range: range, layout: span, relativeTo: document)
    }

    private func listTileLayouts(_ input: ParticipantRequest, document: URL, json: Bool) throws {
        let project = try CutProject.load(from: document)
        let clipID = try input.value("clip_id", as: String.self)
        let source = try input.value("source_id", as: String.self)
        let available = project.tileLayoutListings
        if case .multicam = project {
            guard clipID == nil, source == nil else {
                throw CLIError("invalid_arguments", "Group and occurrence layouts are listed for the whole multicam project.")
            }
        } else {
            if let clipID, !available.contains(where: { $0.clipID == clipID }) {
                throw CLIError("unknown_clip", "No sequence clip has the requested ID.")
            }
            if let source, !available.contains(where: { $0.sourceID == source }) {
                throw CLIError("unknown_source", "No sequence clip uses the requested source.")
            }
        }
        let entries = available.filter { (clipID == nil || $0.clipID == clipID) && (source == nil || $0.sourceID == source) }
        try writeJSON(TileLayoutsReport(layouts: entries), pretty: !json)
    }

    private var tileEditAction: String {
        switch operation {
        case .treatFeed: "Change Feed Treatment"
        case .confirmFeed: "Confirm Feed"
        case .setLayout: "Set Tile Layout"
        case .addBox: "Add Tile Box"
        case .setBox: "Correct Tile Box"
        case .splitTile: "Split Tile"
        case .screenShare: "Mark Screen Share"
        case .correctGrid: "Correct Tile Grid"
        default: "Edit Tiles"
        }
    }

    private func reconcileTiles(_ input: ParticipantRequest, document: URL, json: Bool,
                                interruption: Interruption) throws {
        let apply = try input.value("apply", as: Bool.self) ?? false
        let token = try input.value("review", as: String.self)
        guard apply == (token != nil) else {
            throw CLIError("invalid_arguments", "Use --apply with the --review token from the reconciliation report.")
        }
        let cancelled = { !interruption.isActive }
        let scan = try input.analysis(cancelled: cancelled)
        if let token {
            let receipt = try mutateProject(input, document: document, action: "Reconcile Tiles", interruption: interruption) {
                let source = try sourceID(in: $0, request: input)
                try $0.applyReviewedParticipantReconciliation(scan, sourceID: source, relativeTo: document,
                    token: token, cancelled: cancelled)
            }
            try writeJSON(receipt, pretty: !json, checkCancellation: false)
        } else {
            guard input.fields["out_project"] == nil, input.fields["in_place"] == nil else {
                throw CLIError("invalid_arguments", "Supply an output destination when applying the reviewed reconciliation.")
            }
            let project = try CutProject.load(from: document)
            let source = try sourceID(in: project, request: input)
            let review = try project.participantReconciliation(scan, sourceID: source, relativeTo: document, cancelled: cancelled)
            try writeJSON(TileReconciliationReport(review: review, token: review.reviewToken(for: scan)), pretty: !json)
        }
    }
}

private struct TileEditReceipt: Encodable {
    let ok = true
    let projectPath: String
    let operationCount: Int
    let tileID: String?
    let feedID: String?
    let grid: ParticipantGridCorrection?

    private enum CodingKeys: String, CodingKey {
        case ok, projectPath = "project_path", operationCount = "operation_count"
        case tileID = "tile_id", feedID = "feed_id", grid
    }
}

private struct TileReconciliationReport: Encodable {
    let review: ParticipantReconciliation
    let token: String

    private enum CodingKeys: String, CodingKey {
        case token = "review", sourceID = "source_id", sourceChanged = "source_changed"
        case retainedCopiedGeometry = "retained_copied_geometry", removedTileIDs = "removed_tile_ids"
        case affectedFeedIDs = "affected_feed_ids", affectedTreatmentIDs = "affected_treatment_ids"
        case affectedBindingIDs = "affected_binding_ids", affectedPresentationIDs = "affected_presentation_ids"
        case removedOverrideCount = "removed_preference_count"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(token, forKey: .token)
        try values.encode(review.sourceID, forKey: .sourceID)
        try values.encode(review.sourceChanged, forKey: .sourceChanged)
        try values.encode(review.retainedCopiedGeometry, forKey: .retainedCopiedGeometry)
        try values.encode(review.removedAppearanceIDs, forKey: .removedTileIDs)
        try values.encode(review.affectedParticipantIDs, forKey: .affectedFeedIDs)
        try values.encode(review.affectedRedactionIDs, forKey: .affectedTreatmentIDs)
        try values.encode(review.affectedBindingIDs, forKey: .affectedBindingIDs)
        try values.encode(review.affectedPresentationIDs, forKey: .affectedPresentationIDs)
        try values.encode(review.removedOverrideCount, forKey: .removedOverrideCount)
    }
}

private func requiredTileEditRange(_ request: ParticipantRequest) throws -> MulticamRange {
    guard let range = try request.tileRange() else {
        throw CLIError("invalid_arguments", "Supply both --from and --to.")
    }
    return range
}

private func tileTrackRange(in project: CutProject, sourceID: String, tileID: String) throws -> MulticamRange {
    let regions = project.participants.sources.first { $0.sourceID == sourceID }?.appearances.filter { $0.id == tileID } ?? []
    guard let first = regions.map(\.range.from).min(), let last = regions.map(\.range.to).max() else {
        throw CLIError("unknown_tile", "No tile has the requested ID on the selected source.")
    }
    return .init(from: first, to: last)
}

private func tileBounds(_ request: ParticipantRequest) throws -> ParticipantBounds {
    if let value = request.fields["bounds"] as? String {
        let fields = value.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Double($0) }
        guard fields.count == 4, numbers.count == 4,
              numbers.allSatisfy(\.isFinite) else {
            throw CLIError("invalid_arguments", "Supply normalized bounds as X,Y,WIDTH,HEIGHT.")
        }
        return .init(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
    return try request.required("bounds", as: ParticipantBounds.self)
}


private func tileLayoutSlots(_ input: ParticipantRequest) throws -> [ParticipantSlot] {
    guard let values = input.fields["slot"] as? [String] else {
        return try input.value("slot", as: [ParticipantSlot].self) ?? []
    }
    return try values.map { value in
        let data = Data(value.utf8)
        if let issue = jsonInputIssue(data) {
            throw CLIError("invalid_json", "The layout slot " + issue + ".")
        }
        do { return try JSONDecoder().decode(ParticipantSlot.self, from: data) }
        catch { throw CLIError("invalid_json", "Invalid layout slot. \(error)") }
    }
}

private struct TileLayoutsReport: Encodable {
    let layouts: [TileLayoutListing]
}
