#!/usr/bin/env python3
"""Verify unsaved Tiles edits through the packaged MCP helper and Backstage."""

import argparse
import base64
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from media_regression import ffmpeg
from participant_e2e import bounds, interval
from participant_e2e_fixture import COVER, HOST, LEFT, RIGHT, generate
from participant_gui import hidden_editor
from transcript_lifecycle import eventually, operation

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "docs"))
from mcp_walkthrough import Client, timed_out


def cli(binary, *args, request=None):
    command = [binary, *args, "--no-sidecar", "--json"]
    if request is not None:
        command.append("--stdin")
    result = subprocess.run(command, input=json.dumps(request) if request is not None else None,
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (command, result.stdout, result.stderr)
    return json.loads(result.stdout)


def fixture(binary, directory):
    gallery, _, _ = generate(directory)
    base = directory / "Source.cut"
    base.write_text(json.dumps({
        "format": "mpcut", "schema_version": 9, "kind": "sequence",
        "clips": [{"id": "gallery", "file": str(gallery), **interval(0, 1)}],
    }))
    project = directory / "Live.cut"
    cli(binary, "participants", "project", "apply", request={
        "project_path": str(base), "out_project": str(project),
        "participants": {
            "people": [
                {"id": "host", "name": "Host"},
                {"id": "guest", "name": "Guest"},
            ],
            "sources": [{
                "source_id": str(gallery),
                "appearances": [
                    {"id": name, "participant_id": name, "range": interval(0, 1),
                     "bounds": bounds(rect),
                     "role": "tile", "state": "video"}
                    for name, rect in (("host", LEFT), ("guest", RIGHT))
                ],
                "coverage": [{"range": interval(0, "1/2"), "state": "verified"}],
            }],
        },
    })
    cli(binary, "tiles", "feeds", "treatment", str(project), "--feed-id", "guest",
        "--treatment", "cover", "--in-place")
    return project


def wait_job(client, status_tool, job_id, **target):
    is_file_job = status_tool == "file_job_status_read"
    key = "state" if is_file_job else "status"
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        state = client.call(status_tool, job_id=job_id, **target)
        if state[key] not in ("running", "cancelling"):
            assert state[key] == "succeeded", state
            if is_file_job:
                return client.job_result(state)
            return state["result"]
        client.wait_for_poll()
    raise TimeoutError(f"{status_tool}: {job_id}")


def image(client, target, revision):
    reply = client.request("tools/call", name="review_editor_frame_read",
                           arguments=dict(target, expected_revision=revision, space="sequence", time="1/4"))
    assert not reply.get("isError"), reply
    metadata = reply["structuredContent"]
    block, = [item for item in reply["content"] if item["type"] == "image"]
    assert block["mimeType"] == "image/jpeg", block["mimeType"]
    return metadata, base64.b64decode(block["data"], validate=True)


def assert_swatches(jpeg, info, expected):
    width, height = info["width"], info["height"]
    frame = ffmpeg("-f", "mjpeg", "-i", "-", "-frames:v", "1", "-pix_fmt", "rgb24",
                   "-f", "rawvideo", "-", input=jpeg)
    assert len(frame) == width * height * 3, (len(frame), info)
    for index, color in enumerate(expected):
        x, y = width * (2 * index + 1) // (2 * len(expected)), height // 2
        offset = (y * width + x) * 3
        actual = tuple(frame[offset:offset + 3])
        assert max(abs(a - b) for a, b in zip(actual, color)) <= 22, (actual, color)


def exercise(client, binary, directory, project):
    tools = {tool["name"] for tool in client.pages("tools/list", "tools")}
    assert {"tiles_editor_layout_set", "tiles_editor_scan", "tiles_editor_inspect"} <= tools, tools
    opened = client.call("project_open", project_path=str(project), operation_id=operation())
    target = {"project_handle": opened["project_handle"]}

    def ready():
        state = client.call("project_editor_state_read", **target, limit=1)
        return state if state["can_edit"] else None

    def file_job(tool, **fields):
        job = client.call(tool, operation_id=operation(), **fields)
        return wait_job(client, "file_job_status_read", job["job_id"])

    start = eventually("an editable Tiles project", ready)
    revision = start["revision"]
    saved = project.read_bytes()
    history = client.call("history_read", **target)
    before_list = client.call("tiles_editor_layout_list", **target, expected_revision=revision, clip_id="gallery")
    before, before_jpeg = image(client, target, revision)
    assert_swatches(before_jpeg, before, (HOST, COVER))

    fields = {
        "clip_id": "gallery", "layout": "arranged", "from": "0", "to": "1",
        "slot": [
            {"id": "guest", "target": "participant", "destination_tile_id": "host"},
            {"id": "host", "target": "participant", "destination_tile_id": "guest"},
        ],
    }
    edited = client.call("tiles_editor_layout_set", **target, expected_revision=revision, **fields)
    assert edited["revision"] > revision, edited
    # The first request after the edit must render the new in-memory revision.
    after, after_jpeg = image(client, target, edited["revision"])
    assert not after.get("privacy_issues"), after
    assert_swatches(after_jpeg, after, (COVER, HOST))
    blocked = client.request("tools/call", name="review_editor_frame_read",
                             arguments=dict(target, expected_revision=edited["revision"],
                                            space="sequence", time="3/4"))
    assert blocked.get("isError"), blocked
    assert blocked["structuredContent"]["code"] == "unresolved_participant_privacy", blocked
    assert not any(item["type"] == "image" for item in blocked["content"]), blocked
    edited_history = client.call("history_read", **target)
    assert edited_history["cursor"] == history["cursor"] + 1, edited_history
    assert project.read_bytes() == saved
    current = client.call("tiles_editor_layout_list", **target, expected_revision=edited["revision"], clip_id="gallery")
    assert current["layouts"] != before_list["layouts"]

    parallel = directory / "Saved layout.cut"
    cli(binary, "tiles", "layout", "set", request=dict(fields, project_path=str(project), out_project=str(parallel)))
    cli_list = cli(binary, "tiles", "layout", "list", str(parallel), "--clip-id", "gallery")
    file_list = file_job("tiles_file_layout_list", project_path=str(parallel), clip_id="gallery")
    # The editor resolves media paths while saved project listings retain relative paths.
    live_layouts = [dict(entry, source_id=str(Path(entry["source_id"]).resolve().relative_to(directory)))
                    for entry in current["layouts"]]
    assert live_layouts == file_list["layouts"] == cli_list["layouts"], (current, file_list, cli_list)

    cli_frames = directory / "CLI JPEG"
    file_frames = directory / "MCP JPEG"
    cli_report = cli(binary, "review", "frames", "export", "--project", str(parallel),
                     "--clock", "sequence", "--at", "1/4", "--preset", "review", "--output", str(cli_frames))
    file_report = file_job("review_file_frames_export", project_path=str(parallel), clock="sequence",
                           at=["1/4"], preset="review", output=str(file_frames))
    for report, output in ((cli_report, cli_frames), (file_report, file_frames)):
        frame, = report["frames"]
        assert (after["width"], after["height"]) == (frame["width"], frame["height"]), frame
        assert_swatches((output / frame["file"]).read_bytes(), frame, (COVER, HOST))

    undone = client.call("history_undo", **target, expected_revision=edited["revision"], operation_id=operation())
    assert undone["cursor"] == history["cursor"], undone
    restored, restored_jpeg = image(client, target, undone["revision"])
    assert_swatches(restored_jpeg, restored, (HOST, COVER))
    restored_list = client.call("tiles_editor_layout_list", **target, clip_id="gallery")
    assert restored_list["layouts"] == before_list["layouts"], restored_list
    assert project.read_bytes() == saved
    print("Unsaved layout, immediate gated review, CLI/file parity and one-step undo verified.", flush=True)
    return target, undone["revision"]


def scan(client, binary, directory, target, revision):
    output = str(directory / "Live scan.json")
    receipt = client.call("tiles_editor_scan", **target, expected_revision=revision,
                          backend="cpu-only", sampling="every-frame", feed_layout="2x1",
                          output=output, no_sidecar=True)
    result = wait_job(client, "analysis_job_status_read", receipt["job_id"], **target)
    assert result["state"] == "completed" and result["counts"]["feed_count"] == 2, result
    assert Path(result["analysis_file"]).resolve() == Path(output), result
    report = client.call("tiles_editor_inspect", **target, expected_revision=revision, analysis_file=output, at="0")
    assert len(report["tiles"]) == 2, report
    assert report["revision"] == revision, report
    saved_report = cli(binary, "tiles", "inspect", output, "--at", "0")
    assert report["tiles"] == saved_report["tiles"], (report, saved_report)
    issues = client.call("tiles_editor_inspect", **target, analysis_file=output, issues=True)["issues"]
    assert result["review_issue_count"] == len(issues), (result, issues)
    pending_scan = dict(target, expected_revision=revision, operation_id=operation(), backend="cpu-only",
                        sampling="every-frame", feed_layout="2x1", no_sidecar=True)
    pending = client.call("tiles_editor_scan", **pending_scan)
    assert client.call("tiles_editor_scan", **pending_scan)["job_id"] == pending["job_id"]
    reviewed = wait_job(client, "analysis_job_status_read", pending["job_id"], **target)
    assert reviewed["revision"] > revision and "analysis_file" not in reviewed, reviewed
    assert reviewed["counts"] == result["counts"], reviewed
    live = client.call("tiles_editor_pending_read", **target)
    first_feed, second_feed = live["feed_ids"]
    choices = dict(live["choices"], names={first_feed: "Host"}, unchecked=[second_feed])
    request = dict(target, expected_revision=reviewed["revision"], operation_id=operation(),
                   review_token=live["review_token"], choices=choices)
    staged = client.call("tiles_editor_pending_stage", **request)
    assert client.call("tiles_editor_pending_stage", **request) == staged
    assert staged["pending_review"]["choices"] == choices, staged

    saved = directory / "Pending.cut"
    save = client.call("project_save", **target, expected_revision=staged["revision"],
                       operation_id=operation(), project_path=str(saved))
    on_disk = cli(binary, "tiles", "pending", "read", str(saved))
    assert on_disk["choices"] == staged["pending_review"]["choices"], on_disk

    def file_job(tool, **fields):
        receipt = client.call(tool, operation_id=operation(), **fields)
        return wait_job(client, "file_job_status_read", receipt["job_id"])

    assert file_job("tiles_file_pending_read", project_path=str(saved)) == on_disk
    file_choices = dict(choices, names={first_feed: "Alex"})
    staged_copy = directory / "Pending File Edit.cut"
    file_stage = file_job("tiles_file_pending_stage", project_path=str(saved), out_project=str(staged_copy),
                          review_token=on_disk["review_token"], choices=file_choices)
    assert file_stage["pending_review"] == cli(binary, "tiles", "pending", "read", str(staged_copy))
    assert file_stage["pending_review"]["choices"] == file_choices, file_stage
    file_discard = file_job("tiles_file_pending_discard", project_path=str(staged_copy), in_place=True,
                            review_token=file_stage["pending_review"]["review_token"])
    assert file_discard["operation_count"] == 1 and "pending_review" not in file_discard, file_discard

    discarded = client.call("tiles_editor_pending_discard", **target, expected_revision=save["revision"],
                            operation_id=operation(), review_token=staged["pending_review"]["review_token"])
    undone = client.call("history_undo", **target, expected_revision=discarded["revision"], operation_id=operation())
    assert undone["revision"] > discarded["revision"], undone
    assert client.call("tiles_editor_pending_read", **target)["choices"] == choices
    print("Verified pending scan, choice staging, replay and discard across the editor, CLI and file MCP.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("cli", type=Path)
    parser.add_argument("--scan", action="store_true", help="also scan and inspect a two-column gallery")
    args = parser.parse_args()
    bundle = args.app.resolve(strict=True)
    binary = args.cli.resolve(strict=True)
    helpers = bundle / "Contents" / "Helpers" if bundle.suffix == ".app" else bundle.parent
    signal.signal(signal.SIGALRM, timed_out)
    with tempfile.TemporaryDirectory(prefix="mpcut-tiles-mcp-") as scratch:
        directory = Path(scratch).resolve()
        project = fixture(binary, directory)
        with hidden_editor(bundle, project, directory) as env:
            env["MPCUT_TEST_SOCKET_DIRECTORY"] = env["BACKSTAGE_SESSION"]
            client = Client(helpers / "mpcut-mcp", env=env, poll_interval=0.1)
            try:
                signal.alarm(180)
                target, revision = exercise(client, binary, directory, project)
                if args.scan:
                    scan(client, binary, directory, target, revision)
            finally:
                signal.alarm(0)
                client.close()
            assert client.process.returncode == 0, client.process.returncode


if __name__ == "__main__":
    main()
