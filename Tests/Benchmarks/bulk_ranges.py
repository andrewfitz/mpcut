#!/usr/bin/env python3
"""Compare bulk preflight speed and require matching JSON on fractional PCM ranges."""

import argparse
import json
from pathlib import Path
import statistics
import subprocess
import tempfile
import time
import wave

from benchmark_cli import command_help, normalize_report


def benchmark(candidate, baseline, count, runs, directory):
    source = directory / "audio.wav"
    with wave.open(str(source), "wb") as audio:
        audio.setparams((1, 2, 48_000, 0, "NONE", "not compressed"))
        audio.writeframes(bytes(2 * 48_000 * 2))
    ranges = directory / "ranges.json"
    ranges.write_text(json.dumps([{"from": "1/3", "to": "7/6"}] * count), encoding="utf-8")
    output = directory / "clips"
    output.mkdir()
    arguments = [source, "--ranges", ranges, "--output", output, "--dry-run", "--json"]
    executables = []
    for label, cli in (("baseline", baseline), ("candidate", candidate)):
        help_text = command_help(cli)
        legacy = "export ranges separate" not in help_text
        command = ["bulk"] if legacy else ["export", "ranges", "separate"]
        flags = ["--no-sidecar"] if "--no-sidecar" in help_text else []
        executables.append((label, [cli, *flags, *command, *arguments], legacy))
    mixed_syntax = executables[0][2] != executables[1][2]
    summary = {}
    for name, options in (("automatic", []), ("wav", ["--container", "wav"])):
        samples = {label: [] for label, _, _ in executables}
        reference = None
        for run in range(runs):
            order = executables if run % 2 == 0 else reversed(executables)
            for label, command, legacy in order:
                start = time.perf_counter()
                result = subprocess.run([*command, *options], capture_output=True, timeout=600)
                samples[label].append(time.perf_counter() - start)
                if result.returncode:
                    raise RuntimeError(f"{label} failed: {result.stdout[:1000]!r} {result.stderr[:1000]!r}")
                report = json.loads(result.stdout)
                if not report["ok"] or len(report["outputs"]) != count:
                    raise RuntimeError(f"{label} did not plan all {count} ranges")
                if mixed_syntax:
                    comparable = normalize_report(report) if legacy else report
                else:
                    comparable = result.stdout
                if reference is None:
                    reference = comparable
                elif comparable != reference:
                    raise RuntimeError(f"{label} JSON differs from the baseline for {name} container selection")
        medians = {label: statistics.median(times) for label, times in samples.items()}
        summary[name] = {"medianSeconds": medians, "samplesSeconds": samples,
                         "speedup": medians["baseline"] / medians["candidate"]}
    return {"rangeCount": count, "identicalReports": True,
            "normalizedLegacyFields": mixed_syntax, "containers": summary}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path, help="Path to the candidate MPCut CLI")
    parser.add_argument("--baseline", type=Path, required=True, help="Path to the previous MPCut CLI")
    parser.add_argument("--count", type=int, default=2_000, help="Ranges per bulk request (default 2000)")
    parser.add_argument("--runs", type=int, default=3, help="Runs per build and container (default 3)")
    args = parser.parse_args()
    if not 1 <= args.count <= 100_000:
        parser.error("--count must be between 1 and 100000")
    if args.runs < 1:
        parser.error("--runs must be positive")
    with tempfile.TemporaryDirectory(prefix="mpcut-bulk-benchmark-") as scratch:
        results = benchmark(args.mpcut.resolve(strict=True), args.baseline.resolve(strict=True),
                            args.count, args.runs, Path(scratch))
    print(json.dumps(results, indent=2))
