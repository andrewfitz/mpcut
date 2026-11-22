#!/usr/bin/env python3
"""Exercise native archives using the installed, running Resolve host."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import ffmpeg


class ResolveNativeTests(unittest.TestCase):
    def convert(self, source, destination, *flags, succeeds=True):
        process = subprocess.run([CLI, "convert", str(source), "--output", str(destination), "--json", *flags],
                                 text=True, capture_output=True, timeout=240)
        self.assertEqual(process.returncode == 0, succeeds, process.stdout + process.stderr)
        return json.loads(process.stdout)

    def test_reopen_archives_and_preserve_repeated_source_ranges(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            media = folder / "Camera & sound.mov"
            ffmpeg("-f", "lavfi", "-i", "testsrc2=s=512x288:r=24:d=4",
                   "-f", "lavfi", "-i", "sine=frequency=440:d=4", "-map", "0:v", "-map", "1:a",
                   "-c:v", "prores_ks", "-c:a", "pcm_s16le", media)
            ranges = [("2", "3"), ("0", "2"), ("2", "3")]
            source = folder / "Test.cut"
            source.write_text(json.dumps(dict(format="mpcut", schemaVersion=1, kind="sequence", clips=[
                {"id": str(i), "file": media.name, "from": a, "to": b} for i, (a, b) in enumerate(ranges)])))
            for ext in ("drp", "drt"):
                with self.subTest(ext=ext):
                    native = source.with_suffix("." + ext)
                    self.convert(source, native)
                    self.assertGreater(native.stat().st_size, 0)
                    restored = folder / f"back-{ext}.cut"
                    blocked = self.convert(native, restored, succeeds=False)
                    self.assertEqual(blocked["error"]["code"], "conversion_loss")
                    self.assertFalse(restored.exists())
                    self.convert(native, restored, "--allow-loss")
                    clips = json.loads(restored.read_text())["clips"]
                    self.assertEqual([(c["from"], c["to"]) for c in clips], ranges)
                    for clip in clips:
                        self.assertEqual((folder / clip["file"]).resolve(), media.resolve())

    def test_host_timebase_and_raster_substitutions(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            source = folder / "Timeline.cut"
            output = folder / "Timeline.drp"
            for rate in (7, 24):
                media = folder / f"Camera-{rate}.mov"
                ffmpeg("-f", "lavfi", "-i", f"testsrc2=s=160x90:r={rate}:d=2", "-c:v", "prores_ks", media)
                source.write_text(json.dumps(dict(format="mpcut", schemaVersion=1, kind="sequence", clips=[
                    {"id": "take", "file": media.name, "from": "0", "to": "1"}])))
                error = self.convert(source, output, succeeds=False)["error"]
                self.assertEqual(error["code"], "resolve_timebase_changed" if rate == 7 else "conversion_loss")
                self.assertFalse(output.exists())
                self.assertFalse(list(folder.glob("* Media *")))
            warnings = self.convert(source, output, "--allow-loss")["warnings"]
            self.assertTrue(any("160×90" in w and "256×256" in w for w in warnings), warnings)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True, type=Path)
    args, remaining = parser.parse_known_args()
    CLI = args.cli.resolve()
    unittest.main(argv=[__file__, *remaining])
