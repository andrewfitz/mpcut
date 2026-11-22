import Foundation
import XCTest
@testable import MPCutCore

final class ProjectConverterTests: XCTestCase {
    func testCopyRebasesRepeatedMediaAndKeepsOccurrenceOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data([42]).write(to: folder.appendingPathComponent("interview.mov"))
        let input = folder.appendingPathComponent("Edit.cut")
        let output = other.appendingPathComponent("Copy.cut")
        let end = try RationalTime(parsing: "1001/24000")
        let project = CutProject.sequence(["second", "first"].map {
            CutSequenceClip(id: $0, file: "interview.mov", from: .zero, to: end)
        })
        try project.save(to: input)
        XCTAssertEqual(try ProjectConverter.convert(input: input, output: output), [])
        let copy = try CutProject.load(from: output)
        guard case .sequence(let clips) = copy else { return XCTFail("Expected sequence") }
        XCTAssertEqual(clips.map(\.id), ["second", "first"])
        XCTAssertEqual(clips.map(\.to), [end, end])
        XCTAssertEqual(try copy.requests(relativeTo: output).map { $0.file.resolvingSymlinksInPath().standardizedFileURL },
                       try project.requests(relativeTo: input).map { $0.file.resolvingSymlinksInPath().standardizedFileURL })
        let saved = try Data(contentsOf: output)
        XCTAssertThrowsError(try ProjectConverter.convert(input: input, output: output))
        XCTAssertEqual(try Data(contentsOf: output), saved)
    }

    func testCutCopyPreservesRedoOnlyRecordingAndProtectsItsMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sibling = directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("Edit.cut")
        let output = sibling.appendingPathComponent("Copy.cut")
        let missing = directory.appendingPathComponent("offline.cut")
        let future = CutProject.sequence([.init(id: "clip", file: "offline.cut", from: .zero, to: .init(numerator: 1))])
        try CutProject.sequence([]).save(to: input, undo: [], redo: [.init(action: "Add Clip", project: future)])
        XCTAssertThrowsError(try ProjectConverter.convert(input: input, output: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        _ = try ProjectConverter.convert(input: input, output: output)
        let copy = try CutProject.loadDocument(from: output, limit: 5)
        XCTAssertEqual(copy.project, .sequence([]))
        XCTAssertEqual(copy.redo.map(\.action), ["Add Clip"])
        guard case .sequence(let clips)? = copy.redo.first?.project else { return XCTFail("Expected a sequence") }
        XCTAssertEqual(clips.first?.file, "../offline.cut")
    }

    func testExternalConversionProtectsOfflineRecordingAndPackageContentsFromHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("Edit.cut")
        let output = directory.appendingPathComponent("Restorable.fcpxml")
        let package = directory.appendingPathComponent("Restorable.fcpxmld")
        let state = CutProject.sequence([.init(id: "original", file: "Restorable.fcpxml",
                                               from: .zero, to: .init(numerator: 1),
                                               originalFile: "Restorable.fcpxmld/Info.fcpxml")])
        try CutProject.sequence([]).save(to: input, undo: [.init(action: "Remove Recording", project: state)], redo: [])
        for destination in [output, package] {
            XCTAssertThrowsError(try ProjectConverter.convert(input: input, output: destination)) {
                XCTAssertEqual(($0 as? CutError)?.code, "cut_project_source_collision")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testInvalidDestinationFailsBeforeOpeningHostProject() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = directory.appendingPathComponent("Input.drp")
        let output = directory.appendingPathComponent("Output.cut")
        XCTAssertThrowsError(try ProjectConverter.convert(input: input, output: output, allowLoss: true)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_destination")
        }
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/Output.cut"))
        XCTAssertThrowsError(try ProjectConverter.write(.sequence([]), relativeTo: input, to: remote)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_project_path")
        }
    }

    func testConcurrentExportsPublishExactlyOneCompleteProject() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Shared.cut")
        let projects = (1...6).map { index in
            CutProject.sequence([CutSequenceClip(id: String(index), file: "Camera.mov",
                                                 from: .zero, to: .init(numerator: 1))])
        }
        let winners = await withTaskGroup(of: CutProject?.self) { group in
            for project in projects {
                group.addTask {
                    do {
                        _ = try ProjectConverter.write(project, relativeTo: output, to: output)
                        return project
                    } catch { return nil }
                }
            }
            var winners = [CutProject]()
            for await project in group { if let project { winners.append(project) } }
            return winners
        }
        XCTAssertEqual(winners, [try CutProject.load(from: output)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Shared.cut"])
    }

    func testCannotWriteIntoSourceLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fcpbundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("Imported.cut")
        XCTAssertThrowsError(try ProjectConverter.convert(input: directory, output: output)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_destination")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testDanglingOutputSymlinkSurvivesFailedConversion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("Output.cut")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
        XCTAssertThrowsError(try ProjectConverter.convert(input: directory.appendingPathComponent("Missing.cut"), output: link)) {
            XCTAssertEqual(($0 as? CutError)?.code, "destination_exists")
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "missing")
    }
}
