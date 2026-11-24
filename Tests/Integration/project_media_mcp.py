"""Exercise offline project recovery via the packaged live and file MCP entry points.

Run on a logged-in macOS desktop with backstage, ffmpeg and ffprobe available.
"""

import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile

from transcript_lifecycle import Desktop, eventually, operation

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "docs"))
from mcp_walkthrough import Client, timed_out


def file_job(client, tool, **fields):
    receipt = client.call(tool, operation_id=operation(), **fields)

    def finish():
        status = client.call("file_job_status_read", job_id=receipt["job_id"])
        if status["state"] in {"running", "cancelling"}:
            return None
        assert status["state"] == "succeeded", (tool, status, client.job_result(status))
        return status

    return client.job_result(eventually(tool, finish))


def fixture(folder, client, ffmpeg):
    original = folder / "camera.mov"
    moved = folder / "Relocated media" / original.name
    unrelated = folder / "unrelated.mov"
    replacement = folder / "replacement.mov"
    moved.parent.mkdir()
    video_options = "size=160x90:rate=10:duration=2"
    for path, source, hz in ((original, f"testsrc2={video_options}", 440),
                             (unrelated, f"smptebars={video_options}", 330),
                             (replacement, f"color=c=blue:{video_options}", 220)):
        subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i", source,
                        "-f", "lavfi", "-i", f"sine=frequency={hz}:sample_rate=48000:duration=2",
                        "-c:v", "libx264", "-g", "10", "-pix_fmt", "yuv420p", "-c:a", "aac", str(path)],
                       check=True, timeout=30)
    project = folder / "offline.cut"
    file_job(client, "project_file_create", request={
        "kind": "sequence",
        "out_project": str(project),
        "operations": [{"action": "append", "id": path.stem, "file": str(path)} for path in (original, unrelated)],
    })
    original.rename(moved)
    unrelated.rename(folder / "unavailable-reference.mov")
    return project, original, moved, unrelated, replacement


def chosen(rows, path):
    match, = (row for row in rows if Path(row["path"]).name == path.name)
    assert match["outcome"] == "verified", match
    candidate, = match["candidates"]
    assert Path(candidate["url"]).resolve() == path.resolve(), match
    return {"from": match["path"], "to": candidate["url"]}


def assert_sources(rows, expected):
    current = {Path(row["url"]).resolve(): row["status"] for row in rows
               if any(use["kind"] == "clip" for use in row["uses"])}
    assert current == {path.resolve(): status for path, status in expected.items()}, rows


def exercise_files(client, folder, project, original, moved, unrelated, replacement):
    source_args = {"project_path": str(project)}
    original_bytes = project.read_bytes()
    rows = file_job(client, "project_file_media_list", **source_args)["sources"]
    assert_sources(rows, {original: "offline", unrelated: "offline"})
    located = file_job(client, "project_file_media_locate", folder=str(moved.parent), **source_args)
    mapping = chosen(located["sources"], moved)
    output = folder / "file-relinked.cut"
    receipt = file_job(client, "project_file_media_relink", **source_args,
                       **{"from": str(original), "to": mapping["to"]}, out_project=str(output))
    assert receipt["applied_count"] == 1, receipt
    assert project.read_bytes() == original_bytes
    rows = file_job(client, "project_file_media_list", project_path=str(output))["sources"]
    assert_sources(rows, {moved: "online", unrelated: "offline"})
    linked = next(row["path"] for row in rows if Path(row["url"]).resolve() == moved.resolve())
    replacement_args = {"project_path": str(output), "source": linked, "with": str(replacement)}
    relinked_bytes = output.read_bytes()
    preview = file_job(client, "project_file_media_replace", **replacement_args)
    assert preview["report"]["can_apply"] and output.read_bytes() == relinked_bytes, preview
    replaced = folder / "file-replaced.cut"
    file_job(client, "project_file_media_replace", **replacement_args, confirm=True, out_project=str(replaced))
    rows = file_job(client, "project_file_media_list", project_path=str(replaced))["sources"]
    assert_sources(rows, {replacement: "online", unrelated: "offline"})
    assert output.read_bytes() == relinked_bytes
    print("File worker located the moved source and saved separate relinked and replacement copies.", flush=True)


def exercise_live(client, folder, project, original, moved, unrelated, replacement, ffprobe):
    def open_project(path):
        nonlocal handle
        handle = client.call("project_open", operation_id=operation(), project_path=str(path))["project_handle"]
        eventually("editor indexing", lambda: state()["total"] == 2 and not state()["busy"])
        return handle

    def call(tool, **fields):
        return client.call(tool, project_handle=handle, **fields)

    def state():
        return call("project_editor_state_read")

    def edit_ranges():
        return [(clip["document_id"], clip["source_from"], clip["source_to"]) for clip in state()["clips"]]

    def mutate(tool, **fields):
        return call(tool, operation_id=operation(), expected_revision=state()["revision"], **fields)

    def refused(tool, code, **fields):
        try:
            mutate(tool, **fields)
        except ValueError as error:
            assert str(error).startswith(f"{tool}: {code}:"), error
        else:
            raise AssertionError(f"{tool} accepted a request expected to fail with {code}")

    def sources(expected):
        def check():
            rows = call("project_editor_media_list")["items"]
            if any(row["status"] in {"indexing", "checking"} for row in rows):
                return False
            assert_sources(rows, expected)
            return rows

        return eventually("settled media statuses", check)

    handle = None
    open_project(project)
    sources({original: "offline", unrelated: "offline"})
    initial = edit_ranges()
    locate = mutate("project_editor_media_locate", folder=str(moved.parent))

    def locate_result():
        result = call("analysis_job_status_read", job_id=locate["job_id"])
        if result["status"] == "running":
            return None
        assert result["status"] == "succeeded", result
        return result

    mapping = chosen(eventually("live locate", locate_result)["candidates"], moved)
    linked = mutate("project_editor_media_relink", **mapping, locate_job_id=locate["job_id"])
    assert linked["changed"], linked
    rows = sources({moved: "online", unrelated: "offline"})
    assert edit_ranges() == initial

    blocked = folder / "blocked.mov"
    refused("export_editor_project_render", "source_needs_review",
            scope="timeline", output=str(blocked), mode="encode")
    assert not blocked.exists()

    mutate("timeline_selection_set", action="select_range", **{"from": "0", "to": "1"})
    movie = folder / "selected.mov"
    job = mutate("export_editor_project_render", scope="selection", output=str(movie), mode="encode")

    def rendered():
        result = call("export_editor_job_status_read", job_id=job["job_id"])
        if result["state"] in {"running", "cancelling"}:
            return None
        assert result["state"] == "succeeded", result
        return result

    eventually("selected export", rendered)
    probe = json.loads(subprocess.check_output([ffprobe, "-v", "error", "-show_streams", "-show_format",
                                                "-of", "json", str(movie)], timeout=15))
    assert {stream["codec_type"] for stream in probe["streams"]} == {"video", "audio"}, probe
    assert abs(float(probe["format"]["duration"]) - 1) <= 0.15, probe["format"]

    linked_source = next(row["path"] for row in rows if Path(row["url"]).resolve() == moved.resolve())
    arguments = {"source": linked_source, "with": str(replacement)}
    preview = mutate("project_editor_media_replace", **arguments)
    assert not preview["changed"] and preview["report"]["can_apply"], preview
    candidate_stat = replacement.stat()
    os.utime(replacement, ns=(candidate_stat.st_atime_ns, candidate_stat.st_mtime_ns + 1_000_000_000))
    refused("project_editor_media_replace", "source_changed",
            confirm=True, preview_id=preview["preview_id"], **arguments)
    sources({moved: "online", unrelated: "offline"})
    preview = mutate("project_editor_media_replace", **arguments)
    replaced = mutate("project_editor_media_replace", confirm=True, preview_id=preview["preview_id"], **arguments)
    assert replaced["changed"] and replaced["history_retained"], replaced
    sources({replacement: "online", unrelated: "offline"})
    mutate("history_undo")
    sources({moved: "online", unrelated: "offline"})

    saved = folder / "live-relinked.cut"
    mutate("project_save", project_path=str(saved))
    before = handle
    mutate("project_close", changes="discard")
    assert open_project(saved) != before
    sources({moved: "online", unrelated: "offline"})
    assert edit_ranges() == initial
    print("Live editor recovered offline media, exported a selection, undid a replacement, and reopened the saved relink.",
          flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    args = parser.parse_args()
    app = args.bundle.resolve(strict=True)
    helper = (app / "Contents" / "Helpers" / "mpcut-mcp").resolve(strict=True)
    endpoint = Path("/tmp") / ("mpcut-test-" + operation().replace("-", ""))
    signal.signal(signal.SIGALRM, timed_out)
    with tempfile.TemporaryDirectory(prefix="mpcut-media-mcp-") as temporary:
        folder = Path(temporary).resolve()
        (folder / "Library" / "Preferences").mkdir(parents=True)
        hidden_display = dict(os.environ, BACKSTAGE_SESSION="mpcut-media-" + endpoint.name)
        isolated = dict(os.environ, CFFIXED_USER_HOME=str(folder), MPCUT_TEST_SOCKET_DIRECTORY=endpoint.name,
                        MPCUT_SIDECAR_HOME=str(folder / "sidecars"))
        client = Client(helper, "--files-only", env=isolated, poll_interval=0.05)
        try:
            signal.alarm(150)
            paths = fixture(folder, client, args.ffmpeg)
            exercise_files(client, folder, *paths)
        finally:
            client.close()
            signal.alarm(0)
        assert client.process.returncode == 0, client.process.returncode

        pid = None
        domain = "com.mpcut.test-preferences." + endpoint.name
        try:
            launched = subprocess.run(
                ["backstage", "launch", str(app), "--env", f"CFFIXED_USER_HOME={folder}",
                 "--env", f"MPCUT_TEST_SOCKET_DIRECTORY={endpoint.name}", "--env", "MPCUT_MUTED=1",
                 "--env", f"MPCUT_SIDECAR_HOME={folder / 'sidecars'}",
                 "--", "-automation_local_mcp_enabled", "YES", "-history_max_steps", "50",
                 "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"],
                env=hidden_display, timeout=30, capture_output=True, text=True)
            assert launched.returncode == 0, (launched.stdout, launched.stderr)
            launch = json.loads(launched.stdout)
            pid = launch["pid"]

            def isolated_listener():
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                    try:
                        conn.connect(str(endpoint / "control.sock"))
                    except OSError:
                        return False
                    assert Desktop.peer_pid(conn) == pid, launch
                    return True

            eventually("isolated live MCP listener", isolated_listener)
            client = Client(helper, env=isolated, poll_interval=0.05)
            try:
                signal.alarm(150)
                exercise_live(client, folder, *paths, args.ffprobe)
            finally:
                client.close()
                signal.alarm(0)
            assert client.process.returncode == 0, client.process.returncode
        finally:
            if pid is not None:
                subprocess.run(["backstage", "quit", "--pid", str(pid), "--force"], env=hidden_display,
                               check=False, timeout=15)
            if endpoint.is_dir():
                (endpoint / "control.sock").unlink(missing_ok=True)
                (endpoint / "listener.lock").unlink(missing_ok=True)
                endpoint.rmdir()
            subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False, timeout=10)


if __name__ == "__main__":
    main()
