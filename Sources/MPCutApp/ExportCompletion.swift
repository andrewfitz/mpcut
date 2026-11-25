import AppKit
import UserNotifications

/// Runs the Settings completion actions when a sequence, multicam, queue, JPEG, ISO, Resolve or
/// project interchange export finishes: show in Finder, notify and play a sound.

enum ExportNotificationAuthorization: String, Sendable {
    case authorized, denied, notDetermined = "not_determined", unavailable
}

/// The parts of the notification center export completion needs, so tests use a fake.
@MainActor
protocol ExportNotificationCenter: AnyObject {
    func authorization() async -> ExportNotificationAuthorization
    /// Shows the system prompt when the state is not determined.
    func requestAuthorization() async -> ExportNotificationAuthorization
    func post(title: String, body: String) async -> Bool
}

/// `UNUserNotificationCenter` fails in a process without an app bundle identifier, which includes
/// the XCTest host and a SwiftPM-run executable, so it is reached only through `system`.
@MainActor
final class SystemExportNotifications: ExportNotificationCenter {
    private lazy var center = UNUserNotificationCenter.current()

    private init() {}

    static func system(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                       bundleURL: URL = Bundle.main.bundleURL) -> SystemExportNotifications? {
        // A command-line tool can embed an identifier without being an app.
        guard let bundleIdentifier, !bundleIdentifier.isEmpty, bundleURL.pathExtension == "app" else { return nil }
        return SystemExportNotifications()
    }

    func authorization() async -> ExportNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    func requestAuthorization() async -> ExportNotificationAuthorization {
        // MPCut plays its own completion sound, so a notification stays silent.
        _ = try? await center.requestAuthorization(options: [.alert])
        return await authorization()
    }

    func post(title: String, body: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        return (try? await center.add(request)) != nil
    }
}

@MainActor
final class ExportCompletion {
    struct Outcome: Equatable {
        var revealed = false
        var notified = false
        var playedSound = false
    }

    static let shared = ExportCompletion()

    private let notifications: ExportNotificationCenter?
    private let bundleIdentifier: String?
    private let isFrontmost: () -> Bool
    private let reveal: ([URL]) -> Void
    private let muted: Bool
    private let playSound: () -> Void
    private let openURL: (URL) -> Bool

    /// Every argument defaults to the system service. Tests replace all of them.
    init(notifications: ExportNotificationCenter? = nil, useSystemNotifications: Bool = true,
         bundleIdentifier: String? = Bundle.main.bundleIdentifier, bundleURL: URL = Bundle.main.bundleURL,
         isFrontmost: (() -> Bool)? = nil, reveal: (([URL]) -> Void)? = nil,
         muted: Bool = MutedLaunch.isEnabled, playSound: (() -> Void)? = nil, openURL: ((URL) -> Bool)? = nil) {
        self.notifications = notifications
            ?? (useSystemNotifications ? SystemExportNotifications.system(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL) : nil)
        self.bundleIdentifier = bundleIdentifier
        self.isFrontmost = isFrontmost ?? { NSApplication.shared.isActive }
        self.reveal = reveal ?? { NSWorkspace.shared.activateFileViewerSelecting($0) }
        self.muted = muted
        self.playSound = playSound ?? { NSSound(named: "Glass")?.play() }
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
    }

    /// Call once when an export has written `output`, a file or a folder. `title` heads the
    /// notification, for example "Export finished". Never asks for notification permission.
    func exportFinished(_ output: URL, title: String, reveal: Bool, notify: Bool, playSound: Bool) {
        Task { await finish(output, title: title, reveal: reveal, notify: notify, playSound: playSound) }
    }

    @discardableResult
    func finish(_ output: URL, title: String, reveal: Bool, notify: Bool, playSound: Bool) async -> Outcome {
        var outcome = Outcome()
        // Read before revealing, which brings Finder forward.
        let frontmost = isFrontmost()
        if playSound, !muted {
            self.playSound()
            outcome.playedSound = true
        }
        if reveal, FileManager.default.fileExists(atPath: output.path) {
            self.reveal([output])
            outcome.revealed = true
        }
        if notify, !frontmost, let notifications, await notifications.authorization() == .authorized {
            outcome.notified = await notifications.post(title: title, body: output.lastPathComponent)
        }
        return outcome
    }

    /// For the Notify row in Settings.
    func notificationAuthorization() async -> ExportNotificationAuthorization {
        await notifications?.authorization() ?? .unavailable
    }

    /// Call only when the editor turns Notify on in Settings, never from an agent, a launch
    /// argument or app launch.
    func requestNotificationPermission() async -> ExportNotificationAuthorization {
        await notifications?.requestAuthorization() ?? .unavailable
    }

    static func notificationSettingsURL(bundleIdentifier: String?) -> URL {
        var text = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let bundleIdentifier, !bundleIdentifier.isEmpty,
           let id = bundleIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            text += "?id=" + id
        }
        return URL(string: text)!
    }

    /// Opens MPCut's page in System Settings → Notifications, for a denied permission.
    @discardableResult
    func openNotificationSettings() -> Bool {
        openURL(Self.notificationSettingsURL(bundleIdentifier: bundleIdentifier))
    }
}

extension ExportCompletion {
    nonisolated static let finishedTitle = "Export finished"

    /// Settings → Export → When an export finishes, for an export the editor started. Does nothing while every
    /// action is off, so the shared service is reached only when one is on.
    static func runActions(for output: URL, preferences: EditorPreferences, title: String = finishedTitle,
                           using completion: ExportCompletion? = nil) {
        let reveal = preferences.revealsFinishedExport
        let notify = preferences.notifiesFinishedExport
        let sound = preferences.playsFinishedExportSound
        guard reveal || notify || sound else { return }
        (completion ?? shared).exportFinished(output, title: title, reveal: reveal, notify: notify, playSound: sound)
    }
}
