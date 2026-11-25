#!/usr/bin/env python3
"""Time four-angle multicam preflight and export with sample-exact verification."""

import argparse
from fractions import Fraction
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Integration"))
from media_regression import audio, ffmpeg, packets, probe, ratio  # noqa: E402

FPS = 25
RATE = 48_000
ANGLE_IDS = ("wide", "left", "right", "detail")
SWITCH_COUNT = 20


def make_fixture(directory, duration):
    directory.mkdir(parents=True, exist_ok=True)
    if any(directory.iterdir()):
        raise ValueError(f"fixture directory must be empty: {directory}")
    for number, angle in enumerate(ANGLE_IDS):
        ffmpeg("-f", "lavfi", "-i", f"testsrc2=d={duration}:s=320x180:r={FPS}",
               "-vf", f"hue=h={number * 70}", "-an", "-c:v", "libx264", "-threads", "1",
               "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-x264-params",
               f"keyint={FPS}:min-keyint={FPS}:scenecut=0:open-gop=0:bframes=0",
               "-color_range", "tv", "-color_primaries", "bt709", "-color_trc", "bt709",
               "-colorspace", "bt709", directory / f"{angle}.mov")
    ffmpeg("-f", "lavfi", "-i",
           f"aevalsrc=0.2*sin(2*PI*(349*t+51*t*t)):s={RATE}:d={duration}",
           "-c:a", "pcm_s16le", directory / "lav.wav")
    step = duration // (SWITCH_COUNT + 1)
    split = 10 * step + step // 2
    project = {
        "format": "mpcut", "schema_version": 9, "kind": "multicam", "reference_angle_id": "wide",
        "group_range": {"from": "0", "to": str(duration)},
        "angles": [{"id": angle, "file": f"{angle}.mov", "offset": "0"} for angle in ANGLE_IDS],
        "audio_sources": [{"id": "lav", "file": "lav.wav", "offset": "0"}],
        "audio": {"mode": "fixed", "source_id": "lav", "audio_stream_index": 0},
        "switches": [{"group_time": str(number * step), "angle_id": ANGLE_IDS[number % len(ANGLE_IDS)]}
                     for number in range(SWITCH_COUNT + 1)],
        "assembly": [{"from": str(split), "to": str(duration)}, {"from": "0", "to": str(split)}],
    }
    project_path = directory / "benchmark.cut"
    project_path.write_text(json.dumps(project, indent=2) + "\n")
    return project_path


def timed(cli, *args, timeout=600):
    command = [cli, *args, "--json"]
    with tempfile.TemporaryFile(mode="w+") as stdout, tempfile.TemporaryFile(mode="w+") as stderr:
        started = time.perf_counter()
        with subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True) as child:
            expired = threading.Event()

            def kill_group():
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

            def expire():
                expired.set()
                kill_group()

            watchdog = threading.Timer(timeout, expire)
            watchdog.start()
            try:
                _, status, usage = os.wait4(child.pid, 0)
                child.returncode = os.waitstatus_to_exitcode(status)
            except BaseException:
                kill_group()
                raise
            finally:
                watchdog.cancel()
                watchdog.join()
            seconds = time.perf_counter() - started
        stdout.seek(0)
        stderr.seek(0)
        if expired.is_set() and child.returncode == -signal.SIGKILL:
            raise subprocess.TimeoutExpired(command, timeout, output=stdout.read(), stderr=stderr.read())
        if child.returncode:
            raise RuntimeError(f"{args} failed: {stdout.read()}\n{stderr.read()}")
        report = json.load(stdout)
    if not report["ok"]:
        raise RuntimeError(report)
    return report, {"seconds": seconds, "peakRssBytes": usage.ru_maxrss}


def summarize(samples):
    return {
        "medianSeconds": statistics.median(sample["seconds"] for sample in samples),
        "maxPeakRssBytes": max(sample["peakRssBytes"] for sample in samples),
        "samples": samples,
    }


def interval_json(start, end):
    return {"from": str(start), "to": str(end)}


def verify_media(project_path, output, plan):
    project = json.loads(project_path.read_text())
    angle_packets = {
        angle["id"]: packets(project_path.parent / angle["file"]) for angle in project["angles"]
    }
    selections = [(int(switch["group_time"]), switch["angle_id"]) for switch in project["switches"]]
    group_end = int(project["group_range"]["to"])
    switch_ends = [start for start, _ in selections[1:]] + [group_end]
    source_pcm = audio(project_path.parent / "lav.wav")
    expected_pcm = bytearray()
    expected_hashes = []
    expected_picture = []
    expected_audio = []
    output_start = 0
    for interval in project["assembly"]:
        start = int(interval["from"])
        end = int(interval["to"])
        output_end = output_start + end - start
        expected_audio.append({"source": "lav", "stream": 0,
                               "input": interval, "output": interval_json(output_start, output_end)})
        expected_pcm.extend(source_pcm[start * RATE * 2:end * RATE * 2])
        for (switch_start, angle), switch_end in zip(selections, switch_ends):
            lower = max(start, switch_start)
            upper = min(end, switch_end)
            if lower >= upper:
                continue
            timeline_start = output_start + lower - start
            expected_picture.append({"source": angle, "input": interval_json(lower, upper),
                                     "output": interval_json(timeline_start, timeline_start + upper - lower)})
            expected_hashes.extend(p["data_hash"] for p in angle_packets[angle][lower * FPS:upper * FPS])
        output_start = output_end
    lane, = plan["audio_lanes"]
    if plan["picture"] != expected_picture or lane["spans"] != expected_audio:
        raise AssertionError("CLI plan disagrees with the source intervals")
    actual_packets = packets(output)
    if [p["data_hash"] for p in actual_packets] != expected_hashes:
        raise AssertionError("copied video packets differ from the selected source sequence")
    stream = probe(output, "-select_streams", "v:0", "-show_streams")["streams"][0]
    time_base = Fraction(stream["time_base"])
    if any(int(packet["pts"]) * time_base != Fraction(index, FPS)
           for index, packet in enumerate(actual_packets)):
        raise AssertionError("output video timestamp drift")
    if audio(output) != expected_pcm:
        raise AssertionError("output audio samples differ from the reordered master intervals")
    return {"verifiedVideoPackets": len(expected_hashes), "verifiedAudioSamples": len(expected_pcm) // 2}


def review_frames(cli, project, output):
    duration = int(json.loads(project.read_text())["group_range"]["to"])
    times = [Fraction(duration * index, 5) + Fraction(17, 100) for index in range(5)]
    flags = [flag for time in times for flag in ("--at", str(time))]
    report, metrics = timed(cli, "review", "frames", "export", "--project", project, "--output", output, *flags)
    rows = report["frames"]
    expected_order = [(time, angle) for time in times for angle in ANGLE_IDS]
    if [(ratio(row["group_time"]), row["angle_id"]) for row in rows] != expected_order:
        raise AssertionError("multicam review did not return every requested time and angle")
    files = set()
    sample = ("-frames:v", "1", "-vf", "scale=64:36", "-pix_fmt", "rgb24", "-f", "rawvideo", "-")
    for row, (time, angle) in zip(rows, expected_order):
        frame_time = Fraction(time * FPS // 1, FPS)
        jpeg = (output / row["file"]).resolve()
        if (row["availability"] != "available" or ratio(row["frame_time"]) != frame_time
                or jpeg.parent != output.resolve() or jpeg in files):
            raise AssertionError(f"multicam review returned an unexpected frame for {time}")
        files.add(jpeg)
        encoded = jpeg.read_bytes()
        if not encoded.startswith(b"\xff\xd8") or not encoded.endswith(b"\xff\xd9"):
            raise AssertionError(f"invalid JPEG for {angle} at {time}")
        actual = ffmpeg("-xerror", "-i", jpeg, *sample)
        source = project.parent / f"{angle}.mov"
        reference = ffmpeg("-ss", f"{float(frame_time):.2f}", "-i", source, *sample)
        if len(actual) != 64 * 36 * 3 or len(reference) != len(actual):
            raise AssertionError(f"could not decode both pictures for {angle} at {time}")
        mean_error = sum(abs(a - b) for a, b in zip(actual, reference)) / len(reference)
        if mean_error > 12:
            raise AssertionError(f"JPEG pixels differ from {angle} at {time} (mean error {mean_error:.2f})")
    return {**metrics, "verifiedJpegs": len(rows)}


def benchmark(cli, project, runs, scratch):
    assets = [project.parent / f"{angle}.mov" for angle in ANGLE_IDS] + [project.parent / "lav.wav"]
    sidecars = [path.with_name(path.name + ".cutcache") for path in assets]
    sidecar_files = [path.with_name(path.name + suffix)
                     for path in sidecars for suffix in ("", "-wal", "-shm", "-journal")]
    if any(path.exists() or path.is_symlink() for path in sidecar_files):
        raise ValueError("benchmark requires generated source files without sidecars")
    try:
        return benchmark_exports(cli, project, runs, scratch, assets, sidecars)
    finally:
        for path in sidecar_files:
            path.unlink(missing_ok=True)


def benchmark_exports(cli, project, runs, scratch, assets, sidecars):
    output = scratch / "program.mov"
    export = ("export", "project", "render", "--project", project, "--mode", "copy", "--output", output)
    first_report, first_metrics = timed(cli, *export, "--dry-run", "--no-sidecar")
    if output.exists():
        raise AssertionError("preflight created an output file")
    fresh = []
    for _ in range(runs):
        report, metrics = timed(cli, *export, "--dry-run", "--no-sidecar")
        if report != first_report:
            raise AssertionError("fresh preflight is inconsistent")
        fresh.append(metrics)

    if any(path.exists() for path in sidecars):
        raise AssertionError("uncached preflight created a sidecar")

    build = {}
    for asset in assets:
        _, metrics = timed(cli, "analysis", "sidecar", "build", "--only", "index", asset)
        build[asset.name] = metrics
    if not all(path.is_file() for path in sidecars):
        raise AssertionError("missing source index sidecars")

    cached = []
    for _ in range(runs):
        report, metrics = timed(cli, *export, "--dry-run")
        if report != first_report:
            raise AssertionError("sidecar-backed and uncached preflight disagree")
        cached.append(metrics)
    export_report, export_metrics = timed(cli, *export)
    if export_report["plan"] != first_report["plan"]:
        raise AssertionError("preflight and export disagree")
    return {
        "withoutSidecarsFirstRun": first_metrics,
        "withoutSidecars": summarize(fresh),
        "indexBuildBySource": build,
        "withSidecars": summarize(cached),
        "copyExportWithSidecars": export_metrics,
        "alignedJpegReviewWithSidecars": review_frames(cli, project, scratch / "review"),
        **verify_media(project, output, first_report["plan"]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path, nargs="?")
    parser.add_argument("--fixture-dir", type=Path, help="keep the generated fixture in an empty directory")
    parser.add_argument("--project", type=Path, help="reuse a generated project without sidecars")
    parser.add_argument("--fixture-only", action="store_true", help="generate the desktop test project")
    parser.add_argument("--duration", type=int, default=180, help="camera length in seconds")
    parser.add_argument("--runs", type=int, default=5, help="measured preflight runs per condition")
    options = parser.parse_args()
    if not 42 <= options.duration <= 300 or options.runs < 1:
        parser.error("require 42–300 seconds and at least one run")
    if options.fixture_only and not options.fixture_dir:
        parser.error("--fixture-only requires --fixture-dir")
    if options.project and options.fixture_dir:
        parser.error("--project cannot be combined with --fixture-dir")
    if not options.fixture_only and not options.mpcut:
        parser.error("provide the mpcut executable")
    if not options.fixture_only and sys.platform != "darwin":
        parser.error("timing currently requires macOS")

    with tempfile.TemporaryDirectory(prefix="mpcut-multicam-benchmark-") as scratch:
        scratch = Path(scratch)
        directory = options.fixture_dir or scratch / "fixture"
        project = (options.project.resolve(strict=True) if options.project
                   else make_fixture(directory.resolve(), options.duration))
        if options.fixture_only:
            print(project)
            return
        result = benchmark(options.mpcut.resolve(strict=True), project, options.runs, scratch)
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
