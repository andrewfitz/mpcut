import AppKit
import Combine
import SwiftUI
import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamEditorModelTests: XCTestCase {
    @MainActor
    func testAssemblyTimelineEditsOnlyTheChosenRepeatedOccurrence() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                       subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("assembly.multicam.json")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        let frames = media.frames
        guard frames.count >= 11 else { return XCTFail("Expected at least eleven indexed frames") }
        let repeated = MulticamRange(from: frames[1].time, to: frames[6].time)
        let other = MulticamRange(from: frames[7].time, to: frames[10].time)
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: media.duration),
                                      angles: [.init(id: "wide", file: fixture.path)], audio: .none,
                                      switches: [.init(at: .zero, angle: "wide")], assembly: [repeated, other, repeated])
        try project.save(to: url)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.useAnalysisSidecars = false
        model.openProject(url)
        try await waitForIndex(model)

        let repeatedOutput = try repeated.to.subtracting(repeated.from)
        let otherOutput = try other.to.subtracting(other.from)
        let thirdStart = try repeatedOutput.adding(otherOutput)
        model.seekAssemblyTimeline(thirdStart.seconds, scrubbing: false)
        XCTAssertTrue(model.assemblyPreview)
        XCTAssertEqual(model.selectedOccurrence, 2)
        XCTAssertEqual(model.preview.time, thirdStart)

        let insideFrame = (frames[3].time.seconds + frames[4].time.seconds) / 2
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: MulticamAssemblyTimeline(model: model, preview: model.preview))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func findTimeline(in view: NSView) -> TimelineScrollView? {
            (view as? TimelineScrollView) ?? view.subviews.lazy.compactMap { findTimeline(in: $0) }.first
        }
        for _ in 0..<30 where findTimeline(in: hosting)?.surface.timeline == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let scroll = try XCTUnwrap(findTimeline(in: hosting))
        scroll.resizeDocument()
        let surface = scroll.surface
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: surface.convert(NSPoint(x: x, y: 50), to: nil),
                                             modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let initialScale = (surface.bounds.width - 32) / (thirdStart.seconds + repeatedOutput.seconds)
        let handle = 16 + thirdStart.seconds * initialScale + 2
        let trimTarget = handle + (insideFrame - repeated.from.seconds) * initialScale
        surface.mouseDown(with: try mouse(.leftMouseDown, handle))
        surface.mouseDragged(with: try mouse(.leftMouseDragged, trimTarget))
        XCTAssertEqual(model.ranges, [repeated, other, repeated])
        surface.mouseUp(with: try mouse(.leftMouseUp, trimTarget))
        let trimmed = MulticamRange(from: frames[3].time, to: repeated.to)
        XCTAssertEqual(model.ranges, [repeated, other, trimmed])
        model.undo()
        XCTAssertEqual(model.ranges, [repeated, other, repeated])
        model.redo()
        XCTAssertEqual(model.ranges, [repeated, other, trimmed])

        model.setAnalysisSnap(.keyframes)
        XCTAssertEqual(model.trimAssemblyOccurrence(2, edge: .end, seconds: frames[5].time.seconds + 0.001,
                                                    commit: false), frames[5].time.seconds)
        XCTAssertEqual(model.ranges, [repeated, other, trimmed])

        try await Task.sleep(for: .milliseconds(30))
        let remaining = try trimmed.to.subtracting(trimmed.from).seconds
        let width = surface.bounds.width - 32
        let scale = width / (thirdStart.seconds + remaining)
        let center = 16 + (thirdStart.seconds + remaining / 2) * scale
        surface.mouseDown(with: try mouse(.leftMouseDown, center))
        surface.mouseDragged(with: try mouse(.leftMouseDragged, 20))
        surface.mouseUp(with: try mouse(.leftMouseUp, 20))
        XCTAssertEqual(model.ranges, [trimmed, repeated, other])
        XCTAssertEqual(model.selectedOccurrence, 0)
        XCTAssertEqual(model.preview.time, .zero)
        model.undo()
        XCTAssertEqual(model.ranges, [repeated, other, trimmed])

        let exactEnd = try thirdStart.adding(frames[5].time.subtracting(trimmed.from))
        model.seekAssemblyTimeline(exactEnd.seconds, scrubbing: false)
        try await Task.sleep(for: .milliseconds(30))
        let children = try XCTUnwrap(surface.accessibilityChildren() as? [NSAccessibilityElement])
        let occurrence = try XCTUnwrap(children.last)
        XCTAssertEqual(occurrence.accessibilityLabel(), "Range 3")
        let trimAction = try XCTUnwrap(occurrence.accessibilityCustomActions()?
            .first { $0.name == "Trim end to playhead" }?.handler)
        XCTAssertTrue(trimAction())
        let axTrimmed = MulticamRange(from: trimmed.from, to: frames[5].time)
        XCTAssertEqual(model.ranges, [repeated, other, axTrimmed])
        try await Task.sleep(for: .milliseconds(30))
        let revisedChildren = try XCTUnwrap(surface.accessibilityChildren() as? [NSAccessibilityElement])
        let moveAction = try XCTUnwrap(revisedChildren.last?.accessibilityCustomActions()?
            .first { $0.name == "Move clip earlier" }?.handler)
        XCTAssertTrue(moveAction())
        XCTAssertEqual(model.ranges, [repeated, axTrimmed, other])
    }

    @MainActor
    func testUnresolvedParentPathStaysOfflineUntilRelinked() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                       subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = directory.appendingPathComponent("camera.mov")
        try FileManager.default.copyItem(at: fixture, to: camera)
        let projectURL = directory.appendingPathComponent("edit.multicam.json")
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 1)),
                                      angles: [.init(id: "wide", file: "absent/../camera.mov")],
                                      audio: .none, switches: [.init(at: .zero, angle: "wide")])
        try project.save(to: projectURL)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.useAnalysisSidecars = false

        model.openProject(projectURL)
        try await waitForIndex(model)
        XCTAssertNil(model.media["wide"])
        XCTAssertNotNil(model.sourceIssues["wide"])
        XCTAssertTrue(model.saveProject())
        let saved = try MulticamProject.load(from: projectURL)
        XCTAssertTrue(saved.angles.first?.file.hasSuffix("/absent/../camera.mov") == true)

        model.relink("wide", to: camera)
        try await waitForIndex(model)
        XCTAssertEqual(model.media["wide"]?.url, camera.standardizedFileURL)
        XCTAssertNil(model.sourceIssues["wide"])
        model.undo()
        XCTAssertNil(model.media["wide"])
        XCTAssertNotNil(model.sourceIssues["wide"])
    }

    @MainActor
    func testOpeningProjectClearsPreviousSetupDrafts() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                   subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentDirectory = directory.appendingPathComponent("other/nested")
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: documentDirectory)
        let projectURL = alias.appendingPathComponent("edit.multicam.json")
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: media.duration),
                                      angles: [.init(id: "wide", file: url.path)],
                                      audio: .none, switches: [.init(at: .zero, angle: "wide")])
        try project.save(to: projectURL)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.useAnalysisSidecars = false
        let drafts: [MulticamEditorModel.SourceDraft] = [.init(source: .init(id: "previous", file: url.path), media: media)]
        model.setup = drafts

        model.openProject(projectURL)
        model.confirmSetup(drafts: drafts, opening: "previous", audio: .none)
        XCTAssertNil(model.project)
        try await waitForIndex(model)

        XCTAssertEqual(model.project, project)
        XCTAssertTrue(model.setup.isEmpty)
        XCTAssertFalse(model.isChanged)

        model.updateSource("wide") { $0.name = "Renamed camera" }
        XCTAssertTrue(model.isChanged)
        XCTAssertTrue(model.saveProject())
        XCTAssertFalse(model.isChanged)
        let saved = try MulticamProject.load(from: projectURL)
        let source = try XCTUnwrap(saved.angles.first)
        XCTAssertEqual(source.name, "Renamed camera")
        XCTAssertFalse(source.file.hasPrefix("/"))
        XCTAssertEqual(saved.sourceURL(for: source, relativeTo: projectURL), url.standardizedFileURL)
        model.undo()
        XCTAssertTrue(model.isChanged)
        model.redo()
        XCTAssertFalse(model.isChanged)
    }

    @MainActor
    func testSavedProjectPublishesBeforeAnyIndexAndUsesProvisionalPictureClock() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                   subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectURL = directory.appendingPathComponent("progressive.multicam.json")
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 1)),
                                      angles: [.init(id: "wide", file: url.path),
                                               .init(id: "offline", file: directory.appendingPathComponent("offline.mov").path)],
                                      audio: .none, switches: [.init(at: .zero, angle: "wide")])
        try project.save(to: projectURL)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let model = MulticamEditorModel(preferences: preferences)
        defer { model.reset() }
        let other = MulticamEditorModel(preferences: preferences)
        defer { other.reset() }
        var installedWithoutMedia = false
        var provisional: MediaInfo?
        let projectObservation = model.$project.sink {
            if $0 != nil { installedWithoutMedia = model.media.isEmpty && !model.isBusy }
        }
        let mediaObservation = model.$media.sink {
            if let header = $0["wide"], !header.hasFullEditIndex { provisional = header }
        }

        model.openProject(projectURL)
        other.openProject(projectURL)
        try await waitForIndex(model)
        try await waitForIndex(other)
        XCTAssertTrue(installedWithoutMedia)
        let header = try XCTUnwrap(provisional)
        let target = MulticamPicturePosition.at(.zero, in: try project.plan(), media: ["wide": header])
        XCTAssertEqual(target?.provisional, true)
        let preview = MulticamPreview()
        defer { preview.reset() }
        preview.configure(plan: try project.plan(), media: ["wide": header])
        let previewDeadline = ContinuousClock.now + .seconds(3)
        while preview.displayedFrameTime == nil, .now < previewDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(preview.picture?.provisional, true)
        XCTAssertNotNil(preview.displayedFrameTime)
        XCTAssertNotNil(model.sourceIssues["offline"])
        XCTAssertNotNil(other.sourceIssues["offline"])
        XCTAssertTrue(model.media["wide"]?.hasFullEditIndex == true)
        XCTAssertTrue(other.media["wide"]?.hasFullEditIndex == true)
        XCTAssertNil(model.exportSourceIssue(tracks: .video, wholeGroup: true))
        withExtendedLifetime((projectObservation, mediaObservation)) {}
    }

    @MainActor
    func testSetupCanBeConfirmedWithPreviewMetadata() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                   subdirectory: "Fixtures"))
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.useAnalysisSidecars = false

        model.importSources([url])
        let deadline = ContinuousClock.now + .seconds(3)
        while model.isBusy, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let draft = try XCTUnwrap(model.setup.first)
        XCTAssertFalse(draft.media.hasFullEditIndex)
        XCTAssertTrue(draft.media.hasVideo)
        model.confirmSetup(drafts: [draft], opening: draft.id, audio: .none)
        XCTAssertNotNil(model.project)
        XCTAssertFalse(model.isBusy)
        try await waitForIndex(model)
        XCTAssertTrue(model.media[draft.id]?.hasFullEditIndex == true)
    }

    @MainActor
    func testStepBackFromUncoveredTailFindsLastFrameInOccurrence() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                   subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: url.path), media: media)],
                           opening: "wide", audio: .none)
        let end = try media.duration.adding(RationalTime(numerator: 1, denominator: 1))
        let start = media.frames[2].time
        XCTAssertTrue(model.edit {
            $0.range = MulticamRange(from: .zero, to: end)
            $0.assembly = [MulticamRange(from: start, to: end)]
        })
        model.setAssemblyPreview(true)
        model.seekGroup(end)

        model.step(-1)

        XCTAssertEqual(model.currentGroupTime(), media.frames.last?.time)
        XCTAssertTrue(model.assemblyPreview)
    }

    @MainActor
    func testEnteringAssemblyFromOmittedGroupTimeStartsSelectedOccurrence() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                   subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: url.path), media: media)],
                           opening: "wide", audio: .none)
        let first = MulticamRange(from: media.frames[1].time, to: media.frames[3].time)
        let second = MulticamRange(from: media.frames[6].time, to: media.frames[8].time)
        XCTAssertTrue(model.edit { $0.assembly = [first, second] })
        model.selectOccurrence(1)
        model.seekGroup(first.to)

        model.setAssemblyPreview(true)

        XCTAssertTrue(model.assemblyPreview)
        XCTAssertEqual(model.currentGroupTime(), second.from)
        XCTAssertEqual(model.preview.time, try first.to.subtracting(first.from))

        model.seekGroup(first.to)

        XCTAssertFalse(model.assemblyPreview)
        XCTAssertEqual(model.currentGroupTime(), first.to)
    }

    @MainActor
    func testSeekingPastProjectEndUsesTheExactAssemblyEndpoint() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                   subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let model = MulticamEditorModel()
        defer { model.reset() }
        let source = MulticamSource(id: "wide", file: url.path)
        model.confirmSetup(drafts: [.init(source: source, media: media)], opening: source.id, audio: .none)
        let projectRange = try XCTUnwrap(model.project?.range)
        XCTAssertTrue(model.edit { $0.assembly = [projectRange, projectRange] })
        model.setAssemblyPreview(true)
        model.setAnalysisSnap(.keyframes)
        let tail = try projectRange.to.adding(.init(numerator: 1))
        let assemblyEnd = try projectRange.to.adding(projectRange.to)

        model.seekTimeline(tail)
        XCTAssertTrue(model.assemblyPreview)
        XCTAssertEqual(model.preview.time, assemblyEnd)
        XCTAssertEqual(model.currentGroupTime(), projectRange.to)

        model.seekPlaybackBoundary(end: false)
        model.seekGroup(tail)
        XCTAssertTrue(model.assemblyPreview)
        XCTAssertEqual(model.preview.time, assemblyEnd)
    }

    @MainActor
    func testRepeatedRangesShareSwitchesAndSeekTheirOwnOccurrences() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                   subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let model = MulticamEditorModel()
        defer { model.reset() }
        let drafts = ["wide", "close"].map { id in
            MulticamEditorModel.SourceDraft(source: MulticamSource(id: id, file: url.path), media: media)
        }
        model.confirmSetup(drafts: drafts, opening: "wide", audio: .none)

        let firstCut = media.frames[2].time
        let retimedCut = media.frames[3].time
        let end = media.frames[6].time
        model.seekGroup(firstCut)
        XCTAssertFalse(model.takeCamera(number: 0))
        XCTAssertFalse(model.takeCamera(number: 3))
        XCTAssertTrue(model.takeCamera(number: 2))
        XCTAssertEqual(model.project?.switches.last?.at, firstCut)
        XCTAssertEqual(model.project?.switches.last?.angle, "close")

        model.markIn = .zero
        model.markOut = end
        model.addMarkedRange()
        model.addMarkedRange()
        model.selectOccurrence(1)
        model.setAssemblyPreview(true)
        XCTAssertEqual(model.preview.time, end)
        XCTAssertEqual(model.currentGroupTime(), .zero)
        model.step(-1)
        XCTAssertEqual(model.preview.time, media.frames[5].time)
        model.step(1)
        XCTAssertEqual(model.preview.time, end)
        XCTAssertEqual(model.selectedOccurrence, 1)

        model.moveSwitch(firstCut, to: retimedCut)
        let edited = try XCTUnwrap(model.project)
        let mapped = try edited.plan()
        XCTAssertEqual(mapped.intervals.filter { $0.angle == "close" }.map(\.group.from), [retimedCut, retimedCut])
        XCTAssertEqual(model.preview.time, try end.adding(retimedCut))

        model.changeOccurrence(to: media.frames[5].time)
        XCTAssertEqual(model.ranges.map(\.to), [end, media.frames[5].time])
        model.undo()
        XCTAssertEqual(model.ranges.map(\.to), [end, end])
        model.undo()
        XCTAssertEqual(model.project?.switches.last?.at, firstCut)
        model.redo()
        XCTAssertEqual(model.project?.switches.last?.at, retimedCut)

        model.selectOccurrence(0)
        model.preview.seek(to: try end.adding(firstCut))
        model.splitOccurrence()
        XCTAssertEqual(model.ranges.map(\.from), [.zero, .zero, firstCut])
        XCTAssertEqual(model.ranges.map(\.to), [end, firstCut, end])
    }

    @MainActor
    private func waitForIndex(_ model: MulticamEditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while (model.isBusy || !model.sourceIndexProgress.isEmpty), .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.sourceIndexProgress.isEmpty)
        XCTAssertNil(model.notice)
    }
}
