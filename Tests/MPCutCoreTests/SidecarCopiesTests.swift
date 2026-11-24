import SQLite3
import Foundation
import XCTest
@testable import MPCutCore

final class SidecarCopiesTests: XCTestCase {
    private func withCopies(_ run: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project/test.cut")
        let disk = root.appendingPathComponent("disk")
        for folder in [disk, project.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let source = root.appendingPathComponent("recording.mov")
        try Data([0, 1]).write(to: source)
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("home")) {
            try SidecarLocations.chooseDisk(disk)
            try SidecarLocations.$projectURL.withValue(project) {
                try run(source, project, disk)
            }
        }
    }

    func testRefreshFindsIntactEvidenceAfterNewerCopiesAreDamaged() throws {
        try withCopies { source, _, _ in
            try SidecarLocations.setMode(.media)
            let media = try inspectFixture(at: source)
            let adjacent = AnalysisSidecar(media: media)
            let evidence = try XCTUnwrap(media.refreshEvidence).encoded()
            try adjacent.save([AnalysisSidecar.evidenceKey: evidence])
            try SidecarLocations.setMode(.project)
            let project = try AnalysisSidecar(source: source)
            try project.save(["thumbnail": Data([1])])
            let db = try SidecarDatabase(project.url, writing: true)
            try db.update("UPDATE sections SET digest = zeroblob(32) WHERE name = ?", [AnalysisSidecar.evidenceKey])
            try db.update("UPDATE sidecar_changes SET changed = changed + 60 WHERE name = ?", [AnalysisSidecar.evidenceKey])
            let current = project.currentGenerationEvidence()
            XCTAssertTrue(current.current)
            XCTAssertEqual(current.evidence, evidence)
        }
    }

    func testEqualAnalysisSavesLeaveDatabaseAndReplicaCookiesUntouchedAcrossLocations() throws {
        try withCopies { source, _, _ in
            let blocks = ["media_index_frames.v1": Data(repeating: 2, count: 131072),
                          "media_index_audio.v1": Data(repeating: 3, count: 65536),
                          "media_index.v1": Data([4])]
            let adjacent = try AnalysisSidecar(source: source)
            try adjacent.save(blocks)
            try SidecarLocations.setMode(.project)
            let project = try AnalysisSidecar(source: source)
            try project.save(blocks)
            let copies = [adjacent, project]
            func cookies() throws -> [String] {
                try copies.map { store in
                    let db = try SidecarDatabase(store.url, writing: false)
                    return try XCTUnwrap(db.replicaCookie(generation: store.generation(db))).version
                }
            }
            let before = try cookies()
            let files = try copies.map { try Data(contentsOf: $0.url) }
            for _ in 0..<3 {
                for copy in copies {
                    try copy.save(blocks)
                    try copy.save([:], updating: ["media_index.v1": { try XCTUnwrap($0) }],
                                  retainingLatest: ["timeline_filmstrip.v1.": 2])
                }
            }
            XCTAssertEqual(try cookies(), before)
            XCTAssertEqual(try copies.map { try Data(contentsOf: $0.url) }, files)
            // A real write in the other copy must invalidate the remembered comparison.
            try adjacent.save(["index-extension": Data([8])])
            try project.save(blocks)
            XCTAssertEqual(project.pinned(to: project.url).read("index-extension"), Data([8]))
        }
    }

    func testEveryWriteModeDiscoversEveryOtherModeAndSeedsMissingSections() throws {
        try withCopies { source, _, _ in
            for (i, oldMode) in SidecarStorageMode.allCases.enumerated() {
                for (j, nextMode) in SidecarStorageMode.allCases.enumerated() {
                    let media = source.deletingLastPathComponent().appendingPathComponent("sample-\(i)-\(j).mov")
                    try Data([UInt8(i), UInt8(j)]).write(to: media)
                    try SidecarLocations.setMode(oldMode)
                    let old = try AnalysisSidecar(source: media)
                    try old.save(["only.old": Data([1]), "shared": Data([1])])
                    try SidecarLocations.setMode(nextMode)
                    let next = try AnalysisSidecar(source: media)
                    XCTAssertEqual(next.read("only.old"), Data([1]))
                    XCTAssertEqual(AnalysisSidecar.inventorySnapshot(source: media).location, old.url)
                    if oldMode != nextMode { XCTAssertFalse(FileManager.default.fileExists(atPath: next.url.path)) }
                    try next.save(["shared": Data([2]), "only.new": Data([2])])
                    XCTAssertEqual(next.pinned(to: next.url).read("only.old"), Data([1]))
                    XCTAssertEqual(old.read("shared"), Data([2]))
                    XCTAssertEqual(old.read("only.new"), Data([2]))
                }
            }
        }
    }

    func testReplacingCacheDiskDuringSaveCannotRedirectPublication() throws {
        try withCopies { source, _, disk in
            try SidecarLocations.setMode(.disk)
            let store = try AnalysisSidecar(source: source)
            let displaced = disk.deletingLastPathComponent().appendingPathComponent("disconnected")
            XCTAssertThrowsError(try store.save([:], updating: ["value": { _ in
                try FileManager.default.moveItem(at: disk, to: displaced)
                try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
                return Data([9])
            }]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathExtension("cutdb").path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: disk.path), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        }
    }

    func testIncompleteOrCorruptIndexFallsBackAsAGroup() throws {
        try withCopies { source, _, _ in
            let old = try AnalysisSidecar(source: source)
            let header = "media_index.v1", frames = "media_index_frames.v1", audio = "media_index_audio.v1"
            try old.save([header: Data([1]), frames: Data([1]), audio: Data([1])])
            try SidecarLocations.setMode(.project)
            let newer = try AnalysisSidecar(source: source)
            try newer.save([header: Data([2]), frames: Data([2]), audio: Data([2])])
            let db = try SidecarDatabase(newer.url, writing: true)
            try db.update("UPDATE sections SET value = zeroblob(1) WHERE name = ?", [audio])
            func load(_ store: AnalysisSidecar) throws -> [Data]? {
                try store.withReadSnapshot(orderedBy: header, cancelled: { false }) { read in
                    guard let h = read(header), let f = read(frames), let a = read(audio) else { return nil }
                    return [h, f, a]
                }
            }
            XCTAssertEqual(try load(newer), Array(repeating: Data([1]), count: 3))
            try old.save(["fresh.thumb": Data([7])])
            XCTAssertEqual(try load(old.pinned(to: old.url)), Array(repeating: Data([1]), count: 3))
        }
    }

    private func inspectFixture(at source: URL) throws -> MediaInfo {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Pause-Quiet.mov")
        try FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: fixture, to: source)
        return try CutEngine(useSidecar: false).inspect(source, keyframes: true)
    }

    func testSeedingThirdLocationRepairsDamagedNewerDataAndPreservesValidGroupTimestamps() throws {
        for malformed in AnalysisSidecar.indexKeys {
            try withCopies { source, _, _ in
                let media = try inspectFixture(at: source)
                let older = AnalysisSidecar(media: media)
                let k = "local.analysis"
                var valid = try AnalysisSidecar.indexSections(for: media)
                valid[k] = Data([1])
                try older.save(valid)
                try SidecarLocations.setMode(.project)
                let newer = try AnalysisSidecar(source: source)
                // The broken index row passes checksum verification and fails
                // only when parsed with the other two rows as a single archive.
                try newer.save([k: Data([2]), malformed: Data([255])])
                do {
                    let db = try SidecarDatabase(newer.url, writing: true)
                    try db.update("UPDATE sections SET value = ? WHERE name = ?", ["damaged", k])
                }
                XCTAssertNil(try newer.pinned(to: newer.url).loadIndex(detail: .full, cancelled: { false }))
                try older.save(["other": Data([3])])
                XCTAssertEqual(try older.pinned(to: older.url).loadIndex(detail: .full, cancelled: { false })?.frames.count,
                               media.frames.count)
                try newer.pinned(to: newer.url).save(["latest": Data([4])])
                func clocks(_ store: AnalysisSidecar) throws -> [Double] {
                    let db = try SidecarDatabase(store.url, writing: false)
                    return try AnalysisSidecar.indexKeys.union([k]).sorted().map { key in
                        try db.statement("SELECT changed FROM sidecar_changes WHERE name = ?", [key]) { q in
                            guard sqlite3_step(q) == SQLITE_ROW else { throw db.error() }
                            return sqlite3_column_double(q, 0)
                        }
                    }
                }
                let expected = try clocks(older)
                try SidecarLocations.setMode(.disk)
                let disk = try AnalysisSidecar(source: source)
                try disk.save(["new": Data([5])])
                try FileManager.default.removeItem(at: older.url)
                try FileManager.default.removeItem(at: newer.url)
                for key in AnalysisSidecar.indexKeys.union([k]) { XCTAssertEqual(disk.read(key), valid[key], key) }
                XCTAssertEqual(try disk.loadIndex(detail: .full, cancelled: { false })?.frames.count, media.frames.count)
                XCTAssertEqual(try clocks(disk), expected)
            }
        }
    }

    func testTypedAnalysisRejectsInvalidNewerValuesAndIncompatibleClocks() throws {
        try withCopies { source, _, _ in
            let media = try inspectFixture(at: source)
            let stream = try XCTUnwrap(media.audio.first?.stream.index)
            let wave = try AudioAnalysis.scan(media, stream: stream, useSidecar: false)
            let envelope = try AudioAnalysis.envelope(media, stream: stream, from: 0, to: media.duration.seconds,
                                                       columns: 16, useSidecar: false)
            let silence = try AudioAnalysis.silence(media, stream: stream, minimum: 0.3, waveform: wave, useSidecar: false)
            let report = try SceneAnalysis.scan(media, useSidecar: false)
            let old = AnalysisSidecar(media: media)
            var values = try AnalysisSidecar.sections(media: media, scenes: report, waveforms: [stream: wave],
                                                      envelopeOverviews: [stream: envelope], silence: [silence])
            values[AnalysisSidecar.sceneClockKey] = try XCTUnwrap(AnalysisSidecar.encodeSceneClock(media))
            var initial = values
            initial[AnalysisSidecar.evidenceKey] = try XCTUnwrap(media.refreshEvidence).encoded()
            try old.save(initial)
            try SidecarLocations.setMode(.disk)
            let disk = try AnalysisSidecar(source: source)
            try disk.save(["warm": Data([1])])
            var bad: [String: Data] = [:]
            for (key, data) in values {
                if key == AnalysisSidecar.sceneSectionKey {
                    var scene = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    scene["duration"] = ["numerator": 9000, "denominator": 1]
                    bad[key] = try JSONSerialization.data(withJSONObject: scene)
                    continue
                }
                var row = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
                if key == AnalysisSidecar.sceneClockKey { row["changed_seconds"] = -1 }
                if key.hasPrefix("waveform_peaks") { row["value"] = Data(repeating: 255, count: 4) }
                if key.hasPrefix("waveform_envelope") {
                    var clock = try XCTUnwrap(row["clock"] as? [String: Any])
                    clock["origin"] = ["numerator": 9, "denominator": 1]
                    row["clock"] = clock
                }
                if key.hasPrefix("silence_automatic_threshold") { row["value"] = 1000.0 }
                if key.hasPrefix("silence_pauses") {
                    var settings = try XCTUnwrap(row["value"] as? [String: Any])
                    settings["silence_min_pause_seconds"] = 0.4
                    row["value"] = settings
                }
                bad[key] = try PropertyListSerialization.data(fromPropertyList: row, format: .binary, options: 0)
            }
            try disk.pinned(to: disk.url).save(bad)
            XCTAssertNil(disk.pinned(to: disk.url).waveform(for: media, stream: stream))
            XCTAssertEqual(disk.waveform(for: media, stream: stream)?.count, wave.count)
            XCTAssertEqual(disk.automaticThresholdDB(for: media, stream: stream), silence.automaticThresholdDB)
            XCTAssertEqual(disk.silence(for: media, stream: stream, thresholdDB: nil, minimum: 0.3)?.pauses, silence.pauses)
            XCTAssertEqual(disk.envelopeOverview(for: media, stream: stream)?.low, envelope.low)
            XCTAssertEqual(disk.sceneReport(for: media)?.duration, media.duration)
            XCTAssertEqual(disk.loadSceneClock(cancelled: { false })?.duration, media.duration)
            // Reconcile back into the valid location, then disconnect the bad
            // replica. A metadata save must not propagate the bad typed values.
            try old.save(["other": Data([1])])
            try disk.pinned(to: disk.url).save(["newer": Data([2])])
            try SidecarLocations.setMode(.project)
            let project = try AnalysisSidecar(source: source)
            try project.save(["seeded": Data([3])])
            try FileManager.default.removeItem(at: disk.url)
            func assertUsable(_ copy: AnalysisSidecar, line: UInt = #line) {
                XCTAssertEqual(copy.waveform(for: media, stream: stream)?.count, wave.count, line: line)
                XCTAssertEqual(copy.silence(for: media, stream: stream, thresholdDB: nil, minimum: 0.3)?.pauses, silence.pauses, line: line)
                XCTAssertEqual(copy.automaticThresholdDB(for: media, stream: stream), silence.automaticThresholdDB, line: line)
                XCTAssertEqual(copy.envelopeOverview(for: media, stream: stream)?.low, envelope.low, line: line)
                XCTAssertEqual(copy.sceneReport(for: media)?.duration, media.duration, line: line)
                XCTAssertEqual(copy.loadSceneClock(cancelled: { false })?.duration, media.duration, line: line)
            }
            assertUsable(old.pinned(to: old.url))
            try FileManager.default.removeItem(at: old.url)
            assertUsable(project)
        }
    }

    func testIndependentMetadataEditsAndExplicitClearsSurviveCopyReconciliation() throws {
        try withCopies { source, _, _ in
            let old = try AnalysisSidecar(source: source), key = AnalysisSidecar.viewNameSectionKey
            try old.save([key: Data(#"{"1":"A","2":"B","3":"C"}"#.utf8)])
            try SidecarLocations.setMode(.project)
            let project = try AnalysisSidecar(source: source)
            try project.save(["warm": Data([1])])
            try old.pinned(to: old.url).save([key: Data(#"{"1":"Ann","3":"C"}"#.utf8)])
            try project.pinned(to: project.url).save([key: Data(#"{"1":"A","2":"B","3":"Chris"}"#.utf8)])
            let expected = ["1": "Ann", "3": "Chris"]
            func values(_ store: AnalysisSidecar) throws -> [String: String] {
                try JSONDecoder().decode([String: String].self, from: XCTUnwrap(store.read(key)))
            }
            XCTAssertEqual(try values(project), expected)
            try project.save(["another": Data([2])])
            XCTAssertEqual(try values(project.pinned(to: project.url)), expected)
        }
    }

    func testDatabaseFreshnessPrefersTheNewestInheritedTimeUntilAnEditIsRecorded() throws {
        try withCopies { source, _, _ in
            let store = try AnalysisSidecar(source: source)
            try store.save(["old": Data([1]), "new": Data([2])])
            let db = try SidecarDatabase(store.url, writing: true)
            try store.validate(db)
            try db.execute("UPDATE sidecar_changes SET changed = CASE WHEN name = 'old' THEN -100 ELSE -300 END")
            let inherited = try store.changeTime(nil, in: db, at: store.url)
            XCTAssertFalse(inherited.recorded)
            XCTAssertEqual(inherited.time, 300)
            try db.execute("UPDATE sidecar_changes SET changed = 50 WHERE name = 'old'")
            let edited = try store.changeTime(nil, in: db, at: store.url)
            XCTAssertTrue(edited.recorded)
            XCTAssertEqual(edited.time, 50)
        }
    }

    func testClearInNewLocationWinsOverTouchedLegacyFileAndIdenticalSaves() throws {
        try withCopies { source, _, _ in
            let old = try AnalysisSidecar(source: source), k = AnalysisSidecar.viewNameSectionKey
            try old.save([k: Data(#"{"1":"Guest"}"#.utf8)])
            let oldDB = try SidecarDatabase(old.url, writing: true)
            try oldDB.execute("PRAGMA user_version = 4")
            try SidecarLocations.setMode(.disk)
            let next = try AnalysisSidecar(source: source)
            try next.save([k: Data("{}".utf8)])
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(86_400)], ofItemAtPath: old.url.path)
            XCTAssertEqual(old.read(k), Data("{}".utf8))
            let db = try SidecarDatabase(next.url, writing: true)
            func version() throws -> Double {
                try db.statement("SELECT changed FROM sidecar_changes WHERE name = ?", [k]) { row in
                    guard sqlite3_step(row) == SQLITE_ROW else { throw db.error() }
                    return sqlite3_column_double(row, 0)
                }
            }
            let before = try version()
            try next.save([k: Data("{}".utf8)])
            XCTAssertEqual(try version(), before)
        }
    }
}
