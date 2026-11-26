import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

/// Starting folders, the stills timeline frame rate and the gap color, read from an unpersisted `EditorPreferences`.
@MainActor
final class SettingsFix2PanelTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() async throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        try await super.tearDown()
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsFix2Panel-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mov", subdirectory: "Fixtures"))
    }

    private func same(_ a: URL?, _ b: URL?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a?.resolvingSymlinksInPath().standardizedFileURL.path, b?.resolvingSymlinksInPath().standardizedFileURL.path,
                       file: file, line: line)
    }

    // MARK: Finding 3: no panel opens at a folder made from a relative path, or at the disk root

    func testStartingFolderRefusesARelativeOrRootFolder() throws {
        let automatic = try temporaryFolder()
        let media = try temporaryFolder()
        func resolve(_ mode: ExportStartFolderMode, source: URL? = nil, chosen: URL? = nil, project: URL? = nil) -> URL? {
            ExportStartFolder.resolve(mode: mode, chosenFolder: chosen, projectFile: project, sourceRecording: source,
                                      sessionFolder: nil, automatic: automatic).directory
        }
        // A project-relative file name made into a URL resolves against the working folder, which exists.
        let relative = URL(fileURLWithPath: "camera.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: relative.deletingLastPathComponent().path))
        XCTAssertEqual(resolve(.source, source: relative), automatic, "A relative recording opens at the automatic folder.")
        XCTAssertEqual(resolve(.source, source: URL(fileURLWithPath: "/camera.mov")), automatic, "Never at the disk root.")
        XCTAssertEqual(resolve(.chosen, chosen: URL(fileURLWithPath: "/", isDirectory: true)), automatic)
        XCTAssertEqual(resolve(.project, project: URL(fileURLWithPath: "Interview.cut")), automatic)
        // An absolute recording still starts beside itself, and Automatic is unchanged.
        same(resolve(.source, source: media.appendingPathComponent("camera.mov")), media)
        XCTAssertEqual(resolve(.automatic, source: media.appendingPathComponent("camera.mov")), automatic)
        XCTAssertFalse(ExportStartFolder.isStartingFolder(relative.deletingLastPathComponent()))
        XCTAssertTrue(ExportStartFolder.isStartingFolder(media))
    }

    func testMulticamTranscriptSourceRecordingResolvesAgainstTheProject() throws {
        let folder = try temporaryFolder()
        let preferences = EditorPreferences(defaults: nil)
        preferences.useAnalysisSidecars = false
        let model = MulticamEditorModel(preferences: preferences, draft: ProjectDraft(directory: folder))
        defer { model.reset() }
        let url = try fixture("ProRes-2997")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        // The project names its camera by a path relative to the project document, as a saved project does.
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: "camera.mov"), media: media)], opening: "wide", audio: .none)
        XCTAssertEqual(model.project?.sources.first?.file, "camera.mov")
        let recording = try XCTUnwrap(model.transcriptSourceRecording)
        XCTAssertTrue(recording.relativePath.hasPrefix("/"), "Resolved against the project, not the working folder: \(recording)")
        XCTAssertEqual(recording.lastPathComponent, "camera.mov")
        XCTAssertNotEqual(recording.deletingLastPathComponent().standardizedFileURL.path,
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path)
    }

    // MARK: Finding 6: multicam Resolve and interchange panels share the session folder

    func testMulticamInterchangePanelsShareTheSessionFolderOutsideAutomatic() throws {
        let preferences = EditorPreferences(defaults: nil)
        let model = MulticamEditorModel(preferences: preferences, draft: ProjectDraft(directory: try temporaryFolder()))
        defer { model.reset() }
        let chosen = try temporaryFolder(), picked = try temporaryFolder()
        // Automatic: AppKit's folder, as before, even after a panel chose one.
        XCTAssertNil(model.interchangeStartFolder)
        model.noteExportFolder(picked)
        XCTAssertNil(model.interchangeStartFolder)
        model.exportSessionFolder = nil
        // Chosen folder starts the session; a folder chosen in any panel of the session wins after that.
        preferences.exportStartFolder = .chosen
        preferences.exportStartFolderPath = chosen.path
        same(model.interchangeStartFolder, chosen)
        model.noteExportFolder(picked)
        same(model.interchangeStartFolder, picked)
    }

    // MARK: Finding 7: NTSC rates

    func testStillTimelineNTSCRatesUseTheExactCadence() throws {
        func cadence(_ text: String) throws -> RationalTime? { try StillTimelineFormatDefaults.cadence(frameRate: text) }
        // Factory: 30 fps, as before.
        let factory = StillTimelineFormatDefaults(preferences: EditorPreferences(defaults: nil))
        XCTAssertEqual(factory.frameRateText, "30")
        XCTAssertEqual(try cadence(factory.frameRateText), RationalTime(numerator: 1, denominator: 30))
        // Every NTSC rate the Settings picker offers shows its familiar number and builds the 1001 cadence.
        let preferences = EditorPreferences(defaults: nil)
        for (rate, shown, frames) in [(23.976, "23.976", 24000), (29.97, "29.97", 30000), (59.94, "59.94", 60000),
                                      (119.88, "119.88", 120000)] as [(Double, String, Int64)] {
            preferences.stillTimelineFrameRate = rate
            let text = StillTimelineFormatDefaults(preferences: preferences).frameRateText
            XCTAssertEqual(text, shown)
            XCTAssertEqual(try cadence(text), RationalTime(numerator: 1001, denominator: frames), shown)
            XCTAssertEqual(try cadence(" \(text) "), RationalTime(numerator: 1001, denominator: frames))
        }
        // Other entries are read as written.
        XCTAssertEqual(try cadence("25"), RationalTime(numerator: 1, denominator: 25))
        XCTAssertEqual(try cadence("30000/1001"), RationalTime(numerator: 1001, denominator: 30000))
        XCTAssertEqual(try cadence("29.98"), RationalTime(numerator: 50, denominator: 1499))
        XCTAssertNil(try cadence("0"))
        XCTAssertThrowsError(try cadence("fast"))
    }

    // MARK: Also checked: the gap color survives the color well

    func testEveryGapColorComesBackFromTheColorWellUnchanged() {
        // The panel's own conversion, `StillPanels.rgbHex`, which is private.
        func hex(_ well: NSColorWell) -> String {
            let rgb = well.color.usingColorSpace(.sRGB) ?? .black
            return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                          Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        let well = NSColorWell()
        var checked = 0
        for value in 0...255 {
            for color in [(value, 0, 0), (0, value, 0), (0, 0, value), (value, 255 - value, value / 2)] {
                let original = String(format: "#%02X%02X%02X", color.0, color.1, color.2)
                well.color = StillPanels.startingColor(original)
                XCTAssertEqual(hex(well), original)
                checked += 1
            }
        }
        XCTAssertEqual(checked, 1024)
    }
}
