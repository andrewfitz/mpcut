import Foundation
import MediaProbe

public enum MulticamSync {
    public static let waveformResolution = RationalTime(numerator: 1, denominator: Int64(AudioWaveform.rate))

    public enum StampKind: String, Codable, Sendable {
        case timecode
        case broadcastWave = "broadcast_wave"
    }

    public struct Stamp: Encodable, Sendable {
        public let kind: StampKind
        /// Timestamp at source clock zero.
        public let start: RationalTime
    }

    public struct Match: Encodable, Sendable {
        public let referenceTime: RationalTime
        public let offset: RationalTime
        public let correlation: Double
    }

    public struct Suggestion: Encodable, Sendable {
        public let sourceID: String
        public let currentOffset: RationalTime
        public let stamp: Stamp?
        public let metadataOffset: RationalTime?
        public let metadataIssue: String?
        public let audioStream: Int?
        public let waveformOffset: RationalTime?
        public let waveformIssue: String?
        public let matches: [Match]
        public let drift: RationalTime?
    }

    public struct Report: Encodable, Sendable {
        public let ok = true
        public let referenceSourceID: String
        public let referenceStamp: Stamp?
        public let referenceAudioStream: Int?
        public let waveformRequested: Bool
        public let suggestions: [Suggestion]
    }

    /// A draft recording and the exact scratch and incoming streams to compare.
    public struct ReplacementRequest: Sendable {
        public let referenceSourceID: String
        public let referenceStream: Int?
        public let source: MulticamSource
        public let stream: Int
        public let seed: RationalTime?
        public let referenceRanges: [MulticamRange]?

        public init(reference: MulticamAudioSelection, source: MulticamSource, stream: Int,
                    seed: RationalTime? = nil, referenceRanges: [MulticamRange]? = nil) {
            self.init(referenceSourceID: reference.source, referenceStream: reference.stream, source: source,
                      stream: stream, seed: seed, referenceRanges: referenceRanges)
        }

        public init(referenceSourceID: String, referenceStream: Int?, source: MulticamSource, stream: Int,
                    seed: RationalTime? = nil, referenceRanges: [MulticamRange]? = nil) {
            self.referenceSourceID = referenceSourceID
            self.referenceStream = referenceStream
            self.source = source
            self.stream = stream
            self.seed = seed
            self.referenceRanges = referenceRanges
        }
    }

    public static func analyzeReplacement(
        _ project: MulticamProject, request: ReplacementRequest, relativeTo location: URL?,
        indexed: [String: MediaInfo] = [:], waveform: Bool = true, useSidecar: Bool = true,
        cancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> Report {
        try analyzeReplacement(project, request: request, relativeTo: location, indexed: indexed,
                               waveform: waveform, useSidecar: useSidecar, cachedReferenceWaveform: nil,
                               cancelled: cancelled)
    }

    package static func analyzeReplacement(
        _ project: MulticamProject, request: ReplacementRequest, relativeTo location: URL?,
        indexed: [String: MediaInfo], waveform: Bool = true, useSidecar: Bool,
        cachedReferenceWaveform: AudioWaveform?, cancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> Report {
        try analyze(project, relativeTo: location, indexed: indexed, sourceID: request.source.id,
                    referenceSourceID: request.referenceSourceID, waveform: waveform, useSidecar: useSidecar,
                    cancelled: cancelled, replacement: request, cachedReferenceWaveform: cachedReferenceWaveform)
    }

    public static func analyze(_ project: MulticamProject, relativeTo location: URL?, indexed: [String: MediaInfo] = [:],
                               sourceID: String? = nil, referenceSourceID: String? = nil,
                               waveform: Bool = true, useSidecar: Bool = true,
                               cancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }) throws -> Report {
        try analyze(project, relativeTo: location, indexed: indexed, sourceID: sourceID,
                    referenceSourceID: referenceSourceID, waveform: waveform, useSidecar: useSidecar,
                    cancelled: cancelled, replacement: nil, cachedReferenceWaveform: nil)
    }

    private static func analyze(_ project: MulticamProject, relativeTo location: URL?, indexed: [String: MediaInfo],
                                sourceID: String?, referenceSourceID: String?, waveform: Bool, useSidecar: Bool,
                                cancelled: @escaping @Sendable () -> Bool, replacement: ReplacementRequest?,
                                cachedReferenceWaveform: AudioWaveform?) throws -> Report {
        let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar)
        let referenceID = referenceSourceID ?? project.referenceAngle
        let references = replacement == nil ? project.recordings(for: project.referenceAngle) : project.pictureSources
        guard let reference = references.first(where: { $0.id == referenceID }) else {
            let message = replacement == nil ? "Choose a recording on the reference camera." : "Choose a camera recording."
            throw CutError(code: "invalid_sync_reference", message: message)
        }
        let boundSources = Set(project.audioReplacements.map { $0.replacement.source })
        let targets = replacement.map { [$0.source] } ?? project.sources.filter {
            $0.id != reference.id && !boundSources.contains($0.id) && (sourceID == nil || $0.id == sourceID)
        }
        guard sourceID == nil || !targets.isEmpty else {
            throw CutError(code: "invalid_sync_target", message: "Choose a source other than the reference recording.")
        }
        func checkCancellation() throws {
            if cancelled() { throw CancellationError() }
        }
        func load(_ source: MulticamSource) throws -> MediaInfo {
            try checkCancellation()
            if let media = indexed[source.id] {
                try AnalysisSidecar(media: media).checkSource()
                return try engine.multicamClock(media)
            }
            let absolute = source.file.hasPrefix("/") ? URL(fileURLWithPath: source.file) : nil
            guard let url = location.map({ project.sourceURL(for: source, relativeTo: $0) }) ?? absolute else {
                throw CutError(code: "missing_source", message: "No media is available for \(source.name ?? source.file).")
            }
            do {
                return try engine.multicamClock(engine.inspectForPreview(url))
            } catch let issue as CutError where issue.code == "probe_failed" {
                // Some containers need packet inspection to establish the picture clock.
                return try engine.inspectMulticamSource(url)
            }
        }
        func peaks(_ media: MediaInfo, _ stream: Int?, cached: AudioWaveform? = nil)
            throws -> (samples: [Float], track: AudioIndex?)? {
            guard waveform, let stream else { return nil }
            let indexed = try media.hasFullEditIndex ? media : engine.inspectMulticamSource(media.url)
            guard indexed.identity == media.identity else {
                throw CutError(code: "source_changed", message: "The source changed during sync analysis.")
            }
            let track = indexed.audio.first { $0.stream.index == stream }
            if let cached, cached.matches(indexed, stream: stream) {
                try checkCancellation()
                try AnalysisSidecar(media: indexed).checkSource()
                return (cached.syncPeaks, track)
            }
            let wave = try AudioAnalysis.scan(indexed, stream: stream, useSidecar: useSidecar, cancelled: cancelled)
            return (wave.syncPeaks, track)
        }

        let referenceMedia = try load(reference)
        let referenceStream: Int?
        if let replacement {
            referenceStream = replacement.referenceStream.flatMap { audioStream(reference, media: referenceMedia, explicit: $0) }
            if replacement.referenceStream != nil, referenceStream == nil {
                throw CutError(code: "invalid_sync_reference", message: "The selected scratch stream is unavailable.")
            }
        } else {
            referenceStream = audioStream(reference, media: referenceMedia, explicit: nil)
        }
        let referenceStamp = try? stamp(referenceMedia, preferredStream: replacement?.referenceStream)
        let referenceWave = Result<(samples: [Float], track: AudioIndex?)?, Error> {
            guard !targets.isEmpty else { return nil }
            return try peaks(referenceMedia, referenceStream, cached: cachedReferenceWaveform)
        }
        var matcher: Matcher?

        let suggestions = try targets.map { source -> Suggestion in
            try checkCancellation()
            let media: MediaInfo
            do {
                media = try load(source)
            } catch {
                try checkCancellation()
                return Suggestion(sourceID: source.id, currentOffset: source.offset, stamp: nil,
                                  metadataOffset: nil, metadataIssue: error.localizedDescription,
                                  audioStream: nil, waveformOffset: nil, waveformIssue: nil, matches: [], drift: nil)
            }
            let targetStream = audioStream(source, media: media, explicit: replacement?.stream)
            if replacement != nil, targetStream == nil {
                throw CutError(code: "invalid_sync_target", message: "The selected incoming stream is unavailable.")
            }
            let currentOffset = try replacement.map { try reference.offset.adding($0.seed ?? .zero) } ?? source.offset
            var stampIssue: String?
            let targetStamp: Stamp?
            do {
                targetStamp = try stamp(media, preferredStream: replacement?.stream)
            } catch {
                targetStamp = nil
                stampIssue = error.localizedDescription
            }
            var metadataOffset: RationalTime?
            if let referenceStamp, let targetStamp {
                do {
                    metadataOffset = try reference.offset.adding(targetStamp.start.subtracting(referenceStamp.start))
                    if referenceStamp.kind != targetStamp.kind {
                        stampIssue = "Confirm that the camera timecode and Broadcast Wave reference use the same time-of-day clock."
                    }
                } catch {
                    stampIssue = error.localizedDescription
                }
            } else if stampIssue == nil {
                stampIssue = "Both sources need timecode or Broadcast Wave time-reference metadata."
            }
            var matches: [Match] = []
            var independentSeparation = 30.0
            var waveIssue: String?
            var scratchTrack: AudioIndex?
            var incomingTrack: AudioIndex?
            if waveform {
                do {
                    if let scratch = try referenceWave.get(), let incoming = try peaks(media, targetStream) {
                        let referencePeaks = scratch.samples
                        let target = incoming.samples
                        scratchTrack = scratch.track
                        incomingTrack = incoming.track
                        let current = try currentOffset.subtracting(reference.offset)
                        let baseline = try metadataOffset?.subtracting(reference.offset)
                        if replacement != nil {
                            independentSeparation = Double(waveformWindow(referenceCount: referencePeaks.count,
                                                                          targetCount: target.count,
                                                                          referenceRanges: replacement?.referenceRanges))
                                / Double(AudioWaveform.rate)
                        }
                        if matcher == nil { matcher = Matcher(referencePeaks) }
                        matches = try matcher?.match(target, referenceOffset: reference.offset,
                                                     baselines: replacement?.seed == nil ? [baseline, current].compactMap { $0 } : [current],
                                                     referenceRanges: replacement?.referenceRanges,
                                                     cancelled: cancelled) ?? []
                        if matches.isEmpty {
                            waveIssue = replacement?.seed == nil
                                ? "No distinct waveform match was found near the existing or metadata offset."
                                : "No distinct waveform match was found within 30 seconds of the selected alignment."
                        }
                    } else {
                        waveIssue = "Both sources need a usable audio stream."
                    }
                } catch {
                    try checkCancellation()
                    waveIssue = error.localizedDescription
                }
            }
            // Drift needs separate windows at both ends of the audible retained overlap.
            var drift: RationalTime?
            if let first = matches.first, let last = matches.last {
                let separation = try last.referenceTime.subtracting(first.referenceTime)
                let change = try last.offset.subtracting(first.offset)
                let incomingSeparation = try separation.subtracting(change)
                if separation.seconds >= independentSeparation,
                   replacement == nil || incomingSeparation.seconds >= independentSeparation {
                    let used = replacement?.referenceRanges
                    let measuredEnds: Bool
                    if used == nil {
                        measuredEnds = true
                    } else if let used, let scratchTrack, let incomingTrack {
                        let scratch = try replacementCoverage(in: used, track: scratchTrack, relativeOffset: .zero)
                        let offset = try first.offset.subtracting(reference.offset)
                        let overlap = try replacementCoverage(in: scratch.overlap, track: incomingTrack, relativeOffset: offset)
                        if let opening = overlap.overlap.first, let closing = overlap.overlap.last {
                            let distanceFromStart = try first.referenceTime.subtracting(opening.from)
                            let distanceFromEnd = try closing.to.subtracting(last.referenceTime)
                            measuredEnds = opening.contains(first.referenceTime) && closing.contains(last.referenceTime) &&
                                distanceFromStart.seconds <= independentSeparation && distanceFromEnd.seconds <= independentSeparation
                        } else {
                            measuredEnds = false
                        }
                    } else {
                        measuredEnds = false
                    }
                    if measuredEnds { drift = change }
                }
            }
            return Suggestion(sourceID: source.id, currentOffset: currentOffset, stamp: targetStamp,
                              metadataOffset: metadataOffset, metadataIssue: stampIssue, audioStream: targetStream,
                              waveformOffset: matches.first?.offset, waveformIssue: waveIssue, matches: matches, drift: drift)
        }
        try checkCancellation()
        return Report(referenceSourceID: reference.id, referenceStamp: referenceStamp,
                      referenceAudioStream: referenceStream, waveformRequested: waveform, suggestions: suggestions)
    }

    private static func audioStream(_ source: MulticamSource, media: MediaInfo, explicit: Int?) -> Int? {
        let tracks = media.streams.filter { $0.kind == "audio" && $0.sampleRate > 0 }
        if let index = explicit ?? source.audioStream { return tracks.first(where: { $0.index == index })?.index }
        return tracks.first?.index
    }

    static func stamp(_ media: MediaInfo, preferredStream: Int? = nil) throws -> Stamp? {
        let source = AnalysisSidecar(media: media)
        try source.checkSource()
        let primary = media.primaryStream
        let audio = media.streams.first {
            $0.kind == "audio" && $0.sampleRate > 0 && (preferredStream == nil || $0.index == preferredStream)
        }
        var result: Stamp?
        if let audio, preferredStream != nil { result = try stamp(media, track: audio) }
        if result == nil, preferredStream == nil || primary.kind == "video" {
            result = try stamp(media, track: primary)
        }
        if result == nil, preferredStream == nil, primary.kind == "video", let audio {
            result = try stamp(media, track: audio)
        }
        try source.checkSource()
        return result
    }

    private static func stamp(_ media: MediaInfo, track: StreamInfo) throws -> Stamp? {
        var units: Int64 = 0
        var numerator: Int32 = 1, denominator: Int32 = 1
        let status = mp_source_sync_stamp(media.url.path, Int32(track.index),
                                         Int32(exactly: track.frameRate.numerator) ?? 0,
                                         Int32(exactly: track.frameRate.denominator) ?? 0,
                                         &units, &numerator, &denominator)
        if status == 0 { return nil }
        guard status > 0, status != MP_SOURCE_SYNC_BWF || units >= 0 else {
            throw CutError(code: "invalid_sync_metadata", message: "Unable to read sync metadata from \(media.url.lastPathComponent).")
        }
        let start = try RationalTime(numerator: units, denominator: Int64(denominator))
            .multiplied(by: RationalTime(numerator: Int64(numerator))).subtracting(track.start)
        return Stamp(kind: status == MP_SOURCE_SYNC_TIMECODE ? .timecode : .broadcastWave, start: start)
    }
}
