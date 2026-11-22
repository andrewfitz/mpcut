import Foundation

public struct MulticamRange: Codable, Hashable, Sendable {
    public var from: RationalTime
    public var to: RationalTime

    public init(from: RationalTime, to: RationalTime) {
        self.from = from
        self.to = to
    }

    public func contains(_ time: RationalTime) -> Bool {
        from <= time && time < to
    }

    private enum CodingKeys: String, CodingKey { case from, to }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(from: try ProjectField.time(values, .from), to: try ProjectField.time(values, .to))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(from.description, forKey: .from)
        try values.encode(to.description, forKey: .to)
    }
}

public struct MulticamSource: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var file: String
    public var offset: RationalTime
    public var name: String?
    public var audioStream: Int?

    public init(id: String, file: String, offset: RationalTime = .zero,
                name: String? = nil, audioStream: Int? = nil) {
        self.id = id
        self.file = file
        self.offset = offset
        self.name = name
        self.audioStream = audioStream
    }

    private enum CodingKeys: String, CodingKey { case id, file, offset, name, audioStream }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  file: try values.decode(String.self, forKey: .file),
                  offset: try ProjectField.time(values, .offset, default: "0"),
                  name: try values.decodeIfPresent(String.self, forKey: .name),
                  audioStream: try values.decodeIfPresent(Int.self, forKey: .audioStream))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(file, forKey: .file)
        try values.encode(offset.description, forKey: .offset)
        try values.encodeIfPresent(name, forKey: .name)
        try values.encodeIfPresent(audioStream, forKey: .audioStream)
    }
}

public struct MulticamAudioSelection: Codable, Hashable, Sendable {
    public var source: String
    public var stream: Int

    public init(source: String, stream: Int) {
        self.source = source
        self.stream = stream
    }

    private enum CodingKeys: String, CodingKey { case source, stream }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try values.decode(String.self, forKey: .source),
                  stream: try values.decode(Int.self, forKey: .stream))
    }
}

public enum MulticamAudioPolicy: Codable, Hashable, Sendable {
    case fixed(MulticamAudioSelection)
    case follow
    case none

    private enum CodingKeys: String, CodingKey { case mode, source, stream }
    private enum Mode: String, Codable { case fixed, follow, none }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try values.decode(Mode.self, forKey: .mode)
        if mode == .fixed {
            self = .fixed(.init(source: try values.decode(String.self, forKey: .source),
                                stream: try values.decode(Int.self, forKey: .stream)))
        } else {
            guard !values.contains(.source), !values.contains(.stream) else {
                throw CutError(code: "invalid_multicam_project",
                               message: "Only fixed audio accepts a project-wide source and stream")
            }
            self = mode == .follow ? .follow : .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fixed(let selection):
            try values.encode(Mode.fixed, forKey: .mode)
            try values.encode(selection.source, forKey: .source)
            try values.encode(selection.stream, forKey: .stream)
        case .follow: try values.encode(Mode.follow, forKey: .mode)
        case .none: try values.encode(Mode.none, forKey: .mode)
        }
    }
}

public struct MulticamSwitch: Codable, Hashable, Sendable {
    public var at: RationalTime
    public var angle: String
    public var audio: MulticamAudioSelection?

    public init(at: RationalTime, angle: String, audio: MulticamAudioSelection? = nil) {
        self.at = at
        self.angle = angle
        self.audio = audio
    }

    private enum CodingKeys: String, CodingKey { case at, angle, audio }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(at: try ProjectField.time(values, .at),
                  angle: try values.decode(String.self, forKey: .angle),
                  audio: try values.decodeIfPresent(MulticamAudioSelection.self, forKey: .audio))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(at.description, forKey: .at)
        try values.encode(angle, forKey: .angle)
        try values.encodeIfPresent(audio, forKey: .audio)
    }
}

public struct MulticamProject: Codable, Equatable, Sendable {
    public static let schemaVersion = CutProject.schemaVersion
    public var referenceAngle: String
    public var range: MulticamRange
    public var angles: [MulticamSource]
    public var audioSources: [MulticamSource]
    public var audio: MulticamAudioPolicy
    public var switches: [MulticamSwitch]
    public var assemblyItems: [StillAssemblyItem]?
    public var stillAssets: [StillAsset]
    public var stillReplacements: [StillReplacement]
    public var programColorPolicy: StillProgramColorPolicy?

    /// Group ranges for clients that only work in group coordinates.
    public var assembly: [MulticamRange]? {
        get { assemblyItems?.compactMap(\.group) }
        set { assemblyItems = newValue?.map(StillAssemblyItem.group) }
    }

    var requiresV2: Bool {
        !stillAssets.isEmpty || !stillReplacements.isEmpty || programColorPolicy != nil
            || (assemblyItems?.contains { $0.still != nil } ?? false)
    }

    public var sources: [MulticamSource] { angles + audioSources }

    public init(referenceAngle: String, range: MulticamRange, angles: [MulticamSource],
                audioSources: [MulticamSource] = [], audio: MulticamAudioPolicy,
                switches: [MulticamSwitch], assembly: [MulticamRange]? = nil,
                assemblyItems: [StillAssemblyItem]? = nil, stillAssets: [StillAsset] = [],
                stillReplacements: [StillReplacement] = [], programColorPolicy: StillProgramColorPolicy? = nil) {
        self.referenceAngle = referenceAngle
        self.range = range
        self.angles = angles
        self.audioSources = audioSources
        self.audio = audio
        self.switches = switches
        self.assemblyItems = assemblyItems ?? assembly?.map(StillAssemblyItem.group)
        self.stillAssets = stillAssets
        self.stillReplacements = stillReplacements
        self.programColorPolicy = programColorPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case format, schemaVersion, kind, referenceAngle, range, angles, audioSources, audio, switches, assembly, history
        case stillAssets, stillReplacements, programColorPolicy
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .format) == CutProject.format else {
            throw Self.invalid("Expected an MPCut project document")
        }
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion || version == CutProject.stillSchemaVersion else {
            throw CutError(code: "unsupported_multicam_version",
                           message: "Multicam schema version \(version) is unsupported")
        }
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let v2 = version == CutProject.stillSchemaVersion
        let stillFields: [CodingKeys] = [.stillAssets, .stillReplacements, .programColorPolicy]
        guard v2 || !stillFields.contains(where: values.contains) else {
            throw Self.invalid("Still fields require schema v2")
        }
        if v2 {
            for key in stillFields + [.assembly] where values.contains(key) {
                guard try !values.decodeNil(forKey: key) else {
                    throw Self.invalid("Null value in multicam field ‘\(key.stringValue)’")
                }
            }
        }
        guard try values.decode(String.self, forKey: .kind) == "multicam" else {
            throw Self.invalid("Expected a multicam project")
        }
        self.init(referenceAngle: try values.decode(String.self, forKey: .referenceAngle),
                  range: try values.decode(MulticamRange.self, forKey: .range),
                  angles: try values.decode([MulticamSource].self, forKey: .angles),
                  audioSources: try values.decodeIfPresent([MulticamSource].self, forKey: .audioSources) ?? [],
                  audio: try values.decode(MulticamAudioPolicy.self, forKey: .audio),
                  switches: try values.decode([MulticamSwitch].self, forKey: .switches),
                  assembly: v2 ? nil : try values.decodeIfPresent([MulticamRange].self, forKey: .assembly),
                  assemblyItems: v2 ? try values.decodeIfPresent([StillAssemblyItem].self, forKey: .assembly) : nil,
                  stillAssets: try values.decodeIfPresent([StillAsset].self, forKey: .stillAssets) ?? [],
                  stillReplacements: try values.decodeIfPresent([StillReplacement].self, forKey: .stillReplacements) ?? [],
                  programColorPolicy: try values.decodeIfPresent(StillProgramColorPolicy.self, forKey: .programColorPolicy))
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try encode(to: encoder, forceV2: false)
    }

    func encode(to encoder: Encoder, forceV2: Bool) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        let v2 = requiresV2 || forceV2
        try values.encode(CutProject.format, forKey: .format)
        try values.encode(v2 ? CutProject.stillSchemaVersion : Self.schemaVersion, forKey: .schemaVersion)
        try values.encode("multicam", forKey: .kind)
        try values.encode(referenceAngle, forKey: .referenceAngle)
        try values.encode(range, forKey: .range)
        try values.encode(angles, forKey: .angles)
        if !audioSources.isEmpty { try values.encode(audioSources, forKey: .audioSources) }
        try values.encode(audio, forKey: .audio)
        try values.encode(switches, forKey: .switches)
        if v2 {
            try values.encodeIfPresent(assemblyItems, forKey: .assembly)
            if !stillAssets.isEmpty { try values.encode(stillAssets, forKey: .stillAssets) }
            if !stillReplacements.isEmpty { try values.encode(stillReplacements, forKey: .stillReplacements) }
            try values.encodeIfPresent(programColorPolicy, forKey: .programColorPolicy)
        } else {
            try values.encodeIfPresent(assembly, forKey: .assembly)
        }
    }

    /// Media stream indices are 32-bit.
    private static let streamIndices = 0...Int(Int32.max)

    /// The largest project document `load` reads, matching the CLI's request limit.
    public static let maximumFileSize = 64 * 1024 * 1024

    public static func load(from url: URL) throws -> Self {
        try ProjectFile.read(Self.self, from: url, multicam: true)
    }

    public static func decode(_ data: Data) throws -> Self {
        try ProjectFile.decode(Self.self, data: data, multicam: true)
    }

    public func save(to url: URL) throws {
        try ProjectFile.write(self, to: url, sources: CutProject.multicam(self).mediaPaths, multicam: true)
    }

    public func sourceURL(for source: MulticamSource, relativeTo projectURL: URL) -> URL {
        sourceURL(for: source, in: ProjectFile.directory(of: projectURL))
    }

    func sourceURL(for source: MulticamSource, in directory: URL) -> URL {
        ProjectFile.sourceURL(file: source.file, in: directory)
    }

    public func validate() throws {
        guard range.from == .zero, range.to > range.from else {
            throw Self.invalid("The group must start at zero and have a positive duration")
        }
        var sourceIDs = Set<String>()
        for source in sources {
            guard !source.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !source.file.isEmpty, !source.file.contains("\0") else {
                throw Self.invalid("Each source needs a nonempty ID and file path")
            }
            guard ProjectFile.validMediaPath(source.file) else {
                throw Self.invalid("Source ‘\(source.id)’ must name a recording file")
            }
            guard sourceIDs.insert(source.id).inserted else {
                throw Self.invalid("Repeated source ID ‘\(source.id)’")
            }
            if let stream = source.audioStream, !Self.streamIndices.contains(stream) {
                throw Self.invalid("Source ‘\(source.id)’ has an audio stream index outside 0 to \(Int32.max)")
            }
        }
        let angleIDs = Set(angles.map(\.id))
        guard angleIDs.contains(referenceAngle) else {
            throw Self.invalid("Unknown reference angle ‘\(referenceAngle)’")
        }
        func validateAudio(_ selection: MulticamAudioSelection) throws {
            guard sourceIDs.contains(selection.source), Self.streamIndices.contains(selection.stream) else {
                throw Self.invalid("Invalid audio selection ‘\(selection.source)’ stream \(selection.stream)")
            }
        }
        if case .fixed(let master) = audio { try validateAudio(master) }
        guard switches.first?.at == range.from else {
            throw Self.invalid("A switch is required at the start of the group")
        }
        var previous: RationalTime?
        for marker in switches {
            guard angleIDs.contains(marker.angle) else {
                throw Self.invalid("Unknown angle ‘\(marker.angle)’ at \(marker.at)")
            }
            guard range.contains(marker.at), previous.map({ $0 < marker.at }) ?? true else {
                throw Self.invalid("Switch time \(marker.at) is out of range or not strictly increasing")
            }
            previous = marker.at
            if let override = marker.audio { try validateAudio(override) }
        }
        if let assemblyItems {
            guard !assemblyItems.isEmpty else { throw Self.invalid("Assembly must contain at least one item") }
            let ranges = assemblyItems.compactMap(\.group)
            if !ranges.isEmpty { try validateRanges(ranges) }
        }
        try validateStillCollections(assets: stillAssets, inserts: assemblyItems?.compactMap(\.still) ?? [],
                                     replacements: stillReplacements, color: programColorPolicy, group: range)
        if requiresV2 { try CutProject.multicam(self).validateStillTimelineDuration() }
    }

    private func validateRanges(_ ranges: [MulticamRange]) throws {
        guard !ranges.isEmpty else { throw Self.invalid("Assembly must contain at least one range") }
        var duration = RationalTime.zero
        for (index, requested) in ranges.enumerated() {
            guard range.contains(requested.from), requested.from < requested.to,
                  requested.to <= range.to else {
                throw Self.invalid("Assembly range \(index + 1) (\(requested.from)–\(requested.to)) lies outside the group or is empty")
            }
            duration = try duration.adding(requested.to.subtracting(requested.from))
        }
    }

    private static func invalid(_ message: String) -> CutError {
        CutError(code: "invalid_multicam_project", message: message)
    }

    public func selection(at time: RationalTime) -> MulticamSwitch? {
        guard range.contains(time), let index = switchIndex(at: time) else { return nil }
        return switches[index]
    }

    private func switchIndex(at time: RationalTime) -> Int? {
        var low = 0
        var high = switches.count
        while low < high {
            let middle = low + (high - low) / 2
            if switches[middle].at <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }

    public func groupIntervals() throws -> [MulticamInterval] {
        try plan(ranges: [range]).intervals
    }

    /// Explicit ranges address group time and take precedence over the saved assembly.
    public func plan(ranges: [MulticamRange]? = nil) throws -> MulticamPlan {
        try validate()
        if let ranges { try validateRanges(ranges) }
        let items = ranges.map { $0.map(StillAssemblyItem.group) } ?? assemblyItems ?? [.group(range)]
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var intervals: [MulticamInterval] = []
        var picture: [MulticamSpan] = []
        var sound: [MulticamSpan] = []
        var outputStart = RationalTime.zero

        for (assemblyIndex, item) in items.enumerated() {
            guard let requested = item.group else {
                if let insert = item.still { outputStart = try outputStart.adding(insert.duration) }
                continue
            }
            guard var markerIndex = switchIndex(at: requested.from) else {
                throw Self.invalid("No active switch at \(requested.from)")
            }
            var start = requested.from
            while start < requested.to {
                let marker = switches[markerIndex]
                let end = markerIndex + 1 < switches.count
                    ? min(requested.to, switches[markerIndex + 1].at) : requested.to
                let outputEnd = try outputStart.adding(end.subtracting(start))
                let group = MulticamRange(from: start, to: end)
                let output = MulticamRange(from: outputStart, to: outputEnd)
                // A switch can route a microphone for one interval even when the default is silence.
                let selectedAudio = marker.audio ?? defaultAudio(for: marker.angle, sourcesByID: sourcesByID)
                intervals.append(.init(group: group, output: output, angle: marker.angle,
                                       audio: selectedAudio, assemblyIndex: assemblyIndex))
                try Self.appendSpan(source: sourcesByID[marker.angle]!, stream: nil,
                                    group: group, output: output, to: &picture)
                if let selectedAudio {
                    try Self.appendSpan(source: sourcesByID[selectedAudio.source]!, stream: selectedAudio.stream,
                                        group: group, output: output, to: &sound)
                }
                markerIndex += 1
                start = end
                outputStart = outputEnd
            }
        }
        return .init(intervals: intervals, picture: picture, audio: sound, duration: outputStart)
    }

    private func defaultAudio(for angle: String, sourcesByID: [String: MulticamSource]) -> MulticamAudioSelection? {
        switch audio {
        case .fixed(let master): return master
        case .follow:
            return sourcesByID[angle]?.audioStream.map { .init(source: angle, stream: $0) }
        case .none: return nil
        }
    }

    private static func appendSpan(source: MulticamSource, stream: Int?, group: MulticamRange,
                                   output: MulticamRange, to spans: inout [MulticamSpan]) throws {
        let input: MulticamRange
        do {
            input = try MulticamRange(from: group.from.subtracting(source.offset),
                                      to: group.to.subtracting(source.offset))
        } catch let issue as CutError where issue.code == "time_overflow" {
            throw CutError(code: issue.code,
                           message: "Source \(source.id): offset \(source.offset) places the recording outside the supported time range.")
        }
        MulticamSpan(source: source.id, stream: stream, input: input, output: output)
            .appendCoalescing(to: &spans)
    }
}

public struct MulticamInterval: Codable, Equatable, Sendable {
    public let group: MulticamRange
    public let output: MulticamRange
    public let angle: String
    public let audio: MulticamAudioSelection?
    public let assemblyIndex: Int

    public init(group: MulticamRange, output: MulticamRange, angle: String,
                audio: MulticamAudioSelection?, assemblyIndex: Int) {
        self.group = group
        self.output = output
        self.angle = angle
        self.audio = audio
        self.assemblyIndex = assemblyIndex
    }
}

public struct MulticamSpan: Codable, Equatable, Sendable {
    public let source: String
    public let stream: Int?
    public var input: MulticamRange
    public var output: MulticamRange

    public init(source: String, stream: Int?, input: MulticamRange, output: MulticamRange) {
        self.source = source
        self.stream = stream
        self.input = input
        self.output = output
    }

    public func appendCoalescing(to spans: inout [Self]) {
        if let index = spans.indices.last, spans[index].source == source,
           spans[index].stream == stream, spans[index].input.to == input.from,
           spans[index].output.to == output.from {
            spans[index].input.to = input.to
            spans[index].output.to = output.to
        } else {
            spans.append(self)
        }
    }
}

public struct MulticamPlan: Codable, Equatable, Sendable {
    public let intervals: [MulticamInterval]
    public let picture: [MulticamSpan]
    public let audio: [MulticamSpan]
    public let duration: RationalTime

    public init(intervals: [MulticamInterval], picture: [MulticamSpan],
                audio: [MulticamSpan], duration: RationalTime) {
        self.intervals = intervals
        self.picture = picture
        self.audio = audio
        self.duration = duration
    }
}

package enum JSONInputLocation: Hashable, Sendable {
    case key(String)
    case index(Int)
}

private struct JSONInputContainer {
    var keys: Set<String>?
    var expectsKey: Bool
    var location: JSONInputLocation?

    init(object: Bool) {
        keys = object ? [] : nil
        expectsKey = object
        location = object ? nil : .index(0)
    }
}

/// Check syntax that JSONDecoder accepts silently. Call after decoding syntactically valid UTF-8.
/// The observer receives fractional and exponent spellings, which Foundation may round when decoding.
package func jsonInputIssue(_ data: Data, integerNumbersOnly: Bool = false,
                            inspectDecimal: (([JSONInputLocation], ArraySlice<UInt8>) -> Void)? = nil) -> String? {
    let bytes = [UInt8](data)
    var containers = [JSONInputContainer]()
    var index = 0
    var previous: UInt8?
    while index < bytes.count {
        let byte = bytes[index]
        switch byte {
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            if integerNumbersOnly || inspectDecimal != nil {
                let start = index
                while index + 1 < bytes.count,
                      ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index + 1]) { index += 1 }
                let token = bytes[start...index]
                if token.contains(UInt8(ascii: ".")) || token.contains(UInt8(ascii: "e")) || token.contains(UInt8(ascii: "E")) {
                    if integerNumbersOnly, integralJSONParts(token) == nil {
                        return "contains a non-integer JSON number"
                    }
                    inspectDecimal?(containers.compactMap(\.location), token)
                }
            }
        case UInt8(ascii: "{"): containers.append(JSONInputContainer(object: true))
        case UInt8(ascii: "["): containers.append(JSONInputContainer(object: false))
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            if previous == UInt8(ascii: ",") {
                return "contains a trailing comma"
            }
            _ = containers.popLast()
        case UInt8(ascii: ","):
            if let last = containers.indices.last {
                if containers[last].keys != nil { containers[last].expectsKey = true }
                else if case let .index(item) = containers[last].location { containers[last].location = .index(item + 1) }
            }
        case UInt8(ascii: "\""):
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { return nil }
            if let last = containers.indices.last, containers[last].expectsKey {
                let key = (try? JSONDecoder().decode(String.self, from: Data(bytes[start...index]))) ?? ""
                if containers[last].keys?.insert(key).inserted == false {
                    return "repeats the field '\(key)'"
                }
                containers[last].expectsKey = false
                containers[last].location = .key(key)
            }
        default: break
        }
        if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D { previous = byte }
        index += 1
    }
    return nil
}

/// Return the exact integer represented by a previously validated JSON number token.
package func exactJSONInteger(_ number: ArraySlice<UInt8>) -> Int? {
    guard let (coefficient, last, zeros) = integralJSONParts(number) else { return nil }
    guard let last, let first = coefficient.firstIndex(where: { (49...57).contains($0) }) else { return 0 }
    // An Int on the supported 64-bit platforms has at most 19 decimal digits.
    guard zeros <= 19, last - first + zeros <= 19 else { return nil }
    var digits = String(decoding: coefficient[first...last].filter { $0 != UInt8(ascii: ".") }, as: UTF8.self)
    digits += String(repeating: "0", count: zeros)
    if number.first == UInt8(ascii: "-") { digits.insert("-", at: digits.startIndex) }
    return Int(digits)
}

/// Use the original significand and exponent even when floating-point decoding loses precision.
private func integralJSONParts(_ number: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, Int?, Int)? {
    let exponentIndex = number.firstIndex { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }
    let coefficient = number[..<(exponentIndex ?? number.endIndex)]
    guard let lastNonzero = coefficient.lastIndex(where: { (49...57).contains($0) }) else { return (coefficient, nil, 0) }
    let decimal = coefficient.firstIndex(of: UInt8(ascii: "."))
    let fractionalDigits = decimal.map { coefficient.endIndex - $0 - 1 } ?? 0
    let trailingZeros = coefficient.endIndex - lastNonzero - 1 - (decimal.map { $0 > lastNonzero ? 1 : 0 } ?? 0)
    var exponent = 0
    if let exponentIndex {
        let text = String(decoding: number[(exponentIndex + 1)...], as: UTF8.self)
        exponent = Int(text) ?? (text.hasPrefix("-") ? Int.min : Int.max)
    }
    let integralShift = fractionalDigits - trailingZeros
    guard exponent >= integralShift else { return nil }
    let padding = exponent.subtractingReportingOverflow(integralShift)
    return (coefficient, lastNonzero, padding.overflow ? Int.max : padding.partialValue)
}
