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

    func testStaleHistoryRemovedFromLargeMappedExpansion() throws {
        // A single 64 KiB reference entry expands to over 64 MiB of history before verification.
        // Dropping that history must expose just the remaining edit in the mapped data.
        let literal = String(repeating: "m", count: 65_536)
        let undo = Array(repeating: #""~large""#, count: 1_024).joined(separator: ",")
        let saved = Data(#"{"format":"mpcut","schema_version":9,"kind":"sequence","clips":[],"history":{"base":"stale","undo":[\#(undo)]},"refs":{"large":"\#(literal)"}}"#.utf8)
        let plain = Data(#"{"format":"mpcut","schema_version":9,"kind":"sequence","clips":[]}"#.utf8)

        XCTAssertEqual(try CutProject.documentJSON(saved: saved), plain)
        let decoded = try CutProject.decodeDocument(saved, limit: 5)
        XCTAssertEqual(decoded.project, .sequence([]))
        XCTAssertTrue(decoded.undo.isEmpty)
        XCTAssertTrue(decoded.redo.isEmpty)
        XCTAssertEqual(try CutProject.readableDocument(saved: saved), try CutProject.readableDocument(saved: plain))
    }

    func testEscapedLayoutNamesStillVerifySavedHistory() throws {
        let (url, before, after) = try savedProject()
        let saved = try String(contentsOf: url, encoding: .utf8)
        var escaped = saved.replacingOccurrences(of: #""refs":"#, with: #""\u0072efs":"#)
            .replacingOccurrences(of: #""history":"#, with: #""hi\u0073tory":"#)
            .replacingOccurrences(of: #""kind": "sequence""#, with: #""k\u0069nd": "se\u0071uence""#)
            .replacingOccurrences(of: #""base":"#, with: #""ba\u0073e":"#)
        XCTAssertTrue(escaped.contains(#""\u0072efs":"#))
        let key = try XCTUnwrap(escaped.range(of: #""ba\u0073e": ""#))
        let digestStart = key.upperBound
        let first = try XCTUnwrap(escaped[digestStart].asciiValue)
        escaped.replaceSubrange(digestStart...digestStart, with: String(format: "\\u%04x", first))
        let reopened = try CutProject.decodeDocument(Data(escaped.utf8), limit: 5)
        XCTAssertEqual(reopened.project, .sequence(after))
        XCTAssertEqual(reopened.undo.map(\.project), [.sequence(before)])

        let trim = try XCTUnwrap(escaped.range(of: #""to": "3""#))
        let edited = escaped.replacingCharacters(in: trim, with: #""to": "2""#)
        XCTAssertTrue(try CutProject.decodeDocument(Data(edited.utf8), limit: 5).undo.isEmpty)
    }

    func testPriorSchemaNineLiteralEscapeStampStillVerifies() throws {
        // z2g4hb2fcq hashes the sorted compact edit with the slash escaped.
        let saved = #"{"clips":[{"file":"media\/a.mov","from":"0","id":"a","to":"2"}],"format":"mpcut","history":{"base":"z2g4hb2fcq","undo":[{"action":"Add clip","clips":[]}]},"kind":"sequence","schema_version":9}"#
        let loaded = try CutProject.decodeDocument(Data(saved.utf8), limit: 1)
        XCTAssertEqual(loaded.undo.map(\.project), [.sequence([])])
        let trimmed = saved.replacingOccurrences(of: #""to":"2""#, with: #""to":"1""#)
        XCTAssertTrue(try CutProject.decodeDocument(Data(trimmed.utf8), limit: 1).undo.isEmpty)
    }

    func testFormattingEmbeddedAssetsPreservesHistoryBase() throws {
        let transcript = TranscriptDocument(clock: .presentation, tracks: [.init(id: "mic", name: "Mic")])
        let asset = try TranscriptAsset(document: transcript)
        var project = CutProject.sequence([clip(1)])
        project.transcripts = .init(attachments: [.init(id: "interview", asset: asset, bindings: [])])
        let before = CutHistoryState(action: "Add Clip", project: .sequence([]))
        let bytes = try project.encodedArchive(undo: [before], redo: [], mediaSnapshot: .empty).0
        let saved = try ProjectFile.diskBytes(bytes, prefix: "cut")
        let text = String(decoding: saved, as: UTF8.self)
        let changed = text.replacingOccurrences(of: #""approximate_clock":false"#, with: #""approximate_clock"  :  false"#)
        XCTAssertNotEqual(text, changed)
        let loaded = try CutProject.decodeDocument(Data(changed.utf8), limit: 1)
        XCTAssertEqual(loaded.undo.map(\.action), [before.action])
        XCTAssertEqual(loaded.project.transcripts.attachments.first?.asset.sha256, asset.sha256)
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
        {"clips":[{"file":"a.mov","from":"0","id":"one","to":"3"}],"format":"mpcut","history":{"base":"0","undo":[{"action":"A","clips":[[0,1]]},{"action":"B","clips":[{"~":"k"}]}],"redo":[]},"kind":"sequence","media_snapshot":{"entries":[{"path":"a.mov","size":1},{"path":"b.mov","size":2}],"version":1},"refs":{"k":{"file":"a.mov","from":"0","id":"two","to":"3"},"~":""},"schema_version":9}
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

    func testMergeKeepsBothAssetPayloadsAvailableAndSavesOnlyThoseInTheEdit() throws {
        func bytes(_ attachments: [TranscriptAttachment]) throws -> Data {
            var project = CutProject.sequence([])
            project.transcripts = .init(attachments: attachments)
            return try ProjectFile.encoded(project, compact: true)
        }
        func attachment(_ name: String) throws -> TranscriptAttachment {
            let transcript = TranscriptDocument(clock: .presentation, tracks: [.init(id: name, name: name)])
            return try TranscriptAttachment(id: name, asset: TranscriptAsset(document: transcript), bindings: [])
        }
        let a = try attachment("Lav")
        let b = try attachment("Camera")
        let inputs = try ProjectMerge.sides(base: bytes([]), ours: bytes([a]), theirs: bytes([b]))
        let restored = try inputs.restoringAssets(in: inputs.theirs)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: restored) as? [String: Any])
        let assets = try XCTUnwrap(object["embedded_assets"] as? [String: [String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(assets["transcripts"]).keys), [a.asset.sha256, b.asset.sha256])
        var conflicted = Data("<<<<<<< ours\n".utf8)
        conflicted.append(inputs.ours)
        conflicted.append(Data("=======\n".utf8))
        conflicted.append(inputs.theirs)
        conflicted.append(Data(">>>>>>> theirs\n".utf8))
        let restoredConflict = try inputs.restoringAssets(in: conflicted)
        XCTAssertNil(restoredConflict.range(of: Data("\n  \"embedded_assets\": {}".utf8)))
        // JSON permits escaped spellings of an object's name, including digest keys.
        let digestKey = "\"" + b.asset.sha256 + "\":"
        let firstByte = try XCTUnwrap(b.asset.sha256.utf8.first)
        let escapedKey = String(format: "\"\\u%04x", firstByte) + b.asset.sha256.dropFirst() + "\":"
        let edited = String(decoding: restored, as: UTF8.self).replacingOccurrences(of: digestKey, with: escapedKey)
        XCTAssertNotEqual(edited, String(decoding: restored, as: UTF8.self))
        let saved = try ProjectMerge.saved(Data(edited.utf8))
        XCTAssertEqual(try CutProject.decode(saved).transcripts.attachments, [b])
        let plain = try CutProject.documentJSON(saved: saved)
        XCTAssertNil(plain.range(of: Data(a.asset.sha256.utf8)))
    }

    func testMergeHandsTheLineMergeTheEditAlone() throws {
        func side(clips: String, undo: String, recordings: String) -> Data {
            Data(#"{"clips":[\#(clips)],"format":"mpcut","history":{"undo":[\#(undo)]},"kind":"sequence","media_snapshot":{"entries":[\#(recordings)],"version":1},"schema_version":9}"#.utf8)
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

    func testMediaSnapshotMergeTreatsEscapedPathsAsTheSameRecording() throws {
        func side(_ entry: String) -> Data {
            Data(#"{"clips":[],"format":"mpcut","kind":"sequence","media_snapshot":{"entries":[\#(entry)],"version":1},"schema_version":9}"#.utf8)
        }
        let base = side(#"{"path":"a.mov","size":1}"#)
        let ours = side(#"{"p\u0061th":"\u0061.mov","size":1}"#)
        let theirs = side(#"{"path":"a.mov","size":5}"#)
        let sides = try ProjectMerge.sides(base: base, ours: ours, theirs: theirs)
        let merged = try CutProject.decodeDocument(ProjectMerge.saved(sides.ours), limit: 0)
        XCTAssertEqual(merged.mediaSnapshot.entries.map(\.path), ["a.mov"])
        XCTAssertEqual(merged.mediaSnapshot.entries.map(\.size), [5])
    }
}
