#!/usr/bin/env python3
"""Verify an ordered two-source transcript edit and its rendered audio and video.

Usage: python3 Tests/Integration/transcript_takes.py /path/to/mpcut
"""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile

from media_regression import ffmpeg, probe, ratio, sample_hashes
from mixed_timeline import frame_count, gray, power, samples
from saved_project import read_project


SCRIPT = "Results are usually ready today."
RATE = 48000
SIZE = (64, 48)


def make_take(path, luma, frequency, readings):
    # Fixed one-second closed GOPs give the review both exact picture cuts
    # inside a GOP and verifiable stream-copy alternatives on the GOP grid.
    # A copy starts on a keyframe. It can end before one, and wherever every
    # earlier-coded picture also presents earlier: with runs of twelve and ten
    # B pictures that is only pictures 1 and 14 of each group. The ends that
    # the review requests, pictures 20 and 45, are then nearest to a keyframe,
    # so its copy-safe alternatives stay on the GOP grid.
    ffmpeg("-f", "lavfi", "-i", f"nullsrc=s=64x48:r=25:d=4,geq=lum={luma}:cb=128:cr=128",
           "-f", "lavfi", "-i", f"sine=frequency={frequency}:sample_rate={RATE}:duration=4",
           "-c:v", "libx264", "-preset", "ultrafast", "-g", "25", "-sc_threshold", "0",
           "-bf", "12", "-x264-params", "b-adapt=0:open-gop=0",
           "-threads", "1", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", path)
    types = "".join(frame["pict_type"] for frame in
                    probe(path, "-select_streams", "v:0", "-show_entries", "frame=pict_type")["frames"])
    assert types == ("I" + "B" * 12 + "P" + "B" * 10 + "P") * 4, types
    segments = [
        {"start": words[0][1], "end": words[-1][2], "speaker": 0,
         "words": [{"text": text, "start": start, "end": end} for text, start, end in words]}
        for words in readings
    ]
    transcript = path.with_suffix(".json")
    transcript.write_text(json.dumps({"source": path.name, "duration_seconds": 4,
                                      "speaker_names": ["Unknown"], "metadata": {}, "segments": segments}))
    return transcript


def word_selection(first, last):
    assert first["attachment_id"] == last["attachment_id"]
    return {"space": "source", "attachment_id": first["attachment_id"],
            "first_word_id": first["word_id"], "first_occurrence_id": first["id"],
            "last_word_id": last["word_id"], "last_occurrence_id": last["id"]}


def exercise(cli, directory):
    def call(*args, request=None, fail=None):
        cmd = [cli, *map(str, args), "--json"]
        if request is not None:
            cmd.append("--stdin")
        proc = subprocess.run(cmd, cwd=directory, text=True, capture_output=True, timeout=90,
                              input=json.dumps(request) if request is not None else None)
        assert proc.stdout, (cmd, proc.returncode, proc.stderr)
        result = json.loads(proc.stdout)
        if fail:
            assert proc.returncode and result["error"]["code"] == fail, (cmd, result, proc.stderr)
        else:
            assert proc.returncode == 0, (cmd, result, proc.stderr)
        return result

    left = directory / "left.mov"
    right = directory / "right.mov"
    complete = [("Slate.", .16, .32), ("Results", .4, .6), ("are", .6, .8), ("usually", 1.24, 1.4),
                ("ready", 1.4, 1.6), ("today.", 1.6, 1.8), ("Reset.", 1.84, 1.96)]
    unqualified = [("Results", 2.4, 2.6), ("are", 2.6, 2.8), ("ready", 2.8, 3), ("today.", 3, 3.2)]
    left_transcript = make_take(left, 70, 440, [complete, unqualified])
    right_transcript = make_take(right, 180, 880, [complete])
    project = directory / "takes.cut"
    project.write_text(json.dumps({"format": "mpcut", "schema_version": 3, "kind": "sequence",
                                   "clips": [{"id": path.stem, "file": path.name, "from": "0", "to": "4"}
                                             for path in (left, right)]}))
    for video, transcript in ((left, left_transcript), (right, right_transcript)):
        call("transcript", "attachment", "import", "--project", project, "--file", video, "--audio-stream-index", "1",
             "--transcript", transcript, "--attachment-id", video.stem, "--origin", "0", "--in-place")

    comparison = call("transcript", "words", "compare", "--project", project, "--space", "source", "--query", SCRIPT)
    assert comparison["total"] == 3, comparison
    aligned = call("transcript", "script", "align", "--project", project, "--space", "source", "--script", SCRIPT)
    assert aligned["total"] == 1, aligned
    beat = aligned["items"][0]
    assert beat["status"] == "ambiguous" and len(beat["candidates"]) == 3, beat
    exact = {c["words"][0]["attachment_id"]: c["words"] for c in beat["candidates"] if c["kind"] == "exact"}
    assert set(exact) == {"left", "right"}, beat
    assert exact["left"][0]["word_id"] == exact["right"][0]["word_id"]
    assert exact["left"][0]["id"] != exact["right"][0]["id"]
    context = {take["words"][0]["attachment_id"]: take for take in comparison["items"] if take["kind"] == "exact"}
    slate = context["right"]["before"][-1]
    reset = context["left"]["after"][0]
    assert (slate["text"], reset["text"]) == ("Slate.", "Reset.")
    missing, = [c for c in beat["candidates"] if "usually" in c["missing_terms"]]
    assert missing["words"][0]["attachment_id"] == "left"
    qualifier, = [item for item in beat["qualifiers"] if item["text"] == "usually"]
    assert set(qualifier["present_in"]) == {words[0]["id"] for words in exact.values()}
    assert qualifier["absent_from"] == [missing["words"][0]["id"]]

    opening = word_selection(exact["right"][0], exact["right"][1])
    ending = word_selection(exact["left"][2], exact["left"][-1])
    target = {"project_path": str(project)}
    for name, selection in (("Opening", opening), ("Qualified ending", ending)):
        call("transcript", "words", "correct", request=target | {"attachment_id": selection["attachment_id"], "in_place": True,
             "change": {"named_select": {"name": name}}, "selection": selection})
    call("transcript", "words", "correct", request=target | {"attachment_id": "left", "in_place": True, "selection": ending,
         "change": {"split_speaker": {"speaker_id": "producer", "name": "Producer"}}})

    reviewed = directory / "review.json"
    edit = {"action": "assemble", "selections": [opening, ending]}
    before = read_project(project)
    strict = call("transcript", "edit", "plan", request=target | {"output": str(reviewed),
                  "request": edit | {"boundary_policy": "exact"}})
    assert strict["previous_tier"]["mode"] == "copy" and strict["tier"]["mode"] in {"smart", "encode"}, strict
    boundaries = strict["boundaries"]
    requested = [Fraction(value) for value in ("2/5", "4/5", "31/25", "9/5")]
    assert [b["attachment_id"] for b in boundaries] == ["right", "right", "left", "left"], boundaries
    assert [ratio(b["requested"]) for b in boundaries] == requested, boundaries
    assert [ratio(b["resolved"]) for b in boundaries] == requested, boundaries
    assert all(b["copy_safe_alternatives"] and b["requested"] not in b["copy_safe_alternatives"]
               for b in strict["boundaries"]), strict
    assert any(f["id"] in {"cut_video_start", "cut_video_end"} for f in strict["tier"]["factors"]), strict

    safe = call("transcript", "edit", "plan", request=target | {"request": edit | {"boundary_policy": "copy_safe"}})
    assert safe["tier"]["mode"] == "copy" and safe["duration"] != strict["duration"], safe
    for original, adjusted in zip(strict["boundaries"], safe["boundaries"], strict=True):
        assert adjusted["resolved"] in original["copy_safe_alternatives"], (original, adjusted)
    assert slate["word_id"] in safe["boundaries"][0]["affected_word_ids"], safe
    assert reset["word_id"] in safe["boundaries"][-1]["affected_word_ids"], safe
    safe_plan = directory / "safe.json"
    safe_plan.write_text(json.dumps(safe))
    safe_project = directory / "safe.cut"
    call("transcript", "edit", "apply", "--project", project, "--plan-file", safe_plan, "--out-project", safe_project)
    assert read_project(project) == before

    result = call("transcript", "edit", "apply", "--project", project, "--plan-file", reviewed, "--in-place")
    assert result["history_action"] == strict["history_action"]
    reopened = read_project(project)
    undo = reopened["history"]["undo"]
    assert len(undo) == len(before["history"]["undo"]) + 1
    assert undo[0]["action"] == result["history_action"]
    clips = reopened["clips"]
    assert [(Path(clip["file"]).name, clip["from"], clip["to"]) for clip in clips] == [
        (right.name, "2/5", "4/5"), (left.name, "31/25", "9/5")]
    records = call("transcript", "attachment", "inspect", "--project", project)["authoring"]["items"]
    assert {r["change"]["named_select"]["name"] for r in records if "named_select" in r["change"]} == {
        "Opening", "Qualified ending"}
    for attachment, name, expected, span in [
            ("right", "Opening", ["Results", "are"], ("0", "2/5")),
            ("left", "Qualified ending", ["usually", "ready", "today."], ("2/5", "24/25"))]:
        reading = call("transcript", "words", "read", "--project", project, "--attachment-id", attachment)
        words = reading["items"]
        assert [word["text"] for word in words] == expected, reading
        assert (words[0]["range"]["from"], words[-1]["range"]["to"]) == span, reading
        select, = [entry for entry in reading["authoring"]["items"]
                   if entry["change"].get("named_select", {}).get("name") == name]
        assert all(anchor["status"] == "resolved" for anchor in select["anchors"]), select
        if attachment == "left":
            assert all(word["speaker_id"] == "producer" for word in reading["items"]), reading
            assert {"id": "producer", "name": "Producer"} in reading["speakers"]["items"], reading

    failed = call("export", "project", "render", "--project", project, "--mode", "copy", "--output", directory / "unsafe.mov",
                  "--dry-run", fail="unsafe_boundary")
    assert failed["error"]["reason"] in {"cut_video_start", "cut_video_end"}, failed
    rendered = directory / f"rendered.{strict['tier']['container']}"
    written = call("export", "project", "render", "--project", project, "--mode", strict["tier"]["mode"], "--output", rendered)
    assert written["tier"]["id"] == strict["tier"]["id"] and written["mode"] == strict["tier"]["mode"], written
    duration = ratio(strict["duration"])
    assert written["encoded_duration"]["numerator"] > 0, written
    assert frame_count(rendered) == duration * 25
    source_packets = sample_hashes(right, "v:0")[10:20] + sample_hashes(left, "v:0")[31:45]
    assert sample_hashes(rendered, "v:0") != source_packets
    audio = samples(rendered, RATE)
    assert abs(len(audio) - duration * RATE) < RATE // 25, len(audio)
    for at, expected_source, expected_frequency, other_frequency in [
            (.15, right, 880, 440), (.65, left, 440, 880)]:
        expected_picture = gray(expected_source, .5, size=SIZE)
        picture = gray(rendered, at, size=SIZE)
        assert abs(sum(picture) - sum(expected_picture)) / len(picture) < 3
        window = audio[int(at * RATE):int((at + .08) * RATE)]
        assert power(window, expected_frequency, RATE) > 10 * power(window, other_frequency, RATE)
    assert len(probe(rendered, "-show_streams")["streams"]) == 2

    # The copy-safe alternative must really preserve compressed GOP samples.
    copied = directory / f"copied.{safe['tier']['container']}"
    written_copy = call("export", "project", "render", "--project", safe_project, "--mode", "copy", "--output", copied)
    assert written_copy["tier"]["id"] == safe["tier"]["id"], written_copy
    right_from, right_to, left_from, left_to = (int(25 * ratio(b["resolved"])) for b in safe["boundaries"])
    assert written_copy["encoded_duration"]["numerator"] == 0, written_copy
    assert sample_hashes(copied, "v:0") == (sample_hashes(right, "v:0")[right_from:right_to]
                                           + sample_hashes(left, "v:0")[left_from:left_to])
    samples_per_frame = RATE // 25
    assert samples(copied, RATE) == (
        samples(right, RATE)[right_from * samples_per_frame:right_to * samples_per_frame]
        + samples(left, RATE)[left_from * samples_per_frame:left_to * samples_per_frame])
    print(f"Three readings, qualifier, named selects, and speaker correction passed. "
          f"Strict {strict['tier']['id']} ({duration}s) and verified copy ({ratio(safe['duration'])}s) passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mpcut-transcript-takes-") as temp:
        exercise(str(args.cli.resolve(strict=True)), Path(temp).resolve())
