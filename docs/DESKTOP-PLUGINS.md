# Edit with MPCut in a desktop conversation

Install a helper-enabled build of **MPCut.app** in **/Applications** on your Apple Silicon Mac. Launch it and turn on **Settings → General → Automation → Enable local MCP control**. The desktop plugin starts the helper inside this copy of MPCut. The editor owns the timeline, media, undo history and exports.

## Install in your desktop app

| Where you work | GUI setup |
| --- | --- |
| Claude Desktop, Cowork | Open **Cowork → Customize → Plugins → Add → Upload plugin**. Select **MPCut.plugin**, then start a local Cowork task. The package includes the skill and a per-session MCP connection. [Claude plugin installation](https://claude.com/docs/plugins/overview) |
| Claude Desktop, Chat | Upload **MPCut.plugin** for the editing skill. To connect the tools in Chat, open **Settings → Desktop app → Extensions → Manage → Advanced settings → Install Extension** and select **MPCut.mcpb**. Enable the extension and start a new desktop chat. Older versions put Extensions directly under Settings. [Claude local extensions](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop) |
| ChatGPT Desktop, Work or Codex | Open this checkout as a local project in the desktop app. Restart the app after adding the repository marketplace. In **Plugins**, select the **MPCut Desktop** source, open **MPCut** and install it. Start a local thread and mention **@mpcut**. The repository supplies the plugin and its stdio connection. [OpenAI local marketplaces](https://developers.openai.com/plugins/build/plugins#build-your-own-curated-plugin-list) · [Desktop-only plugins](https://developers.openai.com/plugins/deploy/desktop-only) |

## Try it

Start with “List my open MPCut timelines and tell me which have unsaved edits.” An empty list is a successful connection to an editor with no windows. Seeing a skill in the menu only confirms its instructions loaded. If the host shows the skill but offers no MPCut tools, check the local session, plugin or extension listed above. If the tools report the app is unavailable, check the running app and its Automation setting.

With a project open, try “Show me the picture at the playhead,” “Find the long pauses in this interview and leave them in place for review,” or “Check whether this cut will export to a MOV using packet copy.” For an edit, specify the clock if it matters, for example “In Interview selects, split at 12 seconds on the edited timeline and leave it open.”

## Packaging and verification plan

1. Maintain one editing skill and one stdio launch configuration in [plugins/mpcut](../plugins/mpcut/). Both desktop plugins use the app-bundled helper so a new MPCut build supplies its own tool schemas and guides.
2. For a source build, run `python3 scripts/package-desktop-plugins.py` from the repository root to produce `dist/desktop-plugins/MPCut.plugin` and `MPCut.mcpb` in the same folder. The ChatGPT Desktop marketplace reads the source directory directly. If distributing a build with a different app location, change the command in [the shared connection](../plugins/mpcut/.mcp.json) and rebuild the Claude downloads.
3. Test discovery and a read in each desktop surface. With a disposable sequence, ask for a frame, split inside a clip, check the actual boundary in MPCut and undo it. Preflight a copy export and check the returned eligibility. Request an export to a fresh destination, wait for the job and open the result. Record the desktop app version and workflow outcome for each host before claiming end-to-end support.

The first local check passed Claude's plugin validator and the MCPB manifest schema. ChatGPT Desktop's bundled Codex 0.169.1 backend listed the plugin for this checkout. Both packaged launch commands discovered 83 tools and read an open timeline. The installed helper lacked the still-placement tools in the source tree. Installation, edits and exports through the conversation UIs remain to be tested.

For the full workflow catalog and recovery behavior, see the [MPCut agent guide](MCP-AGENT-GUIDE.md).
