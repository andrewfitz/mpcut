#!/usr/bin/env python3
"""Benchmark the released MPCut CLI on a deterministic, three-hour multicam transcript."""

import argparse
from bisect import bisect_left
from fractions import Fraction
from hashlib import sha256
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

RATE = 16_000
TURN_SECONDS = 8
SWITCH_SECONDS = 80
PAGE_SIZE = 50
QUERY = "shipping ledger"
REPLACEMENT = "delivery register"
SENTENCES = (
    "We counted the cartons on the loading dock before the morning courier arrived.",
    "The shipping ledger lists every parcel that left the warehouse before the doors closed.",
    "Could you walk us through the inspection and tell us where the damaged boxes were stored?",
    "I checked the labels twice and moved the returns to a separate shelf near the office.",
    "During the afternoon shift we kept the eastern entrance clear while the drivers waited outside.",
    "Please record the temperature at each stop so we can compare readings with the earlier route.",
    "After the inventory was finished, the team walked through the building and checked the locks.",
    "We should ask the supervisor whether the replacement parts arrived before the maintenance window.",
)
TRACKS = (("wide", 1), ("close", 1), ("host", 0), ("guest", 0))
ZERO = {"numerator": 0, "denominator": 1}


def write_json(path, value):
    path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")


def require(condition, label):
    if not condition:
        raise RuntimeError(f"Benchmark verification failed: {label}")


def fixture(root, ffmpeg, duration):
    # Loop short encoded recordings to build hours of packets without hours of
    # encoding. The scripted transcript is independent of the picture and tone.
    generate = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error"]
    for index, (name, stream) in enumerate(TRACKS):
        inputs = ["-f", "lavfi", "-i", f"sine=frequency={200 + index * 137}:sample_rate={RATE}"]
        codecs = ["-map", "0:a", "-c:a", "aac", "-b:a", "24k"]
        if stream == 1:
            inputs += ["-f", "lavfi", "-i", f"color={('navy', 'maroon')[index]}:size=160x90:rate=25"]
            codecs = ["-map", "1:v", *codecs, "-c:v", "libx264", "-preset", "ultrafast",
                      "-threads:v", "1", "-g", "50", "-pix_fmt", "yuv420p"]
        seed = root / "seed.mov"
        subprocess.run([*generate, *inputs, *codecs, "-t", "64", seed], check=True, timeout=60)
        subprocess.run([*generate, "-stream_loop", "-1", "-i", seed, "-t", str(duration),
                        "-map", "0", "-c", "copy", root / f"{name}.mov"], check=True, timeout=120)
        seed.unlink()

    switches = []
    for index, start in enumerate(range(0, duration, SWITCH_SECONDS)):
        source, stream = TRACKS[(index + 2) % 3]
        switches.append({"group_time": str(start), "angle_id": TRACKS[index % 2][0],
                         "audio": {"source_id": source, "audio_stream_index": stream}})
    parts = [(start, min(start + 480, duration)) for start in range(0, duration, 480)]
    assembly = parts[1::2] + parts[::2]
    state = {
        "format": "mpcut", "schema_version": 9, "kind": "multicam", "reference_angle_id": "wide",
        "group_range": {"from": "0", "to": str(duration)},
        "angles": [{"id": name, "file": f"{name}.mov", "offset": "0", "audio_stream_index": stream}
                   for name, stream in TRACKS[:2]],
        "audio_sources": [{"id": name, "file": f"{name}.mov", "offset": "0"}
                         for name, _ in TRACKS[2:]],
        "audio": {"mode": "fixed", "source_id": "host", "audio_stream_index": 0},
        "switches": switches,
        "assembly": [{"from": str(start), "to": str(end)} for start, end in assembly],
    }
    plain = root / "plain.cut"
    write_json(plain, state)
    tracks = [{"id": name, "source_id": name, "name": name, "stream_index": stream,
               "origin": ZERO, "session_start": ZERO, "coverage": "recognized",
               "role": "mixed_audio" if stream else "isolated_mic"} for name, stream in TRACKS]
    words = []
    for turn, seconds in enumerate(range(0, duration, TURN_SECONDS)):
        speaker = TRACKS[2 + turn % 2][0]
        for ordinal, word in enumerate(SENTENCES[turn % len(SENTENCES)].split()):
            start = seconds * RATE + (ordinal + 1) * RATE // 3
            end = start + RATE // 4
            observed = ("wide", "close", "host") if speaker == "host" else ("wide", "close", "host", "guest")
            words.append({
                "id": f"w{turn}-{ordinal}", "utterance_id": f"turn-{turn}", "text": word,
                "speaker_id": speaker, "precision": "word", "start_sample": start, "end_sample": end,
                "observations": [{"track_id": track, "start_sample": start, "end_sample": end,
                                  "evidence": "recognized", "speaker_id": speaker} for track in observed],
            })
    transcript = root / "result.json"
    write_json(transcript, {"version": 1, "clock": "session", "sample_rate": RATE,
                            "tracks": tracks, "speakers": [{"id": speaker, "name": speaker.title()}
                                                           for speaker in ("host", "guest")],
                            "words": words})
    ordered = []
    hits = []
    output_start = 0
    starts = [word["start_sample"] for word in words]
    for lower, upper in assembly:
        first = bisect_left(starts, lower * RATE)
        limit = bisect_left(starts, upper * RATE, lo=first)
        for index in range(first, limit):
            word = words[index]
            start = starts[index]
            source = switches[start // (RATE * SWITCH_SECONDS)]["audio"]["source_id"]
            row = word["id"], source, Fraction(start + output_start - lower * RATE, RATE)
            ordered.append(row)
            if word["text"] == "shipping":
                hits.append(row)
        output_start += (upper - lower) * RATE
    guest = [word["id"] for word in words if word["speaker_id"] == "guest"]
    return plain, transcript, ordered, hits, guest, len(switches), len(assembly)


def call(cli, args, request=None):
    command = [cli, *args, "--json"]
    payload = None
    if request is not None:
        command.append("--stdin")
        payload = json.dumps(request).encode()
    started = time.perf_counter_ns()
    with subprocess.Popen(["/usr/bin/time", "-l", *command],
                          stdin=subprocess.PIPE if payload is not None else None,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=os.environ | {"LC_ALL": "C"}, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(payload, timeout=600)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise
    elapsed = (time.perf_counter_ns() - started) / 1e9
    if process.returncode:
        raise RuntimeError(f"{args}: {stdout.decode()}\n{stderr.decode()}")
    rss = re.search(rb"^\s*(\d+)\s+maximum resident set size$", stderr, re.MULTILINE)
    cpu = re.search(rb"^\s*[\d.]+ real\s+([\d.]+) user\s+([\d.]+) sys$", stderr, re.MULTILINE)
    if rss is None or cpu is None:
        raise RuntimeError(f"Missing macOS /usr/bin/time statistics: {stderr!r}")
    return json.loads(stdout), {"seconds": elapsed, "cpuSeconds": float(cpu[1]) + float(cpu[2]),
                                "peakRssBytes": int(rss[1]), "responseBytes": len(stdout)}


def occurrence_key(row):
    return row["word_id"], row["source_id"], Fraction(row["range"]["from"])


def compare_reads(response, expected, offset, limit):
    require(response["total"] == len(expected), "word count")
    require([occurrence_key(row) for row in response["items"]] == expected[offset:offset + limit],
            "current-cut order, source routing, and output timestamps")
    next_offset = offset + limit
    require(response.get("next_offset") == (next_offset if next_offset < len(expected) else None),
            "transcript page continuation")


def project_signature(report):
    inspection = report["inspection"]
    require(report["ok"] and not inspection["issues"], "broader project has all media online")
    # Compare the exported timeline and physical sources. The media report
    # also carries probe details that can differ after index cache warm-up.
    sources = [{
        "source": row["source"],
        "coverage": row["coverage"],
        "audio_coverage": row["audio_coverage"],
        "duration": row["media"]["duration"],
    } for row in inspection["sources"]]
    return report["group_intervals"], inspection["mapping"], sources


def editor_load(loader, project):
    result = subprocess.run([loader, project], capture_output=True, check=True, timeout=30)
    return json.loads(result.stdout)


def exercise(cli, root, duration, ffmpeg, runs, editor_loader, progress):
    if progress:
        print(f"Preparing the {duration}-second fixture.", file=sys.stderr, flush=True)
    plain, transcript, order, hits, guest, switches, intervals = fixture(root, ffmpeg, duration)
    project = root / "attached.cut"
    shutil.copyfile(plain, project)
    imported, _ = call(cli, ["transcript", "attachment", "import"], {
        "project_path": str(project), "transcript": str(transcript), "attachment_id": "benchmark", "in_place": True,
    })
    require(not imported["unbound_tracks"], "all four tracks bound")
    attachment = imported["attachment"]
    def expanded_project():
        return json.loads(subprocess.check_output([cli, "project", "document", "print", project], timeout=600))

    expanded = expanded_project()
    digest = attachment["asset"]["sha256"]
    stored = expanded["embedded_assets"]["transcripts"][digest]
    # This deterministic fixture uses only integer numbers and ASCII text.
    asset_bytes = json.dumps(stored, sort_keys=True, separators=(",", ":")).encode()
    require(sha256(asset_bytes).hexdigest() == digest, "embedded transcript digest")
    sequences = ("projectOpenPlain", "projectOpenAttached", "transcriptOpen",
                 "readFirst", "readMiddle", "search", "searchPage", "correct",
                 "projectOpenWithHistory", "searchAfterCorrection")
    measurements = {name: [] for name in sequences}
    editor_measurements = {name: [] for name in ("plain", "attached", "withHistory")}
    ancillary_report_differences = []
    pass_load_averages = []
    original_project = project.read_bytes()
    middle = len(order) // 2
    hit_offset = len(hits) // 2
    for run in range(runs + 1):
        if progress:
            label = "Warm-up pass" if run == 0 else f"Measured pass {run} of {runs}"
            print(f"{label}.", file=sys.stderr, flush=True)
        start_load = os.getloadavg()
        if run:
            project.write_bytes(original_project)

        def measure(name, arguments, request=None):
            response, sample = call(cli, arguments, request)
            if run:
                measurements[name].append(sample)
                if progress:
                    print(f"  {name} took {sample['seconds']:.3f} s.", file=sys.stderr, flush=True)
            return response

        def transcript_call(name, action, **request):
            # Word records are compact by default. The checks below read the full records.
            full = {"verbose": True} if action in ("words read", "words search", "words locate", "words compare", "words suggest", "script align") else {}
            return measure(name, ["transcript", *action.split()], {"project_path": str(project)} | full | request)

        def project_open(name, path):
            return measure(name, ["project", "inspect", "--project", path])

        def measure_editor(name, path, *, attachments, corrections=0):
            if not editor_loader:
                return
            receipt = editor_load(editor_loader, path)
            require(receipt["mediaFiles"] == sorted(f"{name}.mov" for name, _ in TRACKS), "editor archive’s media references")
            require(receipt["attachmentCount"] == attachments and receipt["authoringCount"] == corrections,
                    "editor archive’s current transcript state")
            require(receipt["undoActions"] == ["Correct Transcript"] * corrections and
                    receipt["undoAuthoringCounts"] == [0] * corrections and not receipt["redoActions"],
                    "editor loads the correction's undo state")
            if run:
                editor_measurements[name].append(receipt["archiveSeconds"])

        controls = [("projectOpenPlain", "plain", plain, 0), ("projectOpenAttached", "attached", project, 1)]
        if run % 2:
            controls.reverse()
        reports = {}
        for name, editor_name, path, attachments in controls:
            reports[name] = project_open(name, path)
            measure_editor(editor_name, path, attachments=attachments)
        reference = reports["projectOpenPlain"]
        signature = project_signature(reference)

        def verify_project(name, report):
            require(signature == project_signature(report), f"{name} preserves the timeline and media coverage")
            changed = sorted(key for key in reference.keys() | report.keys()
                             if key != "project_path" and reference.get(key) != report.get(key))
            if changed:
                ancillary_report_differences.append({"pass": run, "operation": name, "fields": changed})

        verify_project("projectOpenAttached", reports["projectOpenAttached"])

        opened = transcript_call("transcriptOpen", "attachment inspect", limit=4)
        require(len(opened["attachments"]) == 1, "single persisted attachment")
        record = opened["attachments"][0]
        require(record["attachment"]["asset"]["sha256"] == attachment["asset"]["sha256"] and
                record["status"] == "available" and record["words"] == len(order) and
                [track["id"] for track in record["tracks"]["items"]] == [name for name, _ in TRACKS],
                "transcript open resolves asset, words, and tracks")

        if run == 0:
            source, _ = call(cli, ["transcript", "words", "read"], {
                "project_path": str(project), "space": "source", "track_id": "guest", "limit": PAGE_SIZE, "verbose": True,
            })
            require(source["total"] == len(guest) and
                    [row["word_id"] for row in source["items"]] == guest[:PAGE_SIZE] and
                    all(row["source_id"] == "guest" for row in source["items"]),
                    "isolated guest track has its own source-space word count and order")

        first = transcript_call("readFirst", "words read", limit=PAGE_SIZE)
        compare_reads(first, order, 0, PAGE_SIZE)
        page = transcript_call("readMiddle", "words read", offset=middle, limit=PAGE_SIZE)
        compare_reads(page, order, middle, PAGE_SIZE)

        def verify_search(response, offset):
            rows = response["items"]
            require(response["total"] == len(hits) and len(rows) == min(10, len(hits) - offset), "phrase hit count")
            require([occurrence_key(row["words"][0]) for row in rows] == hits[offset:offset + 10],
                    "phrase hit order, source routing, and output timestamps")
            end = offset + len(rows)
            require(response.get("next_offset") == (end if end < len(hits) else None), "search page continuation")
            return rows

        result = verify_search(transcript_call("search", "words search", query=QUERY, limit=10), 0)
        verify_search(transcript_call("searchPage", "words search", query=QUERY, offset=hit_offset, limit=10), hit_offset)
        first_word, last_word = result[0]["words"]
        selection = {"first_word_id": first_word["word_id"], "last_word_id": last_word["word_id"],
                     "first_occurrence_id": first_word["id"], "last_occurrence_id": last_word["id"]}
        before = expanded
        corrected = transcript_call("correct", "words correct", in_place=True, selection=selection,
                                    change={"replace_text": {"text": REPLACEMENT}})
        require(corrected["history_action"] == "Correct Transcript", "correction returns history receipt")
        restored = project_open("projectOpenWithHistory", project)
        verify_project("projectOpenWithHistory", restored)
        measure_editor("withHistory", project, attachments=1, corrections=1)
        after = expanded_project()
        previous = after["history"]["undo"]
        require(len(previous) == 1 and previous[0]["action"] == "Correct Transcript" and not after["history"].get("redo"),
                "undo/redo stack on disk")
        require(previous[0]["transcript_authoring"] == [] and not before["transcripts"]["authoring"] and
                len(after["transcripts"]["authoring"]) == 1 and
                after["transcripts"]["attachments"] == before["transcripts"]["attachments"],
                "undo records how to recover the old authoring state while retaining the same attachment")
        replacement = transcript_call("searchAfterCorrection", "words search", query=REPLACEMENT, limit=10)
        require(replacement["total"] == 1 and
                replacement["items"][0]["words"][0]["word_id"] == first_word["word_id"], "correction survives reopen")
        if run:
            pass_load_averages.append({"before": start_load, "after": os.getloadavg()})

    media = sorted(root.glob("*.mov"))
    report = {
        "fixture": {"seconds": duration, "tracks": len(TRACKS), "words": len(order), "switches": switches,
                    "assemblyIntervals": intervals, "phraseMatches": len(hits), "guestTrackWords": len(guest),
                    "routedTracks": sorted({source for _, source, _ in order}), "assetBytes": len(asset_bytes),
                    "assetSha256": attachment["asset"]["sha256"], "readPageSize": PAGE_SIZE,
                    "projectSha256": sha256(plain.read_bytes()).hexdigest(),
                    "inputTranscriptSha256": sha256(transcript.read_bytes()).hexdigest(),
                    "mediaBytes": {path.name: path.stat().st_size for path in media},
                    "mediaSha256": {path.name: sha256(path.read_bytes()).hexdigest() for path in media}},
        "measuredRuns": runs,
        "passLoadAverages": pass_load_averages,
        "projectReportDifferences": ancillary_report_differences,
        "operations": {
            name: {"medianSeconds": statistics.median(sample["seconds"] for sample in samples),
                   "medianCpuSeconds": statistics.median(sample["cpuSeconds"] for sample in samples),
                   "maxPeakRssBytes": max(sample["peakRssBytes"] for sample in samples), "samples": samples}
            for name, samples in measurements.items()
        },
    }
    if editor_loader:
        report["editorArchiveLoad"] = {
            name: {"medianSeconds": statistics.median(samples), "samples": samples}
            for name, samples in editor_measurements.items()
        }
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--editor-loader", type=Path, help="Headless release-linked editor archive loader")
    parser.add_argument("--seconds", type=int, default=10_800)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--progress", action="store_true", help="Report fixture and pass progress on stderr")
    args = parser.parse_args()
    if args.seconds < 80 or args.seconds % TURN_SECONDS or args.runs < 1:
        parser.error("--seconds requires a multiple of 8 of at least 80 and --runs requires at least 1")
    ffmpeg = shutil.which(args.ffmpeg)
    if ffmpeg is None:
        parser.error("FFmpeg is required to generate the local media")
    cli = args.mpcut.resolve(strict=True)
    binary_digest = sha256(cli.read_bytes()).hexdigest()
    cli_version = subprocess.check_output([cli, "--version"], text=True).strip()
    start_load = os.getloadavg()
    with tempfile.TemporaryDirectory(prefix="mpcut-transcript-bench-") as directory:
        host = subprocess.check_output(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
        version = subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0]
        editor_loader = args.editor_loader.resolve(strict=True) if args.editor_loader else None
        report = exercise(cli, Path(directory).resolve(), args.seconds, ffmpeg, args.runs, editor_loader, args.progress)
    require(sha256(cli.read_bytes()).hexdigest() == binary_digest, "release binary stayed fixed during run")
    output = {"binary": str(cli), "binaryVersion": cli_version, "binarySha256": binary_digest,
              "os": platform.mac_ver()[0], "cpu": host, "logicalCPUs": os.cpu_count(), "ffmpeg": version,
              "loadAverage": {"before": start_load, "after": os.getloadavg()}, **report}
    if editor_loader:
        output["editorLoaderSha256"] = sha256(editor_loader.read_bytes()).hexdigest()
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
