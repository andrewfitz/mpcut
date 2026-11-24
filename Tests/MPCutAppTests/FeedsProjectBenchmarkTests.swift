import AppKit
import MPCutCore
@testable import MPCutApp
import XCTest

final class FeedsProjectBenchmarkTests: XCTestCase {
    @MainActor
    func testTwoHourReviewProject() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MPCUT_FEEDS_BENCH"] == "1" else {
            throw XCTSkip("Set MPCUT_FEEDS_BENCH=1 to measure.")
        }
        let mediaURL = URL(fileURLWithPath: try XCTUnwrap(environment["MPCUT_FEEDS_BENCH_MEDIA"]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = directory.appendingPathComponent("Gallery.mp4")
        try FileManager.default.copyItem(at: mediaURL, to: recording)
        _ = NSApplication.shared

        func time(_ seconds: Int) -> RationalTime { .init(numerator: Int64(seconds)) }
        let duration = time(7200)
        let people = (0..<40).map { ParticipantPerson(id: "feed-\($0)", name: "Feed \($0)") }
        let spanSeconds = try XCTUnwrap(Int(environment["MPCUT_FEEDS_BENCH_SPAN_SECONDS"] ?? "3"))
        guard spanSeconds > 0 && 7200.isMultiple(of: spanSeconds) else {
            throw NSError(domain: "Invalid appearance span for a 7,200-second recording", code: spanSeconds)
        }
        var appearances: [ParticipantAppearance] = []
        appearances.reserveCapacity(7200 / spanSeconds * people.count)
        for second in stride(from: 0, to: 7200, by: spanSeconds) {
            let range = MulticamRange(from: time(second), to: time(second + spanSeconds))
            let drift = Double(second / spanSeconds % 7) * 0.0005
            for (index, person) in people.enumerated() {
                let x = Double(index % 8) * 0.12 + 0.01 + drift
                let y = Double(index / 8) * 0.19 + 0.02
                appearances.append(.init(id: "tile-\(index)", participantID: person.id, range: range,
                                         bounds: .init(x: x, y: y, width: 0.11, height: 0.17),
                                         labelBounds: .init(x: x, y: y + 0.14, width: 0.04, height: 0.02)))
            }
        }
        let participants = ParticipantProject(people: people, sources: [
            .init(sourceID: recording.path, analysisIdentity: "stage-0-dense-gallery", appearances: appearances,
                  coverage: [.init(range: .init(from: .zero, to: duration), state: .verified)])
        ])
        let clip = CutSequenceClip(id: "gallery", file: recording.path, from: .zero, to: duration)
        let seed = directory.appendingPathComponent("Seed.cut")
        try CutProject.sequence([clip]).save(to: seed)

        let preferences = EditorPreferences()
        preferences.historyLimit = 10
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        try editor.openProject([clip], at: seed)
        try await settle(editor)
        try editor.replaceParticipantProject(participants, action: "Accept Geometry")
        try await settle(editor)
        let authoredRange = MulticamRange(from: .zero, to: time(1))
        let layout = TileLayoutSpan(range: authoredRange, layout: .solo, slots: [.init(id: people[0].id)])
        let tiled = try editor.stillProject.settingTileLayout(scope: .clip(clip.id), range: authoredRange, layout: layout)
        try editor.replaceTileLayoutProject(tiled)
        try await settle(editor)
        let destination = directory.appendingPathComponent("Review.cut")
        let startSave = DispatchTime.now().uptimeNanoseconds
        try editor.writeProject(to: destination)
        let save = elapsed(since: startSave)
        let savedBytes = try size(destination)
        XCTAssertLessThanOrEqual(savedBytes, MulticamProject.maximumFileSize)
        print(String(format: "FEEDS_PROJECT_INITIAL feeds=%d appearances=%d bytes=%d save=%.2fms",
                     people.count, appearances.count, savedBytes, save))

        let reopened = ProjectSession(id: UUID(), preferences: preferences)
        defer { reopened.editor.endSession() }
        let startOpen = DispatchTime.now().uptimeNanoseconds
        try reopened.editor.openProject([clip], at: destination)
        try await settle(reopened.editor)
        let open = elapsed(since: startOpen)
        XCTAssertTrue(reopened.editor.participantProject == participants)
        XCTAssertEqual(reopened.editor.sequenceClips.first?.to, duration)
        XCTAssertEqual(reopened.editor.sequenceClips.first?.tileLayouts, [layout])

        var edited = reopened.editor.participantProject
        let startEdit = DispatchTime.now().uptimeNanoseconds
        try edited.correctBounds(sourceID: recording.path, appearanceID: "tile-39",
                                 bounds: .init(x: 0.85, y: 0.78, width: 0.10, height: 0.16),
                                 range: .init(from: time(7200 - spanSeconds), to: duration))
        try reopened.editor.replaceParticipantProject(edited, action: "Correct Tile Bounds")
        let edit = elapsed(since: startEdit)
        XCTAssertTrue(reopened.editor.participantProject == edited)
        let editedURL = directory.appendingPathComponent("Edited.cut")
        try reopened.editor.writeProject(to: editedURL)
        let editedBytes = try size(editedURL)
        XCTAssertLessThanOrEqual(editedBytes, MulticamProject.maximumFileSize)
        XCTAssertEqual(try CutProject.loadEditorDocument(from: editedURL, limit: 10).undo.last?.action,
                       "Correct Tile Bounds")

        let startUndo = DispatchTime.now().uptimeNanoseconds
        reopened.editor.undo()
        try await settle(reopened.editor)
        let undo = elapsed(since: startUndo)
        XCTAssertTrue(reopened.editor.participantProject == participants)
        XCTAssertTrue(reopened.editor.canRedo)
        let undoneURL = directory.appendingPathComponent("Undone.cut")
        try reopened.editor.writeProject(to: undoneURL)
        let undoneBytes = try size(undoneURL)
        XCTAssertLessThanOrEqual(undoneBytes, MulticamProject.maximumFileSize)
        XCTAssertEqual(try CutProject.loadEditorDocument(from: undoneURL, limit: 10).redo.last?.action,
                       "Correct Tile Bounds")
        print(String(format: "FEEDS_PROJECT feeds=%d appearances=%d initialBytes=%d editedBytes=%d undoneBytes=%d save=%.2fms open=%.2fms edit=%.2fms undo=%.2fms",
                     people.count, appearances.count, savedBytes, editedBytes, undoneBytes, save, open, edit, undo))
    }

    @MainActor
    private func settle(_ editor: EditorModel) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
        while editor.isBusy && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(editor.isBusy)
        XCTAssertNil(editor.alert)
    }

    private func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func size(_ url: URL) throws -> Int {
        try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }
}
