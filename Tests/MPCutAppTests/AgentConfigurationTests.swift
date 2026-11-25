import Foundation
import XCTest
@testable import MPCutApp

final class AgentConfigurationTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/MPCut.app", isDirectory: true)

    func testHelperAndCLIPathsInsideTheBundle() {
        XCTAssertEqual(AgentConfiguration.helperURL(bundleURL: app)?.path, "/Applications/MPCut.app/Contents/Helpers/mpcut-mcp")
        XCTAssertEqual(AgentConfiguration.cliURL(bundleURL: app, executableURL: app.appendingPathComponent("Contents/MacOS/MPCut"))?.path,
                       "/Applications/MPCut.app/Contents/Helpers/mpcut")
    }

    func testSwiftPMBuildUsesTheSiblingCLIAndHasNoHelper() {
        let products = URL(fileURLWithPath: "/tmp/build/debug", isDirectory: true)
        XCTAssertNil(AgentConfiguration.helperURL(bundleURL: products))
        XCTAssertEqual(AgentConfiguration.cliURL(bundleURL: products, executableURL: products.appendingPathComponent("MPCutDesktop"))?.path,
                       "/tmp/build/debug/mpcut")
        XCTAssertNil(AgentConfiguration.cliURL(bundleURL: products, executableURL: nil))
    }

    func testSnippetMatchesTheAgentGuide() throws {
        let helper = try XCTUnwrap(AgentConfiguration.helperURL(bundleURL: app))
        XCTAssertEqual(AgentConfiguration.json(helper: helper), """
            {
              "mcpServers": {
                "mpcut": {
                  "command": "/Applications/MPCut.app/Contents/Helpers/mpcut-mcp",
                  "args": []
                }
              }
            }
            """)
    }

    func testSnippetIsTheGuideBlockVerbatim() throws {
        // The guide sits three levels above this file in the source tree.
        let guide = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/MCP-AGENT-GUIDE.md")
        guard let text = try? String(contentsOf: guide, encoding: .utf8) else { throw XCTSkip("Agent guide not found") }
        let helper = try XCTUnwrap(AgentConfiguration.helperURL(bundleURL: app))
        XCTAssertTrue(text.contains("```json\n" + AgentConfiguration.json(helper: helper) + "\n```"))
    }

    func testPathWithSpacesAndQuotesStaysOneValidString() throws {
        let odd = URL(fileURLWithPath: "/Users/me/Apps \"Beta\"/MPCut \\ Test.app", isDirectory: true)
        let helper = try XCTUnwrap(AgentConfiguration.helperURL(bundleURL: odd))
        let data = Data(AgentConfiguration.json(helper: helper).utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let server = try XCTUnwrap((object["mcpServers"] as? [String: Any])?["mpcut"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, helper.path)
        XCTAssertEqual((server["args"] as? [Any])?.count, 0)
    }
}
