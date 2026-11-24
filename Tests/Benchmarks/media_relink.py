#!/usr/bin/env python3
"""Measure Project Media list, folder Locate, and history-preserving relink."""

import argparse
import hashlib
import json
import platform
import shutil
import statistics
import subprocess
import tempfile
import time
import wave
from functools import cache
from pathlib import Path


SIZES = {
    "session": (24, 600, 8, 4),
    "production": (240, 8_000, 32, 16),
}
WORKLOADS = ("inventory", "folder_locate", "archive_relink", "relinked_inventory")


def recording(root, name, seconds):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, 8_000, 0, "NONE", "not compressed"))
        # Vary the PCM payload so equal-size takes are distinguishable.
        sample = 1 + int.from_bytes(hashlib.sha256(name.encode()).digest()[:2], "little") % 2_000
        output.writeframes(sample.to_bytes(2, "little") * (seconds * 8_000))


def fixture(root, size, schema_version=5):
    sources, occurrences, undo_count, redo_count = SIZES[size]
    online = root / "online"
    old = root / "original-volume"
    moved = root / "archive"
    names = [f"day-{index // 40:02}/card-{index // 10:02}/take-{index:03}.wav"
             for index in range(sources + undo_count + redo_count)]
    files = []
    for index, name in enumerate(names):
        available = index < sources and index % 4 == 3
        recording(online if available else moved, name, 3)
        if not available and index % 13 == 0:
            recording(moved / "exports", Path(name).name, 1)
        files.append(str((online if available else old) / name))
    references = list(range(len(files))) if schema_version == 5 else files
    clips = [{"id": f"cut-{index}", "file": references[index % sources],
              "from": "1/2", "to": "5/2"} for index in range(occurrences)]

    def history_steps(offset, count):
        # Each subsequent state changes a clip to a distinct history-only take.
        steps = []
        for index in range(count):
            slot = 1 + index * 5
            clip = dict(clips[slot], file=references[sources + offset + index])
            steps.append({"action": "Replace Take", "origin": "user",
                          "clips": [[0, slot], clip, [slot + 1, occurrences - slot - 1]]})
        return steps

    project = root / "edit.cut"
    document = {
        "format": "mpcut", "schema_version": schema_version, "kind": "sequence", "clips": clips,
        "history": {"undo": history_steps(0, undo_count),
                    "redo": history_steps(undo_count, redo_count)},
    }
    if schema_version == 5:
        document["files"] = files
    project.write_text(json.dumps(document, separators=(",", ":")), encoding="utf-8")
    return project, old, moved


def invoke(binary, arguments):
    start = time.perf_counter()
    completed = subprocess.run([str(binary), *arguments], capture_output=True, check=False,
                               timeout=180)
    milliseconds = (time.perf_counter() - start) * 1_000
    if completed.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, arguments))} exited {completed.returncode}\n"
                           f"{completed.stderr.decode(errors='replace')}\n"
                           f"{completed.stdout.decode(errors='replace')[:2000]}")
    return milliseconds, json.loads(completed.stdout)


def verify_archive(source, rewritten, old, moved):
    before = json.loads(source.read_text(encoding="utf-8"))
    after = json.loads(rewritten.read_text(encoding="utf-8"))

    def materialize(clips, branch):
        for step in branch:
            if "clips" in step:
                clips = [item for piece in step["clips"]
                         for item in ([piece] if isinstance(piece, dict)
                                      else clips[piece[0]:sum(piece)])]
            yield (step["action"], step.get("origin", "unknown")), clips

    @cache
    def resolved(file, remap):
        path = rewritten.parent / file
        if remap and path.is_relative_to(old):
            path = moved / path.relative_to(old)
        return path.resolve()

    def values(document, clips, remap):
        files = document.get("files", [])
        result = []
        for clip in clips:
            file = clip["file"]
            if isinstance(file, int):
                file = files[file]
            result.append((clip["id"], resolved(file, remap), clip["from"], clip["to"]))
        return result

    if values(before, before["clips"], True) != values(after, after["clips"], False):
        raise RuntimeError("Relink changed the current edit or left an incorrect path")
    for key in ("undo", "redo"):
        expected = list(before["history"][key])
        actual = after.get("history", {}).get(key, [])
        if len(actual) != len(expected):
            raise RuntimeError(f"Relink changed or lost retained {key} states")
        states = zip(materialize(before["clips"], expected), materialize(after["clips"], actual))
        for (old_action, old_clips), (new_action, new_clips) in states:
            if old_action != new_action or values(before, old_clips, True) != values(after, new_clips, False):
                raise RuntimeError(f"Relink changed a retained {key} state")


def measure(binary, project, old, moved, size, runs, selected, history_option):
    writable = project.with_name("relink.cut")
    prefix = f"{old}={moved}"
    recordings, clips, undo_steps, redo_steps = SIZES[size]
    history_only = undo_steps + redo_steps
    inventory_count = recordings + history_only
    offline = inventory_count - recordings // 4
    workloads = {
        "inventory": (("list", project, "--json", *history_option), inventory_count),
        "folder_locate": (("locate", project, "--folder", moved, "--json", *history_option), offline),
        "archive_relink": (("relink", writable, "--map-prefix", prefix,
                            "--in-place", "--json"), offline),
        "relinked_inventory": (("list", writable, "--json", *history_option), inventory_count),
    }
    report = {}
    for name, (arguments, count) in workloads.items():
        if name not in selected:
            continue
        if name == "relinked_inventory" and not writable.exists():
            shutil.copyfile(project, writable)
            invoke(binary, ("project", "media", *workloads["archive_relink"][0]))
            verify_archive(project, writable, old, moved)
        samples = []
        for run in range(runs + 1):
            if name == "archive_relink":
                shutil.copyfile(project, writable)
            elapsed, payload = invoke(binary, ("project", "media", *arguments))
            rows = payload.get("sources") if isinstance(payload, dict) else None
            if not isinstance(rows, list) or len(rows) != count:
                actual = len(rows) if isinstance(rows, list) else rows
                raise RuntimeError(f"{name} returned {actual} rows, expected {count}")
            if name in ("inventory", "relinked_inventory"):
                if sum(len(row["uses"]) for row in rows) != clips + history_only:
                    raise RuntimeError(f"{name} omitted timeline uses")
                expected_offline = offline if name == "inventory" else 0
                if sum(row["status"] == "offline" for row in rows) != expected_offline:
                    raise RuntimeError(f"{name} returned unexpected offline statuses")
                expected_reverts = offline if name == "relinked_inventory" else 0
                if sum(row["can_revert"] for row in rows) != expected_reverts:
                    raise RuntimeError(f"{name} returned unexpected Revert availability")
            if name == "folder_locate":
                for row in rows:
                    wanted = moved / Path(row["path"]).relative_to(old)
                    if (row["outcome"] not in ("match", "verified")
                            or Path(row["candidates"][0]["url"]).resolve() != wanted):
                        raise RuntimeError(f"Locate did not choose {wanted}: {row['candidates']!r}")
            if name == "archive_relink":
                for row in rows:
                    if row["candidate"]["outcome"] not in ("match", "verified"):
                        raise RuntimeError(f"Relink failed for {row['from']}: {row['candidate']!r}")
            if run > 0:
                samples.append(round(elapsed, 3))
        if name == "archive_relink":
            verify_archive(project, writable, old, moved)
        report[name] = {"median_ms": statistics.median(samples), "samples_ms": samples}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="Path to a built mpcut executable")
    parser.add_argument("--size", choices=SIZES, default="session")
    parser.add_argument("--schema-version", type=int, choices=(4, 5), default=5)
    parser.add_argument("--workload", choices=WORKLOADS, action="append",
                        help="Measure just this workload. Repeat to select several.")
    parser.add_argument("--legacy-history-default", action="store_true",
                        help="Omit --include-history for early builds that always include history")
    parser.add_argument("--runs", type=int, default=5, help="Samples per command after one warmup")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    binary = args.binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="mpcut-media-relink-") as directory:
        project, old, moved = fixture(Path(directory).resolve(), args.size, args.schema_version)
        print(json.dumps({
            "binary": str(binary),
            "host": platform.platform(),
            "size": args.size,
            "schema_version": args.schema_version,
            "recordings": SIZES[args.size][0],
            "clips": SIZES[args.size][1],
            "undo_steps": SIZES[args.size][2],
            "redo_steps": SIZES[args.size][3],
            "project_bytes": project.stat().st_size,
            "workloads": measure(binary, project, old, moved, args.size, args.runs,
                                 args.workload or WORKLOADS,
                                 () if args.legacy_history_default else ("--include-history",)),
        }, indent=2))


if __name__ == "__main__":
    main()
