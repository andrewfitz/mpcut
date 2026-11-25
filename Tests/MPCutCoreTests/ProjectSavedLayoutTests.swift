import Foundation
import XCTest
@testable import MPCutCore

final class ProjectSavedLayoutTests: XCTestCase {
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testReadableDocumentIsTheSameTextHoweverTheProjectIsStored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-readable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clips = (0..<3).map {
            CutSequenceClip(id: "clip-\($0)", file: "media/a recording.mov", from: .zero, to: .init(numerator: Int64($0 + 1)))
        }
        let url = directory.appendingPathComponent("Interview.cut")
        try CutProject.sequence(clips).save(to: url, undo: [CutHistoryState(action: "Trim Clip", project: .sequence(clips))], redo: [])
        let saved = try Data(contentsOf: url)

        // The saved file, the plain document and the text itself all give one text, with
        // nothing left as a reference.
        let text = try CutProject.readableDocument(saved: saved)
        XCTAssertEqual(try CutProject.readableDocument(saved: text), text)
        let plain = try CutProject.documentJSON(saved: saved)
        XCTAssertEqual(try CutProject.readableDocument(saved: plain), text)
        let lines = String(decoding: text, as: UTF8.self).components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "{")
        XCTAssertEqual(lines.suffix(2), ["}", ""])
        XCTAssertTrue(lines.contains(#"      "id": "clip-1","#))
        XCTAssertFalse(lines.contains { $0.contains("\"refs\"") || $0.contains("\"~") })
        // Each clip names its file in full. The undo step repeats none of them.
        XCTAssertEqual(lines.filter { $0.contains(#""file": "media/a recording.mov""#) }.count, 3)
        let reordered = Data(#"{"schema_version":9,"kind":"sequence","format":"mpcut","clips":[{"to":"1","id":"clip-0","from":"0","file":"media/a recording.mov"}]}"#.utf8)
        let ordered = Data(#"{"clips":[{"file":"media/a recording.mov","from":"0","id":"clip-0","to":"1"}],"format":"mpcut","kind":"sequence","schema_version":9}"#.utf8)
        XCTAssertEqual(try CutProject.readableDocument(saved: reordered), try CutProject.readableDocument(saved: ordered))
        // The text is a project.
        try text.write(to: url)
        XCTAssertEqual(try CutProject.load(from: url), .sequence(clips))
        XCTAssertThrowsError(try CutProject.readableDocument(saved: Data("not a project".utf8)))
        XCTAssertThrowsError(try CutProject.readableDocument(saved: Data("[1]".utf8)))
    }

    func testKeysComeFromContentSoBranchesAgree() throws {
        let recording = #""Interviews 2026/a long recording name.mov""#
        let other = #""Interviews 2026/the second camera.mov""#
        func project(_ clips: [(String, String)]) -> Data {
            let rows = clips.map { #"{"file":\#($0.1),"from":"0","id":"\#($0.0)","to":"1"}"# }.joined(separator: ",")
            return Data(#"{"clips":[\#(rows)],"format":"mpcut","kind":"sequence","schema_version":9}"#.utf8)
        }
        func saved(_ document: Data) throws -> [String: Any] {
            let keyed = try XCTUnwrap(ProjectKeyedLayout.compacted(document))
            XCTAssertEqual(try ProjectKeyedLayout.expanded(keyed), document)
            return try object(keyed)
        }
        // Two branches that add clips in a different order, and one that adds another
        // recording first, give each recording the same key.
        let key = String(decoding: ProjectKeyedLayout.key(Array(recording.utf8)), as: UTF8.self)
        XCTAssertEqual(key.count, 10)
        let first = try saved(project([("a", recording), ("b", recording)]))
        let second = try saved(project([("c", other), ("d", other), ("b", recording), ("a", recording)]))
        XCTAssertEqual((first["refs"] as? [String: String])?[key], String(recording.dropFirst().dropLast()))
        XCTAssertEqual((second["refs"] as? [String: String])?[key], String(recording.dropFirst().dropLast()))
        XCTAssertEqual((second["clips"] as? [[String: Any]])?.map { $0["file"] as? String }.suffix(2), ["~" + key, "~" + key])

        // Text used once, and text too short to gain, stays where it is. The table is there all the same.
        let single = try saved(project([("a", recording), ("b", other)]))
        // Its one entry is the fixed last one, which lets an entry be added without changing another line.
        XCTAssertEqual(single["refs"] as? [String: String], ["~": ""])
        XCTAssertEqual((single["clips"] as? [[String: Any]])?.first?["file"] as? String, String(recording.dropFirst().dropLast()))
        let short = try saved(project([("a", #""a.mov""#), ("b", #""a.mov""#)]))
        XCTAssertEqual(short["refs"] as? [String: String], ["~": ""])
        // Text that begins with the marker is kept apart from a reference.
        let home = try saved(project([("a", #""~/Movies/a.mov""#), ("b", #""~""#)]))
        XCTAssertEqual((home["clips"] as? [[String: Any]])?.map { $0["file"] as? String }, ["~~/Movies/a.mov", "~~"])
    }

    func testEscapedReferenceNamesAndMarkersResolveToTheSameValues() throws {
        let keyed = Data(#"{"clips":[{"\u007e":"\u0063lip"},{"file":"\u007e\u007Ecamera","from":"0","id":"b","to":"1"}],"format":"mpcut","kind":"sequence","\u0072efs":{"\u0063lip":{"file":"\u007E\u0070ath","from":"0","id":"a","to":"1"},"path":"camera.mov"},"schema_version":9}"#.utf8)
        let clips = try XCTUnwrap(CutProject.decode(keyed).sequenceClips)
        XCTAssertEqual(clips.map(\.file), ["camera.mov", "~camera"])
        let literal = Data(#"{"path":"\u007etilde"}"#.utf8)
        let compact = try XCTUnwrap(ProjectKeyedLayout.compacted(literal))
        XCTAssertEqual(try ProjectKeyedLayout.expanded(compact), literal)
    }

    func testKeyedDocumentWithUTF8BOMOpensAndExpands() throws {
        let path = "media/a long recording name.mov"
        let clips = ["a", "b"].map {
            CutSequenceClip(id: $0, file: path, from: .zero, to: .init(numerator: 1))
        }
        let expected = CutProject.sequence(clips)
        let plain = try ProjectFile.encoded(expected, compact: true)
        let keyed = try XCTUnwrap(ProjectKeyedLayout.compacted(plain))
        let withBOM = Data([0xEF, 0xBB, 0xBF]) + keyed

        XCTAssertEqual(try CutProject.decode(withBOM), expected)
        XCTAssertEqual(try CutProject.documentJSON(saved: withBOM), plain)
        XCTAssertEqual(try CutProject.readableDocument(saved: withBOM), try CutProject.readableDocument(saved: plain))
    }

    func testHistoryWritesRepeatedValuesOnceUnderContentKeys() throws {
        func clip(_ index: Int, to: Int) -> String {
            #"{"file":"Interviews 2026/a long recording name.mov","from":"\#(index)","id":"clip-number-\#(index)","to":"\#(to)"}"#
        }
        let steps = (0..<10).map { step in
            #"{"action":"Trim Clip","clips":[\#((0..<30).map { clip($0, to: $0 == step ? 99 : $0 + 1) }.joined(separator: ","))]}"#
        }
        let project = Data(#"{"clips":[\#((0..<30).map { clip($0, to: $0 + 1) }.joined(separator: ","))],"format":"mpcut","history":{"undo":[\#(steps.joined(separator: ","))]},"kind":"sequence","schema_version":9}"#.utf8)
        let keyed = try XCTUnwrap(ProjectKeyedLayout.compacted(project))
        XCTAssertEqual(try ProjectKeyedLayout.expanded(keyed), project)
        XCTAssertLessThan(keyed.count * 2, project.count)
        let root = try object(keyed)
        // A clip an undo step keeps is a reference whose key is taken from the clip as the document holds it.
        let key = String(decoding: ProjectKeyedLayout.key(Array(clip(5, to: 6).utf8)), as: UTF8.self)
        let entry = try XCTUnwrap((root["refs"] as? [String: Any])?[key] as? [String: Any])
        XCTAssertEqual(entry["id"] as? String, "clip-number-5")
        let undo = try XCTUnwrap((root["history"] as? [String: Any])?["undo"] as? [[String: Any]])
        let kept = try XCTUnwrap(undo.first?["clips"] as? [[String: Any]])
        XCTAssertEqual(kept[5] as? [String: String], ["~": key])
        // The timeline itself is left to read as it is.
        XCTAssertEqual((root["clips"] as? [[String: Any]])?[5]["id"] as? String, "clip-number-5")
        // Saved as text, an undo step takes one line, and so does a run of numbers anywhere else.
        let text = String(decoding: try XCTUnwrap(ProjectSavedLayout.readable(keyed)), as: UTF8.self)
        let stepLines = text.split(separator: "\n").filter { $0.contains(#""Trim Clip""#) }
        XCTAssertEqual(stepLines.count, steps.count)
        for (line, expectedStep) in zip(stepLines, undo) {
            let row = line.last == "," ? line.dropLast() : line
            XCTAssertEqual(try object(Data(row.utf8)) as NSDictionary, expectedStep as NSDictionary)
        }
        let runs = String(decoding: try XCTUnwrap(ProjectSavedLayout.readable(Data(#"{"a":[[0,1],[2,30]],"b":[]}"#.utf8))), as: UTF8.self)
        XCTAssertEqual(runs, "{\n  \"a\": [\n    [0, 1],\n    [2, 30]\n  ],\n  \"b\": []\n}\n")
    }

    func testRefsTableReadsWhatAMergeCanLeaveAndRefusesWhatItCannotResolve() throws {
        func expanded(_ text: String) throws -> String {
            guard let document = try ProjectKeyedLayout.expanded(Data(text.utf8)) else {
                throw CutError(code: "no_table", message: "The text has no refs table.")
            }
            return String(decoding: document, as: UTF8.self)
        }
        // An entry nothing refers to, and text written in full beside references, are both read.
        XCTAssertEqual(try expanded(#"{"clips":[{"file":"~k1"},{"file":"b.mov"},{"file":"~~/c.mov"}],"refs":{"k1":"a.mov","unused":"z.mov"},"schema_version":9}"#),
                       #"{"clips":[{"file":"a.mov"},{"file":"b.mov"},{"file":"~/c.mov"}],"schema_version":9}"#)
        XCTAssertEqual(try expanded(#"{"history":{"undo":[{"~":"v2"},{"~":"v1"}]},"refs":{"p":"a.mov","v1":{"file":"~p"},"v2":[{"~":"v1"},{"~":"v1"}]},"schema_version":9}"#),
                       #"{"history":{"undo":[[{"file":"a.mov"},{"file":"a.mov"}],{"file":"a.mov"}]},"schema_version":9}"#)
        // A snapshot is carried exactly, marker and all.
        XCTAssertEqual(try expanded(#"{"media_snapshot":{"entries":[{"file":"~/a.mov","id":"~7"}]},"refs":{},"schema_version":9}"#),
                       #"{"media_snapshot":{"entries":[{"file":"~/a.mov","id":"~7"}]},"schema_version":9}"#)
        // Text with no table is not this layout.
        XCTAssertNil(try ProjectKeyedLayout.expanded(Data(#"{"clips":[{"file":"~k1"}],"schema_version":9}"#.utf8)))

        // A reference whose entry a merge dropped names the entry, so it can be restored.
        XCTAssertThrowsError(try expanded(#"{"clips":[{"file":"~gone"}],"refs":{},"schema_version":9}"#)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_cut_project")
            XCTAssertTrue((($0 as? CutError)?.message ?? "").contains("‘gone’"), "\($0)")
        }
        let refused = [
            #"{"clips":[{"file":"~v"}],"refs":{"v":{"a":1}},"schema_version":9}"#,
            #"{"history":{"undo":[{"~":"p"}]},"refs":{"p":"a.mov"},"schema_version":9}"#,
            #"{"history":{"undo":[{"~":7}]},"refs":{},"schema_version":9}"#,
            #"{"history":{"undo":[{"~":"a"}]},"refs":{"a":[{"~":"b"}],"b":[{"~":"a"}]},"schema_version":9}"#,
            #"{"clips":[],"refs":[],"schema_version":9}"#,
            #"{"clips":[{"file":"~"}],"refs":{},"schema_version":9}"#
        ]
        for text in refused {
            XCTAssertThrowsError(try expanded(text), text) { XCTAssertEqual(($0 as? CutError)?.code, "invalid_cut_project") }
        }
        // Each entry doubles the one before it. Expanding must stop long before memory does.
        let doubling = (1..<40).map { #""e\#($0)":[{"~":"e\#($0 - 1)"},{"~":"e\#($0 - 1)"}]"# }.joined(separator: ",")
        XCTAssertThrowsError(try expanded(#"{"history":{"undo":[{"~":"e39"}]},"refs":{"e0":["0123456789abcdef"],\#(doubling)},"schema_version":9}"#))
    }

    func testLargeExpandedReferencesAndOpaqueEmbeddedPayloads() throws {
        let literal = String(repeating: "x", count: 1 << 20)
        let count = 130
        let references = Array(repeating: #""~p""#, count: count).joined(separator: ",")
        let input = Data(#"{"paths":[\#(references)],"embedded_assets":{"transcripts":{"hash":{"literal":"~p"}}},"refs":{"p":"\#(literal)"}}"#.utf8)
        let expanded = try XCTUnwrap(ProjectKeyedLayout.expanded(input))
        let header = #"{"paths":["#
        let tail = #"],"embedded_assets":{"transcripts":{"hash":{"literal":"~p"}}}}"#
        XCTAssertEqual(expanded.count, header.utf8.count + count * (literal.utf8.count + 2) + count - 1 + tail.utf8.count)
        XCTAssertEqual(expanded.prefix(header.utf8.count), Data(header.utf8))
        XCTAssertEqual(expanded.suffix(tail.utf8.count), Data(tail.utf8))
        for i in 0..<count {
            let offset = header.utf8.count + i * (literal.utf8.count + 3)
            XCTAssertEqual(expanded[offset], 0x22)
            XCTAssertEqual(expanded[offset + 1], 0x78)
            XCTAssertEqual(expanded[offset + literal.utf8.count + 1], 0x22)
        }
    }

    func testRefsBoundAliasDepthAndCachedExpandedDepth() throws {
        func expand(_ json: String) throws -> Data? {
            try ProjectKeyedLayout.expanded(Data(json.utf8))
        }

        // A chain of plain aliases takes stack space without increasing the expanded JSON depth.
        let aliases = (1...600).map { #""e\#($0)":{"~":"e\#($0 - 1)"}"# }
        let supported = aliases.prefix(511).joined(separator: ",")
        XCTAssertEqual(try expand(#"{"value":{"~":"e511"},"refs":{"e0":[0],\#(supported)}}"#), Data(#"{"value":[0]}"#.utf8))
        let excessive = aliases.joined(separator: ",")
        XCTAssertThrowsError(try expand(#"{"value":{"~":"e600"},"refs":{"e0":[0],\#(excessive)}}"#)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_cut_project")
        }

        func nested(_ levels: Int, _ value: String) -> String {
            String(repeating: "[", count: levels) + value + String(repeating: "]", count: levels)
        }
        // The first use is shallow enough to cache. A second use at greater depth is too deep.
        let held = nested(70, "0")
        let withinLimit = nested(50, #"{"~":"held"}"#)
        XCTAssertEqual(try expand(#"{"first":{"~":"held"},"second":\#(withinLimit),"refs":{"held":\#(held)}}"#),
                       Data(#"{"first":\#(held),"second":\#(nested(50, held))}"#.utf8))
        let tooDeep = nested(70, #"{"~":"held"}"#)
        XCTAssertThrowsError(try expand(#"{"first":{"~":"held"},"second":\#(tooDeep),"refs":{"held":\#(held)}}"#)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_cut_project")
        }

        // The number of values in an array does not count toward its depth.
        let row = Array(repeating: "0", count: 10_000).joined(separator: ",")
        XCTAssertEqual(try expand(#"{"value":{"~":"flat"},"refs":{"flat":[\#(row)]}}"#),
                       Data(#"{"value":[\#(row)]}"#.utf8))
    }

    func testProjectSavesWithItsRefsTableAndLoadsBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = "media/a recording with a long name.mov"
        func clip(_ index: Int, to: Int64 = 3) -> CutSequenceClip {
            CutSequenceClip(id: "clip-\(index)", file: path, from: .zero, to: .init(numerator: to))
        }
        let before = (0..<40).map { clip($0) }
        let after = (0..<40).map { clip($0, to: $0 == 7 ? 2 : 3) }
        let url = directory.appendingPathComponent("Interview.cut")
        let undo = [CutHistoryState(action: "Trim Clip", project: .sequence(before))]
        try CutProject.sequence(after).save(to: url, undo: undo, redo: [])

        // The file is text with one field to a line. The path every clip names is written once,
        // under a key taken from the path itself.
        let file = try Data(contentsOf: url)
        let text = String(decoding: file, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\n  \"clips\": [\n    {\n      \"file\": \"~"), text)
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertEqual(text.components(separatedBy: path).count, 2)
        let key = String(decoding: ProjectKeyedLayout.key(Array("\"\(path)\"".utf8)), as: UTF8.self)
        let root = try object(file)
        XCTAssertEqual(root["schema_version"] as? Int, CutProject.schemaVersion)
        XCTAssertEqual((root["refs"] as? [String: Any])?[key] as? String, path)
        XCTAssertEqual((root["clips"] as? [[String: Any]])?.first?["file"] as? String, "~" + key)
        // The plain document is what the file stands for.
        let plain = try ProjectFile.documentJSON(file)
        XCTAssertNil(try object(plain)["refs"])
        XCTAssertEqual((try object(plain)["clips"] as? [[String: Any]])?.first?["file"] as? String, path)

        // Saving it again unchanged writes the same bytes, so version control sees no change.
        let loaded = try CutProject.loadDocument(from: url, limit: 5)
        XCTAssertEqual(loaded.project, .sequence(after))
        XCTAssertEqual(loaded.undo.map(\.project), [.sequence(before)])
        try loaded.project.save(to: url, undo: loaded.undo, redo: loaded.redo)
        XCTAssertEqual(try Data(contentsOf: url), file)

        // The plain document opens, and its next save writes this text.
        let earlier = directory.appendingPathComponent("Plain.cut")
        try plain.write(to: earlier)
        let reopened = try CutProject.loadDocument(from: earlier, limit: 5)
        XCTAssertEqual(reopened.project, .sequence(after))
        XCTAssertEqual(reopened.undo.map(\.project), [.sequence(before)])
        try reopened.project.save(to: earlier, undo: reopened.undo, redo: reopened.redo)
        XCTAssertEqual(try Data(contentsOf: earlier), file)
    }
}
