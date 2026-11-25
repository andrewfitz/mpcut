import Foundation
import XCTest
@testable import MPCutCore

final class SleepPreventionTests: XCTestCase {
    private final class Provider: ActivityProviding, @unchecked Sendable {
        var begun: [(ProcessInfo.ActivityOptions, String)] = []
        var ended: [NSObjectProtocol] = []
        let token = NSObject()

        func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
            begun.append((options, reason))
            return token
        }

        func endActivity(_ activity: NSObjectProtocol) { ended.append(activity) }
    }

    func testBeginsWithReasonAndDisablesIdleSleep() {
        let provider = Provider()
        let token = SleepPrevention(reason: "Exporting Interview.mp4", provider: provider)
        XCTAssertEqual(provider.begun.count, 1)
        XCTAssertEqual(provider.begun.first?.1, "Exporting Interview.mp4")
        XCTAssertTrue(provider.begun.first?.0.contains(.idleSystemSleepDisabled) == true)
        XCTAssertTrue(token.isActive)
        XCTAssertTrue(provider.ended.isEmpty)
        token.end()
    }

    func testExplicitEndEndsOnceAndDeinitDoesNotRepeat() {
        let provider = Provider()
        var token: SleepPrevention? = SleepPrevention(reason: "Transcribing", provider: provider)
        token?.end()
        token?.end()
        XCTAssertEqual(provider.ended.count, 1)
        XCTAssertTrue(provider.ended.first === provider.token)
        XCTAssertEqual(token?.isActive, false)
        token = nil
        XCTAssertEqual(provider.ended.count, 1)
    }

    func testReleasingTheTokenEndsTheActivity() {
        let provider = Provider()
        do {
            let token = SleepPrevention(reason: "Exporting", provider: provider)
            withExtendedLifetime(token) { XCTAssertTrue(provider.ended.isEmpty) }
        }
        XCTAssertEqual(provider.begun.count, 1)
        XCTAssertEqual(provider.ended.count, 1)
    }
}
