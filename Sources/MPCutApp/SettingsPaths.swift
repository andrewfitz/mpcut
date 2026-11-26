import AppKit
import SwiftUI

/// How Settings writes paths and sizes, and how it asks for a file or folder. One place, so every page shows them alike.
enum SettingsPath {
    /// A path with the home folder written as `~`.
    static func display(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// A byte count for the pages and their messages, written "0 KB" rather than "Zero KB".
    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Asks for a folder, or with `files` a file, in a standalone panel: as a sheet it is wider than the Settings
    /// window and hangs off its edge.
    @MainActor static func choose(title: String, message: String? = nil, files: Bool = false, canCreateFolders: Bool = false,
                                  packagesAsFolders: Bool = false, startingIn folder: URL? = nil,
                                  chosen: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        if let message { panel.message = message }
        panel.prompt = "Choose"
        panel.canChooseFiles = files
        panel.canChooseDirectories = !files
        panel.canCreateDirectories = canCreateFolders
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = packagesAsFolders
        panel.directoryURL = folder
        ProjectPanels.present(panel, in: nil) { accepted in
            if accepted, let url = panel.url { chosen(url) }
        }
    }
}

/// A path as a row's value: the whole path, wrapping where it does not fit (after a slash where it can), selectable.
/// It holds the path's characters only, so a selection copies the path exactly: no invisible break characters and no
/// status, which a row shows as a text of its own. A path shown with `~` has its full form as the tooltip, which
/// VoiceOver reads once, as the help; a path shown in full has no tooltip repeating it. Selectable text takes no
/// `accessibilityLabel` of its own: SwiftUI then resolves the label through itself without end.
struct SettingsPathText: View {
    let path: String
    var alignment: TextAlignment = .trailing

    var body: some View {
        let text = Text(SettingsPath.display(path))
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        if let help = Self.help(for: path) { text.help(help) } else { text }
    }

    /// The tooltip: the full path, only when the text shows it shortened.
    static func help(for path: String) -> String? { SettingsPath.display(path) == path ? nil : path }
}
