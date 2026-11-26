import AppKit
import SwiftUI

struct SettingsAutomationPage: View {
    @ObservedObject var preferences: EditorPreferences
    var bundleURL: URL = Bundle.main.bundleURL
    var executableURL: URL? = Bundle.main.executableURL
    @State private var copied: SettingsRow?
    @State private var copiedReset: Task<Void, Never>?

    private static func executable(_ url: URL?) -> URL? {
        url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    private var cliURL: URL? { Self.executable(AgentConfiguration.cliURL(bundleURL: bundleURL, executableURL: executableURL)) }
    private var helperURL: URL? { Self.executable(AgentConfiguration.helperURL(bundleURL: bundleURL)) }

    var body: some View {
        SettingsForm(page: .automation, preferences: preferences) {
            Section {
                // A plain form switch, like every other: its own title is its one accessibility label.
                Toggle(SettingsRow.localMCP.title, isOn: $preferences.localMCPEnabled)
                    .settingsRow(.localMCP)
                    .help("Let programs running on this Mac read and edit open projects and process media files through MPCut.")
                LabeledContent("Status", value: preferences.localMCPStatus)
                    .accessibilityIdentifier("settings.automation.local-mcp.status")
            } header: {
                Text("Local control")
            } footer: {
                SettingsFootnote("When this is on, programs running under your Mac account can read and edit open projects and process media files through MPCut. A client set up with `--files-only` works on files through the bundled command-line tool and does not need this switch. The Grok connector, while its launcher runs, accepts connections only from this Mac, at 127.0.0.1:8472, and only with its key.")
            }
            Section {
                path(.cliPath, cliURL, missing: "Not found next to this copy of MPCut.", noun: "the mpcut command-line tool")
                path(.helperPath, helperURL, missing: "Not found in this copy of MPCut. The MCP helper ships inside the MPCut app.",
                     noun: "the MCP helper")
                HStack {
                    Button(SettingsRow.agentGuide.title) { NSWorkspace.shared.open(MPCutDocument.agentGuide.url) }
                        .settingsRow(.agentGuide)
                        .help("Open the MPCut agent guide.")
                    Spacer()
                    Button(copied == .agentConfiguration ? "Agent Configuration Copied" : SettingsRow.agentConfiguration.title) {
                        if let helperURL { copy(AgentConfiguration.json(helper: helperURL), row: .agentConfiguration) }
                    }
                    .disabled(helperURL == nil)
                    .settingsRow(.agentConfiguration)
                    .help(helperURL == nil
                          ? "There is nothing to copy: the MCP helper was not found in this copy of MPCut."
                          : "Copy the configuration an MCP host such as Claude Code or Codex needs to start MPCut’s MCP helper.")
                }
            } header: {
                Text("Agent setup")
            } footer: {
                SettingsFootnote("Paste the configuration into an MCP host such as Claude Code or Codex. The CLI does not read these settings, so scripts get the same result on every Mac.")
            }
            Section {
                Toggle(SettingsRow.agentSettings.title, isOn: $preferences.agentsChangeSettings)
                    .settingsRow(.agentSettings)
                    .help("Let agents change MPCut settings. Agents can always read them.")
                Toggle(SettingsRow.agentReplace.title, isOn: $preferences.agentsReplaceFiles)
                    .settingsRow(.agentReplace)
                    .help("Let agents save over existing project files when they ask to.")
            } header: {
                Text("Agent permissions")
            } footer: {
                SettingsFootnote("With settings changes off, agents read every setting and change none. Under `--files-only`, the command-line tool is not gated and can still change where cutcaches are saved. With replacing off, agents cannot save over another existing project or update a saved project in place through the app. Agent edits are labeled in Project History.")
            }
        }
    }

    /// A path row: the path as every Settings path shows, and Copy. The path and the button each have their own
    /// identifier, the row's with `.path` and `.copy`; the row's own identifier stays free for search to scroll to.
    @ViewBuilder private func path(_ row: SettingsRow, _ url: URL?, missing: String, noun: String) -> some View {
        LabeledContent(row.title) {
            if let url {
                VStack(alignment: .trailing, spacing: 4) {
                    SettingsPathText(path: url.path)
                        .accessibilityIdentifier(row.id + ".path")
                    Button(copied == row ? "Copied" : "Copy") { copy(url.path, row: row) }
                        .help("Copy the path of \(noun).")
                        .accessibilityLabel("Copy the path of \(noun)")
                        .accessibilityIdentifier(row.id + ".copy")
                }
            } else {
                Text(missing).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(row.id + ".missing")
            }
        }
        .settingsRow(row, identifier: false)
    }

    /// Copies `text` and says so on the button for a few seconds.
    private func copy(_ text: String, row: SettingsRow) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        copied = row
        copiedReset?.cancel()
        copiedReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            copied = nil
        }
    }
}
