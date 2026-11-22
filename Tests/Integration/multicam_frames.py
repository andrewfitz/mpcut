#!/usr/bin/env python3
"""Verify synchronized project JPEGs, source clocks, availability, and publication."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

from frames import ratio, rgb, run


class MulticamFrames(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workspace = tempfile.TemporaryDirectory()
        cls.addClassCleanup(workspace.cleanup)
        cls.root = Path(workspace.name)
        cls.media = cls.root / "media"
        cls.media.mkdir()
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "color=red:s=160x96:r=4:d=3",
             "-c:v", "ffv1", cls.media / "wide.mkv"])
        # Two different pictures on a nonzero PTS clock. The first is held
        # through the sparse portion of the VFR stream.
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "color=blue:s=160x96:r=4:d=0.25[b];color=lime:s=160x96:r=4:d=0.25[g];"
             "[b][g]concat=n=2:v=1:a=0,settb=expr=1/4,setpts='if(eq(N,0),0,3)'",
             "-enc_time_base", "1:4", "-fps_mode", "passthrough", "-c:v", "ffv1", "-output_ts_offset", "2",
             cls.media / "close.mkv"])
        (cls.media / "bad.mov").write_bytes(b"Not a recording")
        cls.project = cls.root / "interview.cut"
        cls.project.write_text(json.dumps({
            "format": "mpcut", "schemaVersion": 1, "kind": "multicam", "referenceAngle": "wide",
            "range": {"from": "0", "to": "3"},
            "angles": [
                {"id": "wide", "file": "media/wide.mkv", "offset": "0"},
                {"id": "close", "name": "Close", "file": "media/close.mkv", "offset": "1/2"},
                {"id": "lost", "file": "media/missing.mov", "offset": "0"},
                {"id": "damaged", "file": "media/bad.mov", "offset": "0"},
            ],
            "audio": {"mode": "follow"},
            "switches": [{"at": "0", "angle": "wide"}, {"at": "1", "angle": "close"}],
            "assembly": [{"from": "2", "to": "3"}],
        }))

    def cmd(self, dest, *options):
        return [CLI, "frames", "--json", "--project", self.project, "--output", dest, *options]

    def test_aligned_requests_and_unavailable_angles(self):
        dest = self.root / "angles"
        requests = ["9/8", "0", "5/4", "3/2", "9/8"]
        flags = [flag for stamp in requests for flag in ("--at", stamp)]
        report = json.loads(run(self.cmd(dest, *flags)))
        self.assertEqual(json.loads((dest / "manifest.json").read_bytes()), report)
        angles = report["angles"]
        self.assertEqual([angle["id"] for angle in angles], ["wide", "close", "lost", "damaged"])
        self.assertEqual(angles[1]["file"], str(self.media / "close.mkv"))
        self.assertEqual(ratio(angles[1]["origin"]), 2)
        self.assertEqual(angles[2]["error"]["code"], "missing_source")
        self.assertEqual(angles[3]["error"]["code"], "probe_failed")
        rows = report["frames"]
        self.assertEqual([(r["requestNumber"], ratio(r["groupTime"]), r["angleID"]) for r in rows],
                         [(i, Fraction(t), angle["id"])
                          for i, t in enumerate(requests, 1) for angle in angles])
        self.assertEqual([r["availability"] for r in rows[1::4]],
                         ["available", "beforeSource", "available", "afterSource", "available"])
        self.assertEqual([ratio(r["sourceTime"]) for r in rows[1::4]],
                         [Fraction(t) - Fraction(1, 2) for t in requests])
        self.assertTrue(all(r["availability"] == "missingSource" for r in rows[2::4]))
        self.assertTrue(all(r["availability"] == "sourceError" for r in rows[3::4]))
        self.assertEqual(sorted(p.name for p in dest.glob("*.jpg")),
                         sorted(r["file"] for r in rows if r["availability"] == "available"))
        for row in rows:
            if row["availability"] != "available":
                self.assertTrue({"file", "framePTS", "frameTime", "groupCoverage"}.isdisjoint(row))
                continue
            path = dest / row["file"]
            self.assertEqual(path.read_bytes()[:2], b"\xff\xd8")
            coverage = row["groupCoverage"]
            self.assertLessEqual(ratio(coverage["from"]), ratio(row["groupTime"]))
            self.assertGreater(ratio(coverage["to"]), ratio(row["groupTime"]))
            angle = angles[0 if row["angleID"] == "wide" else 1]
            self.assertEqual(row["framePTS"] * ratio(angle["timeBase"]),
                             ratio(angle["origin"]) + ratio(row["frameTime"]))
        first, second, last = rows[1], rows[9], rows[17]
        self.assertEqual(ratio(first["frameTime"]), 0)
        self.assertEqual(ratio(second["frameTime"]), Fraction(3, 4))
        self.assertEqual((dest / first["file"]).read_bytes(), (dest / last["file"]).read_bytes())
        self.assertGreater(rgb(dest / rows[0]["file"])[0], 200)
        self.assertGreater(rgb(dest / first["file"])[2], 200)
        self.assertGreater(rgb(dest / second["file"])[1], 200)

    def test_group_bounds_option_errors_and_existing_folder(self):
        dest = self.root / "invalid"
        for flags, exit_status, code in [
            ([], 2, "invalid_arguments"),
            (["--at", "0", "--select", "scenes"], 2, "invalid_arguments"),
            (["--at", "0", self.media / "wide.mkv"], 2, "invalid_arguments"),
            (["--at", "-1/4"], 1, "invalid_range"),
            (["--at", "3"], 1, "invalid_range"),
        ]:
            with self.subTest(flags=flags):
                result = subprocess.run(self.cmd(dest, *flags), capture_output=True, timeout=120)
                self.assertEqual(result.returncode, exit_status, result.stdout)
                self.assertEqual(json.loads(result.stdout)["error"]["code"], code)
                self.assertFalse(dest.exists())
        dest.mkdir()
        marker = dest / "keep"
        marker.write_bytes(b"unchanged")
        result = subprocess.run(self.cmd(dest, "--at", "0"), capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "output_exists")
        self.assertEqual(list(dest.iterdir()), [marker])
        self.assertEqual(marker.read_bytes(), b"unchanged")

    def test_cancellation_removes_staged_jpegs(self):
        dest = self.root / "cancelled"
        with subprocess.Popen(self.cmd(dest, *(["--at", "1"] * 6000)),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline and process.poll() is None:
                    if next(self.root.glob(".mpcut-frames-*/*.jpg"), None) is not None:
                        process.send_signal(signal.SIGINT)
                        break
                    time.sleep(0.01)
                else:
                    self.fail("No staged JPEG observed before the process finished or timed out")
                stdout, _ = process.communicate(timeout=30)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(json.loads(stdout)["error"]["code"], "cancelled")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        self.assertFalse(dest.exists())
        self.assertFalse(list(self.root.glob(".mpcut-frames-*")))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
