"""Exercise saved participant workflows through the standalone MCP file worker."""

import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "docs"))
from mcp_walkthrough import Client, timed_out
from saved_project import read_project


def exercise(client, folder, ffmpeg, test_feed_layouts=False):
    def run(tool, *, error=None, **fields):
        receipt = client.call(tool, operation_id=str(uuid.uuid4()), **fields)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            state = client.call("file_job_status_read", job_id=receipt["job_id"])
            if state["state"] not in ("running", "cancelling"):
                assert state["state"] == ("failed" if error else "succeeded"), (tool, state)
                result = client.job_result(state)
                if error:
                    assert result["error"]["code"] == error, (tool, state, result)
                return result
            client.wait_for_poll()
        raise TimeoutError(tool)

    gallery = str(folder / "gallery.mov")
    project = str(folder / "interview.cut")
    analysis = str(folder / "gallery.json")
    accepted = str(folder / "accepted.cut")
    reviewed = str(folder / "reviewed.cut")
    movie = str(folder / "program.mov")
    angles_directory = str(folder / "angles")

    subprocess.run([
        ffmpeg, "-nostdin", "-v", "error",
        "-f", "lavfi", "-i", "color=black:s=320x180:r=10:d=2",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:d=2",
        "-vf", "drawbox=x=0:y=0:w=152:h=ih:color=red:t=fill,drawbox=x=168:y=0:w=152:h=ih:color=blue:t=fill",
        "-c:v", "libx264", "-c:a", "pcm_s16le", gallery,
    ], check=True)
    assert "participants_file_scan" in {tool["name"] for tool in client.pages("tools/list", "tools")}
    run("project_file_create", request={
        "kind": "sequence", "out_project": project,
        "operations": [{"action": "append", "id": "gallery", "file": gallery}],
    })
    scan = run("participants_file_scan", file=gallery, backend="cpu-only", no_sidecar=True, output=analysis)
    assert scan["state"] == "completed", scan["state"]
    assert scan["analysis"]["tracks"], scan["analysis"]["observations"][0]
    if test_feed_layouts:
        for layout in ("auto", "2x1"):
            feeds = run("participants_file_scan", file=gallery, backend="cpu-only", no_sidecar=True, feed_layout=layout)
            assert feeds["configuration"]["feed_layout"] == layout
            assert len(feeds["analysis"]["tracks"]) == 2
            assert all(len(frame["regions"]) == 2 for frame in feeds["analysis"]["observations"])
    assert json.loads(Path(analysis).read_text())["analysis_identity"] == scan["analysis_identity"]
    run("participants_file_markers_build", analysis_file=analysis,
        rule={"unit": "participants", "threshold": "any", "kinds": ["enter"], "settling_window_ms": 100})

    source = read_project(Path(project))["clips"][0]["file"]
    run("participants_file_project_accept", project_path=project, source_id=source,
        analysis_file=analysis, out_project=accepted)
    result = run("participants_file_project_inspect", project_path=accepted)
    assert result["people"] and result["sources"][0]["appearances"], result

    plan = {"canvas": {"width": 160, "height": 90, "frame_rate": {"numerator": 10, "denominator": 1}},
            "shots": [{"layout": "solo", "slots": [{"id": result["people"][0]["id"]}]}]}
    result["render"] = plan
    participant_file = folder / "edit.json"
    participant_file.write_text(json.dumps(result))
    receipt = run("participants_file_project_apply", project_path=accepted,
                  participants_file=str(participant_file), out_project=reviewed)
    assert receipt["operation_count"] == 1, receipt
    report = run("participants_file_render_plan", project_path=reviewed, output=movie)
    assert report["frame_count"] == 20 and report["publishable"] and not Path(movie).exists(), report
    run("participants_file_render_export", project_path=reviewed, output=movie)
    assert Path(movie).stat().st_size > 0

    saved = read_project(Path(reviewed))
    request = {"project_path": reviewed, "source_id": saved["clips"][0]["file"],
               "participant_ids": [result["people"][0]["id"]],
               "range": {"from": "0", "to": "2"}, "include_original": True}
    virtual = run("participants_file_angles_list", **request)
    assert [item["kind"] for item in virtual["angles"]] == ["participant", "original"], virtual
    report = run("participants_file_angles_plan", canvas=plan["canvas"], **request)
    assert len(report["angles"]) == 2, report
    delivery = run("participants_file_angles_render", canvas=plan["canvas"],
                   output_directory=angles_directory, **request)
    assert Path(delivery["project_path"]).is_file(), delivery
    assert len(list(Path(angles_directory).glob("*.mov"))) >= 2, delivery

    result["sources"][0]["coverage"] = []
    result["render"] = {
        "canvas": plan["canvas"],
        "shots": [{"layout": "original"}],
        "redactions": [{"participant_id": result["people"][0]["id"], "treatment": "opaque"}],
    }
    private = str(folder / "private.cut")
    blocked = str(folder / "blocked.mov")
    run("participants_file_project_apply", project_path=accepted, participants=result, out_project=private)
    report = run("participants_file_render_plan", project_path=private, output=blocked)
    assert not report["publishable"] and report["privacy_issues"], report
    run("participants_file_render_export", project_path=private, output=blocked,
        error="unresolved_participant_privacy")
    assert not Path(blocked).exists()

    take = str(folder / "take.cut")
    run("participants_file_angles_take", project_path=reviewed, angle=virtual["angles"][1], output_time="1",
        out_project=take)
    taken = run("participants_file_project_inspect", project_path=take)
    shots = taken["render"]["shots"]
    assert any(shot["layout"] == "original" and shot.get("range") == {"from": "1", "to": "2"}
               for shot in shots), shots


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--feed-layouts", action="store_true", help="exercise TileTrail 0.2 feed detection")
    args = parser.parse_args()
    signal.signal(signal.SIGALRM, timed_out)
    with tempfile.TemporaryDirectory() as temp:
        client = Client(args.helper.resolve(), "--files-only", poll_interval=0.05)
        try:
            signal.alarm(120)
            exercise(client, Path(temp), args.ffmpeg, args.feed_layouts)
        finally:
            signal.alarm(0)
            client.close()
        assert client.process.returncode == 0, client.process.returncode
    print("Participant MCP integration passed.")
