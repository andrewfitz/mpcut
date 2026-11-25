import Darwin
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

    func testStagedProjectWriteFinishesWhileCallerHoldsTheDirectoryLease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = open(directory.path, O_SEARCH | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let probe = open(directory.path, O_SEARCH | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(probe, 0)
        guard probe >= 0 else { return }
        let competingLock = flock(probe, LOCK_EX | LOCK_NB)
        let lockError = errno
        close(probe)
        XCTAssertEqual(competingLock, -1)
        XCTAssertEqual(lockError, EWOULDBLOCK)

        let stage = directory.appendingPathComponent(".pending-\(UUID().uuidString).cut")
        let named = directory.appendingPathComponent("Edit.cut")
        var project = CutProject.sequence([clip(0)])
        project.transcripts.documentID = UUID()
        let snapshot = project
        let stageDone = DispatchSemaphore(value: 0)
        let namedStarted = DispatchSemaphore(value: 0)
        let namedDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { stageDone.signal() }
            do { try snapshot.saveStaged(to: stage, undo: [], redo: [], mediaSnapshot: .empty) }
            catch { XCTFail(error.localizedDescription) }
        }
        DispatchQueue.global().async {
            defer { namedDone.signal() }
            namedStarted.signal()
            do { try snapshot.save(to: named, undo: [], redo: []) }
            catch { XCTFail(error.localizedDescription) }
        }

        let stagedWhileLocked = stageDone.wait(timeout: .now() + 5)
        XCTAssertEqual(namedStarted.wait(timeout: .now() + 5), .success)
        let namedWhileLocked = namedDone.wait(timeout: .now() + 0.1)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(stagedWhileLocked, .success, "The private draft write attempted to reacquire its caller’s lease.")
        XCTAssertEqual(namedWhileLocked, .timedOut, "A named save did not respect the directory lease.")
        if stagedWhileLocked == .timedOut { XCTAssertEqual(stageDone.wait(timeout: .now() + 5), .success) }
        if namedWhileLocked == .timedOut { XCTAssertEqual(namedDone.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(try CutProject.load(from: stage), snapshot)
        XCTAssertEqual(try CutProject.load(from: named), snapshot)
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
        let redo: [CutHistoryState] = [.init(action: "Trim Clip", origin: .agent, project: .sequence(trimmed))]
        let url = file()
        try CutProject.sequence(current).save(to: url, undo: undo, redo: redo)
        let document = try CutProject.loadDocument(from: url, limit: 5)
        XCTAssertEqual(document.project, .sequence(current))
        XCTAssertEqual(document.undo, undo)
        XCTAssertEqual(document.redo, redo)
        XCTAssertEqual(try CutProject.load(from: url), .sequence(current))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectFile.documentJSON(at: url)) as? [String: Any])
        let history = try XCTUnwrap(object["history"])
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: history).count, 400)
        let limited = try CutProject.loadHistory(from: url, limit: 2)
        XCTAssertEqual(limited.undo, Array(undo.suffix(1)))
        XCTAssertEqual(limited.redo, redo)
        let disabled = try CutProject.loadHistory(from: url, limit: 0)
        XCTAssertTrue(disabled.undo.isEmpty && disabled.redo.isEmpty)
    }

    func testHistoryWithoutOriginRemainsUnknownAfterSaving() throws {
        let url = file()
        let json = #"{"format":"mpcut","schema_version":9,"kind":"sequence","clips":[],"history":{"undo":[{"action":"Earlier Edit"}]}}"#
        try Data(json.utf8).write(to: url)
        let loaded = try CutProject.loadDocument(from: url, limit: 5)
        XCTAssertEqual(loaded.undo.first?.origin, .unknown)
        try loaded.project.save(to: url, undo: loaded.undo, redo: loaded.redo)
        XCTAssertEqual(try CutProject.loadHistory(from: url, limit: 5).undo.first?.origin, .unknown)
    }

    func testTilesOnlyInRetainedHistoryRoundTrip() throws {
        let url = file()
        var changed = clip(1)
        changed.tileLayouts = [.init(range: .init(from: .zero, to: .init(numerator: 2)), layout: .original)]
        let original = CutProject.sequence([clip(1)])
        let edited = CutProject.sequence([changed])
        let redo = [CutHistoryState(action: "Set Clip Layout", project: edited)]
        try original.save(to: url, undo: [], redo: redo)

        let loaded = try CutProject.loadDocument(from: url, limit: 1)
        XCTAssertEqual(loaded.project, original)
        XCTAssertEqual(loaded.redo, redo)
        let json = try ProjectFile.documentJSON(at: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, CutProject.schemaVersion)
        object["schema_version"] = 8
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try CutProject.loadDocument(from: url, limit: 1)) {
            XCTAssertEqual(($0 as? CutError)?.code, "unsupported_cut_version")
        }
    }

    func testMulticamTileEditsRoundTripThroughUndoAndRedoAcrossReopen() throws {
        let url = file()
        let range = MulticamRange(from: .zero, to: .init(numerator: 4))
        let initial = MulticamProject(
            referenceAngle: "camera", range: range, angles: [.init(id: "camera", file: "camera.mov")],
            audio: .none, switches: [.init(at: .zero, angle: "camera")],
            assemblyItems: [.group(range), .group(range)],
            participants: .init(people: [.init(id: "feed", name: "Feed")])
        )
        var changed = initial
        changed.angles.append(.init(id: "feed-angle", file: "camera.mov", name: "Feed",
                                    feedAngle: .init(sourceID: "camera", feedID: "feed")))
        changed.speakerAngles = [.init(voice: .init(attachmentID: "track", speakerID: "speaker"), angleID: "feed-angle")]
        changed.participants.people[0].treatment = .init(mode: .blur)
        changed.groupTileLayouts = [.init(range: range, layout: .original)]
        changed.assemblyItems = [.group(range, id: "first"), .group(range, id: "again", layouts: changed.groupTileLayouts)]

        let clean = CutProject.multicam(initial)
        let edited = CutProject.multicam(changed)
        let action = "Edit Tiles"
        let undo = [CutHistoryState(action: action, project: clean)]
        try edited.save(to: url, undo: undo, redo: [])
        let reopened = try CutProject.loadDocument(from: url, limit: 1)
        XCTAssertEqual(reopened.project, edited)
        XCTAssertEqual(reopened.undo, undo)
        let undone = try XCTUnwrap(reopened.undo.last?.project)
        let redo = [CutHistoryState(action: action, project: reopened.project)]
        try undone.save(to: url, undo: [], redo: redo)
        let reopenedUndone = try CutProject.loadDocument(from: url, limit: 1)
        XCTAssertEqual(reopenedUndone.project, clean)
        XCTAssertEqual(reopenedUndone.redo, redo)
        XCTAssertEqual(try MulticamProject.load(from: url), initial)
        let redone = try XCTUnwrap(reopenedUndone.redo.last?.project)
        try redone.save(to: url, undo: undo, redo: [])
        XCTAssertEqual(try CutProject.loadDocument(from: url, limit: 1).project, edited)
    }

    func testConversionHistoryRoundTripsAcrossBothTimelineKinds() throws {
        let url = file()
        let range = MulticamRange(from: .zero, to: .init(numerator: 3))
        var box = ParticipantAppearance(id: "tile", participantID: "feed", range: range,
                                        bounds: .init(x: 0.17, y: 0.13, width: 0.62, height: 0.81))
        box.detectedBounds = .init(x: 0.15, y: 0.15, width: 0.62, height: 0.81)
        let model = ParticipantProject(people: [.init(id: "feed", name: "Feed")],
            sources: [.init(sourceID: clip(1).file, appearances: [box])])
        var first = CutProject.sequence([clip(1), clip(2)])
        first.participants = model
        var shortened = CutProject.sequence([clip(1)])
        shortened.participants = model
        let plain = try JSONEncoder().encode(shortened)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, CutProject.schemaVersion)
        json["schema_version"] = 8
        XCTAssertThrowsError(try CutProject.decode(JSONSerialization.data(withJSONObject: json)))
        var convertedModel = model
        convertedModel.sources[0].sourceID = "camera"
        let group = MulticamProject(referenceAngle: "camera", range: range,
                                    angles: [.init(id: "camera", file: clip(1).file)], audio: .none,
                                    switches: [.init(at: .zero, angle: "camera")], participants: convertedModel)
        let converted = CutProject.multicam(group)
        let trim = CutHistoryState(action: "Trim Sequence", project: first)
        let undo = [trim, CutHistoryState(action: "Use Feeds as Multicam Angles", project: shortened)]
        try converted.save(to: url, undo: undo, redo: [])
        let reopened = try CutProject.loadDocument(from: url, limit: 2)
        XCTAssertEqual(reopened.project, converted)
        XCTAssertEqual(reopened.undo, undo)
        let protected = try CutProjectMedia.load(from: url).absoluteSources(relativeTo: url)
        XCTAssertEqual(protected[CutProject.mediaURL(clip(2).file, relativeTo: url).path], clip(2).id)

        let redo = [CutHistoryState(action: "Use Feeds as Multicam Angles", project: converted)]
        try shortened.save(to: url, undo: [trim], redo: redo)
        let undone = try CutProject.loadDocument(from: url, limit: 2)
        XCTAssertEqual(undone.project, shortened)
        XCTAssertEqual(undone.undo, [trim])
        XCTAssertEqual(undone.redo, redo)
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

    func testMulticamHistoryBudgetChargesUnchangedAdditionalRecordings() throws {
        let duration = MulticamRange(from: .zero, to: .init(numerator: 5))
        let present = MulticamProject(
            referenceAngle: "A", range: duration,
            angles: [.init(id: "A", file: "A.mov", coverage: .init(from: .zero, to: .init(numerator: 2)),
                           additionalRecordings: [.init(id: "A2", file: "A2.mov", offset: .init(numerator: 3),
                                                        coverage: .init(from: .init(numerator: 3), to: duration.to))])],
            audio: .follow, switches: [.init(at: .zero, angle: "A")]
        )
        let previous = CutHistoryState(action: "Change Audio", project: .multicam(present))
        var updated = present
        updated.audio = .none
        let url = file()
        try CutProject.multicam(updated).save(to: url, undo: [previous], redo: [])
        XCTAssertTrue(try CutProject.loadDocument(from: url, limit: 1, recordBudget: 2).undo.isEmpty)
        XCTAssertEqual(try CutProject.loadDocument(from: url, limit: 1, recordBudget: 3).undo, [previous])
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
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectFile.documentJSON(at: url)) as? [String: Any])
        XCTAssertNil(object["history"])
    }

    func testLargeUndoAndNearestRedoAreBothRetained() throws {
        let url = file()
        let edit = CutProject.sequence([clip(1)])
        let future = CutHistoryState(action: "Remove Clip", project: .sequence([]))
        let large = CutHistoryState(action: "Delete Clips", project: .sequence((0..<50).map(clip)))
        try edit.save(to: url, undo: [large], redo: [future])
        let result = try CutProject.loadDocument(from: url, limit: 500)
        XCTAssertEqual(result.project, edit)
        XCTAssertEqual(result.undo, [large])
        XCTAssertEqual(result.redo, [future])
        let original = try Data(contentsOf: url)
        var recording = clip(0)
        recording.file = url.path
        let unsafe = CutHistoryState(action: "Remove Media", project: .sequence([recording]))
        XCTAssertThrowsError(try edit.save(to: url, undo: [unsafe, large], redo: []))
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

    func testMalformedHistoryCannotAmplifyOrReplaceMedia() throws {
        let url = file()
        let present = CutProject.sequence([clip(0)])
        try present.save(to: url)
        let original = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectFile.documentJSON(at: url)) as? [String: Any])
        let id = clip(0).id
        for bad: [String: Any] in [
            ["action": "Undo", "clips": [[0, 1], [0, 1]]],
            ["action": "Undo", "clips": [[0, 1], ["id": id, "file": "a.mov", "from": "0", "to": "1"]]],
            ["action": "Undo", "clips": [[0, 1], ["id": "new", "file": "a/", "from": "0", "to": "1"]]],
            ["action": "Undo", "clips": [[0, 1], ["id": "new", "file": "a.mov", "from": "0", "to": String(Int64.max)]]],
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
