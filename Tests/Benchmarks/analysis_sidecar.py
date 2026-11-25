#!/usr/bin/env python3
"""Compare fresh and sidecar-backed analysis reports on the same local media."""

import argparse
from fractions import Fraction
import json
import os
from pathlib import Path
import shutil
import sqlite3
import statistics
import tempfile

from scene_detection import measured_run


def report(cli, source, *arguments):
    output, _, (elapsed, rss_mib, _) = measured_run([cli, *arguments, "--json", source])
    return json.loads(output), elapsed, round(rss_mib, 2)


def compare(cli, source, arguments, runs):
    timings = {"fresh": [], "cached": []}
    peaks = {"fresh": [], "cached": []}
    expected = None
    for run in range(runs + 1):
        order = ("fresh", "cached") if run % 2 == 0 else ("cached", "fresh")
        for mode in order:
            flags = ["--no-sidecar", *arguments] if mode == "fresh" else arguments
            result, seconds, peak = report(cli, source, *flags)
            if expected is None:
                expected = result
            elif result != expected:
                raise RuntimeError(f"Cached and fresh reports differ for {arguments}")
            if run:
                timings[mode].append(seconds)
                peaks[mode].append(peak)
    return {f"{mode}Seconds": round(statistics.median(samples), 4)
            for mode, samples in timings.items()} | {f"{mode}PeakMiB": max(values) for mode, values in peaks.items()}


def benchmark(cli, file, directory, runs):
    source = directory / file.name
    shutil.copy2(file, source)
    first, build, peak = report(cli, source, "analysis", "sidecar", "build")
    cache = Path(first["sidecar"])
    if cache.parent != directory:
        raise RuntimeError(f"Expected the benchmark cache in {directory}, got {cache}")
    initial_size = cache.stat().st_size
    with sqlite3.connect(cache.as_uri() + "?mode=ro", uri=True) as database:
        section_sizes = dict(database.execute("SELECT name, length(value) FROM sections ORDER BY name"))
        attempts_size = 0
        if database.execute("SELECT 1 FROM sqlite_schema WHERE name = 'scene_attempts'").fetchone():
            attempts_size = database.execute("SELECT coalesce(sum(length(checkpoint)), 0) FROM scene_attempts").fetchone()[0]
            attempts_size += database.execute("SELECT coalesce(sum(length(value)), 0) FROM scene_markers").fetchone()[0]
    save_times = []
    inspect_times = []
    for _ in range(runs):
        saved, elapsed, _ = report(cli, source, "analysis", "sidecar", "build")
        if saved["sections"] != first["sections"] or saved["status"] != "current":
            raise RuntimeError("Repeating a sidecar save changed the inventory")
        save_times.append(elapsed)
        inspected, elapsed, _ = report(cli, source, "analysis", "sidecar", "inspect")
        if inspected["sections"] != saved["sections"] or inspected["status"] != "current":
            raise RuntimeError("Sidecar inspection and save disagree")
        inspect_times.append(elapsed)
    info, _, _ = report(cli, source, "media", "inspect")
    duration = info["media"]["duration"]
    end = min(1, Fraction(duration["numerator"], duration["denominator"]))
    operations = {"inspection": ["media", "inspect"]}
    if info["media"]["has_video"]:
        operations["scenes"] = ["scenes", "scan"]
        operations["firstSecondOfIndex"] = ["media", "inspect", "--frames", "--from", "0", "--to", str(end)]
    if any(stream["kind"] == "audio" for stream in info["media"]["streams"]):
        operations["silence"] = ["silence", "scan"]
        operations["waveform"] = ["silence", "scan", "--waveform", "512"]
        if not info["media"]["has_video"]:
            # Compare one complete, saved overview and an on-demand detail window.
            operations["signedOverview"] = ["waveform", "envelope", "read", "--columns", "65536"]
            operations["displayOverview"] = ["waveform", "envelope", "read", "--columns", "1024"]
            middle = Fraction(duration["numerator"], duration["denominator"]) / 2
            operations["signedDetail"] = ["waveform", "envelope", "read", "--columns", "1024", "--from", str(middle),
                                          "--to", str(middle + min(middle, Fraction(1, 10)))]
    reports = {name: compare(cli, source, arguments, runs) for name, arguments in operations.items()}
    return {
        "source": file.name, "sourceBytes": source.stat().st_size,
        "sidecarBytes": initial_size, "afterQueriesBytes": cache.stat().st_size,
        "repeatBuildSeconds": round(statistics.median(save_times), 4),
        "inventorySeconds": round(statistics.median(inspect_times), 4),
        "sectionBytes": section_sizes, "sceneAttemptPayloadBytes": attempts_size,
        "databaseBytesOutsidePayloads": initial_size - sum(section_sizes.values()) - attempts_size,
        "coldBuildPeakMiB": peak, "buildSeconds": round(build, 4), "measuredRuns": runs,
        "reports": reports,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    parser.add_argument("file", type=Path)
    parser.add_argument("--runs", type=int, default=3)
    options = parser.parse_args()
    if options.runs < 1:
        parser.error("--runs must be positive")
    with tempfile.TemporaryDirectory(prefix="mpcut-sidecar-benchmark-") as scratch:
        os.environ["MPCUT_SIDECAR_HOME"] = str(Path(scratch) / "settings")
        result = benchmark(options.mpcut.resolve(strict=True), options.file.resolve(strict=True),
                           Path(scratch), options.runs)
    print(json.dumps(result, indent=2))
