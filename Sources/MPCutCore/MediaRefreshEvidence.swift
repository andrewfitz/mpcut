import CFFmpeg
import CryptoKit
import Foundation
import MediaProbe

struct MediaRefreshEvidence: Codable, Sendable {
    static let sectionKey = "source.evidence.v1"

    struct Stream: Codable, Equatable, Sendable {
        let kind: String
        let trackID: Int
        let codec: String
        let payload: Data?
        let timing: Data?
        let packetLayout: Data?
        let codecTag: String
        let nativeMetadata: Data
        let sceneMetadata: Data
        let color: [String]
        let indexTraits: [String]
        let language: String
        let disposition: Int
        let configuration: Data
        let insertedPresentationEdits: Bool
        let channelLayout: String
        let channels: Int
        let sampleRate: Int
        let initialPadding: Int
        let trailingPadding: Int
        let seekPreroll: Int
        let start: RationalTime
        let duration: RationalTime
        let timeBase: RationalTime
        let audioStart: RationalTime?
        let audioEnd: RationalTime?
        let display: [String]

        var hasDeclaredPCMStart: Bool {
            let encodedDeclarationAndPCM = indexTraits.dropFirst().prefix(2)
            return audioStart == start && encodedDeclarationAndPCM.elementsEqual(["true", "true"])
        }

        func hasSamePayload(as other: Self) -> Bool {
            guard let payload else { return false }
            return kind == other.kind && configuration == other.configuration && payload == other.payload
        }

        func hasSameContent(as other: Self) -> Bool {
            guard let timing else { return false }
            return hasSamePayload(as: other) && timing == other.timing
        }

        func hasSameAudioInput(as other: Self) -> Bool {
            hasSameContent(as: other) && start == other.start && initialPadding == other.initialPadding &&
                trailingPadding == other.trailingPadding && seekPreroll == other.seekPreroll &&
                channelLayout == other.channelLayout && channels == other.channels && sampleRate == other.sampleRate &&
                audioStart == other.audioStart && audioEnd == other.audioEnd &&
                insertedPresentationEdits == other.insertedPresentationEdits
        }
    }

    let identity: SourceIdentity
    let format: String
    let origin: RationalTime
    let duration: RationalTime
    let videoIndex: Int
    let indexIssues: [String]
    let streams: [Stream]
    var reviewStreams: [Int]?
    var pictureNeedsReview: Bool?

    init(identity: SourceIdentity, format: String, origin: RationalTime, duration: RationalTime,
         videoIndex: Int, streams: [StreamInfo], audio: [AudioIndex], indexIssues: [String],
         native: UnsafeBufferPointer<MPProbeStream>) {
        self.identity = identity
        self.format = format
        self.origin = origin
        self.duration = duration
        self.videoIndex = videoIndex
        self.indexIssues = indexIssues
        let audioByIndex = Dictionary(uniqueKeysWithValues: audio.map { ($0.stream.index, $0) })
        self.streams = streams.map { stream in
            let nativeStream = native[stream.index]
            let evidenceAvailable = nativeStream.has_payload_evidence != 0 && !stream.multipleDescriptions
            let indexedAudio = audioByIndex[stream.index]
            // The packet digest already contains the initial extradata and any
            // in-band configuration changes. Compare stream descriptions too.
            var hash = SHA256()
            hash.update(data: stream.configuration)
            hash.update(data: Data([0]))
            let description = [stream.codec, String(stream.width), String(stream.height), String(stream.profile),
                               stream.pixelFormat, String(stream.alphaBits), String(stream.hasAdditionalVideoLayers),
                               String(stream.bitDepth), stream.fieldOrder]
            hash.update(data: Data(description.joined(separator: "\0").utf8))
            return Stream(
                kind: stream.kind, trackID: Int(stream.trackID), codec: stream.codec,
                payload: evidenceAvailable ? withUnsafeBytes(of: nativeStream.payload_digest) { Data($0) } : nil,
                timing: evidenceAvailable ? withUnsafeBytes(of: nativeStream.timing_digest) { Data($0) } : nil,
                packetLayout: evidenceAvailable ? withUnsafeBytes(of: nativeStream.layout_digest) { Data($0) } : nil,
                codecTag: stream.codecTag, nativeMetadata: Data(SHA256.hash(data: stream.codecMetadata)),
                sceneMetadata: Self.metadataForSceneDetection(stream.codecMetadata),
                color: [stream.colorPrimaries, stream.colorTransfer, stream.colorMatrix, stream.colorRange, stream.chromaLocation],
                indexTraits: [stream.frameRate.description, String(stream.hasDeclaredStart), String(stream.isPCM),
                              String(stream.complexPicture), String(stream.reconstructedDTS)],
                language: stream.language, disposition: stream.disposition,
                configuration: Data(hash.finalize()),
                insertedPresentationEdits: !(indexedAudio?.presentationEdits.isEmpty ?? true),
                channelLayout: stream.channelLayout, channels: stream.channels, sampleRate: stream.sampleRate,
                initialPadding: stream.initialPadding, trailingPadding: stream.trailingPadding,
                seekPreroll: stream.seekPreroll, start: stream.start, duration: stream.duration, timeBase: stream.timeBase,
                audioStart: indexedAudio?.start, audioEnd: indexedAudio?.end,
                display: [String(stream.displayWidth), String(stream.displayHeight), String(stream.rotation),
                          String(stream.rotationOnly), stream.sampleAspectRatio.description]
            )
        }
    }

    private static func metadataForSceneDetection(_ data: Data) -> Data {
        // Scene descriptors use the decoded picture as stored. The display
        // matrix and sample aspect ratio matter to thumbnails only.
        data.withUnsafeBytes { buffer in
            var hash = SHA256()
            var offset = 0
            while buffer.count - offset >= 8 {
                let type = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let size = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                guard size <= buffer.count - offset - 8 else { return Data(SHA256.hash(data: data)) }
                let end = offset + 8 + Int(size)
                if type != UInt32(AV_PKT_DATA_DISPLAYMATRIX.rawValue) {
                    hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[offset..<end]))
                }
                offset = end
            }
            guard offset == buffer.count else { return Data(SHA256.hash(data: data)) }
            return Data(hash.finalize())
        }
    }

    static func decode(_ data: Data?) -> Self? {
        data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    var hasCompleteProof: Bool {
        streams.filter { $0.kind == "audio" || $0.kind == "video" }.allSatisfy { $0.payload != nil }
    }

    func hasSameObservedInputs(as old: Self) -> Bool {
        duration == old.duration && origin == old.origin && videoIndex == old.videoIndex &&
            format == old.format && indexIssues == old.indexIssues && streams == old.streams
    }

    func verifiesSameFileContents(as old: Self) -> Bool {
        hasCompleteProof && hasSameObservedInputs(as: old)
    }

    struct Comparison {
        var scenes = false
        var audio = Set<Int>()
        var review = Set<Int>()
        var displayChanged = true
        var audioRoutes = Set<Int>()
        var pictureNeedsReview = false

        var verifiedThresholdStreams: Set<Int> { audioRoutes.subtracting(review) }

        func preservedSectionKeys(_ keys: Set<String>) -> Set<String> {
            Set(keys.filter { key in
                if key == AnalysisSidecar.sceneSectionKey || key == AnalysisSidecar.viewNameSectionKey {
                    return scenes
                }
                if key.hasPrefix("filmstrip.v1.") { return !displayChanged }
                let stream = AnalysisSidecar.savedWaveformStream(forKey: key)
                    ?? AnalysisSidecar.savedEnvelopeStream(forKey: key)
                    ?? AnalysisSidecar.savedSilenceSettings(forKey: key)?.stream
                    ?? Self.calibrationStream(key)
                return stream.map(audio.contains) ?? false
            })
        }

        private static func calibrationStream(_ key: String) -> Int? {
            let prefix = "calibration.v1."
            guard key.hasPrefix(prefix), let stream = Int(key.dropFirst(prefix.count)), stream >= 0,
                  key == "\(prefix)\(stream)" else { return nil }
            return stream
        }
    }

    func compare(to old: Self) -> Comparison {
        var result = Comparison(review: Set(old.reviewStreams ?? []),
                                pictureNeedsReview: old.pictureNeedsReview ?? false)
        let clockMatches = origin == old.origin && duration == old.duration
        let exactlySameFile = verifiesSameFileContents(as: old)
        if old.videoIndex >= 0, videoIndex >= 0, old.videoIndex != videoIndex {
            result.review.insert(videoIndex)
        }
        for (index, previous) in old.streams.enumerated() where previous.kind == "audio" || index == old.videoIndex {
            let matchingPositions = streams.indices.filter { streams[$0].hasSamePayload(as: previous) }
            guard streams.indices.contains(index), streams[index].kind == previous.kind else {
                result.review.insert(index)
                result.review.formUnion(matchingPositions)
                continue
            }
            let current = streams[index]
            let requiresStableTrackID = format == old.format && previous.trackID > 0
            let previousCopies = old.streams.filter { $0.hasSamePayload(as: previous) }.count
            let currentMatchesOtherEarlierTrack = !current.hasSamePayload(as: previous) &&
                old.streams.indices.contains { $0 != index && old.streams[$0].hasSamePayload(as: current) }
            let hasCompetingTrack = streams.indices.contains { $0 != index && streams[$0].kind == previous.kind }
            let ambiguous = hasCompetingTrack && !exactlySameFile &&
                (matchingPositions.count > 1 || previousCopies > 1 ||
                 (!requiresStableTrackID && !matchingPositions.contains(index)))
            if (requiresStableTrackID && current.trackID != previous.trackID && !matchingPositions.contains(index)) ||
                (!matchingPositions.isEmpty && !matchingPositions.contains(index)) ||
                (index == old.videoIndex && index != videoIndex) || currentMatchesOtherEarlierTrack || ambiguous {
                result.review.insert(index)
                if !matchingPositions.contains(index) {
                    result.review.formUnion(matchingPositions)
                }
                continue
            }
            if previous.kind == "audio" {
                result.audioRoutes.insert(index)
                if clockMatches, current.hasSameAudioInput(as: previous) { result.audio.insert(index) }
            } else {
                let colorMatches = current.color == previous.color
                let displayMatches = current.display == previous.display && current.nativeMetadata == previous.nativeMetadata
                result.displayChanged = !current.hasSameContent(as: previous) || !displayMatches || !colorMatches || !clockMatches
                result.scenes = clockMatches && current.hasSameContent(as: previous) &&
                    current.timeBase == previous.timeBase && current.start == previous.start &&
                    colorMatches && current.sceneMetadata == previous.sceneMetadata
            }
        }
        if old.videoIndex >= 0 {
            result.pictureNeedsReview = result.pictureNeedsReview || old.videoIndex != videoIndex ||
                result.review.contains(old.videoIndex)
        }
        if old.videoIndex < 0, videoIndex < 0 { result.displayChanged = false }
        return result
    }
}
