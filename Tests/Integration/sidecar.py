#!/usr/bin/env python3
"""Check shared sidecar creation, reuse, invalidation and concurrent saves."""
import argparse
from fractions import Fraction
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time
import unittest

from sidecar_payload import section_bytes


FIXTURES = Path(__file__).resolve().parents[1] / "MPCutAppTests" / "Fixtures"


class Sidecar(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.source = Path(temp.name) / "Interview.mov"
        shutil.copyfile(FIXTURES / "Pause-Quiet.mov", self.source)
        self.sidecar = self.source.with_suffix(".mov.cutdb")

    def cli(self, *args, success=True, cwd=None):
        run = subprocess.run([CLI, *args], cwd=cwd, capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode == 0, success, run.stdout + run.stderr)
        return json.loads(run.stdout)

    def status(self):
        return self.cli("analysis", "sidecar", "inspect", "--json", self.source)

    def save(self, *flags):
        return self.cli("analysis", "sidecar", "build", "--json", *flags, self.source)

    def test_complete_edition_and_analysis_round_trip(self):
        # Different room floors on two linked audio streams.
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", FIXTURES / "Pause-Quiet.mov",
                        "-i", FIXTURES / "Pause-Noisy.mov", "-map", "0:v:0", "-map", "0:a:0",
                        "-map", "1:a:0", "-c", "copy", self.source], check=True, timeout=120)
        self.assertEqual(self.status()["status"], "missing")
        commands = [
            ["media", "inspect", "--json", self.source],
            ["media", "inspect", "--frames", "--json", self.source],
            ["scenes", "scan", "--json", self.source],
            ["silence", "scan", "--json", "--stream", "1", "--waveform", "64", self.source],
            ["silence", "scan", "--json", "--stream", "2", self.source],
            ["silence", "scan", "--json", "--stream", "2", "--threshold-db", "-40", "--min-pause-seconds", "0.7", self.source],
            ["export", "clips", "join", "--dry-run", "--mode", "smart", "--json", "--output",
             self.source.with_name("out.mov"), "--clip", self.source],
        ]
        fresh = [self.cli("--no-sidecar", *command) for command in commands]
        self.assertFalse(self.sidecar.exists())
        for command, expected in zip(commands, fresh):
            self.assertEqual(self.cli(*command), expected)
        automatic = self.status()
        self.assertTrue(automatic["inventory"]["has_index"])
        self.assertTrue(automatic["inventory"]["has_scenes"])
        self.assertEqual(automatic["inventory"]["waveform_streams"], [1, 2])
        result = self.save()
        self.assertEqual(result["sidecar"], str(self.sidecar))
        self.assertEqual(result["status"], "current")
        self.assertTrue({"waveform_peaks.v1.1", "waveform_peaks.v1.2", "scenes_boundaries.v1", "media_index.v1"} <= set(result["sections"]))
        status = self.status()
        self.assertEqual(result["sections"], status["sections"])
        self.assertEqual(status["inventory"], {
            **result["inventory"],
            "scene_attempts": automatic["inventory"]["scene_attempts"],
        })
        self.assertEqual(result["inventory"], {
            "has_index": True, "has_scenes": True, "waveform_streams": [1, 2], "thumbnail_count": 0,
            "silence": automatic["inventory"]["silence"],
        })
        stamp = self.sidecar.stat().st_mtime_ns
        for command, expected in zip(commands, fresh):
            self.assertEqual(self.cli(*command), expected)
            self.assertEqual(self.cli("--no-sidecar", *command), expected)
        self.assertEqual(self.sidecar.stat().st_mtime_ns, stamp)

    def test_partial_saves_merge_and_changed_source_invalidates(self):
        self.assertEqual(self.save("--only", "scenes")["sections"], ["scenes_boundaries.v1"])
        manual = self.save("--only", "audio", "--stream", "1", "--min-pause-seconds", "0.5", "--threshold-db", "-34")
        self.assertEqual(manual["inventory"]["waveform_streams"], [1])
        self.assertEqual(manual["inventory"]["silence"], [
            {"audio_stream_index": 1, "threshold_mode": "manual", "threshold_db": -34, "min_pause_seconds": 0.5},
        ])
        auto = self.save("--only", "audio")
        tracks = sum(s.startswith("waveform_peaks.v1.") for s in auto["sections"])
        self.assertGreater(tracks, 0)
        self.assertEqual(sum(s.startswith("silence_pauses.v1.") for s in auto["sections"]), tracks + 1)
        self.assertIn("scenes_boundaries.v1", auto["sections"])
        before = self.source.stat()
        os.utime(self.source, ns=(before.st_atime_ns, before.st_mtime_ns + 2_000_000_000))
        status = self.status()
        self.assertEqual(status["status"], "stale")
        self.assertEqual(status["sections"], [])
        self.assertEqual(self.cli("scenes", "scan", "--json", self.source),
                         self.cli("scenes", "scan", "--json", "--no-sidecar", self.source))
        replaced = self.save("--only", "index")
        self.assertEqual(replaced["status"], "current")
        self.assertIn("scenes_boundaries.v1", replaced["sections"])

    def test_foreign_neighbor_is_a_read_miss_and_survives_save(self):
        self.sidecar.write_bytes(b"user-owned file")
        self.assertEqual(self.status()["status"], "unreadable")
        self.assertEqual(self.cli("media", "inspect", "--json", self.source),
                         self.cli("media", "inspect", "--json", "--no-sidecar", self.source))
        self.cli("analysis", "sidecar", "build", "--json", self.source, success=False)
        self.assertEqual(self.sidecar.read_bytes(), b"user-owned file")

    def test_parallel_writers_union_completed_sections(self):
        processes = [
            subprocess.Popen([CLI, "analysis", "sidecar", "build", "--json", "--only", group, self.source],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            for group in ("audio", "index", "scenes")
        ]
        try:
            deadline = time.monotonic() + 30
            logs = [process.communicate(timeout=max(0.1, deadline - time.monotonic())) for process in processes]
        finally:
            # A writer that outlives the shared deadline must not keep running
            # against a scratch folder that the test is about to remove.
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        self.assertEqual(len(logs), 3)
        for process, (out, err) in zip(processes, logs, strict=True):
            self.assertEqual(process.returncode, 0, out + err)
        self.assertTrue({"waveform_peaks.v1.1", "scenes_boundaries.v1", "media_index.v1"} <= set(self.status()["sections"]))

    def test_concurrent_repair_keeps_every_silence_profile(self):
        self.sidecar.touch()
        thresholds = [str(i) for i in range(-52, -44)]
        jobs = [subprocess.Popen([CLI, "--no-sidecar", "analysis", "sidecar", "build", "--only", "audio", "--stream", "1",
                                  "--threshold-db", level, self.source], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                for level in thresholds]
        for job in jobs:
            out, err = job.communicate(timeout=30)
            self.assertEqual(job.returncode, 0, (out, err))
        profiles = self.status()["inventory"]["silence"]
        self.assertEqual(sorted(p["threshold_db"] for p in profiles), sorted(map(float, thresholds)))

    def test_concurrent_waveforms_keep_the_finest_overview(self):
        self.save("--only", "index")
        with sqlite3.connect(self.sidecar) as db:
            db.execute("BEGIN IMMEDIATE")
            # Readers can all see the initial empty cache while their writers wait.
            jobs = [subprocess.Popen([CLI, "waveform", "envelope", "read", "--columns", str(count), self.source],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                    for count in (65536, 959, 960, 961, 962, 963)]
            time.sleep(0.5)
            db.rollback()
            for job in jobs:
                _, err = job.communicate(timeout=30)
                self.assertEqual(job.returncode, 0, err)
            overview = section_bytes(db, "waveform_envelope.v1.1")
            self.assertEqual(len(plistlib.loads(overview)["value"]["low"]), 65536 * 4)

    def test_damaged_section_is_recomputed_and_can_be_repaired(self):
        original = self.cli("scenes", "scan", "--json", self.source)
        self.save("--only", "scenes")
        db = sqlite3.connect(self.sidecar)
        self.addCleanup(db.close)
        with db:
            key, names = "scenes_view_names.v1", b'{"1":"Camera A"}'
            stamp = db.execute("SELECT stamp FROM source WHERE id=1").fetchone()[0]
            digest = hashlib.sha256(stamp.encode() + b"\0" + key.encode() + b"\0" + names).digest()
            db.execute("INSERT INTO sections(name, value, digest) VALUES (?, ?, ?)", (key, names, digest))
            original["views"][0]["name"] = "Camera A"
            db.execute("UPDATE sections SET value = ? WHERE name = 'scenes_boundaries.v1'", (b"damaged",))
        self.assertEqual(self.cli("scenes", "scan", "--json", self.source), original)
        self.assertNotEqual(db.execute("SELECT value FROM sections WHERE name='scenes_boundaries.v1'").fetchone()[0], b"damaged")
        self.save("--only", "scenes")
        self.assertNotEqual(db.execute("SELECT value FROM sections WHERE name='scenes_boundaries.v1'").fetchone()[0], b"damaged")
        self.assertEqual(self.cli("scenes", "scan", "--json", self.source), original)

    def test_no_sidecar_bypasses_a_valid_cached_marker_list(self):
        original = self.cli("scenes", "scan", "--json", self.source)
        frames = self.cli("media", "inspect", "--frames", "--json", self.source)["media"]["frames"]
        self.save("--only", "scenes")
        def rational(t):
            return Fraction(t["numerator"], t["denominator"])
        with sqlite3.connect(self.sidecar) as db:
            stamp = db.execute("SELECT stamp FROM source WHERE id=1").fetchone()[0]
            key = "scenes_boundaries.v1"
            payload = json.loads(section_bytes(db, key))
            # Write a valid, distinguishable marker set so comparing two equal
            # fresh scans cannot accidentally pass this read-through test.
            if len(payload["markers"]) > 1:
                payload["markers"] = payload["markers"][:1]
            else:
                start = rational(frames[len(frames) // 2]["time"])
                pts = (start + rational(original["origin"])) / rational(original["time_base"])
                self.assertEqual(pts.denominator, 1)
                payload["markers"].append({"pts": pts.numerator, "view": 2})
            encoded = json.dumps(payload).encode()
            digest = hashlib.sha256(stamp.encode() + b"\0" + key.encode() + b"\0" + encoded).digest()
            db.execute("UPDATE sections SET logical_size=0, value=?, digest=? WHERE name=?", (encoded, digest, key))
        self.assertNotEqual(self.cli("scenes", "scan", "--json", self.source)["scenes"], original["scenes"])
        self.assertEqual(self.cli("scenes", "scan", "--no-sidecar", "--json", self.source), original)
        with sqlite3.connect(self.sidecar) as db:
            # A previous detector's otherwise valid marker list must be rescanned.
            legacy = "scenes.v1"
            digest = hashlib.sha256(stamp.encode() + b"\0" + legacy.encode() + b"\0" + encoded).digest()
            db.execute("UPDATE sections SET name=?, digest=? WHERE name=?", (legacy, digest, key))
            names_key, names = "viewNames.v1", b'{"1":"Legacy angle"}'
            digest = hashlib.sha256(stamp.encode() + b"\0" + names_key.encode() + b"\0" + names).digest()
            db.execute("INSERT INTO sections(name, value, digest) VALUES (?, ?, ?)", (names_key, names, digest))
        self.assertFalse(self.status()["inventory"]["has_scenes"])
        self.assertEqual(self.cli("scenes", "scan", "--json", self.source), original)
        self.assertEqual(self.cli("--no-sidecar", "scenes", "scan", "--json", self.source), original)
        self.assertTrue(self.save("--only", "scenes")["inventory"]["has_scenes"])
        self.assertEqual(self.cli("scenes", "scan", "--json", self.source), original)

    def test_retired_names_are_ignored_and_preserved_during_rescan(self):
        original = self.cli("scenes", "scan", "--json", self.source)
        self.save("--only", "scenes")
        with sqlite3.connect(self.sidecar) as db:
            stamp = db.execute("SELECT stamp FROM source WHERE id=1").fetchone()[0]
            payload = section_bytes(db, "scenes_boundaries.v1")
            db.execute("DELETE FROM sections WHERE name='scenes_boundaries.v1'")
            for key, value in [("scenes.v1", payload), ("viewNames.v1", b'{"1":"Wide shot"}')]:
                digest = hashlib.sha256(stamp.encode() + b"\0" + key.encode() + b"\0" + value).digest()
                db.execute("INSERT INTO sections(name, value, digest) VALUES (?, ?, ?)", (key, value, digest))
        self.assertFalse(self.status()["inventory"]["has_scenes"])
        named = self.cli("scenes", "scan", "--json", self.source)
        self.assertEqual(named["scenes"], original["scenes"])
        self.assertEqual(named["views"], original["views"])
        self.assertTrue(self.save("--only", "scenes")["inventory"]["has_scenes"])
        self.assertEqual(self.cli("scenes", "scan", "--json", self.source), named)
        self.assertEqual(self.cli("scenes", "scan", "--no-sidecar", "--json", self.source), original)
        with sqlite3.connect(self.sidecar) as db:
            self.assertEqual(db.execute("SELECT value FROM sections WHERE name = ?", ("viewNames.v1",)).fetchone()[0],
                             b'{"1":"Wide shot"}')
            key, value = "scenes_view_names.v1", b"{}"
            digest = hashlib.sha256(stamp.encode() + b"\0" + key.encode() + b"\0" + value).digest()
            db.execute("INSERT INTO sections(name, value, digest) VALUES (?, ?, ?)", (key, value, digest))
        self.assertEqual(self.cli("scenes", "scan", "--json", self.source), original)

    def test_interrupted_save_preserves_previous_sections(self):
        saved = self.save("--only", "scenes")
        with sqlite3.connect(self.sidecar) as db:
            db.execute("BEGIN IMMEDIATE")
            with subprocess.Popen([CLI, "analysis", "sidecar", "build", "--only", "index", "--json", self.source],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
                # Wait for the CLI to open the locked database. A fixed sleep can
                # send SIGINT during dyld startup, before the CLI installs handlers.
                deadline = time.monotonic() + 15
                while subprocess.run(["lsof", "-n", "-P", "-a", "-p", str(process.pid), str(self.sidecar)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
                    if process.poll() is not None or time.monotonic() >= deadline:
                        process.kill()
                        self.fail("the CLI did not open the locked sidecar")
                    time.sleep(0.05)
                process.send_signal(signal.SIGINT)
                try:
                    out, err = process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    out, err = process.communicate()
                    self.fail("the interrupted save did not exit: " + out + err)
            db.rollback()
            self.assertEqual(process.returncode, 130, out + err)
            self.assertEqual(json.loads(out)["error"]["code"], "cancelled")
        self.assertEqual(self.status()["sections"], saved["sections"])

    def test_invalid_and_video_only_selections(self):
        for args in [["--only", "index,audio,index"], ["--only", "audio,"], ["--only", "unknown"],
                     ["--only", "scenes", "--min-pause-seconds", "2"], ["--status", "--no-sidecar"]]:
            failure = self.cli("analysis", "sidecar", "build", "--json", *args, self.source, success=False)
            self.assertEqual(failure["error"]["code"], "invalid_arguments")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", FIXTURES / "Pause-Quiet.mov",
                        "-map", "0:v:0", "-c", "copy", self.source], check=True, timeout=120)
        result = self.cli("analysis", "sidecar", "build", "--json", "--only", "audio", self.source, success=False)
        self.assertEqual(result["error"]["code"], "no_audio")
        self.assertFalse(self.sidecar.exists())
        self.assertIn("scenes_boundaries.v1", self.save()["sections"])

    def test_rearranged_video_and_linked_audio_match_with_saved_index(self):
        self.save("--only", "index")
        hashes = []
        for name, flags in [("saved", []), ("fresh", ["--no-sidecar"])]:
            output = self.source.with_name(f"{name}.mov")
            report = self.cli(*flags, "export", "ranges", "join", "--json", self.source, "--output", output, "2-3,0-1")
            self.assertEqual([part["from"]["numerator"] for part in report["segments"]], [2, 0])
            digest = subprocess.check_output(["ffmpeg", "-v", "error", "-i", output, "-map", "0:v:0", "-map", "0:a",
                                              "-f", "streamhash", "-hash", "sha256", "-"], text=True,
                                             timeout=120)
            self.assertEqual(len(digest.splitlines()), 3)
            hashes.append(digest)
        self.assertEqual(hashes[0], hashes[1])

    def test_option_terminator_preserves_literal_source_filename(self):
        named_like_flag = self.source.with_name("--no-sidecar")
        self.source.rename(named_like_flag)
        result = self.cli("analysis", "sidecar", "build", "--only", "scenes", "--json", "--", named_like_flag.name,
                          cwd=named_like_flag.parent)
        self.assertEqual(Path(result["sidecar"]).name, "--no-sidecar.cutdb")
        status = self.cli("analysis", "sidecar", "inspect", "--json", "--", named_like_flag.name, cwd=named_like_flag.parent)
        self.assertEqual(status["inventory"]["has_scenes"], True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, rest = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *rest])
