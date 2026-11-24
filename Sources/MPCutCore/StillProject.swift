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
        case version, transfer, primaries, matrix, range
        case viewingConditions = "viewing_conditions"
        case diffuseWhiteNits = "diffuse_white_nits"
        case renditionPolicyVersion = "rendition_policy_version"
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

private final class StillResourceBundleAnchor {}

public struct StillAsset: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    private var linkedFile: String?
    public var displayName: String
    public var fingerprint: String
    public var isGap: Bool { linkedFile == nil }

    /// A gap uses the placement's background for every pixel. Only linked images
    /// participate in path rebasing. The built-in transparent pixel stays local.
    public var file: String {
        get { linkedFile ?? Self.gapImage.path }
        set { if linkedFile != nil { linkedFile = newValue } }
    }

    static let gapImage: URL = {
        if let bin = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent(),
           ["Helpers", "MacOS"].contains(bin.lastPathComponent),
           bin.deletingLastPathComponent().lastPathComponent == "Contents",
           FileManager.default.fileExists(atPath: bin.deletingLastPathComponent().appendingPathComponent("Resources/Gap.png").path) {
            return bin.deletingLastPathComponent().appendingPathComponent("Resources/Gap.png")
        }
        // Bundle.module traps when its resource bundle is missing. Check both the
        // Xcode resource layout and SwiftPM's flat bundle before using the fallback.
        let roots = [Bundle.main.resourceURL, Bundle(for: StillResourceBundleAnchor.self).resourceURL,
                     Bundle.main.bundleURL]
        for root in roots.compactMap({ $0 }) {
            let bundle = root.appendingPathComponent("MPCut_MPCutCore.bundle", isDirectory: true)
            for path in ["Contents/Resources/Gap.png", "Gap.png"] {
                let resource = bundle.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: resource.path) { return resource }
            }
        }
        // An executable on its own writes the pixel to a file named as the still renderer expects.
        let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-gap-\(getuid())")
        let written = folder.appendingPathComponent("Gap.png")
        if (try? Data(contentsOf: written)) != pixel {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? pixel.write(to: written, options: .atomic)
        }
        return written
    }()

    public init(id: String, file: String, displayName: String, fingerprint: String) {
        self.id = id
        linkedFile = file
        self.displayName = displayName
        self.fingerprint = fingerprint
    }

    public init(gapID: String) {
        id = gapID
        linkedFile = nil
        displayName = "Color Gap"
        fingerprint = "43739c566e26fd7cb88f69d3864ea34740372f5ee99acac169e090beffbce5c6"
    }

    private enum CodingKeys: String, CodingKey { case id, kind, file, displayName = "display_name", fingerprint }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let v = try decoder.container(keyedBy: CodingKeys.self)
        let id = try v.decode(String.self, forKey: .id)
        if v.contains(.kind) {
            guard try v.decode(String.self, forKey: .kind) == "gap",
                  !v.contains(.file), !v.contains(.displayName), !v.contains(.fingerprint) else {
                throw stillError("Invalid color gap asset")
            }
            self.init(gapID: id)
        } else {
            try self.init(id: id, file: v.decode(String.self, forKey: .file),
                          displayName: v.decode(String.self, forKey: .displayName), fingerprint: v.decode(String.self, forKey: .fingerprint))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(id, forKey: .id)
        if let linkedFile {
            try v.encode(linkedFile, forKey: .file)
            try v.encode(displayName, forKey: .displayName)
            try v.encode(fingerprint, forKey: .fingerprint)
        } else {
            try v.encode("gap", forKey: .kind)
        }
    }
}

public struct StillInsert: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var assetID: String
    public var duration: RationalTime
    /// Duration of one generated sample.
    public var cadence: RationalTime
    public var framing: StillImageFraming
    /// Allows a fitted image to end at an exact audio sample boundary.
    public var usesExactDuration: Bool

    public init(id: String, assetID: String, duration: RationalTime, cadence: RationalTime,
                framing: StillImageFraming = .fit, usesExactDuration: Bool = false) {
        self.id = id
        self.assetID = assetID
        self.usesExactDuration = usesExactDuration
        self.duration = duration
        self.cadence = cadence
        self.framing = framing
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetID = "asset_id", duration, cadence, framing
        case usesExactDuration = "exact_duration"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let v = try decoder.container(keyedBy: CodingKeys.self)
        let exact = v.contains(.usesExactDuration)
        if exact, try !v.decode(Bool.self, forKey: .usesExactDuration) {
            throw stillError("An explicit exact_duration must be true")
        }
        try self.init(id: v.decode(String.self, forKey: .id), assetID: v.decode(String.self, forKey: .assetID),
                      duration: ProjectField.time(v, .duration), cadence: ProjectField.time(v, .cadence),
                      framing: v.decode(StillImageFraming.self, forKey: .framing), usesExactDuration: exact)
    }

    public func encode(to encoder: Encoder) throws {
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(id, forKey: .id)
        try v.encode(assetID, forKey: .assetID)
        try v.encode(duration.description, forKey: .duration)
        try v.encode(cadence.description, forKey: .cadence)
        try v.encode(framing, forKey: .framing)
        if usesExactDuration { try v.encode(true, forKey: .usesExactDuration) }
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

    private enum CodingKeys: String, CodingKey { case clipID = "clip_id", range }

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

    private enum CodingKeys: String, CodingKey { case id, assetID = "asset_id", framing, fragments, group }

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

private enum StillItemKey: String, CodingKey { case kind, still }

public enum StillSequenceItem: Codable, Hashable, Sendable {
    case source(CutSequenceClip)
    case still(StillInsert)

    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: StillItemKey.self)
        guard v.contains(.kind) else {
            self = .source(try CutSequenceClip(from: decoder))
            return
        }
        try ProjectField.rejectUnknown(StillItemKey.self, in: decoder)
        switch try v.decode(String.self, forKey: .kind) {
        case "still" where v.allKeys.count == 2: self = .still(try v.decode(StillInsert.self, forKey: .still))
        default: throw stillError("Invalid typed sequence item")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .source(let clip):
            try clip.encode(to: encoder)
        case .still(let insert):
            var v = encoder.container(keyedBy: StillItemKey.self)
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
    case group(MulticamRange, angle: String? = nil)
    case still(StillInsert)

    private enum GroupKey: String, CodingKey { case kind, from, to, angle = "angle_id" }

    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: StillItemKey.self)
        guard v.contains(.kind) else {
            self = .group(try MulticamRange(from: decoder))
            return
        }
        let kind = try v.decode(String.self, forKey: .kind)
        if kind == "group" {
            try ProjectField.rejectUnknown(GroupKey.self, in: decoder)
            let group = try decoder.container(keyedBy: GroupKey.self)
            self = .group(.init(from: try ProjectField.time(group, .from),
                                to: try ProjectField.time(group, .to)),
                          angle: try group.decode(String.self, forKey: .angle))
            return
        }
        try ProjectField.rejectUnknown(StillItemKey.self, in: decoder)
        switch kind {
        case "still" where v.allKeys.count == 2: self = .still(try v.decode(StillInsert.self, forKey: .still))
        default: throw stillError("Invalid typed assembly item")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .group(let range, let angle):
            if let angle {
                var v = encoder.container(keyedBy: GroupKey.self)
                try v.encode("group", forKey: .kind)
                try v.encode(range.from.description, forKey: .from)
                try v.encode(range.to.description, forKey: .to)
                try v.encode(angle, forKey: .angle)
            } else {
                try range.encode(to: encoder)
            }
        case .still(let insert):
            var v = encoder.container(keyedBy: StillItemKey.self)
            try v.encode("still", forKey: .kind)
            try v.encode(insert, forKey: .still)
        }
    }

    public var group: MulticamRange? {
        if case .group(let range, _) = self { return range }
        return nil
    }

    public var angleOverride: String? {
        if case .group(_, let angle) = self { return angle }
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
    public var transcripts: ProjectTranscripts
    public var sourceSelects: [NamedSourceSelect]
    public var participants: ParticipantProject
    // A selection consisting only of inserts still has its parent program's
    // silent sound lanes. This recording supplies their layout, not samples.
    package var stillAudioReference: CutSequenceClip?
    public var stillSoundtrack: CutSequenceClip?

    public init(items: [StillSequenceItem], stillAssets: [StillAsset] = [], stillReplacements: [StillReplacement] = [],
                programColorPolicy: StillProgramColorPolicy? = nil, stillFormat: StillTimelineFormat? = nil,
                transcripts: ProjectTranscripts = .init(), sourceSelects: [NamedSourceSelect] = [],
                participants: ParticipantProject = .init(), stillSoundtrack: CutSequenceClip? = nil) {
        self.stillSoundtrack = stillSoundtrack
        self.items = items
        self.stillAssets = stillAssets
        self.stillReplacements = stillReplacements
        self.programColorPolicy = programColorPolicy
        self.stillFormat = stillFormat
        self.transcripts = transcripts
        self.sourceSelects = sourceSelects
        self.participants = participants
    }

    var hasStillContent: Bool {
        !stillAssets.isEmpty || !stillReplacements.isEmpty || programColorPolicy != nil || stillFormat != nil
            || stillSoundtrack != nil || items.contains { $0.still != nil }
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
        guard validStillID(asset.id), assetIDs.insert(asset.id).inserted,
              asset.isGap || ProjectFile.validMediaPath(asset.file),
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
        if insert.usesExactDuration, group != nil || clipIDs?.isEmpty == false {
            throw stillError("An exact fitted duration requires a still-only sequence")
        }
        guard insert.duration > .zero, insert.cadence > .zero else {
            throw stillError("Still ‘\(insert.id)’ must have a positive duration and cadence")
        }
    }
    var intervals: [String: [(MulticamRange, String)]] = [:]
    let gapIDs = Set(assets.filter(\.isGap).map(\.id))
    for replacement in replacements {
        guard !gapIDs.contains(replacement.assetID) else { throw stillError("A color gap must be an insert") }
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
