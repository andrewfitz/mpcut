#!/usr/bin/env python3
"""Run an offline session against two licensed LibriSpeech test-clean excerpts."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import subprocess
import tarfile
import time
import wave

from media_regression import ffmpeg
from transcript_fixture import RATE, save_json
from transcript_fixture_baseline import edit_counts, normalize

UTTERANCES = ("1089-134686-0001", "1221-135766-0000")
ZERO = {"numerator": 0, "denominator": 1}


def read_member(archive, name):
    with archive.extractfile(name) as member:
        return member.read()


def prepare(archive, out, utterance, engine):
    speaker, chapter, _ = utterance.split("-")
    source = f"LibriSpeech/test-clean/{speaker}/{chapter}"
    flac = out / f"{utterance}.flac"
    flac.write_bytes(read_member(archive, f"{source}/{utterance}.flac"))
    transcript = read_member(archive, f"{source}/{speaker}-{chapter}.trans.txt").decode()
    reference = next(line.split(maxsplit=1)[1] for line in transcript.splitlines()
                     if line.split(maxsplit=1)[0] == utterance)
    audio = out / f"{utterance}.wav"
    ffmpeg("-y", "-i", flac, "-ar", str(RATE), "-ac", "1", "-c:a", "pcm_s16le", audio)
    result = out / f"{utterance}-result.json"
    manifest = out / f"{utterance}-manifest.json"
    digest = sha256(audio.read_bytes()).hexdigest()
    save_json(manifest, {
        "schema_version": 1, "job_id": utterance, "fingerprint": digest, "output": str(result),
        "engine": engine, "language": "en", "tracks": [{
            "track_id": utterance, "source_id": utterance, "name": utterance,
            "binding": {"stream_index": 0, "origin": ZERO, "session_start": ZERO},
            "role": "isolated_mic", "recognize": True, "start_frame": 0,
            "stream_evidence": {"fixture_sha256": digest}, "recognition_key": f"{engine}-{digest}",
            "audio": str(audio), "result": str(out / f"{utterance}-track.json"),
            "activity": str(out / f"{utterance}-activity.json"),
        }],
    })
    with wave.open(str(audio), "rb") as recording:
        duration = recording.getnframes() / RATE
    return manifest, result, reference, duration


def run(archive_path, out, helper, engine):
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    reports = []
    with tarfile.open(archive_path) as archive:
        license_bytes = read_member(archive, "LibriSpeech/LICENSE.TXT")
        if b"Creative Commons Attribution 4.0 International License" not in license_bytes:
            raise ValueError("Missing the expected LibriSpeech license in the local archive")
        (out / "LICENSE.TXT").write_bytes(license_bytes)
        for utterance in UTTERANCES:
            manifest, result, reference, duration = prepare(archive, out, utterance, engine)
            start = time.monotonic()
            with (out / f"{utterance}-run.log").open("w") as log:
                subprocess.run([helper, "session", "--manifest", manifest, "--offline", "--jsonl"],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
            elapsed = time.monotonic() - start
            document = json.loads(result.read_text())
            if document["tracks"][0]["coverage"] != "recognized":
                raise ValueError(f"The helper did not recognize {utterance}: {document['tracks'][0]['error']}")
            observed = [normalize(word["text"]) for word in document["words"] if normalize(word["text"])]
            expected = [normalize(word) for word in reference.split()]
            substitutions, deletions, insertions = edit_counts(expected, observed)
            reports.append({"utterance": utterance, "seconds": duration, "referenceWords": len(expected),
                            "observedWords": len(observed), "substitutions": substitutions,
                            "deletions": deletions, "insertions": insertions,
                            "wordErrorRate": (substitutions + deletions + insertions) / len(expected),
                            "wallSeconds": round(elapsed, 2)})
    report = {"engine": engine, "results": reports}
    save_json(out / "score.json", report)
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="local OpenSLR test-clean.tar.gz archive")
    parser.add_argument("output", type=Path, help="external scratch directory for audio and results")
    parser.add_argument("--helper", required=True, type=Path, help="session-capable Transcriberrr executable")
    parser.add_argument("--engine", choices=("apple-native", "parakeet-v3", "qwen3"), default="apple-native")
    args = parser.parse_args()
    run(args.archive, args.output, args.helper, args.engine)


if __name__ == "__main__":
    main()
