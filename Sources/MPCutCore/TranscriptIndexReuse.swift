import Foundation

extension TranscriptIndex {
    /// The same index as the `spaces:` initializer builds, with each clock projected and
    /// indexed on its own thread. The document is checked and the source words are projected
    /// once, before the threads start. Each clock is then projected from those words and
    /// indexed beside the others, which pays off only where no one clock dominates the build,
    /// as in a multicam project.
    package static func concurrent(document: TranscriptDocument, attachment: TranscriptAttachment? = nil,
                                   project: CutProject? = nil, projectURL: URL? = nil,
                                   sequenceMedia: [String: MediaInfo] = [:], multicamMedia: [String: MediaInfo] = [:],
                                   timelineRevision: Int = 0, records: [TranscriptAuthoredRecord] = [],
                                   spaces: Set<TranscriptSpace> = Set(TranscriptSpace.allCases)) throws -> TranscriptIndex {
        let clocks = TranscriptSpace.allCases.filter(spaces.contains)
        guard clocks.count > 1 else {
            return try TranscriptIndex(document: document, attachment: attachment, project: project, projectURL: projectURL,
                                       sequenceMedia: sequenceMedia, multicamMedia: multicamMedia,
                                       timelineRevision: timelineRevision, records: records, spaces: spaces)
        }
        let shared = try Groundwork(document: document, attachment: attachment, project: project, projectURL: projectURL,
                                    sequenceMedia: sequenceMedia, multicamMedia: multicamMedia,
                                    timelineRevision: timelineRevision, staleMatches: false, records: records,
                                    needsWords: true)
        return try sideBySide(shared, clocks: clocks)
    }

    /// Several clocks, each projected and indexed on its own thread from one groundwork. The
    /// Source index orders a copy of the source words, because the other clocks are still
    /// reading the list in the order it was projected.
    private static func sideBySide(_ shared: Groundwork, clocks: [TranscriptSpace]) throws -> TranscriptIndex {
        let parts = Parts(count: clocks.count)
        DispatchQueue.concurrentPerform(iterations: clocks.count) { position in
            parts.set(Result { try TranscriptIndex(shared.forOneClock(), spaces: [clocks[position]]) }, at: position)
        }
        let built = try parts.results.map { try $0.get() }
        var indexes: [TranscriptSpace: WordIndex] = [:]
        var gaps: [TranscriptCoverageGap] = []
        for part in built {
            let (clocks, found) = part.indexes.built
            indexes.merge(clocks) { first, _ in first }
            // Only the cut has gaps.
            if clocks[.currentCut] != nil { gaps = found }
        }
        // Every part reads the same document, speakers and corrections.
        let first = built[0]
        return TranscriptIndex(clocks: indexes, gaps: gaps, document: first.document, timelineRevision: first.timelineRevision,
                               attachment: first.attachment, transcriptRevision: first.transcriptRevision,
                               speakers: first.speakers, authoredReview: first.authoredReview,
                               inputCoverageProvider: first.inputCoverageProvider, usesMix: first.usesMix,
                               staleLead: shared.staleLead)
    }

    /// An index that builds the clocks asked for now, and any other clock the first time
    /// something reads it. A reader open on one clock then holds one clock, and an edit
    /// rebuilds that one. What each track is bound to is kept for the later clocks. The source
    /// words are not, so a later clock projects them again: about a third of a whole build.
    /// `sideBySide` builds clocks that are asked for together on a thread each. `onBuild` hears
    /// of every later build, and whether a reader caused it by reading a clock nobody had
    /// asked for, which it then waited for where it stood.
    package static func onDemand(document: TranscriptDocument, attachment: TranscriptAttachment? = nil,
                                 project: CutProject? = nil, projectURL: URL? = nil,
                                 sequenceMedia: [String: MediaInfo] = [:], multicamMedia: [String: MediaInfo] = [:],
                                 timelineRevision: Int = 0, records: [TranscriptAuthoredRecord] = [],
                                 spaces: Set<TranscriptSpace>, sideBySide: Bool = false,
                                 onBuild: @escaping @Sendable (_ unrequested: Bool) -> Void = { _ in }) throws -> TranscriptIndex {
        let shared = try Groundwork(document: document, attachment: attachment, project: project, projectURL: projectURL,
                                    sequenceMedia: sequenceMedia, multicamMedia: multicamMedia,
                                    timelineRevision: timelineRevision, staleMatches: false, records: records,
                                    needsWords: true)
        let kept = shared.withoutSourceWords()
        // Staleness that only the first Source and Group words can settle is read from them now.
        let first = shared.staleLead == nil ? spaces.union([.source, .group]) : spaces
        let clocks = TranscriptSpace.allCases.filter(first.contains)
        let index: TranscriptIndex
        if sideBySide, clocks.count > 1 {
            index = try Self.sideBySide(shared, clocks: clocks)
        } else {
            index = try TranscriptIndex(consume shared, spaces: first)
        }
        index.indexes.keep(.init(groundwork: kept, sideBySide: sideBySide, onBuild: onBuild))
        return index
    }

    /// The clocks built so far.
    package var builtSpaces: Set<TranscriptSpace> { indexes.spaces }

    package func holds(_ spaces: Set<TranscriptSpace>) -> Bool {
        spaces.isSubset(of: indexes.spaces)
    }

    /// Builds whichever of these clocks an index made by `onDemand` has not built. A reader
    /// that asks here first, away from the main thread, never waits for a clock when it reads.
    package func build(_ spaces: Set<TranscriptSpace>) throws {
        try indexes.build(spaces, unrequested: false)
    }

    /// The clocks an index has built, shared by every copy of it. An index made by `onDemand`
    /// also keeps what a clock is projected from, and builds a clock the first time it is
    /// read. Reading one of its clocks never comes back empty for want of building it.
    final class Clocks: @unchecked Sendable {
        struct Origin {
            let groundwork: Groundwork
            let sideBySide: Bool
            let onBuild: @Sendable (_ unrequested: Bool) -> Void
        }

        private let lock = NSLock()
        /// Held for the length of a build, so two readers of one missing clock build it once.
        /// Reading a clock that is built takes only `lock`, and never waits for a build.
        private let building = NSLock()
        private var clocks: [TranscriptSpace: WordIndex]
        private var cutGaps: [TranscriptCoverageGap]
        private var origin: Origin?
        /// Why a clock that a reader asked for unannounced could not be built. A read cannot
        /// throw, and must not build again on every call.
        private var failures: [TranscriptSpace: Error] = [:]

        init(_ clocks: [TranscriptSpace: WordIndex], gaps: [TranscriptCoverageGap]) {
            self.clocks = clocks
            self.cutGaps = gaps
        }

        var spaces: Set<TranscriptSpace> { lock.withLock { Set(clocks.keys) } }

        /// What is built now. Nothing is built to answer.
        var built: (clocks: [TranscriptSpace: WordIndex], gaps: [TranscriptCoverageGap]) {
            lock.withLock { (clocks, cutGaps) }
        }

        subscript(space: TranscriptSpace) -> WordIndex? {
            if let index = lock.withLock({ clocks[space] }) { return index }
            try? build([space], unrequested: true)
            return lock.withLock { clocks[space] }
        }

        var gaps: [TranscriptCoverageGap] {
            let known = lock.withLock { clocks[.currentCut] != nil || origin == nil ? cutGaps : nil }
            if let known { return known }
            try? build([.currentCut], unrequested: true)
            return lock.withLock { cutGaps }
        }

        func keep(_ origin: Origin) {
            lock.withLock {
                if clocks.count < TranscriptSpace.allCases.count { self.origin = origin }
            }
        }

        func build(_ spaces: Set<TranscriptSpace>, unrequested: Bool) throws {
            building.lock()
            defer { building.unlock() }
            let (missing, origin, failed) = lock.withLock { (spaces.subtracting(clocks.keys), self.origin, failures) }
            guard !missing.isEmpty, let origin else { return }
            if unrequested, let failure = missing.compactMap({ failed[$0] }).first { throw failure }
            origin.onBuild(unrequested)
            let wanted = TranscriptSpace.allCases.filter(missing.contains)
            do {
                let groundwork = try origin.groundwork.withSourceWords()
                let part: TranscriptIndex
                if origin.sideBySide, wanted.count > 1 {
                    part = try TranscriptIndex.sideBySide(groundwork, clocks: wanted)
                } else {
                    part = try TranscriptIndex(consume groundwork, spaces: missing)
                }
                let (added, found) = part.indexes.built
                lock.withLock {
                    clocks.merge(added) { first, _ in first }
                    if added[.currentCut] != nil { cutGaps = found }
                    for space in missing { failures[space] = nil }
                    // With every clock built there is nothing left to project.
                    if clocks.count == TranscriptSpace.allCases.count { self.origin = nil }
                }
            } catch {
                lock.withLock { for space in missing { failures[space] = error } }
                throw error
            }
        }
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
