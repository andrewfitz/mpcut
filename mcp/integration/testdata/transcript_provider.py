#!/usr/bin/env python3
"""Deterministic batch-session responses for the packaged live MCP fixture."""

import json
import os
from pathlib import Path
import sys
import time
import wave


def engine(name):
    return {
        "name": name, "aliases": [], "included": True, "default_model": "fixture",
        "diarization": False, "minimum_macos": "14.0", "model_source": "macos",
    }


def event(manifest, name, status, **fields):
    print(json.dumps({
        "schema_version": 1, "job_id": manifest["job_id"], "fingerprint": manifest["fingerprint"],
        "event": name, "status": status, **fields,
    }), flush=True)


def main():
    if sys.argv[1:] == ["capabilities"]:
        print(json.dumps({"version": "fixture", "session_schema_version": 1,
                          "engines": [engine("qwen3"), engine("speaker-test"), engine("hold")]}))
        return
    assert sys.argv[1] == "session" and "--offline" in sys.argv
    manifest = json.load(sys.stdin)
    assert manifest["schema_version"] == 1
    if manifest.get("engine") == "hold":
        time.sleep(60)
        return
    marker = Path(".fixture-attempt")
    failed = not marker.exists()
    marker.touch()
    tracks, words = [], []
    for track in manifest["tracks"]:
        binding = track["binding"]
        coverage = "coverage_only" if binding.get("stream_index") is None else "skipped"
        output = {"id": track["track_id"], "source_id": track["source_id"],
                  "name": track["name"], "stream_evidence": track["stream_evidence"],
                  "role": track["role"], "channel": track.get("channel"), **binding}
        if track["recognize"]:
            # Verify that the app handed off the expected PCM format.
            with wave.open(track["audio"]) as wav:
                assert (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) == (16000, 1, 2)
            if failed:
                coverage = "failed"
                output["error"] = "Fixture failure on the first attempt"
            else:
                coverage = "recognized"
                local = {"id": "local", "text": "Ready", "precision": "word",
                         "start_sample": 4000, "end_sample": 8000}
                words.append({
                    **local, "id": "ready", "observations": [{
                        "track_id": output["id"], "word_id": local["id"], "text": local["text"],
                        "start_sample": 4000, "end_sample": 8000, "evidence": "recognized",
                    }],
                })
                output["words"] = [local]
        output["coverage"] = coverage
        tracks.append(output)
        event(manifest, "track_finished", coverage, track_id=output["id"], error=output.get("error"))
    result = {"version": 1, "sample_rate": 16000, "clock": "session", "tracks": tracks,
              "speakers": [], "words": words, "job_id": manifest["job_id"], "fingerprint": manifest["fingerprint"]}
    temporary = Path(manifest["output"]).with_suffix(".tmp")
    temporary.write_text(json.dumps(result))
    os.replace(temporary, manifest["output"])
    event(manifest, "session_finished", "partial" if failed else "completed")


if __name__ == "__main__":
    main()
