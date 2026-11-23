import Foundation

extension TranscriptIndex {
    /// The same index as the `spaces:` initializer builds, with each clock projected and
    /// indexed on its own thread. The clocks share only their inputs, and an open reader
    /// waits for all of them after every edit. Each thread projects the source words again,
    /// so this pays off only where no one clock dominates the build, as in a multicam project.
    package static func concurrent(document: TranscriptDocument, attachment: TranscriptAttachment? = nil,
                                   project: CutProject? = nil, projectURL: URL? = nil,
                                   sequenceMedia: [String: MediaInfo] = [:], multicamMedia: [String: MediaInfo] = [:],
                                   timelineRevision: Int = 0, records: [TranscriptAuthoredRecord] = [],
                                   spaces: Set<TranscriptSpace> = Set(TranscriptSpace.allCases)) throws -> TranscriptIndex {
        func build(_ spaces: Set<TranscriptSpace>) throws -> TranscriptIndex {
            try TranscriptIndex(document: document, attachment: attachment, project: project, projectURL: projectURL,
                                sequenceMedia: sequenceMedia, multicamMedia: multicamMedia,
                                timelineRevision: timelineRevision, records: records, spaces: spaces)
        }
        let clocks = TranscriptSpace.allCases.filter(spaces.contains)
        guard clocks.count > 1 else { return try build(spaces) }
        let parts = Parts(count: clocks.count)
        DispatchQueue.concurrentPerform(iterations: clocks.count) { position in
            parts.set(Result { try build([clocks[position]]) }, at: position)
        }
        let built = try parts.results.map { try $0.get() }
        var indexes: [TranscriptSpace: WordIndex] = [:]
        for part in built { indexes.merge(part.indexes) { first, _ in first } }
        // Every part reads the same document, speakers and corrections. Only the cut has gaps.
        let first = built[0]
        let cut = built.first { $0.indexes[.currentCut] != nil }
        return TranscriptIndex(indexes: indexes, document: first.document, timelineRevision: first.timelineRevision,
                               attachment: first.attachment, transcriptRevision: first.transcriptRevision,
                               speakers: first.speakers, authoredReview: first.authoredReview,
                               inputCoverageProvider: first.inputCoverageProvider, gaps: cut?.gaps ?? first.gaps,
                               usesMix: first.usesMix)
    }

    private final class Parts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Result<TranscriptIndex, Error>?]

        init(count: Int) { values = Array(repeating: nil, count: count) }

        func set(_ value: Result<TranscriptIndex, Error>, at position: Int) {
            lock.withLock { values[position] = value }
        }

        var results: [Result<TranscriptIndex, Error>] {
            lock.withLock { values.map { $0 ?? .failure(CancellationError()) } }
        }
    }
}
