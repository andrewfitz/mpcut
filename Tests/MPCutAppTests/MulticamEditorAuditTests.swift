import AppKit
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

final class MulticamEditorAuditTests: XCTestCase {
    @MainActor
    func testFourCameraTransportFitsAtMinimumAndWideWindowSizes() throws {
        _ = NSApplication.shared
        let url = try fixture("ProRes-2997", "mov")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.useAnalysisSidecars = false
        let names = ["Wide", "Close", "Side", "Overhead"]
        model.confirmSetup(drafts: names.map { .init(source: .init(id: $0, file: url.path, name: $0), media: media) },
                           opening: names[0], audio: .none)
        let project = try XCTUnwrap(model.project)
        let hosting = NSHostingView(rootView: MulticamTransport(model: model, preview: model.preview, project: project))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 810, height: 43),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = hosting

        for width: CGFloat in [810, 1_160] {
            window.setContentSize(NSSize(width: width, height: 43))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.bounds.width, width, accuracy: 0.5)
            XCTAssertEqual(hosting.fittingSize.height, 43, accuracy: 0.5)
            XCTAssertGreaterThan(hosting.fittingSize.width, 500)
            XCTAssertLessThanOrEqual(hosting.fittingSize.width, 1_160)
        }
    }

    @MainActor
    func testResetStillReportsThatACancelledOperationStopped() async throws {
        let (model, _) = try twoAngleModel()
        defer { model.reset() }
        model.run("Slow") { token, _ in
            while !token.isCancelled { Thread.sleep(forTimeInterval: 0.002) }
            Thread.sleep(forTimeInterval: 0.05)
            return 1
        } onSuccess: { (_: Int) in }
        var stopped = 0
        XCTAssertTrue(model.cancelAndWait { stopped += 1 })
        model.reset()
        XCTAssertEqual(stopped, 0, "The worker has not finished yet")
        let deadline = ContinuousClock.now + .seconds(2)
        while stopped == 0, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(stopped, 1)

        // A later operation must not replay the earlier waiter.
        model.run("Quick") { _, _ in 1 } onSuccess: { (_: Int) in }
        let next = ContinuousClock.now + .seconds(2)
        while model.isBusy, .now < next { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(stopped, 1)
    }

    @MainActor
    func testSetupStoresNoBlankSourceName() throws {
        let url = try fixture("ProRes-2997", "mov")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [
            .init(source: .init(id: "wide", file: url.path, name: ""), media: media),
            .init(source: .init(id: "close", file: url.path, name: "  "), media: media),
            .init(source: .init(id: "tele", file: url.path, name: " Tele "), media: media)
        ], opening: "wide", audio: .none)
        XCTAssertEqual(model.project?.angles.map(\.name), [nil, nil, "Tele"])
    }

    @MainActor
    func testTrimStartKeepsThePlayheadOnTheTrimmedFrameInAssemblyPreview() throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        let original = MulticamRange(from: .zero, to: media.duration)
        XCTAssertTrue(model.edit { $0.assembly = [original, original] })
        model.setAssemblyPreview(true)
        model.preview.seek(to: try original.to.adding(frames[4]))
        XCTAssertEqual(model.currentGroupTime(), frames[4])

        model.trimOccurrence(.start)

        XCTAssertEqual(model.ranges, [original, .init(from: frames[4], to: original.to)])
        XCTAssertEqual(model.currentGroupTime(), frames[4])
        XCTAssertEqual(model.activeOccurrenceIndex, 1)
        XCTAssertEqual(model.selectedOccurrence, 1)

        model.undo()
        model.preview.seek(to: frames[4])
        model.trimOccurrence(.start)
        XCTAssertEqual(model.ranges, [.init(from: frames[4], to: original.to), original])
        XCTAssertEqual(model.currentGroupTime(), frames[4])
        XCTAssertEqual(model.activeOccurrenceIndex, 0)
    }

    @MainActor
    func testSavedProjectReopensIdenticallyAndFromAnotherDirectory() async throws {
        let camera = try fixture("Pause-Noisy", "mov")
        let sound = try fixture("Standalone-Chirp", "opus")
        let engine = CutEngine(useSidecar: false)
        let cameraInfo = try engine.inspectMulticamSource(camera)
        let soundInfo = try engine.inspectMulticamSource(sound)
        let stream = try XCTUnwrap(cameraInfo.audio.first?.stream.index)
        let soundStream = try XCTUnwrap(soundInfo.audio.first?.stream.index)
        let frames = cameraInfo.frames.map(\.time)
        let model = MulticamEditorModel()
        model.useAnalysisSidecars = false
        defer { model.reset() }
        model.confirmSetup(drafts: [
            .init(source: .init(id: "wide", file: camera.path, audioStream: stream), media: cameraInfo),
            .init(source: .init(id: "close", file: camera.path, audioStream: stream), media: cameraInfo),
            .init(source: .init(id: "lav", file: sound.path, audioStream: soundStream), media: soundInfo)
        ], opening: "wide", audio: .fixed(.init(source: "lav", stream: soundStream)))
        XCTAssertTrue(model.isChanged)
        model.updateSource("close") { $0.offset = RationalTime(numerator: -1, denominator: 100) }
        model.seekGroup(frames[4])
        model.take("close")
        model.changeSwitch(frames[4], audio: .init(source: "wide", stream: stream))
        XCTAssertTrue(model.edit { $0.assembly = [.init(from: frames[2], to: frames[8]), .init(from: .zero, to: frames[2])] })
        let edited = try XCTUnwrap(model.project)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("edit.multicam.json")
        XCTAssertTrue(model.saveProject(to: first))
        XCTAssertFalse(model.isChanged)
        XCTAssertEqual(model.project, edited)

        func resolved(_ url: URL) throws -> MulticamProject {
            var project = try MulticamProject.load(from: url)
            XCTAssertTrue(project.sources.allSatisfy { !$0.file.hasPrefix("/") })
            project.angles = project.angles.map { var copy = $0; copy.file = project.sourceURL(for: $0, relativeTo: url).path; return copy }
            project.audioSources = project.audioSources.map { var copy = $0; copy.file = project.sourceURL(for: $0, relativeTo: url).path; return copy }
            return project
        }
        func physical(_ project: MulticamProject) -> MulticamProject {
            var copy = project
            copy.angles = copy.angles.map { var s = $0; s.file = URL(fileURLWithPath: $0.file).resolvingSymlinksInPath().path; return s }
            copy.audioSources = copy.audioSources.map { var s = $0; s.file = URL(fileURLWithPath: $0.file).resolvingSymlinksInPath().path; return s }
            return copy
        }
        XCTAssertEqual(physical(try resolved(first)), physical(edited))

        let second = nested.appendingPathComponent("copy.json")
        XCTAssertTrue(model.saveProject(to: second))
        XCTAssertEqual(model.projectURL, second.standardizedFileURL)
        XCTAssertEqual(physical(try resolved(second)), physical(edited))

        let reopened = MulticamEditorModel()
        reopened.useAnalysisSidecars = false
        defer { reopened.reset() }
        reopened.openProject(second)
        try await waitForIdle(reopened)
        XCTAssertEqual(physical(try XCTUnwrap(reopened.project)), physical(edited))
        XCTAssertFalse(reopened.isChanged)
        XCTAssertNil(reopened.notice)
        XCTAssertTrue(reopened.sourceIssues.isEmpty)
        XCTAssertEqual(Set(reopened.media.keys), ["wide", "close", "lav"])
    }

    @MainActor
    func testSwitchEditingRules() throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        model.seekGroup(frames[2]); model.take("close")
        model.seekGroup(frames[5]); model.take("wide")
        model.seekGroup(frames[8]); model.take("close")
        XCTAssertEqual(model.project?.switches.map(\.at), [.zero, frames[2], frames[5], frames[8]])
        let pin = MulticamAudioSelection(source: "wide", stream: 1)
        model.changeSwitch(frames[5], audio: pin)

        // Taking at an existing marker updates it and keeps its microphone pin.
        model.seekGroup(frames[5]); model.take("close")
        XCTAssertEqual(model.project?.switches[2], .init(at: frames[5], angle: "close", audio: pin))
        XCTAssertEqual(model.project?.switches.count, 4)

        // A marker dragged past its neighbours keeps its own decision.
        model.moveSwitch(frames[5], to: frames[10])
        XCTAssertEqual(model.project?.switches.map(\.at), [.zero, frames[2], frames[8], frames[10]])
        XCTAssertEqual(model.project?.switches.last?.audio, pin)
        XCTAssertEqual(model.selectedSwitch, frames[10])

        let before = model.project
        model.moveSwitch(frames[10], to: frames[8])
        XCTAssertNotNil(model.notice); model.notice = nil
        model.moveSwitch(frames[10], to: .zero)
        XCTAssertNotNil(model.notice); model.notice = nil
        model.moveSwitch(frames[10], to: media.duration)
        XCTAssertNotNil(model.notice); model.notice = nil
        model.moveSwitch(.zero, to: frames[1])
        model.deleteSwitch(.zero)
        XCTAssertEqual(model.project, before)

        // The opening marker may change camera.
        model.seekGroup(.zero); model.take("close")
        XCTAssertEqual(model.project?.switches.first, .init(at: .zero, angle: "close"))

        // A moved marker that no longer exists selects nothing.
        model.moveSwitch(frames[4], to: frames[6])
        XCTAssertEqual(model.project?.switches.map(\.at), [.zero, frames[2], frames[8], frames[10]])
        XCTAssertNotEqual(model.selectedSwitch, frames[6])
    }

    @MainActor
    func testGroupSeekAcrossSwitchStaysInThePlayingRepeat() throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        let repeated = MulticamRange(from: .zero, to: frames[10])
        XCTAssertTrue(model.edit {
            $0.switches.append(.init(at: frames[5], angle: "close"))
            $0.assembly = [repeated, repeated]
        })
        model.setAssemblyPreview(true)
        model.selectOccurrence(0)
        model.preview.seek(to: try repeated.to.adding(frames[2]))
        XCTAssertEqual(model.activeOccurrenceIndex, 1)

        model.seekGroup(frames[7])

        XCTAssertEqual(model.preview.time, try repeated.to.adding(frames[7]))
        XCTAssertEqual(model.activeOccurrenceIndex, 1)
    }

    @MainActor
    func testCameraTakeAtOffFrameGroupEndDoesNotCreateASwitch() throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        let end = try frames[5].adding(.init(numerator: 1, denominator: 1_000))
        XCTAssertLessThan(end, frames[6])
        XCTAssertTrue(model.edit { $0.range.to = end })
        model.seekPlaybackBoundary(end: true)
        let original = model.project
        let history = model.undoStack
        let selection = model.selectedSwitch

        model.takeCamera(number: 2)

        XCTAssertEqual(model.project, original)
        XCTAssertEqual(model.undoStack, history)
        XCTAssertEqual(model.selectedSwitch, selection)
    }

    @MainActor
    func testAssemblyRulerSeekUsesTheExactFractionalJoin() throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        let join = frames[1]
        XCTAssertGreaterThan(try XCTUnwrap(timelineRationalTime(join.seconds)), join)
        XCTAssertTrue(model.edit {
            $0.assembly = [.init(from: .zero, to: join), .init(from: frames[4], to: frames[7])]
        })

        model.seekAssemblyTimeline(join.seconds, scrubbing: false)

        XCTAssertEqual(model.preview.time, join)
        XCTAssertEqual(model.currentGroupTime(), frames[4])
        XCTAssertEqual(model.selectedOccurrence, 1)
    }

    @MainActor
    func testScrubbingAssemblyEndPausesReverseShuttle() throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        let end = frames[10]
        XCTAssertTrue(model.edit { $0.assembly = [.init(from: .zero, to: end)] })
        model.setAssemblyPreview(true)
        model.seekGroup(frames[5])
        model.preview.shuttle(-1)
        XCTAssertLessThan(model.preview.playbackRate, 0)

        model.seekAssemblyTimeline(end.seconds, scrubbing: true)

        XCTAssertFalse(model.preview.isPlaying)
        XCTAssertEqual(model.preview.time, end)
    }

    @MainActor
    func testMovingAssemblyOccurrenceKeepsItsGroupFrameUnderThePlayhead() throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        let first = MulticamRange(from: .zero, to: frames[5])
        let second = MulticamRange(from: frames[5], to: frames[10])
        XCTAssertTrue(model.edit { $0.assembly = [first, second] })
        model.selectAssemblyOccurrence(1)
        model.seekGroup(frames[7])
        XCTAssertEqual(model.currentGroupTime(), frames[7])

        model.moveOccurrence(-1)

        XCTAssertEqual(model.ranges, [second, first])
        XCTAssertEqual(model.currentGroupTime(), frames[7])
        XCTAssertEqual(model.activeOccurrenceIndex, 0)
        XCTAssertEqual(model.selectedOccurrence, 0)
    }

    @MainActor
    func testGroupSplitFindsTheRetainedRangeUnderThePlayhead() throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        let first = MulticamRange(from: .zero, to: frames[4])
        let repeated = MulticamRange(from: frames[5], to: frames[10])
        XCTAssertTrue(model.edit { $0.assembly = [first, repeated, repeated] })
        model.setAnalysisSnap(.off)
        model.selectOccurrence(0)
        model.seekGroup(frames[7])

        XCTAssertTrue(model.canCutOccurrence)
        model.splitOccurrence()

        XCTAssertEqual(model.ranges, [first, .init(from: repeated.from, to: frames[7]),
                                     .init(from: frames[7], to: repeated.to), repeated])
        XCTAssertEqual(model.selectedOccurrence, 2)
        XCTAssertEqual(model.currentGroupTime(), frames[7])
        XCTAssertFalse(model.assemblyPreview)
        XCTAssertEqual(model.editSelection, .assembly)
        model.undo()
        XCTAssertEqual(model.ranges, [first, repeated, repeated])
        XCTAssertEqual(model.selectedOccurrence, 0)
    }

    @MainActor
    func testUndoRestoresSelectionWithTheProject() throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        model.seekGroup(frames[3]); model.take("close")
        XCTAssertEqual(model.selectedSwitch, frames[3])
        model.deleteSwitch(frames[3])
        XCTAssertNil(model.selectedSwitch)
        model.undo()
        XCTAssertEqual(model.project?.switches.map(\.at), [.zero, frames[3]])
        XCTAssertEqual(model.selectedSwitch, frames[3])
        model.redo()
        XCTAssertNil(model.selectedSwitch)
        model.undo()

        let a = MulticamRange(from: .zero, to: frames[4])
        let b = MulticamRange(from: frames[4], to: frames[8])
        let c = MulticamRange(from: frames[8], to: frames[10])
        XCTAssertTrue(model.edit { $0.assembly = [a, b, c] })
        model.selectOccurrence(2)
        model.removeOccurrence()
        XCTAssertEqual(model.ranges, [a, b])
        XCTAssertEqual(model.selectedOccurrence, 1)
        model.undo()
        XCTAssertEqual(model.ranges, [a, b, c])
        XCTAssertEqual(model.selectedOccurrence, 2)
        XCTAssertEqual(model.editSelection, .assembly)
    }

    @MainActor
    func testEditsAndExportsAreRefusedWhileBusyAndCancelLeavesNoNotice() async throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        XCTAssertTrue(model.edit { $0.assembly = [.init(from: .zero, to: frames[4]), .init(from: frames[4], to: frames[8])] })
        model.markIn = frames[1]; model.markOut = frames[3]
        let before = model.project
        let undo = model.undoStack
        model.run("Slow") { token, _ in
            while !token.isCancelled { Thread.sleep(forTimeInterval: 0.002) }
            throw CancellationError()
        } onSuccess: { (_: Int) in XCTFail("cancelled") }
        XCTAssertTrue(model.isBusy)
        var second = false
        model.run("Second") { _, _ in 1 } onSuccess: { (_: Int) in second = true }
        XCTAssertFalse(model.edit { $0.assembly = nil })
        model.seekGroup(frames[2]); model.take("close")
        model.moveOffset("close", by: 1)
        model.undo()
        model.addMarkedRange()
        model.removeMarkedRange()
        model.removeOccurrence()
        model.moveOccurrence(1)
        model.reorderAssemblyOccurrence(0, before: 2)
        model.splitOccurrence()
        model.trimOccurrence(.start)
        XCTAssertNil(model.trimAssemblyOccurrence(0, edge: .end, seconds: frames[3].seconds, commit: true))
        XCTAssertFalse(model.enqueueRanges([.init(from: .zero, to: frames[2])]))
        model.enqueueMarkedRange()
        XCTAssertFalse(model.replaceProgramAudio(with: .init(source: "wide", stream: 1)))
        model.setAssemblyPreview(true)
        XCTAssertFalse(model.assemblyPreview)
        model.export(output: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov"),
                     mode: .copy, tracks: .video, dryRun: true, wholeGroup: true)
        XCTAssertEqual(model.project, before)
        XCTAssertEqual(model.undoStack, undo)
        XCTAssertTrue(model.queuedRanges.isEmpty)
        XCTAssertEqual(model.status, "Slow")
        model.cancel()
        try await waitForIdle(model)
        XCTAssertFalse(second)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.status, "Cancelled.")
        XCTAssertFalse(model.isExporting)
        XCTAssertNil(model.progress)
    }

    @MainActor
    func testQueueExportSurfacesFailureAndReturnsToIdle() async throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        XCTAssertTrue(model.enqueueRanges([.init(from: .zero, to: frames[3]), .init(from: frames[3], to: frames[6])]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = Data("keep".utf8)
        let occupied = directory.appendingPathComponent("Multicam-002.mov")
        try sentinel.write(to: occupied)
        model.exportQueuedRanges(to: directory, container: "mov", mode: .copy, tracks: .video)
        XCTAssertTrue(model.isExporting)
        model.exportQueuedRanges(to: directory, container: "mov", mode: .copy, tracks: .video)
        model.removeQueuedRange(model.queuedRanges[0].id)
        XCTAssertEqual(model.queuedRanges.count, 2)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isBusy, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isExporting)
        XCTAssertTrue(model.notice?.message.contains("Range 2") == true)
        XCTAssertEqual(try Data(contentsOf: occupied), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Multicam-001.mov").path))
    }

    @MainActor
    func testSourceAndRangeEdgeCases() throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        model.seekGroup(frames[6]); model.take("close")
        let switches = model.project?.switches

        // Offsets move coverage under the markers and leave group zero alone.
        let offset = RationalTime(numerator: -1, denominator: 4)
        model.updateSource("close") { $0.offset = offset }
        XCTAssertEqual(model.project?.switches, switches)
        XCTAssertEqual(model.project?.range, .init(from: .zero, to: media.duration))
        let picture = try XCTUnwrap(try model.project?.plan().picture.last)
        XCTAssertEqual(picture.input.from, try frames[6].subtracting(offset))

        // The group end cannot cut off a switch, and can be extended.
        model.edit { $0.range.to = frames[5] }
        XCTAssertNotNil(model.notice); model.notice = nil
        XCTAssertEqual(model.project?.range.to, media.duration)
        let longer = try media.duration.adding(RationalTime(numerator: 2))
        XCTAssertTrue(model.edit { $0.range.to = longer })
        XCTAssertNil(model.notice)
        model.seekGroup(longer)
        model.take("wide")
        XCTAssertEqual(model.project?.switches, switches, "No switch can start at the exclusive group end")

        // Adding an angle later preserves switches and can be undone.
        model.confirmSetup(drafts: [.init(source: .init(id: "tele", file: media.url.path), media: media)],
                           opening: "", audio: .none)
        XCTAssertEqual(model.project?.angles.map(\.id), ["wide", "close", "tele"])
        XCTAssertEqual(model.project?.switches, switches)
        XCTAssertNotNil(model.media["tele"])
        model.undo()
        XCTAssertEqual(model.project?.angles.map(\.id), ["wide", "close"])
        XCTAssertNil(model.media["tele"])

        // Reversed marks describe the same range for every command.
        model.markIn = frames[8]; model.markOut = frames[2]
        XCTAssertTrue(model.canEnqueueMarkedRange)
        XCTAssertTrue(model.canAddMarkedRange)
        model.addMarkedRange()
        XCTAssertEqual(model.project?.assembly, [.init(from: frames[2], to: frames[8])])

        // Removing the only range returns to the whole group; the index stays valid.
        model.selectOccurrence(0)
        model.removeOccurrence()
        XCTAssertNil(model.project?.assembly)
        XCTAssertEqual(model.selectedOccurrence, 0)
        model.selectedOccurrence = 7
        model.moveOccurrence(-1)
        model.changeOccurrence(to: frames[3])
        model.removeOccurrence()
        XCTAssertNil(model.project?.assembly)
    }

    @MainActor
    func testFailedSwitchTimingSelectsThatSwitchForEditing() async throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let frames = media.frames.map(\.time)
        model.seekGroup(frames[4]); model.take("close")
        XCTAssertTrue(model.edit { $0.assembly = [.init(from: .zero, to: frames[6]), .init(from: frames[6], to: frames[9])] })
        model.selectAssemblyOccurrence(1)
        XCTAssertEqual(model.deleteTitle, "Delete Assembly Range")
        let at = String(decoding: try JSONEncoder().encode(frames[4]), as: UTF8.self)
        let diagnostic = try JSONDecoder().decode(MulticamDiagnostic.self, from: Data("""
            {"source":"close","group":{"from":"0","to":"1"},"sourceTime":{"from":"0","to":"1"},
             "output":{"from":"0","to":"1"},"at":\(at)}
            """.utf8))
        model.run("Check") { _, _ -> Int in
            throw CutError(code: "unsafe_switch", message: "Unsafe switch", nearest: [frames[3]], multicam: diagnostic)
        } onSuccess: { _ in }
        try await waitForIdle(model)
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(model.selectedSwitch, frames[4])
        XCTAssertEqual(model.suggestions, [frames[3]])
        XCTAssertEqual(model.deleteTitle, "Delete Switch")
        model.deleteSelection()
        XCTAssertEqual(model.ranges.count, 2)
        XCTAssertEqual(model.project?.switches.map(\.at), [.zero])
    }

    @MainActor
    func testClosedModelIsReleased() async throws {
        weak var released: MulticamEditorModel?
        do {
            let (model, media) = try twoAngleModel()
            released = model
            model.seekGroup(media.frames[3].time)
            model.take("close")
            model.setAssemblyPreview(true)
            XCTAssertTrue(model.enqueueRanges([.init(from: .zero, to: media.frames[3].time)]))
            model.run("Quick") { _, _ in 1 } onSuccess: { (_: Int) in }
            try await waitForIdle(model)
            model.reset()
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while released != nil, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(released)
    }

    @MainActor
    func testQueuedFilesUseTheProjectNameWithoutItsDocumentSuffix() throws {
        let (model, media) = try twoAngleModel()
        defer { model.reset() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(model.saveProject(to: directory.appendingPathComponent("Interview.multicam.json")))
        XCTAssertTrue(model.enqueueRanges([.init(from: .zero, to: media.frames[3].time)]))
        XCTAssertTrue(model.saveProject(to: directory.appendingPathComponent("Plain.json")))
        XCTAssertTrue(model.enqueueRanges([.init(from: .zero, to: media.frames[3].time)]))
        XCTAssertEqual(model.queuedRanges.map(\.name), ["Interview", "Plain"])
    }

    @MainActor
    private func twoAngleModel() throws -> (MulticamEditorModel, MediaInfo) {
        let url = try fixture("ProRes-2997", "mov")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let model = MulticamEditorModel()
        model.useAnalysisSidecars = false
        model.confirmSetup(drafts: ["wide", "close"].map { .init(source: .init(id: $0, file: url.path), media: media) },
                           opening: "wide", audio: .none)
        XCTAssertNotNil(model.project)
        return (model, media)
    }

    @MainActor
    private func waitForIdle(_ model: MulticamEditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while (model.isBusy || !model.sourceIndexProgress.isEmpty), .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.isBusy)
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }
}
