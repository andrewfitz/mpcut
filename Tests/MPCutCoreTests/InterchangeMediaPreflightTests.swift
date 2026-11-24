import Foundation
import XCTest
@testable import MPCutCore

final class InterchangeMediaPreflightTests: XCTestCase {
    private let duration = RationalTime(numerator: 1)

    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Shuttle-Chirp.mov").standardizedFileURL
    }

    func testFCPReportsMissingOriginalAndWorkingMediaBeforeWriting() throws {
        try withFolder { folder in
            let location = folder.appendingPathComponent("Edit.cut")
            let output = folder.appendingPathComponent("Edit.fcpxmld")
            let clip = CutSequenceClip(id: "clip", file: "Working.mov", from: .zero, to: duration,
                                       originalFile: "Original.mov")
            let project = CutProject.sequence([clip])
            XCTAssertThrowsError(try ProjectConverter.write(project, relativeTo: location, to: output)) {
                XCTAssertEqual(($0 as? CutError)?.code, "missing_source")
                XCTAssertTrue($0.localizedDescription.contains(folder.appendingPathComponent("Original.mov").path))
                XCTAssertTrue($0.localizedDescription.contains(folder.appendingPathComponent("Working.mov").path))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
            let working = folder.appendingPathComponent("Working.mov")
            let original = folder.appendingPathComponent("Original.mov")
            try FileManager.default.copyItem(at: fixture, to: working)
            try FileManager.default.copyItem(at: fixture, to: original)
            _ = try ProjectConverter.write(project, relativeTo: location, to: output)
            let imported = try FCPInterchange.read(output).0
            XCTAssertEqual(imported.sequenceClips?.first?.file, working.path)
            XCTAssertEqual(imported.sequenceClips?.first?.originalFile, original.path)
        }
    }

    func testFCPChecksPlacedStillFilesAndOmitsUnusedStillFiles() throws {
        try withFolder { folder in
            let location = folder.appendingPathComponent("Edit.cut")
            let output = folder.appendingPathComponent("Edit.fcpxml")
            let camera = try CutEngine(useSidecar: false).inspectSummary(fixture)
            let rate = try XCTUnwrap(camera.videoStream?.frameRate)
            let cadence = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
            let clip = CutSequenceClip(id: "clip", file: fixture.path, from: .zero, to: cadence)
            let used = StillAsset(id: "used", file: "Used.jpg", displayName: "Used", fingerprint: "unverified-fcpxml-used")
            let unused = StillAsset(id: "unused", file: "Unused.jpg", displayName: "Unused", fingerprint: "unverified-fcpxml-unused")
            let insert = StillInsert(id: "insert", assetID: used.id, duration: cadence, cadence: cadence)
            let project = CutProject.stillSequence(.init(items: [.source(clip), .still(insert)], stillAssets: [used, unused]))
            XCTAssertThrowsError(try ProjectConverter.write(project, relativeTo: location, to: output, allowLoss: true)) {
                XCTAssertEqual(($0 as? CutError)?.code, "missing_source")
                XCTAssertTrue($0.localizedDescription.contains("Used.jpg"))
                XCTAssertFalse($0.localizedDescription.contains("Unused.jpg"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testResolveHandoffReportsUnresolvedParentsAndIgnoresStaleIndexesOutsideExport() throws {
        try withFolder { folder in
            let location = folder.appendingPathComponent("Edit.cut")
            let output = folder.appendingPathComponent("Edit.fcpxml")
            let offline = CutSequenceClip(id: "offline", file: "Offline/../Offline.mov", from: .zero, to: duration)
            let online = CutSequenceClip(id: "online", file: fixture.path, from: .zero, to: duration,
                                         originalFile: "Original.mov")
            XCTAssertThrowsError(try ResolveExport.write(.sequence([offline, online]), relativeTo: location, to: output)) {
                XCTAssertEqual(($0 as? CutError)?.code, "missing_source")
                XCTAssertTrue($0.localizedDescription.contains("Offline/../Offline.mov"))
                XCTAssertFalse($0.localizedDescription.contains("Original.mov"))
            }
            let oldSource = folder.appendingPathComponent("Unused.mov")
            try FileManager.default.copyItem(at: fixture, to: oldSource)
            let oldMedia = try CutEngine(useSidecar: false).inspectSummary(oldSource)
            try FileManager.default.removeItem(at: oldSource)
            try ResolveExport.write(.sequence([online]), relativeTo: location, to: output,
                                    useSidecar: false, matching: [oldMedia])
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testPremiereFlattenIgnoresOfflineAlternateAngle() throws {
        try withFolder { folder in
            let location = folder.appendingPathComponent("Edit.cut")
            let output = folder.appendingPathComponent("Edit.xml")
            let group = MulticamProject(referenceAngle: "a", range: .init(from: .zero, to: duration),
                                        angles: [.init(id: "a", file: fixture.path), .init(id: "b", file: "Offline.mov")],
                                        audio: .none, switches: [.init(at: .zero, angle: "a")])
            let resolveOutput = folder.appendingPathComponent("Edit.fcpxml")
            XCTAssertThrowsError(try ResolveExport.write(group, relativeTo: location, to: resolveOutput)) {
                XCTAssertEqual(($0 as? CutError)?.code, "missing_source")
                XCTAssertTrue($0.localizedDescription.contains("Offline.mov"))
            }
            XCTAssertThrowsError(try PremiereTimeline.write(.multicam(group), relativeTo: location, to: output,
                                                            name: "Edit", allowLoss: true)) {
                XCTAssertEqual(($0 as? CutError)?.code, "missing_source")
                XCTAssertTrue($0.localizedDescription.contains("Offline.mov"))
            }
            _ = try PremiereTimeline.write(.multicam(group), relativeTo: location, to: output,
                                           name: "Edit", allowLoss: true, flattenMulticam: true)
            XCTAssertEqual(try PremiereTimeline.nativeAngles(in: output), [])
        }
    }
}
