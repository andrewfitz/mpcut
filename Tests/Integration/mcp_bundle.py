"""Verify the shipped July MCP endpoint without connecting to an editing session."""

import json
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "docs"))
from mcp_walkthrough import Client

PROTOCOL_VERSION = "2026-07-28"
DOCUMENTATION = {"agent-guide": "MCP-AGENT-GUIDE.md", "tool-reference": "MCP-REFERENCE.md", "headless": "HEADLESS.md"}


def check_bundle(app):
    if not __debug__:
        raise SystemExit("MPCut bundle verification requires Python assertions. Run without -O or PYTHONOPTIMIZE.")

    contents = app / "Contents"
    resources = contents / "Resources"
    with (contents / "Info.plist").open("rb") as info_file:
        info = plistlib.load(info_file)
    version = info["CFBundleShortVersionString"]
    assert info["CFBundleVersion"] == version, info["CFBundleVersion"]

    bundled_catalog = {path.name: path for path in (resources / "MCPTools").glob("*.json")}
    source_catalog = {path.name: path for path in (ROOT / "Sources/MPCutApp/MCPResources").glob("*.json")}
    assert bundled_catalog.keys() == source_catalog.keys(), bundled_catalog.keys() ^ source_catalog.keys()
    expected = {}
    for filename, source_path in source_catalog.items():
        descriptor = bundled_catalog[filename].read_bytes()
        assert descriptor == source_path.read_bytes(), filename
        for tool in json.loads(descriptor):
            assert tool["name"] not in expected, tool["name"]
            expected[tool["name"]] = tool
    assert {"project_windows_list", "project_editor_state_read", "timeline_item_split"} <= expected.keys()

    for name in ("Go-LICENSE", "Go-PATENTS", "github.com/modelcontextprotocol/go-sdk/LICENSE"):
        assert (resources / "MCPNotices" / name).stat().st_size > 0, name

    sequence = 0
    with tempfile.TemporaryDirectory() as working_directory:
        environment = {"PATH": "/usr/bin:/bin", "HOME": working_directory}
        cli_version = subprocess.check_output(
            [contents / "Helpers" / "mpcut", "--version"],
            cwd=working_directory, env=environment, text=True, timeout=5,
        ).strip()
        assert cli_version == version, cli_version
        process = subprocess.Popen(
            [contents / "Helpers" / "mpcut-mcp"], cwd=working_directory,
            env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )

        def call(method, **arguments):
            nonlocal sequence
            sequence += 1
            arguments["_meta"] = {
                "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
                "io.modelcontextprotocol/clientCapabilities": {},
            }
            request = {"jsonrpc": "2.0", "id": sequence, "method": method, "params": arguments}
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            response = json.loads(process.stdout.readline())
            assert response["id"] == sequence and "result" in response, response
            result = response["result"]
            assert result["resultType"] == "complete", response
            server_info = result["_meta"]["io.modelcontextprotocol/serverInfo"]
            assert server_info["name"] == "mpcut" and server_info["version"] == version, server_info
            return result

        try:
            # List directly first to exercise July stateless requests without discovery.
            tools = {}
            query = {}
            while True:
                page = call("tools/list", **query)
                for tool in page["tools"]:
                    assert tool["name"] not in tools, tool["name"]
                    tools[tool["name"]] = tool
                if not page.get("nextCursor"):
                    break
                query = {"cursor": page["nextCursor"]}
            assert tools.keys() == expected.keys(), tools.keys() ^ expected.keys()
            for name, descriptor in expected.items():
                for key, value in descriptor.items():
                    actual = tools[name][key]
                    if key == "annotations":
                        # The SDK may supply defaults for omitted annotations.
                        assert all(actual.get(hint) == setting for hint, setting in value.items()), name
                    else:
                        assert actual == value, (name, key)

            invalid = call("tools/call", name="project_editor_state_read", arguments={})
            assert invalid["isError"], invalid
            discover = call("server/discover")
            assert PROTOCOL_VERSION in discover["supportedVersions"], discover

            for slug, filename in DOCUMENTATION.items():
                uri = "mpcut://docs/" + slug
                document = resources / "Documentation" / "docs" / filename
                assert document.read_bytes() == (ROOT / "docs" / filename).read_bytes(), filename
                response = call("resources/read", uri=uri)
                assert response["contents"] == [{
                    "uri": uri, "mimeType": "text/markdown", "text": document.read_text(encoding="utf-8"),
                }], uri
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise
        assert process.returncode == 0, process.returncode
        # Exercise bundle-relative lookup for both child processes before publication.
        client = Client(contents / "Helpers" / "mpcut-mcp", "--files-only", env=environment)
        try:
            job = client.call("cli_version_read", operation_id=str(uuid.uuid4()))
            while job["state"] in ("running", "cancelling"):
                time.sleep(0.05)
                job = client.call("file_job_status_read", job_id=job["job_id"])
            assert job["state"] == "succeeded" and job["result"]["version"] == version, job
        finally:
            client.close()
        assert client.process.returncode == 0, client.process.returncode
    print(f"Verified MPCut {version}, {len(expected)} packaged tools and {len(DOCUMENTATION)} offline documentation resources.")


def time_limit(_signal, _frame):
    raise TimeoutError("Packaged MCP helper did not respond within 30 seconds")


if __name__ == "__main__":
    # Bound an unresponsive helper during a release build, including a blocked read.
    signal.signal(signal.SIGALRM, time_limit)
    signal.alarm(30)
    check_bundle(Path(sys.argv[1]).resolve())
