import Foundation
import XCTest
@testable import MPCutCore

final class ProjectSavedLayoutTests: XCTestCase {
    private func compact(_ json: String) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let interview = #"""
    {"clips":[{"file":"Zoom/a long folder name/recording.mp4","from":"49681/5","id":"A","to":"282381/25"},
              {"file":"Zoom/a long folder name/recording.mp4","from":"0","id":"B","original_file":"Zoom/a long folder name/first take.mp4","to":"3"}],
     "format":"mpcut",
     "history":{"undo":[{"action":"Trim Clip","clips":[{"file":"Zoom/a long folder name/recording.mp4","from":"0","id":"A","to":"282381/25"}],"origin":"user"}]},
     "kind":"sequence","schema_version":4,
     "transcripts":{"attachments":[{"asset":{"file":"eliz.cut.transcripts/00.json","sha256":"00"},
       "bindings":[
        {"audio_stream_index":0,"file":"Zoom/a long folder name/recording.mp4","offset":{"denominator":1,"numerator":0},"sequence_clock_origin":{"denominator":3000,"numerator":-1},"source_confirmed":true,"track_id":"t-1"},
        {"audio_stream_index":0,"file":"Zoom/a long folder name/recording.mp4","offset":{"denominator":1,"numerator":0},"sequence_clock_origin":{"denominator":3000,"numerator":-1},"source_confirmed":true,"track_id":"t-2"},
        {"audio_stream_index":1,"file":"Zoom/a long folder name/recording.mp4","offset":{"denominator":1,"numerator":0},"track_id":"t-3"},
        {"audio_stream_index":0,"file":"Zoom/a long folder name/recording.mp4","offset":{"denominator":1,"numerator":0},"sequence_clock_origin":{"denominator":3000,"numerator":-1},"source_confirmed":true,"track_id":"t-4"}],
       "id":"attachment","import_origin":{"denominator":2,"numerator":1}}],
      "authoring":[{"anchors":[{"binding":{"audio_stream_index":0,"file":"Zoom/a long folder name/recording.mp4","offset":{"denominator":1,"numerator":0},"track_id":"t-1"},"range":{"from":"0","to":"1"}}]}],
      "revision":2}}
    """#

    func testSavedLayoutSharesPathsAndBindingsAndExpandsToTheSameDocument() throws {
        let original = try compact(interview)
        let saved = try XCTUnwrap(ProjectSavedLayout.compacted(Data(interview.utf8)))
        XCTAssertEqual(try ProjectSavedLayout.expanded(saved), original)
        XCTAssertLessThan(saved.count * 4, original.count * 3)

        let root = try object(saved)
        XCTAssertEqual(root["schema_version"] as? Int, 5)
        XCTAssertEqual(root["files"] as? [String], ["Zoom/a long folder name/recording.mp4",
                                                    "Zoom/a long folder name/first take.mp4",
                                                    "eliz.cut.transcripts/00.json"])
        let clips = try XCTUnwrap(root["clips"] as? [[String: Any]])
        XCTAssertEqual(clips.map { $0["file"] as? Int }, [0, 0])
        XCTAssertEqual(clips[1]["original_file"] as? Int, 1)
        let attachment = try XCTUnwrap(((root["transcripts"] as? [String: Any])?["attachments"] as? [[String: Any]])?.first)
        XCTAssertEqual(attachment["import_origin"] as? String, "1/2")
        let bindings = try XCTUnwrap(attachment["bindings"] as? [[String: Any]])
        // Only neighbours join, so the order of the tracks survives.
        XCTAssertEqual(bindings.count, 3)
        XCTAssertEqual(bindings[0]["track_ids"] as? [String], ["t-1", "t-2"])
        XCTAssertEqual(bindings[0]["offset"] as? String, "0")
        XCTAssertEqual(bindings[0]["sequence_clock_origin"] as? String, "-1/3000")
        XCTAssertEqual(bindings[1]["track_id"] as? String, "t-3")
        XCTAssertEqual(bindings[2]["track_id"] as? String, "t-4")
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("numerator"))
    }

    func testTextIsCarriedAsWritten() throws {
        // Escapes, a fraction, an exponent and an integer past 64 bits must not be read and spelled again.
        let project = #"{"clips":[{"file":"a\/bé \"x\".mov","id":"1","n":0.0058479533},{"file":"a\/bé \"x\".mov","id":"2","n":1e-7,"big":123456789012345678901234567890}],"schema_version":4}"#
        let saved = try XCTUnwrap(ProjectSavedLayout.compacted(Data(project.utf8)))
        XCTAssertEqual(try ProjectSavedLayout.expanded(saved), Data(project.utf8))
        let pretty = project.replacingOccurrences(of: ",", with: " ,\n\t").replacingOccurrences(of: "{", with: "{ ")
        XCTAssertEqual(ProjectSavedLayout.compacted(Data(pretty.utf8)), saved)
    }

    func testSnapshotExtensionFieldsSurviveCompactLayout() throws {
        var root = try object(Data(interview.utf8))
        let snapshot: NSDictionary = ["version": 1, "entries": [
            ["path": "camera.mov", "future": ["file": 99, "bindings": [["track_ids": []]]]]
        ]]
        root["media_snapshot"] = snapshot
        let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        let compacted = try XCTUnwrap(ProjectSavedLayout.compacted(original))
        XCTAssertEqual(try object(compacted)["media_snapshot"] as? NSDictionary, snapshot)
        XCTAssertEqual(try ProjectSavedLayout.expanded(compacted), original)
    }

    func testDocumentThatCouldMisleadIsWrittenAsItIs() throws {
        let kept = [
            // Another version, or none.
            #"{"clips":[{"file":"a.mov","id":"1"},{"file":"a.mov","id":"2"}],"schema_version":3}"#,
            #"{"clips":[{"file":"a.mov","id":"1"},{"file":"a.mov","id":"2"}]}"#,
            // Names and values the saved layout gives a meaning of its own.
            #"{"clips":[{"file":"a.mov","id":"1"},{"file":"a.mov","id":"2"}],"files":[],"schema_version":4}"#,
            #"{"clips":[{"file":"a long name.mov","id":"1"},{"file":"a long name.mov","id":"2"},{"file":0}],"schema_version":4}"#,
            #"{"clips":[{"file":"a long name.mov"},{"file":"a long name.mov"}],"schema_version":4,"t":{"bindings":[{"offset":"1/2","track_id":"t"}]}}"#,
            #"{"clips":[{"file":"a long name.mov"},{"file":"a long name.mov"}],"schema_version":4,"t":{"bindings":[{"track_ids":["a","b"]}]}}"#,
            "[1]", "", "{"
        ]
        for (index, project) in kept.enumerated() {
            XCTAssertNil(ProjectSavedLayout.compacted(Data(project.utf8)), "case \(index)")
            XCTAssertNil(try ProjectSavedLayout.expanded(Data(project.utf8)), "case \(index)")
        }
    }

    func testRepeatedTextIsWrittenOnce() throws {
        let digest = String(repeating: "0123456789abcdef", count: 4)
        let angle = "0F8FAD5B-D9CB-469F-A165-70867728950E"
        let project = #"""
        {"angles":[{"file":"wide.mov","id":"\#(angle)"},{"file":"close.mov","id":"close"}],
         "history":{"undo":[{"action":"Switch Angle","switches":[{"angle_id":"\#(angle)","group_time":"0"}]}]},
         "note":"~/Movies is a folder","other":"~","schema_version":4,
         "switches":[{"angle_id":"\#(angle)","group_time":"0"},{"angle_id":"close","group_time":"4"},{"angle_id":"\#(angle)","group_time":"9"}],
         "transcripts":{"attachments":[{"asset":{"file":"Talk.cut.transcripts/\#(digest).json","sha256":"\#(digest)"},"bindings":[]}]}}
        """#
        let original = try compact(project)
        let saved = try XCTUnwrap(ProjectSavedLayout.compacted(Data(project.utf8)))
        XCTAssertEqual(try ProjectSavedLayout.expanded(saved), original)

        let text = String(decoding: saved, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: angle).count, 2)
        let root = try object(saved)
        XCTAssertEqual(root["strings"] as? [String], [angle])
        XCTAssertEqual(root["files"] as? [String], ["wide.mov", "close.mov", "Talk.cut.transcripts/\(digest).json"])
        XCTAssertEqual((root["angles"] as? [[String: Any]])?.map { $0["id"] as? String }, ["~0", "close"])
        XCTAssertEqual((root["switches"] as? [[String: Any]])?.map { $0["angle_id"] as? String }, ["~0", "close", "~0"])
        // Text that begins with the marker is kept apart from a reference.
        XCTAssertEqual(root["note"] as? String, "~~/Movies is a folder")
        XCTAssertEqual(root["other"] as? String, "~~")

        // A snapshot added to the saved document is carried exactly, marker and all.
        var appended = saved
        appended.removeLast()
        appended.append(contentsOf: Data(#","media_snapshot":{"entries":[{"file":"~/a.mov","id":"~7"}]}}"#.utf8))
        let expanded = try XCTUnwrap(ProjectSavedLayout.expanded(appended))
        XCTAssertTrue(String(decoding: expanded, as: UTF8.self).hasSuffix(#""media_snapshot":{"entries":[{"file":"~/a.mov","id":"~7"}]}}"#))

        for damaged in [#"{"a":"~1","schema_version":5,"strings":["only one entry"]}"#,
                        #"{"a":"~x","schema_version":5}"#, #"{"a":"~","schema_version":5}"#,
                        #"{"a":"~0","schema_version":5,"strings":[7]}"#] {
            XCTAssertThrowsError(try ProjectSavedLayout.expanded(Data(damaged.utf8)), damaged)
        }
    }

    func testHistoryWritesWhatItsStepsRepeatOnce() throws {
        // Each undo step keeps every span, and one span differs from step to step.
        func spans(changed: Int) -> String {
            (0..<60).map { index in
                #"{"bounds":{"height":0.23391813,"width":0.2421875,"x":0.00390625,"y":0.0058479533},"id":"span-\#(index)","range":{"from":"\#(index)","to":"\#(index == changed ? 99 : index + 1)"},"role":"tile"}"#
            }.joined(separator: ",")
        }
        let steps = (0..<12).map { #"{"action":"Rename","participants":{"sources":[{"appearances":[\#(spans(changed: $0))]}]}}"# }
        let project = #"{"clips":[{"file":"a.mov","id":"1"}],"history":{"undo":[\#(steps.joined(separator: ","))]},"participants":{"sources":[{"appearances":[\#(spans(changed: 0))]}]},"schema_version":4}"#
        let saved = try XCTUnwrap(ProjectSavedLayout.compacted(Data(project.utf8)))
        XCTAssertEqual(try ProjectSavedLayout.expanded(saved), Data(project.utf8))
        XCTAssertLessThan(saved.count * 4, project.utf8.count)

        let root = try object(saved)
        XCTAssertNotNil(root["shared"] as? [Any])
        // The document itself is left to read as it is; only history refers to the list.
        let live = try XCTUnwrap(((root["participants"] as? [String: Any])?["sources"] as? [[String: Any]])?.first?["appearances"] as? [[String: Any]])
        XCTAssertEqual(live.count, 60)
        XCTAssertEqual(live[3]["id"] as? String, "span-3")

        let damaged = [
            // A position past the list, one that refers forward, and a list that is not one.
            #"{"history":{"undo":[{"~":2}]},"schema_version":5,"shared":[{"a":1}]}"#,
            #"{"history":{"undo":[{"~":0}]},"schema_version":5,"shared":[{"a":{"~":1}},{"b":1}]}"#,
            #"{"history":{"undo":[{"~":0}]},"schema_version":5,"shared":{"a":1}}"#
        ]
        for text in damaged { XCTAssertThrowsError(try ProjectSavedLayout.expanded(Data(text.utf8)), text) }
        // Each entry doubles the one before it. Expanding must stop long before memory does.
        let doubling = (1..<40).map { #"[{"~":\#($0 - 1)},{"~":\#($0 - 1)}]"# }.joined(separator: ",")
        let bomb = #"{"history":{"undo":[{"~":39}]},"schema_version":5,"shared":["0123456789abcdef",\#(doubling)]}"#
        XCTAssertThrowsError(try ProjectSavedLayout.expanded(Data(bomb.utf8)))
        // A marker outside history is an ordinary object.
        XCTAssertEqual(try ProjectSavedLayout.expanded(Data(#"{"clips":[{"~":0}],"schema_version":5}"#.utf8)),
                       Data(#"{"clips":[{"~":0}],"schema_version":4}"#.utf8))
    }

    func testDamagedSavedLayoutIsRefused() throws {
        let damaged = [
            #"{"clips":[{"file":1}],"files":["a.mov"],"schema_version":5}"#,
            #"{"clips":[{"file":-1}],"files":["a.mov"],"schema_version":5}"#,
            #"{"clips":[{"file":0.0}],"files":["a.mov"],"schema_version":5}"#,
            #"{"clips":[{"file":0}],"schema_version":5}"#,
            #"{"clips":[{"file":0}],"files":[1],"schema_version":5}"#,
            #"{"files":["a.mov"],"schema_version":5,"t":{"bindings":[{"offset":"1/1","track_id":"t"}]}}"#,
            #"{"files":["a.mov"],"schema_version":5,"t":{"bindings":[{"offset":"01","track_id":"t"}]}}"#,
            #"{"files":["a.mov"],"schema_version":5,"t":{"bindings":[{"track_ids":[]}]}}"#,
            #"{"files":["a.mov"],"schema_version":5,"t":{"bindings":[{"track_id":"a","track_ids":["b"]}]}}"#
        ]
        for (index, project) in damaged.enumerated() {
            XCTAssertThrowsError(try ProjectSavedLayout.expanded(Data(project.utf8), code: "invalid_multicam_project"), "case \(index)") {
                XCTAssertEqual(($0 as? CutError)?.code, "invalid_multicam_project")
            }
        }
        XCTAssertEqual(try ProjectSavedLayout.expanded(Data(#"{"clips":[{"file":0}],"files":["a.mov"],"schema_version" : 5}"#.utf8)),
                       Data(#"{"clips":[{"file":"a.mov"}],"schema_version":4}"#.utf8))
    }

    func testProjectSavesInTheSharedLayoutAndLoadsBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func clip(_ index: Int, to: Int64 = 3) -> CutSequenceClip {
            CutSequenceClip(id: "clip-\(index)", file: "media/a recording with a long name.mov", from: .zero,
                            to: .init(numerator: to))
        }
        let before = (0..<40).map { clip($0) }
        let after = (0..<40).map { clip($0, to: $0 == 7 ? 2 : 3) }
        let url = directory.appendingPathComponent("Interview.cut")
        let undo = [CutHistoryState(action: "Trim Clip", project: .sequence(before))]
        try CutProject.sequence(after).save(to: url, undo: undo, redo: [])

        // The file is the saved layout's text, compressed.
        let file = try Data(contentsOf: url)
        XCTAssertEqual(file.first, 0)
        let text = try XCTUnwrap(ProjectSavedBytes.unpacked(file, code: "invalid_cut_project"))
        XCTAssertLessThan(file.count * 3, text.count)
        let root = try object(text)
        XCTAssertEqual(root["schema_version"] as? Int, 5)
        XCTAssertEqual(root["files"] as? [String], ["media/a recording with a long name.mov"])
        XCTAssertEqual(String(decoding: text, as: UTF8.self).components(separatedBy: "a recording with a long name").count, 2)
        XCTAssertEqual(try object(ProjectFile.documentJSON(file))["schema_version"] as? Int, 4)

        let loaded = try CutProject.loadDocument(from: url, limit: 5)
        XCTAssertEqual(loaded.project, .sequence(after))
        XCTAssertEqual(loaded.undo.map(\.project), [.sequence(before)])
        try loaded.project.save(to: url, undo: loaded.undo, redo: loaded.redo)
        XCTAssertEqual(try CutProject.load(from: url), .sequence(after))

        // Every project is written the same way, whatever it has to share.
        let single = directory.appendingPathComponent("Single.cut")
        try CutProject.sequence([clip(0)]).save(to: single)
        let saved = try XCTUnwrap(ProjectSavedBytes.unpacked(Data(contentsOf: single), code: "invalid_cut_project"))
        XCTAssertEqual(try object(saved)["schema_version"] as? Int, 5)
        XCTAssertEqual(try CutProject.load(from: single), .sequence([clip(0)]))

        // A plain document written by an earlier build, or by hand, still opens.
        let plain = directory.appendingPathComponent("Plain.cut")
        try ProjectFile.documentJSON(Data(contentsOf: single)).write(to: plain)
        XCTAssertEqual(try CutProject.load(from: plain), .sequence([clip(0)]))
        // Damage to the compressed bytes is refused, not read as something else.
        var damaged = file
        damaged[8] ^= 0x01
        for bytes in [damaged, file.prefix(file.count / 2), file.prefix(16)] {
            XCTAssertThrowsError(try CutProject.decode(Data(bytes))) {
                XCTAssertEqual(($0 as? CutError)?.code, "invalid_cut_project")
            }
        }
    }
}
