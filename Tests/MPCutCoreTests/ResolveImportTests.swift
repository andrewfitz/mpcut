import Foundation
import XCTest
@testable import MPCutCore

final class ResolveImportTests: XCTestCase {
    func testArchiveVerificationDetectsDroppedAudioAndShiftedVideoCuts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let xml = folder.appendingPathComponent("input.fcpxml")
        let report = folder.appendingPathComponent("layout.tsv")
        try """
        <fcpxml><resources><format id="f" frameDuration="1/24s" width="1920" height="1080"/>
        <asset id="r" hasVideo="1" hasAudio="1"/></resources><library><event><project>
        <sequence format="f" duration="1s"><spine><asset-clip ref="r" offset="0s" duration="1s"/>
        </spine></sequence></project></event></library></fcpxml>
        """.write(to: xml, atomically: true, encoding: .utf8)
        let header = "24\t1920\t1080\t24\n"
        for rows in ["video\t0\t24", "video\t1\t24\naudio\t0\t24"] {
            try (header + rows).write(to: report, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try ResolveTimelineGeometry.verify(xml: xml, report: report, allowLoss: true)) {
                XCTAssertEqual(($0 as? CutError)?.code, "resolve_layout_changed")
            }
        }
    }

    func testDirectHandoffReportsAnAlreadyAddedTimelineWhenResolveChangesItsClock() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let xml = folder.appendingPathComponent("input.fcpxml")
        let input = """
        <fcpxml><resources><format id="f" frameDuration="1/7s" width="1920" height="1080"/></resources>
        <library><event><project><sequence format="f" duration="1s"><spine/></sequence></project></event></library></fcpxml>
        """
        try input.write(to: xml, atomically: true, encoding: .utf8)
        let helper = folder.appendingPathComponent("fuscript")
        try """
        #!/bin/sh
        printf '72\\t1920\\t1080\\t7\\n' > "$MPCUT_LAYOUT"
        echo MPCUT_IMPORTED
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        XCTAssertThrowsError(try ResolveExport.importTimeline(xml, helper: helper)) {
            XCTAssertEqual(($0 as? CutError)?.code, "resolve_timeline_unverified")
            XCTAssertTrue($0.localizedDescription.contains("Resolve added the timeline"))
            XCTAssertTrue($0.localizedDescription.contains("72.0 fps"))
        }
        XCTAssertEqual(try String(contentsOf: xml), input)
    }

    func testArchiveExportReportsLostReplacementProvenanceBeforeLaunchingResolve() throws {
        let cut = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).cut")
        let group = CutProject.sequence([CutSequenceClip(id: "abc", file: "remuxed.mov", from: .zero,
                                                         to: .init(numerator: 1), originalFile: "camera.mov")])
        XCTAssertThrowsError(try ResolveNativeInterchange.write(group, relativeTo: cut,
                                                                 to: cut.appendingPathExtension("drp"), allowLoss: false)) {
            XCTAssertEqual(($0 as? CutError)?.code, "conversion_loss")
        }
    }

    func testHandoffCannotImportIntoAnotherConversionsTemporaryResolveProject() throws {
        let url = URL(fileURLWithPath: "/tmp/fixture.fcpxml")
        try ResolveNativeInterchange.withHostLock {
            XCTAssertThrowsError(try ResolveExport.importTimeline(url, helper: URL(fileURLWithPath: "/bin/false"))) {
                XCTAssertEqual(($0 as? CutError)?.code, "resolve_busy")
            }
        }
    }

    func testHandoffRejectsSuccessMarkerInsideDiagnosticText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("fuscript")
        try "#!/bin/sh\necho 'failed to open MPCUT_IMPORTED.mov'\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let xml = folder.appendingPathComponent("file.fcpxml")
        try Data("<fcpxml/>".utf8).write(to: xml)
        XCTAssertThrowsError(try ResolveExport.importTimeline(xml, helper: helper)) {
            XCTAssertEqual(($0 as? CutError)?.code, "resolve_import_failed")
        }
    }

    func testStalledHandoffTimesOutAndReapsHelper() throws {
        try exerciseStalledHandoff(cancel: false)
    }

    func testCancelledHandoffPreservesXMLAndReapsHelper() throws {
        try exerciseStalledHandoff(cancel: true)
    }

    private func exerciseStalledHandoff(cancel: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let xml = directory.appendingPathComponent("Timeline.fcpxml")
        try Data("<fcpxml/>".utf8).write(to: xml)
        let helper = directory.appendingPathComponent("fake-fuscript")
        try "#!/bin/sh\necho $$ > \"$MPCUT_TIMELINE.pid\"\nexec /bin/sleep 30\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let pidFile = xml.appendingPathExtension("pid")

        XCTAssertThrowsError(try ResolveExport.importTimeline(xml, helper: helper, timeout: .seconds(1),
            cancelled: { cancel && FileManager.default.fileExists(atPath: pidFile.path) })) {
            XCTAssertEqual(($0 as? CutError)?.code, cancel ? "cancelled" : "resolve_import_failed")
            XCTAssertTrue($0.localizedDescription.contains(xml.path))
        }
        XCTAssertEqual(try String(contentsOf: xml), "<fcpxml/>")
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        let status = kill(pid, 0)
        let code = errno
        XCTAssertEqual(status, -1)
        XCTAssertEqual(code, ESRCH)
    }

    func testReplacedImportedSourceDoesNotPublishTimeline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Multicam-Delayed-ProRes.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        let imported = try CutEngine(useSidecar: false).inspectSummary(source)
        try Data(contentsOf: fixture).write(to: source, options: .atomic)
        let output = directory.appendingPathComponent("Timeline.fcpxml")
        XCTAssertThrowsError(try ResolveExport.write([ClipRequest(file: source)], to: output,
                                                     useSidecar: false, matching: [imported])) {
            XCTAssertEqual(($0 as? CutError)?.code, "source_changed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testSourceReplacementDuringExportCleansStagingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Multicam-Delayed-ProRes.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        let output = directory.appendingPathComponent("Timeline.fcpxml")
        XCTAssertThrowsError(try ResolveExport.write([ClipRequest(file: source)], to: output, useSidecar: false,
            cancelled: {
                let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
                if files?.contains(where: { $0.hasPrefix(".mpcut-") }) == true {
                    try? Data("replaced".utf8).write(to: source, options: .atomic)
                }
                return false
            })) {
            XCTAssertEqual(($0 as? CutError)?.code, "source_changed")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.mov"])
    }

}
