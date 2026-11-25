import Foundation

public struct TranscriptActivityKey: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case stream, channel
        case extractionVersion = "extraction_version"
    }

    public let stream: Int
    public let channel: Int?
    public let extractionVersion: Int

    public init(stream: Int, channel: Int? = nil, extractionVersion: Int = 1) {
        self.stream = stream
        self.channel = channel
        self.extractionVersion = extractionVersion
    }

    func digest() throws -> String {
        guard stream >= 0, channel.map({ $0 >= 0 }) != false, extractionVersion > 0 else {
            throw transcriptError("Invalid transcript activity key.")
        }
        return TranscriptStore.digest(try ProjectFile.encoded(self, compact: true))
    }
}

extension AnalysisSidecar {
    private static let activityPrefix = "transcript_activity.v1."

    static func savedTranscriptStream(forKey name: String) -> Int? {
        guard name.hasPrefix(activityPrefix) else { return nil }
        let parts = name.dropFirst(activityPrefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let stream = Int(parts[0]), stream >= 0, TranscriptStore.validDigest(String(parts[1])) else { return nil }
        return stream
    }

    private static func transcriptSection(_ prefix: String, stream: Int, digest: String) throws -> String {
        guard stream >= 0, TranscriptStore.validDigest(digest) else {
            throw transcriptError("Invalid transcript recognition key.")
        }
        return "\(prefix)\(stream).\(digest)"
    }

    static func transcriptActivitySection(_ key: TranscriptActivityKey) throws -> String {
        try transcriptSection(activityPrefix, stream: key.stream, digest: key.digest())
    }

    public func readTranscriptActivity(_ key: TranscriptActivityKey, cancelled: () -> Bool = { Task.isCancelled }) -> Data? {
        guard let name = try? Self.transcriptActivitySection(key) else { return nil }
        return read(name, cancelled: cancelled)
    }

    /// A saved section normally stays as first written, so that two processes saving the same
    /// analysis agree. `replacing` is for levels measured from PCM extracted a moment ago,
    /// which supersede a copy that an earlier extraction of the stream left behind.
    public func saveTranscriptActivity(_ data: Data, key: TranscriptActivityKey, media: MediaInfo,
                                       replacing: Bool = false,
                                       cancelled: () -> Bool = { Task.isCancelled }) throws {
        let name = try Self.transcriptActivitySection(key)
        guard media.identity.matchesSnapshot(identity), let evidence = media.refreshEvidence else {
            throw transcriptError("Fully indexed stream evidence is required to cache transcript results.",
                                  code: "missing_stream_evidence")
        }
        try transact([Self.evidenceKey: evidence.encoded()],
                     updating: [name: { previous in replacing ? data : previous ?? data }],
                     cancelled: cancelled) { _, _ in }
    }
}
