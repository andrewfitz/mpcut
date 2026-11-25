import XCTest
@testable import MPCutCore

/// Caption limits are parameters with the old literals as their defaults. The CLI and agents never pass
/// them; the desktop app passes the editor's Settings values.
final class SettingsTranscriptCaptionLimitsTests: XCTestCase {
    /// Ten four-letter words spoken by Ada, half a second each, in one utterance.
    static func index() throws -> TranscriptIndex {
        let words = (0..<10).map { i in
            TranscriptWord(id: "w\(i)", text: " word", start: .init(numerator: Int64(i), denominator: 2),
                           end: .init(numerator: Int64(i + 1), denominator: 2), utteranceID: "u", speakerID: "ada")
        }
        return try TranscriptIndex(document: .init(clock: .presentation, speakers: [.init(id: "ada", name: "Ada")], words: words))
    }

    static let standardOutput = """
    1
    00:00:00,000 --> 00:00:05,000
    [Ada] word word word word word word word
    word word word


    """

    func testStandardLimitsAreTodaysLiteralsAndTheDefault() throws {
        let limits = TranscriptCaptionLimits.standard
        XCTAssertEqual(limits.lineCharacters, 42)
        XCTAssertEqual(limits.lines, 2)
        XCTAssertEqual(limits.longestCue, RationalTime(numerator: 6))
        XCTAssertTrue(limits.speakerLabels)
        let index = try Self.index()
        let unspecified = try TranscriptCodec.encodeCaptions([index], space: .source)
        XCTAssertEqual(String(decoding: unspecified, as: UTF8.self), Self.standardOutput)
        XCTAssertEqual(try TranscriptCodec.encodeCaptions([index], space: .source, limits: .standard), unspecified)
        XCTAssertEqual(try TranscriptCodec.captionExport([index], space: .source, filter: .init()).data, unspecified)
    }

    func testShorterLinesMoreLinesShorterCuesAndNoLabels() throws {
        let limits = TranscriptCaptionLimits(lineCharacters: 20, lines: 3, longestCue: .init(numerator: 3), speakerLabels: false)
        let output = try TranscriptCodec.encodeCaptions([Self.index()], space: .source, limits: limits)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), """
        1
        00:00:00,000 --> 00:00:03,000
        word word word word
        word word

        2
        00:00:03,000 --> 00:00:05,000
        word word word word


        """)
    }

    func testOneLineStartsANewCueWhenTheLineIsFull() throws {
        let limits = TranscriptCaptionLimits(lineCharacters: 42, lines: 1)
        let output = try TranscriptCodec.encodeCaptions([Self.index()], space: .source, limits: limits)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), """
        1
        00:00:00,000 --> 00:00:03,500
        [Ada] word word word word word word word

        2
        00:00:03,500 --> 00:00:05,000
        [Ada] word word word


        """)
    }

    func testLongestCueSplitsOnTime() throws {
        let limits = TranscriptCaptionLimits(longestCue: .init(numerator: 2))
        let cues = try TranscriptCodec.decode(TranscriptCodec.encodeCaptions([Self.index()], space: .source, limits: limits),
                                              format: .srt).words
        XCTAssertEqual(cues.map(\.start), [.zero, .init(numerator: 2), .init(numerator: 4)])
    }

    func testTranscriptExportIgnoresCaptionLimits() throws {
        // Export Transcript keeps its own grouping; only Export Captions takes the limits.
        let index = try Self.index()
        let srt = try TranscriptCodec.encode(index, space: .source, format: .srt)
        XCTAssertTrue(String(decoding: srt, as: UTF8.self).contains("[Ada]"))
    }
}
