#!/usr/bin/env python3
"""Run the participant editor through macOS Accessibility with synthetic media."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from participant_e2e import geometry, interval
from participant_e2e_fixture import generate


def create_fixture(cli, directory):
    gallery, recorder, iso_offset = generate(directory)
    base = directory / "Participant GUI Base.cut"
    base.write_text(json.dumps({
        "format": "mpcut", "schema_version": 4, "kind": "multicam",
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
    saved = json.loads(result.stdout)["participants"]
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
    shot, = saved["render"]["shots"]
    if shot["layout"] != "pair" or [slot["id"] for slot in shot["slots"]] != ["host", "guest"]:
        raise AssertionError(f"Saved pair layout differs: {shot}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("cli", type=Path)
    parser.add_argument("--evidence", type=Path, help="Directory for screenshots")
    args = parser.parse_args()
    if args.evidence:
        args.evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mpcut-participant-gui-") as scratch:
        directory = Path(scratch)
        project = create_fixture(args.cli.resolve(), directory)
        driver = Path(__file__).with_suffix(".swift")
        command = ["swift", str(driver), args.app.resolve(), project]
        if args.evidence:
            command.append(args.evidence.resolve())
        subprocess.run(command, check=True, timeout=360)
        verify_saved_project(args.cli.resolve(), project)


if __name__ == "__main__":
    main()
