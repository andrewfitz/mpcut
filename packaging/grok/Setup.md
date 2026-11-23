# Connect MPCut to Grok or Grok Bot

On the Mac with the footage, open MPCut and enable **Settings → General → Automation → Enable local MCP control**. Local control starts off again after upgrading from 1.x to 2.0. The default app location is `/Applications/MPCut.app`. For another location, edit the absolute path in the accompanying `helper-path.txt`.

1. Expand the ZIP on the editing Mac. Double-click **Start MPCut Connector.command** in Finder. The launcher starts the included Apple Silicon connector and prints the location of the connector key file. The key stays on this Mac until you enter it in your connector's credential settings.
2. Route a reachable HTTPS endpoint to **http://127.0.0.1:8472** on that Mac, preserving the **/mpcut/mcp** path and the Authorization header. Set the upstream Host header to `127.0.0.1:8472`. For example, with ngrok installed and configured, `ngrok http 8472 --host-header=rewrite` gives you a forwarding URL. Append `/mpcut/mcp` to that URL. Keep the bridge and HTTPS route running while you edit. [Grok's tunnel setup](https://docs.x.ai/grok/connectors/custom-mcp-tunneling)
3. Configure the connector in the surface you use.

| Surface | Setup |
| --- | --- |
| **Grok** | Open **Connectors → New Connector → Custom** and enter the HTTPS endpoint. Where a bearer-token field is available, enter the key from the file. If your account offers OAuth only, use an OAuth-protected HTTPS gateway that validates the caller and supplies the bridge's bearer credential upstream. Attach **MPCut Editing.md** to the editing conversation. [Grok connectors](https://docs.x.ai/grok/connectors) |
| **Grok Bot desktop** | Open **Connect apps → Add a custom connector**. Name it **MPCut**, choose **Remote HTTPS**, and enter the endpoint. Add an HTTP header named `Authorization` with value `Bearer ` followed by the key. Choose **Add plugin** and attach the app with **@**. Attach **MPCut Editing.md** and ask the Bot to save its instructions as a private skill named **MPCut Editing**. The Bot's Command connector runs on its own computer, so the editor’s app path belongs in the connector on your Mac. [Grok Bot connectors](https://docs.x.ai/grok-bot/computer-and-apps) · [Private skills](https://docs.x.ai/grok-bot/skills-routines-and-automations) |

Enter credentials using the connector or gateway settings. The Markdown attachment contains only editing instructions. Anyone holding the key and endpoint can invoke the editor's enabled MCP tools. Stopping the bridge disconnects Grok. To rotate the key, stop the bridge, remove its key file on the Mac, restart it and update the connector credential.

Keep the key in a regular file with permissions `600`. If the launcher reports that the file is too broadly accessible, rotate the key.

Start with “List my open MPCut projects and tell me which have unsaved edits.” An empty list confirms the Mac responded. With a timeline open, try “Show the picture at my playhead” or “Check whether this edit will export with packet copy.” A file path in a tool result is on the editing Mac. For CLI-only capabilities the host would also need separately authorized execution on that Mac.
