import XCTest
@testable import MPCutCore

final class MulticamSoundTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpcut-multicam-sound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// One second of 16-bit mono PCM at 48 kHz.
    private func microphone() throws -> MediaInfo {
        let samples = 48_000
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(36 + samples * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(48_000))
        append(UInt32(96_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(samples * 2))
        for sample in 0..<samples { append(Int16(truncatingIfNeeded: sample * 37)) }
        let url = directory.appendingPathComponent("mic.wav")
        try data.write(to: url)
        return try CutEngine(useSidecar: false).inspectMulticamSource(url)
    }

    private func resolve(_ media: MediaInfo, issue: String?) throws -> ResolvedEdit {
        let flagged = MediaInfo(url: media.url, format: media.format, duration: media.duration, origin: media.origin,
                                streams: media.streams, frames: media.frames, audio: media.audio, copyIssue: issue,
                                sourceStartSafe: media.sourceStartSafe, identity: media.identity, videoIndex: -1)
        let second = MulticamRange(from: .zero, to: RationalTime(numerator: 1))
        let selection = MulticamAudioSelection(source: "mic", stream: 0)
        let mapping = MulticamPlan(
            intervals: [.init(group: second, output: second, angle: "mic", audio: selection, assemblyIndex: 0)],
            picture: [], audio: [.init(source: "mic", stream: 0, input: second, output: second)], duration: second.to)
        return try MulticamEngine().resolveSound(mapping, sources: ["mic": flagged], container: "wav")
    }

    func testAnIndexedIssueOnTheSelectedSoundtrackBlocksItsCopy() throws {
        let media = try microphone()
        XCTAssertEqual(try resolve(media, issue: nil).segments.count, 1)
        // An unused microphone on the same recording does not affect the selected one.
        XCTAssertEqual(try resolve(media, issue: "Audio track 3 has no usable presentation clock.").segments.count, 1)
        XCTAssertEqual(try resolve(media, issue: "AAC track 10 has a packet with missing duration.").segments.count, 1)
        for issue in ["Audio track 0 has no usable presentation clock.", "AAC track 0 has a packet with missing duration."] {
            XCTAssertThrowsError(try resolve(media, issue: issue)) { error in
                XCTAssertEqual((error as? CutError)?.code, "unsupported_tracks")
                XCTAssertEqual((error as? CutError)?.track, 0)
            }
        }
    }
}
