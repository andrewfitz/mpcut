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

    func testAudioMappingsCoalescePictureSwitchesButPreserveGapsAndReplay() {
        func interval(_ group: AudioSpan, _ output: AudioSpan, picture: String?, assembly: Int) -> MulticamInterval {
            .init(group: MulticamSilencePlanner.range(group), output: MulticamSilencePlanner.range(output),
                  angle: picture ?? "b", pictureSourceID: picture, audio: micA, assemblyIndex: assembly)
        }
        let mappings = MulticamAudioMapping.coalescing([
            interval(span(0, 10), span(0, 10), picture: "a", assembly: 0),
            interval(span(10, 20), span(10, 20), picture: nil, assembly: 0),
            interval(span(20, 30), span(20, 30), picture: "b", assembly: 0),
            interval(span(40, 50), span(30, 40), picture: "a", assembly: 0),
            interval(span(0, 30), span(45, 75), picture: "b", assembly: 2),
        ])
        XCTAssertEqual(mappings.map(\.assemblyIndex), [0, 0, 2])
        XCTAssertEqual(mappings.map { MulticamSilencePlanner.span($0.group) }, [span(0, 30), span(40, 50), span(0, 30)])
        XCTAssertEqual(mappings.map { MulticamSilencePlanner.span($0.output) }, [span(0, 30), span(30, 40), span(45, 75)])
    }

    private func detection(quiet: [AudioSpan], covered: [AudioSpan]) throws -> SilenceAnalysisResult {
        let runs = SilenceRuns(quiet: quiet, covered: covered)
        let encodedRuns = try JSONSerialization.jsonObject(with: JSONEncoder().encode(runs))
        let data = try JSONSerialization.data(withJSONObject: [
            "audio_stream_index": 1, "silence_min_pause_seconds": 0.02, "silence_automatic_threshold_db": -45,
            "pauses": [], "runs": encodedRuns
        ])
        return try JSONDecoder().decode(SilenceAnalysisResult.self, from: data)
    }

    private func route(_ selection: MulticamAudioSelection, _ from: Int64, _ to: Int64,
                       offset: Int64 = 0, laneID: String? = nil) -> MulticamSilenceRoute {
        MulticamSilenceRoute(selection: selection,
                             group: .init(from: time(from + offset), to: time(to + offset)),
                             input: .init(from: time(from), to: time(to)), offset: time(offset), laneID: laneID)
    }

    func testBlipLimitIsInclusiveAndAppliedBeforeMinimumPause() {
        let quiet = [span(0, 500), span(800, 1300)]
        let runs = SilenceRuns(quiet: quiet, covered: [span(0, 1300)])
        XCTAssertEqual(runs.pauses(minimum: 1, maxBlip: 0.3), [span(0, 1300)])
        XCTAssertEqual(runs.pauses(minimum: 0, maxBlip: 0.29), quiet)
        XCTAssertEqual(runs.pauses(minimum: 0, maxBlip: 0), quiet)
        XCTAssertEqual(SilenceRuns(quiet: quiet, covered: quiet).pauses(minimum: 0, maxBlip: 0.3), quiet)
    }

    func testBlipLimitsAcrossRepeatedClicksAndCoverageGaps() {
        // One continuous clock exercises coverage lookup well beyond the first gap.
        var quiet: [AudioSpan] = []
        var covered: [AudioSpan] = []
        var cases: [(left: Int64, blip: Int64, right: Int64, missing: Bool, start: Int64)] = []
        var start: Int64 = 0
        for left: Int64 in [20, 140, 160, 180, 1000] {
            for right: Int64 in [20, 140, 160, 180, 1000] {
                for blip: Int64 in [20, 60, 80, 280, 300, 320, 980, 1000, 1020] {
                    for missing in [false, true] {
                        let first = span(start, start + left)
                        let second = span(start + left + blip, start + left + blip + right)
                        quiet += [first, second]
                        covered += missing ? [first, second] : [AudioSpan(from: first.from, to: second.to)]
                        cases.append((left, blip, right, missing, start))
                        start += left + blip + right + 20
                    }
                }
            }
        }
        let runs = SilenceRuns(quiet: quiet, covered: covered)
        for limit: Int64 in [0, 60, 300, 1000] {
            let expected = cases.flatMap { item -> [AudioSpan] in
                let onset = item.start + item.left
                let offset = onset + item.blip
                let end = offset + item.right
                if !item.missing, item.left >= 160, item.right >= 160, item.blip <= limit {
                    return [span(item.start, end)]
                }
                return [span(item.start, onset), span(offset, end)]
            }
            XCTAssertEqual(runs.pauses(minimum: 0, maxBlip: Double(limit) / 1000), expected)
        }

        // Clicks can chain only when each pair has its own quiet context.
        let train = SilenceRuns(quiet: [span(0, 160), span(460, 620), span(920, 1080),
                                        span(1380, 1520), span(1820, 1980)], covered: [span(0, 1980)])
        XCTAssertEqual(train.pauses(minimum: 0, maxBlip: 0.30),
                       [span(0, 1080), span(1380, 1520), span(1820, 1980)])
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
    func testMixRequiresQuietEvidenceFromEveryLane() throws {
        let silences = [
            micA: try detection(quiet: [span(0, 1_000)], covered: [span(0, 1_000)]),
            micB: try detection(quiet: [span(200, 600)], covered: [span(0, 800)])
        ]
        let routes = [route(micA, 0, 1_000, laneID: "wide"),
                      route(micB, 0, 800, offset: 100, laneID: "guest")]
        XCTAssertEqual(MulticamSilencePlanner.mixedPauses(routes, laneIDs: ["wide", "guest"],
                                                          silences: silences, maxBlip: 0), [span(300, 700)])
        XCTAssertEqual(MulticamSilencePlanner.mixedPauses(routes, laneIDs: ["wide", "guest"],
                                                          silences: [micA: silences[micA]!]), [])
    }

    func testMixedPauseUsesKnownGapsButDoesNotBridgeUnknownSamples() throws {
        let silences = [
            micA: try detection(quiet: [span(0, 1_000)], covered: [span(0, 1_000)]),
            micB: try detection(quiet: [span(0, 300), span(350, 700)], covered: [span(0, 300), span(350, 700)])
        ]
        let routes = [route(micA, 0, 1_000, laneID: "wide"),
                      route(micB, 0, 700, offset: 200, laneID: "guest")]
        XCTAssertEqual(MulticamSilencePlanner.mixedPauses(routes, laneIDs: ["wide", "guest"],
                           knownGaps: ["guest": [span(0, 200), span(900, 1_000)]], silences: silences),
                       [span(0, 500), span(550, 1_000)])
    }

}
