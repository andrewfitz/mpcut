#!/usr/bin/env python3
"""Exercise imported transcript clocks and saved edits against a built MPCut CLI."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import wave
from saved_project import read_project


def run_suite(cli, directory):
    environment = dict(os.environ, MPCUT_TRANSCRIBERRR_HELPER=str(directory / "missing-helper"))

    def transcript(operation, error=None, **request):
        result = subprocess.run(
            [cli, "transcript", *operation.split(), "--json", "--stdin"],
            input=json.dumps(request), capture_output=True, text=True,
            env=environment, timeout=30,
        )
        try:
            output = json.loads(result.stdout)
        except json.JSONDecodeError as failure:
            raise AssertionError(
                f"{operation} exited {result.returncode}: {result.stdout}{result.stderr}"
            ) from failure
        if error:
            assert result.returncode != 0 and output["error"]["code"] == error, output
        else:
            assert result.returncode == 0, output
        return output

    def store(name, content):
        path = directory / name
        path.write_text(content if isinstance(content, str) else json.dumps(content))
        return str(path)

    def project(name, ranges=((0, 8),)):
        return store(name + ".cut", {
            "format": "mpcut", "schema_version": 9, "kind": "sequence",
            "clips": [
                {"id": f"clip-{index}", "file": "source.wav", "from": str(start), "to": str(end)}
                for index, (start, end) in enumerate(ranges)
            ],
        })

    def imported(name, content, ranges=((0, 8),), **options):
        path = project(Path(name).stem, ranges)
        transcript("attachment import", project_path=path, transcript=store(name, content), audio_stream_index=0,
                   in_place=True, **options)
        return path

    def locate(path, word, space="source"):
        return transcript("words locate", project_path=path, word_id=word, space=space)["items"]

    def bounds(start, end):
        return {"from": str(start), "to": str(end)}

    with wave.open(str(directory / "source.wav"), "wb") as sound:
        sound.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        sound.writeframes(bytes(8 * 16000 * 2))

    transcript("provider capabilities", error="transcript_helper_unavailable")

    zero = {"numerator": 0, "denominator": 1}
    native = {
        "source": "source.wav", "duration_seconds": 8, "sample_zero": zero,
        "speaker_names": ["Guest"], "metadata": {},
        "segments": [
            {"start": 0, "end": 8, "speaker": 0, "words": [
                {"text": "Keep", "start": 0.5, "end": 1.5},
                {"text": "This", "start": 2, "end": 3},
            ]},
        ],
    }
    repeated = imported("native.json", native, ranges=((1, 4), (0, 4)))
    raw = locate(repeated, "s0-w0")
    assert len(raw) == 1 and raw[0]["range"] == bounds("1/2", "3/2"), raw
    retimed = locate(repeated, "s0-w0", space="current_cut")
    assert [word["range"] for word in retimed] == [bounds(0, "1/2"), bounds("7/2", "9/2")], retimed
    assert [word["partial"] for word in retimed] == [True, False], retimed
    selected = transcript("words search", project_path=repeated, query="KEEP, THIS", space="current_cut")
    assert selected["total"] == 2, selected
    transcript("edit plan", project_path=repeated, action="delete", first_word_id="s0-w0",
               error="ambiguous_transcript_occurrence")
    rendered = str(directory / "repeated.srt")
    transcript("export", project_path=repeated, output=rendered, format="srt", space="current_cut")
    export_text = Path(rendered).read_text()
    assert "00:00:00,000 --> " in export_text, export_text
    assert "00:00:03,500 --> " in export_text, export_text

    segment = dict(native, segments=[{"start": 2, "end": 3, "speaker": 0, "text": "Segment only"}])
    segment_path = imported("segment.json", segment)
    segment_rows = locate(segment_path, "s0-w0")
    assert len(segment_rows) == 1 and segment_rows[0]["range"] == bounds(2, 3), segment_rows

    for extension, text in (
        ("srt", "1\n00:00:02,000 --> 00:00:03,000\n[Guest] Cue only\n"),
        ("vtt", "WEBVTT\n\n00:00:02.000 --> 00:00:03.000\n<v Guest>Cue only\n"),
    ):
        name = f"cue-{extension}.{extension}"
        path = imported(name, text)
        row, = transcript("words read", project_path=path, space="source")["items"]
        assert row["approximate"] and row["range"] == bounds(2, 3), row
        assert row.get("speaker_id"), row
        transcript("attachment bind", project_path=path, origin="1", in_place=True)
        rebound, = transcript("words read", project_path=path, space="source")["items"]
        assert rebound["range"] == bounds(3, 4) and not rebound["approximate"], rebound
        # The attached store supplies the cue even when the input subtitle has gone away.
        (directory / name).unlink()
        assert transcript("words read", project_path=path, space="source")["total"] == 1

    merged = {
        "source": "merged", "duration_seconds": 70, "speaker_names": ["Guest"],
        "segments": [{"start": 65, "end": 66, "speaker": 0, "words": [
            {"text": "Hello", "start": 65, "end": 66},
        ]}],
        "metadata": {"merged_from": [
            {"source": "source.wav", "speaker": 0, "offset_seconds": 60, "local_origin": zero},
        ]},
    }
    path = imported("merged.json", merged)
    local, = locate(path, "s0-w0")
    assert local["source_range"] == bounds(5, 6), local
    group, = locate(path, "s0-w0", space="group")
    assert group["range"] == bounds(65, 66), group

    merged["metadata"]["merged_from"].append(
        {"source": "other.wav", "speaker": 0, "offset_seconds": 60, "local_origin": zero}
    )
    ambiguous = project("ambiguous")
    transcript("attachment import", project_path=ambiguous, transcript=store("ambiguous.json", merged), in_place=True)
    unresolved, = locate(ambiguous, "s0-w0")
    assert sorted(unresolved["candidate_track_ids"]) == ["part-0", "part-1"], unresolved
    assert "source_range" not in unresolved and unresolved["range"] == bounds(65, 66), unresolved

    saved_as = str(directory / "Corrected copy.cut")
    transcript("words correct", project_path=segment_path, out_project=saved_as, first_word_id="s0-w0",
               change={"replace_text": {"text": "Corrected cue"}})
    # Every CLI call reopens its input from disk.
    corrected, = locate(saved_as, "s0-w0")
    assert corrected["text"] == "Corrected cue" and corrected["range"] == bounds(2, 3), corrected
    unchanged, = locate(segment_path, "s0-w0")
    assert unchanged["text"] == "Segment only", unchanged
    authored = read_project(Path(saved_as))
    assert len(authored["history"]["undo"]) == 1, authored["history"]

    edited = project("edited")
    transcript("attachment import", project_path=edited, transcript=str(directory / "native.json"),
               audio_stream_index=0, in_place=True)
    plan_path = str(directory / "review.json")
    transcript("edit plan", project_path=edited, output=plan_path, request={
        "action": "delete", "boundary_policy": "exact", "selections": [{"first_word_id": "s0-w1"}],
    })
    transcript("edit apply", project_path=edited, plan_file=plan_path, in_place=True)
    edited_project = read_project(Path(edited))
    kept = [bounds(clip["from"], clip["to"]) for clip in edited_project["clips"]]
    assert kept == [bounds(0, 2), bounds(3, 8)] and len(edited_project["history"]["undo"]) == 1, edited_project
    stale_plan = str(directory / "stale.json")
    transcript("edit plan", project_path=edited, action="delete", first_word_id="s0-w0", output=stale_plan)
    transcript("attachment bind", project_path=edited, origin="1/4", in_place=True)
    before_refusal = Path(edited).read_bytes()
    transcript("edit apply", project_path=edited, plan_file=stale_plan, in_place=True, error="stale_transcript_plan")
    assert before_refusal == Path(edited).read_bytes()

    count = 12_000
    long_document = dict(native, duration_seconds=count, segments=[{"start": 0, "end": count, "words": [
        {"text": "head" if index != count - 1 else "terminus", "start": index, "end": index + 0.5}
        for index in range(count)
    ]}])
    started = time.monotonic()
    long_path = imported("long.json", long_document)
    imported_at = time.monotonic()
    first_page = transcript("words read", project_path=long_path, space="source", limit=5)
    last_page = transcript("words read", project_path=long_path, space="source", offset=count - 1, limit=5)
    paged_at = time.monotonic()
    found = transcript("words search", project_path=long_path, query="TERMINUS", space="source", limit=1)
    assert first_page["total"] == count and first_page["next_offset"] == 5, first_page
    assert last_page["total"] == count and "next_offset" not in last_page, last_page
    assert found["total"] == 1 and found["items"][0]["words"][0]["word_id"] == f"s0-w{count - 1}", found

    print("Verified native, segment, SRT, WebVTT and merged imports, clock mapping, repeat export, "
          "saved correction, and exact reviewed deletion with stale-plan rejection")
    print(f"Three-hour source ({count:,} words), import {imported_at - started:.2f}s, "
          f"two pages {paged_at - imported_at:.2f}s, search {time.monotonic() - paged_at:.2f}s")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mpcut-transcripts-") as directory:
        run_suite(args.cli.resolve(), Path(directory).resolve())


if __name__ == "__main__":
    main()
