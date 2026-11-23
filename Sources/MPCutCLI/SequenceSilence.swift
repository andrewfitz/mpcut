import Foundation
import MPCutCore

struct SequencePauseRow: Encodable {
    let id: String
    let clipID: String
    let stream: Int
    let thresholdDB: Double
    let source: AudioSpan
    let sequence: AudioSpan
    let protected: Bool
    let removal: AudioSpan?
    let requestedRetainedSeconds: Double?
    let retainedSeconds: Double
}

struct SequenceSilenceResult: Encodable {
    let ok = true
    let projectPath: String
    let pauses: [SequencePauseRow]
    let takeCandidates: [AudioSpan]
    let duration: RationalTime
    let removedDuration: RationalTime
    let retainedDuration: RationalTime
    var outProject: String?
}

func sequenceSilence(project: CutProject, location: URL, path: String, options: SilenceOptions,
                     output: URL?, interruption: Interruption) throws -> (CutProject, SequenceSilenceResult) {
    let engine = CutEngine(cancelled: { !interruption.isActive }, smartTrim: options.mode != .copy)
    var indexed: [URL: MediaInfo] = [:]
    struct Scan {
        let pauses: [AudioSpan]
        let threshold: Double
        let protections: [AudioSpan]
    }
    var scans: [URL: [Int: Scan]] = [:]
    var boundaries: [URL: (ends: [RationalTime], starts: [RationalTime])] = [:]
    var containers: [URL: String] = [:]
    var protectionCache = TranscriptPauseProtectionCache()
    let authored = protectionCache.resolve(project.transcripts, relativeTo: location)
    var cursor = RationalTime.zero, removed = RationalTime.zero
    var rows: [SequencePauseRow] = []
    var outputRemovals: [AudioSpan] = []
    let needsEdits = options.outProject != nil || output != nil
    let outputContainer = output?.pathExtension.lowercased()
    var sourceRemovals: [String: [AudioSpan]] = [:]
    for item in project.sequenceItems ?? [] {
        try interruption.check()
        if let card = item.still { cursor = try cursor.adding(card.duration); continue }
        guard let clip = item.source else { continue }
        let bounds = AudioSpan(from: clip.from, to: clip.to)
        let start = cursor
        cursor = try cursor.adding(clip.to.subtracting(clip.from))
        let file = try CutProject.checkedMediaURL(clip.file, relativeTo: location)
        let media = try indexed[file] ?? engine.inspect(file, keyframes: true)
        indexed[file] = media
        guard !media.audio.isEmpty else { continue }
        let ordinal = clip.audioTrack ?? 0
        guard media.audio.indices.contains(ordinal) else { throw CutError(code: "no_audio", message: "Unavailable analysis track on " + clip.id) }
        let stream = media.audio[ordinal].stream.index
        let scan: Scan
        if let saved = scans[file]?[stream] { scan = saved }
        else {
            let detection = try AudioAnalysis.silence(media, stream: stream, thresholdDB: options.thresholdDB, minimum: options.minimum,
                                                      cancelled: { !interruption.isActive })
            let protections = authored.sequence(file: file.path, origin: media.multicamSourceOffset, stream: stream,
                                               sourceFingerprint: media.identity.transcriptFingerprint)
            scan = Scan(pauses: detection.pauses(maxBlip: options.maxBlip), threshold: detection.thresholdDB,
                        protections: protections)
            scans[file, default: [:]][stream] = scan
        }
        var cuts: [AudioSpan] = []
        let first = scan.pauses.lowerBound { $0.to > clip.from }
        for pause in scan.pauses[first...].prefix(while: { $0.from < clip.to }) {
            try interruption.check()
            let span = AudioSpan(from: max(clip.from, pause.from), to: min(clip.to, pause.to))
            guard try span.to.subtracting(span.from).seconds >= options.minimum else { continue }
            let id = "\(clip.id):\(stream):\(span.from):\(span.to)"
            let keep = options.protectedPauses.contains(id) || scan.protections.contains { $0.from < span.to && $0.to > span.from }
            let requested = options.retainedPauseSeconds[id]
            var cut: AudioSpan?
            if !keep {
                let padding = requested.map { $0 / 2 } ?? options.padding ?? 0.2
                let container = containers[file] ?? outputContainer
                    ?? engine.suggestedContainers(for: media).first ?? file.pathExtension.lowercased()
                containers[file] = container
                if media.hasVideo {
                    let edges = boundaries[file] ?? (
                        ends: engine.validBoundaries(in: media, start: false, first: false, last: false, container: container),
                        starts: engine.validBoundaries(in: media, start: true, first: false, last: false, container: container)
                    )
                    boundaries[file] = edges
                    cut = AudioAnalysis.removal(in: span, padding: padding, ends: edges.ends, starts: edges.starts, clip: bounds)
                } else {
                    cut = AudioAnalysis.audioRemoval(in: span, padding: padding, media: media, clip: bounds, container: container)
                }
            }
            func sequence(_ span: AudioSpan) throws -> AudioSpan {
                try AudioSpan(from: start.adding(span.from.subtracting(clip.from)), to: start.adding(span.to.subtracting(clip.from)))
            }
            if let cut {
                cuts.append(cut)
                outputRemovals.append(try sequence(cut))
                removed = try removed.adding(cut.to.subtracting(cut.from))
            }
            let retained = try span.to.subtracting(span.from).subtracting(cut.map { try $0.to.subtracting($0.from) } ?? .zero)
            rows.append(.init(id: id, clipID: clip.id, stream: stream, thresholdDB: scan.threshold,
                              source: span, sequence: try sequence(span), protected: keep, removal: cut,
                              requestedRetainedSeconds: requested, retainedSeconds: retained.seconds))
        }
        if needsEdits && !cuts.isEmpty { sourceRemovals[clip.id] = cuts }
    }
    guard !scans.isEmpty else { throw CutError(code: "no_audio", message: "The sequence has no audio to scan.") }
    let knownPauses = Set(rows.map(\.id))
    guard options.protectedPauses.union(options.retainedPauseSeconds.keys).isSubset(of: knownPauses) else {
        throw CLIError("invalid_arguments", "A pause ID is absent from this scan. Scan again with the same settings.")
    }
    let retained = AudioAnalysis.retained(in: AudioSpan(from: .zero, to: cursor), removing: outputRemovals)
    let candidates = try options.splitTakeCandidates(retained)
    let candidate = try project.removingSequencePauses(sourceRemovals, checkCancellation: interruption.check)
    try interruption.check()
    for (file, media) in indexed where !media.identity.isCurrentSnapshot(at: file) {
        throw CutError(code: "source_changed", message: file.lastPathComponent + " changed during silence analysis.")
    }
    return try (candidate, .init(projectPath: path, pauses: rows, takeCandidates: candidates, duration: cursor, removedDuration: removed,
                                 retainedDuration: cursor.subtracting(removed)))
}
