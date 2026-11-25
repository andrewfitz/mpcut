import CryptoKit
import Foundation

public struct TranscriptAsset: Codable, Hashable, Sendable {
    public let sha256: String
    let document: TranscriptDocument?
    package var recognitionJobID: UUID? { document?.jobID.flatMap(UUID.init(uuidString:)) }

    private enum CodingKeys: String, CodingKey { case sha256 }

    /// An unresolved reference for an API response. A project archive must supply its payload.
    public init(sha256: String) {
        self.sha256 = sha256
        document = nil
    }

    init(document: TranscriptDocument) throws {
        self.document = document
        sha256 = try TranscriptStore.digest(TranscriptCodec.encodeStored(document))
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_state")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = try values.decode(String.self, forKey: .sha256)
        document = try ProjectEmbeddedAssets.transcript(digest: sha256)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        try ProjectEmbeddedAssets.register(self)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sha256, forKey: .sha256)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.sha256 == rhs.sha256 }
    public func hash(into hasher: inout Hasher) { hasher.combine(sha256) }

    func validate() throws {
        guard TranscriptStore.validDigest(sha256) else { throw transcriptError("Invalid transcript digest.") }
    }
}

public enum TranscriptBindingStatus: String, Codable, Sendable {
    case available, unverified, offline, changed, unbound
    case bindingMissing = "binding_missing"
}

public struct TranscriptBinding: Codable, Hashable, Sendable {
    public var trackID: String
    public var sourceID: String?
    public var file: String?
    public var streamIndex: Int
    public var channel: Int?
    public var sequenceClockOrigin: RationalTime?
    public var sequenceStreamOrdinal: Int?
    public var sourceFingerprint: String?
    public var sourceConfirmed: Bool?
    public var offset: RationalTime

    private enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case sourceID = "source_id"
        case file
        case streamIndex = "audio_stream_index"
        case channel
        case sequenceClockOrigin = "sequence_clock_origin"
        case sequenceStreamOrdinal = "sequence_stream_ordinal"
        case sourceFingerprint = "source_fingerprint"
        case sourceConfirmed = "source_confirmed"
        case offset
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_state")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try values.decode(String.self, forKey: .trackID)
        sourceID = values.contains(.sourceID) ? try values.decode(String.self, forKey: .sourceID) : nil
        file = values.contains(.file) ? try values.decode(String.self, forKey: .file) : nil
        streamIndex = try values.decode(Int.self, forKey: .streamIndex)
        channel = values.contains(.channel) ? try values.decode(Int.self, forKey: .channel) : nil
        sequenceClockOrigin = values.contains(.sequenceClockOrigin) ? try values.decode(RationalTime.self, forKey: .sequenceClockOrigin) : nil
        sequenceStreamOrdinal = values.contains(.sequenceStreamOrdinal) ? try values.decode(Int.self, forKey: .sequenceStreamOrdinal) : nil
        sourceFingerprint = values.contains(.sourceFingerprint) ? try values.decode(String.self, forKey: .sourceFingerprint) : nil
        sourceConfirmed = values.contains(.sourceConfirmed) ? try values.decode(Bool.self, forKey: .sourceConfirmed) : nil
        offset = try values.decode(RationalTime.self, forKey: .offset)
    }

    public init(trackID: String, sourceID: String? = nil, file: String? = nil, streamIndex: Int,
                channel: Int? = nil, offset: RationalTime = .zero, sequenceClockOrigin: RationalTime? = nil,
                sequenceStreamOrdinal: Int? = nil, sourceFingerprint: String? = nil, sourceConfirmed: Bool? = nil) {
        self.trackID = trackID
        self.sourceID = sourceID
        self.file = file
        self.streamIndex = streamIndex
        self.channel = channel
        self.sequenceClockOrigin = sequenceClockOrigin
        self.sequenceStreamOrdinal = sequenceStreamOrdinal
        self.sourceFingerprint = sourceFingerprint
        self.sourceConfirmed = sourceConfirmed
        self.offset = offset
    }

    public func mapSourcePaths(_ transform: (String) -> String) -> Self {
        var copy = self
        copy.file = file.map(transform)
        return copy
    }

    private func sourcePath(in project: CutProject) -> String? {
        if case .multicam(let group) = project {
            return group.sources.first { $0.id == sourceID }?.file
        }
        return file
    }

    public func sourceStatus(in project: CutProject, relativeTo document: URL) -> TranscriptBindingStatus {
        guard file != nil || sourceID != nil else { return .unbound }
        guard let path = sourcePath(in: project) else { return .bindingMissing }
        guard let source = try? CutProject.checkedMediaURL(path, relativeTo: document),
              let current = try? SourceIdentity(source) else { return .offline }
        guard let sourceFingerprint else { return .unverified }
        guard sourceFingerprint == current.transcriptFingerprint else { return .changed }
        return sourceConfirmed == true ? .available : .unverified
    }

    /// Remember the selected recording's identity using a filesystem stat.
    /// Inferred imports still need confirmation from the editor.
    public func stamped(in project: CutProject, relativeTo document: URL, confirmed: Bool) -> Self {
        var copy = self
        let identity = sourcePath(in: project)
            .flatMap { try? CutProject.checkedMediaURL($0, relativeTo: document) }
            .flatMap { try? SourceIdentity($0) }
        copy.sourceFingerprint = identity?.transcriptFingerprint
        copy.sourceConfirmed = identity == nil ? nil : confirmed
        return copy
    }

    func validate() throws {
        let indices = 0...Int(Int32.max)
        guard validStillID(trackID), indices.contains(streamIndex), channel.map(indices.contains) ?? true,
              file == nil || sourceID == nil, file.map(ProjectFile.validMediaPath) ?? true,
              sourceID.map(validStillID) ?? true, sequenceStreamOrdinal.map(indices.contains) ?? true,
              sourceFingerprint.map(TranscriptStore.validDigest) ?? true,
              sourceConfirmed != true || sourceFingerprint != nil else {
            throw transcriptError("Invalid transcript binding for track ‘\(trackID)’.")
        }
    }
}

public struct TranscriptAttachment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var asset: TranscriptAsset
    public var bindings: [TranscriptBinding]
    public var importOrigin: RationalTime?
    public var fingerprint: String?
    public var resultID: String { asset.sha256 }

    private enum CodingKeys: String, CodingKey {
        case id
        case asset
        case bindings
        case importOrigin = "import_origin"
        case fingerprint
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_state")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        asset = try values.decode(TranscriptAsset.self, forKey: .asset)
        bindings = try values.decode([TranscriptBinding].self, forKey: .bindings)
        importOrigin = values.contains(.importOrigin) ? try values.decode(RationalTime.self, forKey: .importOrigin) : nil
        fingerprint = values.contains(.fingerprint) ? try values.decode(String.self, forKey: .fingerprint) : nil
    }

    public init(id: String, asset: TranscriptAsset, bindings: [TranscriptBinding], importOrigin: RationalTime? = nil,
                fingerprint: String? = nil) {
        self.id = id
        self.asset = asset
        self.bindings = bindings
        self.importOrigin = importOrigin
        self.fingerprint = fingerprint
    }
}

public struct ProjectTranscripts: Codable, Equatable, Sendable {
    public var attachments: [TranscriptAttachment]
    public var authoring: [TranscriptAuthoredRecord]
    public var revision: UInt64
    public var documentID: UUID?

    private enum CodingKeys: String, CodingKey {
        case attachments
        case authoring
        case revision
        case documentID = "document_id"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_state")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attachments = try values.decode([TranscriptAttachment].self, forKey: .attachments)
        authoring = try values.decode([TranscriptAuthoredRecord].self, forKey: .authoring)
        revision = try values.decode(UInt64.self, forKey: .revision)
        documentID = values.contains(.documentID) ? try values.decode(UUID.self, forKey: .documentID) : nil
    }

    public init(attachments: [TranscriptAttachment] = [], authoring: [TranscriptAuthoredRecord] = [],
                revision: UInt64 = 0, documentID: UUID? = nil) {
        self.attachments = attachments
        self.authoring = authoring
        self.revision = revision
        self.documentID = documentID
    }

    public var isEmpty: Bool { attachments.isEmpty && authoring.isEmpty && revision == 0 && documentID == nil }

    public mutating func advanceRevision() throws {
        guard revision < UInt64.max else { throw transcriptError("The transcript revision counter is exhausted.") }
        revision += 1
    }

    public func mapSourcePaths(_ transform: (String) -> String) -> Self {
        var copy = self
        copy.attachments = attachments.map { attachment in
            var value = attachment
            value.bindings = attachment.bindings.map { $0.mapSourcePaths(transform) }
            return value
        }
        copy.authoring = authoring.map { $0.mapSourcePaths(transform) }
        return copy
    }

    public func validate() throws {
        var ids = Set<String>()
        for attachment in attachments {
            guard validStillID(attachment.id), ids.insert(attachment.id).inserted,
                  Set(attachment.bindings.map(\.trackID)).count == attachment.bindings.count else {
                throw transcriptError("Transcript attachment and binding IDs must be unique.")
            }
            try attachment.asset.validate()
            for binding in attachment.bindings { try binding.validate() }
        }
        ids.removeAll(keepingCapacity: true)
        for record in authoring {
            guard validStillID(record.id), ids.insert(record.id).inserted else {
                throw transcriptError("Transcript authoring IDs must be unique.")
            }
            try record.validate()
        }
    }

    var protectedPaths: [(String, String)] {
        authoring.flatMap { record in record.protectedPaths.map { (record.id, $0) } } + attachments.flatMap { attachment in
            attachment.bindings.compactMap { binding in binding.file.map { (attachment.id, $0) } }
        }
    }
}

extension TranscriptAuthoredRecord {
    var protectedPaths: [String] {
        anchors.compactMap { $0.binding.file } + [speakerReference?.binding.file].compactMap { $0 }
    }
}

func transcriptError(_ message: String, code: String = "invalid_transcript_state") -> CutError {
    CutError(code: code, message: message)
}

extension SourceIdentity {
    package var transcriptFingerprint: String {
        TranscriptStore.digest(Data("\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds)".utf8))
    }
}

public enum TranscriptAssetStatus: String, Codable, Hashable, Sendable {
    case available, missing, invalid
}

public enum TranscriptStore {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validDigest(_ string: String) -> Bool {
        string.utf8.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func put(_ data: Data, relativeTo project: URL, draft: Bool = false) throws -> TranscriptAsset {
        try TranscriptAsset(document: TranscriptCodec.decode(data, format: .json))
    }

    public static func put(_ document: TranscriptDocument) throws -> TranscriptAsset {
        try TranscriptAsset(document: document)
    }

    public static func read(_ asset: TranscriptAsset, relativeTo project: URL) throws -> Data {
        try TranscriptCodec.encodeStored(decoded(asset, relativeTo: project))
    }

    public static func decoded(_ asset: TranscriptAsset, relativeTo project: URL) throws -> TranscriptDocument {
        guard let document = asset.document else {
            throw transcriptError("Missing embedded transcript ‘\(asset.sha256)’.", code: "missing_transcript")
        }
        return document
    }

    public static func assetStatus(_ asset: TranscriptAsset, relativeTo project: URL) -> TranscriptAssetStatus {
        asset.document == nil ? .missing : .available
    }
}

/// Resolve once per attachment state. Timeline operations can project the same
/// source-local protections without decoding a transcript or rebuilding a word index.
package struct TranscriptPauseProtectionCache {
    private var projectURL: URL?
    private var state: ProjectTranscripts?
    private var protections = TranscriptPauseProtections()

    package init() {}

    package mutating func resolve(_ state: ProjectTranscripts, relativeTo projectURL: URL?) -> TranscriptPauseProtections {
        if self.projectURL == projectURL && self.state == state { return protections }
        self.projectURL = projectURL
        self.state = state
        protections = projectURL.map { TranscriptPauseProtections(state: state, relativeTo: $0) } ?? .init()
        return protections
    }
}

package struct TranscriptPauseProtections {
    private struct Edge {
        let binding: TranscriptBinding
        let time: RationalTime
    }

    private struct Gap {
        let from: Edge
        let to: Edge
    }

    private var gaps: [Gap] = []

    package var isEmpty: Bool { gaps.isEmpty }

    fileprivate init() {}

    fileprivate init(state: ProjectTranscripts, relativeTo project: URL) {
        let records = Dictionary(grouping: state.authoring.filter {
            if case .pauseProtection = $0.change { return true }
            return false
        }, by: \.attachmentID)
        for attachment in state.attachments {
            guard let authored = records[attachment.id],
                  let document = try? TranscriptStore.decoded(attachment.asset, relativeTo: project),
                  let words = try? TranscriptIndex.sourceOccurrences(document: document, attachment: attachment) else { continue }
            let review = TranscriptEditorial.review(records: authored, sourceWords: words, attachmentID: attachment.id)
            for record in review {
                guard record.anchors.count == 2, record.anchors.allSatisfy({ $0.status == .resolved }),
                      let left = record.anchors[0].words.last, let right = record.anchors[1].words.first,
                      let from = left.sourceRange?.to, let to = right.sourceRange?.from,
                      let leftBinding = left.binding, let rightBinding = right.binding else { continue }
                gaps.append(Gap(from: Edge(binding: leftBinding, time: from), to: Edge(binding: rightBinding, time: to)))
            }
        }
    }

    private func ranges(_ time: (Edge) -> RationalTime?) -> [AudioSpan] {
        gaps.compactMap { gap in
            guard let from = time(gap.from), let to = time(gap.to), from < to else { return nil }
            return AudioSpan(from: from, to: to)
        }
    }

    package func sequence(file: String, origin: RationalTime, stream: Int, sourceFingerprint: String) -> [AudioSpan] {
        ranges { edge in
            let binding = edge.binding
            guard binding.file == file, binding.streamIndex == stream,
                  binding.sourceFingerprint.map({ $0 == sourceFingerprint }) ?? true else { return nil }
            return try? edge.time.subtracting(origin)
        }
    }

    package func group(sources: [MulticamSource], sourceFingerprints: [String: String]) -> [AudioSpan] {
        group(sources: sources, sourceFingerprints: sourceFingerprints, replacementOffsets: [:])
    }

    package func group(project: MulticamProject, sourceFingerprints: [String: String]) throws -> [AudioSpan] {
        let offsets = Dictionary(uniqueKeysWithValues: try project.transcriptReplacementPlacements().map {
            ($0.trackID, $0.offset)
        })
        return group(sources: project.sources, sourceFingerprints: sourceFingerprints, replacementOffsets: offsets)
    }

    private func group(sources: [MulticamSource], sourceFingerprints: [String: String],
                       replacementOffsets: [String: RationalTime]) -> [AudioSpan] {
        let sources = Dictionary(sources.map { ($0.id, $0.offset) }, uniquingKeysWith: { _, new in new })
        return ranges { edge in
            let binding = edge.binding
            guard let id = binding.sourceID, let offset = sources[id], let fingerprint = sourceFingerprints[id],
                  binding.sourceFingerprint.map({ $0 == fingerprint }) ?? true else { return nil }
            if let replacement = TranscriptJobPlan.replacementTrackIdentity(binding.trackID) {
                guard let replacementOffset = replacementOffsets[replacement] else { return nil }
                return try? edge.time.adding(replacementOffset)
            }
            return try? edge.time.adding(offset)
        }
    }
}
