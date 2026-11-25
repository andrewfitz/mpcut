import Foundation
import XCTest
@testable import MPCutCore

final class ProjectAnalysisAnnotationTests: XCTestCase {
    func testThresholdHistoryAndRecordingContentAcrossRelink() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: folder) }

        let file = folder.appendingPathComponent("room.wav")
        // A mono, one-second, 16 kHz, 16-bit PCM wave.
        var data = Data("RIFF".utf8)
        func integer<T: FixedWidthInteger>(_ number: T) {
            withUnsafeBytes(of: number.littleEndian) { data.append(contentsOf: $0) }
        }
        integer(UInt32(32_036))
        data.append(Data("WAVEfmt ".utf8))
        integer(UInt32(16))
        integer(UInt16(1))
        integer(UInt16(1))
        integer(UInt32(16_000))
        integer(UInt32(32_000))
        integer(UInt16(2))
        integer(UInt16(16))
        data.append(Data("data".utf8))
        integer(UInt32(32_000))
        data.append(Data(repeating: 0, count: 32_000))
        try data.write(to: file)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try files.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let engine = CutEngine(useSidecar: false)
        let original = try engine.inspect(file, keyframes: true)
        let stream = try XCTUnwrap(original.audio.first?.stream.index)
        var project = CutProject.sequence([.init(id: "room", file: file.path, from: .zero, to: original.duration)])
        XCTAssertTrue(project.analysisAnnotations.setThreshold(-37.5, for: original, stream: stream))
        let old = project
        XCTAssertTrue(project.analysisAnnotations.setThreshold(-41.25, for: original, stream: stream))
        let document = folder.appendingPathComponent("test.cut")
        try project.save(to: document, undo: [.init(action: "Set Silence Threshold", project: old)], redo: [])
        let reopened = try CutProject.loadDocument(from: document, limit: 1)
        XCTAssertEqual(reopened.project.analysisAnnotations.threshold(for: original, stream: stream), -41.25)
        XCTAssertEqual(reopened.undo.first?.project.analysisAnnotations.threshold(for: original, stream: stream), -37.5)

        let copy = folder.appendingPathComponent("copied.wav")
        try files.copyItem(at: file, to: copy)
        try files.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path)
        let linked = reopened.project.mapMediaPaths { $0 == file.path ? copy.path : $0 }
        let copied = try engine.inspect(copy, keyframes: true)
        XCTAssertEqual(linked.analysisAnnotations.threshold(for: copied, stream: stream), -41.25)

        data[data.count - 1] = 0x7f
        try data.write(to: file)
        try files.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let replaced = try engine.inspect(file, keyframes: true)
        XCTAssertEqual(SceneSourceStamp(media: replaced), SceneSourceStamp(media: original))
        XCTAssertNil(reopened.project.analysisAnnotations.threshold(for: replaced, stream: stream))
        XCTAssertEqual(reopened.project.analysisAnnotations.silence.first?.thresholdDB, -41.25)
    }
}
