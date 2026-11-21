import AppKit
import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class AudioEditingWorkflowTests: XCTestCase {
    private let rate = 44_100
    private let length = 100_003

    private func sample(_ i: Int) -> Int16 {
        if (30_000..<65_000).contains(i) { return 0 }
        return Int16(i % 20_011 - 10_005)
    }

    private func createWAV(_ url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
        ], commonFormat: .pcmFormatInt16, interleaved: false)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(length)))
        pcm.frameLength = pcm.frameCapacity
        let channel = try XCTUnwrap(pcm.int16ChannelData?[0])
        for i in 0..<length { channel[i] = sample(i) }
        try file.write(from: pcm)
    }

    @MainActor
    private func wait(for editor: EditorModel, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline {
            if let notice = editor.alert { throw NSError(domain: "Editor", code: 1, userInfo: [NSLocalizedDescriptionKey: notice.message]) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), editor.statusMessage)
        XCTAssertNil(editor.alert)
    }

    @MainActor
    func testReopenedAudioCanQueueSampleExactRangesAcrossReorderedJoin() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try createWAV(source)
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.minimumPause = 0.4
        editor.preview.isMuted = true
        editor.importFiles([source])
        try await wait(for: editor) { editor.canEdit }
        XCTAssertTrue(editor.isAudioOnly)
        XCTAssertFalse(editor.canScanScenes)
        XCTAssertNil(editor.jpegSourceAtPlayhead)
        editor.scanForSilence()
        try await wait(for: editor) { editor.pauseAnalysisReady }
        let firstID = try XCTUnwrap(editor.timelineClips.first?.sourceID)
        let pauses = try XCTUnwrap(editor.sourcePauses[firstID])
        XCTAssertFalse(pauses.isEmpty)
        editor.saveAnalysisSidecars()
        try await wait(for: editor) { !editor.isSavingSidecars }
        editor.endSession()
        editor.importFiles([source])
        try await wait(for: editor) { editor.canEdit && editor.pauseAnalysisReady }
        let clip = try XCTUnwrap(editor.timelineClips.first)
        XCTAssertEqual(editor.sourcePauses[clip.sourceID], pauses)

        func seconds(_ samples: Int) -> Double { Double(samples) / Double(rate) }
        let trim = 1_207, cut = 35_521
        XCTAssertEqual(editor.trim(clip.id, edge: .start, sourceTime: seconds(trim), commit: true), seconds(trim))
        try await wait(for: editor) { editor.canEdit }
        editor.seek(seconds(cut - trim))
        editor.split()
        try await wait(for: editor) { editor.canEdit && editor.timelineClips.count == 2 }
        let second = try XCTUnwrap(editor.timelineClips.last)
        editor.move(second.id, to: 0)
        try await wait(for: editor) { editor.canEdit && editor.timelineClips.first?.id == second.id }
        let join = length - cut, tail = 321, head = 733
        editor.seek(seconds(join - tail))
        editor.setIn()
        editor.seek(seconds(join + head))
        editor.setOut()
        editor.addMarkedRange()
        XCTAssertEqual(editor.queuedRanges.first?.clips.count, 2)
        editor.showBulkQueue()
        var options = ExportSheetOptions()
        options.tracks = .audio
        options.copyContainer = "wav"
        editor.exportQueuedRanges(to: directory, options: options)
        try await wait(for: editor) { editor.canEdit && editor.lastExportedURL != nil }

        let output = directory.appendingPathComponent("source-001.wav")
        let file = try AVAudioFile(forReading: output, commonFormat: .pcmFormatInt16, interleaved: false)
        XCTAssertEqual(file.length, Int64(tail + head))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let channel = try XCTUnwrap(pcm.int16ChannelData?[0])
        let decoded = Array(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)))
        XCTAssertEqual(decoded, ((length - tail)..<length).map(sample) + (trim..<(trim + head)).map(sample))
    }
}
