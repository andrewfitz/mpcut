import ImageIO
import MPCutCore
import XCTest
@testable import MPCutApp

final class StillFrameExportTests: XCTestCase {
    @MainActor
    func testEditorUsesExactCutAndTrimAuditionFrames() async throws {
        let source = try fixture("ProRes-2997")
        let editor = EditorModel()
        editor.useAnalysisSidecars = false
        defer { editor.endSession() }
        editor.importFiles([source])
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(editor.isBusy)
        XCTAssertNil(editor.alert)
        editor.snapTarget = .off
        let frames = try CutEngine(useSidecar: false).inspect(source, keyframes: true).frames
        editor.seek(frames[4].time.seconds.nextDown)
        XCTAssertEqual(editor.jpegSourceAtPlayhead?.frame, frames[3].time)
        editor.seek(frames[4].time.seconds)
        XCTAssertEqual(editor.jpegSourceAtPlayhead?.frame, frames[4].time)

        let id = try XCTUnwrap(editor.timelineClips.first?.id)
        XCTAssertNotNil(editor.trim(id, edge: .end, sourceTime: frames[7].time.seconds, commit: false))
        XCTAssertEqual(editor.jpegSourceAtPlayhead?.frame, frames[6].time)
        editor.cancelTrim()
        XCTAssertEqual(editor.jpegSourceAtPlayhead?.frame, frames[4].time)
        XCTAssertNotNil(editor.trim(id, edge: .start, sourceTime: frames[2].time.seconds, commit: false))
        XCTAssertEqual(editor.jpegSourceAtPlayhead?.frame, frames[2].time)
    }

    @MainActor
    func testWholeSourceJPEGsRemainAvailableBeforeFirstPicture() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Leading-Picture-Gap", withExtension: "avi",
                                                   subdirectory: "Fixtures"))
        let editor = EditorModel()
        editor.useAnalysisSidecars = false
        defer { editor.endSession() }
        editor.importFiles([file])
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(editor.alert)
        let source = try XCTUnwrap(editor.jpegSourceAtPlayhead)
        XCTAssertGreaterThan(try XCTUnwrap(source.media.frames.first?.time), .zero)
        XCTAssertNil(source.frame)
        let options = JPEGExportOptions()
        _ = options.panel(source: file, hasAudio: false, hasPictureAtPlayhead: false)
        XCTAssertEqual(options.mode, .scenes)
        editor.seek(try XCTUnwrap(source.media.frames.first?.time.seconds))
        XCTAssertNotNil(editor.jpegSourceAtPlayhead?.frame)
    }

    func testMulticamProgramCutAndReorderedExclusiveEndUseExactSourceClock() throws {
        let engine = CutEngine(useSidecar: false)
        let source = try fixture("Multicam-Delayed-ProRes")
        let media = try engine.inspectMulticamSource(source)
        let first = try XCTUnwrap(media.frames.first)
        XCTAssertGreaterThan(first.time, .zero)
        let cut = media.frames[2].time
        let end = media.frames[4].time
        let offset = media.frames[1].time
        let switchTime = try cut.adding(offset)
        let groupEnd = try end.adding(offset)
        let project = MulticamProject(referenceAngle: "a", range: .init(from: .zero, to: groupEnd),
            angles: [.init(id: "a", file: source.path), .init(id: "b", file: source.path, offset: offset)],
            audio: .none, switches: [.init(at: .zero, angle: "a"), .init(at: switchTime, angle: "b")])
        let left = MulticamRange(from: first.time, to: switchTime)
        let right = MulticamRange(from: switchTime, to: groupEnd)
        let plan = try project.plan(ranges: [left, right])
        let atCut = try MulticamStillPosition.at(switchTime.subtracting(first.time), in: plan)
        XCTAssertEqual(atCut.angle, "b")
        XCTAssertEqual(atCut.sourceTime, cut)
        XCTAssertFalse(atCut.exclusiveEnd)

        let reordered = try project.plan(ranges: [right, left, right])
        let atEnd = try MulticamStillPosition.at(reordered.duration, in: reordered)
        XCTAssertEqual(atEnd.angle, "b")
        XCTAssertEqual(atEnd.sourceTime, end)
        XCTAssertTrue(atEnd.exclusiveEnd)
        XCTAssertEqual(try JPEGExport.stillFrameTime(in: media, at: atEnd.sourceTime,
                                                    exclusiveEnd: atEnd.exclusiveEnd), media.frames[3].time)
        XCTAssertThrowsError(try JPEGExport.stillFrameTime(in: media, at: .zero)) {
            XCTAssertEqual(($0 as? CutError)?.code, "no_frame")
        }

        let directory = try outputDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("still.jpg")
        try JPEGExport.writeStill(media, at: atEnd.sourceTime, to: output, replacing: nil,
                                  exclusiveEnd: atEnd.exclusiveEnd, cancelled: { false })
        let reference = directory.appendingPathComponent("reference.jpg")
        let ordinary = try engine.inspect(source, keyframes: true)
        try JPEGExport.writeStill(ordinary, at: ordinary.frames[3].time, to: reference)
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: reference))
    }

    func testStillPublishingProtectsExistingFilesAndAllowsConfirmedReplacement() throws {
        let fm = FileManager.default
        let directory = try outputDirectory()
        defer { try? fm.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try fm.copyItem(at: fixture("ProRes-2997"), to: source)
        let media = try CutEngine(useSidecar: false).inspect(source, keyframes: true)
        let output = directory.appendingPathComponent("still.jpg")
        let previous = Data("existing".utf8)
        try previous.write(to: output)
        XCTAssertThrowsError(try JPEGExport.writeStill(media, at: .zero, to: output)) {
            XCTAssertEqual(($0 as? CutError)?.code, "output_exists")
        }
        XCTAssertEqual(try Data(contentsOf: output), previous)
        let stale = try SourceIdentity(output)
        try Data("changed contents".utf8).write(to: output, options: .atomic)
        XCTAssertThrowsError(try JPEGExport.writeStill(media, at: .zero, to: output, replacing: stale,
                                                       cancelled: { false }))
        try JPEGExport.writeStill(media, at: .zero, to: output, replacing: SourceIdentity(output),
                                  cancelled: { false })
        XCTAssertNotNil(CGImageSourceCreateWithURL(output as CFURL, nil))

        let alias = directory.appendingPathComponent("source.jpg")
        try fm.linkItem(at: source, to: alias)
        XCTAssertThrowsError(try JPEGExport.writeStill(media, at: .zero, to: alias, replacing: SourceIdentity(alias),
                                                       cancelled: { false })) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_output")
        }
        XCTAssertEqual(try SourceIdentity(alias), try SourceIdentity(source))
        let cancelled = directory.appendingPathComponent("cancelled.jpg")
        XCTAssertThrowsError(try JPEGExport.writeStill(media, at: .zero, to: cancelled, cancelled: { true })) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
        // Adding a hard link advances ctime on the ProRes source. Acquire a
        // current index before independently racing publication.
        let currentMedia = try CutEngine(useSidecar: false).inspect(source, keyframes: true)
        let concurrent = directory.appendingPathComponent("concurrent.jpg")
        XCTAssertThrowsError(try JPEGExport.writeStill(currentMedia, at: .zero, to: concurrent, cancelled: {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            if contents?.contains(where: { $0.hasPrefix(".mpcut-frame-") }) == true {
                try? previous.write(to: concurrent, options: .withoutOverwriting)
            }
            return false
        })) {
            XCTAssertEqual(($0 as? CutError)?.code, "output_exists")
        }
        XCTAssertEqual(try Data(contentsOf: concurrent), previous)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: directory.path)), ["source.mov", "still.jpg", "source.jpg", "concurrent.jpg"])
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mov", subdirectory: "Fixtures"))
    }

    private func outputDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
