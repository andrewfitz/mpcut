import Foundation
import XCTest
@testable import MPCutApp

@MainActor
final class ExportCompletionTests: XCTestCase {
    private final class FakeCenter: ExportNotificationCenter {
        var state: ExportNotificationAuthorization
        var requests = 0
        var posts: [(String, String)] = []

        init(_ state: ExportNotificationAuthorization) { self.state = state }

        func authorization() async -> ExportNotificationAuthorization { state }

        func requestAuthorization() async -> ExportNotificationAuthorization {
            requests += 1
            if state == .notDetermined { state = .authorized }
            return state
        }

        func post(title: String, body: String) async -> Bool {
            posts.append((title, body))
            return true
        }
    }

    private var output: URL!
    private var revealed: [[URL]] = []
    private var sounds = 0
    private var opened: [URL] = []

    override func setUpWithError() throws {
        output = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-export-\(UUID().uuidString).mp4")
        try Data([1]).write(to: output)
        revealed = []
        sounds = 0
        opened = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: output)
    }

    private func completion(_ center: FakeCenter?, frontmost: Bool = false, muted: Bool = false,
                            bundle: String? = "com.mpcut.desktop") -> ExportCompletion {
        ExportCompletion(notifications: center, useSystemNotifications: false, bundleIdentifier: bundle,
                         isFrontmost: { frontmost }, reveal: { [unowned self] in revealed.append($0) },
                         muted: muted, playSound: { [unowned self] in sounds += 1 },
                         openURL: { [unowned self] in opened.append($0); return true })
    }

    func testAllOffDoesNothing() async {
        let center = FakeCenter(.authorized)
        let outcome = await completion(center).finish(output, title: "Export finished", reveal: false, notify: false, playSound: false)
        XCTAssertEqual(outcome, .init())
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertEqual(sounds, 0)
        XCTAssertTrue(center.posts.isEmpty)
    }

    func testRevealNotifyAndSoundInTheBackground() async {
        let center = FakeCenter(.authorized)
        let outcome = await completion(center).finish(output, title: "Export finished", reveal: true, notify: true, playSound: true)
        XCTAssertEqual(outcome, .init(revealed: true, notified: true, playedSound: true))
        XCTAssertEqual(revealed, [[output]])
        XCTAssertEqual(sounds, 1)
        XCTAssertEqual(center.posts.map(\.0), ["Export finished"])
        XCTAssertEqual(center.posts.map(\.1), [output.lastPathComponent])
    }

    func testNoNotificationWhileFrontmost() async {
        let center = FakeCenter(.authorized)
        let outcome = await completion(center, frontmost: true).finish(output, title: "Done", reveal: false, notify: true, playSound: false)
        XCTAssertFalse(outcome.notified)
        XCTAssertTrue(center.posts.isEmpty)
    }

    func testPostingNeverAsksForPermission() async {
        for state in [ExportNotificationAuthorization.notDetermined, .denied] {
            let center = FakeCenter(state)
            let outcome = await completion(center).finish(output, title: "Done", reveal: false, notify: true, playSound: false)
            XCTAssertFalse(outcome.notified)
            XCTAssertEqual(center.requests, 0)
            XCTAssertTrue(center.posts.isEmpty)
        }
    }

    func testMutedLaunchStaysSilent() async {
        let outcome = await completion(FakeCenter(.authorized), muted: true)
            .finish(output, title: "Done", reveal: false, notify: false, playSound: true)
        XCTAssertFalse(outcome.playedSound)
        XCTAssertEqual(sounds, 0)
        // The test process itself is muted.
        XCTAssertTrue(MutedLaunch.isEnabled)
    }

    func testMissingOutputIsNotRevealed() async {
        try? FileManager.default.removeItem(at: output)
        let outcome = await completion(nil).finish(output, title: "Done", reveal: true, notify: true, playSound: false)
        XCTAssertFalse(outcome.revealed)
        XCTAssertFalse(outcome.notified)
        XCTAssertTrue(revealed.isEmpty)
    }

    func testPermissionRequestAndState() async {
        let center = FakeCenter(.notDetermined)
        let subject = completion(center)
        let initial = await subject.notificationAuthorization()
        XCTAssertEqual(initial, .notDetermined)
        let requested = await subject.requestNotificationPermission()
        XCTAssertEqual(requested, .authorized)
        XCTAssertEqual(center.requests, 1)
        let none = completion(nil)
        let unavailable = await none.notificationAuthorization()
        let refused = await none.requestNotificationPermission()
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertEqual(refused, .unavailable)
    }

    func testNoSystemCenterWithoutABundleIdentifier() async {
        let app = URL(fileURLWithPath: "/Applications/MPCut.app")
        XCTAssertNil(SystemExportNotifications.system(bundleIdentifier: nil, bundleURL: app))
        XCTAssertNil(SystemExportNotifications.system(bundleIdentifier: "", bundleURL: app))
        XCTAssertNil(SystemExportNotifications.system(bundleIdentifier: "com.apple.dt.xctest.tool",
                                                      bundleURL: URL(fileURLWithPath: "/usr/bin")))
        // The XCTest host is not an app, so the defaults never reach the system center.
        XCTAssertNotEqual(Bundle.main.bundleURL.pathExtension, "app")
        XCTAssertNil(SystemExportNotifications.system())
        let subject = ExportCompletion(isFrontmost: { false }, reveal: { _ in }, muted: true, playSound: {}, openURL: { _ in false })
        let state = await subject.notificationAuthorization()
        XCTAssertEqual(state, .unavailable)
    }

    func testOpensNotificationSettingsForTheApp() {
        XCTAssertTrue(completion(nil).openNotificationSettings())
        XCTAssertEqual(opened.map(\.absoluteString),
                       ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.mpcut.desktop"])
        XCTAssertEqual(ExportCompletion.notificationSettingsURL(bundleIdentifier: nil).absoluteString,
                       "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }
}
