import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamMCPTests: XCTestCase {
    @MainActor
    private func model(in directory: URL) throws -> MulticamEditorModel {
        let preferences = EditorPreferences()
        preferences.historyLimit = 10
        preferences.useAnalysisSidecars = false
        let model = MulticamEditorModel(preferences: preferences, draft: ProjectDraft(directory: directory))
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        let draft = MulticamEditorModel.SourceDraft(source: .init(id: "wide", file: fixture.path), media: media)
        model.confirmSetup(drafts: [draft], opening: "wide", audio: .none)
        return model
    }

    @MainActor
    func testSplitTargetsSecondOccurrenceAndUsesNativeHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        defer { model.reset() }
        let range = try XCTUnwrap(model.project?.range)
        XCTAssertTrue(model.edit("Repeat") { $0.assembly = [range, range] })
        let initialRevision = model.mcpRevision
        let frame = try XCTUnwrap(model.media["wide"]?.frames.dropFirst().first?.time)
        let output = try range.to.adding(frame)
        let reply = try await model.mcpCommand(tool: "split_at", arguments: [
            "space": "assembly", "time": output.description, "occurrence": 1
        ]) {}
        XCTAssertEqual(reply?["groupTime"] as? String, frame.description)
        XCTAssertEqual(reply?["boundary"] as? String, output.description)
        XCTAssertEqual(model.ranges, [range, .init(from: range.from, to: frame), .init(from: frame, to: range.to)])
        XCTAssertEqual(model.historyActions, ["Repeat", "Split Assembly Range"])
        XCTAssertGreaterThan(model.mcpRevision, initialRevision)
        let revisionAfterSplit = model.mcpRevision
        model.undo()
        XCTAssertEqual(model.ranges, [range, range])
        XCTAssertGreaterThan(model.mcpRevision, revisionAfterSplit)
    }

    @MainActor
    func testSeekResolvesAndValidatesRepeatedOccurrence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        defer { model.reset() }
        let range = try XCTUnwrap(model.project?.range)
        let group = try XCTUnwrap(model.media["wide"]?.frames.dropFirst().first?.time)
        XCTAssertTrue(model.edit("Repeat") { $0.assembly = [range, range] })
        let revision = model.mcpRevision
        let expected = try range.to.adding(group)

        let second = try await model.mcpCommand(tool: "seek", arguments: [
            "space": "group", "time": group.description, "occurrence": 1
        ]) {}
        XCTAssertEqual(second?["space"] as? String, "assembly")
        XCTAssertEqual(second?["time"] as? String, expected.description)
        XCTAssertEqual(second?["groupTime"] as? String, group.description)
        XCTAssertEqual(second?["occurrence"] as? Int, 1)

        do {
            _ = try await model.mcpCommand(tool: "seek", arguments: [
                "space": "assembly", "time": range.to.description, "occurrence": 0
            ]) {}
            XCTFail("The join belongs to the next occurrence.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "invalid_target")
        }
        XCTAssertEqual(model.preview.currentTime(), expected)
        XCTAssertEqual(model.selectedOccurrence, 1)

        let join = try await model.mcpCommand(tool: "seek", arguments: [
            "space": "assembly", "time": range.to.description, "occurrence": 1
        ]) {}
        XCTAssertEqual(join?["time"] as? String, range.to.description)
        XCTAssertEqual(join?["groupTime"] as? String, "0")
        XCTAssertEqual(join?["occurrence"] as? Int, 1)
        XCTAssertEqual(model.mcpRevision, revision)
        XCTAssertEqual(model.historyActions, ["Repeat"])
    }

    @MainActor
    func testCameraTimeIsExplicitAndRevisionAdvancesWhenHistoryDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        defer { model.reset() }
        model.preferences.historyLimit = 0
        let time = try XCTUnwrap(model.media["wide"]?.frames.dropFirst().first?.time)
        let revision = model.mcpRevision
        let args: [String: Any] = ["angle": "wide", "time": time.description]
        let reply = try await model.mcpCommand(tool: "set_camera_at", arguments: args) {}
        XCTAssertEqual(reply?["time"] as? String, time.description)
        XCTAssertEqual(reply?["action"] as? String, "Switch Camera")
        XCTAssertEqual(reply?["historyRetained"] as? Bool, false)
        XCTAssertEqual(model.project?.switches.map(\.at), [.zero, time])
        XCTAssertTrue(model.historyActions.isEmpty)
        XCTAssertGreaterThan(model.mcpRevision, revision)
        let current = model.mcpRevision
        let sources = try await model.mcpCommand(tool: "get_multicam", arguments: ["section": "sources"]) {}
        XCTAssertEqual((sources?["sources"] as? [[String: Any]])?.first?["number"] as? Int, 1)
        let again = try await model.mcpCommand(tool: "set_camera_at", arguments: ["number": 1, "time": time.description]) {}
        XCTAssertEqual(again?["changed"] as? Bool, false)
        XCTAssertEqual(model.mcpRevision, current)
    }

    @MainActor
    func testInvalidTargetAndRevocationLeaveProjectUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        defer { model.reset() }
        let original = model.project
        do {
            _ = try await model.mcpCommand(tool: "split_at", arguments: [
                "occurrence": 8, "space": "assembly", "time": "1"
            ]) {}
            XCTFail("Expected invalid occurrence")
        } catch is MCPCommandError {}
        do {
            _ = try await model.mcpCommand(tool: "multicam_source", arguments: [
                "source": "wide", "action": "rename", "name": "new"
            ]) { throw MCPCommandError("disabled", "Disabled by editor.") }
            XCTFail("Expected disabled error")
        } catch is MCPCommandError {}
        XCTAssertEqual(model.project, original)
        XCTAssertTrue(model.historyActions.isEmpty)
    }
    @MainActor
    func testRelinkValidatesAccessAfterReadingAndCommitsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory.appendingPathComponent("Drafts"))
        defer { model.reset() }
        let old = try XCTUnwrap(model.project?.angles.first?.file)
        let replacement = directory.appendingPathComponent("new camera.mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: old), to: replacement)
        let args: [String: Any] = ["source": "wide", "action": "relink", "path": replacement.path]
        var validations = 0
        do {
            _ = try await model.mcpCommand(tool: "multicam_source", arguments: args) {
                validations += 1
                if validations > 1 { throw MCPCommandError("control_disabled", "Control was disabled.") }
            }
            XCTFail("Expected revocation at native commit")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "control_disabled")
        }
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(model.project?.angles.first?.file, old)
        XCTAssertTrue(model.historyActions.isEmpty)
        let changed = try await model.mcpCommand(tool: "multicam_source", arguments: args) {}
        XCTAssertEqual(changed?["changed"] as? Bool, true)
        XCTAssertEqual(changed?["historyRetained"] as? Bool, true)
        XCTAssertEqual(model.project?.angles.first?.file, replacement.path)
        XCTAssertEqual(model.historyActions, ["Relink Source"])
        let generation = model.mcpGeneration
        let revision = model.mcpRevision
        let destination = directory.appendingPathComponent("Relinked.cut")
        try model.writeProject(to: destination)
        XCTAssertEqual(model.mcpGeneration, generation)
        XCTAssertEqual(model.mcpRevision, revision)
        let document = try CutProject.loadEditorDocument(from: destination, limit: 10)
        XCTAssertEqual(document.undo.map(\.action), ["Relink Source"])
        guard case .multicam(let prior)? = document.undo.first?.project else {
            return XCTFail("Expected the original multicam project in persistent history.")
        }
        let originalFile = try XCTUnwrap(prior.angles.first?.file)
        XCTAssertEqual(CutProject.mediaURL(originalFile, relativeTo: destination).path, old)
        model.undo()
        XCTAssertEqual(model.project?.angles.first?.file, old)
        model.redo()
        XCTAssertEqual(model.project?.angles.first?.file, replacement.path)
    }

    @MainActor
    func testHumanChangingMarksInvalidatesSelectionEditWithoutAdvancingRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        defer { model.reset() }
        let frames = try XCTUnwrap(model.media["wide"]?.frames)
        XCTAssertGreaterThan(frames.count, 3)
        let revision = model.mcpRevision
        model.selectGroupRange(frames[1].time, frames[2].time)
        let args: [String: Any] = ["action": "subtract_selection", "space": "group",
                                   "from": try XCTUnwrap(model.markIn).description, "to": try XCTUnwrap(model.markOut).description]
        model.selectGroupRange(frames[2].time, frames[3].time)
        do {
            _ = try await model.mcpCommand(tool: "multicam_assembly", arguments: args) {}
            XCTFail("Expected the changed selection to invalidate the request.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "selection_changed")
        }
        XCTAssertEqual(model.mcpRevision, revision)
        XCTAssertTrue(model.historyActions.isEmpty)
    }

    @MainActor
    func testAssemblyRangeAndTrimPreserveUnsnappedRationalTimes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        defer { model.reset() }
        model.setAnalysisSnap(.off)
        let end = RationalTime(numerator: 2, denominator: 1)
        let start = RationalTime(numerator: 3_000_000_001, denominator: 3_000_000_000)
        XCTAssertTrue(model.edit("Extend Group") { $0.range.to = end })
        let revision = model.mcpRevision
        let select = try await model.mcpCommand(tool: "multicam_select", arguments: [
            "action": "assembly_range", "from": start.description, "to": end.description
        ]) {}
        XCTAssertEqual(select?["markIn"] as? String, start.description)
        XCTAssertEqual(model.assemblySelection?.from, start)
        XCTAssertEqual(model.mcpRevision, revision)

        let preview = try await model.mcpCommand(tool: "multicam_assembly", arguments: [
            "action": "preview_trim", "occurrence": 0, "edge": "start", "time": start.description
        ]) {}
        XCTAssertEqual(preview?["boundary"] as? String, start.description)
        XCTAssertEqual(model.mcpRevision, revision)
        let trim = try await model.mcpCommand(tool: "multicam_assembly", arguments: [
            "action": "trim_edge", "occurrence": 0, "edge": "start", "time": start.description
        ]) {}
        XCTAssertEqual(trim?["boundary"] as? String, start.description)
        XCTAssertEqual(model.ranges, [.init(from: start, to: end)])
        XCTAssertEqual(model.historyActions, ["Extend Group", "Trim Assembly Range"])

        let remove = try await model.mcpCommand(tool: "multicam_assembly", arguments: [
            "action": "remove", "occurrence": 0
        ]) {}
        XCTAssertEqual(remove?["action"] as? String, "Delete Assembly Range")
        XCTAssertNil(model.project?.assembly)
        XCTAssertEqual(model.ranges, [.init(from: .zero, to: end)])
        model.undo()
        XCTAssertEqual(model.ranges, [.init(from: start, to: end)])
    }

    @MainActor
    func testMCPTrimUsesExplicitOccurrenceWithoutOverwritingUndoSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        defer { model.reset() }
        let range = try XCTUnwrap(model.project?.range)
        let frame = try XCTUnwrap(model.media["wide"]?.frames.dropFirst().first?.time)
        XCTAssertTrue(model.edit("Repeat Range") { $0.assembly = [range, range] })
        model.selectedOccurrence = 0
        let trim = try await model.mcpCommand(tool: "multicam_assembly", arguments: [
            "action": "trim", "occurrence": 1, "from": frame.description
        ]) {}
        XCTAssertEqual(trim?["historyRetained"] as? Bool, true)
        XCTAssertEqual(model.ranges, [range, .init(from: frame, to: range.to)])
        XCTAssertEqual(model.selectedOccurrence, 1)
        model.undo()
        XCTAssertEqual(model.ranges, [range, range])
        XCTAssertEqual(model.selectedOccurrence, 0)
    }

    @MainActor
    func testCancellingMCPRelinkStopsTheNativeImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        defer { model.reset() }
        let old = try XCTUnwrap(model.project?.angles.first?.file)
        let replacement = directory.appendingPathComponent("cancelled camera.mov")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: old), to: replacement)
        let revision = model.mcpRevision
        let operation = Task {
            try await model.mcpCommand(tool: "multicam_source", arguments: [
                "source": "wide", "action": "relink", "path": replacement.path
            ]) {}
        }
        for _ in 0..<100 where !model.isBusy { await Task.yield() }
        XCTAssertTrue(model.isBusy)
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Expected the native relink to be cancelled.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "cancelled")
        }
        XCTAssertNil(model.activeNativeOperation)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.mcpRevision, revision)
        XCTAssertEqual(model.project?.angles.first?.file, old)
        XCTAssertTrue(model.historyActions.isEmpty)
    }
}
