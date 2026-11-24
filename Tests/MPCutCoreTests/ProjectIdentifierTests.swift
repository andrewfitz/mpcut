import Foundation
@testable import MPCutCore
import XCTest

final class ProjectIdentifierTests: XCTestCase {
    private struct Scripted: RandomNumberGenerator {
        var values: [UInt64]
        mutating func next() -> UInt64 { values.removeFirst() }
    }

    private let symbols = Set("0123456789abcdefghjkmnpqrstvwxyz")

    /// Every position must be able to hold every symbol, or the ID carries fewer than 60 bits.
    private func assertFullRange(_ make: () -> String, file: StaticString = #filePath, line: UInt = #line) {
        var seen = Array(repeating: Set<Character>(), count: ProjectIdentifier.length)
        for _ in 0..<20_000 {
            let id = make()
            guard id.count == ProjectIdentifier.length else {
                return XCTFail("‘\(id)’ has \(id.count) symbols", file: file, line: line)
            }
            for (position, symbol) in id.enumerated() { seen[position].insert(symbol) }
        }
        for (position, found) in seen.enumerated() {
            XCTAssertEqual(found, symbols, "position \(position)", file: file, line: line)
        }
    }

    func testAnIDIsTwelveSymbolsFromTheAlphabet() {
        XCTAssertEqual(ProjectIdentifier.length, 12)
        XCTAssertEqual(symbols.count, 32)
        XCTAssertEqual(Set(String(decoding: ProjectIdentifier.alphabet, as: UTF8.self)), symbols)
        XCTAssertTrue(symbols.isDisjoint(with: "ilouILOU-_ ./\\\"'"))
        XCTAssertTrue(symbols.allSatisfy { $0.isNumber || $0.isLowercase })
        assertFullRange { ProjectIdentifier.make() }
    }

    func testAMillionIDsAreDistinct() {
        var ids = Set<String>(minimumCapacity: 1_000_000)
        for _ in 0..<1_000_000 { ids.insert(ProjectIdentifier.make()) }
        XCTAssertEqual(ids.count, 1_000_000)
    }

    func testTheLowSixtyBitsChooseTheSymbols() {
        var generator = Scripted(values: [0, 31, 1 << 55, .max, 0xF << 60])
        XCTAssertEqual(ProjectIdentifier.make(using: &generator), "000000000000")
        XCTAssertEqual(ProjectIdentifier.make(using: &generator), "z00000000000")
        XCTAssertEqual(ProjectIdentifier.make(using: &generator), "000000000001")
        XCTAssertEqual(ProjectIdentifier.make(using: &generator), "zzzzzzzzzzzz")
        XCTAssertEqual(ProjectIdentifier.make(using: &generator), "000000000000")
    }

    func testAvoidingDrawsAgainUntilTheIDIsNew() {
        var generator = Scripted(values: [7, 7, 7, 9])
        let first = ProjectIdentifier.make(using: &generator)
        XCTAssertEqual(first, "700000000000")
        XCTAssertEqual(ProjectIdentifier.make(avoiding: ["camera-1", first], using: &generator), "900000000000")
        XCTAssertTrue(generator.values.isEmpty)

        var unopposed = Scripted(values: [7])
        XCTAssertEqual(ProjectIdentifier.make(avoiding: ["camera-1"], using: &unopposed), first)

        let existing = (0..<1_000).map { _ in ProjectIdentifier.make() }
        let added = ProjectIdentifier.make(avoiding: existing)
        XCTAssertEqual(added.count, ProjectIdentifier.length)
        XCTAssertFalse(existing.contains(added))
    }

    func testAUUIDAlwaysYieldsTheSameID() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "01234567-89AB-4CDE-8F01-23456789ABCD"))
        var bits = Scripted(values: [0x0123_4567_89AB_0123])
        XCTAssertEqual(ProjectIdentifier.make(from: uuid), ProjectIdentifier.make(using: &bits))
        XCTAssertEqual(ProjectIdentifier.make(from: uuid), ProjectIdentifier.make(from: uuid))

        // The version and variant are the same in every random UUID, so they must not reach the ID.
        let fixedBitsOnly = try XCTUnwrap(UUID(uuidString: "01234567-89AB-1CDE-BF01-23456789ABCD"))
        XCTAssertEqual(ProjectIdentifier.make(from: fixedBitsOnly), ProjectIdentifier.make(from: uuid))

        assertFullRange { ProjectIdentifier.make(from: UUID()) }
        XCTAssertEqual(Set((0..<100_000).map { _ in ProjectIdentifier.make(from: UUID()) }).count, 100_000)
    }

    func testAProjectAcceptsTheIDsItGenerates() throws {
        let clip = CutSequenceClip(id: "interview", file: "/media/Interview.mov", from: .zero, to: .init(numerator: 8))
        let project = try CutProject.sequence([clip])
            .splittingSequenceClip(id: clip.id, at: .init(numerator: 3))
            .duplicatingSequenceClip(id: clip.id)
        let ids = try XCTUnwrap(project.sequenceClips).map(\.id)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 3)
        for id in ids where id != clip.id {
            XCTAssertEqual(id.count, ProjectIdentifier.length)
            XCTAssertTrue(id.allSatisfy(symbols.contains))
        }
        try project.validate()
    }
}
