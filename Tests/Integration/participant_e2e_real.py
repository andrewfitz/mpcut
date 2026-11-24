#!/usr/bin/env python3
"""Verify an accepted crop on TileTrail's licensed Jitsi development fixture."""

import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import subprocess
from time import perf_counter

from media_regression import ffmpeg, probe
from participant_e2e import rational
from participant_e2e_fixture import frame_times
from saved_project import read_project

SOURCE_SHA = "02ed5ace27ab4b1fda6e0c93807c25c1a9775b7edeb519bfd707cf1debfc26d5"
WIDTH, HEIGHT, FPS = 264, 320, 12


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as content:
        for chunk in iter(lambda: content.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def native_rect(appearance, size):
    rect = appearance["bounds"]
    return [rect[key] * dimension for key, dimension in zip(("x", "y", "width", "height"), (*size, *size))]


def iou(first, second):
    x, y, width, height = first
    left, top, other_width, other_height = second
    intersection = (max(0, min(x + width, left + other_width) - max(x, left))
                    * max(0, min(y + height, top + other_height) - max(y, top)))
    return intersection / (width * height + other_width * other_height - intersection)


def luma(path, timestamp, rect=None):
    filters = ["scale=66:80:flags=area"]
    if rect is not None:
        x, y, width, height = rect
        filters.insert(0, f"crop={width}:{height}:{x}:{y}:exact=1")
    data = ffmpeg("-ss", str(float(timestamp)), "-i", path, "-map", "0:v:0", "-vf", ",".join(filters),
                  "-frames:v", "1", "-pix_fmt", "gray", "-f", "rawvideo", "-")
    assert len(data) == 66 * 80, (path.name, timestamp)
    return data


def run(cli, fixtures, evidence):
    cli_version = subprocess.check_output([cli, "--version"], text=True, timeout=10).strip()
    source = fixtures / "media" / "jitsi-gallery.mp4"
    assert digest(source) == SOURCE_SHA, source
    labels = json.loads((fixtures / "labels.json").read_text())
    fixture, = (fixture for fixture in labels["fixtures"] if fixture["clip"] == source.name)
    size = tuple(fixture["size"])
    native, = probe(source, "-select_streams", "v:0", "-show_streams")["streams"]
    assert (native["width"], native["height"]) == size and fixture["source_start_sec"] == 8
    source_times = frame_times(source, native)
    duration = Fraction(native["time_base"]) * int(native["duration_ts"])
    assert duration == 3

    evidence.mkdir(parents=True)
    notice = evidence / "README.md"
    notice.write_text("""# Real Jitsi participant crop

The solo.mov derivative crops the participant tile from the muted, three-second
Jitsi development excerpt at original recording time 00:08–00:11. The crop is
scaled to 264 × 320 at 12 fps and encoded as H.264. The derivative retains the
original CC BY-SA 4.0 license.

The original recording is *Abstract Wikipedia Volunteer Corner 2023-09.webm*,
September 18, 2023, by **DVrandecic (WMF)**.
[Original recording](https://commons.wikimedia.org/w/index.php?title=File:Abstract_Wikipedia_Volunteer_Corner_2023-09.webm&oldid=1004710052) · [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)

The result.json report records the CLI and media checksums, CLI arguments,
accepted participant ID, and comparison with the native development annotations.
""")
    commands = {}

    def invoke(label, *args, request=None):
        words = [*map(str, args), "--no-sidecar", "--json"]
        if request is not None:
            words.append("--stdin")
        start = perf_counter()
        completed = subprocess.run([cli, *words], input=json.dumps(request) if request is not None else None,
                                   capture_output=True, text=True, timeout=180)
        commands[label] = {"arguments": words, "request": request, "seconds": round(perf_counter() - start, 3)}
        if completed.returncode:
            raise RuntimeError(f"{label} exited {completed.returncode}\n{completed.stdout}{completed.stderr}")
        return json.loads(completed.stdout)

    scan_path = evidence / "scan.json"
    scan = invoke("scan", "participants", "scan", "--file", source, "--backend", "cpu-only",
                  "--sampling", "every-frame", "--output", scan_path)
    assert scan["state"] == "completed"
    assert {diag["backend"] for diag in scan["analysis"]["diagnostics"]} == {"cpu"}
    assert [rational(obs["timestamp"]) for obs in scan["analysis"]["observations"]] == source_times
    base = evidence / "source.cut"
    base.write_text(json.dumps({"format": "mpcut", "schema_version": 4, "kind": "sequence",
                                "clips": [{"id": "gallery", "file": str(source), "from": "0", "to": str(duration)}]}))
    accepted_path = evidence / "accepted.cut"
    invoke("accept", "participants", "project", "accept",
           request={"project_path": str(base), "out_project": str(accepted_path),
                    "source_id": str(source), "analysis_file": str(scan_path)})
    participants = read_project(accepted_path)["participants"]
    geometry, = participants["sources"]
    assert geometry["analysis_identity"] == scan["analysis_identity"]

    matches = []
    target_id = "a"
    for sample in fixture["samples"]:
        timestamp = Fraction(sample["tick"], labels["frames_per_second"])
        assert timestamp in source_times
        target, = (tile for tile in sample["tiles"] if tile["id"] == target_id)
        candidates = [item for item in geometry["appearances"] if item["state"] == "video"
                      and item.get("participant_id") and rational(item["range"]["from"]) <= timestamp
                      < rational(item["range"]["to"])]
        assert candidates, f"No accepted video tile at {timestamp} seconds"
        best = max(candidates, key=lambda item: iou(native_rect(item, size), target["box"]))
        rect = native_rect(best, size)
        overlap = iou(rect, target["box"])
        assert overlap >= 0.80, (timestamp, overlap, rect)
        matches.append((timestamp, sample, target, best["participant_id"], rect, overlap))
    participant, = {match[3] for match in matches}
    assert participant in {person["id"] for person in participants["people"]}

    output = evidence / "solo.mov"
    plan = {"canvas": {"width": WIDTH, "height": HEIGHT, "frame_rate": {"numerator": FPS, "denominator": 1}},
            "shots": [{"layout": "solo", "slots": [{"id": participant, "framing": "fill"}]}],
            "audio": {"mode": "silence"}}
    render = invoke("render", "participants", "render", "export",
                    request={"project_path": str(accepted_path), "plan": plan, "output": str(output)})
    assert render["publishable"]
    stream, = probe(output, "-select_streams", "v:0", "-show_streams")["streams"]
    assert (stream["width"], stream["height"], stream["codec_name"]) == (WIDTH, HEIGHT, "h264")
    output_times = frame_times(output, stream)
    assert output_times == [Fraction(index, FPS) for index in range(int(duration * FPS))]
    assert Fraction(stream["time_base"]) * int(stream["duration_ts"]) == duration
    assert probe(output, "-select_streams", "a", "-show_streams")["streams"] == []

    comparisons = []
    for timestamp, sample, target, _, rect, overlap in matches:
        actual = luma(output, timestamp)
        errors = {}
        for tile in sample["tiles"]:
            reference = luma(source, timestamp, tile["box"])
            errors[tile["id"]] = sum(abs(left - right) for left, right in zip(actual, reference)) / len(actual)
        target_error = errors.pop(target_id)
        competitor, other_error = min(errors.items(), key=lambda item: item[1])
        assert target_error <= 18 and target_error < 0.70 * other_error, (timestamp, target_error, other_error)
        comparisons.append({"timestamp": str(timestamp), "annotation": target["box"], "accepted_rectangle": rect,
                            "iou": overlap, "luma_mae_8bit": target_error, "closest_other_annotation": competitor,
                            "closest_other_luma_mae_8bit": other_error})
    result = {"status": "passed", "fixture": source.name, "source_sha256": SOURCE_SHA, "cli_sha256": digest(cli),
              "cli_version": cli_version,
              "output_sha256": digest(output), "cli": str(cli), "participant_id": participant,
              "annotation_id": target_id, "source_frames": len(source_times), "output_frames": len(output_times),
              "duration": str(duration), "canvas": [WIDTH, HEIGHT], "output_fps": FPS,
              "frame_comparisons": comparisons, "commands": commands}
    (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    with notice.open("a") as file:
        file.write(f"\nPassed. The CPU scan observed all {len(source_times)} native frames. A single generated\n"
                   f"participant ID matched both annotations without geometry edits. The render has\n"
                   f"{len(output_times)} exact presentation timestamps at {FPS} fps and lasts {duration} seconds.\n\n"
                   "| Clip time | Tile IoU | Target luma MAE | Nearest other tile luma MAE |\n"
                   "| --- | --- | --- | --- |\n")
        for item in comparisons:
            file.write(f"| {item['timestamp']} s | {item['iou']:.3f} | {item['luma_mae_8bit']:.2f} | "
                       f"{item['closest_other_luma_mae_8bit']:.2f} |\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    parser.add_argument("development_fixtures", type=Path, help="TileTrail validation/real directory")
    parser.add_argument("evidence", type=Path, help="Path to a new evidence directory")
    args = parser.parse_args()
    run(args.mpcut.resolve(strict=True), args.development_fixtures.resolve(strict=True), args.evidence.resolve())
