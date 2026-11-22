"""Build Claude desktop downloads from the same skill and launch config as Codex."""

import json
import shlex
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins/mpcut"
DIST = ROOT / "dist/desktop-plugins"


def main():
    DIST.mkdir(parents=True, exist_ok=True)
    manifest = Path(".claude-plugin/plugin.json")
    metadata = json.loads((PLUGIN / manifest).read_text())
    config = json.loads((PLUGIN / ".mcp.json").read_text())["mcpServers"]["mpcut"]
    skill_files = sorted(path.relative_to(PLUGIN) for path in (PLUGIN / "skills").rglob("*.md"))
    with ZipFile(DIST / "MPCut.plugin", "w", ZIP_DEFLATED) as archive:
        for path in [manifest, Path(".mcp.json"), *skill_files]:
            archive.write(PLUGIN / path, path)

    # Desktop Chat loads local tools through an extension. Run the installed
    # helper in place so it can find the matching app's catalog and resources.
    entry = "server/launch.sh"
    extension = {
        "manifest_version": "0.3",
        "name": metadata["name"],
        "display_name": "MPCut",
        "version": metadata["version"],
        "description": metadata["description"],
        "author": metadata["author"],
        "compatibility": {"platforms": ["darwin"]},
        "tools_generated": True,
        "server": {
            "type": "binary",
            "entry_point": entry,
            "mcp_config": {"command": "/bin/sh", "args": ["${__dirname}/" + entry]},
        },
    }
    command = shlex.join([config["command"], *config["args"]])
    with ZipFile(DIST / "MPCut.mcpb", "w", ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(extension, indent=2) + "\n")
        archive.writestr(entry, f"#!/bin/sh\nexec {command}\n")


if __name__ == "__main__":
    main()
