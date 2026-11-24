import Foundation
import XCTest
@testable import MPCutCore

final class SidecarLocationsTests: XCTestCase {
    private func withFolders(_ test: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("support", isDirectory: true)
        try SidecarLocations.$storageDirectory.withValue(home) { try test(root, home) }
    }

    private func contents(_ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: file)
    }

    func testInspectionLeavesHomeAndProjectUntouched() throws {
        try withFolders { root, home in
            let source = root.appendingPathComponent("clip.mov")
            let project = root.appendingPathComponent("edit.cut")
            try contents(source)
            let options = SidecarLocations(source: source, project: project)
            XCTAssertEqual(options.destination, source.appendingPathExtension("cutdb"))
            XCTAssertTrue(options.candidates.contains(source.appendingPathExtension("cutdb")))
            XCTAssertTrue(SidecarLocations.knownEntries().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("MPCut Cache").path))
        }
    }

    func testReadOnlyObservationsSurviveClosingProjectWithinOneSession() throws {
        try withFolders { root, _ in
            let source = root.appendingPathComponent("recording.mov")
            let project = root.appendingPathComponent("editing/project.cut")
            for file in [source, project] { try contents(file) }
            try SidecarLocations.setMode(.project)
            let saved = try SidecarLocations.$projectURL.withValue(project) {
                let store = try AnalysisSidecar(source: source)
                try store.save(["value": Data([42])])
                return store.url
            }
            let readingHome = root.appendingPathComponent("new-session")
            try SidecarLocations.$storageDirectory.withValue(readingHome) {
                XCTAssertTrue(SidecarLocations.knownEntries().isEmpty)
                try SidecarLocations.$projectURL.withValue(project) {
                    XCTAssertEqual(try AnalysisSidecar(source: source).read("value"), Data([42]))
                }
                // The window is closed. Clear Caches and file-only work can now
                // find this project copy using only the read-only observation.
                XCTAssertEqual(SidecarLocations.knownEntries().map(\.url), [saved])
                XCTAssertEqual(SidecarCacheCleaner.preview().map(\.url), [saved])
                XCTAssertTrue(SidecarLocations(source: source).candidates.contains(saved))
                XCTAssertEqual(try AnalysisSidecar(source: source).read("value"), Data([42]))
                XCTAssertFalse(FileManager.default.fileExists(atPath: readingHome.path))
                SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("unrelated-session")) {
                    XCTAssertTrue(SidecarLocations.knownEntries().isEmpty)
                    XCTAssertFalse(SidecarLocations(source: source).candidates.contains(saved))
                }
                let row = try XCTUnwrap(SidecarLocations.knownEntries().first)
                SidecarLocations.forgetEntry(row)
                XCTAssertTrue(SidecarLocations.knownEntries().isEmpty)
                XCTAssertFalse(SidecarLocations(source: source).candidates.contains(saved))
                XCTAssertFalse(FileManager.default.fileExists(atPath: readingHome.path))
                try SidecarLocations.$projectURL.withValue(project) {
                    XCTAssertEqual(try AnalysisSidecar(source: source).read("value"), Data([42]))
                }
                try Data("replacement".utf8).write(to: saved, options: .atomic)
                XCTAssertTrue(SidecarLocations.knownEntries().isEmpty)
            }
        }
    }

    func testSessionObservationReportsDisconnectedDiskAndResumesAfterReconnect() throws {
        try withFolders { root, _ in
            let source = root.appendingPathComponent("clip.mov")
            let disk = root.appendingPathComponent("external", isDirectory: true)
            let other = root.appendingPathComponent("new-cache", isDirectory: true)
            let disconnected = root.appendingPathComponent("unmounted", isDirectory: true)
            try contents(source)
            for folder in [disk, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
            try SidecarLocations.chooseDisk(disk, selecting: true)
            let store = try AnalysisSidecar(source: source)
            try store.save(["test": Data([7])])
            let sidecar = store.url
            let readingHome = root.appendingPathComponent("reading-session")
            try SidecarLocations.$storageDirectory.withValue(readingHome) {
                try SidecarLocations.chooseDisk(disk)
                XCTAssertEqual(try AnalysisSidecar(source: source).read("test"), Data([7]))
                try SidecarLocations.chooseDisk(other)
                try FileManager.default.moveItem(at: disk, to: disconnected)
                XCTAssertFalse(SidecarLocations(source: source).candidates.contains(sidecar))
                let skipped = try XCTUnwrap(SidecarCacheCleaner.preview().first { $0.url == sidecar })
                XCTAssertNotNil(skipped.issue)
                XCTAssertTrue(SidecarCacheCleaner.clear([skipped], wholeSidecars: true).cleared.isEmpty)
                try FileManager.default.moveItem(at: disconnected, to: disk)
                XCTAssertTrue(SidecarLocations(source: source).candidates.contains(sidecar))
                XCTAssertEqual(try AnalysisSidecar(source: source).read("test"), Data([7]))
                XCTAssertFalse(FileManager.default.fileExists(atPath: readingHome.appendingPathComponent("locations.sqlite").path))
                try FileManager.default.removeItem(at: sidecar)
                XCTAssertTrue(SidecarLocations.knownEntries().isEmpty)
            }
        }
    }

    func testRejectedReadNeverAddsLegacyCompanionToSessionCatalog() throws {
        try withFolders { root, home in
            let source = root.appendingPathComponent("recording.mov")
            try contents(source)
            let adjacent = source.appendingPathExtension("cutdb")
            try Data("ordinary file".utf8).write(to: adjacent)
            XCTAssertNil(try AnalysisSidecar(source: source).read("value"))
            XCTAssertTrue(SidecarLocations.knownEntries().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        }
    }

    func testDamagedSettingsRequireExplicitReselection() throws {
        try withFolders { root, home in
            let source = root.appendingPathComponent("recording.mov")
            try contents(source)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data("damaged".utf8).write(to: home.appendingPathComponent("config.json"))
            let invalid = SidecarLocations(source: source)
            XCTAssertNil(invalid.destination)
            XCTAssertThrowsError(try invalid.checkWriteConfiguration())
            XCTAssertThrowsError(try invalid.prepareDestination())
            XCTAssertTrue(invalid.candidates.contains(source.appendingPathExtension("cutdb")))
            try SidecarLocations.setMode(.media)
            XCTAssertEqual(try SidecarLocations(source: source).prepareDestination(), source.appendingPathExtension("cutdb"))
        }
    }

    func testCollisionsAliasesAndProjectMove() throws {
        try withFolders { root, _ in
            let first = root.appendingPathComponent("tree/media/first/clip.mov")
            let second = root.appendingPathComponent("tree/media/second/clip.mov")
            let alias = root.appendingPathComponent("alias.mov")
            let project = root.appendingPathComponent("tree/edits/project.cut")
            for file in [first, second, project] { try contents(file) }
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
            try SidecarLocations.setMode(.project)
            let lhs = SidecarLocations(source: first, project: project)
            let rhs = SidecarLocations(source: second, project: project)
            let target = try lhs.prepareDestination()
            XCTAssertNotEqual(target, rhs.destination)
            XCTAssertEqual(target, SidecarLocations(source: alias, project: project).destination)
            XCTAssertNil(SidecarLocations(source: first).destination)
            XCTAssertThrowsError(try SidecarLocations(source: first).prepareDestination())
            try FileManager.default.moveItem(at: root.appendingPathComponent("tree"), to: root.appendingPathComponent("moved"))
            let moved = SidecarLocations(source: root.appendingPathComponent("moved/media/first/clip.mov"),
                                         project: root.appendingPathComponent("moved/edits/project.cut"))
            XCTAssertEqual(moved.destination?.lastPathComponent, target.lastPathComponent)
        }
    }

    func testDirectoryAliasesKeepFirstPathButFileAliasesHaveIndependentSidecars() throws {
        try withFolders { root, _ in
            let source = root.appendingPathComponent("physical/clip.mov")
            try contents(source)
            let directoryAlias = root.appendingPathComponent("folder-link")
            try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: source.deletingLastPathComponent())
            let throughDirectory = directoryAlias.appendingPathComponent("clip.mov")
            let directoryLocation = SidecarLocations(source: throughDirectory)
            XCTAssertEqual(directoryLocation.candidates, [throughDirectory.appendingPathExtension("cutdb")])
            XCTAssertEqual(directoryLocation.candidateEntries.map(\.url), directoryLocation.candidates)
            let fileAlias = directoryAlias.appendingPathComponent("other-name.mov")
            try FileManager.default.createSymbolicLink(at: fileAlias, withDestinationURL: source)
            let throughFile = SidecarLocations(source: fileAlias)
            XCTAssertEqual(throughFile.candidates.count, 2)
            XCTAssertEqual(throughFile.candidates.first, fileAlias.appendingPathExtension("cutdb"))
            XCTAssertEqual(throughFile.candidates.last?.lastPathComponent, "clip.mov.cutdb")
            // Exercise the same comparison with actual filesystem entries.
            for url in throughFile.candidates { try Data([1]).write(to: url) }
            XCTAssertEqual(directoryLocation.candidates, [throughDirectory.appendingPathExtension("cutdb")])
            XCTAssertEqual(throughFile.candidates.count, 2)
        }
    }

    func testAllModesDiscoverEachOtherAfterPublication() throws {
        try withFolders { root, _ in
            let source = root.appendingPathComponent("clip.mov")
            let project = root.appendingPathComponent("editing/edit.cut")
            let disk = root.appendingPathComponent("disk", isDirectory: true)
            try contents(source)
            try contents(project)
            try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
            try SidecarLocations.chooseDisk(disk)
            var saved: Set<URL> = []
            for location in SidecarStorageMode.allCases {
                try SidecarLocations.setMode(location)
                let options = SidecarLocations(source: source, project: project)
                let path = try options.prepareDestination()
                saved.insert(path)
                options.registerSaved(path)
            }
            XCTAssertEqual(saved.count, 3)
            XCTAssertEqual(Set(SidecarLocations.knownEntries().map(\.url)), saved)
            for location in SidecarStorageMode.allCases {
                try SidecarLocations.setMode(location)
                let options = SidecarLocations(source: source, project: project)
                XCTAssertEqual(Set(options.candidates), saved)
                XCTAssertEqual(options.candidates.first, options.destination)
            }
            // The standalone invocation still finds the project copy via its registration.
            XCTAssertEqual(Set(SidecarLocations(source: source).candidates), saved)
            SidecarLocations.forget(saved)
            XCTAssertTrue(SidecarLocations.knownEntries().isEmpty)
        }
    }

    func testSameMountPathKeepsEachDiskRegistration() throws {
        try withFolders { root, _ in
            let disk = root.appendingPathComponent("disk")
            let parked = root.appendingPathComponent("parked")
            let source = root.appendingPathComponent("media.mov")
            try contents(source)
            try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
            for _ in 0..<2 {
                try SidecarLocations.chooseDisk(disk, selecting: true)
                let location = SidecarLocations(source: source)
                location.registerSaved(try location.prepareDestination())
                if !FileManager.default.fileExists(atPath: parked.path) {
                    try FileManager.default.moveItem(at: disk, to: parked)
                    try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
                }
            }
            let known = SidecarLocations.knownEntries()
            XCTAssertEqual(known.count, 2)
            XCTAssertEqual(Set(known.map(\.url)).count, 1)
            XCTAssertEqual(Set(known.map(\.rootIdentity)).count, 2)
            let mounted = try XCTUnwrap(known.first(where: SidecarLocations.validate))
            SidecarLocations.forgetEntry(mounted)
            XCTAssertEqual(SidecarLocations.knownEntries().count, 1)
            XCTAssertFalse(try XCTUnwrap(SidecarLocations.knownEntries().first).rootIdentity == mounted.rootIdentity)
        }
    }

    func testMixedProjectContextSelectsFolderForEachRecording() throws {
        try withFolders { root, _ in
            let a = root.appendingPathComponent("first/clip.mov")
            let b = root.appendingPathComponent("second/clip.mov")
            let projectA = root.appendingPathComponent("A/p.cut")
            let projectB = root.appendingPathComponent("B/p.cut")
            for url in [a, b, projectA, projectB] { try contents(url) }
            try SidecarLocations.setMode(.project)
            let map = [SidecarLocations.sourceKey(a): projectA, SidecarLocations.sourceKey(b): projectB]
            try SidecarLocations.$projectsBySource.withValue(map) {
                XCTAssertEqual(SidecarLocations(source: a).destination, SidecarLocations(source: a, project: projectA).destination)
                XCTAssertEqual(SidecarLocations(source: b).destination, SidecarLocations(source: b, project: projectB).destination)
                XCTAssertNotEqual(try SidecarLocations(source: a).prepareDestination(), SidecarLocations(source: a, project: projectB).destination)
            }
        }
    }

    func testChangedDiskAndManagedSymlinksStayUnavailable() throws {
        try withFolders { root, _ in
            let disk = root.appendingPathComponent("disk", isDirectory: true)
            let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
            for directory in [disk, elsewhere] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            let source = root.appendingPathComponent("clip.mov")
            try contents(source)
            try SidecarLocations.chooseDisk(disk)
            try SidecarLocations.setMode(.disk)
            let location = SidecarLocations(source: source)
            let original = try location.prepareDestination()
            location.registerSaved(original)
            let row = try XCTUnwrap(SidecarLocations.knownEntries().first)
            XCTAssertTrue(SidecarLocations.validate(row))
            let unmounted = root.appendingPathComponent("unmounted")
            try FileManager.default.moveItem(at: disk, to: unmounted)
            try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
            XCTAssertFalse(SidecarLocations.diskAvailable)
            XCTAssertNil(location.destination)
            XCTAssertFalse(SidecarLocations.validate(row))
            XCTAssertThrowsError(try location.prepareDestination())
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: disk.path).isEmpty)
            try FileManager.default.removeItem(at: disk)
            try FileManager.default.moveItem(at: unmounted, to: disk)
            XCTAssertTrue(SidecarLocations.diskAvailable)
            XCTAssertTrue(SidecarLocations(source: source).candidates.contains(original))
            let managed = disk.appendingPathComponent("MPCut Cache")
            try FileManager.default.moveItem(at: managed, to: root.appendingPathComponent("old"))
            try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: elsewhere)
            XCTAssertThrowsError(try location.prepareDestination())
            XCTAssertFalse(SidecarLocations.validate(row))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        }
    }
}
