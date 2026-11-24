import AppKit
import Combine
@testable import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

/// Measures the reader's work per edit and per playhead tick. Counts are asserted. Durations
/// are printed with a `MEASURE` prefix because they depend on the machine's load.
final class TranscriptResponsivenessTests: XCTestCase {
    @MainActor
    func testTimelineEditsRebuildTheIndexOffTheMainThread() async throws {
        let fixture = try await Fixture(seconds: 7_200)
        defer { fixture.end() }
        let controller = fixture.session.transcript
        let editor = fixture.session.editor
        let attachment = try await fixture.attach()

        let idle = await MainStall.measure { try? await Task.sleep(for: .milliseconds(300)) }
        var started = ContinuousClock.now
        let stall = MainStall()
        let first = try await controller.indexedTranscript(attachmentID: attachment.id)
        report("cold index build", ContinuousClock.now - started, "main stall \(stall.finish()) ms, idle floor \(idle) ms")
        XCTAssertEqual(first.read(space: .currentCut, limit: 1).total, 28_800)

        // One reviewed deletion gives the history a step to undo and redo.
        let word = try XCTUnwrap(first.read(space: .currentCut, offset: 4_000, limit: 1).items.first)
        let selection = TranscriptWordSelection(firstWordID: word.wordID, firstOccurrenceID: word.id)
        _ = try controller.apply(controller.plan(.init(action: .delete, selections: [selection], boundaryPolicy: .exact)))

        var rebuilds: [Duration] = []
        var stalls: [Int] = []
        let before = controller.indexBuilds.count
        for step in 0..<6 {
            if step.isMultiple(of: 2) { editor.undo() } else { editor.redo() }
            let stall = MainStall()
            started = ContinuousClock.now
            let index = try await controller.indexedTranscript(attachmentID: attachment.id)
            rebuilds.append(ContinuousClock.now - started)
            stalls.append(stall.finish())
            XCTAssertEqual(index.timelineRevision, controller.timelineRevision)
        }
        report("index rebuild after a timeline edit (median of 6)", median(rebuilds),
               "main stall median \(stalls.sorted()[stalls.count / 2]) ms, idle floor \(idle) ms")
        report("index builds for 6 timeline edits", count: controller.indexBuilds.count - before)
        XCTAssertEqual(controller.indexBuilds.count - before, 6)

        // Held undo and redo: each revision supersedes the load the reader started for the last one.
        let burstBefore = controller.indexBuilds.count
        started = ContinuousClock.now
        var load: Task<TranscriptIndex, Error>?
        for step in 0..<8 {
            if step.isMultiple(of: 2) { editor.undo() } else { editor.redo() }
            load?.cancel()
            load = Task { @MainActor in try await controller.indexedTranscript(attachmentID: attachment.id) }
            await Task.yield()
        }
        let settled = try await XCTUnwrap(load).value
        XCTAssertEqual(settled.timelineRevision, controller.timelineRevision)
        report("8 superseding revisions settle", ContinuousClock.now - started,
               "\(controller.indexBuilds.count - burstBefore) index builds started")
        // The build running when the burst began, and the one for the revision it ended on.
        XCTAssertLessThanOrEqual(controller.indexBuilds.count - burstBefore, 2)
    }

    @MainActor
    func testIndexBuildPhases() async throws {
        let fixture = try await Fixture(seconds: 7_200)
        defer { fixture.end() }
        let controller = fixture.session.transcript
        let attachment = try await fixture.attach()
        let document = fixture.document
        let project = controller.project
        let context = try controller.assetContext()
        let media = fixture.session.editor.transcriptMedia
        let sets: [(String, Set<TranscriptSpace>)] = [("coverage only", []), ("source", [.source]), ("group", [.group]),
                                                      ("current cut", [.currentCut]), ("all", Set(TranscriptSpace.allCases))]
        for (name, spaces) in sets {
            var runs: [Duration] = []
            for _ in 0..<3 {
                let started = ContinuousClock.now
                _ = try await Task.detached {
                    try TranscriptIndex(document: document, attachment: attachment, project: project, projectURL: context,
                                        sequenceMedia: media, timelineRevision: 1, spaces: spaces)
                }.value
                runs.append(ContinuousClock.now - started)
            }
            report("sequence index build, \(name)", median(runs))
        }

        let multicam = Self.multicamConversation(words: 28_800)
        for (name, spaces) in sets {
            var runs: [Duration] = []
            for _ in 0..<3 {
                let started = ContinuousClock.now
                _ = try await Task.detached {
                    try TranscriptIndex(document: multicam.document, project: .multicam(multicam.project),
                                        timelineRevision: 1, spaces: spaces)
                }.value
                runs.append(ContinuousClock.now - started)
            }
            report("multicam index build, \(name)", median(runs))
        }

        // The two builds alternate so both see the same load.
        var serial: [Duration] = []
        var concurrent: [Duration] = []
        var sequenceSerial: [Duration] = []
        var sequenceConcurrent: [Duration] = []
        for _ in 0..<5 {
            var started = ContinuousClock.now
            _ = try await Task.detached {
                try TranscriptIndex(document: multicam.document, project: .multicam(multicam.project), timelineRevision: 1)
            }.value
            serial.append(ContinuousClock.now - started)
            started = ContinuousClock.now
            _ = try await Task.detached {
                try TranscriptIndex.concurrent(document: multicam.document, project: .multicam(multicam.project), timelineRevision: 1)
            }.value
            concurrent.append(ContinuousClock.now - started)
            started = ContinuousClock.now
            _ = try await Task.detached {
                try TranscriptIndex(document: document, attachment: attachment, project: project, projectURL: context,
                                    sequenceMedia: media, timelineRevision: 1)
            }.value
            sequenceSerial.append(ContinuousClock.now - started)
            started = ContinuousClock.now
            _ = try await Task.detached {
                try TranscriptIndex.concurrent(document: document, attachment: attachment, project: project,
                                               projectURL: context, sequenceMedia: media, timelineRevision: 1)
            }.value
            sequenceConcurrent.append(ContinuousClock.now - started)
        }
        report("multicam index, one thread (median of 5)", median(serial))
        report("multicam index, one thread per clock (median of 5)", median(concurrent))
        report("sequence index, one thread (median of 5)", median(sequenceSerial))
        report("sequence index, one thread per clock (median of 5)", median(sequenceConcurrent))
    }

    /// Two lavalier tracks that alternate, under a camera that switches every minute.
    static func multicamConversation(words count: Int) -> (document: TranscriptDocument, project: MulticamProject) {
        let tracks = ["host", "guest"].map { TranscriptTrack(id: $0, name: $0.capitalized, sourceID: $0, streamIndex: 0) }
        let script = ["We", "stayed", "for", "a", "while", "and", "talked", "about", "what", "we", "had", "seen."]
        let words = (0..<count).map { position -> TranscriptWord in
            let start = RationalTime(numerator: Int64(position), denominator: 4)
            let end = RationalTime(numerator: Int64(position + 1), denominator: 4)
            let track = tracks[position / 12 % 2].id
            return .init(id: "w\(position)", text: script[position % 12], start: start, end: end, speakerID: track,
                         observations: [.init(trackID: track, start: start, end: end, evidence: .recognized)])
        }
        let document = TranscriptDocument(clock: .session, tracks: tracks,
                                          speakers: tracks.map { .init(id: $0.id, name: $0.name) }, words: words)
        let end = RationalTime(numerator: Int64(count), denominator: 4)
        let switches = stride(from: 0, to: count / 4, by: 60).map {
            MulticamSwitch(at: .init(numerator: Int64($0)), angle: $0 / 60 % 2 == 0 ? "wide" : "close")
        }
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: end),
                                      angles: [.init(id: "wide", file: "wide.mov"), .init(id: "close", file: "close.mov")],
                                      audioSources: [.init(id: "host", file: "host.wav"), .init(id: "guest", file: "guest.wav")],
                                      audio: .fixed(.init(source: "host", stream: 0)), switches: switches,
                                      assembly: [.init(from: .zero, to: end)])
        return (document, project)
    }

    @MainActor
    func testReviewingAnEditAcrossAttachments() async throws {
        let fixture = try await Fixture(seconds: 600)
        defer { fixture.end() }
        let controller = fixture.session.transcript
        var attachments: [TranscriptAttachment] = []
        for _ in 0..<4 { attachments.append(try await fixture.attach()) }
        let primary = try await controller.indexedTranscript(attachmentID: attachments[0].id)
        let word = try XCTUnwrap(primary.read(space: .currentCut, offset: 300, limit: 1).items.first)
        let selection = TranscriptWordSelection(firstWordID: word.wordID, firstOccurrenceID: word.id,
                                                attachmentID: attachments[0].id)
        let request = TranscriptEditRequest(action: .delete, selections: [selection], boundaryPolicy: .exact)
        var counts: [Int] = []
        var durations: [Duration] = []
        for _ in 0..<3 {
            let before = controller.indexBuilds.count
            let started = ContinuousClock.now
            let work = try controller.preparePlanReview(request, attachmentID: attachments[0].id, index: primary)
            _ = try await Task.detached(priority: .userInitiated, operation: work).value
            durations.append(ContinuousClock.now - started)
            counts.append(controller.indexBuilds.count - before)
        }
        report("review an edit with 4 attachments, three times", median(durations), "index builds per review \(counts)")
        XCTAssertEqual(counts, [3, 0, 0], "A second review of the same revision builds nothing.")
    }

    @MainActor
    func testStoringAndReadingAJobResult() async throws {
        let fixture = try await Fixture(seconds: 7_200)
        defer { fixture.end() }
        let document = fixture.document
        let context = try fixture.session.transcript.assetContext()
        var encode: [Duration] = []
        var decode: [Duration] = []
        var again: [Duration] = []
        for _ in 0..<3 {
            var started = ContinuousClock.now
            let data = try TranscriptCodec.encode(document, format: .json)
            let asset = try TranscriptStore.put(data, relativeTo: context, draft: false)
            encode.append(ContinuousClock.now - started)
            TranscriptStore.releaseDecoded(relativeTo: context)
            started = ContinuousClock.now
            _ = try TranscriptStore.decoded(asset, relativeTo: context)
            decode.append(ContinuousClock.now - started)
            started = ContinuousClock.now
            _ = try TranscriptStore.decoded(asset, relativeTo: context)
            again.append(ContinuousClock.now - started)
        }
        report("encode, hash and write a 28,800-word result", median(encode))
        report("verify and decode a stored 28,800-word result", median(decode))
        report("read the same result again, as Rebind and Reconcile do once the reader has opened it", median(again))
    }

    @MainActor
    func testContinuousReaderScrollsTheFullTwoHourTranscript() async throws {
        let fixture = try await Fixture(seconds: 7_200)
        defer { fixture.end() }
        _ = try await fixture.attach()
        let reader = HostedReader(fixture.session)
        defer { reader.close() }
        try await reader.wait(for: "all 28,800 words") { reader.flow?.layoutResult?.ranges.count == 28_800 }
        reader.showWindow()
        try await reader.settle()
        let flow = try XCTUnwrap(reader.flow)
        let table = try XCTUnwrap(flow.documentView as? NSTableView)
        let layout = try XCTUnwrap(flow.layoutResult)
        XCTAssertTrue(flow.wantsLayer)
        XCTAssertGreaterThan(flow.frame.height, 150)
        XCTAssertGreaterThan(table.numberOfRows, 2400)
        var durations: [Duration] = []
        var maxCells = 0
        for fraction in 0...100 {
            let word = fraction * (layout.ranges.count - 1) / 100
            let row = try XCTUnwrap(layout.row(for: word))
            let start = ContinuousClock.now
            flow.reveal(word, atTop: false)
            table.layoutSubtreeIfNeeded()
            flow.displayIfNeeded()
            durations.append(ContinuousClock.now - start)
            XCTAssertTrue(NSLocationInRange(row, table.rows(in: table.visibleRect)))
            var available = 0
            table.enumerateAvailableRowViews { _, _ in available += 1 }
            maxCells = max(maxCells, available)
        }
        // Click a word well beyond the former 160-word boundary through AppKit hit testing.
        let target = 14_401
        flow.reveal(target, atTop: true)
        table.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(layout.row(for: target))
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true))
        let id = "transcript.word." + layout.source.words[target].id
        let ax = try XCTUnwrap((cell.accessibilityChildren() as? [NSAccessibilityElement])?.first {
            $0.accessibilityIdentifier() == id
        })
        let rect = ax.accessibilityFrameInParentSpace()
        let location = cell.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let window = try XCTUnwrap(cell.window)
        let hit = try XCTUnwrap(window.contentView?.hitTest(location))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
        }
        XCTAssertEqual(fixture.session.editor.playhead, layout.source.words[target].range.from.seconds, accuracy: 0.001)
        try await reader.settle()
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 124))
        XCTAssertEqual(fixture.session.presentation.transcriptKeyHandler?(right, [.shift]), true)
        try await reader.settle()
        XCTAssertEqual(fixture.session.editor.playhead, layout.source.words[target + 1].range.from.seconds, accuracy: 0.001)
        try await reader.wait(for: "extended word selection") { reader.flow?.selection?.positions == target...(target + 1) }
        XCTAssertGreaterThan(maxCells, 0)
        XCTAssertLessThan(maxCells, 100)
        XCTAssertTrue(flow.layoutResult === layout)
        report("28,800 words, median scroll and layout across 101 positions", median(durations),
               "\(table.numberOfRows) lines, at most \(maxCells) materialized rows")
    }

    @MainActor
    func testPlayheadTicksDoNotRebuildThePane() async throws {
        let fixture = try await Fixture(seconds: 600)
        defer { fixture.end() }
        _ = try await fixture.attach()
        TranscriptPaneProbe.status = ""
        let reader = HostedReader(fixture.session)
        defer { reader.close() }
        try await reader.wait(for: "the transcript") { reader.flow?.layoutResult?.source.words.count == 2400 }
        for _ in 0..<10 { try await reader.settle() }

        // Four seconds of preview at 30 ticks a second. A word lasts a quarter of a second.
        let ticks = 120
        let initializations = TranscriptPaneProbe.initializations
        let bodies = TranscriptPaneProbe.bodyEvaluations
        let lines = TranscriptPaneProbe.lineConfigurations
        let started = ContinuousClock.now
        for tick in 0..<ticks {
            fixture.session.editor.seek(1 + Double(tick) / 30)
            try await reader.settle()
        }
        let elapsed = ContinuousClock.now - started
        report("pane per 120 playhead ticks (16 word changes)", elapsed,
               "init \(TranscriptPaneProbe.initializations - initializations), body \(TranscriptPaneProbe.bodyEvaluations - bodies), "
               + "line configurations \(TranscriptPaneProbe.lineConfigurations - lines)")
        // The pane redraws when the word under the playhead changes, and then only the word
        // left and the word reached.
        XCTAssertLessThanOrEqual(TranscriptPaneProbe.bodyEvaluations - bodies, 20)
        XCTAssertLessThanOrEqual(TranscriptPaneProbe.lineConfigurations - lines, 40)
    }
}

extension TranscriptResponsivenessTests {
    @MainActor
    func testConcurrentIndexMatchesTheSerialBuild() async throws {
        func encoded<T: Encodable>(_ value: T) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(value)
        }
        func assertSame(_ serial: TranscriptIndex, _ concurrent: TranscriptIndex, _ name: String) throws {
            for space in TranscriptSpace.allCases {
                XCTAssertEqual(try encoded(serial.readAll(space: space)), try encoded(concurrent.readAll(space: space)),
                               "\(name) \(space)")
                for phrase in ["talked about", "we had seen", "lantern", "stayed for a while and"] {
                    XCTAssertEqual(try encoded(serial.search(phrase, space: space, limit: 500)),
                                   try encoded(concurrent.search(phrase, space: space, limit: 500)), "\(name) \(space) \(phrase)")
                }
                XCTAssertEqual(try encoded(serial.inputCoverage(space: space)), try encoded(concurrent.inputCoverage(space: space)))
            }
            XCTAssertEqual(try encoded(serial.gaps), try encoded(concurrent.gaps), name)
            XCTAssertEqual(try encoded(serial.speakers), try encoded(concurrent.speakers), name)
            XCTAssertEqual(try encoded(serial.authoredReview), try encoded(concurrent.authoredReview), name)
            XCTAssertEqual(serial.timelineRevision, concurrent.timelineRevision)
            XCTAssertEqual(serial.transcriptRevision, concurrent.transcriptRevision)
        }

        // A multicam cut with a replayed range, a dropped range and a correction.
        var multicam = Self.multicamConversation(words: 2_400)
        let end = multicam.project.range.to
        multicam.project.assembly = [.init(from: .init(numerator: 30), to: .init(numerator: 90)),
                                     .init(from: .init(numerator: 30), to: .init(numerator: 45)),
                                     .init(from: .init(numerator: 200), to: end)]
        let attached = TranscriptAttachment(id: "dialogue", asset: .init(file: "Interview.transcripts/" + String(repeating: "a", count: 64) + ".json",
                                                                       sha256: String(repeating: "a", count: 64)),
                                            bindings: multicam.document.tracks.map {
                                                TranscriptBinding(trackID: $0.id, sourceID: $0.id, streamIndex: 0)
                                            })
        let plain = try TranscriptIndex(document: multicam.document, attachment: attached,
                                        project: .multicam(multicam.project), timelineRevision: 7)
        let word = try XCTUnwrap(plain.read(space: .source, offset: 40, limit: 1).items.first)
        let record = try TranscriptEditorial.makeRecord(
            change: .replaceText(text: "lantern"),
            selections: [.init(firstWordID: word.wordID, space: .source, firstOccurrenceID: word.id)], in: plain)
        let serial = try TranscriptIndex(document: multicam.document, attachment: attached,
                                         project: .multicam(multicam.project), timelineRevision: 7, records: [record])
        let concurrent = try TranscriptIndex.concurrent(document: multicam.document, attachment: attached,
                                                        project: .multicam(multicam.project),
                                                        timelineRevision: 7, records: [record])
        XCTAssertGreaterThan(serial.read(space: .currentCut, limit: 1).total, 0)
        XCTAssertGreaterThan(serial.read(space: .group, limit: 1).total, 0)
        XCTAssertFalse(serial.authoredReview.isEmpty)
        try assertSame(serial, concurrent, "multicam")
        for spaces in [Set<TranscriptSpace>(), [.source], [.group, .currentCut]] {
            let part = try TranscriptIndex.concurrent(document: multicam.document, attachment: attached,
                                                      project: .multicam(multicam.project),
                                                      timelineRevision: 7, records: [record], spaces: spaces)
            let expected = try TranscriptIndex(document: multicam.document, attachment: attached,
                                               project: .multicam(multicam.project),
                                               timelineRevision: 7, records: [record], spaces: spaces)
            try assertSame(expected, part, "multicam \(spaces.map(\.rawValue).sorted())")
        }

        // A sequence over real media, after a deletion.
        let fixture = try await Fixture(seconds: 600)
        defer { fixture.end() }
        let controller = fixture.session.transcript
        let attachment = try await fixture.attach()
        let first = try controller.index(attachmentID: attachment.id)
        let removed = try XCTUnwrap(first.read(space: .currentCut, offset: 200, limit: 1).items.first)
        _ = try controller.apply(controller.plan(.init(action: .delete, selections: [
            .init(firstWordID: removed.wordID, firstOccurrenceID: removed.id)
        ], boundaryPolicy: .exact)))
        let expected = try TranscriptIndex(document: fixture.document, attachment: controller.attachment(),
                                           project: controller.project, projectURL: controller.assetContext(),
                                           sequenceMedia: fixture.session.editor.transcriptMedia,
                                           timelineRevision: controller.timelineRevision)
        XCTAssertEqual(expected.read(space: .currentCut, limit: 1).total, 2_399)
        try assertSame(expected, controller.index(attachmentID: attachment.id), "sequence through the controller")
        try assertSame(expected, .concurrent(document: fixture.document, attachment: controller.attachment(),
                                             project: controller.project, projectURL: controller.assetContext(),
                                             sequenceMedia: fixture.session.editor.transcriptMedia,
                                             timelineRevision: controller.timelineRevision), "sequence")
    }

    @MainActor
    func testAnEditLeavesTheReaderWhereItWas() async throws {
        let fixture = try await Fixture(seconds: 600)
        defer { fixture.end() }
        let controller = fixture.session.transcript
        let attachment = try await fixture.attach()
        let index = try await controller.indexedTranscript(attachmentID: attachment.id)
        func word(_ position: Int) throws -> TranscriptOccurrence {
            try XCTUnwrap(index.read(space: .currentCut, offset: position, limit: 1).items.first)
        }
        func delete(_ position: Int) async throws {
            let current = try await controller.indexedTranscript(attachmentID: attachment.id)
            let target = try XCTUnwrap(current.read(space: .currentCut, offset: position, limit: 1).items.first)
            _ = try controller.apply(controller.plan(.init(action: .delete, selections: [
                .init(firstWordID: target.wordID, firstOccurrenceID: target.id)
            ], boundaryPolicy: .exact)))
        }
        let scope = TranscriptPane.BrowseScope(space: .currentCut, speaker: nil, source: nil, file: nil, track: nil,
                                               assembly: nil, clip: nil, inferred: false)
        func place(query: String = "", anchor: TranscriptOccurrence? = nil, anchorIndex: Int = 0,
                   selection: (TranscriptOccurrence, TranscriptOccurrence)? = nil,
                   match: (Int, TranscriptOccurrence)? = nil) -> TranscriptReaderPlace {
            TranscriptReaderPlace(owner: fixture.session.mcpHandle, attachmentID: attachment.id, resultID: attachment.resultID,
                                  selectedAttachmentID: nil, scope: scope, searchText: query, query: query,
                                  followPlayback: true, anchor: anchor, anchorIndex: anchorIndex,
                                  selectionStart: selection?.0, selectionEnd: selection?.1,
                                  matchNumber: match?.0, matchWord: match?.1)
        }

        // The reader was hidden at word 480 with five words selected.
        let memory = fixture.session.transcriptPaneMemory
        memory.place = place(anchor: try word(480), selection: (try word(500), try word(504)))
        TranscriptPaneProbe.status = ""
        let reader = HostedReader(fixture.session)
        defer { reader.close() }
        try await reader.wait(for: "the remembered word") { reader.flow?.topWord == 480 }

        // Removing an earlier word moves the viewport anchor down by one index.
        try await delete(100)
        try await reader.wait(for: "the same visible word after an earlier edit") {
            reader.flow?.layoutResult?.source.words.count == 2399 && reader.flow?.topWord == 479
        }
        // Hiding the pane, as another inspector tab does, keeps the viewport and the whole selection.
        memory.place = nil
        reader.state.showsTranscript = false
        try await reader.wait(for: "the pane to leave") { memory.place?.anchor != nil }
        for _ in 0..<20 { try await reader.settle() }
        let kept = try XCTUnwrap(memory.place)
        XCTAssertEqual(kept.anchor?.wordID, try word(480).wordID)
        XCTAssertEqual(kept.selectionStart?.wordID, try word(500).wordID)
        XCTAssertEqual(kept.selectionEnd?.wordID, try word(504).wordID)
        XCTAssertEqual(kept.selectionStart?.timelineRevision, controller.timelineRevision)
        TranscriptPaneProbe.status = ""
        reader.state.showsTranscript = true
        try await reader.wait(for: "the scroll position after the pane returns") { reader.flow?.layoutResult?.source.words.count == 2399 && reader.flow?.topWord == 479 }
        memory.place = nil
        reader.state.showsTranscript = false
        try await reader.wait(for: "the pane to leave again") { memory.place != nil }
        for _ in 0..<20 { try await reader.settle() }

        // The reader is on the sixth of ten matches. An edit elsewhere leaves it there.
        let matches = index.search("lantern", space: .currentCut).items
        XCTAssertEqual(matches.count, 10)
        memory.place = place(query: "lantern", match: (5, try XCTUnwrap(matches[5].words.first)))
        TranscriptPaneProbe.status = ""
        reader.state.showsTranscript = true
        try await reader.wait(for: "the remembered match") { TranscriptPaneProbe.status == "Match 6 of 10" }
        try await delete(50)
        let revision = controller.timelineRevision
        try await reader.wait(for: "the reader to index the edit") {
            fixture.session.transcript.cachedIndex(attachmentID: attachment.id)?.timelineRevision == revision
        }
        for _ in 0..<40 { try await reader.settle() }
        XCTAssertEqual(TranscriptPaneProbe.status, "Match 6 of 10")
        // Removing an earlier match makes it the fifth of nine.
        let earlier = try await controller.indexedTranscript(attachmentID: attachment.id)
        let target = try XCTUnwrap(earlier.search("lantern", space: .currentCut).items[1].words.first)
        _ = try controller.apply(controller.plan(.init(action: .delete, selections: [
            .init(firstWordID: target.wordID, firstOccurrenceID: target.id)
        ], boundaryPolicy: .exact)))
        try await reader.wait(for: "the same match under its new number") { TranscriptPaneProbe.status == "Match 5 of 9" }
    }

    func testRestoredWordFollowsACutButNeverMovesToAReplay() throws {
        let file = "/tmp/MPCut-replay/Interview.wav"
        let track = TranscriptTrack(id: "lav", name: "Lav", streamIndex: 0)
        let document = TranscriptDocument(clock: .session, tracks: [track], words: (0..<8).map { second in
            let start = RationalTime(numerator: Int64(second)), end = RationalTime(numerator: Int64(second + 1))
            return .init(id: "w\(second)", text: "word\(second)", start: start, end: end,
                         observations: [.init(trackID: track.id, start: start, end: end, evidence: .recognized)])
        })
        let attachment = TranscriptAttachment(id: "dialogue", asset: .init(file: "Interview.transcripts/" + String(repeating: "b", count: 64) + ".json",
                                                                         sha256: String(repeating: "b", count: 64)),
                                              bindings: [.init(trackID: track.id, file: file, streamIndex: 0)])
        func clip(_ id: String, _ from: Int64, _ to: Int64) -> CutSequenceClip {
            .init(id: id, file: file, from: .init(numerator: from), to: .init(numerator: to))
        }
        func index(_ clips: [CutSequenceClip], revision: Int) throws -> TranscriptIndex {
            try TranscriptIndex(document: document, attachment: attachment, project: .sequence(clips),
                                projectURL: URL(fileURLWithPath: "/tmp/MPCut-replay/Interview.cut"), timelineRevision: revision)
        }
        func restored(_ word: TranscriptOccurrence, from earlier: TranscriptIndex, in later: TranscriptIndex) -> TranscriptOccurrence? {
            later.revalidatedPaneWord(word, in: .currentCut, after: earlier)
        }

        // One clip, then the same clip with its fourth word cut out. The part after the cut is a new clip.
        let whole = try index([clip("take", 0, 8)], revision: 1)
        XCTAssertEqual(whole.read(space: .currentCut, limit: 1).total, 8)
        let removed = try XCTUnwrap(whole.locate(wordID: "w3", space: .currentCut).first)
        let later = try XCTUnwrap(whole.locate(wordID: "w5", space: .currentCut).first)
        let cut = try index([clip("take", 0, 3), clip("rest", 4, 8)], revision: 2)
        XCTAssertNil(cut.revalidatedPaneWord(later, in: .currentCut), "The clip ID changed, so the strict match fails.")
        let followed = try XCTUnwrap(restored(later, from: whole, in: cut))
        XCTAssertEqual(followed.clipID, "rest")
        XCTAssertEqual(followed.range.from, .init(numerator: 4))
        XCTAssertNil(restored(removed, from: whole, in: cut))

        // The take is replayed. Deleting a word from the first pass leaves its replay, which is another occurrence.
        let replayed = try index([clip("take", 0, 8), clip("replay", 0, 8)], revision: 3)
        let first = try XCTUnwrap(replayed.locate(wordID: "w3", space: .currentCut).first { $0.clipID == "take" })
        let trimmed = try index([clip("take", 0, 3), clip("rest", 4, 8), clip("replay", 0, 8)], revision: 4)
        XCTAssertEqual(trimmed.locate(wordID: "w3", space: .currentCut).map(\.clipID), ["replay"])
        XCTAssertNil(restored(first, from: replayed, in: trimmed), "A selection must not move to the replay.")
    }

    @MainActor
    func testCorrectionNamesTheRevisionItsSelectionWasReadFrom() async throws {
        let fixture = try await Fixture(seconds: 60)
        defer { fixture.end() }
        let controller = fixture.session.transcript
        let attachment = try await fixture.attach()
        let index = try controller.index(attachmentID: attachment.id)
        let word = try XCTUnwrap(index.read(space: .source, offset: 3, limit: 1).items.first)
        let selection = TranscriptWordSelection(firstWordID: word.wordID, space: .source, firstOccurrenceID: word.id,
                                                attachmentID: attachment.id)
        let read = try controller.editRevision(attachmentID: attachment.id)

        // A corrected result replaces the attachment's while the correction sheet is open.
        var revised = fixture.document
        revised.words[3].text = "longer"
        let replacement = fixture.directory.appendingPathComponent("Revised.json")
        try TranscriptCodec.encode(revised, format: .json).write(to: replacement)
        let replaced = try controller.importTranscript(replacement, format: .json, replacing: attachment.id)
        XCTAssertNotEqual(replaced.resultID, attachment.resultID)
        XCTAssertThrowsError(try controller.correct(.replaceText(text: "briefly"), selection: selection,
                                                    attachmentID: attachment.id, expecting: read)) {
            XCTAssertEqual(($0 as? CutError)?.code, "stale_transcript_plan")
        }
        XCTAssertTrue(controller.state.authoring.isEmpty)

        // The same selection read again from the current result is accepted.
        let current = try controller.index(attachmentID: attachment.id)
        let again = try XCTUnwrap(current.read(space: .source, offset: 3, limit: 1).items.first)
        let record = try controller.correct(.replaceText(text: "briefly"),
                                            selection: .init(firstWordID: again.wordID, space: .source,
                                                             firstOccurrenceID: again.id, attachmentID: attachment.id),
                                            attachmentID: attachment.id,
                                            expecting: controller.editRevision(attachmentID: attachment.id))
        XCTAssertEqual(controller.state.authoring, [record])
    }

    @MainActor
    func testSteppingThroughSourceWordsKeepsOneAuditionPanel() async throws {
        _ = NSApplication.shared
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka",
                                                  subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectForPreview(url)
        let stream = try XCTUnwrap(media.streams.first { $0.kind == "audio" })
        func passage(_ step: Int64) throws -> PreviewRange {
            let from = RationalTime(numerator: step, denominator: 100)
            return try transcriptAuditionRange(media: media, presentation: .init(from: from, to: try from.adding(.init(numerator: 1, denominator: 100))),
                                               streamIndex: stream.index, clockOffset: .zero,
                                               indexedInPresentationClock: true, includeLead: false)
        }
        var closed = 0
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: nil) { note in
            if (note.object as? NSWindow)?.title.hasPrefix("Source Context") == true { closed += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let panel = TranscriptAuditionPanel()
        panel.show(try passage(0), streamIndex: stream.index, parent: nil, autoplay: false, clockOffset: .zero)
        let shown = NSApp.windows.filter { $0.title.hasPrefix("Source Context") }
        print("MEASURE audition panel in a test process: visible \(shown.map(\.isVisible)), on screen \(shown.map { $0.occlusionState.contains(.visible) }), activation policy \(NSApp.activationPolicy().rawValue)")
        let started = ContinuousClock.now
        for step in 1...12 {
            panel.show(try passage(Int64(step)), streamIndex: stream.index, parent: nil, autoplay: false, clockOffset: .zero)
        }
        report("12 Source steps with the audition panel open", ContinuousClock.now - started, "panels closed and rebuilt \(closed)")
        XCTAssertEqual(closed, 0, "A step moves the open panel to the new passage.")
        try await Task.sleep(for: .milliseconds(250))
        panel.close()
        XCTAssertEqual(closed, 1)
    }

    @MainActor
    func testJobListShowsTheRunningJobsLatestRecord() throws {
        func job(_ state: TranscriptJobState, id: UUID = UUID()) -> TranscriptJobRecord {
            TranscriptJobRecord(id: id, documentID: "/tmp/Interview.cut", options: .init(), policy: .reuse, state: state,
                                sessions: [], workingDirectory: URL(fileURLWithPath: "/tmp"))
        }
        let earlier = job(.completed)
        let stored = job(.preparing)
        var live = stored
        live.state = .running
        live.message = "Recognizing 40%"
        XCTAssertEqual(TranscriptJobList.current([stored, earlier], live: live), [live, earlier])
        XCTAssertEqual(TranscriptJobList.current([earlier], live: live), [live, earlier])
        XCTAssertEqual(TranscriptJobList.current([stored, earlier], live: nil), [stored, earlier])
    }

    @MainActor
    func testFinishedJobAttachesWithoutHoldingTheMainThread() async throws {
        _ = NSApplication.shared
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("MPCut-attach-\(UUID())", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("fixture-helper")
        try files.copyItem(at: try XCTUnwrap(Bundle.module.url(forResource: "TranscriptLifecycleProvider", withExtension: "py",
                                                               subdirectory: "Fixtures")), to: helper)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let previous = ProcessInfo.processInfo.environment["MPCUT_TRANSCRIBERRR_HELPER"]
        let previousExtraWords = ProcessInfo.processInfo.environment["MPCUT_FIXTURE_EXTRA_WORDS"]
        setenv("MPCUT_TRANSCRIBERRR_HELPER", helper.path, 1)
        setenv("MPCUT_FIXTURE_EXTRA_WORDS", "24000", 1)
        defer {
            if let previous { setenv("MPCUT_TRANSCRIBERRR_HELPER", previous, 1) }
            else { unsetenv("MPCUT_TRANSCRIBERRR_HELPER") }
            if let previousExtraWords { setenv("MPCUT_FIXTURE_EXTRA_WORDS", previousExtraWords, 1) }
            else { unsetenv("MPCUT_FIXTURE_EXTRA_WORDS") }
        }
        let source = folder.appendingPathComponent("Camera.mov")
        try files.copyItem(at: try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov",
                                                               subdirectory: "Fixtures")), to: source)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let session = ProjectSession(id: UUID(), preferences: preferences)
        session.isMulticam = true
        defer { session.multicam.reset() }
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(source)
        session.multicam.confirmSetup(drafts: [.init(source: .init(id: "camera", file: source.path), media: media)],
                                      opening: "camera", audio: .none)
        let controller = session.transcript
        let store = TranscriptJobStore(directory: LiveTranscriptController.jobsDirectory)
        func until(_ description: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(60)
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    XCTFail("Timed out waiting for \(description). \(controller.jobError ?? "")")
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        let id = try controller.start(options: .init(engine: "lifecycle-fixture"))
        defer {
            if let record = try? store.status(id) {
                if record.ownerToken != nil { _ = try? store.interrupt(id) }
                try? store.discard(documentID: record.documentID)
            }
        }
        var stalls: [Int] = []
        let idle = await MainStall.measure { try? await Task.sleep(for: .milliseconds(300)) }
        for attempt in 1...3 {
            if attempt > 1 { try controller.retry(id) }
            try await until("the helper to start attempt \(attempt)") {
                files.fileExists(atPath: folder.appendingPathComponent("started-\(attempt)").path)
            }
            // The helper is released and the editor is otherwise idle, as it is during playback.
            let stall = MainStall()
            try Data("completed".utf8).write(to: folder.appendingPathComponent("release-\(attempt)"), options: .atomic)
            try await until("attempt \(attempt) to attach") { controller.activeJobID == nil }
            stalls.append(stall.finish())
            XCTAssertEqual(try controller.status(id).state, .completed, controller.jobError ?? "")
            XCTAssertEqual(controller.state.attachments.count, 1)
        }
        XCTAssertEqual(try controller.document().words.count, 24_001)
        report("longest main-thread stall while a 24,001-word result attaches, three deliveries", count: stalls.max() ?? 0)
        print("MEASURE main-thread stalls per delivery: \(stalls) ms · idle floor \(idle) ms")
        XCTAssertLessThan(stalls.sorted()[1], max(150, idle * 8), "Attaching a finished job held the main thread.")
    }

    @MainActor
    func testOutdatedHelperStopsAJobBeforeAudioIsStaged() async throws {
        _ = NSApplication.shared
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("MPCut-helper-\(UUID())", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: folder) }
        // A helper from before sessions existed answers `capabilities` without a session schema.
        let helper = folder.appendingPathComponent("transcriberrr")
        try Data("#!/bin/sh\necho '{\"version\":\"0.9\",\"engines\":[]}'\n".utf8).write(to: helper)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let previous = ProcessInfo.processInfo.environment["MPCUT_TRANSCRIBERRR_HELPER"]
        setenv("MPCUT_TRANSCRIBERRR_HELPER", helper.path, 1)
        defer {
            if let previous { setenv("MPCUT_TRANSCRIBERRR_HELPER", previous, 1) }
            else { unsetenv("MPCUT_TRANSCRIBERRR_HELPER") }
        }
        let source = folder.appendingPathComponent("Camera.mov")
        try files.copyItem(at: try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov",
                                                               subdirectory: "Fixtures")), to: source)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let session = ProjectSession(id: UUID(), preferences: preferences)
        session.isMulticam = true
        defer { session.multicam.reset() }
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(source)
        session.multicam.confirmSetup(drafts: [.init(source: .init(id: "camera", file: source.path), media: media)],
                                      opening: "camera", audio: .none)
        let controller = session.transcript
        let store = TranscriptJobStore(directory: LiveTranscriptController.jobsDirectory)

        do {
            try await controller.checkHelper()
            XCTFail("A helper without session support passed the check.")
        } catch {
            XCTAssertEqual((error as? CutError)?.code, "transcript_capability_missing")
        }
        let id = try controller.start(options: .init(engine: "lifecycle-fixture"))
        defer {
            if let record = try? store.status(id) {
                if record.ownerToken != nil { _ = try? store.interrupt(id) }
                try? store.discard(documentID: record.documentID)
            }
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.activeJobID != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(controller.activeJobID)
        XCTAssertTrue(controller.jobError?.contains("Update Transcriberrr") == true, controller.jobError ?? "No error was reported.")
        // Preparation never ran, so there is no job record and no extracted audio to clean up.
        let record = try? store.status(id)
        XCTAssertNil(record, "Staged audio: \(record?.sessions.flatMap(\.tracks).compactMap(\.audio?.path) ?? [])")

        setenv("MPCUT_TRANSCRIBERRR_HELPER", folder.appendingPathComponent("missing").path, 1)
        do {
            try await controller.checkHelper()
            XCTFail("A missing helper passed the check.")
        } catch {
            XCTAssertEqual((error as? CutError)?.code, "transcript_helper_unavailable")
        }
    }
}

private struct PlaybackHost: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var host: HostState
    let session: ProjectSession

    var body: some View {
        HSplitView {
            Text(String(editor.playhead)).frame(minWidth: 330, maxWidth: .infinity)
            if host.showsTranscript {
                TranscriptPane(session: session).equatable()
                    .frame(minWidth: 315, idealWidth: 380, maxWidth: 650)
                    .frame(height: 700)
            }
        }
        .frame(width: 900, height: 700)
    }
}

@MainActor
private final class HostState: ObservableObject {
    @Published var showsTranscript = true
}

/// A window holding the reader beside a view that redraws for every tick.
@MainActor
private final class HostedReader {
    let state = HostState()
    private let host: NSHostingView<PlaybackHost>
    private let window: NSWindow

    init(_ session: ProjectSession) {
        host = NSHostingView(rootView: PlaybackHost(editor: session.editor, host: state, session: session))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
                          backing: .buffered, defer: true)
        window.contentView = host
        window.setContentSize(NSSize(width: 900, height: 700))
    }

    func settle() async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(4))
        host.layoutSubtreeIfNeeded()
    }

    func wait(for description: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(description). The reader shows ‘\(TranscriptPaneProbe.status)’.")
                throw CancellationError()
            }
            try await settle()
        }
    }

    var flow: TranscriptFlowScrollView? {
        func find(in view: NSView) -> TranscriptFlowScrollView? {
            if let flow = view as? TranscriptFlowScrollView { return flow }
            for child in view.subviews { if let result = find(in: child) { return result } }
            return nil
        }
        return find(in: host)
    }

    func showWindow() { window.orderBack(nil) }

    func close() { window.orderOut(nil); window.contentView = nil }
}

/// The longest interval in which the main queue ran nothing, in milliseconds.
@MainActor
final class MainStall {
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var last = DispatchTime.now().uptimeNanoseconds
    private var longest: UInt64 = 0

    init() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.beat() }
        timer.resume()
    }

    private func beat() {
        let now = DispatchTime.now().uptimeNanoseconds
        longest = max(longest, now - last)
        last = now
    }

    func finish() -> Int {
        beat()
        timer.cancel()
        return Int(longest / 1_000_000)
    }

    static func measure(_ work: () async -> Void) async -> Int {
        let stall = MainStall()
        await work()
        return stall.finish()
    }
}

func median(_ durations: [Duration]) -> Duration {
    durations.sorted()[durations.count / 2]
}

func report(_ label: String, _ duration: Duration, _ detail: String = "") {
    let milliseconds = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    print("MEASURE \(label): \(String(format: "%.1f", milliseconds)) ms" + (detail.isEmpty ? "" : " · " + detail))
}

func report(_ label: String, count: Int) {
    print("MEASURE \(label): \(count)")
}

/// A sequence over one silent recording with a generated conversation, as the window benchmark uses.
@MainActor
final class Fixture {
    let directory: URL
    let session: ProjectSession
    let document: TranscriptDocument
    private let binding: TranscriptBinding

    init(seconds: Int) async throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MPCut-reader-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = directory.appendingPathComponent("Interview.wav")
        let rate = 8_000
        let size = UInt32(seconds * rate * 2)
        func bytes<T: FixedWidthInteger>(_ number: T) -> Data {
            var value = number.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        var header = Data("RIFF".utf8) + bytes(size + 36) + Data("WAVEfmt ".utf8) + bytes(UInt32(16))
        header += bytes(UInt16(1)) + bytes(UInt16(1)) + bytes(UInt32(rate)) + bytes(UInt32(rate * 2))
        header += bytes(UInt16(2)) + bytes(UInt16(16)) + Data("data".utf8) + bytes(size)
        try header.write(to: media)
        let audio = try FileHandle(forWritingTo: media)
        try audio.truncate(atOffset: UInt64(header.count) + UInt64(size))
        try audio.close()

        let script = ["We", "stayed", "for", "a", "while", "and", "talked", "about", "what", "we", "had", "seen."]
        var json = #"{"source":"Interview.wav","duration_seconds":\#(seconds),"metadata":{},"speaker_names":["Host","Guest"],"segments":["#
        for segment in 0..<(seconds / 3) {
            if segment > 0 { json += "," }
            let start = segment * 3
            json += #"{"start":\#(start),"end":\#(start + 3),"speaker":\#(segment % 2),"words":["#
            for index in script.indices {
                if index > 0 { json += "," }
                let time = Double(start) + Double(index) / 4
                let word = start % 60 == 3 && index == 8 ? "lantern" : script[index]
                json += #"{"text":"\#(word)","start":\#(time),"end":\#(time + 0.25)}"#
            }
            json += "]}"
        }
        json += "]}"
        document = try TranscriptCodec.decode(Data(json.utf8), format: .json)

        let clips = [CutSequenceClip(id: UUID().uuidString, file: media.path, from: .zero, to: .init(numerator: Int64(seconds)))]
        let project = directory.appendingPathComponent("Interview.cut")
        try CutProject.sequence(clips).save(to: project)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        preferences.historyLimit = 20
        session = ProjectSession(id: UUID(), preferences: preferences)
        try session.editor.openProject(clips, at: project)
        let deadline = ContinuousClock.now + .seconds(60)
        while !session.editor.canEdit, session.editor.alert == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard session.editor.canEdit else {
            throw CutError(code: "test_fixture", message: session.editor.alert?.message ?? session.editor.statusMessage)
        }
        let path = try XCTUnwrap(session.editor.sequenceClips.first?.file)
        let stream = try XCTUnwrap(session.editor.transcriptMedia[path]?.streams.first { $0.kind == "audio" })
        binding = TranscriptBinding(trackID: try XCTUnwrap(document.tracks.first?.id), file: path, streamIndex: stream.index)
    }

    func attach() async throws -> TranscriptAttachment {
        try await session.transcript.attachImportedTranscript(document, bindings: [binding], origin: .zero)
    }

    func end() {
        session.transcript.prepareForWindowEnd()
        session.editor.endSession()
        try? FileManager.default.removeItem(at: directory)
    }
}
