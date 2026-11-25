#!/usr/bin/env python3
"""Exercise the standalone workflow with a generated recording and an explicit provider stub.

    python3 Tests/Integration/transcript_cli.py /path/to/mpcut
"""
import argparse
from array import array
from hashlib import sha256
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid
import wave
from saved_project import read_project


PROVIDER = """#!/usr/bin/env python3
import json
import sys
from pathlib import Path

with Path(__file__).with_name("provider-calls").open("a") as log:
    print(json.dumps(sys.argv[1:]), file=log)
assert sys.argv[1] == "session"
assert "--offline" in sys.argv
manifest = json.loads(Path(sys.argv[sys.argv.index("--manifest") + 1]).read_text())
Path("provider-ran").touch()
speaker = {"id": "guest", "name": "Guest"}
tracks = []
words = []
for source in manifest["tracks"]:
    binding = source["binding"]
    track = {"id": source["track_id"], "name": source["name"], "source_id": source["source_id"],
             "stream_index": binding["stream_index"], "origin": binding["origin"],
             "session_start": binding["session_start"], "role": source["role"],
             "stream_evidence": source["stream_evidence"], "channel": source.get("channel"),
             "coverage": "recognized" if source["recognize"] else "skipped",
             "activity": [{"start_sample": 0, "end_sample": 320, "level": 0.125}]}
    tracks.append(track)
    if source["recognize"]:
        with Path(source["audio"]).open("rb") as audio:
            assert audio.read(4) == b"RIFF"
        for index, (text, start, end) in enumerate([("Expected", 16000, 20000), ("benefit.", 20000, 28000)]):
            observation = {"track_id": track["id"], "start_sample": start,
                           "end_sample": end, "evidence": "recognized"}
            words.append({"id": f"word-{index}", "text": text, "speaker_id": "guest", "precision": "word",
                          "start_sample": start + source["start_frame"], "end_sample": end + source["start_frame"],
                          "observations": [observation]})
result = {"version": 1, "clock": "session", "sample_rate": 16000, "job_id": manifest["job_id"],
          "fingerprint": manifest["fingerprint"], "speakers": [speaker], "tracks": tracks, "words": words}
Path(manifest["output"]).write_text(json.dumps(result))
"""


def exercise(cli, directory):
    env = os.environ | {"MPCUT_SIDECAR_HOME": str(directory / "cache-settings"),
                        "MPCUT_TRANSCRIBERRR_HELPER": str(directory / "provider"),
                        "MPCUT_TRANSCRIPT_CLAIMS_HOME": str(directory / "claims")}

    def call(verb, *args, request=None, fail=None):
        cmd = [cli, "transcript", *verb.split(), "--json", *map(str, args)]
        if request is not None:
            cmd.append("--stdin")
        proc = subprocess.run(cmd, cwd=directory, text=True, capture_output=True, timeout=90,
                              input=json.dumps(request) if request is not None else None, env=env)
        assert proc.stdout, (cmd, proc.returncode, proc.stderr)
        result = json.loads(proc.stdout)
        if fail:
            assert proc.returncode and result["error"]["code"] == fail, (cmd, result, proc.stderr)
        else:
            assert proc.returncode == 0, (cmd, proc.returncode, result, proc.stderr)
        return result

    recording = directory / "interview.wav"
    with wave.open(str(recording), "wb") as wav:
        wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        wav.writeframes(array("h", ([450, -450] * 8000) * 4).tobytes())
    provider = directory / "provider"
    provider.write_text(PROVIDER)
    provider.chmod(0o700)
    project = directory / "interview.cut"
    project.write_text(json.dumps({"format": "mpcut", "schema_version": 9, "kind": "sequence",
                                   "clips": [{"id": "first", "file": recording.name, "from": "0", "to": "3"},
                                             {"id": "repeat", "file": recording.name, "from": "1", "to": "3"}]}))

    help_result = subprocess.run([cli, "help", "transcript", "job", "prepare", "--json"],
                                 capture_output=True, check=True, timeout=90)
    assert json.loads(help_result.stdout)["examples"]
    inventory = call("tracks list", "--project", project)
    assert len(inventory["sessions"]) == 1
    assert len(inventory["sessions"][0]["tracks"]) == 1
    jobs = directory / "jobs"
    job = call("job prepare", "--project", project, "--job-directory", jobs, "--operation-id", uuid.uuid4(),
               "--progress", "jsonl")
    assert job["state"] == "prepared"
    assert not (directory / "provider-ran").exists()
    listed = call("job list", "--project", project, "--job-directory", jobs, "--limit", 1)
    assert listed["total"] == 1 and listed["items"][0]["id"] == job["id"] and not listed["items"][0]["attached"]
    assert call("job list", "--project", project, "--job-directory", jobs, "--offset", 1)["items"] == []
    session = job["sessions"][0]
    assert session["manifest"] and session["output"]
    subprocess.run([provider, *session["command"][1:]], cwd=directory, check=True, timeout=90)
    assert (directory / "provider-ran").exists()
    attached = call("attachment import", "--project", project, "--job-id", job["id"], "--job-directory", jobs, "--in-place")
    status = call("job status", "--job-id", job["id"], "--job-directory", jobs)
    assert status["state"] == "completed" and status["attached"]
    before_replay = project.read_bytes()
    replay = call("attachment import", "--project", project, "--job-id", job["id"], "--job-directory", jobs, "--in-place")
    assert replay["attachment"]["id"] == attached["attachment"]["id"]
    assert project.read_bytes() == before_replay

    query = {"project_path": str(project), "space": "current_cut", "query": "EXPECTED, BENEFIT", "limit": 1}
    (directory / "search.json").write_text(json.dumps(query))
    call("words search", request=query | {"project": str(project)}, fail="invalid_json")
    call("words search", "--project-path", project, "--query", "line", fail="invalid_arguments")
    match = call("words search", "--input", "search.json")
    assert match["total"] == 2 and match["next_offset"] == 1
    second_page = call("words search", request=query | {"offset": 1})
    first_words = match["items"][0]["words"]
    assert [w["word_id"] for w in first_words] == ["word-0", "word-1"]
    assert second_page["items"][0]["words"][0]["clip_id"] == "repeat"
    assert call("words locate", "--project", project, "--word-id", "word-0")["total"] == 2
    assert call("words compare", "--project", project, "--query", "expected benefit")["total"] == 2
    assert call("script align", "--project", project, "--script", "Expected benefit.")["total"] == 1
    call("script align", request={"project_path": str(project), "script_file": "-"}, fail="invalid_arguments")
    inspected = call("attachment inspect", "--project", project, "--attachment-id", attached["attachment"]["id"],
                     "--offset", sys.maxsize)
    assert len(inspected["attachments"]) == 1
    track_id = session["tracks"][0]["id"]
    inspected = call("attachment inspect", "--project", project, "--track-id", track_id, "--offset", sys.maxsize)
    assert len(inspected["attachments"]) == 1
    assert inspected["attachments"][0]["tracks"]["total"] == 1

    # A copied project reopens with only its linked recording. Each CLI command opens
    # a fresh document. Check the imported provider output and the call log after deletion.
    subprocess.run([cli, "analysis", "sidecar", "build", "--only", "index", "--json", recording],
                   env=env, cwd=directory, check=True, capture_output=True, timeout=90)
    caches = list(directory.rglob("*.cutcache"))
    assert caches, "Expected a recording cutcache before deletion"
    for cache in caches:
        cache.unlink()
    transfer = directory / "transfer"
    transfer.mkdir()
    copied_project = transfer / project.name
    shutil.copyfile(project, copied_project)
    shutil.copyfile(recording, transfer / recording.name)
    calls_before_reopen = (directory / "provider-calls").read_bytes()
    copied = read_project(copied_project)
    reference = copied["transcripts"]["attachments"][0]["asset"]
    assert set(reference) == {"sha256"}
    asset = copied["embedded_assets"]["transcripts"][reference["sha256"]]
    canonical = json.dumps(asset, sort_keys=True, separators=(",", ":")).encode()
    assert sha256(canonical).hexdigest() == reference["sha256"]
    assert asset["tracks"][0]["provider_activity"] == [{"start": "0", "end": "1/50", "level": 0.125}]
    recovered = call("attachment inspect", "--project", copied_project, "--track-id", track_id)["attachments"][0]
    assert recovered["words"] == 2
    frame = recovered["tracks"]["items"][0]["activity"]["items"][0]
    assert frame == {"start": {"numerator": 0, "denominator": 1},
                     "end": {"numerator": 1, "denominator": 50}, "level": 0.125}, frame
    assert (directory / "provider-calls").read_bytes() == calls_before_reopen
    listed = call("job list", "--project", copied_project, "--job-directory", jobs)
    assert listed["items"][0]["id"] == job["id"] and listed["items"][0]["attached"]
    original_copy = copied_project.read_bytes()
    reconciled = call("job reconcile", "--project", copied_project, "--job-directory", jobs)
    assert reconciled["id"] == job["id"] and copied_project.read_bytes() == original_copy
    assert len(reconciled["sessions"]) == 1 and reconciled["sessions"][0]["id"] != session["id"]
    subprocess.run([provider, *reconciled["sessions"][0]["command"][1:]], cwd=directory, check=True, timeout=90)
    published = call("attachment import", "--project", copied_project, "--job-id", job["id"], "--job-directory", jobs,
                     "--attachment-id", attached["attachment"]["id"], "--in-place")
    assert published["attachment"]["id"] == attached["attachment"]["id"]
    assert len(call("attachment inspect", "--project", copied_project)["attachments"]) == 1

    damaged = transfer / "damaged.cut"
    asset["words"][0]["t"] = "Changed"
    damaged.write_text(json.dumps(copied))
    call("words read", "--project", damaged, fail="invalid_embedded_asset")
    del copied["embedded_assets"]["transcripts"][reference["sha256"]]
    damaged.write_text(json.dumps(copied))
    call("words read", "--project", damaged, fail="missing_embedded_asset")

    first, last = first_words
    selection = {"first_word_id": first["word_id"], "last_word_id": last["word_id"],
                 "first_occurrence_id": first["id"], "last_occurrence_id": last["id"]}
    resolved = call("words select", request={"project_path": str(project), "selection": selection})
    assert resolved["range"] == {"from": "1", "to": "7/4"}
    repeat = second_page["items"][0]["words"]
    for expansion in ("sentence", "speaker_turn"):
        expanded = call("words select", "--project", project, "--first-word-id", repeat[1]["word_id"],
                        "--first-occurrence-id", repeat[1]["id"], "--expansion", expansion)
        assert expanded["first"]["id"] == repeat[0]["id"] and expanded["last"]["id"] == repeat[1]["id"]
    call("words select", "--project", project, "--first-word-id", "word-0", fail="ambiguous_transcript_occurrence")

    plan_path = directory / "review.json"
    plan = call("edit plan", request={"project_path": str(project), "output": str(plan_path),
                                 "request": {"action": "delete", "selections": [selection]}})
    assert plan["duration"] != plan["previous_duration"]
    assert project.read_bytes() == before_replay
    duplicate_plan = directory / "ambiguous-review.json"
    duplicate_plan.write_text('{"duration":"0",' + plan_path.read_text()[1:])
    call("edit apply", "--project", project, "--plan-file", duplicate_plan, "--in-place", fail="invalid_json")
    call("edit apply", request={"project_path": str(project), "plan_file": "-", "in_place": True}, fail="invalid_arguments")
    assert project.read_bytes() == before_replay
    reviewed = directory / "copy" / "reviewed.cut"
    reviewed.parent.mkdir()
    result = call("edit apply", "--project", project, "--plan-file", plan_path, "--out-project", reviewed)
    assert result["history_action"] and project.read_bytes() == before_replay
    assert call("words read", "--project", reviewed, "--limit", 1)["total"] == 2
    assert len(read_project(reviewed)["history"]["undo"]) == 1

    receipt = call("excerpt queue", request={"project_path": str(project), "out_project": "Expected benefit.cut",
                                     "request": {"action": "queue", "name": "Expected benefit", "selections": [selection]}})
    assert receipt["name"] == "Expected benefit"
    assert call("words read", "--project", receipt["project_path"])["total"] == 2
    finished = subprocess.run([cli, "export", "project", "render", "--project", receipt["project_path"], "--output", "excerpt.wav", "--json"],
                              capture_output=True, text=True, cwd=directory)
    assert finished.returncode == 0, (finished.stdout, finished.stderr)
    with wave.open(str(directory / "excerpt.wav")) as exported:
        assert exported.getnframes() / exported.getframerate() == 0.75

    call("words correct", request={"project_path": str(project), "in_place": True,
                             "change": {"replace_text": {"text": "Documented benefit."}}, "selection": selection})
    assert call("words search", "--project", project, "--query", "documented benefit")["total"] == 2
    assert call("words search", "--project", receipt["project_path"], "--query", "expected benefit")["total"] == 1
    original = project.read_bytes()
    call("edit apply", "--project", project, "--plan-file", plan_path, "--in-place", fail="stale_transcript_plan")
    assert project.read_bytes() == original

    captions = directory / "output.srt"
    call("export", "--project", project, "--output", captions)
    assert "Documented benefit." in captions.read_text()
    record = call("attachment inspect", "--project", project)["authoring"]["items"][0]
    replacement = record | {"change": {"replace_text": {"text": "Revised benefit."}}}
    call("words correct", request={"project_path": str(project), "in_place": True, "record": replacement})
    corrected = call("attachment inspect", "--project", project)["authoring"]
    assert corrected["total"] == 1 and corrected["items"][0]["id"] == record["id"]
    assert call("words search", "--project", project, "--query", "revised benefit")["total"] == 2
    call("attachment detach", "--project", reviewed, "--in-place")
    assert call("attachment inspect", "--project", reviewed)["attachments"] == []

    external = directory / "external.vtt"
    external.write_text("WEBVTT\n\n00:01.000 --> 00:01.750\n<v Guest>External cue.\n")
    call("attachment import", "--project", reviewed, "--transcript", external, "--in-place")
    assert call("words read", "--project", reviewed, "--space", "source")["items"][0]["approximate"]
    call("attachment bind", "--project", reviewed, "--origin", "1/8", "--in-place")
    cue = call("words read", "--project", reviewed, "--space", "source")["items"][0]
    assert not cue["approximate"] and cue["range"]["from"] == "9/8"

    # Independently attached sources can both have cue-0. The attachment and
    # occurrence addresses keep the ordered edit tied to the intended recordings.
    other = directory / "other.wav"
    other.write_bytes(recording.read_bytes())
    call("attachment bind", "--project", project, "--file", other, "--audio-stream-index", 0, "--in-place",
         fail="invalid_transcript_binding")
    original_binding = attached["attachment"]["bindings"][0]
    call("attachment bind", request={"project_path": str(project), "in_place": True,
                          "bindings": [original_binding | {"audio_stream_index": 99}]}, fail="transcript_stream_missing")
    multi = directory / "takes.cut"
    multi.write_text(json.dumps({"format": "mpcut", "schema_version": 9, "kind": "sequence",
                                 "clips": [{"id": "left", "file": recording.name, "from": "0", "to": "3"},
                                           {"id": "right", "file": other.name, "from": "0", "to": "3"}]}))
    multi_job = call("job prepare", "--project", multi, "--job-directory", jobs)
    assert len(multi_job["sessions"]) == 2
    for part in multi_job["sessions"]:
        subprocess.run([provider, *part["command"][1:]], cwd=directory, check=True)
    first_track = multi_job["sessions"][0]["tracks"][0]["id"]
    import_job = ("--project", multi, "--job-id", multi_job["id"], "--job-directory", jobs)
    rejected_copy = directory / "rejected-transcript-copy.cut"
    before_import = multi.read_bytes()
    call("attachment import", *import_job, "--track-id", first_track, "--out-project", rejected_copy,
         fail="transcript_track_missing")
    assert not rejected_copy.exists() and not (directory / "rejected-transcript-copy.cut.transcripts").exists()
    call("attachment import", *import_job, "--track-id", first_track, "--in-place", fail="transcript_track_missing")
    assert multi.read_bytes() == before_import and not (directory / "takes.cut.transcripts").exists()
    for name, file in [("left", recording), ("right", other)]:
        call("attachment import", "--project", multi, "--file", file, "--audio-stream-index", 0, "--transcript", external,
             "--attachment-id", name, "--origin", "0", "--in-place")
    imported_copy = directory / "transcript-copy.cut"
    call("attachment import", *import_job, "--out-project", imported_copy)
    imported_attachments = call("attachment inspect", "--project", imported_copy)["attachments"]
    assert len(imported_attachments) == 4 and all(entry["status"] == "available" for entry in imported_attachments)
    takes = call("words compare", "--project", multi, "--space", "source", "--query", "external cue")
    assert takes["total"] == 2
    choices = {take["words"][0]["attachment_id"]: take["words"][0] for take in takes["items"]}
    assert choices["right"]["word_id"] == choices["left"]["word_id"]
    ordered = [{"space": "source", "first_word_id": choices[name]["word_id"],
                "first_occurrence_id": choices[name]["id"]} for name in ["right", "left"]]
    order_plan = directory / "order-plan.json"
    call("edit plan", request={"project_path": str(multi), "output": str(order_plan),
                           "request": {"action": "assemble", "selections": ordered}})
    sorted_project = directory / "ordered.cut"
    call("edit apply", "--project", multi, "--plan-file", order_plan, "--out-project", sorted_project)
    right = call("words read", "--project", sorted_project, "--attachment-id", "right")["items"][0]
    left = call("words read", "--project", sorted_project, "--attachment-id", "left")["items"][0]
    assert right["range"] == {"from": "0", "to": "3/4"}
    assert left["range"] == {"from": "3/4", "to": "3/2"}
    combined = call("words read", "--project", sorted_project, "--limit", 1)
    assert combined["total"] == 2 and combined["next_offset"] == 1
    assert combined["items"][0]["attachment_id"] == "right"
    after = call("words read", request={"project_path": str(sorted_project), "offset": combined["next_offset"],
                                  "expected_attachment_results": combined["attachment_results"]})
    assert after["items"][0]["attachment_id"] == "left"
    results = call("words search", "--project", sorted_project, "--query", "external cue")
    assert [hit["words"][0]["attachment_id"] for hit in results["items"]] == ["right", "left"]
    locations = call("words locate", "--project", sorted_project, "--word-id", right["word_id"])
    assert [item["id"] for item in locations["items"]] == [right["id"], left["id"]]
    assert call("words locate", "--project", sorted_project, "--occurrence-id", left["id"])["total"] == 1
    call("words search", "--project", sorted_project, "--query", "external cue", "--occurrence-id", "nonexistent",
         fail="invalid_arguments")
    aggregate_file = directory / "aggregate.json"
    call("export", "--project", sorted_project, "--output", aggregate_file)
    aggregate = json.loads(aggregate_file.read_text())
    assert len(aggregate["words"]) == 2
    assert [word["projection"]["attachment_id"] for word in aggregate["words"]] == ["right", "left"]

    bare_output = directory / "bare-cut.cut"
    call("attachment import", "--file", recording, "--audio-stream-index", 99, "--transcript", external, "--out-project", bare_output,
         fail="transcript_stream_missing")
    assert not bare_output.exists()
    call("attachment import", "--file", recording, "--audio-stream-index", 0, "--channel", 1, "--transcript", external,
         "--output", "invalid-channel.json", fail="transcript_stream_missing")
    normalized = directory / "bare.json"
    call("attachment import", "--file", recording, "--audio-stream-index", 0, "--channel", 0, "--transcript", external,
         "--output", normalized)
    normalized_track = json.loads(normalized.read_text())["tracks"][0]
    assert normalized_track["audio_stream_index"] == 0 and normalized_track["channel"] == 0
    call("attachment import", "--file", recording, "--audio-stream-index", 0, "--channel", 0, "--transcript", external,
         "--attachment-id", "bare", "--out-project", bare_output)
    original_cue = call("words read", "--project", bare_output)["items"][0]
    assert original_cue["attachment_id"] == "bare" and original_cue["range"]["from"] == "1"
    overlay_file = directory / "overlay.srt"
    overlay_file.write_text("1\n00:00:01,125 --> 00:00:01,625\nA second voice.\n")
    call("attachment import", "--project", bare_output, "--audio-stream-index", 0, "--attachment-id", "second",
         "--transcript", overlay_file, "--in-place")
    reviewed_speech = call("edit plan", "--project", bare_output, "--attachment-id", "bare", "--action", "delete",
                           "--first-word-id", original_cue["word_id"])
    assert any(word["attachment_id"] == "second" and "second voice" in word["text"]
               for word in reviewed_speech["affected_speech"]), reviewed_speech
    pauses = directory / "pauses.srt"
    pauses.write_text("1\n00:00:00,750 --> 00:00:01,000\nBefore.\n\n"
                      "2\n00:00:01,750 --> 00:00:02,000\nAfter.\n")
    call("attachment import", "--project", bare_output, "--audio-stream-index", 0, "--attachment-id", "pauses",
         "--transcript", pauses, "--in-place")
    endpoints = call("words read", "--project", bare_output, "--attachment-id", "pauses")["items"]
    call("edit plan", "--project", bare_output, "--attachment-id", "pauses", "--action", "tighten", "--kind", "gap",
         "--first-word-id", endpoints[0]["word_id"], "--last-word-id", endpoints[1]["word_id"],
         "--retained-duration", "0", fail="transcript_gap_contains_speech")

    merged = directory / "merged-ambiguous.json"
    merged.write_text(json.dumps({"source": "Session", "duration_seconds": 80,
                                  "metadata": {"merged_from": [
                                      {"source": "Part 1.wav", "speaker": 0, "offset_seconds": 0},
                                      {"source": "Part 2.wav", "speaker": 0, "offset_seconds": 60}]},
                                  "segments": [{"text": "Ambiguous part.", "start": 65, "end": 66, "speaker": 0}]}))
    call("attachment import", "--project", bare_output, "--transcript", merged, "--attachment-id", "merged", "--in-place")
    ambiguous = call("words read", "--project", bare_output, "--space", "source", "--attachment-id", "merged")["items"][0]
    assert ambiguous["range"]["from"] == "65" and "source_range" not in ambiguous
    assert ambiguous["candidate_track_ids"] == ["part-0", "part-1"]
    renamed = directory / "renamed-cut.cut"
    bare_output.rename(renamed)
    assert call("words read", "--project", renamed, "--attachment-id", "bare")["total"] == 1
    call("attachment bind", "--project", renamed, "--attachment-id", "bare", "--origin", "1/8", "--in-place")
    renamed_attachment = call("attachment inspect", "--project", renamed, "--attachment-id", "bare")["attachments"][0]["attachment"]
    digest = renamed_attachment["asset"]["sha256"]
    transcript = read_project(renamed)["embedded_assets"]["transcripts"][digest]
    assert transcript["schema_version"] == 4 and transcript["words"]
    assert not Path(str(renamed) + ".transcripts").exists()

    bare = call("job prepare", "--file", recording, "--job-directory", jobs)
    assert call("job cancel", "--job-id", bare["id"], "--job-directory", jobs)["state"] == "cancelled"
    marker = directory / "provider-ran"
    marker.unlink()
    assert call("job retry", "--job-id", bare["id"], "--job-directory", jobs)["state"] == "prepared"
    assert not marker.exists()

    tracked = call("words read", "--project", project, "--space", "source", "--track-id", original_binding["track_id"], "--limit", 1)
    assert tracked["input_coverage"]["tracks"]["total"] == 1
    available_track = tracked["input_coverage"]["tracks"]["items"][0]
    assert available_track["binding_status"] == "available"
    assert available_track["bounds"] == {"from": "0", "to": "4"}
    moved = directory / "temporarily-offline.wav"
    recording.rename(moved)
    try:
        inspection = call("attachment inspect", "--project", project)
        assert inspection["attachments"][0]["tracks"]["items"][0]["source_status"] == "offline"
        offline = call("words read", "--project", project, "--space", "source")
        assert offline["total"] == 2
        offline_track = offline["input_coverage"]["tracks"]["items"][0]
        assert offline_track["binding_status"] == "offline" and "bounds" not in offline_track
    finally:
        moved.rename(recording)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mpcut-transcript-") as temp:
        exercise(str(args.cli.resolve()), Path(temp).resolve())
    print("Transcript CLI handoff, attachments, review, edits, queue, and export passed.")
