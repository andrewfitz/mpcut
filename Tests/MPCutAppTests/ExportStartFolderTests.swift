import Foundation
import XCTest
@testable import MPCutApp

final class ExportStartFolderTests: XCTestCase {
    private var root: URL!
    private var chosen: URL!
    private var project: URL!
    private var source: URL!
    private var automatic: URL!
    private var session: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-start-\(UUID().uuidString)", isDirectory: true)
        for name in ["chosen", "projects", "recordings", "automatic", "session"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        chosen = root.appendingPathComponent("chosen", isDirectory: true)
        project = root.appendingPathComponent("projects/Edit.cut")
        source = root.appendingPathComponent("recordings/Interview.mov")
        automatic = root.appendingPathComponent("automatic", isDirectory: true)
        session = root.appendingPathComponent("session", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func resolve(_ mode: ExportStartFolderMode, chosen: URL?? = nil, project: URL?? = nil, source: URL?? = nil,
                         session: URL? = nil, automatic: URL?? = nil) -> ExportStartFolder {
        ExportStartFolder.resolve(mode: mode, chosenFolder: chosen ?? self.chosen, projectFile: project ?? self.project,
                                  sourceRecording: source ?? self.source, sessionFolder: session,
                                  automatic: automatic ?? self.automatic)
    }

    func testRawValuesMatchTheKeySchedule() {
        XCTAssertEqual(ExportStartFolderMode.allCases.map(\.rawValue), ["automatic", "project", "source", "chosen"])
    }

    func testEachModeStartsInItsFolder() {
        XCTAssertEqual(resolve(.automatic).directory, automatic)
        XCTAssertEqual(resolve(.project).directory, project.deletingLastPathComponent())
        XCTAssertEqual(resolve(.source).directory, source.deletingLastPathComponent())
        XCTAssertEqual(resolve(.chosen).directory, chosen)
        XCTAssertFalse(resolve(.chosen).chosenFolderUnavailable)
        XCTAssertNil(resolve(.automatic, automatic: .some(nil)).directory)
    }

    func testSessionFolderAlwaysWins() {
        for mode in ExportStartFolderMode.allCases {
            XCTAssertEqual(resolve(mode, session: session).directory, session, mode.rawValue)
        }
        let missing = root.appendingPathComponent("gone")
        let offline = resolve(.chosen, chosen: missing, session: session)
        XCTAssertEqual(offline.directory, session)
        XCTAssertTrue(offline.chosenFolderUnavailable)
    }

    func testMissingChosenFolderFallsBackAndReportsIt() throws {
        try FileManager.default.removeItem(at: chosen)
        let result = resolve(.chosen)
        XCTAssertEqual(result.directory, automatic)
        XCTAssertTrue(result.chosenFolderUnavailable)
        XCTAssertFalse(ExportStartFolder.isAvailable(chosen))

        let file = root.appendingPathComponent("file.txt")
        try Data([1]).write(to: file)
        XCTAssertTrue(resolve(.chosen, chosen: file).chosenFolderUnavailable)
        // No folder saved yet is not an unavailable folder.
        XCTAssertFalse(resolve(.chosen, chosen: .some(nil)).chosenFolderUnavailable)
        XCTAssertEqual(resolve(.chosen, chosen: .some(nil)).directory, automatic)
        // Other modes never mark the chosen folder.
        XCTAssertFalse(resolve(.automatic).chosenFolderUnavailable)
    }

    func testProjectAndSourceFallBackWhenAbsentOrOffline() throws {
        XCTAssertEqual(resolve(.project, project: .some(nil)).directory, automatic)
        XCTAssertEqual(resolve(.source, source: .some(nil)).directory, automatic)
        let offline = root.appendingPathComponent("Volume/Clip.mov")
        XCTAssertEqual(resolve(.source, source: offline).directory, automatic)
        XCTAssertFalse(resolve(.source, source: offline).chosenFolderUnavailable)
    }
}
