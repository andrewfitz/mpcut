import AppKit
import MPCutCore
import SwiftUI

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About MPCut") { openWindow(id: "about") }
                .help("Show app information")
        }
        CommandGroup(replacing: .help) {
            Button("MPCut User Guide") { NSWorkspace.shared.open(MPCutDocument.guide.url) }
                .keyboardShortcut("?", modifiers: .command)
                .help("Open user guide")
            Button("MPCut Agent Guide") { NSWorkspace.shared.open(MPCutDocument.agentGuide.url) }
                .help("Open agent guide")
            Button("Release Notes") { NSWorkspace.shared.open(MPCutDocument.releaseNotes.url) }
                .help("Open release notes")
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
    @State private var openError: NSError?

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
                documentLink("User guide", to: MPCutDocument.guide.url)
                documentLink("Release notes", to: MPCutDocument.releaseNotes.url)
                if let credits = Bundle.main.url(forResource: "Credits", withExtension: "html") {
                    documentLink("Credits", to: credits)
                }
            }
            if let cliURL {
                Divider()
                Text("Command-line help").font(.headline)
                Text(cliURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                (Text("Run ") + Text("mpcut help --json").font(.system(.callout, design: .monospaced)) + Text(" to list commands."))
                    .font(.callout)
                Button(copied ? "CLI Path Copied" : "Copy CLI Path") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    copied = pasteboard.setString(cliURL.path, forType: .string)
                }
                .help("Copy CLI path")
            }
        }
        .padding(26)
        .frame(width: 380)
        .alert("Couldn’t open the document", isPresented: Binding(
            get: { openError != nil }, set: { if !$0 { openError = nil } }
        )) {
            Button("OK") { openError = nil }
                .help("Dismiss error")
        } message: {
            Text(openError?.localizedDescription ?? "")
        }
    }

    private func documentLink(_ title: String, to url: URL) -> some View {
        Button(title) {
            NSWorkspace.shared.open(url, configuration: .init()) { _, error in
                if let error { DispatchQueue.main.async { openError = error as NSError } }
            }
        }
        .buttonStyle(.link)
        .help("Open \(title.lowercased())")
    }
}
