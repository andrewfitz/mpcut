#!/usr/bin/env python3
"""Run the installed batch helper offline and score the spoken fixture."""

import argparse
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from itertools import permutations
import json
from pathlib import Path
import re
from statistics import mean
import subprocess
import time

from transcript_fixture import RATE, save_json


def normalize(word):
    return re.sub(r"[^a-z0-9]", "", word.lower())


def edit_counts(reference, observed):
    """Minimum word edit distance as (substitutions, deletions, insertions)."""
    prior = [(0, 0, i) for i in range(len(observed) + 1)]
    for i, expected in enumerate(reference, 1):
        row = [(0, i, 0)]
        for j, token in enumerate(observed, 1):
            unchanged = prior[j - 1]
            if expected == token:
                row.append(unchanged)
                continue
            substitute = (unchanged[0] + 1, unchanged[1], unchanged[2])
            delete = (prior[j][0], prior[j][1] + 1, prior[j][2])
            insert = (row[-1][0], row[-1][1], row[-1][2] + 1)
            row.append(min((substitute, delete, insert), key=sum))
        prior = row
    return prior[-1]


def report_track(document, phrases):
    recognized = defaultdict(list)
    for segment in document["segments"]:
        for word in segment.get("words", []):
            token = normalize(word["text"])
            if not token:
                continue
            center = (word["start"] + word["end"]) * RATE / 2
            candidates = [phrase for phrase in phrases if phrase["start"] - RATE / 4 <= center
                          <= phrase["end"] + RATE / 4]
            if candidates:
                def key(phrase):
                    matching = [reference for reference in phrase["words"] if normalize(reference["text"]) == token]
                    distance = min((abs(center - (reference["start"] + reference["end"]) / 2)
                                    for reference in matching), default=float("inf"))
                    return distance, abs(center - (phrase["start"] + phrase["end"]) / 2)
                label = min(candidates, key=key)["id"]
            else:
                label = None
            recognized[label].append((token, word, word.get("speaker", segment.get("speaker"))))

    timing = []
    attribution = defaultdict(Counter)
    results = {}
    duplicates = 0
    for phrase in phrases:
        expected = [normalize(word["text"]) for word in phrase["words"]]
        observed = recognized[phrase["id"]]
        observed_text = [normalized for normalized, _, _ in observed]
        matcher = SequenceMatcher(None, expected, observed_text, autojunk=False)
        matched = 0
        for block in matcher.get_matching_blocks():
            for i in range(block.size):
                reference = phrase["words"][block.a + i]
                _, result, speaker = observed[block.b + i]
                matched += 1
                for edge in ("start", "end"):
                    timing.append(abs(reference[edge] / RATE - result[edge]) * 1000)
                if speaker is not None:
                    attribution[speaker][phrase["speaker"]] += 1
        count = sum(observed_text[i:i + len(expected)] == expected
                    for i in range(len(observed_text) - len(expected) + 1))
        duplicates += max(0, count - 1)
        expected_counts = Counter(expected)
        excess = sum(max(0, count - expected_counts[token]) for token, count in Counter(observed_text).items()
                     if token in expected_counts)
        substitutions, deletions, insertions = edit_counts(expected, observed_text)
        results[phrase["id"]] = {"expectedWords": len(expected), "matchedWords": matched,
                                 "repeatedReferenceWords": excess, "recognized": " ".join(observed_text),
                                 "substitutions": substitutions, "deletions": deletions, "insertions": insertions}

    lexical = sum(item["matchedWords"] for item in results.values())
    reference_count = sum(item["expectedWords"] for item in results.values())
    observed_count = sum(len(items) for items in recognized.values())
    errors = {name: sum(item[name] for item in results.values()) for name in ("substitutions", "deletions", "insertions")}
    errors["insertions"] += len(recognized[None])
    have_speaker = sum(sum(counts.values()) for counts in attribution.values())
    # Speaker IDs are arbitrary. Choose a one-to-one assignment for the labeled speakers.
    speakers = sorted({phrase["speaker"] for phrase in phrases})
    labels = list(attribution) + [None] * len(speakers)
    best = max(sum(attribution[label][speaker] for label, speaker in zip(mapping, speakers))
               for mapping in permutations(labels, len(speakers)))
    return {"expectedWords": reference_count, "matchedWords": lexical, "observedWords": observed_count,
            **errors, "wordErrorRate": round(sum(errors.values()) / reference_count, 3) if reference_count else None,
            "repeatedReferenceWords": sum(item["repeatedReferenceWords"] for item in results.values()),
            "timingEdgeMAEMilliseconds": round(mean(timing), 1) if timing else None,
            "speakerMistakes": have_speaker - best if have_speaker else None, "scoredSpeakerWords": have_speaker,
            "duplicateUtterances": duplicates, "outsideReferenceWords": [item[0] for item in recognized[None]],
            "phrases": results}


def baseline(helper, root, engine):
    out = root / "baseline" / engine
    out.mkdir(parents=True, exist_ok=True)
    tracks = ("wide", "close", "lav")
    truth = json.loads((root / "truth.json").read_text())
    inputs = [root / f"{track}-recognition.wav" for track in tracks]
    command = [helper, *inputs, "--offline", "--engine", engine, "--overwrite", "--jsonl", "-o", out]
    if engine != "apple-native":
        command.extend(("--speakers", "2"))
    start = time.monotonic()
    with (out / "run.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=False, timeout=240)
    elapsed = time.monotonic() - start
    scores = {}
    for track, input_path in zip(tracks, inputs):
        path = out / (input_path.stem + ".json")
        if result.returncode == 0 and path.exists():
            phrases = [phrase for phrase in truth["phrases"] if track in phrase["tracks"]]
            scores[track] = report_track(json.loads(path.read_text()), phrases)
    scores_path = out / "score.json"
    save_json(scores_path, {"engine": engine, "returnCode": result.returncode, "wallSeconds": round(elapsed, 2),
                            "realTimeFactor": round(elapsed / (len(inputs) * truth["duration"] / RATE), 3),
                            "tracks": scores})
    print(scores_path, flush=True)
    return result.returncode == 0 and len(scores) == len(tracks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--helper", type=Path,
                        default=Path("/Applications/Transcriberrr.app/Contents/Helpers/transcriberrr"))
    parser.add_argument("--engine", action="append", choices=("parakeet-v3", "apple-native", "qwen3"))
    args = parser.parse_args()
    results = [baseline(args.helper, args.fixture, engine)
               for engine in args.engine or ("parakeet-v3", "apple-native", "qwen3")]
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
