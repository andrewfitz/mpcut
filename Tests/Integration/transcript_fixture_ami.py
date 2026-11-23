#!/usr/bin/env python3
"""Replay a synchronized real AMI meeting excerpt without retaining whole recordings."""

import argparse
from collections import Counter, defaultdict
from fractions import Fraction
from hashlib import sha256
from itertools import permutations
import json
from pathlib import Path
import struct
import subprocess
import time
from urllib.request import Request, urlopen
import wave
from xml.etree import ElementTree
from zipfile import ZipFile

from transcript_fixture import RATE, samples, save_json
from transcript_fixture_baseline import edit_counts, normalize

EXCERPTS = {"ES2002a": (902, 917), "ES2004a": (578, 593), "ES2005a": (0, 15), "ES2012b": (2000, 2020)}
URL = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus"
CHANNELS = {"A": "Headset-0", "B": "Headset-1", "C": "Headset-2", "D": "Headset-3", "room": "Array1-01"}
ZERO = {"numerator": 0, "denominator": 1}
MATCH_WINDOW = samples("0.65")
DUPLICATE_PAIR_WINDOW = samples("0.125")


def fetch_range(url, first, last):
    with urlopen(Request(url, headers={"Range": f"bytes={first}-{last}"}), timeout=30) as response:
        if response.status != 206 or not response.headers.get("Content-Range", "").startswith(f"bytes {first}-{last}/"):
            raise ValueError(f"Server did not respect the requested range for {url}")
        data = response.read(last - first + 2)
    if len(data) != last - first + 1:
        raise ValueError(f"Unexpected byte count for {url}")
    return data


def crop(out, meeting, channel, start, end):
    url = f"{URL}/{meeting}/audio/{meeting}.{channel}.wav"
    header = fetch_range(url, 0, 43)
    expected = b"RIFF", b"WAVEfmt ", b"data", (16, 1, 1, RATE, RATE * 2, 2, 16)
    fields = (header[:4], header[8:16], header[36:40], struct.unpack("<IHHIIHH", header[16:36]))
    if fields != expected:
        raise ValueError(f"The fixed header no longer describes contiguous 16 kHz mono PCM for {channel}")
    audio = fetch_range(url, 44 + start * RATE * 2, 43 + end * RATE * 2)
    with wave.open(str(out), "wb") as recording:
        recording.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        recording.writeframes(audio)
    return sha256(audio).hexdigest()


def load_reference(path, meeting, start, end):
    words = []
    with ZipFile(path) as archive:
        for speaker in "ABCD":
            xml = archive.read(f"words/{meeting}.{speaker}.words.xml")
            for token in ElementTree.fromstring(xml):
                if token.tag != "w" or "starttime" not in token.attrib or "endtime" not in token.attrib:
                    continue
                text = normalize(token.text or "")
                first, last = (Fraction(token.attrib[key]) for key in ("starttime", "endtime"))
                if text and start <= first < last <= end:
                    words.append({"text": text, "start": samples(first - start), "end": samples(last - start),
                                  "speaker": speaker})
    return sorted(words, key=lambda word: (word["start"], word["end"], word["speaker"]))


def midpoint(word):
    return (word["start"] + word["end"]) / 2


def overlap(word, reference):
    return any(word["speaker"] != other["speaker"]
               and min(word["end"], other["end"]) - max(word["start"], other["start"]) >= samples("0.08")
               for other in reference)


def timed_matches(observed, reference, names=None):
    """Maximize token matches within the time window, then minimize midpoint error."""
    expected_lanes, observed_lanes = defaultdict(list), defaultdict(list)
    for index, word in enumerate(reference):
        lane = (word["text"], word["speaker"] if names is not None else None)
        expected_lanes[lane].append((midpoint(word), index))
    for index, word in enumerate(observed):
        lane = (word["text"], names.get(word["speaker"]) if names is not None else None)
        observed_lanes[lane].append((midpoint(word), index))
    matched = {}
    for lane, expected in expected_lanes.items():
        expected.sort()
        found = sorted(observed_lanes[lane])
        # A minimum-distance matching on a time axis has a chronological solution.
        # Maximize the match count first, then minimize total midpoint distance.
        row = [(0, 0, ())] * (len(found) + 1)
        for at, index in expected:
            updated = [row[0]]
            for pos, (seen_at, found_index) in enumerate(found, 1):
                choices = [row[pos], updated[-1]]
                distance = abs(at - seen_at)
                if distance <= MATCH_WINDOW:
                    count, cost, indices = row[pos - 1]
                    choices.append((count + 1, cost - distance, indices + ((index, found_index),)))
                updated.append(max(choices, key=lambda result: result[:2]))
            row = updated
        matched.update(row[-1][2])
    return matched


def score(words, reference, conversation=None, speaker_names=None):
    observed = [{"text": normalize(word["text"]), "start": word["start_sample"],
                 "end": word["end_sample"], "speaker": word.get("speaker_id")} for word in words]
    observed = [word for word in observed if word["text"]]
    assigned = timed_matches(observed, reference)
    matched = set(assigned.values())
    candidates = []
    for index, found in enumerate(observed):
        if index in matched:
            continue
        plausible = [i for i, expected in enumerate(reference) if found["text"] == expected["text"]
                     and abs(midpoint(found) - midpoint(expected)) <= MATCH_WINDOW]
        if plausible:
            candidates.append((index, plausible))
    label_supported_duplicates = 0
    for index, plausible in candidates:
        if len(plausible) != 1:
            continue
        other_index = assigned.get(plausible[0])
        if other_index is None:
            continue
        word, other = observed[index], observed[other_index]
        if (abs(midpoint(word) - midpoint(other)) <= DUPLICATE_PAIR_WINDOW
                and max(word["start"], other["start"]) < min(word["end"], other["end"])):
            label_supported_duplicates += 1
    real_overlap = reference if conversation is None else conversation
    errors = [abs(observed[found][edge] - reference[expected][edge]) / RATE * 1000
              for expected, found in assigned.items() for edge in ("start", "end")]
    speaker_votes = Counter((observed[found]["speaker"], reference[expected]["speaker"])
                            for expected, found in assigned.items() if observed[found]["speaker"] is not None)
    classes = sorted({word["speaker"] for word in reference})
    ids = sorted({label for label, _ in speaker_votes}) + [None] * len(classes)
    correct = max(sum(speaker_votes[label, speaker] for label, speaker in zip(labels, classes))
                  for labels in permutations(ids, len(classes)))
    result = {"reference": len(reference), "observed": len(observed), "matched": len(assigned),
              "overlapReference": sum(overlap(word, real_overlap) for word in reference),
              "overlapMatched": sum(overlap(reference[index], real_overlap) for index in assigned),
              "duplicateCandidates": len(candidates), "labelSupportedDuplicates": label_supported_duplicates,
              "meanEdgeErrorMS": round(sum(errors) / len(errors), 1) if errors else None,
              "speakerWrongOrUnknown": len(assigned) - correct,
              "speakerKnown": sum(speaker_votes.values())}
    if speaker_names is not None:
        named = timed_matches(observed, reference, speaker_names)
        result["namedSpeakerWrongOrUnknown"] = len(assigned) - len(named)
        result["namedMatched"] = len(named)
        result["overlapMatchedWithCorrectSpeaker"] = sum(overlap(reference[i], real_overlap) for i in named)
    return result


def summarize(document, reference, elapsed, engine):
    tracks = {}
    for track in document["tracks"]:
        name = track["id"]
        expected = reference if name == "room" else [word for word in reference if word["speaker"] == name]
        tracks[name] = {"coverage": track["coverage"], **score(track["words"], expected, reference)}
        if name != "room":
            observed = [normalize(word["text"]) for word in track["words"] if normalize(word["text"])]
            substitutions, deletions, insertions = edit_counts([word["text"] for word in expected], observed)
            tracks[name].update(substitutions=substitutions, deletions=deletions, insertions=insertions)
            tracks[name]["speakerWrongOrUnknown"] = None
    speakers = {speaker["id"]: speaker["name"] for speaker in document["speakers"]}
    raw_words = [word for track in document["tracks"] for word in track["words"]]
    possible = score(raw_words, reference)
    return {"engine": engine, "wallSeconds": round(elapsed, 2), "tracks": tracks,
            "inAnyRawTrack": {"matched": possible["matched"], "overlapMatched": possible["overlapMatched"]},
            "conversation": score(document["words"], reference, speaker_names=speakers)}


def run(archive, out, helper, engine, meeting, reuse_from=None, audio_from=None):
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    start, end = EXCERPTS[meeting]
    reference = load_reference(archive, meeting, start, end)
    job_id = f"AMI-{meeting}-{start}-{end}"
    cached_files = {}
    capabilities = json.loads(subprocess.check_output([helper, "capabilities"]))
    selected_engine = next(item for item in capabilities["engines"] if item["name"] == engine)
    diarization = {"diarization": bool(selected_engine["diarization"])}
    # The two original fixtures used the known speaker count. Later held-out
    # recordings also cover normal use with no count supplied.
    if diarization["diarization"] and meeting in {"ES2002a", "ES2004a", "ES2005a"}:
        diarization["expected_speakers"] = len({word["speaker"] for word in reference})
    if reuse_from:
        if reuse_from.resolve() == out:
            raise ValueError("Use a new output directory to preserve the original run.")
        previous = json.loads((reuse_from / "manifest.json").read_text())
        if previous["job_id"] != job_id or previous["engine"] != engine:
            raise ValueError("The original manifest must use the same meeting and engine.")
        diarization = {key: previous[key] for key in ("diarization", "expected_speakers") if key in previous}
        entries = previous["tracks"]
        for track in entries:
            track["reuse"] = True
            for key in ("audio", "result", "activity"):
                path = Path(track[key])
                cached_files[path] = sha256(path.read_bytes()).hexdigest()
    else:
        entries = []
        if audio_from:
            prior = json.loads((audio_from / "manifest.json").read_text())
            if prior["job_id"] != job_id:
                raise ValueError("Audio inputs must belong to the same meeting excerpt.")
            input_tracks = {track["track_id"]: track for track in prior["tracks"]}
        for name, channel in CHANNELS.items():
            if audio_from:
                track = input_tracks[name]
                audio = Path(track["audio"])
                with wave.open(str(audio), "rb") as recording:
                    digest = sha256(recording.readframes(recording.getnframes())).hexdigest()
                if digest != track["stream_evidence"]["fixture_sha256"]:
                    raise ValueError(f"Input audio changed on {name}")
            else:
                audio = out / f"{name}.wav"
                digest = crop(audio, meeting, channel, start, end)
            entries.append({"track_id": name, "source_id": name, "name": channel,
                            "binding": {"stream_index": 0, "origin": ZERO, "session_start": ZERO},
                            "role": "mixed_audio" if name == "room" else "isolated_mic",
                            "speaker": None if name == "room" else name, "recognize": True,
                            "stream_evidence": {"fixture_sha256": digest}, "recognition_key": f"{engine}-{digest}",
                            "start_frame": 0, "audio": str(audio), "result": str(out / f"{name}-track.json"),
                            "activity": str(out / f"{name}-activity.json")})
    output = out / "result.json"
    manifest = out / "manifest.json"
    save_json(manifest, {"schema_version": 1, "job_id": job_id,
                         "fingerprint": sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest(),
                         "engine": engine, "language": "en",
                         **diarization, "output": str(output), "tracks": entries})
    save_json(out / "reference.json", reference)
    command = [helper, "session", "--manifest", manifest, "--offline", "--jsonl"]
    if reuse_from:
        command.append("--reconcile-only")
    start = time.monotonic()
    with (out / "events.jsonl").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
    elapsed = time.monotonic() - start
    if any(sha256(path.read_bytes()).hexdigest() != digest for path, digest in cached_files.items()):
        raise ValueError("Recognition, activity, or audio changed during reconcile-only.")
    document = json.loads(output.read_text())
    if {track["id"] for track in document["tracks"] if track["coverage"] == "recognized"} != set(CHANNELS):
        raise ValueError("Expected successful recognition on every headset and the room microphone.")
    report = summarize(document, reference, elapsed, engine)
    save_json(out / "score.json", report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("annotations", type=Path, help="official AMI manual annotations 1.6.2 zip")
    parser.add_argument("output", type=Path, help="external directory for excerpts and results")
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--engine", choices=("parakeet-v3", "qwen3", "apple-native"), default="parakeet-v3")
    parser.add_argument("--meeting", choices=EXCERPTS, default="ES2002a")
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--reuse-from", type=Path, help="reconcile stored observations from an earlier run")
    inputs.add_argument("--audio-from", type=Path, help="run recognition on the verified WAVs of an earlier run")
    args = parser.parse_args()
    run(args.annotations, args.output, args.helper.resolve(), args.engine, args.meeting, args.reuse_from, args.audio_from)
