#!/usr/bin/env python3
"""Run the participant editor through macOS Accessibility with synthetic media.

The monitor check also uses Backstage's Screen Recording access.
Set MPCUT_GUI_REQUIRE_SCAN=1 to verify that TileTrail scan review is available.
"""

import argparse
import contextlib
import json
import os
import socket
import uuid
from pathlib import Path
import subprocess
import tempfile

from participant_e2e import geometry, interval
from participant_e2e_fixture import generate
from transcript_lifecycle import Desktop, eventually
from saved_project import read_project


@contextlib.contextmanager
def hidden_editor(bundle, project, folder, launch_environment=None, *, use_sidecars=False):
    operation = uuid.uuid4()
    name = "mpcut-test-" + operation.hex
    endpoint = Path("/tmp") / name
    home = folder / "home"
    (home / "Library" / "Preferences").mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, BACKSTAGE_SESSION=name)
    extra = [arg for key, value in (launch_environment or {}).items() for arg in ("--env", f"{key}={value}")]
    result = subprocess.run(
        ["backstage", "launch", str(bundle), "--timeout", "75", "--env", f"CFFIXED_USER_HOME={home}",
         "--env", f"MPCUT_TEST_SOCKET_DIRECTORY={name}", "--env", "MPCUT_MUTED=1", *extra,
         "--", "-automation_local_mcp_enabled", "YES",
         "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
         "-analysis_sidecar_reuse_enabled", "YES" if use_sidecars else "NO",
         "-export_tier_downgrade_warning_enabled", "NO"],
        env=env, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f"Backstage launch failed: {result.stdout} {result.stderr}")
    pid = json.loads(result.stdout)["pid"]
    try:
        def open_test_project():
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                    conn.settimeout(15)
                    conn.connect(str(endpoint / "control.sock"))
                    if Desktop.peer_pid(conn) != pid:
                        raise RuntimeError("Test socket belongs to a different app")
                    request = {"version": 2, "tool": "project_open", "arguments": {
                        "operation_id": str(operation), "project_path": str(project)}}
                    conn.sendall(json.dumps(request).encode() + b"\n")
                    reply = json.loads(conn.makefile("rb").readline())
                    if "project_handle" not in reply.get("result", {}):
                        raise RuntimeError(f"Opening the test project failed: {reply}")
                    return True
            except (FileNotFoundError, ConnectionRefusedError):
                return False
        eventually("the Backstage desktop listener", open_test_project)
        yield dict(env, MPCUT_TEST_EDITOR_PID=str(pid))
    finally:
        subprocess.run(["backstage", "quit", "--pid", str(pid), "--force"], env=env, timeout=20, check=True)
        subprocess.run(["defaults", "delete", "com.mpcut.test-preferences." + name],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        for child in ("control.sock", "listener.lock"):
            (endpoint / child).unlink(missing_ok=True)
        if endpoint.is_dir():
            endpoint.rmdir()


def create_fixture(cli, directory):
    gallery, recorder, iso_offset = generate(directory)
    base = directory / "Participant GUI Base.cut"
    base.write_text(json.dumps({
        "format": "mpcut", "schema_version": 9, "kind": "multicam",
        "reference_angle_id": "gallery", "group_range": interval(0, 5),
        "angles": [{"id": "gallery", "file": str(gallery), "audio_stream_index": 1}],
        "audio_sources": [{"id": "recorder", "file": str(recorder), "offset": str(iso_offset)}],
        "audio": {"mode": "fixed", "source_id": "gallery", "audio_stream_index": 1},
        "switches": [{"group_time": "0", "angle_id": "gallery"}],
        "participants": {
            "people": [
                {"id": "host", "name": "Host", "speakers": []},
                {"id": "guest", "name": "Guest", "speakers": []},
            ],
            "sources": [geometry()], "appearance_overrides": [],
        },
    }))
    words = directory / "overlap.json"
    words.write_text(json.dumps({
        "source": str(gallery), "duration_seconds": 5, "metadata": {},
        "sample_zero": {"numerator": 0, "denominator": 1},
        "speaker_names": ["Host Voice", "Guest Voice"],
        "segments": [
            {"speaker": 0, "start": 2.125, "end": 3.5, "words": [
                {"text": "hostword", "start": 2.125, "end": 3.5},
            ]},
            {"speaker": 1, "start": 2.125, "end": 3.5, "words": [
                {"text": "guestword", "start": 2.125, "end": 3.5},
            ]},
        ],
    }))
    project = directory / "Participant GUI.cut"
    subprocess.run([
        cli, "transcript", "attachment", "import", "--project", base, "--transcript", words,
        "--attachment-id", "overlap", "--source-id", "gallery", "--audio-stream-index", "1",
        "--out-project", project, "--json",
    ], check=True, timeout=60)
    return project


def verify_saved_project(cli, project):
    result = subprocess.run([
        cli, "participants", "project", "inspect", "--project", project, "--json",
    ], check=True, timeout=60, text=True, capture_output=True)
    saved = json.loads(result.stdout)
    expected = {
        "host": [{"attachment_id": "overlap", "speaker_id": "speaker-0"}],
        "guest": [{"attachment_id": "overlap", "speaker_id": "speaker-1"}],
    }
    actual = {person["id"]: person["speakers"] for person in saved["people"]}
    if actual != expected:
        raise AssertionError(f"Saved speaker bindings differ: {actual}")
    guest = next(person for person in saved["people"] if person["id"] == "guest")
    if guest["audio"] != {"selection": {"source_id": "recorder", "audio_stream_index": 1}}:
        raise AssertionError(f"Saved Guest ISO binding differs: {guest['audio']}")
    override, = saved["appearance_overrides"]
    if override != {
        "participant_id": "guest", "source_id": "gallery", "appearance_id": "guest-stage-16",
        "range": interval(2, 3),
    }:
        raise AssertionError(f"Saved appearance override differs: {override}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("cli", type=Path)
    parser.add_argument("--evidence", type=Path, help="Directory for screenshots")
    parser.add_argument("--feeds", action="store_true", help="scan and accept a burned-in camera multiview")
    args = parser.parse_args()
    if args.evidence:
        args.evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mpcut-participant-gui-") as scratch:
        directory = Path(scratch)
        if args.feeds:
            from participant_feeds import generate_grid
            movie = directory / "Camera feeds.mov"
            from media_regression import ffmpeg
            cycle = directory / "Four-second grid.mov"
            generate_grid(cycle, margin=4, gutter=4)
            # Give accessibility time to observe the native progress bar during analysis.
            ffmpeg("-stream_loop", "39", "-i", cycle, "-c", "copy", movie)
            project = directory / "Camera feeds.cut"
            project.write_text(json.dumps({
                "format": "mpcut", "schema_version": 9, "kind": "multicam",
                "reference_angle_id": "gallery", "group_range": interval(0, 4),
                "angles": [{"id": "gallery", "file": str(movie)}, {"id": "alternate", "file": str(cycle)}],
                "audio": {"mode": "none"},
                "switches": [{"group_time": "0", "angle_id": "gallery"}, {"group_time": "2", "angle_id": "alternate"}],
            }))
        else:
            project = create_fixture(args.cli.resolve(), directory)
        driver = Path(__file__).with_suffix(".swift")
        command = ["swift", str(driver), args.app.resolve(), project]
        if args.evidence:
            command.append(args.evidence.resolve())
        with hidden_editor(args.app.resolve(), project, directory) as env:
            if args.feeds:
                env["MPCUT_GUI_FEEDS_ONLY"] = "1"
            subprocess.run(command, check=True, timeout=360, env=env)
        if args.feeds:
            roster = read_project(project)["participants"]
            assert {p["name"] for p in roster["people"]} == {f"Feed {n}" for n in range(1, 5)}
            assert roster["sources"][0]["feed_layout"] == "auto"
            print("Verified GUI scan, accept and save for four automatic camera feeds")
            return
        verify_saved_project(args.cli.resolve(), project)
        print("Verified saved participant bindings and appearance override")
        with hidden_editor(args.app.resolve(), project, directory) as env:
            env["MPCUT_GUI_REOPEN_ONLY"] = "1"
            subprocess.run(command, check=True, timeout=120, env=env)


if __name__ == "__main__":
    main()
