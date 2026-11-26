import AppKit
import SwiftUI
import XCTest
@testable import MPCutApp

/// The Settings window resizes from 760 × 560 down to 640 × 420, and every page fits at the minimum.
@MainActor
final class SettingsFix3WindowTests: XCTestCase {
    private typealias S = SettingsFix3Support

    private func settings(_ preferences: EditorPreferences, locations: StorageLocations) -> SettingsWindow {
        SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() }, storageLocations: locations)
    }

    func testTheHooksMakeAFixedWindowResizableWithItsMinimumAndStartingSize() throws {
        let preferences = EditorPreferences()
        // The style a SwiftUI Settings scene gives its window: titled and closable, not resizable.
        let (window, host) = S.window(settings(preferences, locations: try S.temporaryLocations()),
                                      size: NSSize(width: 300, height: 200), style: [.titled, .closable, .miniaturizable])
        defer { window.close() }
        S.spin()
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 640, height: 420))
        XCTAssertGreaterThan(window.contentMaxSize.width, 10_000)
        XCTAssertGreaterThan(window.contentMaxSize.height, 10_000)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 760, height: 560), "It starts at 760 × 560")
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled ?? true, true)

        // SwiftUI setting the style again does not make it fixed.
        window.styleMask.remove(.resizable)
        XCTAssertTrue(window.styleMask.contains(.resizable))

        // The content follows the window to the minimum and beyond the start, and its layout does not push back.
        for size in [NSSize(width: 640, height: 420), NSSize(width: 1100, height: 800), NSSize(width: 700, height: 480)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            S.spin(0.1)
            XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, size)
            XCTAssertEqual(host.frame.size, size)
        }
        // A size the editor chose survives the hooks running again, as when the window becomes key.
        SettingsWindowHooks.configure(window)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 700, height: 480))
    }

    func testAWindowAlreadyAboveTheMinimumKeepsItsSize() throws {
        let (window, _) = S.window(settings(EditorPreferences(), locations: try S.temporaryLocations()),
                                   size: NSSize(width: 900, height: 700), style: [.titled, .closable])
        defer { window.close() }
        S.spin()
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 900, height: 700))
    }

    func testTheHooksWorkInAHostingControllerWindowToo() throws {
        _ = WindowTestHost.application
        let controller = NSHostingController(rootView: settings(EditorPreferences(), locations: try S.temporaryLocations()))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }
        S.spin()
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 640, height: 420))
        window.setContentSize(NSSize(width: 640, height: 420))
        window.layoutIfNeeded()
        S.spin(0.1)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 640, height: 420))
    }

    func testEveryPageFitsTheMinimumSize() throws {
        let preferences = EditorPreferences()
        let locations = try S.temporaryLocations()
        // Show the optional rows too: a chosen export folder and nonzero limits.
        preferences.exportStartFolder = .chosen
        preferences.exportStartFolderPath = FileManager.default.temporaryDirectory.path
        preferences.sharedCacheLimitBytes = 2_500_000_000
        for page in SettingsPage.allCases {
            preferences.settingsPage = page
            let (window, host) = S.window(settings(preferences, locations: locations), size: NSSize(width: 640, height: 420))
            S.spin(0.1)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 640, height: 420), page.rawValue)
            XCTAssertEqual(host.frame.size, NSSize(width: 640, height: 420), page.rawValue)
            // Every AppKit control the page shows lies within the window's width: nothing is pushed off the side.
            let controls = S.descendants(host).compactMap { $0 as? NSControl }.filter { !$0.isHiddenOrHasHiddenAncestor }
            XCTAssertFalse(controls.isEmpty, page.rawValue)
            for control in controls {
                let frame = control.convert(control.bounds, to: host)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(page.rawValue): \(control)")
                XCTAssertLessThanOrEqual(frame.maxX, 640.5, "\(page.rawValue): \(control) \(frame)")
            }
            window.close()
        }
    }
}
