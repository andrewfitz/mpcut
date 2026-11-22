import Foundation
@testable import MPCutCore
import XCTest

final class CutHistoryTests: XCTestCase {
    private func file() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cut")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func clip(_ index: Int) -> CutSequenceClip {
        CutSequenceClip(id: "clip-\(index)", file: "media/camera-\(index).mov", from: .zero, to: .init(numerator: 3))
    }

    func testCompactReorderAndTrimRoundTripAcrossBothBranches() throws {
        let current = (0..<1000).map(clip)
        let reordered = Array(current[1...]) + [current[0]]
        var trimmed = current
        trimmed[400].from = .init(numerator: 1)
        let undo: [CutHistoryState] = [
            .init(action: "Add Clips", project: .sequence([])),
            .init(action: "Move Clip", project: .sequence(reordered))
        ]
        let redo: [CutHistoryState] = [.init(action: "Trim Clip", project: .sequence(trimmed))]
        let url = file()
        try CutProject.sequence(current).save(to: url, undo: undo, redo: redo)
        let document = try CutProject.loadDocument(from: url, limit: 5)
        XCTAssertEqual(document.project, .sequence(current))
        XCTAssertEqual(document.undo, undo)
        XCTAssertEqual(document.redo, redo)
        XCTAssertEqual(try CutProject.load(from: url), .sequence(current))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let history = try XCTUnwrap(object["history"])
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: history).count, 400)
        let limited = try CutProject.loadHistory(from: url, limit: 2)
        XCTAssertEqual(limited.undo, Array(undo.suffix(1)))
        XCTAssertEqual(limited.redo, redo)
        let disabled = try CutProject.loadHistory(from: url, limit: 0)
        XCTAssertTrue(disabled.undo.isEmpty && disabled.redo.isEmpty)
    }

    func testMulticamSettingsAndRepeatedAssembly() throws {
        let duration = MulticamRange(from: .zero, to: .init(numerator: 5))
        let second = MulticamRange(from: .init(numerator: 1), to: .init(numerator: 3))
        let present = MulticamProject(referenceAngle: "A", range: duration,
                                     angles: [.init(id: "A", file: "A.mov"), .init(id: "B", file: "B.mov")],
                                     audio: .follow, switches: [.init(at: .zero, angle: "A")],
                                     assembly: [duration, second, duration])
        var arranged = present
        arranged.assembly = [second, duration, duration, second]
        var prior = arranged
        prior.assembly = nil
        prior.angles.swapAt(0, 1)
        prior.referenceAngle = "B"
        prior.switches = [.init(at: .zero, angle: "B"), .init(at: .init(numerator: 1), angle: "A")]
        prior.audio = .fixed(.init(source: "B", stream: 1))
        let undo: [CutHistoryState] = [.init(action: "Change Angles", project: .multicam(prior)),
                                       .init(action: "Change Assembly", project: .multicam(arranged))]
        let url = file()
        try CutProject.multicam(present).save(to: url, undo: undo, redo: [])
        XCTAssertEqual(try CutProject.loadHistory(from: url, limit: 2).undo, undo)
        XCTAssertEqual(try MulticamProject.load(from: url), present)
    }

    func testLimitsAndNoHistoryEncoding() throws {
        let url = file()
        let edit = CutProject.sequence([])
        let entries = (0..<750).map { CutHistoryState(action: "Edit \($0)", project: edit) }
        try edit.save(to: url, undo: entries, redo: entries)
        let loaded = try CutProject.loadDocument(from: url, limit: Int.max)
        XCTAssertEqual(loaded.undo, Array(entries.suffix(250)))
        XCTAssertEqual(loaded.redo, Array(entries.suffix(250)))
        XCTAssertEqual(CutProject.historyCounts(undo: 10, redo: 12, limit: 3).undo, 2)
        XCTAssertEqual(CutProject.historyCounts(undo: 0, redo: 12, limit: 3).redo, 3)
        try edit.save(to: url, undo: [], redo: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(object["history"])
    }

    func testLargeUndoCanBePrunedWithoutLosingCurrentProjectOrNearestRedo() throws {
        let url = file()
        let edit = CutProject.sequence([clip(1)])
        let future = CutHistoryState(action: "Remove Clip", project: .sequence([]))
        let large = CutHistoryState(action: "Delete Clips", project: .sequence((0..<50).map(clip)))
        try edit.save(to: url, undo: [large], redo: [future], byteLimit: 360)
        let result = try CutProject.loadDocument(from: url, limit: 500)
        XCTAssertEqual(result.project, edit)
        XCTAssertTrue(result.undo.isEmpty)
        XCTAssertEqual(result.redo, [future])
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 360)
        let original = try Data(contentsOf: url)
        var recording = clip(0)
        recording.file = url.path
        let unsafe = CutHistoryState(action: "Remove Media", project: .sequence([recording]))
        XCTAssertThrowsError(try edit.save(to: url, undo: [unsafe, large], redo: [], byteLimit: 360))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testExpandedArrayBudgetKeepsNearbyStatesOnBothBranches() throws {
        let clips = (0..<5).map(clip)
        let left = Array(clips.reversed())
        let right = Array(clips[1...]) + [clips[0]]
        let url = file()
        let undo = [CutHistoryState(action: "Move Earlier", project: .sequence(clips)),
                    CutHistoryState(action: "Reverse", project: .sequence(left))]
        let redo = [CutHistoryState(action: "Move Later", project: .sequence(clips)),
                    CutHistoryState(action: "Rotate", project: .sequence(right))]
        try CutProject.sequence(clips).save(to: url, undo: undo, redo: redo)
        let limited = try CutProject.loadDocument(from: url, limit: 500, recordBudget: 10)
        XCTAssertEqual(limited.undo, Array(undo.suffix(1)))
        XCTAssertEqual(limited.redo, Array(redo.suffix(1)))
        let same = CutHistoryState(action: "Edit", project: .sequence(clips))
        try CutProject.sequence(clips).save(to: url, undo: Array(repeating: same, count: 10), redo: [])
        XCTAssertEqual(try CutProject.loadDocument(from: url, limit: 500, recordBudget: 10).undo.count, 2)
    }

    func testDestinationProtectionUsesEvenHistoryBeyondTheMaterializationLimit() throws {
        let url = file()
        let edit = CutProject.sequence([clip(0)])
        var hidden = clip(5)
        hidden.file = "offline.cut"
        let state = CutHistoryState(action: "Remove", project: .sequence([clip(3), hidden]))
        try edit.save(to: url, undo: [state], redo: [])
        let destination = url.deletingLastPathComponent().appendingPathComponent(hidden.file)
        XCTAssertTrue(try CutProject.loadDocument(from: url, limit: 0).undo.isEmpty)
        XCTAssertThrowsError(try CutProject.loadDocument(from: url, limit: 0, recordBudget: 0,
                                                         validatingDestination: destination)) {
            XCTAssertEqual(($0 as? CutError)?.code, "cut_project_source_collision")
        }
    }

    func testMulticamHistorySourcesProtectCameraAndRecorderOnDiskAndStdin() throws {
        let url = file()
        let group = MulticamRange(from: .zero, to: .init(numerator: 1))
        let present = MulticamProject(referenceAngle: "cam", range: group, angles: [.init(id: "cam", file: "new.mov")],
                                      audio: .none, switches: [.init(at: .zero, angle: "cam")])
        var past = present
        past.angles[0].file = "Old Camera.mov"
        past.audioSources = [.init(id: "mic", file: "Frames/Old Recorder.wav")]
        try CutProject.multicam(present).save(to: url, undo: [], redo: [.init(action: "Relink", project: .multicam(past))])
        let directory = url.deletingLastPathComponent()
        for document in [try CutProjectMedia.load(from: url, multicam: true),
                         try CutProjectMedia.decode(Data(contentsOf: url))] {
            XCTAssertEqual(document.project, .multicam(present))
            XCTAssertThrowsError(try document.validateDestination(directory.appendingPathComponent("Old Camera.mov"), relativeTo: url))
            XCTAssertThrowsError(try document.validateDestination(directory.appendingPathComponent("Frames"),
                                                                   relativeTo: url, includesContents: true))
            XCTAssertNoThrow(try document.validateDestination(directory.appendingPathComponent("Frame"),
                                                               relativeTo: url, includesContents: true))
        }
    }

    func testUnicodeActionLengthMatchesTheProjectSchema() throws {
        let url = file()
        let present = CutProject.sequence([])
        let action = String(repeating: "🎞", count: 1024)
        try present.save(to: url, undo: [.init(action: action, project: present)], redo: [])
        XCTAssertEqual(try CutProject.loadHistory(from: url, limit: 1).undo.first?.action, action)
        XCTAssertThrowsError(try present.save(to: url, undo: [.init(action: action + "x", project: present)], redo: []))
    }

    func testCombinedDeltaSizeIsCheckedBeforeDecodingEitherBranch() throws {
        let url = file()
        let copies = String(repeating: "[0,1],", count: 500_000) + "[0,1]"
        let step = #"{"action":"Edit","clips":["# + copies + "]}"
        let document = #"{"format":"mpcut","schemaVersion":1,"kind":"sequence","clips":[],"history":{"undo":["#
            + step + #"],"redo":["# + step + "]}}"
        try Data(document.utf8).write(to: url)
        XCTAssertThrowsError(try CutProject.loadDocument(from: url, limit: 0)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_cut_history")
            XCTAssertTrue($0.localizedDescription.contains("stored-record limit"))
        }
    }

    func testMalformedHistoryCannotAmplifyOrReplaceMedia() throws {
        let url = file()
        let present = CutProject.sequence([clip(0)])
        try present.save(to: url)
        let original = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        for bad: [String: Any] in [
            ["action": "Undo", "clips": [[0, 1], [0, 1]]],
            ["action": "Undo", "clips": [[1, Int.max]]],
            ["action": "Undo", "clips": [[0, 2_000_000]]],
            ["action": "Undo", "clips": [[0, -1]]],
            ["action": "Undo", "clips": [[0, 1, 2]]],
            ["action": "Undo", "clips": NSNull()],
            ["action": "Undo", "angles": []],
            ["action": "Undo", "unknown": 0],
            ["action": " "]
        ] {
            object["history"] = ["undo": [bad]]
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            XCTAssertThrowsError(try CutProject.loadHistory(from: url, limit: 1), "\(bad)")
        }
        object["history"] = ["redo": Array(repeating: ["action": "Edit"], count: 501)]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try CutProject.loadHistory(from: url, limit: 1))

        var collision = clip(1)
        collision.originalFile = url.path
        try original.write(to: url)
        XCTAssertThrowsError(try present.save(to: url, undo: [.init(action: "Delete", project: .sequence([collision]))], redo: []))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
