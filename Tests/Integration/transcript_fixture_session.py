#!/usr/bin/env python3
"""Score the session-capable provider on the independently labeled spoken fixture."""

import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import time

from transcript_fixture import RATE, samples, save_json
from transcript_fixture_baseline import normalize, report_track


def clock(time):
    return Fraction(time["numerator"], time["denominator"])


def evaluate(document, truth):
    phrases = truth["phrases"]
    words = document["words"]
    report = report_track({"segments": [{"words": [
        {"text": word["text"], "start": word["start_sample"] / RATE,
         "end": word["end_sample"] / RATE, "speaker": word.get("speaker_id")}
        for word in words
    ]}]}, phrases)
    mistake_count = report["matchedWords"] - report["scoredSpeakerWords"] + (report["speakerMistakes"] or 0)
    tokens = [normalize(word["text"]) for word in words]
    retake_start = [words[i]["start_sample"] for i in range(len(words) - 2)
                   if tokens[i:i + 3] == ["the", "lantern", "glows"]]
    retakes_valid = len(retake_start) == 3 and all(
        abs(observed - expected) <= samples("0.45")
        for observed, expected in zip(retake_start, (samples(second) for second in (3, 7, 11)))
    )
    by_source = {track["source_id"]: track for track in document["tracks"]}
    close = by_source["close"]
    signed_starts = {name: str(clock(track["session_start"])) for name, track in by_source.items()}
    offsets_valid = signed_starts == {name: item["offset"] for name, item in truth["tracks"].items()}
    burst = truth["nonSpeech"][0]
    offset = samples(clock(close["session_start"]))
    activity = any(frame["level"] > 0 and frame["start_sample"] + offset < burst["end"]
                   and frame["end_sample"] + offset > burst["start"] for frame in close["activity"])
    recognized_close = [
        (word, observation)
        for word in words for observation in word["observations"]
        if observation["track_id"] == close["id"] and observation["evidence"] == "recognized"
    ]
    close_observations = [observation for _, observation in recognized_close]
    burst_recognized = sorted({word["text"] for word in close["words"] + close_observations
                               if burst["start"] <= (word["start_sample"] + word["end_sample"]) / 2 + offset
                               < burst["end"]})
    off_air = next(phrase for phrase in phrases if phrase["id"] == "off-air")
    tolerance = samples("0.35")
    local_words = {word["id"]: word for word in close["words"]}
    off_air_matches = [
        (word, observation) for word, observation in recognized_close
        if off_air["start"] - tolerance <= (word["start_sample"] + word["end_sample"]) / 2
        < off_air["end"] + tolerance
    ]
    off_air_matches.sort(key=lambda match: match[0]["start_sample"])
    off_air_words = [normalize(observation["text"]) for _, observation in off_air_matches]
    keys = ("text", "start_sample", "end_sample")
    off_air_valid = len(off_air_matches) == len(off_air["words"]) and all(
        normalize(word["text"]) == normalize(observation["text"]) == normalize(reference["text"])
        and all(evidence["track_id"] == close["id"] or evidence["evidence"] != "recognized"
                for evidence in word["observations"])
        and 0 <= observation["start_sample"] < observation["end_sample"]
        and abs(observation["start_sample"] + offset - reference["start"]) <= tolerance
        and abs(observation["end_sample"] + offset - reference["end"]) <= tolerance
        and all(observation[key] == local_words.get(observation["word_id"], {}).get(key) for key in keys)
        for (word, observation), reference in zip(off_air_matches, off_air["words"])
    )
    report["retakeOnsets"] = [sample / RATE for sample in retake_start]
    report["speakerMistakesOrUnresolved"] = mistake_count
    report["closeBurstHasActivity"] = activity
    report["closeBurstRecognizedWords"] = burst_recognized
    report["closeOffAirWords"] = off_air_words
    report["signedStarts"] = signed_starts
    report["perTrackObservedWords"] = {
        name: sum(bool(normalize(word["text"])) for word in track["words"])
        for name, track in by_source.items()
    }
    edge_error = report["timingEdgeMAEMilliseconds"]
    report["checks"] = {
        "wordRecall": report["matchedWords"] >= 36,
        "wordErrorRateAndInsertions": report["wordErrorRate"] <= .10 and report["insertions"] <= 3,
        "offAir": report["phrases"]["off-air"]["matchedWords"] == 5
        and off_air_valid,
        "interruption": report["phrases"]["interrupt"]["matchedWords"] == 3,
        "retakes": retakes_valid,
        "noSpuriousDuplicates": report["repeatedReferenceWords"] == 0,
        "speakerAttribution": mistake_count <= 2,
        "groupWordTiming": edge_error is not None and edge_error <= 300,
        "activityDoesNotCreateRecognitions": activity and not burst_recognized,
        "signedStarts": offsets_valid,
    }
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--result", type=Path, help="score a result produced by MPCut or an earlier helper run")
    parser.add_argument("--report", type=Path, help="destination for the JSON score")
    args = parser.parse_args()
    root = args.fixture.resolve()
    folder = root / "helper-session"
    result_path = args.result or folder / "result.json"
    elapsed = None
    if args.helper:
        start = time.monotonic()
        with (folder / "run.log").open("w") as log:
            subprocess.run([args.helper, "session", "--manifest", folder / "manifest.json", "--offline", "--jsonl"],
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
        elapsed = time.monotonic() - start
    report = evaluate(json.loads(result_path.read_text()), json.loads((root / "truth.json").read_text()))
    if elapsed is not None:
        report["wallSeconds"] = round(elapsed, 2)
    save_json(args.report or folder / "score.json", report)
    print(json.dumps(report, indent=2))
    return 0 if all(report["checks"].values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
