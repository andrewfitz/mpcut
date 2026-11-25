import XCTest
@testable import MPCutCore

final class TextCueMergeTests: XCTestCase {
    private func event(_ text: String, style: String = "Default") -> String { "0,0,\(style),,0,0,0,,\(text)" }

    func testCuesThatStartTogetherShareEachPartInCueOrder() {
        // Three cues that all cross the start of a kept range land at zero together.
        let cues = [TextCue(start: 0, end: 1000, event: event("One")), TextCue(start: 0, end: 2000, event: event("Two")),
                    TextCue(start: 0, end: 500, event: event("Same start"))]
        XCTAssertTrue(TextCueMerge.overlaps(cues))
        XCTAssertEqual(TextCueMerge.merged(cues), [
            TextCue(start: 0, end: 500, event: "0,0,Default,,0,0,0,,One\\N{\\rDefault}Two\\N{\\rDefault}Same start"),
            TextCue(start: 500, end: 1000, event: "1,0,Default,,0,0,0,,One\\N{\\rDefault}Two"),
            TextCue(start: 1000, end: 2000, event: "2,0,Default,,0,0,0,,Two"),
        ])
    }

    func testCuesThatMeetOrStandApartDoNotOverlap() {
        let cues = [TextCue(start: 0, end: 1000, event: event("A")), TextCue(start: 1000, end: 2000, event: event("B")),
                    TextCue(start: 3000, end: 4000, event: event("C"))]
        XCTAssertFalse(TextCueMerge.overlaps(cues))
        // Merging them anyway keeps each cue, numbered in order, and leaves the gap empty.
        XCTAssertEqual(TextCueMerge.merged(cues).map(\.start), [0, 1000, 3000])
        XCTAssertEqual(TextCueMerge.merged(cues).map(\.end), [1000, 2000, 4000])
    }

    func testEachJoinedCueResetsToItsOwnStyle() {
        let cues = [TextCue(start: 0, end: 10, event: "3,0,Red,,0,0,0,,{\\i1}A"),
                    TextCue(start: 5, end: 20, event: "4,1,Blue,Bob,5,5,5,,B{\\b1\\r}c{\\r\\i1}d"),
                    // Draws nothing, so it adds no line.
                    TextCue(start: 5, end: 15, event: "5,0,,,0,0,0,,{\\i1}"),
                    // No style name is the Default style, and commas belong to the text.
                    TextCue(start: 8, end: 12, event: "6,0,,,0,0,0,,x, y")]
        let merged = TextCueMerge.merged(cues)
        XCTAssertEqual(merged, [
            TextCue(start: 0, end: 5, event: "0,0,Red,,0,0,0,,{\\i1}A"),
            // A reset without a name inside a later cue names that cue's style.
            TextCue(start: 5, end: 8, event: "1,0,Red,,0,0,0,,{\\i1}A\\N{\\rBlue}B{\\b1\\rBlue}c{\\rBlue\\i1}d"),
            TextCue(start: 8, end: 10, event: "2,0,Red,,0,0,0,,{\\i1}A\\N{\\rBlue}B{\\b1\\rBlue}c{\\rBlue\\i1}d\\N{\\rDefault}x, y"),
            // The first cue shown describes the event, and its own resets stay as they are.
            TextCue(start: 10, end: 12, event: "3,1,Blue,Bob,5,5,5,,B{\\b1\\r}c{\\r\\i1}d\\N{\\rDefault}x, y"),
            // The empty cue ends at 15 without changing what is shown, so one part runs to 20.
            TextCue(start: 12, end: 20, event: "4,1,Blue,Bob,5,5,5,,B{\\b1\\r}c{\\r\\i1}d"),
        ])
    }

    func testACueWithoutALengthLastsUntilTheNextStarts() {
        let cues = [TextCue(start: 0, end: 0, event: event("A")), TextCue(start: 0, end: 300, event: event("B")),
                    TextCue(start: 500, end: 500, event: event("C"))]
        XCTAssertTrue(TextCueMerge.overlaps(cues))
        XCTAssertEqual(TextCueMerge.merged(cues), [
            TextCue(start: 0, end: 300, event: "0,0,Default,,0,0,0,,A\\N{\\rDefault}B"),
            TextCue(start: 300, end: 500, event: "1,0,Default,,0,0,0,,A"),
            // After every other cue has ended it keeps no length.
            TextCue(start: 500, end: 500, event: "2,0,Default,,0,0,0,,C"),
        ])
    }

    func testIdenticalLinesOnLayersAreOneLineInTheTopLayersStyle() {
        // An outline drawn under the same text on a lower layer: one line, in the place of the first and the style of
        // the highest layer. A line with other text stays.
        let events = ["0,0,Default,,0,0,0,,{\\c&H000000&\\bord4}Sign", "0,0,Default,,0,0,0,,Speech",
                      "0,1,Red,,0,0,0,,{\\c&H0000FF&}Sign"]
        XCTAssertEqual(TextCueMerge.joined(events, readOrder: 2, collapsing: true),
                       "2,1,Red,,0,0,0,,{\\c&H0000FF&}Sign\\N{\\rDefault}Speech")
        // Of lines on one layer, the last is drawn on top. Without collapsing, every line is kept.
        XCTAssertEqual(TextCueMerge.joined(["0,0,A,,0,0,0,,Yes", "0,0,B,,0,0,0,,Yes"], readOrder: 0, collapsing: true),
                       "0,0,B,,0,0,0,,Yes")
        XCTAssertEqual(TextCueMerge.joined(["0,0,A,,0,0,0,,Yes", "0,0,B,,0,0,0,,Yes"], readOrder: 0),
                       "0,0,A,,0,0,0,,Yes\\N{\\rB}Yes")
        let cues = [TextCue(start: 0, end: 10, event: events[0]), TextCue(start: 0, end: 10, event: events[2])]
        XCTAssertEqual(TextCueMerge.merged(cues, collapsing: true), [TextCue(start: 0, end: 10, event: "0,1,Red,,0,0,0,,{\\c&H0000FF&}Sign")])
    }
}
