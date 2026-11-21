import Foundation

private struct MulticamField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }

    static func rejectUnknown<K: CodingKey>(_ keys: K.Type, in decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Self.self)
        if let field = container.allKeys.map(\.stringValue).sorted().first(where: { K(stringValue: $0) == nil }) {
            throw CutError(code: "invalid_multicam_project",
                           message: "Unknown field ‘\(field)’ in \(location(decoder.codingPath))")
        }
    }

    /// A JSON path such as `switches[1].at`.
    static func location(_ path: [CodingKey]) -> String {
        let text = path.reduce(into: "") { text, key in
            if let index = key.intValue {
                text += "[\(index)]"
            } else {
                text += (text.isEmpty ? "" : ".") + key.stringValue
            }
        }
        return text.isEmpty ? "the project root" : text
    }

    /// A malformed time is a fault in the project document, reported with its JSON location.
    static func time<K: CodingKey>(_ values: KeyedDecodingContainer<K>, _ key: K,
                                   default fallback: String? = nil) throws -> RationalTime {
        let text = try values.decodeIfPresent(String.self, forKey: key) ?? fallback
            ?? values.decode(String.self, forKey: key)
        do {
            return try RationalTime(parsing: text)
        } catch {
            throw CutError(code: "invalid_multicam_project",
                           message: "Invalid timestamp ‘\(text)’ in \(location(values.codingPath + [key]))")
        }
    }
}

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
        try MulticamField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(from: try MulticamField.time(values, .from), to: try MulticamField.time(values, .to))
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
        try MulticamField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  file: try values.decode(String.self, forKey: .file),
                  offset: try MulticamField.time(values, .offset, default: "0"),
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
        try MulticamField.rejectUnknown(CodingKeys.self, in: decoder)
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
        try MulticamField.rejectUnknown(CodingKeys.self, in: decoder)
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
        try MulticamField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(at: try MulticamField.time(values, .at),
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
    public static let schemaVersion = 1
    public var referenceAngle: String
    public var range: MulticamRange
    public var angles: [MulticamSource]
    public var audioSources: [MulticamSource]
    public var audio: MulticamAudioPolicy
    public var switches: [MulticamSwitch]
    public var assembly: [MulticamRange]?

    public var sources: [MulticamSource] { angles + audioSources }

    public init(referenceAngle: String, range: MulticamRange, angles: [MulticamSource],
                audioSources: [MulticamSource] = [], audio: MulticamAudioPolicy,
                switches: [MulticamSwitch], assembly: [MulticamRange]? = nil) {
        self.referenceAngle = referenceAngle
        self.range = range
        self.angles = angles
        self.audioSources = audioSources
        self.audio = audio
        self.switches = switches
        self.assembly = assembly
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, referenceAngle, range, angles, audioSources, audio, switches, assembly
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw CutError(code: "unsupported_multicam_version",
                           message: "Multicam schema version \(version) is unsupported")
        }
        try MulticamField.rejectUnknown(CodingKeys.self, in: decoder)
        guard try values.decode(String.self, forKey: .kind) == "multicam" else {
            throw Self.invalid("Expected a multicam project")
        }
        self.init(referenceAngle: try values.decode(String.self, forKey: .referenceAngle),
                  range: try values.decode(MulticamRange.self, forKey: .range),
                  angles: try values.decode([MulticamSource].self, forKey: .angles),
                  audioSources: try values.decodeIfPresent([MulticamSource].self, forKey: .audioSources) ?? [],
                  audio: try values.decode(MulticamAudioPolicy.self, forKey: .audio),
                  switches: try values.decode([MulticamSwitch].self, forKey: .switches),
                  assembly: try values.decodeIfPresent([MulticamRange].self, forKey: .assembly))
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.schemaVersion, forKey: .schemaVersion)
        try values.encode("multicam", forKey: .kind)
        try values.encode(referenceAngle, forKey: .referenceAngle)
        try values.encode(range, forKey: .range)
        try values.encode(angles, forKey: .angles)
        if !audioSources.isEmpty { try values.encode(audioSources, forKey: .audioSources) }
        try values.encode(audio, forKey: .audio)
        try values.encode(switches, forKey: .switches)
        try values.encodeIfPresent(assembly, forKey: .assembly)
    }

    /// Media stream indices are 32-bit.
    private static let streamIndices = 0...Int(Int32.max)

    /// The largest project document `load` reads, matching the CLI's request limit.
    public static let maximumFileSize = 64 * 1024 * 1024

    public static func load(from url: URL) throws -> Self {
        let data: Data
        do {
            // A recording passed by mistake must not be read into memory whole.
            if let size = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > maximumFileSize {
                throw invalid("Multicam project exceeds the 64 MB limit")
            }
            data = try Data(contentsOf: url)
        } catch let error as CutError {
            throw error
        } catch {
            throw CutError(code: "multicam_project_read_failed",
                           message: "Could not read \(url.path): \(error.localizedDescription)")
        }
        return try decode(data)
    }

    /// Decode a project document that was read from a file or from standard input.
    public static func decode(_ data: Data) throws -> Self {
        do {
            guard data.count <= maximumFileSize else {
                throw invalid("Multicam project exceeds the 64 MB limit")
            }
            guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
                throw invalid("Multicam project must contain a UTF-8 JSON object")
            }
            let project = try JSONDecoder().decode(Self.self, from: data)
            if let issue = jsonInputIssue(data) {
                throw invalid("Multicam project \(issue)")
            }
            return project
        } catch let error as CutError {
            throw error
        } catch let error as DecodingError {
            throw invalid("Invalid Multicam JSON: \(error)")
        }
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        let destination = Self.canonicalFileURL(url)
        let destinationIdentity = Self.fileIdentity(destination)
        for source in sources {
            let location = sourceURL(for: source, relativeTo: url)
            // An unavailable directory prefix has no source file to protect.
            guard !location.path.split(separator: "/").contains("..") else { continue }
            let media = Self.canonicalFileURL(location)
            guard media != destination,
                  destinationIdentity.map({ $0 != Self.fileIdentity(media) }) ?? true else {
                throw CutError(code: "multicam_project_source_collision",
                               message: "Project destination overlaps source ‘\(source.id)’ at \(media.path)")
            }
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CutError(code: "multicam_project_write_failed",
                           message: "Could not save \(url.path): \(error.localizedDescription)")
        }
    }

    public func sourceURL(for source: MulticamSource, relativeTo projectURL: URL) -> URL {
        sourceURL(for: source, in: projectURL.deletingLastPathComponent())
    }

    func sourceURL(for source: MulticamSource, in directory: URL) -> URL {
        let path = source.file.hasPrefix("/") ? source.file :
            directory.path + "/" + source.file
        let components = path.split(separator: "/")
        guard let parent = components.lastIndex(of: "..") else {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        let prefix = "/" + components[...parent].joined(separator: "/")
        if let resolved = realpath(prefix, nil) {
            defer { free(resolved) }
            let path = String(cString: resolved) + "/" + components[(parent + 1)...].joined(separator: "/")
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        // Preserve the unresolved traversal for diagnostics and missing-source
        // checks. Standardizing here could select another recording.
        var url = URLComponents()
        url.scheme = "file"
        url.host = ""
        url.path = path
        return url.url!
    }

    private static func canonicalFileURL(_ url: URL) -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if (try? resolved.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true,
           let target = try? URL(resolvingAliasFileAt: resolved, options: [.withoutUI, .withoutMounting]) {
            return target.standardizedFileURL.resolvingSymlinksInPath()
        }
        return resolved
    }

    private struct FileIdentity: Equatable {
        let device: NSNumber
        let inode: NSNumber
    }

    private static func fileIdentity(_ url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return .init(device: device, inode: inode)
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
            let endpoint = source.file.split(separator: "/").last
            guard !source.file.hasSuffix("/"), endpoint != ".", endpoint != ".." else {
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
        if let assembly { try validateRanges(assembly) }
    }

    private func validateRanges(_ ranges: [MulticamRange]) throws {
        guard !ranges.isEmpty else { throw Self.invalid("Assembly must contain at least one range") }
        for (index, requested) in ranges.enumerated() {
            guard range.contains(requested.from), requested.from < requested.to,
                  requested.to <= range.to else {
                throw Self.invalid("Assembly range \(index + 1) (\(requested.from)–\(requested.to)) lies outside the group or is empty")
            }
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
        let ranges = ranges ?? assembly ?? [range]
        try validateRanges(ranges)
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var intervals: [MulticamInterval] = []
        var picture: [MulticamSpan] = []
        var sound: [MulticamSpan] = []
        var outputStart = RationalTime.zero

        for (assemblyIndex, requested) in ranges.enumerated() {
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

/// Check syntax that JSONDecoder accepts silently. Call after decoding syntactically valid UTF-8.
package func jsonInputIssue(_ data: Data) -> String? {
    let bytes = [UInt8](data)
    var objects: [(keys: Set<String>, expectsKey: Bool)?] = []
    var index = 0
    var previous: UInt8?
    while index < bytes.count {
        let byte = bytes[index]
        switch byte {
        case UInt8(ascii: "{"): objects.append((keys: [], expectsKey: true))
        case UInt8(ascii: "["): objects.append(nil)
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            if previous == UInt8(ascii: ",") {
                return "contains a trailing comma"
            }
            _ = objects.popLast()
        case UInt8(ascii: ","):
            if objects.last??.keys != nil { objects[objects.count - 1]?.expectsKey = true }
        case UInt8(ascii: "\""):
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { return nil }
            if objects.last??.expectsKey == true {
                let key = (try? JSONDecoder().decode(String.self, from: Data(bytes[start...index]))) ?? ""
                if objects[objects.count - 1]?.keys.insert(key).inserted == false {
                    return "repeats the field '\(key)'"
                }
                objects[objects.count - 1]?.expectsKey = false
            }
        default: break
        }
        if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D { previous = byte }
        index += 1
    }
    return nil
}
