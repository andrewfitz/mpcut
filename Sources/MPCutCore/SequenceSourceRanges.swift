import Foundation

public struct SequenceSourceRange: Codable, Hashable, Sendable {
    public var file: String
    public let from: RationalTime
    public let to: RationalTime

    enum CodingKeys: String, CodingKey { case file, from, to }

    public init(file: String, from: RationalTime, to: RationalTime) throws {
        self.file = file
        self.from = from
        self.to = to
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_source_range")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(file: values.decode(String.self, forKey: .file),
                      from: ProjectField.time(values, .from),
                      to: ProjectField.time(values, .to))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(file, forKey: .file)
        try values.encode(from.description, forKey: .from)
        try values.encode(to.description, forKey: .to)
    }

    package func validate() throws {
        guard validStillID(file), ProjectFile.validMediaPath(file), from >= .zero, from < to else {
            throw CutError(code: "invalid_source_range", message: "Supply a media file and a nonempty source range.")
        }
    }

    package func fileURL(relativeTo projectURL: URL?) throws -> URL {
        try validate()
        if let projectURL {
            return try CutProject.checkedMediaURL(file, relativeTo: projectURL)
        }
        guard file.hasPrefix("/") else {
            throw CutError(code: "invalid_source_range", message: "Supply an absolute media path.")
        }
        return try ProjectFile.checkedSourceURL(file: file, in: URL(fileURLWithPath: "/", isDirectory: true))
    }

    package func resolve(relativeTo projectURL: URL?, inspect: (URL) throws -> MediaInfo) throws -> MediaInfo {
        let url = try fileURL(relativeTo: projectURL)
        let media = try inspect(url)
        guard to <= media.duration else {
            throw CutError(code: "invalid_source_range", message: "The range extends beyond \(url.lastPathComponent).")
        }
        return media
    }
}

public struct NamedSourceSelect: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public var range: SequenceSourceRange

    enum CodingKeys: String, CodingKey { case id, name, range }

    public init(id: String, name: String, range: SequenceSourceRange) throws {
        self.id = id
        self.name = name
        self.range = range
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_source_select")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      range: values.decode(SequenceSourceRange.self, forKey: .range))
    }

    package func validate() throws {
        guard validStillID(id), validStillID(name) else {
            throw CutError(code: "invalid_source_select", message: "Supply a nonblank select ID and name.")
        }
        try range.validate()
    }

    package func mapPath(_ transform: (String) -> String) -> Self {
        var result = self
        result.range.file = transform(range.file)
        return result
    }
}

extension CutProject {
    public var sourceSelects: [NamedSourceSelect] { stillSequenceValue?.sourceSelects ?? [] }

    public func settingSourceSelect(_ select: NamedSourceSelect) throws -> Self {
        guard sequenceItems != nil else { throw expectedSourceSequence() }
        return try editingStills(sequence: { project in
            if let index = project.sourceSelects.firstIndex(where: { $0.id == select.id }) {
                project.sourceSelects[index] = select
            } else {
                project.sourceSelects.append(select)
            }
        }, multicam: { _ in })
    }

    public func removingSourceSelect(id: String) throws -> Self {
        guard sequenceItems != nil else { throw expectedSourceSequence() }
        guard sourceSelects.contains(where: { $0.id == id }) else {
            throw CutError(code: "invalid_source_select", message: "No source select has ID \(id).")
        }
        return try editingStills(sequence: { $0.sourceSelects.removeAll { $0.id == id } }, multicam: { _ in })
    }

    /// Build a candidate without changing the input project. The caller resolves media
    /// on its own worker and publishes only after its revision and identity checks.
    package func applyingSourceRanges(_ ranges: [SequenceSourceRange], from: RationalTime, to: RationalTime,
                                     relativeTo projectURL: URL? = nil,
                                     onRetainedClip: (_ retainedID: String, _ originalID: String) -> Void = { _, _ in },
                                     inspect: (URL) throws -> MediaInfo) throws -> Self {
        guard sequenceItems != nil else { throw expectedSourceSequence() }
        guard !ranges.isEmpty else {
            throw CutError(code: "invalid_source_range", message: "Supply at least one source range.")
        }
        let timeline = try TranscriptEditTimeline(self)
        guard from >= .zero, from <= to, to <= timeline.duration else {
            throw CutError(code: "invalid_range", message: "The destination lies outside the sequence.")
        }
        let clips = try ranges.map { range -> TranscriptEditSlice in
            let media = try range.resolve(relativeTo: projectURL, inspect: inspect)
            return .sequence(CutSequenceClip(id: UUID().uuidString, file: media.url.path,
                                             from: range.from, to: range.to))
        }
        let (before, after) = try timeline.retaining(before: from, after: to)
        return try timeline.project(self, with: before + clips + after, adoptingSourceFormat: true,
                                    preservingHiddenStillHandles: true,
                                    onRetainedClip: onRetainedClip)
    }
}

private func expectedSourceSequence() -> CutError {
    CutError(code: "expected_sequence", message: "Source selects and range plans require a sequence.")
}

extension SequenceSourceRange {
    /// Shared by the live editor and file authoring. A select reference is resolved at the requested revision.
    package static func request(_ row: [String: Any], selects: [NamedSourceSelect],
                                rawPath: (String) throws -> String = { $0 }) throws -> SequenceSourceRange {
        if let id = row["select_id"] as? String, row.count == 1 {
            guard let select = selects.first(where: { $0.id == id }) else {
                throw CutError(code: "invalid_source_select", message: "No source select has ID \(id).")
            }
            return select.range
        }
        guard row.count == 3, let file = row["file"] as? String, let from = row["from"] as? String,
              let to = row["to"] as? String else {
            throw CutError(code: "invalid_source_range", message: "Supply file, from and to, or a select_id.")
        }
        return try .init(file: rawPath(file), from: .init(parsing: from), to: .init(parsing: to))
    }
}
