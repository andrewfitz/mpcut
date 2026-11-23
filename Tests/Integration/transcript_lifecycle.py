#!/usr/bin/env python3
"""Exercise transcript recovery across packaged macOS app processes.

Use a logged-in desktop with Accessibility access for the test terminal.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Tests" / "MPCutAppTests" / "Fixtures"
SOCKET_PEER_PID = 2  # Darwin LOCAL_PEERPID at SOL_LOCAL (0).


def eventually(label, check, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.10)
    raise AssertionError(f"Timed out waiting for {label}")


def operation():
    return str(uuid.uuid4())


class ControlError(AssertionError):
    def __init__(self, tool, error):
        self.code = error["code"]
        super().__init__(f"{tool}: {self.code}: {error['message']}")


class Desktop:
    def __init__(self, app, folder, endpoint, helper):
        self.endpoint = endpoint
        self.quit_tool = folder / "native-quit"
        self.pid = None
        args = ["/usr/bin/open", "-g", "-n", "-W", "-a", str(app),
                "--env", f"CFFIXED_USER_HOME={folder}",
                "--env", f"MPCUT_TEST_SOCKET_DIRECTORY={endpoint.name}",
                "--env", f"MPCUT_TRANSCRIBERRR_HELPER={helper}",
                "--args", "-automation_local_mcp_enabled", "YES", "-history_max_steps", "50",
                "-analysis_sidecar_reuse_enabled", "NO", "-timeline_snap_target", "off",
                "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        self.launch = subprocess.Popen(args)
        try:
            def listener():
                try:
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                        conn.connect(str(self.endpoint / "control.sock"))
                        return self.peer_pid(conn)
                except OSError:
                    return None

            self.pid = eventually("the isolated desktop listener", listener)
            eventually("the initial project window", lambda: self.call("project_windows_list")["projects"])
            print(f"Background desktop launched (PID {self.pid})", flush=True)
        except Exception:
            self.cleanup()
            raise

    @staticmethod
    def peer_pid(conn):
        return struct.unpack("i", conn.getsockopt(0, SOCKET_PEER_PID, 4))[0]

    def call(self, tool, **arguments):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(45)
            conn.connect(str(self.endpoint / "control.sock"))
            assert self.peer_pid(conn) == self.pid, "A different process acquired the test socket"
            request = {"version": 2, "tool": tool, "arguments": arguments}
            conn.sendall(json.dumps(request).encode() + b"\n")
            with conn.makefile("rb") as reply:
                response = json.loads(reply.readline())
        if "error" in response:
            raise ControlError(tool, response["error"])
        return response["result"]

    def quit(self):
        # NSRunningApplication sends the native Quit event to this specific PID.
        # Wait for the process started by Launch Services to exit naturally.
        subprocess.run([self.quit_tool, str(self.pid)], check=True, timeout=25)
        assert self.launch.wait(timeout=35) == 0
        # Launch Services reports the exit a few milliseconds before the kernel reaps the process.
        eventually(f"MPCut PID {self.pid} to exit", lambda: not process_alive(self.pid), timeout=5)
        print(f"Native Quit completed (PID {self.pid})", flush=True)

    def cleanup(self):
        if self.launch.poll() is None:
            if self.pid is not None and process_alive(self.pid):
                os.kill(self.pid, 9)
            try:
                self.launch.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.launch.kill()
                self.launch.wait()


def process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class Project:
    def __init__(self, desktop, tool, **args):
        self.desktop = desktop
        self.handle = desktop.call(tool, operation_id=operation(), **args)["project_handle"]
        def indexing_finished():
            state = self.state()
            return state["total"] > 0 and not state["busy"]

        eventually("media indexing", indexing_finished)

    def call(self, tool, **args):
        return self.desktop.call(tool, project_handle=self.handle, **args)

    def state(self):
        return self.call("project_editor_state_read")

    def start(self, engine=None):
        state = self.inspect()
        options = {"engine": engine} if engine else {}
        args = {"options": options, "expected_revision": state["revision"],
                "expected_transcript_revision": state["transcript_revision"],
                "policy": "restart", "operation_id": operation()}
        job_id = self.call("transcript_editor_job_start", **args)["job_id"]
        assert self.call("transcript_editor_job_start", **args)["job_id"] == job_id
        return job_id

    def inspect(self):
        return self.call("transcript_editor_attachments_list")

    def status(self, job_id):
        return self.call("transcript_editor_job_status_read", job_id=job_id, limit=10)

    def retry(self, job_id):
        def start_retry():
            try:
                return self.call("transcript_editor_job_retry", job_id=job_id, operation_id=operation())
            except ControlError as error:
                if error.code != "transcript_job_busy":
                    raise
                return None

        eventually("the preceding worker to exit before retry", start_retry)

    def save(self, path=None):
        destination = {"project_path": str(path)} if path else {}
        return self.call("project_save", expected_revision=self.state()["revision"],
                         operation_id=operation(), **destination)

    def edit(self, tool):
        return self.call(tool, expected_revision=self.state()["revision"], operation_id=operation())


def assert_state(project, job_id, expected, *, attached=None):
    def check():
        status = project.status(job_id)
        if status.get("attachment_error") or status["state"] == "failed":
            raise AssertionError(status)
        if status["state"] == expected and (attached is None or status["attached"] == attached):
            return status
        return False
    return eventually(f"job {expected}", check)


def synthetic_lifecycle(app, folder, endpoint):
    helper = folder / "lifecycle-provider"
    shutil.copyfile(FIXTURES / "TranscriptLifecycleProvider.py", helper)
    helper.chmod(0o700)
    source = folder / "Synthetic camera.mov"
    shutil.copyfile(FIXTURES / "Pause-Quiet.mov", source)
    first_save = folder / "First save.cut"
    saved_as = folder / "Saved As.cut"
    def started(index):
        marker = folder / f"started-{index}"
        return eventually(f"helper attempt {index}", lambda: int(marker.read_text()) if marker.exists() else None)

    def visible(project, job_id):
        return any(row["job_id"] == job_id for row in project.call("transcript_editor_jobs_list")["items"])

    def release(index, state):
        destination = folder / f"release-{index}"
        temporary = destination.with_suffix(".tmp")
        temporary.write_text(state)
        temporary.replace(destination)

    first = Desktop(app, folder, endpoint, helper)
    try:
        project = Project(first, "project_create", kind="sequence", paths=[str(source)])
        assert project.state()["total"] == 1
        job = project.start("lifecycle-fixture")
        helper_pid = started(1)
        assert_state(project, job, "running")
        state = project.state()
        project.call("timeline_item_split", expected_revision=state["revision"], operation_id=operation(),
                     occurrence=state["clips"][0]["id"], space="sequence", time="1")
        assert project.state()["total"] == 2
        project.save(first_save)
        eventually("job ownership after first save", lambda: visible(project, job))
        assert_state(project, job, "running")
        project.save(saved_as)
        eventually("job ownership after Save As", lambda: visible(project, job))
        assert_state(project, job, "running")
        assert first_save.is_file() and saved_as.is_file()
        print("Saved the edited project twice while the helper was running", flush=True)
        first.quit()
        assert not process_alive(helper_pid), f"Helper PID {helper_pid} survived Quit"
    finally:
        first.cleanup()

    second = Desktop(app, folder, endpoint, helper)
    try:
        assert second.pid != first.pid
        project = Project(second, "project_open", project_path=str(saved_as))
        assert project.state()["total"] == 2
        assert_state(project, job, "interrupted")
        project.edit("history_undo")
        assert project.state()["total"] == 1
        project.edit("history_redo")
        assert project.state()["total"] == 2
        print("Recovered the interrupted job and native undo/redo after process relaunch", flush=True)

        project.retry(job)
        started(2)
        release(2, "partial")
        partial = assert_state(project, job, "partial", attached=True)
        assert sorted(item["track"]["state"] for item in partial["items"]) == ["failed", "recognized"], partial
        project.retry(job)
        started(3)
        project.call("transcript_editor_job_cancel", job_id=job, operation_id=operation())
        assert_state(project, job, "cancelled")
        project.retry(job)
        started(4)
        release(4, "completed")
        assert_state(project, job, "completed", attached=True)
        assert project.inspect()["total"] == 1
        assert project.call("transcript_editor_words_search", query="Ready", space="source")["total"] == 1
        project.save()
        eventually("saved attachment acknowledgement", lambda: project.status(job)["saved_attachment"])
        print("Retried the failed stream after cancellation and saved one acknowledged attachment", flush=True)
        second.quit()
    finally:
        second.cleanup()

    third = Desktop(app, folder, endpoint, helper)
    try:
        assert third.pid not in [first.pid, second.pid]
        project = Project(third, "project_open", project_path=str(saved_as))
        assert project.state()["total"] == 2 and project.inspect()["total"] == 1
        status = assert_state(project, job, "completed", attached=True)
        assert status["saved_attachment"]
        assert project.call("transcript_editor_words_search", query="Ready", space="source")["total"] == 1
        print("Reopened the acknowledged result with one recognized passage", flush=True)
        third.quit()
    finally:
        third.cleanup()


def real_recognition(app, folder, endpoint, helper, media, timeout):
    source = folder / ("Real source" + media.suffix)
    shutil.copyfile(media, source)
    desktop = Desktop(app, folder, endpoint, helper)
    try:
        project = Project(desktop, "project_create", kind="sequence", paths=[str(source)])
        capabilities = project.call("transcript_provider_capabilities_read")
        assert capabilities["session_schema_version"] == 1
        job_id = project.start()
        seen = set()

        def check():
            status = project.status(job_id)
            summaries = tuple((item["track"]["state"], item["track"].get("message"))
                              for item in status.get("items", []))
            marker = (status["state"], summaries)
            if marker not in seen:
                seen.add(marker)
                print(f"Default-engine desktop progress: {marker}", flush=True)
            if status.get("attachment_error") or status["state"] in {"failed", "stale", "cancelled", "interrupted"}:
                raise AssertionError(status)
            return status["state"] == "completed" and status["attached"]

        eventually("default-engine completion through the desktop", check, timeout=timeout)
        assert any(state == "running" and any(message for _, message in tracks)
                   for state, tracks in seen), seen
        page = project.call("transcript_editor_words_read", space="source", limit=10)
        assert page["total"] > 0, page
        project.save(folder / "Recognized.cut")
        desktop.quit()
        print(f"Default-engine real-helper transcription attached {page['total']} source words", flush=True)
    finally:
        desktop.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--scratch-dir", type=Path, help="Optional parent for disposable fixtures and app preferences. Keep it on the startup disk: "
                             "an app opened through Launch Services waits on file access under /Volumes")
    parser.add_argument("--real-helper", type=Path)
    parser.add_argument("--real-media", type=Path)
    parser.add_argument("--real-timeout", type=float, default=180)
    parser.add_argument("--real-only", action="store_true")
    args = parser.parse_args()
    if bool(args.real_helper) != bool(args.real_media) or (args.real_only and not args.real_helper):
        parser.error("Supply both --real-helper and --real-media for real recognition")
    app = args.bundle.resolve(strict=True)

    with tempfile.TemporaryDirectory(prefix="mpcut-lifecycle-", dir=args.scratch_dir) as temporary:
        folder = Path(temporary).resolve()
        (folder / "Library" / "Preferences").mkdir(parents=True)
        quit_source = Path(__file__).with_name("transcript_lifecycle_quit.swift")
        subprocess.run(["swiftc", str(quit_source), "-o", str(folder / "native-quit")], check=True)
        endpoint = Path("/tmp") / ("mpcut-test-" + uuid.uuid4().hex)
        try:
            if not args.real_only:
                synthetic_lifecycle(app, folder, endpoint)
            if args.real_helper:
                real_recognition(app, folder, endpoint, args.real_helper.resolve(strict=True),
                                 args.real_media.resolve(strict=True), args.real_timeout)
        finally:
            shutil.rmtree(endpoint, ignore_errors=True)
            subprocess.run(["/usr/bin/defaults", "delete", "com.mpcut.test-preferences." + endpoint.name],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


if __name__ == "__main__":
    main()
