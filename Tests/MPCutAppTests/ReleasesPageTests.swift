import Foundation
import XCTest
@testable import MPCutApp

@MainActor
final class ReleasesPageTests: XCTestCase {
    func testOpensTheLatestReleasePage() {
        XCTAssertEqual(ReleasesPage.url.absoluteString, "https://github.com/andrewfitz/mpcut/releases/latest")
        var opened: [URL] = []
        XCTAssertTrue(ReleasesPage.open { opened.append($0); return true })
        XCTAssertEqual(opened, [ReleasesPage.url])
    }
}
