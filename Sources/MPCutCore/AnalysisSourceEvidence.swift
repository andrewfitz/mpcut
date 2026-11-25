import Foundation

/// Evidence for the presentation samples underlying a saved editorial choice.
/// A full file digest covers streams for which the index has no packet evidence.
public struct AnalysisSourceEvidence: Codable, Equatable, Hashable, Sendable {
    private enum Method: String, Codable { case stream, file }
    private let method: Method
    public let stream: Int
    public let sha256: String

    private struct Payload: Encodable {
        let origin: RationalTime
        let kind: String
        let configuration: Data
        let payload: Data
        let timing: Data
        let start: RationalTime
        let timeBase: RationalTime
        let audio: Audio?
        let picture: Picture?

        struct Audio: Encodable {
            let channels: Int
            let channelLayout: String
            let sampleRate: Int
            let initialPadding: Int
            let trailingPadding: Int
            let seekPreroll: Int
            let start: RationalTime?
            let end: RationalTime?
            let presentationEdits: Bool
        }

        struct Picture: Encodable {
            let color: [String]
            let sceneMetadata: Data
        }

        init?(origin: RationalTime, stream: MediaRefreshEvidence.Stream) {
            guard let payload = stream.payload, let timing = stream.timing else { return nil }
            self.origin = origin
            self.payload = payload
            self.timing = timing
            kind = stream.kind
            configuration = stream.configuration
            start = stream.start
            timeBase = stream.timeBase
            audio = kind == "audio" ? Audio(channels: stream.channels, channelLayout: stream.channelLayout,
                sampleRate: stream.sampleRate, initialPadding: stream.initialPadding,
                trailingPadding: stream.trailingPadding, seekPreroll: stream.seekPreroll,
                start: stream.audioStart, end: stream.audioEnd, presentationEdits: stream.insertedPresentationEdits) : nil
            picture = kind == "video" ? Picture(color: stream.color, sceneMetadata: stream.sceneMetadata) : nil
        }
    }

    private struct Key: Hashable {
        let identity: SourceIdentity
        let changeTime: SourceIdentity.ChangeTime
        let stream: Int
        let method: Method
    }

    private final class DigestCache: @unchecked Sendable {
        static let shared = DigestCache()
        private let lock = NSLock()
        private var values: [Key: String] = [:]

        func value(_ key: Key, calculate: () -> String?) -> String? {
            lock.lock()
            let saved = values[key]
            lock.unlock()
            if let saved { return saved }
            guard let computed = calculate() else { return nil }
            lock.lock()
            if values.count >= 1024 { values.removeAll(keepingCapacity: true) }
            values[key] = computed
            lock.unlock()
            return computed
        }
    }

    package init?(media: MediaInfo, stream: Int) {
        guard media.streams.contains(where: { $0.index == stream }), media.identity.isCurrentSnapshot(at: media.url) else { return nil }
        self.stream = stream
        if let digest = Self.digest(media, stream: stream, method: .stream, probe: false) {
            method = .stream
            sha256 = digest
        } else if let digest = Self.digest(media, stream: stream, method: .file, probe: false) {
            method = .file
            sha256 = digest
        } else {
            return nil
        }
    }

    package func matches(_ media: MediaInfo) -> Bool {
        guard media.streams.contains(where: { $0.index == stream }), media.identity.isCurrentSnapshot(at: media.url) else { return false }
        return Self.digest(media, stream: stream, method: method, probe: true) == sha256
    }

    private static func digest(_ media: MediaInfo, stream: Int, method: Method, probe: Bool) -> String? {
        guard let changeTime = media.identity.changeTime else { return nil }
        let key = Key(identity: media.identity, changeTime: changeTime, stream: method == .file ? -1 : stream, method: method)
        return DigestCache.shared.value(key) {
            if method == .file { return try? participantSourceDigest(media.url, identity: media.identity) }
            func streamDigest(_ input: MediaInfo) -> String? {
                guard let evidence = input.refreshEvidence, evidence.identity.changeTime == changeTime,
                      evidence.identity == media.identity, evidence.streams.indices.contains(stream) else { return nil }
                guard let input = Payload(origin: evidence.origin, stream: evidence.streams[stream]) else { return nil }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                return (try? encoder.encode(input)).map(TranscriptStore.digest)
            }
            if let value = streamDigest(media) { return value }
            guard probe, let fresh = try? CutEngine(useSidecar: false).inspect(media.url, keyframes: true),
                  fresh.identity.matchesSnapshot(media.identity) else { return nil }
            return streamDigest(fresh)
        }
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_analysis_annotations")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        method = try values.decode(Method.self, forKey: .method)
        stream = try values.decode(Int.self, forKey: .stream)
        sha256 = try values.decode(String.self, forKey: .sha256)
        guard stream >= 0, TranscriptStore.validDigest(sha256) else {
            throw CutError(code: "invalid_analysis_annotations", message: "Invalid saved analysis source evidence.")
        }
    }
}
