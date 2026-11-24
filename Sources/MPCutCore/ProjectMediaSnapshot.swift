import Foundation

/// Media descriptions and evidence for an archive. Snapshots are independent of edit history.
public struct ProjectMediaSnapshot: Codable, Equatable, Sendable {
    public static let empty = Self()
    private static let version = 1
    static let maximumBytes = 4 * 1024 * 1024
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case version, entries }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.version else {
            self = .empty
            return
        }
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_cut_project")
        entries = try values.decode([Entry].self, forKey: .entries)
        guard Set(entries.map(\.path)).count == entries.count else {
            throw CutError(code: "invalid_cut_project", message: "Duplicate path in media snapshot.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.version, forKey: .version)
        try values.encode(entries, forKey: .entries)
    }

    public func mappingPaths(_ transform: (String) -> String) -> Self {
        var mapped: [Entry] = []
        var indices: [String: Int] = [:]
        for var entry in entries {
            entry.path = transform(entry.path)
            entry.previousPath = entry.previousPath.map(transform)
            if let index = indices[entry.path] {
                mapped[index] = mapped[index].coalescingAlias(entry)
            } else {
                indices[entry.path] = mapped.count
                mapped.append(entry)
            }
        }
        return Self(entries: mapped)
    }

    public func rebased(from source: URL, to destination: URL) -> Self {
        rebased(from: source, to: destination, makeRelative: false)
    }

    package func rebased(from source: URL, to destination: URL, makeRelative: Bool) -> Self {
        guard makeRelative || ProjectFile.directory(of: source) != ProjectFile.directory(of: destination) else {
            return self
        }
        return mappingPaths { path in
            CutProject.relativeMediaPath(CutProject.mediaURL(path, relativeTo: source).path, to: destination)
        }
    }

    /// Keep saved information for offline paths and replace descriptions with newly inspected data.
    public func merging(_ newer: Self) -> Self {
        var byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for var entry in newer.entries {
            if let previous = byPath[entry.path] {
                if let digest = entry.stillSHA256, digest == previous.stillSHA256 {
                    entry.size = entry.size ?? previous.size
                    entry.modifiedSeconds = entry.modifiedSeconds ?? previous.modifiedSeconds
                    entry.modifiedNanoseconds = entry.modifiedNanoseconds ?? previous.modifiedNanoseconds
                    entry.width = entry.width ?? previous.width
                    entry.height = entry.height ?? previous.height
                }
                entry.unknownFields = previous.unknownFields.merging(entry.unknownFields) { _, new in new }
                if entry.previousPath == nil, entry.relinkUses == nil {
                    entry.previousPath = previous.previousPath
                    entry.relinkUses = previous.relinkUses
                }
                entry.ignored = entry.ignored ?? previous.ignored
            }
            byPath[entry.path] = entry
        }
        return Self(entries: byPath.values.sorted { $0.path < $1.path })
    }

    package func merging(media: [(path: String, media: MediaInfo)], stills: [Entry] = []) -> Self {
        let saved = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let refreshed = media.compactMap { path, media -> Entry? in
            if media.isFromSavedIndex || media.hasProvisionalClock, media.snapshotEvidence == nil,
               let previous = saved[path], previous.hasCompleteProof,
               previous.sourceFingerprint == media.identity.transcriptFingerprint {
                // A provisional or cached index cannot replace the proof
                // originally obtained by probing the expected generation.
                return nil
            }
            return Entry(path: path, media: media)
        }
        return merging(Self(entries: refreshed + stills))
    }

    /// Preserve the existing history selection and append only whole entries that fit.
    func appending(to base: Data, current: Set<String>, retained: Set<String>, byteLimit: Int) throws -> Data {
        guard !entries.isEmpty else { return base }
        // The compact on-disk layout can leave substantially more space than
        // the expanded history bytes used to select steps.
        let mayCompact = !ProjectSavedLayout.prefersExpanded && byteLimit == MulticamProject.maximumFileSize
        let base = mayCompact ? ProjectSavedLayout.compacted(base) ?? base : base
        let prefix = Data(",\"media_snapshot\":{\"version\":\(Self.version),\"entries\":[".utf8)
        let suffix = Data("]}}".utf8)
        let budget = min(Self.maximumBytes, byteLimit - base.count + 1) - prefix.count - suffix.count
        guard budget > 0, base.last == 0x7D else { return base }

        let ordered = entries.filter { current.contains($0.path) || retained.contains($0.path) }.sorted {
            let firstCurrent = current.contains($0.path)
            let secondCurrent = current.contains($1.path)
            return firstCurrent == secondCurrent ? $0.path < $1.path : firstCurrent
        }
        var payload = Data()
        var seen = Set<String>()
        for entry in ordered where seen.insert(entry.path).inserted {
            let bytes = try ProjectFile.encoded(entry, compact: true)
            let separator = payload.isEmpty ? 0 : 1
            guard bytes.count + separator <= budget - payload.count else { continue }
            if separator > 0 { payload.append(0x2C) }
            payload.append(bytes)
        }
        guard !payload.isEmpty else { return base }
        var result = base
        result.removeLast()
        result.append(prefix)
        result.append(payload)
        result.append(suffix)
        return result
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public internal(set) var size: Int64?
        public internal(set) var modifiedSeconds: Int?
        public internal(set) var modifiedNanoseconds: Int?
        public internal(set) var duration: RationalTime?
        public internal(set) var origin: RationalTime?
        public internal(set) var frameRate: RationalTime?
        public internal(set) var width: Int?
        public internal(set) var height: Int?
        public internal(set) var streams: [Stream]?
        public internal(set) var sourceClock: SourceClock?
        public internal(set) var sourceFingerprint: String?
        public internal(set) var stillSHA256: String?
        public var previousPath: String?
        public var relinkUses: [String]?
        public var ignored: Bool?
        var evidence: MediaRefreshEvidence.Content?
        var unknownFields: [String: TranscriptJSONValue] = [:]

        public struct Stream: Codable, Equatable, Sendable {
            public let index: Int
            public let kind: String
            public let codec: String
            public let channels: Int
            public let language: String
            public var channelLayout: String? = nil
            public var name: String? = nil

            enum CodingKeys: String, CodingKey {
                case index, kind, codec, channels, language, name
                case channelLayout = "channel_layout"
            }
        }

        public struct SourceClock: Codable, Equatable, Sendable {
            public let kind: MulticamSync.StampKind
            public let start: RationalTime
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case path, size, duration, origin, width, height, streams, evidence, ignored
            case modifiedSeconds = "modified_seconds"
            case modifiedNanoseconds = "modified_nanoseconds"
            case frameRate = "frame_rate"
            case sourceClock = "source_clock"
            case sourceFingerprint = "source_fingerprint"
            case stillSHA256 = "still_sha256"
            case previousPath = "previous_path"
            case relinkUses = "relink_uses"
        }

        public init(path: String) { self.path = path }

        public init(path: String, media: MediaInfo) {
            self.init(path: path)
            size = media.identity.size
            modifiedSeconds = media.identity.modifiedSeconds
            modifiedNanoseconds = media.identity.modifiedNanoseconds
            duration = (try? media.duration.subtracting(media.multicamClockOffset)) ?? media.duration
            origin = media.multicamClockOffset > .zero ? media.multicamClockOffset : media.origin
            frameRate = media.videoStream?.frameRate
            width = media.videoStream?.displayWidth
            height = media.videoStream?.displayHeight
            streams = media.streams.map {
                Stream(index: $0.index, kind: $0.kind, codec: $0.codec, channels: $0.channels, language: $0.language,
                       channelLayout: $0.kind == "audio" ? $0.canonicalChannelLayout : nil, name: $0.name)
            }
            sourceClock = media.snapshotSourceClock
            if let proof = media.snapshotEvidence {
                evidence = proof.content
                sourceFingerprint = proof.identity.transcriptFingerprint
            }
        }

        public init?(path: String, asset: StillAsset) {
            guard !asset.isGap, TranscriptStore.validDigest(asset.fingerprint) else { return nil }
            self.init(path: path)
            stillSHA256 = asset.fingerprint
        }

        public var hasCompleteProof: Bool { evidence?.hasCompleteProof == true && sourceFingerprint != nil }

        func coalescingAlias(_ other: Self) -> Self {
            // A proof and its generation fingerprint travel together. When two
            // spellings collapse, favor the entry with actual content evidence.
            let preferOther = (!hasCompleteProof && other.hasCompleteProof) ||
                (stillSHA256 == nil && other.stillSHA256 != nil && !hasCompleteProof)
            var entry = preferOther ? other : self
            let alternate = preferOther ? self : other
            entry.unknownFields = alternate.unknownFields.merging(entry.unknownFields) { _, preferred in preferred }
            entry.ignored = entry.ignored ?? alternate.ignored
            // Independent spellings may have independently authored uses. A
            // reverse map is safe only when the provenance already agrees.
            if entry.previousPath != alternate.previousPath || entry.relinkUses != alternate.relinkUses {
                entry.previousPath = nil
                entry.relinkUses = nil
            }
            return entry
        }

        public func verifies(_ media: MediaInfo) -> Bool {
            guard hasCompleteProof, let candidate = media.snapshotEvidence,
                  candidate.identity.isCurrentSnapshot(at: media.url) else { return false }
            return candidate.content == evidence
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = try values.decode(String.self, forKey: .path)
            size = try values.decodeIfPresent(Int64.self, forKey: .size)
            modifiedSeconds = try values.decodeIfPresent(Int.self, forKey: .modifiedSeconds)
            modifiedNanoseconds = try values.decodeIfPresent(Int.self, forKey: .modifiedNanoseconds)
            duration = try values.decodeIfPresent(RationalTime.self, forKey: .duration)
            origin = try values.decodeIfPresent(RationalTime.self, forKey: .origin)
            frameRate = try values.decodeIfPresent(RationalTime.self, forKey: .frameRate)
            width = try values.decodeIfPresent(Int.self, forKey: .width)
            height = try values.decodeIfPresent(Int.self, forKey: .height)
            streams = try values.decodeIfPresent([Stream].self, forKey: .streams)
            sourceClock = try values.decodeIfPresent(SourceClock.self, forKey: .sourceClock)
            sourceFingerprint = try values.decodeIfPresent(String.self, forKey: .sourceFingerprint)
            stillSHA256 = try values.decodeIfPresent(String.self, forKey: .stillSHA256)
            previousPath = try values.decodeIfPresent(String.self, forKey: .previousPath)
            relinkUses = try values.decodeIfPresent([String].self, forKey: .relinkUses)
            ignored = try values.decodeIfPresent(Bool.self, forKey: .ignored)
            evidence = try values.decodeIfPresent(MediaRefreshEvidence.Content.self, forKey: .evidence)
            let all = try decoder.container(keyedBy: ProjectField.self)
            for key in all.allKeys where CodingKeys(stringValue: key.stringValue) == nil {
                unknownFields[key.stringValue] = try all.decode(TranscriptJSONValue.self, forKey: key)
            }
            guard ProjectFile.validMediaPath(path), previousPath.map(ProjectFile.validMediaPath) ?? true,
                  stillSHA256.map(TranscriptStore.validDigest) ?? true,
                  sourceFingerprint.map(TranscriptStore.validDigest) ?? true else {
                throw CutError(code: "invalid_cut_project", message: "Invalid path or fingerprint in media snapshot.")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(path, forKey: .path)
            try values.encodeIfPresent(size, forKey: .size)
            try values.encodeIfPresent(modifiedSeconds, forKey: .modifiedSeconds)
            try values.encodeIfPresent(modifiedNanoseconds, forKey: .modifiedNanoseconds)
            try values.encodeIfPresent(duration, forKey: .duration)
            try values.encodeIfPresent(origin, forKey: .origin)
            try values.encodeIfPresent(frameRate, forKey: .frameRate)
            try values.encodeIfPresent(width, forKey: .width)
            try values.encodeIfPresent(height, forKey: .height)
            try values.encodeIfPresent(streams, forKey: .streams)
            try values.encodeIfPresent(sourceClock, forKey: .sourceClock)
            try values.encodeIfPresent(sourceFingerprint, forKey: .sourceFingerprint)
            try values.encodeIfPresent(stillSHA256, forKey: .stillSHA256)
            try values.encodeIfPresent(previousPath, forKey: .previousPath)
            try values.encodeIfPresent(relinkUses, forKey: .relinkUses)
            try values.encodeIfPresent(ignored, forKey: .ignored)
            try values.encodeIfPresent(evidence, forKey: .evidence)
            var all = encoder.container(keyedBy: ProjectField.self)
            for (key, value) in unknownFields {
                try all.encode(value, forKey: ProjectField(stringValue: key))
            }
        }
    }
}
