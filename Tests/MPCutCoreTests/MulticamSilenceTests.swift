import XCTest
@testable import MPCutCore

final class MulticamSilenceTests: XCTestCase {
    private let micA = MulticamAudioSelection(source: "a", stream: 1)
    private let micB = MulticamAudioSelection(source: "b", stream: 1)

    private func time(_ milliseconds: Int64) -> RationalTime {
        RationalTime(numerator: milliseconds, denominator: 1_000)
    }

    private func span(_ from: Int64, _ to: Int64) -> AudioSpan {
        AudioSpan(from: time(from), to: time(to))
    }

    private func detection(quiet: [AudioSpan], covered: [AudioSpan]) throws -> SilenceAnalysisResult {
        let runs = SilenceRuns(quiet: quiet, covered: covered)
        let encodedRuns = try JSONSerialization.jsonObject(with: JSONEncoder().encode(runs))
        let data = try JSONSerialization.data(withJSONObject: [
            "stream": 1, "minimum": 0.02, "automaticThresholdDB": -45,
            "pauses": [], "runs": encodedRuns
        ])
        return try JSONDecoder().decode(SilenceAnalysisResult.self, from: data)
    }

    private func route(_ selection: MulticamAudioSelection, _ from: Int64, _ to: Int64,
                       offset: Int64 = 0) -> MulticamSilenceRoute {
        MulticamSilenceRoute(selection: selection,
                             group: .init(from: time(from + offset), to: time(to + offset)),
                             input: .init(from: time(from), to: time(to)), offset: time(offset))
    }

    func testBlipUsesQuietContextFromTheSelectedProgram() throws {
        let silences = [
            micA: try detection(quiet: [span(0, 500), span(540, 1_000)], covered: [span(0, 1_000)]),
            micB: try detection(quiet: [span(0, 800)], covered: [span(0, 1_000)])
        ]
        // The program takes only A's blip and uses B for the quiet context
        // on either side.
        let routes = [route(micB, 0, 500), route(micA, 500, 540), route(micB, 500, 800, offset: 40)]
        XCTAssertEqual(MulticamSilencePlanner.routedPauses(Array(routes.reversed()), silences: silences),
                       [span(0, 840)])
        // An assembly occurrence entering on the blip has no quiet lead-in.
        XCTAssertEqual(MulticamSilencePlanner.routedPauses(Array(routes.dropFirst()), silences: silences),
                       [span(540, 840)])
        // The two measured quiet ranges cannot bridge missing audio.
        XCTAssertEqual(MulticamSilencePlanner.routedPauses([routes[0], routes[2]], silences: silences),
                       [span(0, 500), span(540, 840)])
    }

    func testMicrophoneSwitchExtendsSpeechPastPreviouslyBridgedBlip() throws {
        let silences = [
            micA: try detection(quiet: [span(0, 500), span(540, 1_000)], covered: [span(0, 1_000)]),
            micB: try detection(quiet: [], covered: [span(0, 1_000)])
        ]
        let routes = [route(micA, 0, 540), route(micB, 540, 1_000)]
        XCTAssertEqual(MulticamSilencePlanner.routedPauses(routes, silences: silences), [span(0, 500)])
    }
}
