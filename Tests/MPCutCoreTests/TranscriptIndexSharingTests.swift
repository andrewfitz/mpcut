import Foundation
import XCTest
@testable import MPCutCore

/// A rebuild for several clocks projects the source words once and hands them to each clock.
/// These compare what that builds, row by row, with indexes built on their own.
final class TranscriptIndexSharingTests: XCTestCase {
    private static let everyClock = Set(TranscriptSpace.allCases)
    private static let script = ["We", "stayed", "for", "a", "while", "and", "talked", "about", "what", "we", "had", "seen."]

    private struct Case {
        let name: String
        var document: TranscriptDocument
        var attachment: TranscriptAttachment? = nil
        var project: CutProject? = nil
        var revision = 0
        var records: [TranscriptAuthoredRecord] = []

        /// One build that projects everything it is asked for by itself.
        func alone(_ spaces: Set<TranscriptSpace> = TranscriptIndexSharingTests.everyClock) throws -> TranscriptIndex {
            try TranscriptIndex(document: document, attachment: attachment, project: project,
                                timelineRevision: revision, records: records, spaces: spaces)
        }

        func together(_ spaces: Set<TranscriptSpace> = TranscriptIndexSharingTests.everyClock) throws -> TranscriptIndex {
            try .concurrent(document: document, attachment: attachment, project: project,
                            timelineRevision: revision, records: records, spaces: spaces)
        }

        /// An index that builds these clocks now and the others when they are first read.
        func onDemand(_ spaces: Set<TranscriptSpace>, sideBySide: Bool = false, builds: BuildLog? = nil) throws -> TranscriptIndex {
            try .onDemand(document: document, attachment: attachment, project: project,
                          timelineRevision: revision, records: records, spaces: spaces, sideBySide: sideBySide) { unrequested in
                builds?.note(unrequested)
            }
        }
    }

    /// The later builds an on-demand index reports, and how many a reader caused without asking.
    private final class BuildLog: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        private var unasked = 0

        func note(_ unrequested: Bool) {
            lock.withLock { if unrequested { unasked += 1 } else { asked += 1 } }
        }

        var requested: Int { lock.withLock { asked } }
        var unrequested: Int { lock.withLock { unasked } }
    }

    /// What the reader computed from the rows before an index reported it.
    private func leadingRowsAreStale(_ index: TranscriptIndex) -> Bool {
        index.read(space: .source, limit: 1).items.first?.staleMatches == true
            || index.read(space: .group, limit: 1).items.first?.staleMatches == true
    }

    /// An index that builds its clocks one at a time, in any order and with or without being
    /// asked first, against one build of every clock.
    private func checkOnDemand(_ fixture: Case, against whole: TranscriptIndex,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(whole.staleMatches, leadingRowsAreStale(whole), fixture.name, file: file, line: line)
        let clocks = TranscriptSpace.allCases
        for start in clocks.indices {
            let order = Array(clocks[start...] + clocks[..<start])
            let log = BuildLog()
            let index = try fixture.onDemand([order[0]], sideBySide: start == 1, builds: log)
            XCTAssertTrue(index.holds([order[0]]), fixture.name, file: file, line: line)
            XCTAssertEqual(index.staleMatches, whole.staleMatches, fixture.name, file: file, line: line)
            var expected = index.builtSpaces.count
            for clock in order.dropFirst() {
                if !index.holds([clock]) { expected += 1 }
                try index.build([clock])
                try index.build([clock])
                XCTAssertEqual(index.builtSpaces.count, expected, fixture.name, file: file, line: line)
            }
            XCTAssertEqual(index.builtSpaces, Self.everyClock, fixture.name, file: file, line: line)
            XCTAssertEqual(log.unrequested, 0, fixture.name, file: file, line: line)
            try assertSame(index, whole, "\(fixture.name) on demand from \(order[0].rawValue)", file: file, line: line)
            XCTAssertEqual(log.unrequested, 0, "Reading a built clock builds nothing.", file: file, line: line)
        }
        // Nothing is asked for first. Each clock is built by whatever reads it.
        let log = BuildLog()
        let unasked = try fixture.onDemand([], builds: log)
        let pair = try fixture.onDemand([.source, .currentCut], sideBySide: true)
        try pair.build([.group, .currentCut])
        for space in clocks {
            try assertSameRows(unasked.readAll(space: space), whole.readAll(space: space),
                               "\(fixture.name) \(space.rawValue) read without asking", file: file, line: line)
            try assertSameRows(pair.readAll(space: space), whole.readAll(space: space),
                               "\(fixture.name) \(space.rawValue) built in pairs", file: file, line: line)
        }
        XCTAssertEqual(try encoded(unasked.gaps), try encoded(whole.gaps), fixture.name, file: file, line: line)
        XCTAssertEqual(try encoded(pair.gaps), try encoded(whole.gaps), fixture.name, file: file, line: line)
        XCTAssertEqual(log.requested, 0, fixture.name, file: file, line: line)
        XCTAssertLessThanOrEqual(log.unrequested, clocks.count, "A clock is built once.", file: file, line: line)
        // A view of another clock does not build Current Cut to learn its gaps until it is asked for them.
        let view = try fixture.onDemand([.source])
        let before = view.builtSpaces
        let source = TranscriptProjectIndex(indexes: [view], space: .source)
        try assertSameRows(source.readAll(), whole.readAll(space: .source), fixture.name, file: file, line: line)
        XCTAssertEqual(view.builtSpaces, before, fixture.name, file: file, line: line)
        XCTAssertEqual(try encoded(source.gaps), try encoded(whole.gaps), fixture.name, file: file, line: line)
        XCTAssertTrue(view.holds([.currentCut]), fixture.name, file: file, line: line)
    }

    private func t(_ numerator: Int64, _ denominator: Int64 = 1) -> RationalTime {
        .init(numerator: numerator, denominator: denominator)
    }

    private func r(_ start: Int64, _ end: Int64) -> MulticamRange {
        .init(from: t(start), to: t(end))
    }

    private func attachment(_ bindings: [TranscriptBinding]) -> TranscriptAttachment {
        let digest = String(repeating: "a", count: 64)
        return .init(id: "dialogue", asset: .init(sha256: digest),
                     bindings: bindings)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try XCTUnwrap(String(data: encoder.encode(value), encoding: .utf8))
    }

    /// Everything one row holds. The encoded form leaves out what a lane filter and an
    /// overlap lookup read, so those are written beside it.
    private func row(_ word: TranscriptOccurrence) throws -> String {
        let lanes = word.trackLanes.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") }
        let hearings = try word.alternateLaneHearings.map { try $0.map(row).joined(separator: "|") }
        return try encoded(word) + " lanes=\(lanes ?? "nil") hearings=[\(hearings ?? "nil")]"
    }

    private func assertSameRows(_ have: [TranscriptOccurrence], _ want: [TranscriptOccurrence], _ name: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let have = try have.map(row)
        let want = try want.map(row)
        XCTAssertEqual(have.count, want.count, name, file: file, line: line)
        if let position = (0..<min(have.count, want.count)).first(where: { have[$0] != want[$0] }) {
            XCTFail("\(name) row \(position): \(have[position]) is not \(want[position])", file: file, line: line)
        }
    }

    private func assertSame(_ have: TranscriptIndex, _ want: TranscriptIndex, _ name: String,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        for space in TranscriptSpace.allCases {
            let label = "\(name) \(space.rawValue)"
            let rows = want.readAll(space: space)
            try assertSameRows(have.readAll(space: space), rows, label, file: file, line: line)
            for phrase in ["talked about", "we had seen", "stayed for a while and", "lantern", "bled wide", "seen. We"] {
                XCTAssertEqual(try encoded(have.search(phrase, space: space, limit: 500)),
                               try encoded(want.search(phrase, space: space, limit: 500)), "\(label) \(phrase)", file: file, line: line)
            }
            var filters = [TranscriptFilter(includeInferred: true)]
            for track in want.document.tracks {
                filters.append(.init(trackID: track.id))
                filters.append(.init(trackID: track.id, includeInferred: true))
            }
            filters += Set(rows.compactMap(\.speakerID)).sorted().map { .init(speakerID: $0) }
            filters += Set(rows.compactMap(\.sourceID)).sorted().map { .init(sourceID: $0) }
            filters += Set(rows.compactMap(\.clipID)).sorted().map { .init(clipID: $0) }
            filters += Set(rows.flatMap { [$0.laneID].compactMap { $0 } + ($0.heardOnLaneIDs ?? []) }).sorted().map { .init(laneID: $0) }
            for filter in filters {
                let scope = try "\(label) \(encoded(filter))"
                try assertSameRows(have.readAll(space: space, filter: filter), want.readAll(space: space, filter: filter),
                                   scope, file: file, line: line)
                XCTAssertEqual(try encoded(have.search("talked about", space: space, filter: filter, limit: 500)),
                               try encoded(want.search("talked about", space: space, filter: filter, limit: 500)),
                               scope, file: file, line: line)
                XCTAssertEqual(try encoded(have.inputCoverage(space: space, filter: filter, limit: 500)),
                               try encoded(want.inputCoverage(space: space, filter: filter, limit: 500)),
                               scope, file: file, line: line)
            }
            let end = rows.map(\.range.to).max() ?? .zero
            for step in 0..<8 {
                let from = RationalTime(numerator: end.numerator * Int64(step), denominator: end.denominator * 8)
                let to = RationalTime(numerator: end.numerator * Int64(step + 1), denominator: end.denominator * 8)
                try assertSameRows(have.overlapping(.init(from: from, to: to), space: space),
                                   want.overlapping(.init(from: from, to: to), space: space),
                                   "\(label) overlapping \(from)-\(to)", file: file, line: line)
                XCTAssertEqual(have.position(at: from, space: space), want.position(at: from, space: space), label, file: file, line: line)
                XCTAssertEqual(have.activeWords(at: from, space: space).map(\.id), want.activeWords(at: from, space: space).map(\.id),
                               label, file: file, line: line)
            }
            for word in rows.prefix(40) {
                XCTAssertEqual(have.locate(wordID: word.wordID, space: space).map(\.id),
                               want.locate(wordID: word.wordID, space: space).map(\.id), label, file: file, line: line)
                XCTAssertEqual(have.position(of: word.id, space: space), want.position(of: word.id, space: space), label, file: file, line: line)
            }
        }
        XCTAssertEqual(try encoded(have.gaps), try encoded(want.gaps), name, file: file, line: line)
        XCTAssertEqual(have.speakers, want.speakers, name, file: file, line: line)
        XCTAssertEqual(try encoded(have.authoredReview), try encoded(want.authoredReview), name, file: file, line: line)
        XCTAssertEqual(have.document, want.document, name, file: file, line: line)
        XCTAssertEqual(have.attachment, want.attachment, name, file: file, line: line)
        XCTAssertEqual(have.timelineRevision, want.timelineRevision, name, file: file, line: line)
        XCTAssertEqual(have.transcriptRevision, want.transcriptRevision, name, file: file, line: line)
        XCTAssertEqual(have.usesMix, want.usesMix, name, file: file, line: line)
        XCTAssertEqual(have.staleMatches, want.staleMatches, name, file: file, line: line)
    }

    /// The shared build against one build of every clock, against one build per clock, and
    /// for every set of clocks a caller can ask for.
    private func check(_ fixture: Case, expecting counts: [TranscriptSpace: Int]? = nil,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let whole = try fixture.alone()
        let shared = try fixture.together()
        try assertSame(shared, whole, fixture.name, file: file, line: line)
        try checkOnDemand(fixture, against: whole, file: file, line: line)
        for space in TranscriptSpace.allCases {
            let single = try fixture.alone([space])
            try assertSameRows(shared.readAll(space: space), single.readAll(space: space),
                               "\(fixture.name) \(space.rawValue) built alone", file: file, line: line)
            if space == .currentCut {
                XCTAssertEqual(try encoded(shared.gaps), try encoded(single.gaps), fixture.name, file: file, line: line)
            }
            if let count = counts?[space] {
                XCTAssertEqual(shared.readAll(space: space).count, count, "\(fixture.name) \(space.rawValue)", file: file, line: line)
            }
        }
        let sets: [Set<TranscriptSpace>] = [[], [.source], [.group], [.currentCut], [.source, .group],
                                            [.source, .currentCut], [.group, .currentCut]]
        for spaces in sets {
            try assertSame(fixture.together(spaces), fixture.alone(spaces),
                           "\(fixture.name) \(spaces.map(\.rawValue).sorted())", file: file, line: line)
        }
        // Occurrence IDs carry the revision, so a second revision is a second set of rows.
        var later = fixture
        later.revision += 1
        let next = try later.together()
        try assertSame(next, later.alone(), "\(fixture.name) next revision", file: file, line: line)
        for space in TranscriptSpace.allCases where !whole.readAll(space: space).isEmpty {
            XCTAssertTrue(Set(next.readAll(space: space).map(\.id)).isDisjoint(with: whole.readAll(space: space).map(\.id)),
                          fixture.name, file: file, line: line)
        }
    }

    /// Two microphones that take turns under a camera that switches every minute. Each stores
    /// the words it recognized for the conversation and as many again that the conversation
    /// does not use.
    private func interview(words count: Int, extras: Bool = false) -> (document: TranscriptDocument, project: MulticamProject) {
        let script = Self.script
        func bounds(_ position: Int) -> (RationalTime, RationalTime) {
            (t(Int64(position) * 2, 5), t(Int64(position + 1) * 2, 5))
        }
        let microphones = ["host", "guest"]
        var tracks = microphones.enumerated().map { order, id -> TranscriptTrack in
            var local = (0..<count / 2).map { position -> TranscriptWord in
                let (start, end) = bounds(position * 2 + order)
                return .init(id: "t\(position)", text: script[(position * 5 + 3) % script.count], start: start, end: end,
                             speakerID: "voice", confidence: 0.8)
            }
            for position in 0..<count where position / script.count % 2 == order {
                let (start, end) = bounds(position)
                local.append(.init(id: "recognized-\(position)", text: script[position % script.count],
                                   start: start, end: end, speakerID: "voice"))
            }
            local.sort { $0.start < $1.start }
            return TranscriptTrack(id: id, name: id.capitalized, sourceID: id, streamIndex: 0, words: local,
                                   speakers: [.init(id: "voice", name: id.capitalized + " microphone")])
        }
        tracks.append(.init(id: "scratch", name: "Camera", sourceID: "wide", streamIndex: 1, coverage: .skipped))
        var words = (0..<count).map { position -> TranscriptWord in
            let (start, end) = bounds(position)
            let turn = position / script.count % 2
            var observations = [TranscriptObservation(trackID: microphones[turn], wordID: "recognized-\(position)",
                                                      start: start, end: end, evidence: .recognized)]
            if position.isMultiple(of: 5) {
                observations.append(.init(trackID: microphones[1 - turn], start: start, end: end, evidence: .inferred, basis: "bleed"))
            }
            return .init(id: "w\(position)", text: script[position % script.count], start: start, end: end,
                         utteranceID: "u\(position / script.count)", speakerID: microphones[turn], observations: observations)
        }
        let end = t(Int64(count) * 2, 5)
        if extras {
            // A word brought in from an exported cut, and one no single recording can claim.
            let (start, stop) = bounds(count / 3)
            words.append(.init(id: "imported", text: "lantern", start: start, end: stop, projection: .init(
                clock: .group, wordID: "w0", attachmentID: "earlier", originalText: "Lantern", originalSpeakerID: "guest",
                originalSourceStart: start, originalSourceEnd: stop, trackID: "guest", partial: true, staleMatches: false)))
            let (from, to) = bounds(count / 2)
            words.append(.init(id: "unplaced", text: "somewhere", start: from, end: to, candidateTrackIDs: microphones))
        }
        let document = TranscriptDocument(clock: .session, tracks: tracks,
                                          speakers: microphones.map { .init(id: $0, name: $0.capitalized) }, words: words)
        let seconds = Int(end.seconds)
        let switches = stride(from: 0, to: seconds, by: 60).map { second -> MulticamSwitch in
            let minute = second / 60
            return .init(at: t(Int64(second)), angle: minute.isMultiple(of: 2) ? "wide" : "close",
                         audio: minute % 3 == 1 ? .init(source: "guest", stream: 0) : nil)
        }
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: end),
                                      angles: [.init(id: "wide", file: "wide.mov"), .init(id: "close", file: "close.mov")],
                                      audioSources: microphones.map { .init(id: $0, file: "\($0).wav") },
                                      audio: .fixed(.init(source: "host", stream: 0)), switches: switches,
                                      assembly: [.init(from: .zero, to: end)])
        return (document, project)
    }

    /// The interview after an edit: a later stretch moved ahead of an earlier one, a replay,
    /// and the rest removed. One boundary falls inside a word.
    private func editedInterview(words count: Int = 900) throws -> Case {
        var (document, project) = interview(words: count, extras: true)
        let end = project.range.to
        func part(_ numerator: Int64, of denominator: Int64) -> RationalTime {
            RationalTime(numerator: end.numerator * numerator, denominator: end.denominator * denominator)
        }
        project.assembly = [.init(from: part(5, of: 8), to: part(7, of: 8)),
                            .init(from: part(1, of: 8), to: try part(3, of: 8).adding(t(1, 10))),
                            .init(from: part(1, of: 8), to: part(2, of: 8)),
                            .init(from: try part(3, of: 8).adding(t(1, 10)), to: part(4, of: 8))]
        document.jobID = nil
        let attached = attachment(document.tracks.map { TranscriptBinding(trackID: $0.id, sourceID: $0.sourceID, streamIndex: $0.streamIndex ?? 0) })
        var fixture = Case(name: "edited interview", document: document, attachment: attached,
                           project: .multicam(project), revision: 7)
        let plain = try fixture.alone()
        let source = plain.readAll(space: .source)
        let corrected = try XCTUnwrap(source.first { $0.wordID == "w40" })
        let renamed = try XCTUnwrap(source.first { $0.wordID == "w\(count / 2)" })
        fixture.records = [
            try TranscriptEditorial.makeRecord(change: .replaceText(text: "lantern"), selections: [
                .init(firstWordID: corrected.wordID, space: .source, firstOccurrenceID: corrected.id)
            ], in: plain, id: "correction"),
            try TranscriptEditorial.makeRecord(change: .replaceText(text: "talked about"), selections: [
                .init(firstWordID: renamed.wordID, space: .source, firstOccurrenceID: renamed.id)
            ], in: plain, id: "second-correction")
        ]
        return fixture
    }

    func testAnEditedMulticamInterviewMatchesClockByClock() throws {
        let fixture = try editedInterview()
        let index = try fixture.alone()
        // 900 conversation words heard on one microphone, 180 of them also inferred on the
        // other, 900 words the microphones keep for themselves, and the two extra words.
        XCTAssertEqual(index.readAll(space: .source).count, 900 + 180 + 900 + 2)
        XCTAssertEqual(index.readAll(space: .group).count, 900 + 900 + 2)
        XCTAssertFalse(index.readAll(space: .currentCut).isEmpty)
        XCTAssertTrue(index.readAll(space: .currentCut).contains(where: \.partial))
        XCTAssertEqual(Set(index.readAll(space: .currentCut).compactMap(\.assemblyIndex)), [0, 1, 2, 3])
        XCTAssertEqual(index.authoredReview.count, 2)
        XCTAssertTrue(index.readAll(space: .source).contains { $0.text == "lantern" && $0.textReplacementID == "correction" })
        XCTAssertEqual(index.locate(wordID: "imported", space: .source).first?.originalText, "Lantern")
        XCTAssertNil(index.locate(wordID: "unplaced", space: .source).first?.trackID)
        XCTAssertEqual(index.locate(wordID: "unplaced", space: .group).count, 1)
        try check(fixture)

        var unattached = fixture
        unattached.attachment = nil
        unattached.records = []
        try check(Case(name: "unattached interview", document: unattached.document, project: unattached.project, revision: 2))
    }

    func testMovedSourcesMatchClockByClock() throws {
        var fixture = try editedInterview(words: 360)
        fixture.records = []
        guard case .multicam(var project) = fixture.project else { return XCTFail("The interview is a multicam project.") }
        // A job result remembers where each recording sat. Moving one leaves every match in
        // doubt, and Group then lists a word once for each recording that heard it.
        fixture.document.jobID = "job"
        let word = fixture.document.words[0]
        let localID = "guest-overlap"
        fixture.document.tracks[1].words?.insert(.init(id: localID, text: word.text, start: word.start, end: word.end), at: 0)
        fixture.document.words[0].observations.removeAll { $0.trackID == "guest" }
        fixture.document.words[0].observations.append(
            .init(trackID: "guest", wordID: localID, start: word.start, end: word.end, evidence: .recognized)
        )
        project.audioSources[0].offset = t(1)
        fixture.project = .multicam(project)
        let index = try fixture.alone()
        XCTAssertTrue(index.readAll(space: .group).allSatisfy(\.staleMatches))
        XCTAssertEqual(Set(index.locate(wordID: word.id, space: .group).compactMap(\.trackID)), ["host", "guest"])
        try check(Case(name: "moved sources", document: fixture.document, attachment: fixture.attachment,
                       project: fixture.project, revision: 3))
    }

    func testAMixWithBleedMatchesClockByClock() throws {
        let tracks = [
            TranscriptTrack(id: "wide-mic", name: "Wide mic", sourceID: "wide", streamIndex: 0),
            TranscriptTrack(id: "close-mic", name: "Close mic", sourceID: "close", streamIndex: 1),
            TranscriptTrack(id: "close-second-channel", name: "Close second channel", sourceID: "close", streamIndex: 1, channel: 1),
            TranscriptTrack(id: "rollover-mic", name: "Rollover mic", sourceID: "rollover", streamIndex: 2)
        ]
        let document = TranscriptDocument(clock: .session, tracks: tracks, words: [
            .init(id: "bled", text: "bled", start: t(1), end: t(2), observations: [
                .init(trackID: "close-mic", start: t(1), end: t(2), evidence: .recognized),
                .init(trackID: "close-second-channel", start: t(1), end: t(2), evidence: .recognized),
                .init(trackID: "wide-mic", start: t(1), end: t(3), evidence: .recognized)
            ]),
            .init(id: "interruption", text: "interrupt", start: t(3, 2), end: t(2), observations: [
                .init(trackID: "close-mic", start: t(3, 2), end: t(2), evidence: .recognized)
            ]),
            .init(id: "wide-word", text: "wide", start: t(2), end: t(4), observations: [
                .init(trackID: "wide-mic", start: t(2), end: t(4), evidence: .recognized)
            ]),
            .init(id: "close-word", text: "close", start: t(3), end: t(4), observations: [
                .init(trackID: "rollover-mic", start: .zero, end: t(1), evidence: .recognized)
            ])
        ])
        var project = MulticamProject(referenceAngle: "wide", range: r(0, 5), angles: [
            .init(id: "wide", file: "wide.mov", audioStream: 0),
            .init(id: "close", file: "close.mov", audioStream: 1, coverage: r(0, 2), additionalRecordings: [
                .init(id: "rollover", file: "rollover.mov", offset: t(3), audioStream: 2, coverage: r(3, 5))
            ])
        ], audio: .mix, switches: [.init(at: .zero, angle: "wide")], mixLanes: [
            .init(id: "wide-lane", target: .camera("wide"), label: "Wide", colorSlot: 4),
            .init(id: "close-lane", target: .camera("close"), label: "Close", colorSlot: 1)
        ])
        let fixture = Case(name: "mix", document: document, project: .multicam(project), revision: 4)
        let index = try fixture.together()
        let bled = try XCTUnwrap(index.locate(wordID: "bled", space: .currentCut).first)
        XCTAssertEqual(bled.heardOnLaneIDs, ["wide-lane"])
        XCTAssertEqual(bled.alternateLaneHearings?.map(\.range), [r(1, 3)])
        XCTAssertEqual(bled.trackLanes, ["close-mic": "close-lane", "close-second-channel": "close-lane", "wide-mic": "wide-lane"])
        XCTAssertEqual(index.search("bled wide", space: .currentCut, filter: .init(laneID: "wide-lane")).total, 1)
        XCTAssertEqual(index.overlapping(r(2, 3), space: .currentCut).first { $0.wordID == "bled" }?.laneID, "wide-lane")
        try check(fixture, expecting: [.currentCut: 4])

        // The same recordings with the assembly reordered and one stretch dropped.
        project.assembly = [r(3, 5), r(0, 2)]
        try check(Case(name: "reordered mix", document: document, project: .multicam(project), revision: 5))
    }

    func testAnEditedSequenceMatchesClockByClock() throws {
        let script = Self.script
        let tracks = [TranscriptTrack(id: "a.lav", name: "Lav", streamIndex: 1),
                      TranscriptTrack(id: "a.room", name: "Room", streamIndex: 2),
                      TranscriptTrack(id: "b.lav", name: "Second lav", streamIndex: 1)]
        var words = (0..<80).map { position -> TranscriptWord in
            let start = t(Int64(position), 2)
            let end = t(Int64(position + 1), 2)
            var observations = [TranscriptObservation(trackID: "a.lav", start: start, end: end, evidence: .recognized)]
            if position.isMultiple(of: 3) {
                observations.append(.init(trackID: "a.room", start: start, end: end, evidence: .recognized))
            }
            return .init(id: "a\(position)", text: script[position % script.count], start: start, end: end,
                         utteranceID: "a-u\(position / script.count)", observations: observations)
        }
        words += (0..<40).map { position -> TranscriptWord in
            let start = t(Int64(position), 2)
            let end = t(Int64(position + 1), 2)
            return .init(id: "b\(position)", text: script[(position + 6) % script.count], start: start, end: end,
                         observations: [.init(trackID: "b.lav", start: start, end: end, evidence: .recognized)])
        }
        let document = TranscriptDocument(clock: .presentation, tracks: tracks, words: words)
        let attached = attachment([
            .init(trackID: "a.lav", file: "a.mov", streamIndex: 1, sequenceStreamOrdinal: 0),
            .init(trackID: "a.room", file: "a.mov", streamIndex: 2, sequenceStreamOrdinal: 1),
            .init(trackID: "b.lav", file: "b.mov", streamIndex: 1, sequenceStreamOrdinal: 0)
        ])
        // Clips out of recording order, with most of both recordings removed. The third and
        // fourth meet inside a word, as a blade leaves them.
        let clips: [CutSequenceClip] = [
            .init(id: "c1", file: "b.mov", from: t(10), to: t(20)),
            .init(id: "c2", file: "a.mov", from: t(30), to: t(40)),
            .init(id: "c3", file: "a.mov", from: t(5), to: t(49, 4)),
            .init(id: "c4", file: "a.mov", from: t(49, 4), to: t(15)),
            .init(id: "c5", file: "b.mov", from: t(2), to: t(4))
        ]
        var fixture = Case(name: "sequence", document: document, attachment: attached, project: .sequence(clips), revision: 11)
        let plain = try fixture.alone()
        XCTAssertEqual(plain.readAll(space: .source).count, 80 + 27 + 40)
        XCTAssertEqual(Set(plain.readAll(space: .currentCut).compactMap(\.clipID)), ["c1", "c2", "c3", "c4", "c5"])
        XCTAssertTrue(plain.readAll(space: .currentCut).contains(where: \.partial))
        XCTAssertTrue(plain.readAll(space: .group).isEmpty)
        let corrected = try XCTUnwrap(plain.readAll(space: .currentCut).first { $0.clipID == "c2" })
        fixture.records = [try TranscriptEditorial.makeRecord(change: .replaceText(text: "lantern"), selections: [
            .init(firstWordID: corrected.wordID, firstOccurrenceID: corrected.id)
        ], in: plain, id: "correction")]
        XCTAssertTrue(try fixture.alone().readAll(space: .currentCut).contains { $0.text == "lantern" })
        try check(fixture)

        let stills = CutProject.stillSequence(.init(items: [
            .source(clips[1]), .still(.init(id: "insert", assetID: "card", duration: t(2), cadence: t(1))), .source(clips[0])
        ], stillAssets: [.init(id: "card", file: "card.png", displayName: "Card", fingerprint: String(repeating: "a", count: 64))]))
        try check(Case(name: "sequence with a card", document: document, attachment: attached, project: stills, revision: 12))
    }

    func testATranscriptWithoutAProjectMatchesClockByClock() throws {
        let (document, _) = interview(words: 240, extras: true)
        try check(Case(name: "session transcript", document: document), expecting: [.group: 242, .currentCut: 0])
        var exported = document
        exported.clock = .currentCut
        try check(Case(name: "exported cut", document: exported), expecting: [.group: 0, .currentCut: 242])
    }

    func testAnIndexReportsStaleMatchesAsItsFirstRowsDo() throws {
        let (document, project) = interview(words: 120, extras: true)
        func imported(from: RationalTime, to: RationalTime, stale: Bool) -> TranscriptWord {
            .init(id: "early", text: "before", start: from, end: to, projection: .init(
                clock: .group, wordID: "w0", originalText: "Before", originalSourceStart: from, originalSourceEnd: to,
                trackID: "guest", partial: false, staleMatches: stale))
        }
        // A word from an export that was already stale, ahead of every other word and then behind them.
        var leading = document
        leading.words.append(imported(from: t(-2, 5), to: .zero, stale: true))
        var trailing = document
        trailing.words.append(imported(from: t(10_000), to: t(10_001), stale: true))
        var current = document
        current.words.append(imported(from: t(-2, 5), to: .zero, stale: false))
        let empty = TranscriptDocument(clock: .session, tracks: document.tracks.map { TranscriptTrack(id: $0.id, name: $0.name) })
        for (name, document, stale) in [("stale word first", leading, true), ("stale word last", trailing, false),
                                        ("current word first", current, false), ("no words", empty, false)] {
            for fixture in [Case(name: name, document: document, project: .multicam(project), revision: 6),
                            Case(name: name + " without a project", document: document, revision: 6)] {
                let whole = try fixture.alone()
                XCTAssertEqual(whole.staleMatches, stale, fixture.name)
                XCTAssertEqual(leadingRowsAreStale(whole), stale, fixture.name)
                XCTAssertEqual(try fixture.together().staleMatches, stale, fixture.name)
                for space in TranscriptSpace.allCases {
                    let index = try fixture.onDemand([space])
                    XCTAssertEqual(index.staleMatches, stale, "\(fixture.name) \(space.rawValue)")
                    // Only the rows can speak for a word that carries its own flag, so they are built.
                    XCTAssertEqual(index.holds([.source, .group]), name.hasPrefix("stale word"), "\(fixture.name) \(space.rawValue)")
                }
                try checkOnDemand(fixture, against: whole)
            }
        }
    }

    func testReadersOfMissingClocksBuildEachOnce() throws {
        let fixture = try editedInterview(words: 600)
        let whole = try fixture.alone()
        let log = BuildLog()
        let index = try fixture.onDemand([], builds: log)
        XCTAssertTrue(index.builtSpaces.isEmpty)
        let clocks = TranscriptSpace.allCases
        let lock = NSLock()
        var totals: [[Int]] = Array(repeating: [], count: clocks.count)
        DispatchQueue.concurrentPerform(iterations: 12) { reader in
            let space = clocks[reader % clocks.count]
            let total = reader.isMultiple(of: 2) ? index.read(space: space, limit: 1).total : index.readAll(space: space).count
            lock.withLock { totals[reader % clocks.count].append(total) }
        }
        for (position, space) in clocks.enumerated() {
            XCTAssertEqual(totals[position], Array(repeating: whole.readAll(space: space).count, count: 4), space.rawValue)
        }
        XCTAssertEqual(log.unrequested, clocks.count, "Readers that arrive together wait for one build of each clock.")
        XCTAssertEqual(log.requested, 0)
        XCTAssertEqual(index.builtSpaces, Self.everyClock)
        try assertSame(index, whole, "read by twelve threads")
    }

    private func assertMatchingErrors(_ fixture: Case) throws {
        var sharedError: CutError?
        XCTAssertThrowsError(try fixture.together()) { sharedError = $0 as? CutError }
        let shared = try XCTUnwrap(sharedError)
        XCTAssertThrowsError(try fixture.alone()) { error in
            XCTAssertEqual((error as? CutError)?.code, shared.code)
            XCTAssertEqual((error as? CutError)?.message, shared.message)
        }
    }

    func testAnInvalidTranscriptFailsTheSameWay() throws {
        var (document, project) = interview(words: 24)
        document.words[3].text = ""
        let broken = Case(name: "invalid", document: document, project: .multicam(project))
        try assertMatchingErrors(broken)
        (document, project) = interview(words: 24)
        project.switches = []
        let unroutable = Case(name: "invalid project", document: document, project: .multicam(project))
        try assertMatchingErrors(unroutable)
    }
}

/// What one rebuild of a three-hour interview costs. Set MPCUT_TRANSCRIPT_BENCH=1 to run it.
/// MPCUT_TRANSCRIPT_INDEX_BUILD=independent builds each clock from the document by itself and
/// =serial builds them on one thread, for comparison. =cut builds Current Cut alone, as a
/// reader open on it does, and =cut-planned also plans each edit there. A process's peak
/// cannot be reset, so each run measures one way of building.
extension TranscriptIndexSharingTests {
    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    private func processCPUMilliseconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func milliseconds(_ time: timeval) -> Double { Double(time.tv_sec) * 1_000 + Double(time.tv_usec) / 1_000 }
        return milliseconds(usage.ru_utime) + milliseconds(usage.ru_stime)
    }

    /// Bytes the process has allocated and not freed.
    private func heapInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }

    /// The highest reading seen while it runs, taken every half millisecond.
    private final class PeakWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var peak = 0
        private var running = true
        private let done = DispatchSemaphore(value: 0)

        init(read: @escaping @Sendable () -> Int) {
            peak = read()
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let now = read()
                    lock.withLock { peak = max(peak, now) }
                    usleep(500)
                }
                done.signal()
            }
        }

        func finish(_ last: Int) -> Int {
            lock.withLock { running = false }
            done.wait()
            return max(peak, last)
        }
    }

    func testRebuildBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MPCUT_TRANSCRIPT_BENCH"] == "1" else {
            throw XCTSkip("Set MPCUT_TRANSCRIPT_BENCH=1 to measure.")
        }
        let way = ProcessInfo.processInfo.environment["MPCUT_TRANSCRIPT_INDEX_BUILD"] ?? "shared"
        let independent = way == "independent"
        let emptyHeap = heapInUse()
        let (document, base) = interview(words: 27_000)
        var multicam = base
        let end = multicam.range.to
        multicam.assembly = [.init(from: t(5_400), to: t(9_000)), .init(from: t(600), to: t(3_600)),
                             .init(from: t(600), to: t(900)), .init(from: t(9_600), to: end)]
        let project = CutProject.multicam(multicam)
        // 27,000 conversation words. Each microphone stores the 13,500 it recognized for the
        // conversation and 13,500 the conversation does not use.
        let stored = document.words.count + document.tracks.reduce(0) { $0 + ($1.words?.count ?? 0) }
        XCTAssertEqual(stored, 81_000)
        let megabyte = 1_048_576.0

        func build(_ revision: Int) throws -> [TranscriptIndex] {
            // "serial" is the build a sequence project and the command line use: every clock on one thread.
            if way == "serial" { return [try TranscriptIndex(document: document, project: project, timelineRevision: revision)] }
            // "cut" is a reader open on Current Cut: one clock, and what a later clock is built from.
            // "cut-planned" also plans an edit in it, which reads every clock of the revision it edits.
            // "cut-fixed" is that clock with nothing kept for a later one, to tell the two apart.
            if way == "cut-fixed" {
                return [try TranscriptIndex(document: document, project: project, timelineRevision: revision, spaces: [.currentCut])]
            }
            if way.hasPrefix("cut") {
                return [try .onDemand(document: document, project: project, timelineRevision: revision,
                                      spaces: [.currentCut], sideBySide: true)]
            }
            guard independent else {
                return [try .concurrent(document: document, project: project, timelineRevision: revision)]
            }
            let clocks = TranscriptSpace.allCases
            let lock = NSLock()
            var parts: [Result<TranscriptIndex, Error>?] = Array(repeating: nil, count: clocks.count)
            DispatchQueue.concurrentPerform(iterations: clocks.count) { position in
                let part = Result { try TranscriptIndex(document: document, project: project, timelineRevision: revision,
                                                        spaces: [clocks[position]]) }
                lock.withLock { parts[position] = part }
            }
            return try parts.map { try XCTUnwrap($0).get() }
        }

        let documentHeap = heapInUse()
        // A reader holds the index of the last revision while the next one is built.
        var held = try build(1)
        let steadyHeap = heapInUse()
        var elapsed: [Double] = []
        var cpu: [Double] = []
        var heapPeaks: [Int] = []
        var footprintPeaks: [Int] = []
        let readHeap: @Sendable () -> Int = { [self] in heapInUse() }
        let readFootprint: @Sendable () -> Int = { [self] in footprint() }
        for revision in 2..<7 {
            let heap = PeakWatch(read: readHeap)
            let memory = PeakWatch(read: readFootprint)
            let cpuStart = processCPUMilliseconds()
            let started = ContinuousClock.now
            if way == "cut-planned" { try held[0].build(Self.everyClock) }
            let next = try build(revision)
            let duration = ContinuousClock.now - started
            cpu.append(processCPUMilliseconds() - cpuStart)
            heapPeaks.append(heap.finish(heapInUse()) - steadyHeap)
            footprintPeaks.append(memory.finish(footprint()))
            elapsed.append(Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
            held = next
        }
        // The rows of the clocks that are built. Reading a clock that is not would build it.
        let rows = TranscriptSpace.allCases.map { space in
            held.reduce(0) { $0 + ($1.indexes.built.clocks[space]?.words.count ?? 0) }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        // The heap figures count bytes in use, so they leave out pages that were freed and
        // not yet returned. The footprint and the resident peak are the whole process.
        print(String(format: "TRANSCRIPT_BENCH rebuild=%@ storedWords=%d rows=%d,%d,%d wordStride=%d occurrenceStride=%d "
                     + "documentHeapMB=%.1f indexHeapMB=%.1f rebuildHeapOverSteadyMB=%.1f rebuildHeapOverSteadyMaxMB=%.1f "
                     + "peakFootprintMB=%.1f maxRSSMB=%.1f rebuildMs=%.0f rebuildCpuMs=%.0f",
                     way, stored, rows[0], rows[1], rows[2],
                     MemoryLayout<TranscriptWord>.stride, MemoryLayout<TranscriptOccurrence>.stride,
                     Double(documentHeap - emptyHeap) / megabyte, Double(steadyHeap - documentHeap) / megabyte,
                     Double(heapPeaks.sorted()[heapPeaks.count / 2]) / megabyte, Double(heapPeaks.max() ?? 0) / megabyte,
                     Double(footprintPeaks.max() ?? 0) / megabyte, Double(usage.ru_maxrss) / megabyte,
                     elapsed.sorted()[elapsed.count / 2], cpu.sorted()[cpu.count / 2]))
    }
}
