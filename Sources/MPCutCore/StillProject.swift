import Foundation

public struct StillImageFraming: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable { case fit, fill }

    public struct Crop: Codable, Hashable, Sendable {
        public var x: RationalTime
        public var y: RationalTime
        public var width: RationalTime
        public var height: RationalTime

        public init(x: RationalTime, y: RationalTime, width: RationalTime, height: RationalTime) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        private enum CodingKeys: String, CodingKey { case x, y, width, height }

        public init(from decoder: Decoder) throws {
            try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(x: ProjectField.time(values, .x), y: ProjectField.time(values, .y),
                          width: ProjectField.time(values, .width), height: ProjectField.time(values, .height))
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(x.description, forKey: .x)
            try values.encode(y.description, forKey: .y)
            try values.encode(width.description, forKey: .width)
            try values.encode(height.description, forKey: .height)
        }
    }

    public var mode: Mode
    public var crop: Crop?
    public var background: String

    public static let fit = Self(mode: .fit)
    public static let fill = Self(mode: .fill)

    public init(mode: Mode, crop: Crop? = nil, background: String = "#000000") {
        self.mode = mode
        self.crop = crop
        self.background = background
    }

    private enum CodingKeys: String, CodingKey { case mode, crop, background }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(mode: values.decode(Mode.self, forKey: .mode),
                      crop: values.decodeIfPresent(Crop.self, forKey: .crop),
                      background: values.decode(String.self, forKey: .background))
    }

    public func validate() throws {
        guard background.utf8.count == 7, background.first == "#", background.utf8.dropFirst().allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw stillError("Still background must be an opaque #RRGGBB color") }
        if let crop {
            let one = RationalTime(numerator: 1)
            guard crop.x >= .zero, crop.y >= .zero, crop.width > .zero, crop.height > .zero,
                  try crop.x.adding(crop.width) <= one, try crop.y.adding(crop.height) <= one else {
                throw stillError("Still crop must be a positive rectangle within the image")
            }
        }
    }
}

public struct StillProgramColorPolicy: Codable, Hashable, Sendable {
    public var version: Int
    public var transfer: String
    public var primaries: String
    public var matrix: String
    public var range: String
    public var viewingConditions: String
    public var diffuseWhiteNits: Int
    public var renditionPolicyVersion: Int

    public init(version: Int = 1, transfer: String, primaries: String, matrix: String, range: String,
                viewingConditions: String, diffuseWhiteNits: Int, renditionPolicyVersion: Int = 1) {
        self.version = version
        self.transfer = transfer
        self.primaries = primaries
        self.matrix = matrix
        self.range = range
        self.viewingConditions = viewingConditions
        self.diffuseWhiteNits = diffuseWhiteNits
        self.renditionPolicyVersion = renditionPolicyVersion
    }

    private enum CodingKeys: String, CodingKey {
        case version, transfer, primaries, matrix, range, viewingConditions, diffuseWhiteNits, renditionPolicyVersion
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: v.decode(Int.self, forKey: .version), transfer: v.decode(String.self, forKey: .transfer),
                      primaries: v.decode(String.self, forKey: .primaries), matrix: v.decode(String.self, forKey: .matrix),
                      range: v.decode(String.self, forKey: .range), viewingConditions: v.decode(String.self, forKey: .viewingConditions),
                      diffuseWhiteNits: v.decode(Int.self, forKey: .diffuseWhiteNits),
                      renditionPolicyVersion: v.decode(Int.self, forKey: .renditionPolicyVersion))
    }

    func validate() throws {
        guard version == 1, renditionPolicyVersion == 1, diffuseWhiteNits > 0,
              [transfer, primaries, matrix, range, viewingConditions].allSatisfy(validStillID) else {
            throw stillError("Invalid program color policy")
        }
    }
}

public struct StillAsset: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var file: String
    public var displayName: String
    public var fingerprint: String

    public init(id: String, file: String, displayName: String, fingerprint: String) {
        self.id = id
        self.file = file
        self.displayName = displayName
        self.fingerprint = fingerprint
    }

    private enum CodingKeys: String, CodingKey { case id, file, displayName, fingerprint }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: v.decode(String.self, forKey: .id), file: v.decode(String.self, forKey: .file),
                      displayName: v.decode(String.self, forKey: .displayName), fingerprint: v.decode(String.self, forKey: .fingerprint))
    }
}

public struct StillInsert: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var assetID: String
    public var duration: RationalTime
    /// Duration of one generated sample.
    public var cadence: RationalTime
    public var framing: StillImageFraming

    public init(id: String, assetID: String, duration: RationalTime, cadence: RationalTime,
                framing: StillImageFraming = .fit) {
        self.id = id
        self.assetID = assetID
        self.duration = duration
        self.cadence = cadence
        self.framing = framing
    }

    private enum CodingKeys: String, CodingKey { case id, assetID, duration, cadence, framing }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: v.decode(String.self, forKey: .id), assetID: v.decode(String.self, forKey: .assetID),
                      duration: ProjectField.time(v, .duration), cadence: ProjectField.time(v, .cadence),
                      framing: v.decode(StillImageFraming.self, forKey: .framing))
    }

    public func encode(to encoder: Encoder) throws {
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(id, forKey: .id)
        try v.encode(assetID, forKey: .assetID)
        try v.encode(duration.description, forKey: .duration)
        try v.encode(cadence.description, forKey: .cadence)
        try v.encode(framing, forKey: .framing)
    }

    public func frameCount() throws -> Int64 {
        guard duration > .zero, cadence > .zero else {
            throw stillError("Still ‘\(id)’ must have a positive duration and cadence")
        }
        let count = try duration.multiplied(by: .init(numerator: cadence.denominator, denominator: cadence.numerator))
        guard count.denominator == 1 else {
            throw stillError("Still ‘\(id)’ duration must be an integral number of samples at its cadence")
        }
        return count.numerator
    }
}

public struct StillReplacementFragment: Codable, Hashable, Sendable {
    public var clipID: String
    public var range: MulticamRange

    public init(clipID: String, range: MulticamRange) {
        self.clipID = clipID
        self.range = range
    }

    private enum CodingKeys: String, CodingKey { case clipID, range }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(clipID: v.decode(String.self, forKey: .clipID), range: v.decode(MulticamRange.self, forKey: .range))
    }
}

public enum StillReplacementCoverage: Hashable, Sendable {
    case sequence([StillReplacementFragment])
    case group(MulticamRange)
}

public struct StillReplacement: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var assetID: String
    public var framing: StillImageFraming
    public var coverage: StillReplacementCoverage

    public init(id: String, assetID: String, framing: StillImageFraming = .fit, coverage: StillReplacementCoverage) {
        self.id = id
        self.assetID = assetID
        self.framing = framing
        self.coverage = coverage
    }

    private enum CodingKeys: String, CodingKey { case id, assetID, framing, fragments, group }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let v = try decoder.container(keyedBy: CodingKeys.self)
        guard v.contains(.fragments) != v.contains(.group) else {
            throw stillError("A still replacement must specify exactly one coordinate domain")
        }
        let coverage: StillReplacementCoverage = try v.contains(.fragments)
            ? .sequence(v.decode([StillReplacementFragment].self, forKey: .fragments))
            : .group(v.decode(MulticamRange.self, forKey: .group))
        try self.init(id: v.decode(String.self, forKey: .id), assetID: v.decode(String.self, forKey: .assetID),
                      framing: v.decode(StillImageFraming.self, forKey: .framing), coverage: coverage)
    }

    public func encode(to encoder: Encoder) throws {
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(id, forKey: .id)
        try v.encode(assetID, forKey: .assetID)
        try v.encode(framing, forKey: .framing)
        switch coverage {
        case .sequence(let fragments): try v.encode(fragments, forKey: .fragments)
        case .group(let range): try v.encode(range, forKey: .group)
        }
    }
}

private enum StillItemKey: String, CodingKey { case kind, source, group, still }

public enum StillSequenceItem: Codable, Hashable, Sendable {
    case source(CutSequenceClip)
    case still(StillInsert)

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(StillItemKey.self, in: decoder)
        let v = try decoder.container(keyedBy: StillItemKey.self)
        switch try v.decode(String.self, forKey: .kind) {
        case "source" where v.allKeys.count == 2: self = .source(try v.decode(CutSequenceClip.self, forKey: .source))
        case "still" where v.allKeys.count == 2: self = .still(try v.decode(StillInsert.self, forKey: .still))
        default: throw stillError("Invalid typed sequence item")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var v = encoder.container(keyedBy: StillItemKey.self)
        switch self {
        case .source(let clip):
            try v.encode("source", forKey: .kind)
            try v.encode(clip, forKey: .source)
        case .still(let insert):
            try v.encode("still", forKey: .kind)
            try v.encode(insert, forKey: .still)
        }
    }

    public var source: CutSequenceClip? {
        if case .source(let clip) = self { return clip }
        return nil
    }

    public var still: StillInsert? {
        if case .still(let insert) = self { return insert }
        return nil
    }
}

public enum StillAssemblyItem: Codable, Hashable, Sendable {
    case group(MulticamRange)
    case still(StillInsert)

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(StillItemKey.self, in: decoder)
        let v = try decoder.container(keyedBy: StillItemKey.self)
        switch try v.decode(String.self, forKey: .kind) {
        case "group" where v.allKeys.count == 2: self = .group(try v.decode(MulticamRange.self, forKey: .group))
        case "still" where v.allKeys.count == 2: self = .still(try v.decode(StillInsert.self, forKey: .still))
        default: throw stillError("Invalid typed assembly item")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var v = encoder.container(keyedBy: StillItemKey.self)
        switch self {
        case .group(let range):
            try v.encode("group", forKey: .kind)
            try v.encode(range, forKey: .group)
        case .still(let insert):
            try v.encode("still", forKey: .kind)
            try v.encode(insert, forKey: .still)
        }
    }

    public var group: MulticamRange? {
        if case .group(let range) = self { return range }
        return nil
    }

    public var still: StillInsert? {
        if case .still(let insert) = self { return insert }
        return nil
    }
}

public struct StillSequenceProject: Equatable, Sendable {
    public var items: [StillSequenceItem]
    public var stillAssets: [StillAsset]
    public var stillReplacements: [StillReplacement]
    public var programColorPolicy: StillProgramColorPolicy?
    public var stillFormat: StillTimelineFormat?
    // A selection consisting only of inserts still has its parent program's
    // silent sound lanes. This recording supplies their layout, not samples.
    package var stillAudioReference: CutSequenceClip?

    public init(items: [StillSequenceItem], stillAssets: [StillAsset] = [], stillReplacements: [StillReplacement] = [],
                programColorPolicy: StillProgramColorPolicy? = nil, stillFormat: StillTimelineFormat? = nil) {
        self.items = items
        self.stillAssets = stillAssets
        self.stillReplacements = stillReplacements
        self.programColorPolicy = programColorPolicy
        self.stillFormat = stillFormat
    }

    var requiresV2: Bool {
        !stillAssets.isEmpty || !stillReplacements.isEmpty || programColorPolicy != nil || stillFormat != nil
            || items.contains { $0.still != nil }
    }
}

func stillError(_ message: String, code: String = "invalid_still_project", placementIDs: [String]? = nil) -> CutError {
    CutError(code: code, message: message, placementIDs: placementIDs)
}

func validStillID(_ id: String) -> Bool {
    !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !id.contains("\0")
}

func validateStillCollections(assets: [StillAsset], inserts: [StillInsert], replacements: [StillReplacement],
                              color: StillProgramColorPolicy?, clipIDs: Set<String>? = nil,
                              group: MulticamRange? = nil) throws {
    var assetIDs = Set<String>()
    for asset in assets {
        guard validStillID(asset.id), assetIDs.insert(asset.id).inserted, ProjectFile.validMediaPath(asset.file),
              validStillID(asset.displayName), validStillID(asset.fingerprint) else {
            throw stillError("Invalid or repeated still asset ‘\(asset.id)’")
        }
    }
    try color?.validate()
    var placementIDs = Set<String>()
    func validatePlacement(id: String, assetID: String, framing: StillImageFraming) throws {
        guard validStillID(id), placementIDs.insert(id).inserted else {
            throw stillError("Invalid or repeated still placement ID ‘\(id)’")
        }
        guard assetIDs.contains(assetID) else {
            throw stillError("Still placement ‘\(id)’ refers to unknown asset ‘\(assetID)’")
        }
        try framing.validate()
    }
    for insert in inserts {
        try validatePlacement(id: insert.id, assetID: insert.assetID, framing: insert.framing)
        guard insert.duration > .zero, insert.cadence > .zero else {
            throw stillError("Still ‘\(insert.id)’ must have a positive duration and cadence")
        }
    }
    var intervals: [String: [(MulticamRange, String)]] = [:]
    for replacement in replacements {
        try validatePlacement(id: replacement.id, assetID: replacement.assetID, framing: replacement.framing)
        switch replacement.coverage {
        case .sequence(let fragments):
            guard let clipIDs, !fragments.isEmpty else { throw stillError("Sequence still needs source fragments") }
            for fragment in fragments {
                guard clipIDs.contains(fragment.clipID), fragment.range.from >= .zero, fragment.range.to > fragment.range.from else {
                    throw stillError("Invalid source fragment for still ‘\(replacement.id)’ on clip ‘\(fragment.clipID)’")
                }
                intervals[fragment.clipID, default: []].append((fragment.range, replacement.id))
            }
        case .group(let authored):
            guard let group, authored.from >= group.from, authored.to <= group.to, authored.to > authored.from else {
                throw stillError("Group still ‘\(replacement.id)’ lies outside the group")
            }
            intervals["", default: []].append((authored, replacement.id))
        }
    }
    for key in intervals.keys.sorted() {
        let ordered = intervals[key, default: []].sorted { $0.0.from < $1.0.from }
        for (previous, next) in zip(ordered, ordered.dropFirst()) where previous.0.to > next.0.from {
            throw stillError("Still placements ‘\(previous.1)’ and ‘\(next.1)’ overlap",
                             code: "still_replacement_overlap", placementIDs: [previous.1, next.1])
        }
    }
}
