@testable import MPCutCore
import XCTest

/// One project file that version control, a text editor and MPCut can all change.
final class ProjectHistoryStampTests: XCTestCase {
    private func clip(_ index: Int, to: Int64 = 3) -> CutSequenceClip {
        CutSequenceClip(id: "clip-\(index)", file: "media/a recording with a long name.mov", from: .zero, to: .init(numerator: to))
    }

    private func savedProject() throws -> (url: URL, before: [CutSequenceClip], after: [CutSequenceClip]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let before = (0..<4).map { clip($0) }
        let after = Array(before.dropLast())
        let url = directory.appendingPathComponent("Interview.cut")
        try CutProject.sequence(after).save(to: url, undo: [CutHistoryState(action: "Delete Clip", project: .sequence(before))], redo: [])
        return (url, before, after)
    }

    func testHistoryStaysWithTheEditItWasSavedFor() throws {
        let (url, before, _) = try savedProject()
        let file = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(file.contains("\"base\": \""), file)
        XCTAssertEqual(try CutProject.loadDocument(from: url, limit: 5).undo.map(\.project), [.sequence(before)])
        // The mark belongs to the saved layout. The document the file stands for has none.
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: CutProject.documentJSON(at: url)) as? [String: Any])
        XCTAssertNil((plain["history"] as? [String: Any])?["base"])
        XCTAssertNotNil((plain["history"] as? [String: Any])?["undo"])

        // A change to what MPCut keeps beside the edit leaves the history good.
        let noted = file.replacingOccurrences(of: "\"format\": \"mpcut\",", with: "\"format\": \"mpcut\",\n  \"media_snapshot\": {\"entries\": [], \"version\": 1},")
        XCTAssertNotEqual(noted, file)
        try Data(noted.utf8).write(to: url)
        XCTAssertEqual(try CutProject.loadDocument(from: url, limit: 5).undo.count, 1)
    }

    func testAProjectChangedAsTextOpensWithNoHistory() throws {
        let (url, _, after) = try savedProject()
        let file = try String(contentsOf: url, encoding: .utf8)

        // A trim made in the text.
        let position = try XCTUnwrap(file.range(of: "\"to\": \"3\""))
        try Data(file.replacingCharacters(in: position, with: "\"to\": \"2\"").utf8).write(to: url)
        var trimmed = after
        trimmed[0] = clip(0, to: 2)
        var loaded = try CutProject.loadDocument(from: url, limit: 5)
        XCTAssertEqual(loaded.project, .sequence(trimmed))
        XCTAssertEqual(loaded.undo.count, 0)

        // Clips put in another order, by a tool that writes the JSON its own way. The undo step
        // would still apply, to the wrong clips.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any])
        object["clips"] = Array(try XCTUnwrap(object["clips"] as? [Any]).reversed())
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: url)
        loaded = try CutProject.loadDocument(from: url, limit: 5)
        XCTAssertEqual(loaded.project, .sequence(after.reversed()))
        XCTAssertEqual(loaded.undo.count, 0)

        // The next save starts a history for the project as it now is.
        try loaded.project.save(to: url, undo: [CutHistoryState(action: "Reorder", project: .sequence(after))], redo: [])
        XCTAssertEqual(try CutProject.loadDocument(from: url, limit: 5).undo.map(\.project), [.sequence(after)])
    }

    func testWhatMPCutKeepsForItselfTakesALineForEachItem() throws {
        let document = Data(#"""
        {"clips":[{"file":"a.mov","from":"0","id":"one","to":"3"}],"format":"mpcut","history":{"base":"0","undo":[{"action":"A","clips":[[0,1]]},{"action":"B","clips":[{"~":"k"}]}],"redo":[]},"kind":"sequence","media_snapshot":{"entries":[{"path":"a.mov","size":1},{"path":"b.mov","size":2}],"version":1},"refs":{"k":{"file":"a.mov","from":"0","id":"two","to":"3"},"~":""},"schema_version":4}
        """#.utf8)
        let text = String(decoding: try XCTUnwrap(ProjectSavedLayout.readable(document)), as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        for line in [#"      {"action":"A","clips":[[0,1]]},"#, #"      {"action":"B","clips":[{"~":"k"}]}"#,
                     #"      {"path":"a.mov","size":1},"#, #"      {"path":"b.mov","size":2}"#,
                     #"    "k": {"file":"a.mov","from":"0","id":"two","to":"3"},"#, #"    "redo": [],"#,
                     #"      "file": "a.mov","#] {
            XCTAssertTrue(lines.contains(line), "\(line)\n\(text)")
        }
        // The same document, and the same text when written again.
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: document) as? NSDictionary)
        XCTAssertEqual(ProjectSavedLayout.readable(Data(text.utf8)), Data(text.utf8))
    }

    func testMergeHandsTheLineMergeTheEditAlone() throws {
        func side(clips: String, undo: String, recordings: String) -> Data {
            Data(#"{"clips":[\#(clips)],"format":"mpcut","history":{"undo":[\#(undo)]},"kind":"sequence","media_snapshot":{"entries":[\#(recordings)],"version":1},"schema_version":4}"#.utf8)
        }
        let one = #"{"file":"a.mov","from":"0","id":"one","to":"3"}"#
        let base = side(clips: one, undo: "", recordings: #"{"path":"a.mov","size":1},{"path":"old.mov","size":9}"#)
        let ours = side(clips: one + #",{"file":"b.mov","from":"0","id":"two","to":"3"}"#, undo: #"{"action":"A","clips":[[0,1]]}"#,
                        recordings: #"{"path":"a.mov","size":1},{"path":"b.mov","size":2}"#)
        let theirs = side(clips: #"{"file":"c.mov","from":"0","id":"zero","to":"3"},"# + one, undo: #"{"action":"B","clips":[[1,1]]}"#,
                          recordings: #"{"path":"a.mov","size":5},{"path":"c.mov","size":3},{"path":"old.mov","size":9}"#)
        let sides = try ProjectMerge.sides(base: base, ours: ours, theirs: theirs)
        let texts = [sides.base, sides.ours, sides.theirs].map { String(decoding: $0, as: UTF8.self) }
        // No side carries a history. Each carries the same snapshot: the recording each branch
        // added, the entry one branch changed, and not the one a branch dropped.
        let snapshot = """
          "media_snapshot": {
            "entries": [
              {"path":"a.mov","size":5},
              {"path":"b.mov","size":2},
              {"path":"c.mov","size":3}
            ],
            "version": 1
          },
        """
        for text in texts {
            XCTAssertFalse(text.contains("history"), text)
            XCTAssertTrue(text.contains(snapshot), text)
        }
        XCTAssertTrue(texts[1].contains("\"id\": \"two\""))
        XCTAssertTrue(texts[2].contains("\"id\": \"zero\""))
        // A merged text is saved as any project is, and a project both branches added has no base.
        XCTAssertEqual(ProjectSavedLayout.parse(try ProjectFile.documentJSON(ProjectMerge.saved(sides.ours))),
                       ProjectSavedLayout.parse(sides.ours))
        XCTAssertEqual(try ProjectMerge.sides(base: Data(), ours: ours, theirs: theirs).base, Data())
    }
}
