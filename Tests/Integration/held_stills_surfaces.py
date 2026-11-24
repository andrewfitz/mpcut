#!/usr/bin/env python3
"""Compare CLI and live MCP exports of one saved still project in a packaged app."""
import argparse
from fractions import Fraction
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import uuid

from held_stills_release import matroska_blocks, pcm_fixture
from media_regression import ffmpeg, probe
from transcript_lifecycle import Desktop, eventually, operation

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "docs"))
from mcp_walkthrough import Client, timed_out
from saved_project import media_paths, read_project


def exercise(app, folder):
    folder.mkdir(parents=True)
    (folder / "Library" / "Preferences").mkdir(parents=True)
    endpoint = Path("/tmp") / ("mpcut-test-" + uuid.uuid4().hex)
    display = dict(os.environ, BACKSTAGE_SESSION="mpcut-held-" + endpoint.name)
    packaged = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"],
                "CFFIXED_USER_HOME": str(folder), "MPCUT_TEST_SOCKET_DIRECTORY": endpoint.name,
                "MPCUT_SIDECAR_HOME": str(folder / "sidecars")}
    helpers = app / "Contents" / "Helpers"
    cover, end = (folder / name for name in ("cover.png", "end.png"))
    for image, color in ((cover, "white"), (end, "black")):
        ffmpeg("-f", "lavfi", "-i", f"color={color}:size=320x180", "-frames:v", "1", image)
    soundtrack = folder / "soundtrack.wav"
    pcm = pcm_fixture(soundtrack, 48000, 96000)
    project = folder / "project.cut"

    def cli(*args, succeeds=True):
        reply = subprocess.run([helpers / "mpcut", *args, "--json"], env=packaged,
                               capture_output=True, text=True, timeout=45)
        result = json.loads(reply.stdout)
        assert (reply.returncode == 0) == succeeds, (args, result, reply.stderr)
        return result

    cli("still", "project", "create", "--out-project", project, "--image", cover, "--duration", "1",
        "--width", "320", "--height", "180", "--rate", "24", "--codec", "h264",
        "--container", "mov", "--soundtrack", soundtrack)
    cli("still", "placement", "insert", "--project", project, "--image", end,
        "--clock", "sequence", "--at", "1", "--duration", "1", "--in-place")
    saved = project.read_bytes()

    pid = None
    try:
        args = ["backstage", "launch", str(app), "--env", "MPCUT_MUTED=1"]
        for key in ("CFFIXED_USER_HOME", "MPCUT_TEST_SOCKET_DIRECTORY", "MPCUT_SIDECAR_HOME"):
            args += ["--env", f"{key}={packaged[key]}"]
        args += ["--", "-automation_local_mcp_enabled", "YES", "-history_max_steps", "50",
                 "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        launch = subprocess.run(args, env=display, capture_output=True, timeout=30)
        assert launch.returncode == 0, (launch.stdout.decode(), launch.stderr.decode())
        pid = json.loads(launch.stdout)["pid"]

        def listener():
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                try:
                    conn.connect(str(endpoint / "control.sock"))
                except OSError:
                    return False
                assert Desktop.peer_pid(conn) == pid
                return True

        eventually("isolated listener", listener)
        client = Client(helpers / "mpcut-mcp", env=packaged, poll_interval=0.05)
        try:
            check_exports(client, folder, project, cover, soundtrack, pcm, cli)
        finally:
            client.close()
        assert client.process.returncode == 0
        assert project.read_bytes() == saved
    finally:
        if pid is not None:
            subprocess.run(["backstage", "quit", "--pid", str(pid), "--force"], env=display,
                           timeout=15, check=False)
        if endpoint.is_dir():
            for name in ("control.sock", "listener.lock"):
                (endpoint / name).unlink(missing_ok=True)
            endpoint.rmdir()


def check_exports(client, folder, project, cover, soundtrack, pcm, cli):
    handle = None

    def call(tool, **fields):
        return client.call(tool, project_handle=handle, **fields)

    def state():
        return call("project_editor_state_read")

    def mutate(tool, **fields):
        return call(tool, expected_revision=state()["revision"], operation_id=operation(), **fields)

    def open_project(path, items=2):
        nonlocal handle
        handle = client.call("project_open", project_path=str(path), operation_id=operation())["project_handle"]
        eventually("editor ready", lambda: not state()["busy"] and state()["total"] == items)

    def await_output(label, job, expected_state):
        def finished():
            status = call("export_editor_job_status_read", job_id=job["job_id"])
            if status["state"] in {"running", "cancelling"}:
                return None
            assert status["state"] == expected_state, (label, status)
            return status

        return eventually(label, finished, timeout=60)

    def run_output(tool, expected_state="succeeded", **fields):
        return await_output(tool, mutate(tool, **fields), expected_state)

    def live_render(output, **options):
        planned = run_output("export_editor_project_plan", output=str(output), **options)["result"]
        assert planned["eligible"] and not output.exists(), planned
        assert "output_bytes" not in planned, planned
        rendered = run_output("export_editor_project_render", output=str(output), **options)["result"]
        assert rendered["eligible"], rendered
        assert rendered["output_bytes"] == output.stat().st_size, rendered
        return planned["plan"], rendered["plan"]

    open_project(project)
    columns = ("container", "video_codec", "picture_timing", "generated_video_sample_count",
               "generated_still_duration")
    formats = (("mov", "hevc", "pcm"), ("mp4", "h264", "alac"),
               ("m4v", "h264", "flac"), ("mkv", "h264", "flac"))
    for extension, codec, audio in formats:
        command_output = folder / f"cli.{extension}"
        live_output = folder / f"live.{extension}"
        command = ("export", "project", "render", "--project", project, "--output", command_output,
                   "--mode", "smart", "--video", codec, "--audio", audio,
                   "--still-timing", "held", "--container", extension)
        cli_plan = cli(*command, "--dry-run")
        assert not command_output.exists()
        cli_render = cli(*command)
        assert "output_bytes" not in cli_plan and cli_render["output_bytes"] == command_output.stat().st_size
        live_plan, live_report = live_render(live_output, mode="smart", codec=codec, audio=audio,
                                             still_timing="held", container=extension)
        expected = (extension, codec, "held", 2)
        for report in (cli_plan, cli_render, live_plan, live_report):
            assert tuple(report[key] for key in columns[:4]) == expected, report
            assert report[columns[-1]] == cli_plan[columns[-1]], report
        for output in (command_output, live_output):
            packets = probe(output, "-select_streams", "v:0", "-show_packets")["packets"]
            assert [float(packet["pts_time"]) for packet in packets] == [0, 1], packets
            sound = ffmpeg("-i", output, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "s32le", "-")
            assert sound == pcm, output
        print(f"CLI and live MCP agree for .{extension}", flush=True)

    output = folder / "cadence.mov"
    _, cadence = live_render(output, mode="smart", codec="h264", audio="alac", still_timing="cadence")
    assert cadence["picture_timing"] == "cadence" and cadence["generated_video_sample_count"] == 48, cadence
    output = folder / "default.mov"
    _, default = live_render(output, mode="smart")
    assert default["picture_timing"] == "held" and default["generated_video_sample_count"] == 2, default

    for label, start, end, timestamps, durations in (
            ("inside", "1/4", "3/4", [0], [0.5]),
            ("across", "3/4", "5/4", [0, 0.25], [0.25, 0.25])):
        mutate("timeline_selection_set", action="select_range", **{"from": start, "to": end})
        movie = folder / f"selection-{label}.mov"
        _, report = live_render(movie, scope="selection", mode="smart", audio="pcm")
        assert report["picture_timing"] == "held" and report["generated_video_sample_count"] == len(timestamps), report
        packets = probe(movie, "-select_streams", "v:0", "-show_packets")["packets"]
        assert [float(packet["pts_time"]) for packet in packets] == timestamps, packets
        assert [float(packet["duration_time"]) for packet in packets] == durations, packets
        first = 12000 if label == "inside" else 36000
        assert ffmpeg("-i", movie, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "s32le", "-") == pcm[first * 8:(first + 24000) * 8]

    blocked = folder / "blocked.mov"
    command = ("export", "project", "render", "--project", project, "--output", blocked)
    for invalid in (("--mode", "copy"), ("--container", "mp4")):
        for extra in ((), ("--dry-run",)):
            result = cli(*command, *invalid, *extra, succeeds=False)
            assert not result["ok"] and not blocked.exists(), result
    for invalid in ({"mode": "copy"}, {"mode": "smart", "container": "mp4"}):
        refusal = run_output("export_editor_project_plan", output=str(blocked), **invalid)["result"]
        assert not refusal["eligible"] and not blocked.exists(), refusal
        run_output("export_editor_project_render", expected_state="failed", output=str(blocked), **invalid)
        assert not blocked.exists()

    mutate("project_close", changes="discard")
    open_project(project)
    mutate("timeline_selection_set", action="select_range", **{"from": "0", "to": "2"})
    queued = mutate("export_queue_range_add")["ranges"]
    assert len(queued) == 1 and [item["kind"] for item in queued[0]["items"]] == ["still", "still", "audio"], queued
    queue_settings = [(extension, codec, audio, "held", 2, {}) for extension, codec, audio in formats]
    queue_settings.append(("mov", "h264", "pcm", "cadence", 48, {"still_timing": "cadence"}))
    for extension, codec, audio, timing, count, overrides in queue_settings:
        queue_output = folder / f"queue-{timing}-{extension}"
        queue_output.mkdir()
        options = dict(output=str(queue_output), mode="smart", codec=codec, audio=audio,
                       container=extension, **overrides)
        queue_plan = run_output("export_queue_plan", **options)["result"]
        assert not list(queue_output.iterdir()), queue_plan
        queue_result = run_output("export_queue_render", **options)["result"]
        assert queue_result["destinations"] == queue_plan["destinations"], queue_result
        movie, = map(Path, queue_result["destinations"])
        assert movie.suffix == f".{extension}", movie
        assert "output_bytes" not in queue_plan["still_plans"][0], queue_plan
        assert queue_result["still_plans"][0]["output_bytes"] == movie.stat().st_size, queue_result
        for result in (queue_plan, queue_result):
            report = result["still_plans"][0]["plan"]
            assert report["picture_timing"] == timing and report["generated_video_sample_count"] == count, report
            assert report["container"] == extension and report["video_codec"] == codec, report
        packets = probe(movie, "-select_streams", "v:0", "-show_packets")["packets"]
        assert len(packets) == count, (movie, len(packets))
        if timing == "held":
            assert [float(packet["pts_time"]) for packet in packets] == [0, 1], packets
            if extension == "mkv":
                assert matroska_blocks(movie) == [(Fraction(0), Fraction(1)), (Fraction(1), Fraction(1))]
            else:
                assert [float(packet["duration_time"]) for packet in packets] == [1, 1], packets
        assert ffmpeg("-i", movie, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "s32le", "-") == pcm

    placement = state()["clips"][0]["placement"]
    mutate("timeline_item_split", occurrence=placement, space="sequence", time="1/2")
    assert state()["total"] == 3
    assert call("export_queue_list")["ranges"] == queued
    relocated = folder / "Relocated"
    relocated.mkdir()
    moved = [(source, relocated / source.name) for source in (cover, soundtrack)]
    for source, target in moved:
        source.rename(target)
    try:
        mappings = [{"from": str(source), "to": str(target)} for source, target in moved]
        result = mutate("project_editor_media_relink", mappings=mappings)
        assert result["changed"], result
        relinked_movie = folder / "relinked.mov"
        _, relinked = live_render(relinked_movie, mode="smart", audio="alac")
        assert relinked["generated_video_sample_count"] == 3, relinked
        assert ffmpeg("-i", relinked_movie, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "s32le", "-") == pcm
        relinked_copy = folder / "relinked.cut"
        mutate("project_save", project_path=str(relinked_copy))
        assert {"Relocated/cover.png", "Relocated/soundtrack.wav"} <= set(media_paths(read_project(relinked_copy)))
        mutate("history_undo")
        assert state()["total"] == 2
        _, undone = live_render(folder / "undo.mov", mode="smart")
        assert undone["generated_video_sample_count"] == 2, undone
        mutate("history_redo")
        assert state()["total"] == 3
        _, redone = live_render(folder / "redo.mov", mode="smart")
        assert redone["generated_video_sample_count"] == 3, redone
        print("Verified rendered queue, timing overrides, refusals, relative relink and history", flush=True)
    finally:
        for source, target in moved:
            os.link(target, source)

    long_project = folder / "cancellation.cut"
    cli("still", "project", "create", "--out-project", long_project, "--image", cover,
        "--duration", "24", "--width", "1280", "--height", "720", "--rate", "24",
        "--codec", "h264", "--container", "mov", "--soundtrack", soundtrack)
    open_project(long_project, items=1)
    cancellation_dir = folder / "cancellation"
    cancellation_dir.mkdir()
    movie = cancellation_dir / "retried.mov"
    options = dict(output=str(movie), mode="smart", codec="h264", audio="pcm", still_timing="cadence")
    started = mutate("export_editor_project_render", **options)
    assert started["state"] == "running", started
    call("export_editor_job_cancel", job_id=started["job_id"])
    stopped = await_output("cancelled render", started, "cancelled")
    assert stopped["outputs"] == [] and not list(cancellation_dir.iterdir()), stopped
    done = run_output("export_editor_project_render", **options)
    assert done["outputs"] == [str(movie)], done
    assert done["result"]["output_bytes"] == movie.stat().st_size, done
    assert done["result"]["plan"]["generated_video_sample_count"] == 24 * 24, done
    print("Verified cancellation cleanup, retry and published size", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("work_directory", type=Path)
    args = parser.parse_args()
    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(240)
    exercise(args.app.resolve(strict=True), args.work_directory.resolve())
    signal.alarm(0)
