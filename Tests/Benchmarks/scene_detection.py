#!/usr/bin/env python3
"""Generate labeled multicam-style edits and compare MPCut with FFmpeg scdet."""
import argparse
import itertools
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
import threading
from time import perf_counter

from benchmark_cli import command_help, normalize_report


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
    result = subprocess.run(argv, capture_output=True, text=True, timeout=3600)
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
    return scene["start_seconds"]


def measured_run(argv):
    # wait4 returns usage for this CLI invocation, including decoder allocations.
    # Temporary files let FFmpeg fill stderr without blocking on a pipe.
    with tempfile.TemporaryFile(mode="w+") as stdout, tempfile.TemporaryFile(mode="w+") as stderr:
        started = perf_counter()
        with subprocess.Popen(argv, stdout=stdout, stderr=stderr) as child:
            # wait4 has no timeout of its own. A stalled child is killed, which
            # surfaces below as a nonzero exit instead of blocking the benchmark.
            watchdog = threading.Timer(3600, child.kill)
            watchdog.daemon = True
            watchdog.start()
            try:
                _, status, usage = os.wait4(child.pid, 0)
            finally:
                watchdog.cancel()
            elapsed = perf_counter() - started
            child.returncode = os.waitstatus_to_exitcode(status)
        stderr.seek(0)
        if child.returncode:
            raise RuntimeError(f"{argv[0]} exited {child.returncode}\n{stderr.read()[-4000:]}")
        stdout.seek(0)
        rss_mib = usage.ru_maxrss / (1024 ** 2 if sys.platform == "darwin" else 1024)
        return stdout.read(), stderr.read(), (elapsed, rss_mib, usage.ru_utime + usage.ru_stime)


def mpcut(cli, path):
    command, legacy = cli
    stdout, _, metrics = measured_run([*command, str(path), "--json"])
    report = json.loads(stdout)
    if legacy:
        report = normalize_report(report)
    return [scene_start(scene) for scene in report["scenes"]][1:], report, metrics


def uncached_command(binary):
    help_output = command_help(binary)
    legacy = "scenes scan" not in help_output
    flags = ["--no-sidecar"] if "--no-sidecar" in help_output else []
    command = ["scenes"] if legacy else ["scenes", "scan"]
    return [binary, *flags, *command], legacy


def scdet(ffmpeg, path, threshold, pixel_format):
    if pixel_format is None:
        decode = []
        scale = "scale=w=64:h=36:flags=neighbor"
    else:
        decode = ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"]
        scale = f"scale_vt=w=64:h=36,hwdownload,format={pixel_format}"
    _, stderr, metrics = measured_run([ffmpeg, "-hide_banner", "-nostats", *decode,
                                      "-i", str(path), "-map", "0:v:0", "-an", "-sn", "-dn",
                                      "-vf", f"{scale},format=yuv420p,scdet=t={threshold}",
                                      "-f", "null", "-"])
    return [float(time) for time in re.findall(r"lavfi\.scd\.time:\s*([0-9.]+)", stderr)], {}, metrics


def measure(args, path, score, pixel_format="nv12"):
    operations = {"mpcut": lambda: mpcut(args.mpcut, path)}
    if args.baseline:
        operations["baseline"] = lambda: mpcut(args.baseline, path)
    if not args.skip_scdet:
        operations["scdet"] = lambda: scdet(args.ffmpeg, path, args.scdet_threshold, pixel_format)
    samples = {name: [] for name in operations}
    outputs = {}
    for repeat in range(-args.warmups, args.runs):
        # Reverse alternating rounds to share first-reader/cache and thermal effects.
        order = list(operations) if repeat % 2 == 0 else reversed(operations)
        for name in order:
            cuts, report, metrics = operations[name]()
            if repeat < 0:
                continue
            if name in outputs and outputs[name] != (cuts, report):
                raise RuntimeError(f"{name} produced inconsistent results on {path}")
            outputs[name] = (cuts, report)
            samples[name].append(metrics)
    result = {}
    for name, history in samples.items():
        times, rss, cpu = zip(*history)
        result[name] = {**score(*outputs[name]), "seconds": round(statistics.median(times), 3),
                        "peakRSSMiB": round(statistics.median(rss), 1),
                        "cpuSeconds": round(statistics.median(cpu), 3)}
    if args.baseline:
        result["reportsIdentical"] = outputs["mpcut"][1] == outputs["baseline"][1]
    return result


def summarize_view_groups(report, expected):
    actual = [scene["view"] for scene in report["scenes"]]
    if len(actual) != len(expected):
        return {"estimatedViews": report["view_count"], "expectedViews": len(set(expected))}
    pairs = list(itertools.combinations(range(len(actual)), 2))
    correct = sum((actual[i] == actual[j]) == (expected[i] == expected[j]) for i, j in pairs)
    return {"estimatedViews": report["view_count"], "expectedViews": len(set(expected)),
            "correctFrameGroupPairs": correct, "frameGroupPairs": len(pairs)}


def benchmark(args, directory):
    durations = list(itertools.accumulate(frames for _, frames in ORDER))
    expected = [frame / FPS for frame in durations[:-1]]
    def score_montage(cuts, report):
        accuracy = quality(expected, cuts)
        if report:
            accuracy.update(summarize_view_groups(report, [name for name, _ in ORDER]))
        return accuracy

    def score_unlabeled(cuts, report):
        result = {"cuts": len(cuts)}
        if report:
            result["estimatedViews"] = report["view_count"]
        return result

    results = {}
    for name, flash in [("multicam", False), ("multicam-with-flashes", True)]:
        path = directory / f"{name}.mp4"
        make_source(args.fixture_ffmpeg, path, flash=flash)
        results[name] = {"durationSeconds": durations[-1] / FPS,
                         **measure(args, path, score_montage)}

    if args.codec_matrix:
        # Remux one Main10 encode so only the HEVC sample entry changes.
        hevc = "hevc-main10-2160p.mp4"
        matrix = [
            (hevc, "multicam.mp4", "p010le",
             ["-vf", "scale=3840:2160", "-c:v", "hevc_videotoolbox", "-profile:v", "main10",
              "-pix_fmt", "p010le", "-b:v", "12M", "-tag:v", "hev1"]),
            ("hevc-main10-hvc1-2160p.mp4", hevc, "p010le", ["-c:v", "copy", "-tag:v", "hvc1"]),
            ("prores-422-2160p.mov", "multicam.mp4", "p210le",
             ["-vf", "scale=3840:2160", "-c:v", "prores_videotoolbox", "-profile:v", "standard", "-pix_fmt", "p210le"]),
            ("ffv1-1080p.mkv", "multicam.mp4", None,
             ["-vf", "scale=1920:1080", "-c:v", "ffv1", "-level", "3", "-pix_fmt", "yuv420p", "-threads", "4"]),
        ]
        for name, source, decoder_format, options in matrix:
            path = directory / name
            run([args.fixture_ffmpeg, "-hide_banner", "-v", "error", "-i", str(directory / source),
                 *options, "-an", str(path)])
            results[name] = {"durationSeconds": durations[-1] / FPS,
                             **measure(args, path, score_montage, decoder_format)}

    for path in args.extra:
        # An arbitrary codec may have no VideoToolbox output surface.
        results[str(path)] = measure(args, path, score_unlabeled, pixel_format=None)
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

        def score_film(cuts, report):
            result = {**scored_excerpts(cuts), "cutsTotal": len(cuts)}
            if report:
                result["estimatedViews"] = report["view_count"]
            return result

        results["tears-of-steel"] = {"durationSeconds": 17620 / 24,
                                    **measure(args, args.tears_of_steel, score_film)}
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", help="Path to the built mpcut executable")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="Reference FFmpeg with VideoToolbox and scdet")
    parser.add_argument("--fixture-ffmpeg", default="ffmpeg", help="Fixture generator with libx264")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--baseline", help="Previous MPCut CLI to compare on identical inputs")
    parser.add_argument("--warmups", type=int, default=1, help="Untimed warmup rounds per input (default 1)")
    parser.add_argument("--skip-scdet", action="store_true", help="Skip the independent FFmpeg comparison")
    parser.add_argument("--require-identical", action="store_true",
                        help="Exit with a failure if the baseline and candidate detection reports differ")
    parser.add_argument("--codec-matrix", action="store_true",
                        help="Also score 4K HEVC Main10 (hev1 and hvc1), 4K ProRes 422, and 1080p software-decoded FFV1")
    parser.add_argument("--scdet-threshold", type=float, default=10, help="FFmpeg scene score threshold")
    parser.add_argument("--extra", action="append", default=[], type=Path,
                        help="Additional unlabeled source for throughput measurements")
    parser.add_argument("--tears-of-steel", type=Path,
                        help="Original Blender 720p MOV for hand-annotated excerpts and full-film throughput")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    if args.warmups < 0:
        parser.error("--warmups must be nonnegative")
    if args.require_identical and not args.baseline:
        parser.error("--require-identical requires --baseline")
    if not 0 <= args.scdet_threshold <= 100:
        parser.error("--scdet-threshold must be between 0 and 100")
    args.mpcut = uncached_command(args.mpcut)
    if args.baseline:
        args.baseline = uncached_command(args.baseline)
    with tempfile.TemporaryDirectory(prefix="mpcut-scene-benchmark-") as temporary:
        results = benchmark(args, Path(temporary))
    print(json.dumps(results, indent=2))
    if args.require_identical and not all(result["reportsIdentical"] for result in results.values()):
        raise SystemExit(1)
