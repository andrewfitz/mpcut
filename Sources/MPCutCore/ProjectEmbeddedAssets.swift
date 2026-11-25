import Foundation

/// One table is shared by the edit and both history branches during a synchronous
/// Codable traversal. The project retains immutable values on the references themselves.
final class ProjectEmbeddedAssets: @unchecked Sendable, Codable {
    private enum Root: String, CodingKey {
        case assets = "embedded_assets"
        case version = "schema_version"
    }
    private enum CodingKeys: String, CodingKey { case transcripts, tileScans = "tile_scans" }
    @TaskLocal private static var current: ProjectEmbeddedAssets?

    private var transcripts: [String: TranscriptDocument] = [:]
    private var tileScans: [String: EmbeddedTileScan] = [:]
    private init() {}

    static func encoding(to encoder: Encoder, _ write: () throws -> Void) throws {
        if current != nil { return try write() }
        let table = ProjectEmbeddedAssets()
        try $current.withValue(table, operation: write)
        if !table.transcripts.isEmpty || !table.tileScans.isEmpty {
            var root = encoder.container(keyedBy: Root.self)
            try root.encode(table, forKey: .assets)
        }
    }

    static func decoding<T>(from decoder: Decoder, _ read: () throws -> T) throws -> T {
        if current != nil { return try read() }
        let root = try decoder.container(keyedBy: Root.self)
        // Let the project reader report an unsupported version before interpreting its payloads.
        let version = try root.decodeIfPresent(Int.self, forKey: .version)
        let table = version == CutProject.schemaVersion && root.contains(.assets)
            ? try root.decode(Self.self, forKey: .assets) : Self()
        return try $current.withValue(table, operation: read)
    }

    static func register(_ asset: TranscriptAsset) throws {
        guard let current, current.transcripts[asset.sha256] == nil else { return }
        guard let document = asset.document else { throw missing(asset.sha256) }
        current.transcripts[asset.sha256] = document
    }

    static func transcript(digest: String) throws -> TranscriptDocument? {
        guard let current else { return nil }
        guard let value = current.transcripts[digest] else { throw missing(digest) }
        return value
    }

    static func register(_ scan: EmbeddedTileScan, digest: String, encoder: Encoder) throws {
        guard let current, current.tileScans[digest] == nil else { return }
        current.tileScans[digest] = scan
    }

    static func scan(digest: String, decoder: Decoder) throws -> EmbeddedTileScan {
        guard let scan = current?.tileScans[digest] else { throw missing(digest) }
        return scan
    }

    private static func damaged(_ key: String) -> CutError {
        CutError(code: "invalid_embedded_asset", message: "Embedded asset ‘\(key)’ failed its SHA-256 check.")
    }

    private static func missing(_ key: String) -> CutError {
        CutError(code: "missing_embedded_asset", message: "Project references missing embedded asset ‘\(key)’.")
    }

    init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_embedded_asset")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if fields.contains(.transcripts) {
            let items = try fields.nestedContainer(keyedBy: ProjectField.self, forKey: .transcripts)
            for key in items.allKeys {
                let stored = try items.decode(TranscriptStoredForm.Document.self, forKey: key)
                let document = try stored.document()
                guard TranscriptStore.validDigest(key.stringValue),
                      try TranscriptStore.digest(TranscriptCodec.encodeStored(document)) == key.stringValue else {
                    throw Self.damaged(key.stringValue)
                }
                transcripts[key.stringValue] = document
            }
        }
        if fields.contains(.tileScans) {
            let items = try fields.nestedContainer(keyedBy: ProjectField.self, forKey: .tileScans)
            for key in items.allKeys {
                let scan = try items.decode(EmbeddedTileScan.self, forKey: key)
                guard TranscriptStore.validDigest(key.stringValue), try scan.digest() == key.stringValue else {
                    throw Self.damaged(key.stringValue)
                }
                tileScans[key.stringValue] = scan
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        if !transcripts.isEmpty {
            var items = fields.nestedContainer(keyedBy: ProjectField.self, forKey: .transcripts)
            for (key, document) in transcripts {
                try items.encode(TranscriptStoredForm.Document(document), forKey: ProjectField(stringValue: key))
            }
        }
        if !tileScans.isEmpty { try fields.encode(tileScans, forKey: .tileScans) }
    }
}
