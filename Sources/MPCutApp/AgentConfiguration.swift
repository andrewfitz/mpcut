import Foundation

/// Paths and the paste-ready host configuration for the Automation page.
enum AgentConfiguration {
    /// The stdio MCP helper ships only inside an app bundle. Callers check that it is executable.
    static func helperURL(bundleURL: URL) -> URL? {
        guard bundleURL.pathExtension == "app" else { return nil }
        return bundleURL.appendingPathComponent("Contents/Helpers/mpcut-mcp")
    }

    /// The rule file jobs use: an app bundle runs its bundled CLI, and a SwiftPM build its sibling
    /// `mpcut`. Callers check that it is executable.
    static func cliURL(bundleURL: URL, executableURL: URL?) -> URL? {
        bundleURL.pathExtension == "app" ? bundleURL.appendingPathComponent("Contents/Helpers/mpcut")
            : executableURL?.deletingLastPathComponent().appendingPathComponent("mpcut")
    }

    /// The `mcpServers` block from the agent guide with `helper` as the command.
    static func json(helper: URL) -> String {
        """
        {
          "mcpServers": {
            "mpcut": {
              "command": \(jsonString(helper.path)),
              "args": []
            }
          }
        }
        """
    }

    private static func jsonString(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text), let quoted = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return quoted
    }
}
