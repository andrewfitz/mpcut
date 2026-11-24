import Foundation
import XCTest
@testable import MPCutCore

final class SidecarRetentionTests: XCTestCase {
    private func makeSidecar() throws -> AnalysisSidecar {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("shot.mov")
        try Data([1, 2, 3]).write(to: source)
        return try AnalysisSidecar(source: source)
    }

    /// The name of a pause list for an automatic threshold, in the property-list layout (1) or the packed one (2).
    private func silence(_ layout: Int, stream: Int, minimum: Double) -> String {
        "silence_pauses.v\(layout).\(stream).auto.\(String(minimum.bitPattern, radix: 16))"
    }

    private func silenceKeys(_ store: AnalysisSidecar, stream: Int) -> Set<String> {
        Set(store.keys().filter { AnalysisSidecar.savedSilenceSettings(forKey: $0)?.stream == stream })
    }

    func testSilenceKeepsTheLatestFourSettingsOfEachStreamInEitherLayout() throws {
        let store = try makeSidecar()
        XCTAssertEqual(AnalysisSidecar.retainedSilenceSettings, 4)
        for layout in [1, 2] {
            XCTAssertEqual(AnalysisSidecar.savedSilenceSettings(forKey: silence(layout, stream: 1, minimum: 0.5))?.minimum, 0.5)
        }
        let other = ["silence_automatic_threshold_db.v1.1": Data([1]), "waveform_peaks.v1.1": Data([2]),
                     "silence_pauses.v3.1.auto.3fe0000000000000": Data([3]), "silence_pauses.v1.1": Data([4])]
        try store.save(other)
        // Six settings on stream 1, in alternating layouts and through both ways of saving.
        let settings = [(1, 0.1), (2, 0.2), (1, 0.3), (2, 0.4), (1, 0.5), (2, 0.6)]
        for (index, (layout, minimum)) in settings.enumerated() {
            let section = [silence(layout, stream: 1, minimum: minimum): Data([UInt8(index)])]
            if index.isMultiple(of: 2) { try store.save(section) } else { store.saveAutomatically(section) }
        }
        try store.save([silence(1, stream: 2, minimum: 0.1): Data([20]), silence(2, stream: 2, minimum: 0.2): Data([21])])
        XCTAssertEqual(silenceKeys(store, stream: 1), [silence(1, stream: 1, minimum: 0.3), silence(2, stream: 1, minimum: 0.4),
                                                      silence(1, stream: 1, minimum: 0.5), silence(2, stream: 1, minimum: 0.6)])
        XCTAssertEqual(silenceKeys(store, stream: 2).count, 2)
        XCTAssertEqual(store.read(silence(1, stream: 1, minimum: 0.3)), Data([2]))
        for (key, value) in other { XCTAssertEqual(store.read(key), value, key) }

        // Saving an unchanged result again is a use. It outlives results saved before that.
        try store.save([silence(1, stream: 1, minimum: 0.3): Data([2])])
        try store.save([silence(2, stream: 1, minimum: 0.7): Data([7])])
        try store.save([silence(1, stream: 1, minimum: 0.8): Data([8])])
        XCTAssertEqual(silenceKeys(store, stream: 1), [silence(1, stream: 1, minimum: 0.3), silence(2, stream: 1, minimum: 0.6),
                                                      silence(2, stream: 1, minimum: 0.7), silence(1, stream: 1, minimum: 0.8)])

        // The two layouts of one setting are one setting, and no other is evicted for it.
        try store.save([silence(2, stream: 1, minimum: 0.8): Data([9])])
        XCTAssertEqual(silenceKeys(store, stream: 1).count, 5)
        XCTAssertTrue(silenceKeys(store, stream: 1).contains(silence(1, stream: 1, minimum: 0.3)))
        try store.save([silence(2, stream: 1, minimum: 0.9): Data([10])])
        XCTAssertEqual(silenceKeys(store, stream: 1), [silence(1, stream: 1, minimum: 0.3), silence(2, stream: 1, minimum: 0.7),
                                                      silence(1, stream: 1, minimum: 0.8), silence(2, stream: 1, minimum: 0.8),
                                                      silence(2, stream: 1, minimum: 0.9)])
        XCTAssertEqual(silenceKeys(store, stream: 2).count, 2)
        for (key, value) in other { XCTAssertEqual(store.read(key), value, key) }
    }

    func testAFileFromBeforeTheLimitIsPrunedByTheNextSilenceSaveAndBeforeArchiving() throws {
        let store = try makeSidecar()
        // Rows as a build without the limit left them: inserted without the write path.
        try store.save(["a": Data([1])])
        func addUnbounded(to sidecar: AnalysisSidecar) throws {
            let db = try SidecarDatabase(sidecar.url, writing: true)
            for stream in [1, 2] {
                for step in 1...9 {
                    let key = silence(1 + step % 2, stream: stream, minimum: Double(step))
                    try db.updateBlobs("INSERT OR REPLACE INTO sections(name, digest, value) VALUES(?, ?, ?)", [key],
                                       blobs: [Data(count: 32), Data([UInt8(step)])])
                }
            }
        }
        try addUnbounded(to: store)
        XCTAssertEqual(silenceKeys(store, stream: 1).count, 9)
        // Any silence result that is saved applies the limit to every stream.
        func expected(_ steps: [Int], stream: Int) -> Set<String> {
            Set(steps.map { silence(1 + $0 % 2, stream: stream, minimum: Double($0)) })
        }
        try store.save([silence(1, stream: 1, minimum: 10): Data([10])])
        XCTAssertEqual(silenceKeys(store, stream: 1), expected([10, 9, 8, 7], stream: 1))
        XCTAssertEqual(silenceKeys(store, stream: 2), expected([9, 8, 7, 6], stream: 2))

        // When the media changes, at most that many go into the archive of the old generation.
        try addUnbounded(to: store)
        try Data([4, 5, 6, 7]).write(to: store.source)
        let fresh = try AnalysisSidecar(source: store.source)
        try fresh.save(["b": Data([2])])
        let db = try SidecarDatabase(fresh.url, writing: false)
        for layout in [1, 2] {
            XCTAssertEqual(try db.integer("SELECT count(*) FROM archived_sections WHERE name GLOB 'silence_pauses.v\(layout).*'"), 4)
        }
        for stream in [1, 2] {
            XCTAssertEqual(try db.integer("SELECT count(*) FROM archived_sections WHERE name GLOB 'silence_pauses.v?.\(stream).*'"), 4)
        }
        XCTAssertEqual(fresh.keys(), ["b"])
    }

    func testFilmstripTilesKeepToAByteBudgetOldestFirst() throws {
        let store = try makeSidecar()
        let prefix = AnalysisSidecar.filmstripSectionPrefix
        XCTAssertEqual(AnalysisSidecar.filmstripByteBudget, 4 * 1024 * 1024)
        // Like a JPEG, random bytes do not compress, so each tile is stored at its full size.
        var generator = SystemRandomNumberGenerator()
        let tile = Data((0..<250_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        func key(_ index: Int) -> String { prefix + String(index, radix: 16) + ".4020.4040" }
        func tiles() -> [Int] {
            store.keys().filter { $0.hasPrefix(prefix) }
                .compactMap { Int($0.dropFirst(prefix.count).prefix { $0 != "." }, radix: 16) }.sorted()
        }
        try store.save(["waveform_peaks.v1.1": tile, "other.1": tile])
        // Sixteen tiles of 250 kB fit in 4 MB. The count limit alone would keep all twenty.
        for batch in [0..<8, 8..<16, 16..<20] {
            try store.saveOrderedCacheEntries(batch.map { (key($0), tile) }, prefix: prefix, keepingLatest: 256, cancelled: { false })
        }
        XCTAssertEqual(tiles(), Array(4..<20))
        let db = try SidecarDatabase(store.url, writing: false)
        XCTAssertLessThanOrEqual(try db.integer("SELECT sum(length(value)) FROM sections WHERE name GLOB 'timeline_filmstrip.*'"),
                                 Int32(AnalysisSidecar.filmstripByteBudget))
        // A tile that is saved again counts as new. The explicit save applies the same budget.
        try store.save([key(4): tile, key(20): tile], retainingLatest: [prefix: 256])
        XCTAssertEqual(tiles(), [4] + Array(6...20))
        store.saveAutomatically([key(21): tile], retainingLatest: [prefix: 256])
        XCTAssertEqual(tiles(), [4] + Array(7...21))
        // The count still applies, and other sections of any size are not part of the budget.
        try store.save([key(22): tile], retainingLatest: [prefix: 2])
        XCTAssertEqual(tiles(), [21, 22])
        XCTAssertEqual(store.read("waveform_peaks.v1.1"), tile)
        XCTAssertEqual(store.read("other.1"), tile)
        for index in 0..<20 { try store.save(["other.\(index)": tile], retainingLatest: ["other.": 256]) }
        XCTAssertEqual(store.keys().filter { $0.hasPrefix("other.") }.count, 20)
    }
}
