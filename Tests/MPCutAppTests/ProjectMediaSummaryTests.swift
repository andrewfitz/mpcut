import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class ProjectMediaSummaryTests: XCTestCase {
    @MainActor
    func testSummaryReusesReferencesAndReadsLiveStatuses() {
        let cache = ProjectMediaSummaryPaths()
        let generation = UUID()
        let document = URL(fileURLWithPath: "/Test/Edit.cut")
        var built = 0
        var file = "Clip.mov"
        var seen: Set<URL> = []
        var mediaStatus = ProjectMediaStatus.offline
        func project() -> CutProject {
            built += 1
            return .sequence([
                .init(id: "one", file: file, from: .zero, to: RationalTime(numerator: 1), originalFile: "Original.mov"),
                .init(id: "two", file: file, from: .zero, to: RationalTime(numerator: 1))
            ])
        }
        func summary(revision: Int = 0, location: URL? = nil, session: UUID? = nil) -> ProjectMediaAlertSummary {
            cache.summary(generation: session ?? generation, revision: revision, document: location ?? document, project: project()) { url in
                seen.insert(url)
                return mediaStatus
            }
        }

        XCTAssertEqual(summary().offline, 1)
        XCTAssertEqual(seen.map(\.path).sorted(), ["/Test/Clip.mov"])
        mediaStatus = .needsReview
        XCTAssertEqual(summary().offline, 0)
        XCTAssertEqual(summary().review, 1)
        XCTAssertEqual(built, 1)

        file = "Replacement.mov"
        seen = []
        _ = summary(revision: 1)
        XCTAssertEqual(seen.map(\.path).sorted(), ["/Test/Replacement.mov"])
        seen = []
        let moved = URL(fileURLWithPath: "/Moved/Edit.cut")
        _ = summary(revision: 1, location: moved)
        XCTAssertEqual(seen.map(\.path).sorted(), ["/Moved/Replacement.mov"])
        let nextSession = UUID()
        _ = summary(revision: 1, location: moved, session: nextSession)
        XCTAssertEqual(built, 4)
        cache.invalidate()
        _ = summary(revision: 1, location: moved, session: nextSession)
        XCTAssertEqual(built, 5)
    }
}
