import Foundation
import MPCutCore

struct StillOptions {
    enum Operation: String { case add, list, update, relink, remove }
    enum Clock: String { case sequence, group, assembly, source }
    enum Fit: String { case fit, fill }

    let operation: Operation
    let project: String
    let output: String?
    let inPlace: Bool
    let image: String?
    let asset: String?
    let placement: String?
    let replace: Bool
    let clock: Clock?
    let from: RationalTime?
    let to: RationalTime?
    let at: RationalTime?
    let fragmentIndex: Int?
    let duplicateID: String?
    let detachID: String?
    let duration: RationalTime?
    let cadence: RationalTime?
    let fit: Fit?
    let cropX: RationalTime?
    let cropY: RationalTime?
    let cropWidth: RationalTime?
    let cropHeight: RationalTime?
    let background: String?
    let color: StillTimelineFormat.Color?

    init(_ arguments: [String]) throws {
        var arguments = arguments.filter { $0 != "--json" }.makeIterator()
        guard let verb = arguments.next(), let operation = Operation(rawValue: verb) else {
            throw CLIError("invalid_arguments", "Use mpcut still add, list, update, relink or remove.")
        }
        self.operation = operation
        let destinations: Set<String> = ["--out-project", "--in-place"]
        let framing: Set<String> = ["--fit", "--crop-x", "--crop-y", "--crop-width", "--crop-height", "--background"]
        let length: Set<String> = ["--duration", "--rate", "--frames"]
        let allowed: Set<String>
        switch operation {
        case .add:
            allowed = destinations.union(framing).union(length).union(
                ["--image", "--asset", "--replace", "--insert", "--clock", "--from", "--to", "--at", "--color"])
        case .list:
            allowed = ["--placement"]
        case .update:
            allowed = destinations.union(framing).union(length).union(["--placement", "--asset", "--at", "--from", "--to", "--clock",
                                                                 "--fragment-index", "--duplicate-id", "--detach-id", "--color"])
        case .relink:
            allowed = destinations.union(["--asset", "--image"])
        case .remove:
            allowed = destinations.union(["--placement"])
        }
        var values: [String: String] = [:]
        var seen = Set<String>()
        while let flag = arguments.next() {
            guard flag == "--project" || allowed.contains(flag) else {
                throw CLIError("invalid_arguments", "Unknown still \(operation.rawValue) option '\(flag)'.")
            }
            guard seen.insert(flag).inserted else { throw CLIError("invalid_arguments", "Duplicate \(flag).") }
            if ["--in-place", "--insert", "--replace"].contains(flag) { continue }
            guard let value = arguments.next(), !value.isEmpty, !value.hasPrefix("--") else {
                throw CLIError("invalid_arguments", "Missing value for \(flag).")
            }
            values[flag] = value
        }
        guard let project = values["--project"] else {
            throw CLIError("invalid_arguments", "Specify --project FILE. Use --project - for standard input.")
        }
        self.project = project
        output = values["--out-project"]
        inPlace = seen.contains("--in-place")
        if operation != .list, inPlace == (output != nil) {
            throw CLIError("invalid_arguments", "Choose either --out-project FILE or --in-place.")
        }
        image = values["--image"]
        asset = values["--asset"]
        placement = values["--placement"]
        replace = seen.contains("--replace")
        let insert = seen.contains("--insert")
        if operation == .add {
            guard replace != insert, (asset == nil) != (image == nil) else {
                throw CLIError("invalid_arguments", "Choose one of --replace or --insert and one of --image or --asset.")
            }
        }
        if (operation == .update || operation == .remove) && placement == nil {
            throw CLIError("invalid_arguments", "Specify --placement ID.")
        }
        if operation == .relink && (asset == nil || image == nil) {
            throw CLIError("invalid_arguments", "Specify --asset ID and --image FILE.")
        }
        if let raw = values["--clock"] {
            guard let value = Clock(rawValue: raw) else {
                throw CLIError("invalid_arguments", "--clock accepts sequence, group, assembly or source.")
            }
            clock = value
        } else {
            clock = nil
        }
        if operation == .add, clock == nil {
            throw CLIError("invalid_arguments", "Specify the authoring clock with --clock.")
        }
        func time(_ key: String) throws -> RationalTime? {
            try values[key].map(RationalTime.init(parsing:))
        }
        from = try time("--from")
        to = try time("--to")
        at = try time("--at")
        if let raw = values["--fragment-index"] {
            guard let index = Int(raw), index >= 0 else {
                throw CLIError("invalid_arguments", "--fragment-index requires a zero-based integer.")
            }
            fragmentIndex = index
        } else {
            fragmentIndex = nil
        }
        duplicateID = values["--duplicate-id"]
        detachID = values["--detach-id"]
        let requestedDuration = try time("--duration")
        if let rate = try time("--rate") {
            guard rate > .zero else { throw CLIError("invalid_time", "--rate must be positive.") }
            cadence = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        } else {
            cadence = nil
        }
        if let raw = values["--frames"] {
            guard let frames = Int64(raw), frames > 0, let cadence, requestedDuration == nil else {
                throw CLIError("invalid_arguments", "--frames requires a positive integer and --rate. Use one of --frames or --duration.")
            }
            duration = try cadence.multiplied(by: RationalTime(numerator: frames))
        } else {
            duration = requestedDuration
        }
        if let duration, duration <= .zero {
            throw CLIError("invalid_time", "--duration must be positive.")
        }
        if replace {
            guard let from, let to, from >= .zero, to > from, at == nil, duration == nil, cadence == nil else {
                throw CLIError("invalid_arguments", "Use --replace with a nonempty --from/--to range.")
            }
        } else if insert {
            guard let at, at >= .zero, duration != nil, from == nil, to == nil else {
                throw CLIError("invalid_arguments", "Use --insert with --at and --duration or --frames and --rate.")
            }
        }
        if let raw = values["--fit"] {
            guard let value = Fit(rawValue: raw) else { throw CLIError("invalid_arguments", "--fit accepts fit or fill.") }
            fit = value
        } else {
            fit = nil
        }
        cropX = try time("--crop-x")
        cropY = try time("--crop-y")
        cropWidth = try time("--crop-width")
        cropHeight = try time("--crop-height")
        background = values["--background"]
        if let raw = values["--color"] {
            guard let interpretation = StillTimelineFormat.Color(rawValue: raw) else {
                throw CLIError("invalid_arguments", "--color accepts sdr, pq or hlg.")
            }
            color = interpretation
        } else {
            color = nil
        }
    }
}

func hasStillPlacements(_ project: CutProject) -> Bool {
    !project.stillInserts.isEmpty || !project.stillReplacements.isEmpty
}

struct StillInspection: Encodable {
    struct Asset: Encodable {
        let id: String
        let file: String
        let resolvedFile: String
        let displayName: String
        let fingerprint: String
        let offline: Bool

        init(_ asset: StillAsset, relativeTo location: URL) {
            let url = CutProject.mediaURL(asset.file, relativeTo: location)
            id = asset.id
            file = asset.file
            resolvedFile = url.path
            displayName = asset.displayName
            fingerprint = asset.fingerprint
            offline = (try? SourceIdentity(url)) == nil
        }
    }

    struct Placement: Encodable {
        let id: String
        let assetID: String
        let operation: String
        let clock: String
        let offline: Bool
        let framing: StillImageFraming
        let authoredFragments: [StillReplacementFragment]?
        let authoredRange: MulticamRange?
        let duration: RationalTime?
        let cadence: RationalTime?
        let visibleOccurrences: [StillTimelineSpan]
        let visibleDuration: RationalTime
    }

    let ok = true
    let project: String
    let kind: String
    let duration: RationalTime
    let assets: [Asset]
    let placements: [Placement]
    let colorPolicy: StillProgramColorPolicy?
    let timeline: CutProject
    var placementID: String?
    var assetID: String?

    init(_ timeline: CutProject, location: URL, input: String, placement: String? = nil) throws {
        self.timeline = timeline
        project = input
        let isMulticam: Bool
        if case .multicam = timeline { isMulticam = true } else { isMulticam = false }
        kind = isMulticam ? "multicam" : "sequence"
        let plan = try timeline.resolveStills()
        duration = plan.duration
        colorPolicy = timeline.programColorPolicy
        assets = timeline.stillAssets.map { Asset($0, relativeTo: location) }
        let offlineAssets = Set(assets.filter(\.offline).map(\.id))
        let byPlacement = Dictionary(grouping: plan.spans.filter { $0.placementID != nil }, by: \.placementID)
        var rows: [Placement] = []
        for insert in timeline.stillInserts where placement == nil || placement == insert.id {
            let visible = byPlacement[insert.id] ?? []
            rows.append(Placement(id: insert.id, assetID: insert.assetID, operation: "insert",
                                  clock: isMulticam ? "assembly" : "sequence", offline: offlineAssets.contains(insert.assetID),
                                  framing: insert.framing,
                                  authoredFragments: nil, authoredRange: visible.first?.output,
                                  duration: insert.duration, cadence: insert.cadence,
                                  visibleOccurrences: visible, visibleDuration: insert.duration))
        }
        for replacement in timeline.stillReplacements where placement == nil || placement == replacement.id {
            let visible = byPlacement[replacement.id] ?? []
            let visibleDuration = try visible.reduce(RationalTime.zero) {
                try $0.adding($1.output.to.subtracting($1.output.from))
            }
            let fragments: [StillReplacementFragment]?
            let range: MulticamRange?
            switch replacement.coverage {
            case .sequence(let coverage): fragments = coverage; range = nil
            case .group(let coverage): fragments = nil; range = coverage
            }
            rows.append(Placement(id: replacement.id, assetID: replacement.assetID, operation: "replace",
                                  clock: isMulticam ? "group" : "sequence", offline: offlineAssets.contains(replacement.assetID),
                                  framing: replacement.framing,
                                  authoredFragments: fragments, authoredRange: range, duration: nil, cadence: nil,
                                  visibleOccurrences: visible, visibleDuration: visibleDuration))
        }
        if let placement, rows.isEmpty {
            throw CutError(code: "invalid_target", message: "Unknown still placement ‘\(placement)’.")
        }
        placements = rows
    }
}

extension StillOptions {
    func checkedFraming(from original: StillImageFraming = .fit) throws -> StillImageFraming {
        var framing = original
        if let fit { framing.mode = fit == .fit ? .fit : .fill }
        if let background { framing.background = background }
        if cropX != nil || cropY != nil || cropWidth != nil || cropHeight != nil {
            let unit = RationalTime(numerator: 1)
            let x = cropX ?? framing.crop?.x ?? .zero
            let y = cropY ?? framing.crop?.y ?? .zero
            let width = try cropWidth ?? framing.crop?.width ?? unit.subtracting(x)
            let height = try cropHeight ?? framing.crop?.height ?? unit.subtracting(y)
            framing.crop = .init(x: x, y: y, width: width, height: height)
        }
        return framing
    }

    func sourceAsset(at location: URL, id: String = UUID().uuidString) throws -> StillAsset {
        guard let image else { throw CLIError("invalid_arguments", "Specify --image FILE.") }
        let url = try fileURL(image, label: "Image")
        let identity = try SourceIdentity(url)
        _ = try StillImage.inspect(url)
        let fingerprint = try StillImage.fingerprint(url)
        guard (try? SourceIdentity(url)) == identity else {
            throw CutError(code: "source_changed", message: "Image ‘\(url.path)’ changed while opening it.")
        }
        return StillAsset(id: id, file: CutProject.relativeMediaPath(url.path, to: location),
                          displayName: url.lastPathComponent, fingerprint: fingerprint)
    }
}

struct StillCLIExportReport: Encodable {
    private enum CodingKeys: String, CodingKey {
        case ok, dryRun, output, copiedDuration, encodedDuration, audioActions, audioStream, tier
    }

    let dryRun: Bool
    let output: String
    let report: StillExportReport
    let audioStream: Int?

    func encode(to encoder: Encoder) throws {
        try report.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(true, forKey: .ok)
        try fields.encode(dryRun, forKey: .dryRun)
        try fields.encode(output, forKey: .output)
        try fields.encodeIfPresent(audioStream, forKey: .audioStream)
        try fields.encode(report.selectedTier, forKey: .tier)
        try fields.encode(report.soundActions, forKey: .audioActions)
        if report.tracks == .audio {
            let copied = report.soundActions.allSatisfy { $0.audio == .copyOriginal }
            try fields.encode(copied ? report.duration : .zero, forKey: .copiedDuration)
            try fields.encode(copied ? .zero : report.duration, forKey: .encodedDuration)
        } else {
            try fields.encode(report.copiedVideoDuration, forKey: .copiedDuration)
            try fields.encode(report.encodedVideoDuration, forKey: .encodedDuration)
        }
    }
}

extension StillOptions {
    struct Edit {
        let project: CutProject
        let placementID: String?
        let assetID: String?
        let action: String
    }

    func edit(_ project: CutProject, relativeTo location: URL,
              cancelled: @escaping @Sendable () -> Bool) throws -> Edit {
        let timing = StillAuthoringTiming(project: project, location: location,
                                         engine: CutEngine(cancelled: cancelled))
        switch operation {
        case .list:
            throw CLIError("invalid_arguments", "Listing stills does not edit the project.")
        case .add:
            return try add(to: project, timing: timing)
        case .update:
            guard let placement else { throw CLIError("invalid_arguments", "Specify --placement ID.") }
            let insert = project.stillInserts.first { $0.id == placement }
            let replacement = project.stillReplacements.first { $0.id == placement }
            guard let original = insert?.framing ?? replacement?.framing else {
                throw CutError(code: "invalid_target", message: "Unknown still placement ‘\(placement)’.")
            }
            let framing = try checkedFraming(from: original)
            var updated = project
            if duplicateID == nil && detachID == nil {
                updated = try project.updatingStill(id: placement, assetID: asset, framing: framing)
            }
            var resultID = placement
            var action = "Update Still"
            if let insert {
                let expected: Clock = project.sequenceItems == nil ? .assembly : .sequence
                guard from == nil, to == nil, fragmentIndex == nil, duplicateID == nil, detachID == nil,
                      clock == nil || clock == expected else {
                    throw CLIError("invalid_arguments", "Insert updates accept --at in \(expected.rawValue) time and duration or cadence.")
                }
                if let at {
                    guard at >= .zero else { throw CLIError("invalid_time", "--at must be nonnegative.") }
                    try timing.validateInsertBoundary(at, moving: placement)
                    updated = try updated.movingStill(id: placement, to: at)
                }
                if duration != nil || cadence != nil {
                    updated = try updated.resizingStill(id: placement, duration: duration ?? insert.duration,
                                                        cadence: cadence ?? insert.cadence)
                }
            } else {
                guard duration == nil, cadence == nil else {
                    throw CLIError("invalid_arguments", "Replacement updates use --from and --to to set bounds.")
                }
                if at != nil || from != nil || to != nil || fragmentIndex != nil || clock != nil
                    || duplicateID != nil || detachID != nil {
                    updated = try updated.editingStillReplacement(id: placement, fragmentIndex: fragmentIndex,
                                                                 from: from, to: to, at: at, clock: clock?.rawValue,
                                                                 duplicateID: duplicateID, detachID: detachID)
                    resultID = detachID ?? duplicateID ?? placement
                    if let result = updated.stillReplacements.first(where: { $0.id == resultID }) {
                        if detachID == nil {
                            switch result.coverage {
                            case .sequence(let fragments):
                                let prior: Set<StillReplacementFragment>
                                if case .sequence(let existing) = replacement?.coverage { prior = Set(existing) }
                                else { prior = [] }
                                try timing.validateFragments(fragments.filter { !prior.contains($0) })
                            case .group(let range): try timing.validateGroup(range)
                            }
                        }
                        if resultID != placement {
                            updated = try updated.updatingStill(id: resultID, assetID: asset, framing: framing)
                        }
                    }
                    if detachID != nil { action = "Detach Still Fragment" }
                    if duplicateID != nil { action = "Duplicate Still" }
                }
            }
            if let color { updated = try updated.settingStillColorPolicy(color.policy) }
            return Edit(project: updated, placementID: resultID, assetID: asset ?? insert?.assetID ?? replacement?.assetID, action: action)
        case .relink:
            guard let asset else { throw CLIError("invalid_arguments", "Specify --asset ID.") }
            let replacement = try sourceAsset(at: location, id: asset)
            let updated = try project.relinkingStillAsset(asset, file: replacement.file, fingerprint: replacement.fingerprint)
            return Edit(project: updated, placementID: nil, assetID: asset, action: "Relink Still")
        case .remove:
            guard let placement else { throw CLIError("invalid_arguments", "Specify --placement ID.") }
            let updated = try project.removingStill(id: placement)
            return Edit(project: updated, placementID: placement, assetID: nil, action: "Remove Still")
        }
    }

    private func add(to project: CutProject, timing: StillAuthoringTiming) throws -> Edit {
        let expected: Clock
        switch project {
        case .multicam: expected = replace ? .group : .assembly
        case .sequence, .stillSequence: expected = .sequence
        }
        guard clock == expected else {
            throw CLIError("invalid_arguments", "Use --clock \(expected.rawValue) for this operation.")
        }
        let placement = UUID().uuidString
        let framing = try checkedFraming()
        var updated = project
        let assetID: String
        if let asset {
            guard project.stillAssets.contains(where: { $0.id == asset }) else {
                throw CutError(code: "invalid_target", message: "Unknown still asset ‘\(asset)’.")
            }
            assetID = asset
        } else {
            let source = try sourceAsset(at: timing.location)
            if let existing = project.stillAssets.first(where: {
                $0.fingerprint == source.fingerprint &&
                    CutProject.mediaURL($0.file, relativeTo: timing.location).resolvingSymlinksInPath() ==
                    CutProject.mediaURL(source.file, relativeTo: timing.location).resolvingSymlinksInPath()
            }) {
                assetID = existing.id
            } else {
                assetID = source.id
                updated = try updated.addingStillAsset(source)
            }
        }
        if replace, let from, let to {
            if case .multicam = project {
                let range = MulticamRange(from: from, to: to)
                let replacement = StillReplacement(id: placement, assetID: assetID, framing: framing, coverage: .group(range))
                updated = try updated.addingStillReplacement(replacement)
                try timing.validateGroup(range)
            } else {
                updated = try updated.replacingPicture(id: placement, assetID: assetID, framing: framing,
                                                       from: from, to: to)
                if let replacement = updated.stillReplacements.first(where: { $0.id == placement }),
                   case .sequence(let fragments) = replacement.coverage {
                    try timing.validateFragments(fragments)
                }
            }
        } else if let at, let duration {
            let sampleDuration = try cadence ?? project.stillFormat?.cadence ?? timing.inferredCadence(at)
            let insert = StillInsert(id: placement, assetID: assetID, duration: duration, cadence: sampleDuration, framing: framing)
            updated = try updated.insertingStill(insert, at: at)
            try timing.validateInsertBoundary(at)
        }
        if let color {
            updated = try updated.settingStillColorPolicy(color.policy)
        } else if updated.programColorPolicy == nil, let inferred = try timing.colorPolicy(in: updated) {
            updated = try updated.settingStillColorPolicy(inferred)
        }
        return Edit(project: updated, placementID: placement, assetID: assetID,
                    action: replace ? "Replace Picture" : "Insert Still")
    }
}
