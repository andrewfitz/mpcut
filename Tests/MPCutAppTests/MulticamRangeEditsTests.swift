import AppKit
import SwiftUI
import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamRangeEditsTests: XCTestCase {
    func testShorteningFollowsReorderedAndRepeatedOccurrencesAndPreservesMarks() throws {
        let (project, media) = try fixture()
        let frames = media.frames.map(\.time)
        let first = MulticamRange(from: frames[2], to: media.duration)
        let second = MulticamRange(from: .zero, to: frames[2])
        let ranges = [first, second, first]
        let pause = AudioSpan(from: frames[4], to: frames[10])
        let marked = AudioSpan(from: frames[5], to: frames[11])
        func plan(protecting protected: Set<AudioSpan>) -> [MulticamPauseEdit] {
            MulticamSilencePlanner.plan(project: project, media: ["wide": media], ranges: ranges,
                                   pauses: [pause], scope: marked, minimum: 0, leave: 0, protected: protected)
        }
        let edits = plan(protecting: [])
        XCTAssertEqual(edits.map(\.id.occurrence), [0, 2])
        XCTAssertEqual(edits.compactMap(\.removal), Array(repeating: .init(from: frames[5], to: frames[10]), count: 2))
        let left = MulticamRange(from: first.from, to: frames[5])
        let right = MulticamRange(from: frames[10], to: first.to)
        XCTAssertEqual(MulticamSilencePlanner.retained(ranges, pauses: edits), [left, right, second, left, right])
        XCTAssertEqual(MulticamSilencePlanner.retained(ranges, pauses: edits, scope: marked),
                       Array(repeating: .init(from: frames[10], to: frames[11]), count: 2))
        let protected = plan(protecting: [pause])
        XCTAssertEqual(protected.map(\.isProtected), [true, true])
        XCTAssertEqual(MulticamSilencePlanner.retained(ranges, pauses: protected), ranges)
    }

    func testPauseAcrossSwitchSnapsToEachActiveCamerasFrameClock() throws {
        var (project, media) = try fixture()
        let frames = media.frames.map(\.time)
        let offset = RationalTime(numerator: 1, denominator: 120)
        project.angles.append(.init(id: "close", file: media.url.path, offset: offset))
        project.switches.append(.init(at: frames[6], angle: "close"))
        let pause = AudioSpan(from: frames[3], to: frames[10])
        let plan = MulticamSilencePlanner.plan(project: project, media: ["wide": media, "close": media],
                                           ranges: [project.range], pauses: [pause], scope: nil,
                                           minimum: 0, leave: 0, protected: [])
        XCTAssertEqual(plan.compactMap(\.removal), [
            .init(from: frames[3], to: try frames[9].adding(offset))
        ])
    }

    @MainActor
    func testSilenceScanQueuesTakesAndAppliesUndoableAssembly() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.useAnalysisSidecars = false
        let draft = MulticamEditorModel.SourceDraft(source: .init(id: "wide", file: url.path, audioStream: stream),
                                                    media: media)
        model.confirmSetup(drafts: [draft], opening: "wide", audio: .fixed(.init(source: "wide", stream: stream)))
        model.configureSilenceAnalysis(minimum: 1, threshold: -45)
        model.scanAnalysis(.silence)
        let deadline = ContinuousClock.now + .seconds(3)
        while !model.canApplyPauses && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.canApplyPauses)
        let original = try XCTUnwrap(model.project)
        let pauses = model.multicamPausePlan
        let cut = try XCTUnwrap(pauses.first?.removal)
        XCTAssertLessThan(cut.from, cut.to)

        model.applyMulticamPauses(queueTakes: true, plan: pauses)
        XCTAssertEqual(model.project, original)
        XCTAssertEqual(model.queuedRanges.map(\.range), [
            .init(from: original.range.from, to: cut.from), .init(from: cut.to, to: original.range.to)
        ])
        model.reviewMulticamPause(try XCTUnwrap(pauses.first))
        XCTAssertEqual(model.pauseEdits.review?.plan.intervals.count, 2)
        model.pauseEdits.review = nil

        model.applyMulticamPauses(queueTakes: false, plan: pauses)
        XCTAssertEqual(model.ranges, model.queuedRanges.map(\.range))
        XCTAssertTrue(model.assemblyPreview)
        model.undo()
        XCTAssertEqual(model.project, original)
    }

    @MainActor
    func testTrimActsOnPlayingOccurrenceAndMarkedRemovalCanBeUndone() throws {
        let (project, media) = try fixture()
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: project.angles[0], media: media)], opening: "wide", audio: .none)
        let frames = media.frames.map(\.time)
        let original = MulticamRange(from: .zero, to: media.duration)
        XCTAssertTrue(model.edit { $0.assembly = [original, original] })
        model.setAssemblyPreview(true)
        model.selectOccurrence(0)
        model.preview.seek(to: try original.to.adding(frames[8]))
        model.trimOccurrence(.end)
        XCTAssertEqual(model.ranges, [original, .init(from: .zero, to: frames[8])])
        model.undo()
        XCTAssertEqual(model.ranges, [original, original])

        model.markIn = frames[9]
        model.markOut = frames[3]
        model.removeMarkedRange()
        let retained = [MulticamRange(from: .zero, to: frames[3]),
                        MulticamRange(from: frames[9], to: original.to)]
        XCTAssertEqual(model.ranges, retained + retained)
        XCTAssertEqual(model.project?.switches, project.switches)
        model.undo()
        XCTAssertEqual(model.ranges, [original, original])
    }

    @MainActor
    func testDeleteFollowsAssemblyAndSwitchGesturesWithRepeatedRanges() throws {
        let (project, media) = try fixture()
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: project.angles[0], media: media)], opening: "wide", audio: .none)
        let frames = media.frames.map(\.time)
        let duplicate = MulticamRange(from: .zero, to: frames[7])
        let distinct = MulticamRange(from: frames[7], to: media.duration)
        let cut = frames[3]
        XCTAssertTrue(model.edit {
            $0.switches.append(.init(at: cut, angle: "wide"))
            $0.assembly = [duplicate, distinct, duplicate]
        })

        model.selectMarker(cut)
        model.selectAssemblyOccurrence(2)
        XCTAssertEqual(model.deleteTitle, "Delete Assembly Range")
        model.deleteSelection()
        XCTAssertEqual(model.ranges, [duplicate, distinct])
        XCTAssertEqual(model.project?.switches.map(\.at), [.zero, cut])

        model.selectMarker(cut)
        XCTAssertEqual(model.deleteTitle, "Delete Switch")
        model.deleteSelection()
        XCTAssertEqual(model.ranges, [duplicate, distinct])
        XCTAssertEqual(model.project?.switches.map(\.at), [.zero])

        model.selectMarker(.zero)
        XCTAssertFalse(model.canDeleteSelection)
        model.deleteSelection()
        XCTAssertEqual(model.project?.switches.map(\.at), [.zero])

        model.selectAssemblyOccurrence(0)
        model.markIn = frames[1]
        model.markOut = frames[2]
        XCTAssertEqual(model.deleteTitle, "Delete Marked Range")
        model.deleteSelection()
        XCTAssertEqual(model.ranges, [
            .init(from: duplicate.from, to: frames[1]), .init(from: frames[2], to: duplicate.to), distinct
        ])
        XCTAssertNil(model.markedGroupSpan)
        XCTAssertEqual(model.project?.switches.map(\.at), [.zero])

        XCTAssertTrue(model.edit { $0.assembly = [duplicate] })
        model.selectAssemblyOccurrence(0)
        XCTAssertFalse(model.canDeleteSelection)
        model.deleteSelection()
        XCTAssertEqual(model.project?.assembly, [duplicate])

        XCTAssertTrue(model.edit { $0.assembly = nil })
        model.selectAssemblyOccurrence(0)
        XCTAssertFalse(model.canDeleteSelection)
        model.deleteSelection()
        XCTAssertNil(model.project?.assembly)
    }

    @MainActor
    func testPauseNavigationOpensAssemblyAndSeeksTheRequestedRepeat() throws {
        let (project, media) = try fixture()
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: project.angles[0], media: media)], opening: "wide", audio: .none)
        let range = MulticamRange(from: .zero, to: media.duration)
        XCTAssertTrue(model.edit { $0.assembly = [range, range] })
        XCTAssertFalse(model.assemblyPreview)
        let pause = AudioSpan(from: media.frames[4].time, to: media.frames[10].time)

        model.seekMulticamPause(.init(id: .init(occurrence: 1, span: pause), visible: pause,
                                      removal: pause, isProtected: false))

        XCTAssertTrue(model.assemblyPreview)
        XCTAssertEqual(model.selectedOccurrence, 1)
        XCTAssertEqual(model.preview.time, try range.to.adding(pause.from))
    }

    @MainActor
    func testSkippingUsesCurrentRepeatAndDoesNotChangeAssembly() throws {
        let (project, media) = try fixture()
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: project.angles[0], media: media)], opening: "wide", audio: .none)
        let frames = media.frames.map(\.time)
        let range = MulticamRange(from: .zero, to: media.duration)
        XCTAssertTrue(model.edit { $0.assembly = [range, range] })
        model.setAssemblyPreview(true)
        model.selectOccurrence(0)
        model.preview.seek(to: try range.to.adding(frames[5]))
        let pause = AudioSpan(from: frames[4], to: frames[10])
        let plan = [
            MulticamPauseEdit(id: .init(occurrence: 0, span: pause), visible: pause, removal: nil, isProtected: true),
            MulticamPauseEdit(id: .init(occurrence: 1, span: pause), visible: pause, removal: pause, isProtected: false)
        ]
        model.pauseEdits.skip = true
        model.preview.togglePlayback()
        XCTAssertTrue(model.preview.isPlaying)
        model.skipMulticamPause(plan)
        // Playing preview time is published on display ticks. The live clock can
        // already have crossed the pause while this synchronous test holds the main actor.
        XCTAssertGreaterThanOrEqual(model.preview.currentTime(), try range.to.adding(pause.to))
        XCTAssertEqual(model.ranges, [range, range])
    }

    @MainActor
    func testSplitUsesTheSameSnappedBoundaryAsTrimInRepeatedRanges() throws {
        let (project, media) = try fixture()
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: project.angles[0], media: media)], opening: "wide", audio: .none)
        let frames = media.frames.map(\.time)
        let original = MulticamRange(from: .zero, to: media.duration)
        XCTAssertTrue(model.edit { $0.assembly = [original, original] })
        model.setAssemblyPreview(true)
        model.setAnalysisSnap(.keyframes)
        let subframe = RationalTime(numerator: 1, denominator: 1000)
        model.preview.seek(to: try original.to.adding(subframe))
        XCTAssertFalse(model.canCutOccurrence)
        model.splitOccurrence()
        XCTAssertEqual(model.ranges, [original, original])

        model.preview.seek(to: try original.to.adding(frames[8]).adding(subframe))
        XCTAssertTrue(model.canCutOccurrence)
        model.splitOccurrence()
        XCTAssertEqual(model.ranges, [original, .init(from: .zero, to: frames[8]), .init(from: frames[8], to: original.to)])
        XCTAssertEqual(model.activeOccurrenceIndex, 2)
        XCTAssertEqual(model.selectedOccurrence, 2)
        XCTAssertEqual(model.currentGroupTime(), frames[8])
        XCTAssertFalse(model.canCutOccurrence)
    }

    @MainActor
    func testGroupSplitFindsTheRangeAtThePlayhead() throws {
        let (project, media) = try fixture()
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: project.angles[0], media: media)], opening: "wide", audio: .none)
        model.setAnalysisSnap(.off)
        let frames = media.frames.map(\.time)
        let first = MulticamRange(from: .zero, to: frames[4])
        let second = MulticamRange(from: frames[6], to: media.duration)
        XCTAssertTrue(model.edit { $0.assembly = [first, second] })
        model.selectOccurrence(0)

        model.seekGroup(frames[5])
        XCTAssertFalse(model.canCutOccurrence)

        model.seekGroup(frames[8])
        XCTAssertTrue(model.canCutOccurrence)
        model.splitOccurrence()

        XCTAssertFalse(model.assemblyPreview)
        XCTAssertEqual(model.ranges, [first, .init(from: second.from, to: frames[8]), .init(from: frames[8], to: second.to)])
        XCTAssertEqual(model.selectedOccurrence, 2)
        XCTAssertEqual(model.currentGroupTime(), frames[8])
        XCTAssertFalse(model.canCutOccurrence)
        XCTAssertEqual(model.splitRevision, 1)
        model.undo()
        XCTAssertEqual(model.ranges, [first, second])
        XCTAssertEqual(model.selectedOccurrence, 0)
    }

    @MainActor
    func testGroupSurfaceCommitsDragAndCancelsWithEscape() async throws {
        let (project, media) = try fixture()
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: project.angles[0], media: media)], opening: "wide", audio: .none)
        model.setAnalysisSnap(.off)
        let timeline = MulticamTimeline(project: project, media: model.media, playhead: .zero,
                                        seek: { _ in XCTFail("Range gesture sought") }, take: { _ in },
                                        moveSwitch: { _, _ in XCTFail("Range gesture moved a switch") },
                                        deleteSwitch: { _ in }, selectSwitch: { _ in },
                                        thumbnailService: model.filmstrip, selectRange: model.selectGroupRange)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: timeline)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 260), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func findSurface(_ view: NSView) -> MulticamGroupRangeSurface.Surface? {
            (view as? MulticamGroupRangeSurface.Surface) ?? view.subviews.lazy.compactMap(findSurface).first
        }
        for _ in 0..<30 where findSurface(host) == nil { try await Task.sleep(for: .milliseconds(10)) }
        let surface = try XCTUnwrap(findSurface(host))
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: surface.convert(.init(x: x, y: 10), to: nil),
                                             modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        surface.mouseDown(with: try mouse(.leftMouseDown, 40))
        surface.mouseDragged(with: try mouse(.leftMouseDragged, 240))
        XCTAssertNil(model.markedGroupSpan)
        surface.mouseUp(with: try mouse(.leftMouseUp, 240))
        let selected = try XCTUnwrap(model.markedGroupSpan)
        surface.mouseDown(with: try mouse(.leftMouseDown, 120))
        surface.mouseDragged(with: try mouse(.leftMouseDragged, 350))
        surface.cancelOperation(nil)
        surface.mouseUp(with: try mouse(.leftMouseUp, 350))
        XCTAssertEqual(model.markedGroupSpan, selected)
        surface.mouseDown(with: try mouse(.leftMouseDown, 100))
        surface.mouseUp(with: try mouse(.leftMouseUp, 100))
        XCTAssertFalse(model.canActOnRange)
    }

    @MainActor
    func testAssemblyDragAcrossRepeatEditsOnlySelectedOutput() throws {
        let (project, media) = try fixture()
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: project.angles[0], media: media)], opening: "wide", audio: .none)
        model.setAnalysisSnap(.off)
        let frames = media.frames.map(\.time)
        let clip = MulticamRange(from: frames[1], to: frames[7])
        XCTAssertTrue(model.edit { $0.assembly = [clip, clip, clip] })
        model.rangeTool = true
        let duration = try clip.to.subtracting(clip.from)
        let start = try frames[4].subtracting(clip.from).seconds + 0.000001
        let end = duration.seconds + (try frames[3].subtracting(clip.from)).seconds + 0.000001
        model.selectAssemblyRange(end, start)
        let head = MulticamRange(from: clip.from, to: frames[4])
        let tail = MulticamRange(from: frames[3], to: clip.to)
        let expected = [MulticamRange(from: frames[4], to: clip.to), MulticamRange(from: clip.from, to: frames[3])]
        XCTAssertEqual(model.selectedExportRanges, expected)
        model.chooseSelectionExport()
        XCTAssertEqual(model.exportProgram, .selection)
        model.splitSelectedRange()
        XCTAssertEqual(model.ranges, [head] + expected + [tail, clip])
        XCTAssertEqual(model.selectedExportRanges, expected)
        model.deleteSelection()
        XCTAssertEqual(model.ranges, [head, tail, clip])
        XCTAssertTrue(model.selectedExportRanges.isEmpty)
        XCTAssertEqual(model.exportProgram, .selection)
        XCTAssertNotNil(model.exportSourceIssue(tracks: .video, wholeGroup: false, selection: model.selectedExportRanges))
        model.undo()
        XCTAssertEqual(model.ranges, [head] + expected + [tail, clip])
        XCTAssertEqual(model.selectedExportRanges, expected)
        XCTAssertFalse(model.canSplitSelectedRange)
        model.undo()
        XCTAssertEqual(model.ranges, [clip, clip, clip])
        XCTAssertEqual(model.selectedExportRanges, expected)
        XCTAssertTrue(model.canSplitSelectedRange)
        model.redo()
        model.redo()
        XCTAssertEqual(model.ranges, [head, tail, clip])
        XCTAssertTrue(model.selectedExportRanges.isEmpty)
        model.undo()
        model.undo()
        model.selectAssemblyRange(start, start)
        XCTAssertFalse(model.canDeleteSelection)
        model.deleteSelection()
        XCTAssertEqual(model.ranges, [clip, clip, clip])
    }

    @MainActor
    func testSelectionCopyWritesOnlyFramesFromSelectedOccurrences() async throws {
        let (project, media) = try fixture()
        let model = MulticamEditorModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selection-\(UUID()).mov")
        defer { model.reset(); try? FileManager.default.removeItem(at: url) }
        model.confirmSetup(drafts: [.init(source: project.angles[0], media: media)], opening: "wide", audio: .none)
        model.setAnalysisSnap(.off)
        let frames = media.frames.map(\.time)
        let clip = MulticamRange(from: .zero, to: frames[7])
        XCTAssertTrue(model.edit { $0.assembly = [clip, clip, clip] })
        model.selectAssemblyRange(frames[5].seconds + 0.000001, clip.to.seconds + frames[3].seconds + 0.000001)
        model.export(output: url, mode: .copy, tracks: .video, dryRun: false, wholeGroup: false,
                     selection: model.selectedExportRanges)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.notice)
        let written = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        XCTAssertEqual(written.frames.count, 5)
        XCTAssertEqual(written.duration, frames[5])
        XCTAssertEqual(model.ranges, [clip, clip, clip])
    }

    @MainActor
    func testGroupDragUsesGroupClockAndClickDisablesRangeActions() throws {
        let (project, media) = try fixture()
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: project.angles[0], media: media)], opening: "wide", audio: .none)
        model.setAnalysisSnap(.off)
        let frames = media.frames.map(\.time)
        let clip = MulticamRange(from: .zero, to: frames[9])
        XCTAssertTrue(model.edit { $0.assembly = [clip, clip] })
        model.rangeTool = true
        model.selectGroupRange(frames[6], frames[2])
        XCTAssertEqual(model.selectedExportRanges, [.init(from: frames[2], to: frames[6])])
        model.deleteSelection()
        let kept = [MulticamRange(from: clip.from, to: frames[2]), MulticamRange(from: frames[6], to: clip.to)]
        XCTAssertEqual(model.ranges, kept + kept)
        model.undo()
        model.selectGroupRange(frames[4], frames[4])
        XCTAssertFalse(model.canActOnRange)
        model.deleteSelection()
        XCTAssertEqual(model.ranges, [clip, clip])
    }

    @MainActor
    func testRangeActionsMatchAssemblyCoverage() throws {
        let (project, media) = try fixture()
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: project.angles[0], media: media)], opening: "wide", audio: .none)
        model.setAnalysisSnap(.off)
        model.rangeTool = true
        let frames = media.frames.map(\.time)
        let clip = MulticamRange(from: frames[3], to: frames[9])
        XCTAssertTrue(model.edit { $0.assembly = [clip, clip] })

        model.selectGroupRange(frames[0], frames[2])
        XCTAssertTrue(model.canActOnRange)
        XCTAssertFalse(model.canSplitSelectedRange)
        XCTAssertFalse(model.canDeleteSelectedRange)

        let duration = try clip.to.subtracting(clip.from)
        model.selectAssemblyRange(0, duration.seconds)
        XCTAssertEqual(model.selectedExportRanges, [clip])
        XCTAssertFalse(model.canSplitSelectedRange)
        XCTAssertTrue(model.canDeleteSelectedRange)

        model.selectAssemblyRange(0, duration.seconds * 2)
        XCTAssertEqual(model.selectedExportRanges, [clip, clip])
        XCTAssertFalse(model.canSplitSelectedRange)
        XCTAssertFalse(model.canDeleteSelectedRange)
        model.deleteSelection()
        XCTAssertEqual(model.ranges, [clip, clip])
        XCTAssertTrue(model.canActOnRange)

        model.chooseSelectionExport()
        model.markIn = nil
        model.markOut = nil
        XCTAssertTrue(model.selectedExportRanges.isEmpty)
        XCTAssertFalse(model.canActOnRange)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("empty-selection-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: destination) }
        model.export(output: destination, mode: .copy, tracks: .video, dryRun: false, wholeGroup: false,
                     selection: model.selectedExportRanges)
        XCTAssertNotNil(model.notice)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        model.chooseProgramExport()
        XCTAssertEqual(model.exportProgram, .assembly)
    }

    private func fixture() throws -> (MulticamProject, MediaInfo) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: media.duration),
                                      angles: [.init(id: "wide", file: url.path)],
                                      audio: .none, switches: [.init(at: .zero, angle: "wide")])
        return (project, media)
    }
}
