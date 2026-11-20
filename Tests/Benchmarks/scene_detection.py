#!/usr/bin/env python3
"""Generate labeled multicam-style edits and compare MPCut with FFmpeg scdet."""
import argparse
import itertools
import json
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
from time import perf_counter


FPS = 30
SIZE = "640x360"

# The tight shots use crops of the corresponding wide shots.
VIEWS = {
    "A": ("293b46", 48, 36, "160:89:142:189", "375:151:143:118"),
    "B": ("3e3430", 54, 42, "355:102:136:177", "103:59:119:217"),
    "C": ("454b2d", 34, 60, "75:129:190:135", "482:77:130:177"),
    "D": ("323850", 80, 22, "244:33:174:186", "72:159:137:125"),
}
ORDER = (
    ("A", 58), ("B", 52), ("A", 63), ("C", 44), ("A-tight", 55),
    ("D", 8), ("B", 61), ("B-tight", 45), ("D", 49), ("A-tight", 32),
    ("B-tight", 67), ("C", 48), ("A", 59),
)
# Blender's source MOV runs at exactly 24 fps. These are zero-based frames
# annotated by comparing adjacent pictures in two excerpts.
TEARS_HARD_CUTS = (966, 1010, 1095, 1195, 1227, 1288, 1360)
TEARS_GRADUAL_TRANSITION = range(1135, 1155)
TEARS_HOLDOUT_CUTS = (1778, 1905, 1971, 2036, 2218)


def run(argv):
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{argv[0]} exited {result.returncode}\n{result.stderr[-4000:]}")
    return result


def montage_graph(order, flash):
    chains = []
    for index, (view, frames) in enumerate(order):
        base = view.split("-")[0]
        background, grid_width, grid_height, window, desk = VIEWS[base]
        chains.extend([
            f"color=0x{background}:s={SIZE}:r={FPS},"
            f"drawgrid=w={grid_width}:h={grid_height}:t=1:c=white@0.20,"
            f"drawbox={window}:t=fill:c=0x96a5ae,"
            f"drawbox={desk}:t=fill:c=0x865743[set{index}]",
            f"color=0xbca76e:s=54x78:r={FPS}[actor{index}]",
        ])
        subject = {"A": 245, "B": 373, "C": 148, "D": 304}[base]
        filters = [
            f"[set{index}][actor{index}]overlay="
            f"x='{subject}+24*sin(2*t+{index}/5)':y='181+10*sin(t+{index}/8)'",
        ]
        if view.endswith("-tight"):
            center = 102 if base == "A" else 223
            filters.append(f"crop=384:216:{center}:104,scale={SIZE.replace('x', ':')}")
        if flash and index in (1, 8):
            filters.append("drawbox=c=white:t=fill:enable='eq(n,21)'")
        filters.append(f"trim=end_frame={frames}[v{index}]")
        chains.append(",".join(filters))
    chains.append("".join(f"[v{i}]" for i in range(len(order))) + f"concat=n={len(order)}:v=1:a=0")
    return ";".join(chains)


def make_source(ffmpeg, path, *, flash):
    run([ffmpeg, "-hide_banner", "-v", "error", "-f", "lavfi", "-i", montage_graph(ORDER, flash),
         "-an", "-c:v", "libx264", "-crf", "17", "-preset", "veryfast", "-g", "120",
         "-pix_fmt", "yuv420p", str(path)])


def quality(expected, actual, tolerance=0.25 / FPS):
    remaining = set(range(len(actual)))
    hits = []
    for target in expected:
        if not remaining:
            break
        nearest = min(remaining, key=lambda index: abs(actual[index] - target))
        if abs(actual[nearest] - target) <= tolerance:
            remaining.remove(nearest)
            hits.append(nearest)
    return {"found": len(hits), "missed": len(expected) - len(hits),
            "falsePositives": len(remaining)}


def scene_start(scene):
    if "start" in scene:
        return scene["start"]["numerator"] / scene["start"]["denominator"]
    return scene["startSeconds"]


def mpcut(mpcut_cli, path):
    report = json.loads(run([mpcut_cli, "scenes", str(path), "--json"]).stdout)
    return [scene_start(scene) for scene in report["scenes"]][1:], report


def scdet(ffmpeg, path, threshold=10):
    # Decode and scale on the media engine, then convert the tiny frame for scdet.
    video_filter = f"scale_vt=w=64:h=36,hwdownload,format=nv12,format=yuv420p,scdet=t={threshold}"
    result = run([ffmpeg, "-hide_banner", "-nostats",
                  "-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld",
                  "-i", str(path), "-map", "0:v:0", "-an", "-sn", "-dn",
                  "-vf", video_filter, "-f", "null", "-"])
    return [float(time) for time in re.findall(r"lavfi\.scd\.time:\s*([0-9.]+)", result.stderr)], {}


def sample(operation, count):
    times = []
    for _ in range(count):
        started = perf_counter()
        cuts, report = operation()
        times.append(perf_counter() - started)
    return cuts, report, round(statistics.median(times), 3)


def summarize_view_groups(report, expected):
    actual = [scene["view"] for scene in report["scenes"]]
    if len(actual) != len(expected):
        return {"estimatedViews": report["viewCount"], "expectedViews": len(set(expected))}
    pairs = list(itertools.combinations(range(len(actual)), 2))
    correct = sum((actual[i] == actual[j]) == (expected[i] == expected[j]) for i, j in pairs)
    return {"estimatedViews": report["viewCount"], "expectedViews": len(set(expected)),
            "correctFrameGroupPairs": correct, "frameGroupPairs": len(pairs)}


def benchmark(args, directory):
    durations = list(itertools.accumulate(frames for _, frames in ORDER))
    expected = [frame / FPS for frame in durations[:-1]]
    results = {}
    for name, flash in [("multicam", False), ("multicam-with-flashes", True)]:
        path = directory / f"{name}.mp4"
        make_source(args.fixture_ffmpeg, path, flash=flash)
        cuts, report, elapsed = sample(lambda: mpcut(args.mpcut, path), args.runs)
        baseline, _, baseline_seconds = sample(lambda: scdet(args.ffmpeg, path, args.scdet_threshold), args.runs)
        results[name] = {"durationSeconds": durations[-1] / FPS,
                         "mpcut": {**quality(expected, cuts), "seconds": elapsed,
                                   **summarize_view_groups(report, [name for name, _ in ORDER])},
                         "scdet": {**quality(expected, baseline), "seconds": baseline_seconds}}
    for path in args.extra:
        cuts, report, elapsed = sample(lambda: mpcut(args.mpcut, path), args.runs)
        baseline, _, baseline_seconds = sample(lambda: scdet(args.ffmpeg, path, args.scdet_threshold), args.runs)
        results[str(path)] = {"mpcut": {"cuts": len(cuts), "estimatedViews": report["viewCount"], "seconds": elapsed},
                              "scdet": {"cuts": len(baseline), "seconds": baseline_seconds}}
    if args.tears_of_steel:
        def tuning_excerpt(times):
            return [time for time in times if 40 <= time < 64 and round(time * 24) not in TEARS_GRADUAL_TRANSITION]

        def holdout_excerpt(times):
            return [time for time in times if 70 <= time < 94]

        def scored_excerpts(times):
            return {
                "tuningExcerpt": quality([frame / 24 for frame in TEARS_HARD_CUTS], tuning_excerpt(times)),
                "holdoutExcerpt": quality([frame / 24 for frame in TEARS_HOLDOUT_CUTS], holdout_excerpt(times)),
            }

        cuts, report, elapsed = sample(lambda: mpcut(args.mpcut, args.tears_of_steel), args.runs)
        baseline, _, baseline_seconds = sample(
            lambda: scdet(args.ffmpeg, args.tears_of_steel, args.scdet_threshold), args.runs)
        results["tears-of-steel"] = {
            "durationSeconds": 17620 / 24,
            "mpcut": {**scored_excerpts(cuts), "cutsTotal": len(cuts),
                      "estimatedViews": report["viewCount"], "seconds": elapsed},
            "scdet": {**scored_excerpts(baseline), "cutsTotal": len(baseline), "seconds": baseline_seconds},
        }
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", help="Path to the built mpcut executable")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="Reference FFmpeg with VideoToolbox and scdet")
    parser.add_argument("--fixture-ffmpeg", default="ffmpeg", help="Fixture generator with libx264")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--scdet-threshold", type=float, default=10, help="FFmpeg scene score threshold")
    parser.add_argument("--extra", action="append", default=[], type=Path,
                        help="Additional unlabeled source for throughput measurements")
    parser.add_argument("--tears-of-steel", type=Path,
                        help="Original Blender 720p MOV for hand-annotated excerpts and full-film throughput")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    if not 0 <= args.scdet_threshold <= 100:
        parser.error("--scdet-threshold must be between 0 and 100")
    with tempfile.TemporaryDirectory(prefix="mpcut-scene-benchmark-") as temporary:
        print(json.dumps(benchmark(args, Path(temporary)), indent=2))
