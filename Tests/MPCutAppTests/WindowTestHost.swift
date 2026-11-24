import AppKit

/// The standalone XCTest runner has no application event loop to finish AppKit launch.
/// Window tests need that lifecycle step before ordering windows or presenting sheets.
@MainActor
enum WindowTestHost {
    static let application: NSApplication = {
        let application = NSApplication.shared
        application.finishLaunching()
        return application
    }()
}
