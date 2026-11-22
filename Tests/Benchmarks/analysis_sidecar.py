#!/usr/bin/env python3
"""Compare fresh and sidecar-backed analysis reports on the same local media."""

import argparse
from fractions import Fraction
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time


def report(cli, source, *arguments):
    started = time.perf_counter()
    output = subprocess.check_output([cli, *arguments, "--json", source], timeout=3600)
    elapsed = time.perf_counter() - started
    return json.loads(output), elapsed


def compare(cli, source, arguments, runs):
    timings = {"fresh": [], "cached": []}
    expected = None
    for run in range(runs + 1):
        order = ("fresh", "cached") if run % 2 == 0 else ("cached", "fresh")
        for mode in order:
            flags = ["--no-sidecar", *arguments] if mode == "fresh" else arguments
            result, seconds = report(cli, source, *flags)
            if expected is None:
                expected = result
            elif result != expected:
                raise RuntimeError(f"Cached and fresh reports differ for {arguments}")
            if run:
                timings[mode].append(seconds)
    return {f"{mode}Seconds": round(statistics.median(samples), 4)
            for mode, samples in timings.items()}


def benchmark(cli, file, directory, runs):
    source = directory / file.name
    shutil.copy2(file, source)
    _, build = report(cli, source, "sidecar")
    info, _ = report(cli, source, "inspect")
    duration = info["media"]["duration"]
    end = min(1, Fraction(duration["numerator"], duration["denominator"]))
    operations = {"inspection": ["inspect"]}
    if info["media"]["hasVideo"]:
        operations["scenes"] = ["scenes"]
        operations["firstSecondOfIndex"] = ["inspect", "--frames", "--from", "0", "--to", str(end)]
    if any(stream["kind"] == "audio" for stream in info["media"]["streams"]):
        operations["silence"] = ["silence"]
        operations["waveform"] = ["silence", "--waveform", "512"]
        if not info["media"]["hasVideo"]:
            # Compare one complete, saved overview and an on-demand detail window.
            operations["signedOverview"] = ["waveform", "--columns", "65536"]
            operations["displayOverview"] = ["waveform", "--columns", "1024"]
            middle = Fraction(duration["numerator"], duration["denominator"]) / 2
            operations["signedDetail"] = ["waveform", "--columns", "1024", "--from", str(middle),
                                          "--to", str(middle + min(middle, Fraction(1, 10)))]
    return {
        "source": file.name, "sourceBytes": source.stat().st_size,
        "sidecarBytes": source.with_name(source.name + ".cutdb").stat().st_size,
        "buildSeconds": round(build, 4), "measuredRuns": runs,
        "reports": {name: compare(cli, source, arguments, runs) for name, arguments in operations.items()},
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
        result = benchmark(options.mpcut.resolve(strict=True), options.file.resolve(strict=True),
                           Path(scratch), options.runs)
    print(json.dumps(result, indent=2))
