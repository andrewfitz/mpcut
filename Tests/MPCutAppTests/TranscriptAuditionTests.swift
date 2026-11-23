import MPCutCore
import XCTest
@testable import MPCutApp

final class TranscriptAuditionTests: XCTestCase {
    func testSourceAuditionKeepsSelectedStreamAndStopsAtMediaEnd() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka",
                                                  subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectForPreview(url)
        let audio = media.streams.filter { $0.kind == "audio" }
        let selected = try XCTUnwrap(audio.dropFirst().first)
        let start = try media.duration.subtracting(.init(numerator: 1, denominator: 100))
        let word = MulticamRange(from: start, to: media.duration)
        let clip = try transcriptAuditionRange(media: media, presentation: word, streamIndex: selected.index,
                                               clockOffset: .zero, indexedInPresentationClock: true,
                                               includeLead: false)
        XCTAssertEqual(clip.audioTrack, 1)
        XCTAssertEqual(clip.exactStart, start)
        XCTAssertEqual(clip.exactEnd, media.duration)
        XCTAssertThrowsError(try transcriptAuditionRange(media: media, presentation: word, streamIndex: -1,
                                                         clockOffset: .zero, indexedInPresentationClock: true,
                                                         includeLead: false))
    }

    func testSourceAuditionMaintainsPresentationClockBeforePicture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Multicam-Delayed-PCM", withExtension: "mov",
                                                  subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectForPreview(url)
        let audio = try XCTUnwrap(media.streams.first { $0.kind == "audio" })
        XCTAssertTrue(media.hasVideo)
        // Model the same clip in a MOV with a leading picture edit.
        let clockOffset = RationalTime(numerator: 1, denominator: 5)
        XCTAssertLessThan(audio.start, clockOffset)
        let word = MulticamRange(from: audio.start, to: clockOffset)
        let clip = try transcriptAuditionRange(media: media, presentation: word, streamIndex: audio.index,
                                               clockOffset: clockOffset, indexedInPresentationClock: false,
                                               includeLead: false)
        XCTAssertTrue(clip.isAudioOnly)
        XCTAssertEqual(clip.assetClockOrigin, .zero)
        XCTAssertEqual(clip.exactStart, audio.start)
    }
}
