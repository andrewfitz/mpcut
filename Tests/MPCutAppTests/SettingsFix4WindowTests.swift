import AppKit
import SwiftUI
import XCTest
@testable import MPCutApp

/// At its minimum the Settings window gives the content exactly the content's minimum below the title bar, in a window
/// whose content view runs under the title bar, as SwiftUI's windows do, and nothing is pushed under the title bar or
/// past the bottom edge.
@MainActor
final class SettingsFix4WindowTests: XCTestCase {
    private typealias S = SettingsFix3Support
    private let fullSize: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView]

    private func settings(_ preferences: EditorPreferences) throws -> SettingsWindow {
        SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() }, storageLocations: try S.temporaryLocations())
    }

    /// Shrinks the window to its minimum frame and checks the content's area and where the controls sit.
    private func checkAtMinimum(_ window: NSWindow, host: NSView, _ name: String) throws {
        let titleBar = SettingsWindowHooks.titleBarInset(window).height
        XCTAssertGreaterThan(titleBar, 0, "\(name): the content view runs under the title bar")
        XCTAssertEqual(window.minSize.height, SettingsWindowHooks.minimumSize.height + titleBar, "\(name): the frame minimum adds the title bar")
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
        host.layoutSubtreeIfNeeded()
        S.spin(0.3)
        // The content's area is the root view's minimum frame, the same numbers as the window's minimum.
        XCTAssertEqual(window.contentLayoutRect.size, SettingsWindowHooks.minimumSize, name)
        let area = host.convert(window.contentLayoutRect, from: nil).insetBy(dx: -0.5, dy: -0.5)
        let search = try XCTUnwrap(S.descendants(host).compactMap { $0 as? NSSearchField }.first)
        let searchFrame = search.convert(search.bounds, to: host)
        XCTAssertTrue(area.contains(searchFrame), "\(name): the search field \(searchFrame) is below the title bar, inside \(area)")
        // The sidebar and the page show their content inside the area: neither runs past the bottom edge, and a scroll view
        // that draws under the title bar insets its content below it.
        let scrolls = S.descendants(host).compactMap { $0 as? NSScrollView }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.height > 40 }
        XCTAssertFalse(scrolls.isEmpty, name)
        for scroll in scrolls {
            let insets = scroll.contentView.contentInsets
            let frame = scroll.convert(scroll.bounds, to: host)
            let shown = NSRect(x: frame.minX + insets.left, y: frame.minY + insets.top,
                               width: frame.width - insets.left - insets.right, height: frame.height - insets.top - insets.bottom)
            XCTAssertTrue(area.contains(shown), "\(name): \(type(of: scroll)) shows \(shown), inside \(area)")
        }
    }

    func testAtTheMinimumTheContentFitsBelowTheTitleBar() throws {
        let preferences = EditorPreferences()
        let (window, host) = S.window(try settings(preferences), size: NSSize(width: 760, height: 560), style: fullSize)
        defer { window.close() }
        S.spin(0.3)
        // The hooks run again whenever the window becomes key or SwiftUI updates the view; they must not lower the minimum.
        SettingsWindowHooks.configure(window)
        S.spin(0.1)
        XCTAssertEqual(window.contentLayoutRect.size, NSSize(width: 760, height: 560 - SettingsWindowHooks.titleBarInset(window).height))
        try checkAtMinimum(window, host: host, "full-size content view")
    }

    /// A hosting view that leaves the window's minimum to the window, as a scene's window can: AppKit then recomputes the
    /// minimum from the content view's constraints, which once reset it below the title bar's share.
    func testTheMinimumHoldsWhenTheHostingViewSetsNoSizeConstraints() throws {
        _ = WindowTestHost.application
        let host = NSHostingView(rootView: try settings(EditorPreferences()))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: fullSize,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        S.spin(0.3)
        try checkAtMinimum(window, host: host, "no hosting constraints")
    }

    func testAWindowWithATitleBarAboveItsContentKeepsTheExactMinimum() throws {
        let (window, host) = S.window(try settings(EditorPreferences()), size: NSSize(width: 760, height: 560))
        defer { window.close() }
        S.spin(0.3)
        XCTAssertEqual(SettingsWindowHooks.titleBarInset(window), .zero)
        XCTAssertEqual(window.contentMinSize, SettingsWindowHooks.minimumSize)
        window.setContentSize(window.contentMinSize)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.size, SettingsWindowHooks.minimumSize)
    }
}
