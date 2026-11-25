# Edit with MPCut in a desktop conversation

Install a helper-enabled build of **MPCut.app** in **/Applications** on your Apple Silicon Mac. Launch it and turn on **Settings → General → Automation → Enable local MCP control**. Local control starts off in 2.0, including after an upgrade from 1.x. The desktop plugin starts the helper inside this copy of MPCut. The editor owns the timeline, media, undo history and exports.

## Install in your desktop app

| Where you work | GUI setup |
| --- | --- |
| Claude Desktop, Cowork | Open **Cowork → Customize → Plugins → Add → Upload plugin**. Select **MPCut.plugin**, then start a local Cowork task. The package includes the skill and a per-session MCP connection. [Claude plugin installation](https://claude.com/docs/plugins/overview) |
| Claude Desktop, Chat | Upload **MPCut.plugin** for the editing skill. To connect the tools in Chat, open **Settings → Desktop app → Extensions → Manage → Advanced settings → Install Extension** and select **MPCut.mcpb**. Enable the extension and start a new desktop chat. Older versions put Extensions directly under Settings. [Claude local extensions](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop) |
| ChatGPT Desktop, Work or Codex | Open this checkout as a local project in the desktop app. Restart the app after adding the repository marketplace. In **Plugins**, select the **MPCut Desktop** source, open **MPCut** and install it. Start a local thread and mention **@mpcut**. The repository supplies the plugin and its stdio connection. [OpenAI local marketplaces](https://developers.openai.com/plugins/build/plugins#build-your-own-curated-plugin-list) · [Desktop-only plugins](https://developers.openai.com/plugins/deploy/desktop-only) |

**Grok and Grok Bot** use the **MPCut-Grok.zip** download. Expand it on the editing Mac. It includes a Finder launcher, the HTTPS connector setup for each host, and a self-contained copy of the shared skill to attach in Grok or save as a private skill in Grok Bot. The bridge binds to loopback and requires a bearer key. Connect your own HTTPS route for remote access. [Grok setup](../packaging/grok/Setup.md)

For a checkout build, the packaged application is `dist/MPCut.app` and the desktop downloads are in `dist/desktop-plugins/`. The default desktop configuration launches the helper in Applications. To identify the build that connection actually uses, collect the result of `cli_version_read` and compare its `build_id` with `dist/MPCut.app/Contents/Helpers/mpcut --version --json`. A result containing only `version` comes from an older CLI. [Build and installation](../README.md#build-from-source)

## Try it

Start with “List my open MPCut timelines and tell me which have unsaved edits.” An empty list is a successful connection to an editor with no windows. Seeing a skill in the menu only confirms its instructions loaded. If the host shows the skill but offers no MPCut tools, check the local session, plugin or extension listed above. If the tools report the app is unavailable, check the running app and its Automation setting.

With a project open, try “Show me the picture at the playhead,” “Find the long pauses in this interview and leave them in place for review,” or “Check whether this cut will export to a MOV using packet copy.” For an edit, specify the clock if it matters, for example “In Interview selects, split at 12 seconds on the edited timeline and leave it open.”

For a review or delivery task, try “Show me every place this source interval appears in the current cut,” “Check picture and microphone coverage if I switch to Wide at 12 seconds group time,” or “Tell me which files and trims the first queued excerpt contains.”

## Check the connection

Compare the host’s `tools/list` response with the installed reference. Read the advertised schemas and check that the host can retrieve the agent guide and tool reference. Some saved-file operations, including creating or revising a saved still placement, use the bundled CLI. [Tool reference](MCP-REFERENCE.md) · [File workflows and CLI options](../plugins/mpcut/skills/mpcut-editing/references/files.md)

For unattended review of saved cuts, a local stdio host can register a separate `--files-only` connection. It exposes file jobs and their documentation independently of the desktop editor. [Headless setup](HEADLESS.md)

Local tests cover helper discovery, reads, editing and export. The Grok bridge test also checks bearer authentication and JPEG responses. Installation and editing in each desktop conversation UI, and the remote xAI account connection, still need host-level verification. [MCP integration coverage](MCP-COVERAGE.md)

## Build the plugin packages

Run `python3 scripts/package-desktop-plugins.py` from the repository root. It writes `MPCut.plugin`, `MPCut.mcpb` and `MPCut-Grok.zip` to `dist/desktop-plugins/`. The ChatGPT Desktop marketplace reads [the plugin source](../plugins/mpcut/) directly. If MPCut lives outside Applications, update [the shared connection](../plugins/mpcut/.mcp.json) before packaging.

To test the packaged Grok bridge locally, run the following from the checkout. Add `--live` with a build supporting isolated test sockets to exercise an edit.

```sh
python3 Tests/Integration/grok_connector.py dist/desktop-plugins/MPCut-Grok.zip /Applications/MPCut.app
```
