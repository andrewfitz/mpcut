"""Package desktop connectors from the shared MPCut skill and helper configuration."""

import fcntl
import json
import re
import shlex
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins/mpcut"
DIST = ROOT / "dist/desktop-plugins"


def package_grok(config, version, output):
    # Grok accepts Markdown attachments. Inline the shared references so the
    # model can use the entire workflow without a local plugin filesystem.
    skill = PLUGIN / "skills/mpcut-editing"
    guide = (skill / "SKILL.md").read_text().split("---\n", 2)[2].strip()
    for reference in sorted((skill / "references").glob("*.md")):
        guide += "\n\n" + reference.read_text().strip()
    guide = re.sub(r"\[([^\]]+)\]\((?:references/)?[\w-]+\.md\)", r"\1", guide)
    with tempfile.TemporaryDirectory(dir=output) as temp:
        stage = Path(temp)
        subprocess.run([ROOT / "scripts/build-mcp-helper.sh", stage, version], check=True)
        guide += "\n\n## Available tools"
        for catalog in sorted((stage / "Resources/MCPTools").glob("*.json")):
            names = sorted(tool["name"] for tool in json.loads(catalog.read_text()))
            guide += f"\n\n**{catalog.stem.title()}**\n\n" + ", ".join(f"`{name}`" for name in names)
        binary = stage / "Helpers/mpcut-mcp"
        subprocess.run(["codesign", "--force", "--sign", "-", binary], check=True)
        notices = stage / "Resources/MCPNotices"
        package = stage / "MPCut-Grok.zip"
        with ZipFile(package, "w", ZIP_DEFLATED) as archive:
            archive.write(binary, "mpcut-grok-connector")
            for path in sorted(notices.rglob("*")):
                if path.is_file():
                    archive.write(path, Path("Notices") / path.relative_to(notices))
            for name in ["Start MPCut Connector.command", "Setup.md"]:
                archive.write(ROOT / "packaging/grok" / name, name)
            archive.writestr("helper-path.txt", config["command"] + "\n")
            archive.writestr("MPCut Editing.md", guide + "\n")
        package.replace(output / package.name)


def package_plugins(output):
    manifest = Path(".claude-plugin/plugin.json")
    metadata = json.loads((PLUGIN / manifest).read_text())
    config = json.loads((PLUGIN / ".mcp.json").read_text())["mcpServers"]["mpcut"]
    skill_files = sorted(path.relative_to(PLUGIN) for path in (PLUGIN / "skills").rglob("*.md"))
    with ZipFile(output / "MPCut.plugin", "w", ZIP_DEFLATED) as archive:
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
    with ZipFile(output / "MPCut.mcpb", "w", ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(extension, indent=2) + "\n")
        archive.writestr(entry, f"#!/bin/sh\nexec {command}\n")

    package_grok(config, metadata["version"], output)


def main():
    DIST.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=DIST) as temp:
        output = Path(temp)
        package_plugins(output)
        with (DIST / ".publish.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            for archive in output.iterdir():
                archive.replace(DIST / archive.name)


if __name__ == "__main__":
    main()
