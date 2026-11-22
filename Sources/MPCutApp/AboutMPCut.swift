import AppKit
import MPCutCore
import SwiftUI

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About MPCut") { openWindow(id: "about") }
        }
        CommandGroup(replacing: .help) {
            Button("MPCut User Guide") { NSWorkspace.shared.open(MPCutDocument.guide.url) }
                .keyboardShortcut("?", modifiers: .command)
            Button("MPCut Agent Guide") { NSWorkspace.shared.open(MPCutDocument.agentGuide.url) }
            Button("Release Notes") { NSWorkspace.shared.open(MPCutDocument.releaseNotes.url) }
        }
    }
}

enum MPCutDocument: String {
    case guide = "docs/USAGE"
    case agentGuide = "docs/MCP-AGENT-GUIDE"
    case releaseNotes = "CHANGELOG"

    var url: URL {
        if let local = Bundle.main.url(forResource: rawValue, withExtension: "md", subdirectory: "Documentation") {
            return local
        }
        return URL(string: "https://github.com/andrewfitz/mpcut/blob/main/")!
            .appendingPathComponent(rawValue).appendingPathExtension("md")
    }
}

struct AboutMPCut: View {
    @State private var copied = false

    private var cliURL: URL? {
        let bundle = Bundle.main
        let candidates = [bundle.bundleURL.appendingPathComponent("Contents/Helpers/mpcut"),
                          bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("mpcut")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("MPCut").font(.largeTitle.bold())
            Text("Version \(MPCutRelease.version)").foregroundStyle(.secondary)
            Text("Trim, rearrange, and analyze local video and audio on Apple Silicon.")
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("User guide", destination: MPCutDocument.guide.url)
                Link("Release notes", destination: MPCutDocument.releaseNotes.url)
                if let credits = Bundle.main.url(forResource: "Credits", withExtension: "html") {
                    Link("Credits", destination: credits)
                }
            }
            if let cliURL {
                Divider()
                Text("Command-line help").font(.headline)
                Text(cliURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text("Run the CLI with help --json to list commands.")
                    .font(.callout)
                Button(copied ? "CLI Path Copied" : "Copy CLI Path") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    copied = pasteboard.setString(cliURL.path, forType: .string)
                }
                .help(cliURL.path)
            }
        }
        .padding(26)
        .frame(width: 380)
    }
}
