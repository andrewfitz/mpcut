import Foundation
import MPCutCore
import XCTest

final class CutProjectTests: XCTestCase {
    func testSequenceRoundTripAndRebase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let out = dir.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("interview.cut")
        let frame = RationalTime(numerator: 1001, denominator: 30000)
        let clip = CutSequenceClip(id: "A", file: "a #1.mov", from: frame, to: .init(numerator: 2),
                                   audioTrack: 1, originalFile: "original.mov", replacementNames: [1: "boom"])
        var repeatClip = clip
        repeatClip.id = "B"
        let project = CutProject.sequence([clip, repeatClip])
        try Data([1, 2]).write(to: dir.appendingPathComponent(clip.file))
        try project.save(to: url)
        XCTAssertEqual(try CutProject.load(from: url), project)
        let requests = try project.requests(relativeTo: url)
        XCTAssertEqual(requests.map(\.file), Array(repeating: dir.appendingPathComponent(clip.file), count: 2))
        XCTAssertEqual(requests.map(\.from), [frame, frame])
        let other = out.appendingPathComponent("copy.cut")
        let rebased = try project.rebased(from: url, to: other)
        guard case .sequence(let clips) = rebased else { return XCTFail("Expected a sequence") }
        XCTAssertEqual(clips.map(\.file), ["../a #1.mov", "../a #1.mov"])
        XCTAssertEqual(clips.map(\.originalFile), ["../original.mov", "../original.mov"])
        XCTAssertEqual(try rebased.requests(relativeTo: other).map { $0.file.resolvingSymlinksInPath() },
                       requests.map { $0.file.resolvingSymlinksInPath() })
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try CutProject.sequence([clip, clip]).save(to: url))
        XCTAssertThrowsError(try project.validateDestination(dir.appendingPathComponent("original.mov"), relativeTo: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testOpeningProjectSymlinkKeepsTargetMediaAndSavingUpdatesTarget() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: directory) }
        let actual = directory.appendingPathComponent("actual", isDirectory: true)
        try fm.createDirectory(at: actual, withIntermediateDirectories: true)
        let url = actual.appendingPathComponent("edit.cut")
        let link = directory.appendingPathComponent("shortcut.cut")
        let media = actual.appendingPathComponent("shot.mov")
        try Data([1]).write(to: media)
        try Data([2]).write(to: directory.appendingPathComponent("shot.mov"))
        let clip = CutSequenceClip(id: "a", file: "shot.mov", from: .zero, to: .init(numerator: 1))
        try CutProject.sequence([clip]).save(to: url)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "actual/edit.cut")

        let read = try CutProject.load(from: link)
        let requests = try read.requests(relativeTo: link)
        XCTAssertEqual(try Data(contentsOf: requests[0].file), Data([1]))
        let copy = directory.appendingPathComponent("copy.cut")
        let rebased = try read.rebased(from: link, to: copy)
        XCTAssertEqual(try Data(contentsOf: rebased.requests(relativeTo: copy)[0].file), Data([1]))

        try CutProject.sequence([]).save(to: link)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "actual/edit.cut")
        XCTAssertEqual(try CutProject.load(from: url), .sequence([]))
    }

    func testOfflineMediaCannotBecomeTheNewProject() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Edit.cut")
        try fm.createSymbolicLink(atPath: directory.appendingPathComponent("offline.mov").path,
                                  withDestinationPath: "Edit.cut")
        var names = ["offline.mov"]
        if try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false {
            names.append("edit.cut")
        }
        for name in names {
            let clip = CutSequenceClip(id: "a", file: name, from: .zero, to: .init(numerator: 1))
            XCTAssertThrowsError(try CutProject.sequence([clip]).save(to: output)) {
                XCTAssertEqual(($0 as? CutError)?.code, "cut_project_source_collision")
            }
            XCTAssertFalse(fm.fileExists(atPath: output.path))
        }
    }

    func testMissingParentTraversalNeverSelectsARecordingBySimplifyingThePath() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("shot.mov"))
        let url = folder.appendingPathComponent("show.cut")
        let clip = CutSequenceClip(id: "a", file: "missing/../shot.mov", from: .zero, to: .init(numerator: 1))
        XCTAssertThrowsError(try CutProject.sequence([clip]).requests(relativeTo: url)) {
            XCTAssertEqual(($0 as? CutError)?.code, "missing_source")
        }
        try fm.createDirectory(at: folder.appendingPathComponent("missing"), withIntermediateDirectories: false)
        let request = try CutProject.sequence([clip]).requests(relativeTo: url)[0]
        XCTAssertEqual(try Data(contentsOf: request.file), Data([1]))
    }

    func testJSONNumbersCannotRoundIntoAnIntegerField() throws {
        func project(_ version: String, track: String) -> Data {
            Data("""
            {"format":"mpcut","schemaVersion":\(version),"kind":"sequence",
             "clips":[{"id":"a","file":"shot.mov","from":"0","to":"1","audioTrack":\(track)}]}
            """.utf8)
        }
        for version in ["1.00000000000000000001", "100000000000000000001e-20"] {
            XCTAssertThrowsError(try CutProject.decode(project(version, track: "0")))
        }
        XCTAssertThrowsError(try CutProject.decode(project("1", track: "1e-1000")))
        XCTAssertNoThrow(try CutProject.decode(project("10e-1", track: "1.00e1")))
    }

    func testRejectsMalformedAndIncompatibleDocuments() throws {
        let header = #""format":"mpcut","schemaVersion":1,"kind":"sequence""#
        let cases = [
            "{\(header),\"clips\":[],\"clips\":[]}",
            "{\(header),\"clips\":[],\"unknown\":true}",
            #"{"schemaVersion":1,"kind":"sequence","clips":[]}"#,
            #"{"schemaVersion":2,"format":"mpcut","kind":"sequence","clips":[]}"#,
            "{\(header),\"clips\":[{\"id\":\"a\",\"file\":\"file\",\"from\":\"1\",\"to\":\"1\"}]}",
        ]
        for document in cases {
            XCTAssertThrowsError(try CutProject.decode(Data(document.utf8)), document)
        }
        XCTAssertEqual(try CutProject.decode(Data("{\(header),\"clips\":[]}".utf8)), .sequence([]))
    }

    func testMulticamEntryPointsUseTheSameDocument() throws {
        let project = MulticamProject(referenceAngle: "cam", range: .init(from: .zero, to: .init(numerator: 10)),
                                      angles: [.init(id: "cam", file: "media/cam.mov")],
                                      audioSources: [.init(id: "mic", file: "media/mic.wav")],
                                      audio: .fixed(.init(source: "mic", stream: 0)),
                                      switches: [.init(at: .zero, angle: "cam")])
        let doc = CutProject.multicam(project)
        XCTAssertEqual(try CutProject.decode(JSONEncoder().encode(project)), doc)
        XCTAssertEqual(try MulticamProject.decode(JSONEncoder().encode(doc)), project)
        let base = URL(fileURLWithPath: "/edits/show.cut")
        let target = URL(fileURLWithPath: "/archive/show.cut")
        guard case .multicam(let copy) = try doc.rebased(from: base, to: target) else {
            return XCTFail("Expected a multicam project")
        }
        XCTAssertEqual(copy.angles.first?.file, "../edits/media/cam.mov")
        XCTAssertEqual(copy.audioSources.first?.file, "../edits/media/mic.wav")
        XCTAssertEqual(copy.audio, project.audio)
        XCTAssertEqual(copy.switches, project.switches)
    }
}
