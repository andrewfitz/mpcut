import Foundation
import XCTest
@testable import MPCutCore

final class ProjectMediaRelinkPathTests: XCTestCase {
    func testRelinkAndPrefixAcceptPhysicalAliasOfOfflineLocation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let physical = folder.appendingPathComponent("Original")
        let redirected = folder.appendingPathComponent("Alias")
        let relocated = folder.appendingPathComponent("Relocated")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: physical)
        try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
        let source = redirected.appendingPathComponent("Image.png")
        let candidate = relocated.appendingPathComponent("Image.png")
        try FileManager.default.copyItem(at: StillAsset.gapImage, to: candidate)
        let fingerprint = try StillImage.fingerprint(candidate)
        let asset = StillAsset(id: "image", file: source.path, displayName: "Image", fingerprint: fingerprint)
        let insert = StillInsert(id: "placement", assetID: asset.id, duration: RationalTime(numerator: 1),
                                 cadence: RationalTime(numerator: 1, denominator: 30))
        let project = CutProject.stillSequence(.init(items: [.still(insert)], stillAssets: [asset],
                                                     stillFormat: .init(width: 128, height: 128, cadence: insert.cadence,
                                                                        codec: .h264, container: "mov")))
        let document = folder.appendingPathComponent("Edit.cut")

        let mappings = ProjectMedia.prefixMappings(project: project, relativeTo: document, from: physical, to: relocated)
        XCTAssertEqual(mappings.count, 1)
        let relinked = try ProjectMedia.relink(project: project, relativeTo: document,
                                             from: physical.appendingPathComponent("Image.png").path, to: candidate)
        XCTAssertEqual(relinked.candidate.outcome, .verified)
        XCTAssertEqual(relinked.project.stillAssets.map(\.file), ["Relocated/Image.png"])
        let row = try XCTUnwrap(ProjectMedia.inventory(project: relinked.project, relativeTo: document,
                                                       snapshot: relinked.snapshot).first)
        XCTAssertEqual(Set(row.uses.map(\.id)), ["image", "placement"])
    }
}
