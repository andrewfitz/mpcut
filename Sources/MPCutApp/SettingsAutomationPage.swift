import AppKit
import SwiftUI

struct SettingsAutomationPage: View {
    @ObservedObject var preferences: EditorPreferences
    var bundleURL: URL = Bundle.main.bundleURL
    var executableURL: URL? = Bundle.main.executableURL
    @State private var copied: SettingsRow?

    private static func executable(_ url: URL?) -> URL? {
        url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    private var cliURL: URL? { Self.executable(AgentConfiguration.cliURL(bundleURL: bundleURL, executableURL: executableURL)) }
    private var helperURL: URL? { Self.executable(AgentConfiguration.helperURL(bundleURL: bundleURL)) }

    var body: some View {
        SettingsForm(page: .automation, preferences: preferences) {
            Section {
                Toggle(SettingsRow.localMCP.title, isOn: $preferences.localMCPEnabled)
                    .settingsRow(.localMCP)
                    .accessibilityLabel(SettingsRow.localMCP.title)
                    .help("Allow local MCP control")
                LabeledContent("Status", value: preferences.localMCPStatus)
                    .accessibilityIdentifier("settings.automation.local-mcp.status")
            } header: {
                Text("Local control")
            } footer: {
                SettingsFootnote("Programs running under your Mac account can read and edit projects and process media files. The switch gates open projects and file jobs that run through the app. A client configured with --files-only processes files through the bundled CLI without it. The Grok connector listens on 127.0.0.1:8472 with a bearer key while its launcher is running.")
            }
            Section {
                path(.cliPath, cliURL, missing: "The mpcut command is not next to this copy of MPCut.")
                path(.helperPath, helperURL, missing: "The MCP helper ships inside the MPCut app bundle.")
                HStack {
                    Button(SettingsRow.agentGuide.title) { NSWorkspace.shared.open(MPCutDocument.agentGuide.url) }
                        .settingsRow(.agentGuide)
                        .help("Open the MPCut agent guide")
                    Spacer()
                    Button(copied == .agentConfiguration ? "Agent Configuration Copied" : SettingsRow.agentConfiguration.title) {
                        if let helperURL { copy(AgentConfiguration.json(helper: helperURL), row: .agentConfiguration) }
                    }
                    .disabled(helperURL == nil)
                    .settingsRow(.agentConfiguration)
                    .help("Copy an mcpServers block that runs the MCP helper")
                }
            } header: {
                Text("Agent setup")
            } footer: {
                SettingsFootnote("Paste the configuration into an MCP host such as Claude Code or Codex. The CLI does not read these settings, so scripts get the same result on every Mac.")
            }
            Section {
                Toggle(SettingsRow.agentSettings.title, isOn: $preferences.agentsChangeSettings)
                    .settingsRow(.agentSettings)
                    .help("Allow agents to change MPCut settings")
                Toggle(SettingsRow.agentReplace.title, isOn: $preferences.agentsReplaceFiles)
                    .settingsRow(.agentReplace)
                    .help("Allow agents to replace existing project files")
            } header: {
                Text("Agent permissions")
            } footer: {
                SettingsFootnote("With settings changes off, agents read every setting and change none. Under --files-only, the CLI is not gated and can still change the cutcache location. With replacing off, agents cannot save over another existing project or update a saved project in place through the app. Agent edits are labelled in Project History.")
            }
        }
    }

    @ViewBuilder private func path(_ row: SettingsRow, _ url: URL?, missing: String) -> some View {
        LabeledContent(row.title) {
            if let url {
                HStack {
                    Text(url.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(url.path)
                    Button(copied == row ? "Copied" : "Copy") { copy(url.path, row: row) }
                        .help("Copy the path")
                        .accessibilityLabel("Copy \(row.title)")
                }
            } else {
                Text(missing).font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsRow(row)
    }

    private func copy(_ text: String, row: SettingsRow) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) { copied = row }
    }
}
