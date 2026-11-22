#!/usr/bin/env python3
"""Check CSV record boundaries and optional scene numbers through the CLI."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import ffmpeg


class ListFileAudit(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.directory = Path(scratch.name)
        self.source = self.directory / "\u0301,shot.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=size=128x96:rate=24:duration=1",
               "-c:v", "prores_ks", self.source)
        self.csv = self.directory / "edit.csv"

    def command(self, *args, status=0):
        result = subprocess.run([CLI, "--json", *map(str, args)], cwd=self.directory,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_quoted_clip_path_can_begin_with_combining_mark(self):
        self.csv.write_bytes(f'\ufefffile,from,to\r\n"{self.source.name}",0,0.5\r\n'.encode())
        plan = self.command("export", "--clips", self.csv, "--output", "output.mov",
                            "--dry-run", "--no-sidecar")
        self.assertEqual(len(plan["segments"]), 1)

    def test_empty_csv_scene_number_uses_default(self):
        self.csv.write_text("start,end,view,number\n0,0.5,1,\n0.5,1,2,2\n")
        plan = self.command("scenes", self.source, "--scenes-file", self.csv, "--export-to",
                            self.directory, "--tracks", "video", "--dry-run", "--no-sidecar")
        self.assertEqual(len(plan["outputs"]), 2)

    def test_malformed_json_is_rejected_without_creating_output(self):
        path = self.directory / "clips.json"
        output = self.directory / "output.mov"
        for raw in (b"[" * 520, b'[{"file":"fake","file":"other"}]', b'["fake",]'):
            with self.subTest(raw=raw):
                path.write_bytes(raw)
                result = self.command("export", "--clips", path, "--output", output, status=2)
                self.assertEqual(result["error"]["code"], "invalid_list")
                self.assertFalse(output.exists())

    def test_json_ranges_do_not_round_overprecise_numbers(self):
        ranges = self.directory / "ranges.json"
        args = ("rearrange", self.source, "--ranges", ranges, "--output", "output.mov",
                "--dry-run", "--no-sidecar")
        ranges.write_text('[{"from":0,"to":5e-1}]')
        self.assertEqual(len(self.command(*args)["segments"]), 1)
        ranges.write_text('[{"from":0,"to":0.5' + "0" * 42 + '1}]')
        result = self.command(*args, status=2)
        self.assertEqual(result["error"]["code"], "invalid_list")
        self.assertIn("significant digits", result["error"]["message"])

    def test_json_rational_components_cannot_underflow_to_zero(self):
        clips = self.directory / "clips.json"
        times = self.directory / "times.json"
        clip_args = ("export", "--clips", clips, "--output", "output.mov", "--dry-run", "--no-sidecar")
        time_args = ("frames", self.source, "--at-file", times, "--output", "frames", "--no-sidecar")
        valid = '{"numerator":1,"denominator":2}'
        invalid = '{"numerator":1e-1000,"denominator":1}'
        for rational, status in ((valid, 0), (invalid, 2)):
            with self.subTest(rational=rational):
                clips.write_text('[{"file":' + json.dumps(self.source.name) + ',"from":' + rational + '}]')
                times.write_text("[" + rational + "]")
                self.command(*clip_args, status=status)
                self.command(*time_args, status=status)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    CLI = parser.parse_args().mpcut.resolve()
    unittest.main(argv=[__file__])
