import XCTest
@testable import MPCutCore

final class MulticamAssemblySelectionTests: XCTestCase {
    func testSelectionSlicesCardsAndPreservesRepeatedGroupOccurrences() throws {
        let one = RationalTime(numerator: 1)
        let two = RationalTime(numerator: 2)
        let three = RationalTime(numerator: 3)
        let group = MulticamRange(from: .zero, to: one)
        let asset = StillAsset(id: "picture", file: "offline.png", displayName: "Picture", fingerprint: "offline")
        let card = StillInsert(id: "title", assetID: asset.id, duration: one,
                               cadence: .init(numerator: 1, denominator: 24))
        let original = MulticamProject(referenceAngle: "wide", range: group,
                                       angles: [.init(id: "wide", file: "offline.mov")], audio: .none,
                                       switches: [.init(at: .zero, angle: "wide")],
                                       assemblyItems: [.group(group), .still(card), .group(group)],
                                       stillAssets: [asset])
        let sliced = try original.assemblySelection(.init(from: .init(numerator: 1, denominator: 2), to: three))
        XCTAssertEqual(sliced.assemblyItems, [
            .group(.init(from: .init(numerator: 1, denominator: 2), to: one)),
            .still(card),
            .group(group)
        ])
        XCTAssertEqual(try sliced.plan().intervals.map(\.assemblyIndex), [0, 2])
        let partial = try original.assemblySelection(.init(from: .init(numerator: 3, denominator: 2), to: two))
        let selectedCard = try XCTUnwrap(partial.assemblyItems?.first?.still)
        XCTAssertEqual(try selectedCard.frameCount(), 12)
        XCTAssertThrowsError(try original.assemblySelection(.init(from: .init(numerator: 101, denominator: 100), to: two))) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_still_time")
        }
    }
}

