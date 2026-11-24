import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class FeedAngleConversionTests: XCTestCase {
    func testConversionKeepsSequenceClipsAndRoundTripsHistory() async throws {
        _ = NSApplication.shared
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                       subdirectory: "Fixtures"))
        let delayed = try XCTUnwrap(Bundle.module.url(forResource: "Multicam-Delayed-ProRes", withExtension: "mov",
                                                       subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gallery = directory.appendingPathComponent("Gallery.mov")
        let insert = directory.appendingPathComponent("Insert.mov")
        try FileManager.default.copyItem(at: delayed, to: gallery)
        try FileManager.default.copyItem(at: fixture, to: insert)
        let url = directory.appendingPathComponent("Edit.cut")
        let range = MulticamRange(from: .zero, to: .init(numerator: 1001, denominator: 10000))
        let clips = [
            CutSequenceClip(id: "gallery-start", file: gallery.path, from: range.from, to: range.to),
            CutSequenceClip(id: "insert", file: insert.path, from: range.from, to: range.to),
            CutSequenceClip(id: "gallery-end", file: gallery.path, from: range.from, to: range.to)
        ]
        let people = [ParticipantPerson(id: "alice", name: "Alice"), ParticipantPerson(id: "bob", name: "Bob")]
        let appearances = people.enumerated().map { index, person in
            ParticipantAppearance(id: "tile-\(index)", participantID: person.id, range: range,
                                  bounds: .init(x: Double(index) * 0.5, y: 0, width: 0.5, height: 1))
        }
        var project = CutProject.sequence(clips)
        project.participants = .init(people: people, sources: [
            .init(sourceID: gallery.path, analysisIdentity: "gallery-test", appearances: appearances)
        ])
        try project.save(to: url)

        let preferences = EditorPreferences()
        preferences.historyLimit = 10
        preferences.useAnalysisSidecars = false
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        try session.editor.openProject(clips, at: url)
        try await waitFor { !session.editor.isBusy && session.editor.sequenceClips.count == clips.count }
        var renamed = session.editor.participantProject
        renamed.people[0].name = "Alice Edited"
        try session.editor.replaceParticipantProject(renamed, action: "Rename Feed")
        let original = session.editor.transcriptProject
        let originalCursor = session.editor.historyCursor
        let handle = session.mcpHandle
        let revision = session.mcpRevision
        session.useFeedsAsMulticamAngles(sourceID: gallery.path, feedIDs: ["alice"])
        try await waitFor { !session.isConvertingFeedAngles }
        XCTAssertTrue(session.isMulticam, session.editor.alert?.message ?? "")
        XCTAssertEqual(session.mcpHandle, handle)
        XCTAssertGreaterThan(session.mcpRevision, revision)
        let converted = try XCTUnwrap(session.multicam.project)
        XCTAssertEqual(converted.assemblyItems?.compactMap(\.occurrenceID), clips.map(\.id))
        XCTAssertEqual(converted.angles.compactMap { $0.feedAngle?.feedID }, ["alice"])
        let parent = try XCTUnwrap(converted.angles.first { $0.file == gallery.path && $0.feedAngle == nil })
        let virtual = try XCTUnwrap(converted.angles.first { $0.feedAngle != nil })
        let sessions = ProjectSessions(preferences: preferences)
        do {
            _ = try await sessions.handleMCPCommand(tool: "tiles_editor_inspect",
                arguments: ["source_id": virtual.id], session: session, checkAccess: {})
            XCTFail("A virtual angle cannot supply a separate recording for tile inspection.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "unknown_source")
        }
        try await waitFor { session.multicam.media[parent.id]?.hasFullEditIndex == true }
        let indexedGallery = try XCTUnwrap(session.multicam.media[parent.id])
        XCTAssertGreaterThan(indexedGallery.multicamClockOffset, .zero)
        XCTAssertEqual(try parent.offset.adding(indexedGallery.multicamClockOffset), .zero)
        XCTAssertEqual(try converted.plan().picture.first?.input.from, indexedGallery.frames.first?.time)
        XCTAssertEqual(converted.pictureSources.filter { $0.feedAngle == nil }.map(\.file), [gallery.path, insert.path])
        XCTAssertEqual(try converted.plan().duration, try range.to.adding(range.to).adding(range.to))

        let repeatedStart = try range.to.adding(range.to)
        let repeatedEnd = try repeatedStart.adding(range.to)
        session.multicam.selectAssemblyOccurrence(2)
        session.multicam.assemblySelection = .init(from: repeatedStart, to: repeatedEnd)
        XCTAssertEqual(session.participantMarkedSourceRange(sourceID: parent.id), range)
        session.multicam.assemblySelection = .init(from: range.to, to: repeatedEnd)
        XCTAssertNil(session.participantMarkedSourceRange(sourceID: parent.id))
        session.multicam.assemblySelection = nil
        session.multicam.setAssemblyPreview(false)

        let galleryAngle = try XCTUnwrap(converted.pictureSources.first?.id)
        session.useFeedsAsMulticamAngles(sourceID: galleryAngle, feedIDs: ["bob"])
        try await waitFor { !session.isConvertingFeedAngles }
        XCTAssertEqual(session.multicam.project?.angles.compactMap { $0.feedAngle?.feedID }, ["alice", "bob"])
        session.restoreConversionHistory(originalCursor + 1)
        XCTAssertEqual(session.multicam.project, converted)
        session.undoFeedAngleConversion()
        XCTAssertFalse(session.isMulticam)
        XCTAssertEqual(session.editor.transcriptProject, original)
        session.redoFeedAngleConversion()
        XCTAssertTrue(session.isMulticam)
        XCTAssertEqual(session.multicam.project, converted)
        try session.multicam.writeProject(to: url)

        let saved = try CutProject.loadEditorDocument(from: url, limit: preferences.historyLimit)
        let reopened = ProjectSession(id: UUID(), preferences: preferences)
        defer { reopened.end() }
        guard case .multicam(let savedMulticam) = saved.project else {
            return XCTFail("Expected a saved multicam project")
        }
        reopened.isMulticam = true
        reopened.multicam.openProject(url, document: savedMulticam, history: (saved.undo, saved.redo), archiveMedia: saved.media,
                                      onConversionHistory: { states in
            reopened.loadFeedAngleHistory(states, at: url, archiveMedia: saved.media)
        })
        try await waitFor { reopened.canUndoFeedAngleConversion }
        reopened.undoFeedAngleConversion()
        XCTAssertFalse(reopened.isMulticam)
        XCTAssertTrue(reopened.editor.isProjectChanged)
        XCTAssertEqual(reopened.editor.transcriptProject, original)
        XCTAssertEqual(reopened.editor.projectHistory.map(\.name), ["Rename Feed"])
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the editor")
    }
}
