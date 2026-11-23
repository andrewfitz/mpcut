import Foundation

extension TranscriptCodec {
    public static func encode(_ index: TranscriptIndex, space: TranscriptSpace, format: TranscriptFormat,
                              filter: TranscriptFilter = .init()) throws -> Data {
        try encode(projectedDocument(index, space: space, filter: filter), format: format)
    }

    public static func encode(_ indexes: [TranscriptIndex], space: TranscriptSpace, format: TranscriptFormat,
                              filter: TranscriptFilter = .init()) throws -> Data {
        if let index = indexes.first, indexes.count == 1 {
            return try encode(index, space: space, format: format, filter: filter)
        }
        let documents = indexes.enumerated().map { position, index in
            projectedDocument(index, space: space, filter: filter, namespace: String(position))
        }
        let words = documents.flatMap(\.words).sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        let document = TranscriptDocument(clock: exportClock(space, words: words), tracks: documents.flatMap(\.tracks),
                                          speakers: documents.flatMap(\.speakers), words: words,
                                          approximateClock: documents.contains(where: \.approximateClock))
        return try encode(document, format: format)
    }

    private static func projectedDocument(_ index: TranscriptIndex, space: TranscriptSpace,
                                          filter: TranscriptFilter, namespace: String? = nil) -> TranscriptDocument {
        func scoped(_ id: String) -> String {
            namespace.map { "\($0):\(id)" } ?? id
        }
        let clock = exportClock(space, words: [])
        let originalWords = Dictionary(uniqueKeysWithValues: index.document.words.map { ($0.id, $0) })
        let projectedWords = index.readAll(space: space, filter: filter)
        let originalSpeakerIDs = Set(projectedWords.flatMap {
            ($0.observations.isEmpty ? [$0.observation].compactMap { $0 } : $0.observations).compactMap(\.speakerID)
        })
        let correctedSpeakerIDs = Set(index.speakers.map(\.id))
        let originalSpeakers = index.speakers + index.document.speakers.filter {
            originalSpeakerIDs.contains($0.id) && !correctedSpeakerIDs.contains($0.id)
        }
        let speakerIDs = Set(originalSpeakers.map(\.id))
        func scopedSpeaker(_ id: String?) -> String? {
            guard let id, speakerIDs.contains(id) else { return nil }
            return scoped(id)
        }
        let words = projectedWords.map { occurrence in
            let original = originalWords[occurrence.wordID]
            let wordClock = space == .source && occurrence.sourceRange == nil
                ? original?.projection?.clock ?? index.document.clock : clock
            let observations = occurrence.observations.isEmpty ? [occurrence.observation].compactMap { $0 } : occurrence.observations
            let candidates = occurrence.candidateTrackIDs.isEmpty && observations.isEmpty
                ? [occurrence.trackID].compactMap { $0 } : occurrence.candidateTrackIDs
            let evidence = observations.map { item in
                var observation = item
                observation.trackID = scoped(item.trackID)
                observation.speakerID = scopedSpeaker(item.speakerID)
                return observation
            }
            let projection = TranscriptWordProjection(clock: wordClock, wordID: original?.projection?.wordID ?? occurrence.wordID,
                                                      attachmentID: index.attachment?.id ?? original?.projection?.attachmentID,
                                                      originalText: occurrence.originalText, originalSpeakerID: occurrence.originalSpeakerID,
                                                      originalSourceStart: occurrence.originalSourceRange?.from,
                                                      originalSourceEnd: occurrence.originalSourceRange?.to,
                                                      trackID: occurrence.trackID.map(scoped), sourceID: occurrence.sourceID,
                                                      streamIndex: occurrence.streamIndex, routedSourceID: occurrence.routedSourceID,
                                                      routedStreamIndex: occurrence.routedStreamIndex, clipID: occurrence.clipID,
                                                      assemblyIndex: occurrence.assemblyIndex, partial: occurrence.partial,
                                                      staleMatches: occurrence.staleMatches)
            return TranscriptWord(id: scoped(occurrence.id), text: occurrence.text,
                                  start: occurrence.range.from, end: occurrence.range.to,
                                  utteranceID: occurrence.utteranceID.map(scoped),
                                  speakerID: scopedSpeaker(occurrence.speakerID),
                                  precision: occurrence.precision,
                                  observations: evidence, candidateTrackIDs: candidates.map(scoped),
                                  confidence: original == nil ? occurrence.observation?.confidence : original?.confidence,
                                  projection: projection)
        }
        let tracks = index.document.tracks.map { original in
            var track = original
            track.id = scoped(track.id)
            return track
        }
        let speakers = originalSpeakers.map { TranscriptSpeaker(id: scoped($0.id), name: $0.name) }
        return TranscriptDocument(clock: exportClock(space, words: words), tracks: tracks, speakers: speakers, words: words,
                                  approximateClock: projectedWords.contains(where: \.approximate),
                                  jobID: index.document.jobID, fingerprint: index.document.fingerprint,
                                  provenance: index.document.provenance)
    }

    private static func exportClock(_ space: TranscriptSpace, words: [TranscriptWord]) -> TranscriptClock {
        switch space {
        case .source:
            if let clock = words.first?.projection?.clock, words.allSatisfy({ $0.projection?.clock == clock }) {
                return clock
            }
            return .presentation
        case .group: return .group
        case .currentCut: return .currentCut
        }
    }
}
