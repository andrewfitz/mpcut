import XCTest
@testable import MPCutCore

/// The tier badge and the export sheet choose the container by one rule: the preferred container when the
/// timeline verifies in it, otherwise the first container that verifies.
final class TimelineTierContainerTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func fixture(_ name: String) -> URL {
        Self.repository.appendingPathComponent("Tests/MPCutAppTests/Fixtures/\(name)").standardizedFileURL
    }

    private func container(_ state: TierState) -> String? {
        if case .known(_, _, let container, _) = state { return container }
        return nil
    }

    func testTierAndOpeningContainerPreferTheUsersContainerOnlyWhenItVerifies() throws {
        // H.264 with AAC in MOV. Two ranges joined on keyframes that are not on AAC packets copy into MOV and MP4,
        // whose edit lists place the join. Matroska refuses them: a copy cannot join AAC frames there, and the second
        // range, one picture long, is too short for the AAC frames Smart Trim would encode. All three are listed.
        let movie = fixture("Shuttle-Chirp.mov")
        let media = try CutEngine(useSidecar: false).inspect(movie, keyframes: true)
        let cut = [ClipRequest(file: movie, from: .zero, to: RationalTime(numerator: 3, denominator: 5)),
                   ClipRequest(file: movie, from: RationalTime(numerator: 6, denominator: 5), to: RationalTime(numerator: 31, denominator: 25))]
        let whole = [ClipRequest(file: movie)]
        let engine = CutEngine(useSidecar: false)
        XCTAssertEqual(engine.suggestedContainers(for: media, clips: cut), ["mov", "mkv", "mp4"])
        let planner = ExportPlanner(useSidecar: false)
        func plans(_ container: String) -> Bool {
            if case .ready = planner.resolve(ExportRequest(clips: cut, mode: .copy, container: container), media: [movie: media]) { return true }
            return false
        }
        XCTAssertTrue(plans("mov") && plans("mp4"))
        XCTAssertFalse(plans("mkv"), "The scenario needs a listed container that fails for these cuts.")
        // A single cut inside an AAC frame copies into Matroska too: a codec delay hides the start, packets unchanged.
        let head = [ClipRequest(file: movie, from: RationalTime(numerator: 3, denominator: 5), to: nil)]
        if case .unavailable(let issue, _) = planner.resolve(ExportRequest(clips: head, mode: .copy, container: "mkv"), media: [movie: media]) {
            XCTFail("A Matroska copy refuses a start inside an AAC frame: \(issue.message)")
        }

        // preferred → the container of the tier and of the sheet's opening state.
        let cases: [(preferred: String?, clips: [ClipRequest], expected: String)] = [
            (nil, cut, "mov"),          // no preference: the first that verifies
            ("mkv", cut, "mov"),        // the preference fails: the first that verifies, never the failing one
            ("mp4", cut, "mp4"),        // the preference verifies: it is used although another comes first
            ("mkv", whole, "mkv"),      // the whole source copies into Matroska, so the preference stands
            ("flv", cut, "mov")         // a container outside the list is not used
        ]
        for (preferred, clips, expected) in cases {
            let evaluator = TimelineTierEvaluator(useSidecar: false)
            evaluator.preferredContainer = preferred
            let state = evaluator.evaluate(clips, media: [movie: media])
            XCTAssertEqual(state.tier, .trueLossless, "\(String(describing: preferred))")
            XCTAssertEqual(container(state), expected, "tier, preferred \(String(describing: preferred))")
            for mode in [ExportMode.copy, .smart] {
                let opening = planner.openingContainer(for: ExportRequest(clips: clips, mode: mode), preferred: preferred, media: [movie: media])
                XCTAssertEqual(opening, expected, "sheet \(mode.rawValue), preferred \(String(describing: preferred))")
            }
            // The export the sheet opens on is planned in that container.
            if case .unavailable(let issue, _) = planner.resolve(ExportRequest(clips: clips, mode: .copy, container: expected), media: [movie: media]) {
                XCTFail("The opening container does not plan: \(issue.message)")
            }
        }

        // One evaluator follows a change of preference: the answer is not kept from the earlier one.
        let evaluator = TimelineTierEvaluator(useSidecar: false)
        XCTAssertEqual(container(evaluator.evaluate(cut, media: [movie: media])), "mov")
        evaluator.preferredContainer = "mp4"
        XCTAssertEqual(container(evaluator.evaluate(cut, media: [movie: media])), "mp4")
        evaluator.preferredContainer = "mkv"
        XCTAssertEqual(container(evaluator.evaluate(cut, media: [movie: media])), "mov")

        // A re-encode names its container by its settings, and a request that plans nowhere opens on none.
        XCTAssertNil(planner.openingContainer(for: ExportRequest(clips: cut, mode: .encode), preferred: "mov", media: [movie: media]))
        let offFrame = [ClipRequest(file: movie, from: RationalTime(numerator: 1, denominator: 3), to: nil)]
        XCTAssertNil(planner.openingContainer(for: ExportRequest(clips: offFrame, mode: .copy), preferred: "mov", media: [movie: media]))
    }
}
