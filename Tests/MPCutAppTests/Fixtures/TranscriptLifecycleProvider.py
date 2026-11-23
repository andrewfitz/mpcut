#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys
import time
import wave

if sys.argv[1:] == ["capabilities"]:
    print(json.dumps({"version": "lifecycle-fixture", "session_schema_version": 1, "engines": [{
        "name": "lifecycle-fixture", "aliases": [], "included": True, "default_model": "fixture",
        "diarization": False, "minimum_macos": "14.0", "model_source": "macos"
    }]}))
    sys.exit()

assert sys.argv[1] == "session" and "--offline" in sys.argv
manifest = json.load(sys.stdin)
assert manifest["schema_version"] == 1
folder = Path(__file__).parent
attempt = 1
while (folder / f"started-{attempt}").exists():
    attempt += 1
started = folder / f"started-{attempt}"
started_temp = started.with_suffix(".tmp")
started_temp.write_text(str(os.getpid()))
started_temp.replace(started)
gate = folder / f"release-{attempt}"
deadline = time.monotonic() + 45
parent = int(os.environ.get("TRANSCRIBERRR_PARENT_PID", os.getppid()))
while not gate.exists():
    if os.getppid() != parent:
        sys.exit(1)
    assert time.monotonic() < deadline, "Fixture did not release the helper"
    time.sleep(0.025)
status = gate.read_text()

def event(name, state, **extra):
    print(json.dumps({"schema_version": 1, "job_id": manifest["job_id"],
                      "fingerprint": manifest["fingerprint"], "event": name,
                      "status": state, **extra}), flush=True)

tracks, words = [], []
for ordinal, track in enumerate(manifest["tracks"]):
    output = {"id": track["track_id"], "source_id": track["source_id"], "name": track["name"],
              "stream_evidence": track["stream_evidence"], "role": track["role"],
              "channel": track.get("channel"), **track["binding"]}
    coverage = "recognized"
    if status == "partial" and ordinal == 1:
        assert not track.get("reuse")
        coverage = "failed"
        output["error"] = "Fixture recognition failed"
    else:
        result_path = Path(track["result"])
        if track.get("reuse"):
            local_words = json.loads(result_path.read_text())["words"]
        else:
            with wave.open(track["audio"]) as wav:
                assert (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) == (16000, 1, 2)
                duration = wav.getnframes()
            local_words = [{"id": "local", "text": "Ready", "precision": "word",
                            "start_sample": 4000, "end_sample": 8000,
                            "speaker_id": "person", "utterance_id": "fixture-utterance"}] if ordinal == 0 else []
            # A long recording: many short words after the first, for tests that time a large result.
            local_words += [{"id": f"local-{extra}", "text": "again", "precision": "word",
                             "start_sample": 8000 + 2 * extra, "end_sample": 8002 + 2 * extra,
                             "speaker_id": "person", "utterance_id": "fixture-utterance"}
                            for extra in range(int(os.environ.get("MPCUT_FIXTURE_EXTRA_WORDS", "0")) if ordinal == 0 else 0)]
            activity = [{"start_sample": start, "end_sample": min(start + 320, duration), "level": 0.25}
                        for start in range(0, duration, 320)]
            evidence = {"version": 1, "sample_rate": 16000, "stream_evidence": track["stream_evidence"],
                        "duration_samples": duration, "activity": activity}
            Path(track["activity"]).write_text(json.dumps(evidence))
            result_path.write_text(json.dumps({
                **evidence, "recognition_key": track.get("recognition_key"), "words": local_words
            }))
        output["words"] = local_words
        output["speakers"] = [{"id": "person", "name": "Fixture speaker"}] if local_words else []
        for local in local_words:
            offset = track["start_frame"]
            words.append({**local, "id": local["id"].replace("local", "ready"), "start_sample": local["start_sample"] + offset,
                          "end_sample": local["end_sample"] + offset, "observations": [{
                              "track_id": output["id"], "word_id": local["id"], "text": local["text"],
                              "start_sample": local["start_sample"], "end_sample": local["end_sample"],
                              "evidence": "recognized", "speaker_id": "person",
                          }]})
    output["coverage"] = coverage
    tracks.append(output)
    event("track_finished", coverage, track_id=output["id"], error=output.get("error"))
result = {"version": 1, "sample_rate": 16000, "clock": "session", "tracks": tracks,
          "speakers": [{"id": "person", "name": "Fixture speaker"}],
          "words": words, "job_id": manifest["job_id"], "fingerprint": manifest["fingerprint"]}
destination = Path(manifest["output"])
temporary = destination.with_suffix(".tmp")
temporary.write_text(json.dumps(result))
temporary.replace(destination)
event("session_finished", status)
