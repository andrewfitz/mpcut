"""Run against a packaged or development mpcut-mcp helper, without an editor."""

import argparse
import json
import math
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "docs"))
from mcp_walkthrough import Client, PROTOCOL_VERSION, timed_out
from saved_project import read_project


def exercise(client, folder):
    def job(tool, *, error=None, operation_id=None, paged=False, **arguments):
        receipt = client.call(tool, operation_id=operation_id or str(uuid.uuid4()), **arguments)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            state = client.call("file_job_status_read", job_id=receipt["job_id"])
            if state["state"] not in ("running", "cancelling"):
                assert state["state"] == ("failed" if error else "succeeded"), (tool, state)
                if paged:
                    assert "result" not in state and state["result_bytes"] > 131072, state.keys()
                result = client.job_result(state)
                if error:
                    assert result["error"]["code"] == error, state
                return result
            time.sleep(0.05)
        raise TimeoutError(tool)

    discovery = client.request("server/discover")
    assert PROTOCOL_VERSION in discovery["supportedVersions"], discovery
    catalog = [tool["name"] for tool in client.pages("tools/list", "tools")]
    assert "project_file_create" in catalog and "project_windows_list" not in catalog
    assert len(set(catalog)) == len(catalog)
    assert all("_file_" in name or name.startswith("file_job_") or name in ("cli_help_read", "cli_version_read")
               for name in catalog)
    resources = {item["uri"] for item in client.pages("resources/list", "resources")}
    guide = "mpcut://docs/headless"
    assert guide in resources, resources
    assert "--files-only" in client.request("resources/read", uri=guide)["contents"][0]["text"]
    src = str(folder / "take.wav")
    with wave.open(src, "wb") as wav:
        wav.setparams((1, 2, 16000, 0, "NONE", ""))
        samples = (0 if 16000 <= i < 48000 else int(16000 * math.sin(i * .11)) for i in range(64000))
        wav.writeframes(b"".join(struct.pack("<h", value) for value in samples))
    seq = str(folder / "repeated.cut")
    create = dict(kind="sequence", out_project=seq, operations=[
        dict(action="append", id=key, file=src) for key in ("a", "b")])
    operation_id = str(uuid.uuid4())
    created = job("project_file_create", operation_id=operation_id, request=create)
    assert job("project_file_create", operation_id=operation_id, request=create) == created
    duplicate = folder / "duplicate.cut"
    try:
        client.call("project_file_create", operation_id=operation_id,
                    request=dict(create, out_project=str(duplicate)))
    except ValueError as error:
        assert str(error).startswith("project_file_create: operation_id_conflict:"), error
    else:
        raise AssertionError("A reused operation ID accepted different arguments.")
    assert not duplicate.exists()
    edited = folder / "edited.cut"
    job("project_file_edit", request=dict(project_path=seq, out_project=str(edited), operations=[
        dict(action="split", id="a", at="2", new_id="c"), {"action": "trim", "id": "b", "from": "1", "to": "3"},
        dict(action="move", id="c", index=0), dict(action="remove", id="a")]))
    assert [c["id"] for c in read_project(edited)["clips"]] == ["c", "b"]
    original = Path(seq).read_bytes()
    job("project_file_edit", error="output_exists", request=dict(project_path=seq, out_project=seq, operations=[]))
    invalid = folder / "invalid.cut"
    job("project_file_edit", error="invalid_range", request=dict(project_path=seq, out_project=str(invalid), operations=[
        dict(action="remove", id="a"), {"action": "trim", "id": "b", "from": "1", "to": "5"}]))
    assert not invalid.exists()
    assert Path(seq).read_bytes() == original
    mapping = job("timeline_file_range_map", project_path=seq, space="source", file=src,
                  **{"from": "1", "to": "2"})
    assert mapping["output_clock"] == "sequence"
    assert [piece["id"] for piece in mapping["pieces"]] == ["a", "b"]
    assert [piece["output"] for piece in mapping["pieces"]] == [{"from": "1", "to": "2"}, {"from": "5", "to": "6"}]
    many = folder / "many-occurrences.cut"
    clip_ids = [f"repeated-recording-occurrence-{index:04d}-" + "a" * 64 for index in range(650)]
    fixture = json.loads(original)
    clip = fixture["clips"][0]
    fixture["clips"] = [dict(clip, id=key) for key in clip_ids]
    many.write_text(json.dumps(fixture))
    large = job("timeline_file_range_map", paged=True, project_path=str(many), space="source", file=src,
                **{"from": "0", "to": "1"})
    assert [piece["id"] for piece in large["pieces"]] == clip_ids
    comparison = job("history_file_compare", before_project_path=seq, project_path=str(edited))
    assert comparison["before_duration"] == "8" and comparison["after_duration"] == "4"
    assert {change["kind"] for change in comparison["changes"]} == {"added", "removed", "modified"}
    selects = str(folder / "named-select.cut")
    job("project_file_edit", request=dict(project_path=seq, out_project=selects, operations=[
        {"action": "source_select_save", "id": "answer", "name": "Answer", "file": src, "from": "0", "to": "1/2"},
        {"action": "source_ranges_apply", "from": "0", "to": "0", "ranges": [{"select_id": "answer"}]}]))
    selected = job("project_file_inspect", project_path=selects)
    assert [item["id"] for item in selected["source_selects"]] == ["answer"]
    inserted = job("timeline_file_range_map", project_path=selects, space="sequence", **{"from": "0", "to": "1/2"})
    assert inserted["pieces"][0]["input"] == {"from": "0", "to": "1/2"}
    options = dict(project_path=seq, silence_threshold_db=-45, silence_min_pause_seconds=.6)
    report = job("silence_file_scan", **options)
    assert len(report["pauses"]) == 2
    revised_pauses = job("silence_file_scan", **options, take_boundaries=["1/2"],
                        retain_pauses=[{"pause_id": report["pauses"][0]["id"], "retained_seconds": 0.5}])
    assert revised_pauses["pauses"][0]["requested_retained_seconds"] == 0.5
    assert len(revised_pauses["take_candidates"]) == len(report["take_candidates"]) + 1
    shortened = folder / "short.cut"
    job("silence_file_shorten", error="invalid_arguments", **options, out_project=str(shortened), protect_pauses=["stale"])
    assert not shortened.exists()
    job("silence_file_shorten", **options, out_project=str(shortened), protect_pauses=[report["pauses"][0]["id"]])
    assert len(read_project(shortened)["clips"]) == 3
    job("silence_file_export", **options, output=str(folder / "short.wav"))
    with wave.open(str(folder / "short.wav"), "rb") as shortened_audio:
        assert shortened_audio.getnframes() < 8 * shortened_audio.getframerate()
    job("export_file_ranges_separate", file=src, output_directory=str(folder), ranges=[{"from": "0", "to": "1"}],
        subfolder="Audio", base_name="Take", container="wav")
    assert (folder / "Audio/Take-001.wav").exists()
    still = str(folder / "still.cut")
    job("still_file_project_create", out_project=still, gap=True, frames=10, rate="30", codec="h264",
        container="mp4", width=320, height=180)
    placements = job("still_file_placements_list", project_path=still)
    assert [asset["kind"] for asset in placements["assets"]] == ["gap"]
    assert len(placements["placements"]) == 1, placements
    assert placements["placements"][0]["visible_occurrences"][0]["output"] == {"from": "0", "to": "1/3"}
    movie = str(folder / "camera.mov")
    shutil.copyfile(ROOT / "Tests/MPCutAppTests/Fixtures/ProRes-2997.mov", movie)
    multi = str(folder / "multi.cut")
    end = "1001/10000"
    job("project_file_create", request=dict(kind="multicam", angles=[dict(id="one", file=movie), dict(id="two", file=movie)],
        group_end=end, out_project=multi, operations=[dict(action="switch_set", at="1001/30000", angle_id="two"),
                                                    {"action": "trim", "index": 0, "from": "1001/30000", "to": end}]))
    review = job("review_file_frames_export", project_path=multi, at=["0"], clock="assembly", output=str(folder / "frames"))
    assert review["clock"] == "assembly" and review["frames"][0]["source"] == "two"
    assert (folder / "frames" / review["frames"][0]["file"]).read_bytes().startswith(b"\xff\xd8")
    sync = job("multicam_file_sync_suggest", project_path=multi, source_id="two", metadata_only=True)
    assert sync["reference_source_id"] == "one" and not sync["waveform_requested"]
    assert [suggestion["source_id"] for suggestion in sync["suggestions"]] == ["two"]
    coverage = job("multicam_file_switch_coverage_read", project_path=multi, angle_id="two", group_time="0")
    assert coverage["angle_id"] == "two" and coverage["picture"]["status"] == "covered"
    directory = str(folder / "jobs")
    prepared = job("transcript_file_job_prepare", request=dict(project_path=seq, job_directory=directory,
                                                                engine="lifecycle-fixture", model="fixture"))
    recognition = dict(job_id=prepared["id"], job_directory=directory)
    completed = job("transcript_file_job_run", request=recognition)
    assert completed["state"] == "completed", completed
    attached = str(folder / "with-transcript.cut")
    job("transcript_file_attachment_import", request=dict(recognition, project_path=seq, out_project=attached))
    attachment = job("transcript_file_attachment_inspect", request=dict(project_path=attached))
    assert [(item["status"], item["words"]) for item in attachment["attachments"]] == [("available", 1)], attachment
    assert Path(seq).read_bytes() == original


def check_shutdown(helper):
    # An editor-only environment override must never affect the private worker.
    client = Client(helper, "--files-only", env=dict(os.environ, MPCUT_TEST_SOCKET_DIRECTORY="invalid/override"))
    try:
        catalog = {tool["name"] for tool in client.pages("tools/list", "tools")}
        assert "cli_version_read" in catalog
        processes = subprocess.check_output(["ps", "-axww", "-o", "ppid=,command="], text=True)
        workers = []
        for line in processes.splitlines():
            parent, command = line.strip().split(maxsplit=1)
            if int(parent) == client.process.pid and " --file-worker " in command:
                workers.append(Path(command.rsplit(" --file-worker ", 1)[1]))
        assert len(workers) == 1, workers
        directory = workers[0]
        assert (directory / "control.sock").is_socket(), directory
        client.process.kill()
        client.process.wait(timeout=5)
        deadline = time.monotonic() + 10
        while directory.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not directory.exists(), f"Worker left its socket directory at {directory}"
    finally:
        client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path)
    args = parser.parse_args()
    signal.signal(signal.SIGALRM, timed_out)
    with tempfile.TemporaryDirectory() as temp:
        folder = Path(temp)
        provider = folder / "provider"
        shutil.copyfile(ROOT / "Tests/MPCutAppTests/Fixtures/TranscriptLifecycleProvider.py", provider)
        provider.chmod(0o755)
        (folder / "release-1").write_text("completed")
        client = Client(args.helper.resolve(), "--files-only", env=dict(os.environ, MPCUT_TRANSCRIBERRR_HELPER=str(provider)))
        try:
            signal.alarm(120)
            exercise(client, folder)
            check_shutdown(args.helper.resolve())
        finally:
            signal.alarm(0)
            client.close()
        assert client.process.returncode == 0, client.process.returncode
    print("Headless integration passed.")
