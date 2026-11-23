import AppKit
import ImageIO
import MPCutCore
import UniformTypeIdentifiers
import XCTest
@testable import MPCutApp

/// The multicam editor asks after an edit made by hand lowers the tier of the program, and never for another edit.
final class MulticamTierGateTests: XCTestCase {
    /// A range that starts inside a picture group: Smart Trim encodes that edge.
    private let inside = RationalTime(numerator: 7, denominator: 25)

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    @MainActor
    private func settle(_ model: MulticamEditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        // The tier is current before the gate has compared it with the tier before the edits.
        while model.isBusy || !model.sourceIndexProgress.isEmpty || !model.tierIsCurrent || model.tierGate.isComparing, .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.tierIsCurrent)
        XCTAssertFalse(model.tierGate.isComparing)
    }

    /// The questions an editor asked, each answered with `answer`.
    @MainActor
    private final class Asked {
        var prompts: [TierPrompt] = []
        var answer = TierPrompt.Choice(answer: .proceed)
    }

    /// One camera whose whole group is the program, with its tier known.
    @MainActor
    private func editor() async throws -> (model: MulticamEditorModel, asked: Asked, end: RationalTime) {
        let url = try fixture("SmartTrim-GOP", "mp4")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let model = MulticamEditorModel()
        model.useAnalysisSidecars = false
        let asked = Asked()
        model.tierGate.ask = { prompt, answer in
            asked.prompts.append(prompt)
            answer(asked.answer)
        }
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: url.path), media: media)], opening: "wide", audio: .none)
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        XCTAssertTrue(asked.prompts.isEmpty, "Opening sources never asks.")
        return (model, asked, media.duration)
    }

    @MainActor
    func testLoweringByHandAsksOnceAndContinueKeepsTheEdit() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        XCTAssertTrue(asked.prompts.isEmpty, "The question waits for the tier of the edit.")
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertEqual(prompt.from, .trueLossless)
        XCTAssertEqual(prompt.to.tier, .lossless)
        XCTAssertEqual(prompt.applied, 1)
        XCTAssertEqual(prompt.factors.map(\.id), [.cutVideoStart])
        XCTAssertEqual(prompt.title, "Change export quality from True Lossless to Lossless?")
        XCTAssertEqual(prompt.buttons.map(\.title), ["Continue", "Cancel"])
        XCTAssertTrue(prompt.message.contains("Smart Trim"), prompt.message)
        XCTAssertTrue(prompt.message.contains("Verified times near this cut: "), prompt.message)
        XCTAssertFalse(prompt.message.contains("Cancel undoes"), prompt.message)
        // The question names the source and never gives its id.
        let source = try XCTUnwrap(model.project?.sources.first)
        XCTAssertTrue(prompt.message.hasPrefix("Source \(source.displayName) "), prompt.message)
        if source.displayName != source.id { XCTAssertFalse(prompt.message.contains(source.id), prompt.message) }
        // The edit stays, and its tier is not asked about again.
        XCTAssertEqual(model.project?.assembly, [.init(from: inside, to: end)])
        XCTAssertEqual(model.settledTier, .lossless)
        XCTAssertEqual(model.historyActions, ["Add Marked Range"])
        XCTAssertTrue(model.preferences.warnBeforeLoweringExportTier)

        // An edit by hand that keeps the tier, and one that raises it, only change the badge.
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        model.byHand { model.removeOccurrence(1) }
        model.byHand { model.changeOccurrence(0, from: .zero) }
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        XCTAssertEqual(asked.prompts.count, 1)
    }

    @MainActor
    func testCancelUndoesTheEditThatLoweredTheTier() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        asked.answer = .init(answer: .cancel)
        // An earlier edit by hand whose tier is known is not part of the question.
        model.byHand { model.addAssemblyRange(.init(from: .zero, to: end)) }
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        let before = try XCTUnwrap(model.project)

        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertEqual(asked.prompts.first?.applied, 1)
        XCTAssertEqual(model.project, before)
        XCTAssertEqual(model.settledTier, .trueLossless)
        XCTAssertEqual(model.historyCursor, 1)
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.preferences.warnBeforeLoweringExportTier, "Cancelling changes nothing, including the preference.")

        // Cancel is an undo: the edit can be redone, and redoing it never asks.
        XCTAssertEqual(model.redoStack.count, 1)
        model.redo()
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        XCTAssertEqual(asked.prompts.count, 1)
    }

    @MainActor
    func testSeveralEditsBeforeTheTierArrivesAreCancelledTogether() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        asked.answer = .init(answer: .cancel)
        let before = try XCTUnwrap(model.project)
        model.byHand { model.addAssemblyRange(.init(from: .zero, to: end)) }
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        model.byHand { model.reorderAssemblyOccurrence(1, before: 0) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertEqual(prompt.applied, 3)
        XCTAssertTrue(prompt.message.hasSuffix("Cancel undoes the last 3 edits."), prompt.message)
        XCTAssertEqual(model.project, before, "Cancel returns to the program whose tier was last known.")
        XCTAssertEqual(model.historyCursor, 0)
        XCTAssertEqual(model.redoStack.count, 3)
        XCTAssertEqual(model.settledTier, .trueLossless)
    }

    @MainActor
    func testEditsUndoneBeforeTheTierArrivesAreNotAskedAbout() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        // Undone to before the edit.
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        model.undo()
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        // Undone and redone: the tier that arrives is the tier of a redo.
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        model.undo()
        model.redo()
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        XCTAssertTrue(asked.prompts.isEmpty)
    }

    /// The tier that arrives is compared with the tier of the program before the first edit by hand, and with nothing
    /// else. When that tier was still being checked it is found for the question.
    @MainActor
    func testTheTierOfTheProgramBeforeTheFirstEditByHandIsComparedWith() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        // A remote edit lowers the tier. An edit by hand lands before that tier is known and does not lower it further.
        model.addAssemblyRange(.init(from: inside, to: end))
        XCTAssertNil(model.settledTier)
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        XCTAssertTrue(asked.prompts.isEmpty, "The remote edit lowered the tier. The last known tier is not what the edit by hand started from.")

        model.removeOccurrence(1)
        model.changeOccurrence(0, from: .zero)
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)

        // The other way round: a remote edit keeps the tier, and an edit by hand lowers it before that tier is known.
        model.addAssemblyRange(.init(from: .zero, to: end))
        XCTAssertNil(model.settledTier)
        let remote = try XCTUnwrap(model.project)
        asked.answer = .init(answer: .cancel)
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1, "The tier before the edit by hand is found for the question.")
        XCTAssertEqual(asked.prompts.first?.from, .trueLossless)
        XCTAssertEqual(asked.prompts.first?.to.tier, .lossless)
        XCTAssertEqual(asked.prompts.first?.applied, 1)
        XCTAssertEqual(model.project, remote, "Cancel undoes the edit by hand and keeps the remote edit.")
        XCTAssertEqual(model.settledTier, .trueLossless)
        asked.prompts = []
        asked.answer = .init(answer: .proceed)
        model.removeOccurrence(1)
        try await settle(model)

        // A tier that is being checked is not a tier: the edit is not compared with it.
        model.tierState = .checking
        model.tierGate.settled(model)
        model.byHand { model.changeOccurrence(0, from: inside) }
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        XCTAssertEqual(asked.prompts.count, 1, "Checking in between leaves the last known tier in place.")
        XCTAssertEqual(asked.prompts.first?.from, .trueLossless)
    }

    @MainActor
    func testAnEditThatStopsEveryModeAsksAndCancelUndoesIt() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        asked.answer = .init(answer: .cancel)
        let before = try XCTUnwrap(model.project)
        // A cut that is on no picture.
        model.byHand { model.edit { $0.assembly = [.init(from: RationalTime(numerator: 1, denominator: 3), to: end)] } }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertNil(prompt.to.tier)
        XCTAssertEqual(prompt.title, "“Edit Assembly” prevents export")
        XCTAssertEqual(prompt.factors.first?.id, .cutOffFrame)
        XCTAssertEqual(model.project, before)
        XCTAssertEqual(model.settledTier, .trueLossless)
    }

    @MainActor
    func testThePreferenceTurnsTheQuestionOff() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        // "Don't ask again" on a kept edit stores the preference.
        asked.answer = .init(answer: .proceed, dontAskAgain: true)
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertFalse(model.preferences.warnBeforeLoweringExportTier)
        XCTAssertEqual(model.settledTier, .lossless)
        model.undo()
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        // With it off the same edit lowers the tier without a question.
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        XCTAssertEqual(asked.prompts.count, 1)
    }

    /// Remote commands, undo and redo lower the tier without a question, alone or around edits made by hand.
    @MainActor
    func testRemoteEditsUndoAndRedoNeverAsk() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        @discardableResult
        func remote(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
            let result = try await model.mcpCommand(tool: tool, arguments: arguments, validateCommit: {})
            return try XCTUnwrap(result)
        }
        let append: [String: Any] = ["action": "append", "from": inside.description, "to": end.description]

        try await remote("multicam_assembly_edit", append)
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        try await remote("history_undo")
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        try await remote("history_redo")
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        let history = try await remote("history_read")
        let token = try XCTUnwrap(history["history_token"] as? String)
        try await remote("history_state_restore", ["index": 0, "history_token": token])
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)

        // The editor's own undo and redo, and a model call that no one made by hand.
        model.redo()
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        model.undo()
        try await settle(model)
        model.addAssemblyRange(.init(from: inside, to: end))
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        model.undo()
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)

        // The toolbar's Undo and Redo run inside `byHand`, as every tool does. They are not edits.
        model.byHand { model.redo() }
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        model.byHand { model.undo() }
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)

        // An edit by hand keeps the tier. A remote edit lowers it before that tier arrives.
        model.byHand { model.addAssemblyRange(.init(from: .zero, to: end)) }
        try await remote("multicam_assembly_edit", append)
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)

        // A remote command that a nested run loop lets in while an edit by hand runs is not by hand.
        try await remote("history_undo")
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        // The run loop calls the block as it calls an event, outside any task, and its nested turn runs the command.
        let ranInside: Bool = await withCheckedContinuation { done in
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    model.byHand {
                        Task { @MainActor in _ = try? await model.mcpCommand(tool: "multicam_assembly_edit", arguments: append, validateCommit: {}) }
                        let deadline = Date(timeIntervalSinceNow: 5)
                        while model.project?.assembly?.count != 2, Date() < deadline {
                            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
                        }
                        done.resume(returning: model.project?.assembly?.count == 2)
                    }
                }
            }
        }
        XCTAssertTrue(ranInside, "The remote command ran while the edit by hand did.")
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        XCTAssertEqual(model.project?.assembly?.count, 2)

        XCTAssertTrue(asked.prompts.isEmpty)
        XCTAssertTrue(model.preferences.warnBeforeLoweringExportTier)
    }

    /// Adding or relinking a source is followed by its index, not by a tier of the same sources.
    @MainActor
    func testAnEditThatChangesTheSourcesIsNotAskedAbout() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        let inside = inside
        let added = model.byHand {
            model.edit("Add Multicam Sources") { project in
                project.assembly = [.init(from: inside, to: end)]
                project.angles.append(.init(id: "close", file: project.angles[0].file))
            }
        }
        XCTAssertTrue(added)
        try await settle(model)
        XCTAssertEqual(model.project?.sources.count, 2)
        XCTAssertEqual(model.settledTier, .lossless)
        XCTAssertTrue(asked.prompts.isEmpty)
    }

    /// With history off there is nothing to undo, so Cancel puts the earlier project back.
    @MainActor
    func testCancelRestoresTheProjectWhenHistoryIsOff() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        model.preferences.historyLimit = 0
        asked.answer = .init(answer: .cancel)
        let before = try XCTUnwrap(model.project)
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        XCTAssertTrue(model.undoStack.isEmpty)
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertEqual(model.project, before)
        XCTAssertEqual(model.settledTier, .trueLossless)
        XCTAssertNil(model.notice)
    }

    /// The editor's own commands and tools are edits made by hand without their callers saying so.
    @MainActor
    func testTheEditorsCommandsAreEditsMadeByHand() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        asked.answer = .init(answer: .cancel)
        model.addAssemblyRange(.init(from: .zero, to: end))
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        // Trim Start to Playhead, inside a picture group.
        model.setAssemblyPreview(true)
        model.selectAssemblyOccurrence(0)
        model.seekAssembly(at: inside, scrubbing: false)
        XCTAssertTrue(model.canTrimOccurrence)
        model.trimOccurrence(.start)
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertEqual(asked.prompts.first?.action, "Trim Assembly Range")
        XCTAssertEqual(model.project?.assembly, [.init(from: .zero, to: end)])
    }

    @MainActor
    func testWithoutAVisibleWindowThereIsNoOneToAsk() async throws {
        let (model, _, end) = try await editor()
        defer { model.reset() }
        model.tierGate.ask = nil
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        XCTAssertEqual(model.project?.assembly, [.init(from: inside, to: end)])
    }

    // MARK: Edits made before a tier is known

    /// An edit by hand made while the first tier of new sources is being checked.
    @MainActor
    func testAnEditByHandWhileTheFirstTierIsCheckedAsksOnce() async throws {
        let url = try fixture("SmartTrim-GOP", "mp4")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.useAnalysisSidecars = false
        let asked = Asked()
        asked.answer = .init(answer: .cancel)
        model.tierGate.ask = { prompt, answer in
            asked.prompts.append(prompt)
            answer(asked.answer)
        }
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: url.path), media: media)], opening: "wide", audio: .none)
        let opened = try XCTUnwrap(model.project)
        XCTAssertNil(model.settledTier, "The first tier has not arrived.")
        model.byHand { model.addAssemblyRange(.init(from: inside, to: media.duration)) }
        XCTAssertNotEqual(model.project, opened)
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertEqual(asked.prompts.first?.from, .trueLossless)
        XCTAssertEqual(asked.prompts.first?.to.tier, .lossless)
        XCTAssertEqual(model.project, opened)
        XCTAssertEqual(model.settledTier, .trueLossless)
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
    }

    /// A saved project opens before its sources are indexed. An edit by hand made then is asked about once the
    /// indexes and the tier arrive, and Cancel returns to the project as it was opened.
    @MainActor
    func testAnEditByHandBeforeTheSourcesOfAnOpenedProjectAreIndexedAsksOnce() async throws {
        let url = try fixture("SmartTrim-GOP", "mp4")
        let end = try CutEngine(useSidecar: false).inspectMulticamSource(url).duration
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("program.cut")
        try MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: end), angles: [.init(id: "wide", file: url.path)],
                            audio: .none, switches: [.init(at: .zero, angle: "wide")], assembly: nil).save(to: file)
        let model = MulticamEditorModel(preferences: EditorPreferences(), draft: ProjectDraft(directory: folder.appendingPathComponent("Drafts")))
        defer { model.reset() }
        model.useAnalysisSidecars = false
        let asked = Asked()
        asked.answer = .init(answer: .cancel)
        model.tierGate.ask = { prompt, answer in
            asked.prompts.append(prompt)
            answer(asked.answer)
        }
        model.openProject(file)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.project == nil || model.isBusy, .now < deadline { await Task.yield() }
        let opened = try XCTUnwrap(model.project)
        XCTAssertNil(model.settledTier, "The first tier has not arrived.")
        let indexedBefore = model.media["wide"]?.hasFullEditIndex == true
        model.byHand { model.addAssemblyRange(.init(from: inside, to: end)) }
        XCTAssertNotEqual(model.project, opened)
        // Without an index the tier is not being checked, so there is nothing to settle yet.
        while model.media["wide"]?.hasFullEditIndex != true, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1, "Indexed before the edit: \(indexedBefore).")
        XCTAssertEqual(asked.prompts.first?.from, .trueLossless)
        XCTAssertEqual(asked.prompts.first?.to.tier, .lossless)
        XCTAssertEqual(asked.prompts.first?.applied, 1)
        XCTAssertEqual(model.project, opened, "Cancel restores the opened project.")
        XCTAssertEqual(model.settledTier, .trueLossless)
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
    }

    // MARK: The nearest verified times

    /// A camera, and the same recording under another name as a second one.
    @MainActor
    private func twoCameras(in folder: URL) async throws -> (model: MulticamEditorModel, asked: Asked, end: RationalTime) {
        let url = try fixture("SmartTrim-GOP", "mp4")
        let other = folder.appendingPathComponent("close.mp4")
        try FileManager.default.copyItem(at: url, to: other)
        let engine = CutEngine(useSidecar: false)
        let media = try engine.inspectMulticamSource(url)
        let model = MulticamEditorModel()
        model.useAnalysisSidecars = false
        let asked = Asked()
        model.tierGate.ask = { prompt, answer in
            asked.prompts.append(prompt)
            answer(asked.answer)
        }
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: url.path), media: media),
                                    .init(source: .init(id: "close", file: other.path), media: try engine.inspectMulticamSource(other))],
                           opening: "wide", audio: .none)
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        return (model, asked, media.duration)
    }

    /// A range edge inside the second picture group. The keyframe nearest to it starts that group.
    private let late = RationalTime(numerator: 20, denominator: 25)
    private let keyframe = RationalTime(numerator: 1)

    @MainActor
    func testCutAtNearestMovesTheRangeEdgeAndKeepsTheTier() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        asked.answer = .init(answer: .nearest)
        model.byHand { model.addAssemblyRange(.init(from: late, to: end)) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertEqual(prompt.from, .trueLossless)
        XCTAssertEqual(prompt.to.tier, .lossless)
        XCTAssertEqual(prompt.factors.first?.edge, MulticamEdge(range: 1, boundary: "from", at: late))
        XCTAssertEqual(prompt.moves, [.edge(MulticamEdge(range: 1, boundary: "from", at: late), to: keyframe)])
        XCTAssertEqual(prompt.movements, [.init(label: "Range 1 In", requested: late, resolved: keyframe, frameCount: 5, edge: .start)])
        XCTAssertTrue(prompt.message.contains("00:00.800 → 00:01.000 (200 ms later, 5 frames, removes material)"), prompt.message)
        XCTAssertEqual(prompt.title, "Keep the cut here?")
        XCTAssertEqual(prompt.buttons.map(\.title), ["Cut at Nearest Keyframe", "Cut Here", "Cancel"])
        XCTAssertTrue(prompt.message.contains("Move the cut to the nearest keyframe to keep True Lossless."), prompt.message)
        XCTAssertTrue(prompt.message.contains("Verified times near this cut: "), prompt.message)
        // The move is an edit of its own. It raises the tier again and asks nothing.
        XCTAssertEqual(model.project?.assembly, [.init(from: keyframe, to: end)])
        XCTAssertEqual(model.historyActions, ["Add Marked Range", "Move Range Edge"])
        XCTAssertEqual(model.settledTier, .trueLossless)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertNil(model.notice)
        // Undo returns to the cut as it was made, which lowers the tier without a question.
        model.undo()
        try await settle(model)
        XCTAssertEqual(model.project?.assembly, [.init(from: late, to: end)])
        XCTAssertEqual(model.settledTier, .lossless)
        XCTAssertEqual(asked.prompts.count, 1)
    }

    @MainActor
    func testCutAtNearestMovesTheSwitchAndKeepsTheTier() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, asked, _) = try await twoCameras(in: folder)
        defer { model.reset() }
        asked.answer = .init(answer: .nearest)
        let late = late
        model.byHand { model.edit("Add Switch") { $0.switches.append(.init(at: late, angle: "close")) } }
        model.selectedSwitch = late
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertEqual(prompt.to.tier, .lossless)
        XCTAssertEqual(prompt.factors.first?.switchAt, late)
        XCTAssertNil(prompt.factors.first?.edge)
        XCTAssertEqual(prompt.moves, [.switchAt(late, to: keyframe)])
        XCTAssertEqual(prompt.buttons.map(\.title), ["Cut at Nearest Keyframe", "Cut Here", "Cancel"])
        XCTAssertEqual(model.project?.switches.map(\.at), [.zero, keyframe])
        XCTAssertEqual(model.project?.switches.last?.angle, "close")
        XCTAssertEqual(model.selectedSwitch, keyframe)
        XCTAssertEqual(model.historyActions, ["Add Switch", "Move Switch"])
        XCTAssertEqual(model.settledTier, .trueLossless)
        XCTAssertEqual(asked.prompts.count, 1)
    }

    /// Each mode names one cut at a time. Every cut that lowers the tier moves, as the file editor moves every cut.
    @MainActor
    func testCutAtNearestMovesEveryCutThatLowersTheTier() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        asked.answer = .init(answer: .nearest)
        let early = RationalTime(numerator: 40, denominator: 25)
        model.byHand { model.addAssemblyRange(.init(from: late, to: early)) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertEqual(prompt.moves, [.edge(MulticamEdge(range: 1, boundary: "from", at: late), to: keyframe),
                                      .edge(MulticamEdge(range: 1, boundary: "to", at: early), to: end)])
        XCTAssertTrue(prompt.message.contains("Move the cuts to the nearest keyframe to keep True Lossless."), prompt.message)
        XCTAssertEqual(model.project?.assembly, [.init(from: keyframe, to: end)])
        XCTAssertEqual(model.historyActions, ["Add Marked Range", "Move Cuts to Verified Times"])
        XCTAssertEqual(model.settledTier, .trueLossless)
        XCTAssertEqual(asked.prompts.count, 1)
    }

    /// Moving the cut back to where it was is what Cancel does. It is not offered as a third choice.
    @MainActor
    func testCutAtNearestIsNotOfferedWhenItWouldUndoTheEdit() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        model.addAssemblyRange(.init(from: keyframe, to: end))
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        model.byHand { model.changeOccurrence(0, from: late) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertEqual(prompt.factors.first?.nearest?.contains(keyframe), true)
        XCTAssertNil(prompt.moves)
        XCTAssertEqual(prompt.buttons.map(\.title), ["Continue", "Cancel"])
        XCTAssertEqual(prompt.title, "Change export quality from True Lossless to Lossless?")
    }

    /// A split inside a picture group makes two ranges that are joined at the cut. They plan as one range, so the
    /// tier stays and no edge of the seam is offered a move of its own.
    @MainActor
    func testASplitInsideAPictureGroupKeepsTheTierAndAsksNothing() async throws {
        let (model, asked, end) = try await editor()
        defer { model.reset() }
        let late = late
        model.byHand { model.edit("Split Assembly Range") { $0.assemblyItems = [.group(.init(from: .zero, to: late)), .group(.init(from: late, to: end))] } }
        try await settle(model)
        XCTAssertEqual(model.project?.assembly, [.init(from: .zero, to: late), .init(from: late, to: end)])
        XCTAssertEqual(model.settledTier, .trueLossless)
        XCTAssertTrue(asked.prompts.isEmpty)
    }

    /// What a factor is about reaches remote clients and the command line as new keys only.
    @MainActor
    func testFactorsNameTheSwitchOrRangeEdgeAdditively() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _, end) = try await twoCameras(in: folder)
        defer { model.reset() }
        func factor() throws -> [String: Any] {
            let report = try XCTUnwrap(model.tierReport)
            return try XCTUnwrap((report["factors"] as? [[String: Any]])?.first)
        }
        let late = late
        XCTAssertTrue(model.edit { $0.assemblyItems = [.group(.init(from: late, to: end))] })
        try await settle(model)
        var entry = try factor()
        XCTAssertEqual(entry["id"] as? String, "cut_video_start")
        XCTAssertEqual(entry["edge"] as? [String: AnyHashable], ["range_number": 1, "boundary": "from", "group_time": late.description])
        XCTAssertNil(entry["switch_group_time"])
        XCTAssertEqual(Set(entry.keys).subtracting(["id", "message", "forces", "segment", "boundary", "track", "nearest"]), ["edge"])

        XCTAssertTrue(model.edit { $0.assemblyItems = nil; $0.switches.append(.init(at: late, angle: "close")) })
        try await settle(model)
        entry = try factor()
        XCTAssertEqual(entry["switch_group_time"] as? String, late.description)
        XCTAssertNil(entry["edge"])

        // The command line writes the same factors through their coding, with its snake case keys.
        let state = try XCTUnwrap(model.tierState)
        let summary = state.summary(source: .multicam)
        let snake = JSONEncoder()
        snake.keyEncodingStrategy = .convertToSnakeCase
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: snake.encode(summary)) as? [String: Any])
        let coded = try XCTUnwrap((written["factors"] as? [[String: Any]])?.first)
        XCTAssertNotNil(coded["switch_group_time"])
        XCTAssertNil(coded["switchAt"])
        XCTAssertNil(coded["edge"])
        XCTAssertEqual(try JSONDecoder().decode(TierSummary.self, from: JSONEncoder().encode(summary)), summary)
        // A factor written without the new keys still reads, and one that has neither writes neither.
        let plain = try JSONDecoder().decode(TierFactor.self, from: Data(#"{"id":"cut_video_start","message":"m"}"#.utf8))
        XCTAssertNil(plain.switchAt)
        XCTAssertNil(plain.edge)
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        XCTAssertEqual(Set(rewritten.keys), ["id", "message"])
    }

    // MARK: Edits that are committed after their command returned

    @MainActor
    private func writeCard(_ url: URL) throws {
        let rgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(.init(x: 0, y: 0, width: 64, height: 36))
        let image = try XCTUnwrap(context.makeImage())
        let file = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(file, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(file))
    }

    /// A dropped image replaces the marked picture after it is read off the main actor. That commit is by hand. The
    /// remote command that adds the same replacement commits through the same function and is not.
    @MainActor
    func testAStillDroppedByHandAsksAndTheSameStillAddedRemotelyDoesNot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let card = folder.appendingPathComponent("card.png")
        try writeCard(card)
        let url = try fixture("SmartTrim-GOP", "mp4")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        session.isMulticam = true
        let model = session.multicam
        let asked = Asked()
        asked.answer = .init(answer: .cancel)
        model.tierGate.ask = { prompt, answer in
            asked.prompts.append(prompt)
            answer(asked.answer)
        }
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: url.path), media: media)], opening: "wide", audio: .none)
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        let before = try XCTUnwrap(model.project)

        // By hand: the drop returns before the image is read, and the edit follows.
        model.markIn = .zero
        model.markOut = keyframe
        model.dropMulticamStills([card], replacingMarkedRange: true)
        XCTAssertTrue(model.isBusy, model.notice?.message ?? "The image is read off the main actor.")
        XCTAssertEqual(model.project, before)
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1, model.notice?.message ?? "")
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertEqual(prompt.action, "Replace Picture")
        XCTAssertEqual(prompt.from, .trueLossless)
        let lowered = prompt.to.tier
        XCTAssertNotEqual(lowered, .trueLossless)
        XCTAssertEqual(model.project, before, "Cancel undoes the replacement.")
        XCTAssertEqual(model.settledTier, .trueLossless)

        // Remote: the same replacement lowers the tier the same way and asks nothing.
        let result = try await sessions.mcpStills(tool: "still_editor_picture_replace", arguments: [
            "space": "group", "path": card.path, "from": "0", "to": keyframe.description
        ], session: session, checkAccess: {})
        XCTAssertEqual(result?["action"] as? String, "Replace Picture", String(describing: result))
        XCTAssertEqual(model.project?.stillReplacements.count, 1)
        try await settle(model)
        XCTAssertEqual(model.tierState?.tier, lowered)
        XCTAssertEqual(asked.prompts.count, 1)
    }

    /// The soundtrack sheet replaces the program audio inside `byHand`. The remote command calls the same function.
    @MainActor
    func testProgramAudioReplacedByHandAsksAndReplacedRemotelyDoesNot() async throws {
        let url = try fixture("SmartTrim-GOP", "mp4")
        let sound = try fixture("Pause-Noisy", "mov")
        let engine = CutEngine(useSidecar: false)
        let recording = try engine.inspectMulticamSource(sound)
        let stream = try XCTUnwrap(recording.audio.first?.stream.index)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        session.isMulticam = true
        let model = session.multicam
        let asked = Asked()
        asked.answer = .init(answer: .cancel)
        model.tierGate.ask = { prompt, answer in
            asked.prompts.append(prompt)
            answer(asked.answer)
        }
        // The recording starts a third of a second before the group, so the program cuts it between audio samples.
        model.confirmSetup(drafts: [
            .init(source: .init(id: "wide", file: url.path), media: try engine.inspectMulticamSource(url)),
            .init(source: .init(id: "sound", file: sound.path, offset: RationalTime(numerator: -1, denominator: 3), audioStream: stream),
                  media: recording)
        ], opening: "wide", audio: .none)
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)
        let before = try XCTUnwrap(model.project)
        let selection = MulticamAudioSelection(source: "sound", stream: stream)

        // Remote.
        let result = try await sessions.mcpOutputs(tool: "multicam_program_audio_set", arguments: [
            "project_handle": session.mcpHandle, "mode": "replace", "source_id": "sound", "audio_stream_index": stream
        ], session: session, checkAccess: {})
        XCTAssertEqual(result?["action"] as? String, "Replace Program Audio", String(describing: result))
        XCTAssertEqual(model.project?.audio, .fixed(selection))
        try await settle(model)
        XCTAssertEqual(model.settledTier, .reencode)
        XCTAssertTrue(asked.prompts.isEmpty)
        model.undo()
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)

        // By hand, as the Use Soundtrack button of the sheet calls it.
        XCTAssertTrue(model.byHand { model.replaceProgramAudio(with: selection) })
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertEqual(prompt.action, "Replace Program Audio")
        XCTAssertEqual(prompt.from, .trueLossless)
        XCTAssertEqual(prompt.to.tier, .reencode)
        XCTAssertNil(prompt.moves, "No verified time puts the sound back on its samples.")
        XCTAssertEqual(prompt.buttons.map(\.title), ["Continue", "Cancel"])
        XCTAssertEqual(model.project, before)
        XCTAssertEqual(model.settledTier, .trueLossless)
    }
}
