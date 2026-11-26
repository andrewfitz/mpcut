import XCTest
import MPCutCore
@testable import MPCutApp

final class MCPTranscriptContractTests: XCTestCase {
    func testMergedProjectIndexFollowsAttachmentSnapshotsAndSpace() throws {
        let cache = MCPTranscriptProjectIndexCache()
        let first = try transcriptIndex("first")
        let second = try transcriptIndex("second")
        let replacement = try transcriptIndex("replacement", attachmentID: "second")

        let original = cache.index(for: [first, second], space: .source)
        XCTAssertEqual(original.attachmentResults.count, 2)
        XCTAssertEqual(original.read().items.map(\.text), ["first", "second"])
        let cached = cache.index(for: [first, second], space: .source)
        XCTAssertEqual(cached.search("second").items.first?.words.first?.text, "second")
        XCTAssertEqual(cache.index(for: [first, replacement], space: .source).read().items.map(\.text),
                       ["first", "replacement"])
        XCTAssertTrue(cache.index(for: [first, replacement], space: .group).read().items.isEmpty)
    }

    func testMergedProjectIndexBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MPCUT_TRANSCRIPT_BENCH"] == "1" else {
            throw XCTSkip("Set MPCUT_TRANSCRIPT_BENCH=1 to measure.")
        }
        let indexes = [try transcriptIndex("first", count: 28_800), try transcriptIndex("second", count: 28_800)]
        let cache = MCPTranscriptProjectIndexCache()
        let warm = cache.index(for: indexes, space: .source)
        XCTAssertEqual(warm.read(limit: 1).total, 57_600)
        var uncached: [Duration] = []
        var cached: [Duration] = []
        for _ in 0..<7 {
            var start = ContinuousClock.now
            let built = TranscriptProjectIndex(indexes: indexes, space: .source)
            uncached.append(ContinuousClock.now - start)
            start = ContinuousClock.now
            let reused = cache.index(for: indexes, space: .source)
            cached.append(ContinuousClock.now - start)
            let baseline = built.read(offset: 28_799, limit: 50)
            let candidate = reused.read(offset: 28_799, limit: 50)
            XCTAssertEqual(baseline.items.map(\.id), candidate.items.map(\.id))
            XCTAssertEqual(baseline.total, candidate.total)
        }
        print("TRANSCRIPT_BENCH mergedProjectWords=57600 uncached=\(uncached.sorted()[3]) cached=\(cached.sorted()[3])")
    }

    private func transcriptIndex(_ text: String, count: Int = 1, attachmentID: String? = nil) throws -> TranscriptIndex {
        let words = (0..<count).map { number in
            TranscriptWord(id: "\(text)-\(number)", text: text,
                           start: .init(numerator: Int64(number), denominator: 4),
                           end: .init(numerator: Int64(number + 1), denominator: 4))
        }
        let digest = String(repeating: "a", count: 64)
        let asset = TranscriptAsset(sha256: digest)
        let attachment = TranscriptAttachment(id: attachmentID ?? text, asset: asset, bindings: [])
        return try TranscriptIndex(document: TranscriptDocument(clock: .presentation, words: words),
                                   attachment: attachment, spaces: [.source])
    }

    func testCompactRowsKeepWhatReadingAndSelectingNeed() throws {
        let index = MCPTranscriptProjectIndexCache().index(for: [try transcriptIndex("word", count: 120)], space: .source)
        func json(_ value: some Encodable) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        }
        func size(_ value: Any) throws -> Int { try JSONSerialization.data(withJSONObject: value).count }
        let page = try json(index.read(limit: 100))
        let full = try XCTUnwrap(page["items"] as? [[String: Any]])
        let compact = try XCTUnwrap((TranscriptRows.compact(page) as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(compact.count, 100)
        XCTAssertEqual(Set(compact[3].keys), ["id", "word_id", "text", "from", "to", "attachment_id"])
        XCTAssertEqual(compact[3]["id"] as? String, full[3]["id"] as? String)
        XCTAssertEqual(compact[3]["word_id"] as? String, "word-3")
        XCTAssertEqual(compact[3]["from"] as? String, "3/4")
        XCTAssertEqual(compact[3]["to"] as? String, "1")
        // An unbound test word is the smallest full record. Bound, routed words run to about 2 KB each.
        XCTAssertLessThan(try size(compact) * 3, try size(full))

        // Lines join an unbroken run and keep the four identifiers a selection takes.
        let lines = TranscriptRows.lines(full)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]["words"] as? Int, 80)
        XCTAssertEqual(lines[1]["words"] as? Int, 20)
        XCTAssertEqual(lines[0]["from"] as? String, "0")
        XCTAssertEqual(lines[1]["to"] as? String, "25")
        XCTAssertEqual(lines[1]["first_word_id"] as? String, "word-80")
        XCTAssertEqual(lines[1]["last_word_id"] as? String, "word-99")
        XCTAssertEqual(lines[1]["first_occurrence_id"] as? String, full[80]["id"] as? String)
        XCTAssertEqual(lines[1]["last_occurrence_id"] as? String, full[99]["id"] as? String)
        XCTAssertEqual((lines[1]["text"] as? String)?.split(separator: " ").count, 20)
        let spaced: [[String: Any]] = [
            ["text": "  hello  ", "range": ["from": "0", "to": "1"],
             "speaker_id": "speaker", "attachment_id": "word"],
            ["text": "\tworld\n", "range": ["from": "1", "to": "2"],
             "speaker_id": "speaker", "attachment_id": "word"]
        ]
        XCTAssertEqual(TranscriptRows.lines(spaced).first?["text"] as? String, "hello world")
        XCTAssertEqual(lines[0]["attachment_id"] as? String, "word")
        XCTAssertLessThan(try size(lines) * 30, try size(full))
        // A page reports its one transcript once, and a line never joins two transcripts.
        var hoisted: [String: Any] = ["items": compact]
        TranscriptRows.hoist(&hoisted)
        XCTAssertEqual((hoisted["shared"] as? [String: String])?["attachment_id"], "word")
        XCTAssertEqual(Set(try XCTUnwrap((hoisted["items"] as? [[String: Any]])?[3]).keys), ["id", "word_id", "text", "from", "to"])
        var other = Array(full.prefix(3))
        other[2]["attachment_id"] = "second"
        XCTAssertEqual(TranscriptRows.lines(other).map { $0["words"] as? Int }, [2, 1])
        var broken = Array(full.prefix(3))
        broken[2]["speaker_id"] = "guest"
        XCTAssertEqual(TranscriptRows.lines(broken).map { $0["words"] as? Int }, [2, 1])

        // A phrase match is one row with its context as text.
        let search = try json(index.search("word word", limit: 1))
        let match = try XCTUnwrap(((TranscriptRows.compact(search) as? [String: Any])?["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(match["text"] as? String, "word word")
        XCTAssertEqual(match["words"] as? Int, 2)
        XCTAssertEqual(match["first_word_id"] as? String, "word-0")
        XCTAssertEqual(match["last_word_id"] as? String, "word-1")
        XCTAssertNil(match["before"])
        XCTAssertTrue(match["after"] is String)

        // A recording that every row repeats is reported once.
        var rows: [String: Any] = ["items": [["text": "a", "file": "/m.mov"], ["text": "b", "file": "/m.mov"]]]
        TranscriptRows.hoist(&rows)
        XCTAssertEqual(rows["shared"] as? [String: String], ["file": "/m.mov"])
        XCTAssertEqual((rows["items"] as? [[String: String]])?.map(\.keys.count), [1, 1])
        var mixed: [String: Any] = ["items": [["text": "a", "file": "/m.mov"], ["text": "b", "file": "/n.mov"]]]
        TranscriptRows.hoist(&mixed)
        XCTAssertNil(mixed["shared"])

        let schemas = try MCPSchemas.loaded.get()
        XCTAssertNoThrow(try schemas.validate(tool: "transcript_editor_words_read",
                                              arguments: ["project_handle": "test", "lines": true, "limit": 500]))
        XCTAssertNoThrow(try schemas.validate(tool: "transcript_editor_words_search",
                                              arguments: ["project_handle": "test", "query": "hello", "verbose": true]))
        XCTAssertThrowsError(try schemas.validate(tool: "transcript_editor_words_search",
                                                   arguments: ["project_handle": "test", "query": "hello", "lines": true]))
    }

    func testSearchAcceptsPagedScopedReadsAndRejectsNavigation() throws {
        let schemas = try MCPSchemas.loaded.get()
        let resultID = String(repeating: "a", count: 64)
        let search: [String: Any] = [
            "project_handle": "test", "query": "hello", "space": "current_cut",
            "expected_revision": 5, "expected_transcript_revision": 2,
            "expected_attachment_results": ["attachment": resultID],
            "attachment_id": "attachment", "result_id": resultID, "assembly_index": 1,
            "include_inferred": true, "lane_id": "dialogue", "offset": 2, "limit": 1
        ]
        XCTAssertNoThrow(try schemas.validate(tool: "transcript_editor_words_search", arguments: search))
        for extra in [["action": "seek"], ["occurrence_id": "occurrence"], ["space": "assembly"], ["lane_id": ""]] {
            XCTAssertThrowsError(try schemas.validate(tool: "transcript_editor_words_search",
                                                       arguments: search.merging(extra) { _, new in new }))
        }
        XCTAssertThrowsError(try schemas.validate(tool: "transcript_editor_occurrence_seek",
                                                   arguments: ["project_handle": "test", "occurrence_id": "occurrence"]))
    }

    func testLaneReadoutPreservesSpeakerFieldsAndAddsMetadata() throws {
        let speaker = TranscriptSpeaker(id: "guest", name: "Guest")
        let first = TranscriptLaneMetadata(id: "boom", order: 0, label: "Boom", colorSlot: 2)
        let second = TranscriptLaneMetadata(id: "lav", order: 1, label: "Lav", colorSlot: 3)
        func encoded(_ lanes: [TranscriptLaneMetadata]) throws -> [String: Any] {
            let data = try JSONEncoder().encode(TranscriptLaneReadout(speaker, lanes: lanes))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let single = try encoded([first])
        XCTAssertEqual(single["id"] as? String, "guest")
        XCTAssertEqual(single["name"] as? String, "Guest")
        XCTAssertEqual(single["lane_id"] as? String, "boom")
        XCTAssertEqual(single["lane_order"] as? Int, 0)
        XCTAssertEqual(single["lane_label"] as? String, "Boom")
        XCTAssertEqual(single["lane_color_slot"] as? Int, 2)
        let multiple = try encoded([first, second])
        XCTAssertEqual((multiple["lanes"] as? [[String: Any]])?.compactMap { $0["lane_id"] as? String }, ["boom", "lav"])
        XCTAssertEqual(Set(try encoded([]).keys), ["id", "name"])
    }

    func testSpeakerLaneReadoutUsesRecognizedTracksAcrossStoredLanes() throws {
        let boom = TranscriptTrack(id: "boom", name: "Boom", sourceID: "boom", streamIndex: 0)
        let lav = TranscriptTrack(id: "lav", name: "Lav", sourceID: "lav", streamIndex: 0)
        let end = RationalTime(numerator: 2)
        let tracks = [boom, lav]
        let words: [TranscriptWord] = [
            .init(id: "host", text: "Hello", start: .zero, end: end, speakerID: "host",
                  observations: tracks.map { .init(trackID: $0.id, start: .zero, end: end, evidence: .recognized) }),
            .init(id: "guest", text: "Hi", start: .zero, end: end, speakerID: "guest", observations: [
                .init(trackID: lav.id, start: .zero, end: end, evidence: .recognized),
                .init(trackID: boom.id, start: .zero, end: end, evidence: .inferred, basis: "alignment")
            ]),
        ]
        let document = TranscriptDocument(clock: .session, tracks: tracks,
                                          speakers: [.init(id: "host", name: "Host"), .init(id: "guest", name: "Guest")],
                                          words: words)
        let boomSelection = MulticamAudioSelection(source: boom.id, stream: 0)
        let lavSelection = MulticamAudioSelection(source: lav.id, stream: 0)
        let project = CutProject.multicam(.init(referenceAngle: "camera", range: .init(from: .zero, to: end),
            angles: [.init(id: "camera", file: "camera.mov")],
            audioSources: [.init(id: "boom", file: "boom.wav"), .init(id: "lav", file: "lav.wav")],
            audio: .fixed(boomSelection), switches: [.init(at: .zero, angle: "camera")],
            mixLanes: [.init(id: "boom-lane", target: .recording(boomSelection), label: "Boom", colorSlot: 1),
                       .init(id: "lav-lane", target: .recording(lavSelection), label: "Lav", colorSlot: 3)]))
        let index = try TranscriptIndex(document: document, project: project, spaces: [.source])
        let speakers = index.transcriptSpeakerReadouts(project: project, laneID: nil)
        XCTAssertEqual(speakers.first(where: { $0.item.id == "host" })?.lanes.map(\.id), ["boom-lane", "lav-lane"])
        XCTAssertEqual(speakers.first(where: { $0.item.id == "guest" })?.lanes.map(\.id), ["lav-lane"])
        XCTAssertEqual(index.transcriptSpeakerReadouts(project: project, laneID: "boom-lane").map(\.item.id), ["host"])
    }

    func testFileSearchHasOneCLIPathAndCannotOverrideTheOperation() throws {
        let input: [String: Any] = ["query": "hello", "project_path": "/tmp/Interview.cut", "lane_id": "dialogue"]
        let fields: [String: Any] = ["request": input, "operation_id": UUID().uuidString]
        let search = try MCPFileRequest(tool: "transcript_file_words_search", fields: fields)
        XCTAssertEqual(search.arguments, ["transcript", "words", "search", "--stdin", "--json"])
        let forwarded = try JSONSerialization.jsonObject(with: XCTUnwrap(search.input)) as? [String: String]
        XCTAssertEqual(forwarded, input as? [String: String])
        let output = input.merging(["output": "/tmp/captions.vtt"]) { _, new in new }
        XCTAssertThrowsError(try MCPFileRequest(tool: "transcript_file_words_search",
                                                 fields: fields.merging(["request": output]) { _, new in new }))
        XCTAssertThrowsError(try MCPFileRequest(tool: "transcript_file_words_search",
                                                 fields: fields.merging(["action": "export"]) { _, new in new }))
    }
}
