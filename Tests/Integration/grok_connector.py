"""Check the packaged Grok launcher, authentication and installed app catalog."""

import base64
from contextlib import ExitStack
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def request(method, params, key=None, **extra_headers):
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if key:
        headers["Authorization"] = "Bearer " + key
    message = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    req = Request("http://127.0.0.1:8472/mpcut/mcp", json.dumps(message).encode(), headers | extra_headers)
    with urlopen(req, timeout=60) as response:
        return json.load(response)["result"]


def check_edit(root, key, headers):
    def call(name, **arguments):
        result = request("tools/call", {"name": name, "arguments": arguments}, key, **headers)
        assert not result.get("isError"), (name, result.get("structuredContent"))
        return result

    clip = root / "media.mov"
    shutil.copyfile(Path(__file__).resolve().parents[1] / "MPCutAppTests/Fixtures/ProRes-2997.mov", clip)
    path = root / "Sample.cut"
    path.write_text(json.dumps({"format": "mpcut", "schema_version": 3, "kind": "sequence",
                                "clips": [{"id": "demo", "file": clip.name, "from": "0", "to": "1001/2500"}]}))
    handle = call("project_open", project_path=str(path), operation_id=str(uuid.uuid4()))["structuredContent"]["project_handle"]
    for _ in range(100):
        state = call("project_editor_state_read", project_handle=handle)["structuredContent"]
        if state["total"] == 1 and not state["busy"]:
            break
        time.sleep(0.1)
    frame = call("review_editor_frame_read", project_handle=handle, time="1001/30000", space="sequence")
    assert any(c["type"] == "image" and base64.b64decode(c["data"]).startswith(b"\xff\xd8") for c in frame["content"])
    exact = call("project_editor_state_read", project_handle=handle, offset=9007199254740993)
    assert json.loads(exact["content"][0]["text"])["offset"] == 9007199254740993
    edit = call("timeline_item_split", project_handle=handle, expected_revision=state["revision"], operation_id=str(uuid.uuid4()),
                occurrence=state["clips"][0]["id"], space="sequence", time="1001/6000")["structuredContent"]
    assert call("project_editor_state_read", project_handle=handle)["structuredContent"]["total"] == 2
    call("history_undo", project_handle=handle, expected_revision=edit["revision"], operation_id=str(uuid.uuid4()))
    assert call("project_editor_state_read", project_handle=handle)["structuredContent"]["total"] == 1
    job = call("media_file_inspect", file=str(clip), no_sidecar=True, operation_id=str(uuid.uuid4()))["structuredContent"]
    for _ in range(100):
        status = call("file_job_status_read", job_id=job["job_id"])["structuredContent"]
        if status["state"] == "succeeded":
            break
        assert status["state"] == "running", status
        time.sleep(0.1)
    else:
        raise TimeoutError("file inspection")
    print("Verified live JPEG, exact integer receipt, split, undo and CLI-backed file inspection.")


def check(package, app, live):
    contents = app / "Contents"
    expected = {t["name"]: t["inputSchema"] for path in (contents / "Resources/MCPTools").glob("*.json")
                for t in json.loads(path.read_text())}
    assert expected, "missing installed tool catalog"
    with tempfile.TemporaryDirectory(prefix="MPCut Grok QA ") as temp, ExitStack() as cleanup:
        root = Path(temp).resolve()
        subprocess.run(["unzip", "-q", package, "-d", root], check=True)
        (root / "helper-path.txt").write_text(str(contents / "Helpers/mpcut-mcp") + "\n")
        guide = (root / "MPCut Editing.md").read_text()
        assert all(f"`{name}`" in guide for name in expected)
        keys = root / "keys"
        env = os.environ | {"MPCUT_GROK_KEY_DIR": str(keys)}
        keys.mkdir(mode=0o700)
        key_file = keys / "bearer-token.txt"
        key_file.write_text("a" * 64 + "\n")
        key_file.chmod(0o644)
        unsafe = subprocess.run([root / "Start MPCut Connector.command"], env=env,
                                capture_output=True, text=True, timeout=5)
        assert unsafe.returncode != 0 and "private regular file" in unsafe.stderr, unsafe.stderr
        key_file.unlink()
        if live:
            # The editor and helper both validate this private test socket name.
            socket_dir = Path("/tmp") / ("mpcut-test-" + uuid.uuid4().hex)
            socket_dir.mkdir(mode=0o700)
            cleanup.callback(socket_dir.rmdir)
            domain = "com.mpcut.test-preferences." + socket_dir.name
            cleanup.callback(subprocess.run, ["/usr/bin/defaults", "delete", domain], stderr=subprocess.DEVNULL)
            for name in ["control.sock", "listener.lock"]:
                cleanup.callback((socket_dir / name).unlink, missing_ok=True)
            env.update(MPCUT_TEST_SOCKET_DIRECTORY=socket_dir.name, CFFIXED_USER_HOME=str(root))
            (root / "Library/Preferences").mkdir(parents=True)
            editor = subprocess.Popen([contents / "MacOS/MPCut", "-automation_local_mcp_enabled", "YES", "-history_max_steps", "20",
                                       "-timeline_snap_target", "off", "-analysis_sidecar_reuse_enabled", "NO",
                                       "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"], env=env)
            cleanup.callback(editor.wait, timeout=5)
            cleanup.callback(editor.kill)
            for _ in range(150):
                if (socket_dir / "control.sock").is_socket():
                    break
                time.sleep(0.1)
            else:
                raise TimeoutError("isolated test editor socket")
        launcher = subprocess.Popen([root / "Start MPCut Connector.command"],
                                    env=env)
        try:
            params = {"protocolVersion": "2025-06-18", "capabilities": {},
                      "clientInfo": {"name": "grok-parity", "version": "1"}}
            for _ in range(100):
                assert launcher.poll() is None, "launcher exited"
                try:
                    request("initialize", params)
                except HTTPError as error:
                    assert error.code == 401
                    break
                except URLError:
                    time.sleep(0.05)
                else:
                    raise AssertionError("unauthenticated connector access")
            else:
                raise TimeoutError("connector failed to start")
            assert key_file.stat().st_mode & 0o077 == 0
            key = key_file.read_text().strip()
            assert request("initialize", params, key)["protocolVersion"] == "2025-06-18"
            headers = {"MCP-Protocol-Version": "2025-06-18"}
            tools = {}
            page = {}
            while True:
                result = request("tools/list", page, key, **headers)
                tools.update({t["name"]: t["inputSchema"] for t in result["tools"]})
                if not result.get("nextCursor"):
                    break
                page = {"cursor": result["nextCursor"]}
            assert tools == expected
            for name in ["agent-guide", "tool-reference"]:
                uri = "mpcut://docs/" + name
                result = request("resources/read", {"uri": uri}, key, **headers)
                assert result["contents"][0]["text"]
            print(f"Verified authenticated HTTP discovery for all {len(tools)} tools and both guides.")
            if live:
                check_edit(root, key, headers)
        finally:
            launcher.terminate()
            launcher.wait(timeout=5)


if __name__ == "__main__":
    check(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), "--live" in sys.argv[3:])
