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
        let asset = TranscriptAsset(file: "Transcripts/\(digest).json", sha256: digest)
        let attachment = TranscriptAttachment(id: attachmentID ?? text, asset: asset, bindings: [])
        return try TranscriptIndex(document: TranscriptDocument(clock: .presentation, words: words),
                                   attachment: attachment, spaces: [.source])
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
