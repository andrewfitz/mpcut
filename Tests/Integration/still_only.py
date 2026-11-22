#!/usr/bin/env python3
"""Verify standalone still authoring, exact picture timing, and tagged delivery."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import ffmpeg, probe, run

CLI = None


class StillOnlyTests(unittest.TestCase):
    def test_creation_rejects_fractional_frame_and_preserves_existing_destination(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-invalid-") as directory:
            root = Path(directory)
            image = root / "first.png"
            cut = root / "stills.cut"
            ffmpeg("-f", "lavfi", "-i", "color=white:size=80x80", "-frames:v", "1", image)
            command = [
                CLI, "still", "create", "--out-project", cut, "--image", image,
                "--width", "320", "--height", "180", "--rate", "30000/1001",
                "--codec", "h264", "--container", "mp4", "--duration",
            ]
            result = subprocess.run([*command, "1", "--json"], capture_output=True, timeout=60)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(cut.exists())
            run([*command, "1001/30000"])
            original = cut.read_bytes()
            result = subprocess.run([*command, "1001/15000", "--json"], capture_output=True, timeout=60)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(cut.read_bytes(), original)

    def test_generated_delivery(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-only-") as directory:
            root = Path(directory)
            image = root / "first.png"
            ffmpeg("-f", "lavfi", "-i", "color=white:size=80x80", "-frames:v", "1", image)
            last_image = root / "last.png"
            ffmpeg("-f", "lavfi", "-i", "color=black:size=80x80", "-frames:v", "1", last_image)
            for codec, extension, program_color, transfer in [
                ("h264", "mp4", "sdr", "bt709"),
                ("h264", "mov", "sdr", "bt709"),
                ("prores", "mov", "sdr", "bt709"),
                ("prores", "mov", "pq", "smpte2084"),
                ("prores", "mov", "hlg", "arib-std-b67"),
                ("hevc", "mov", "sdr", "bt709"),
                ("hevc", "mov", "pq", "smpte2084"),
                ("hevc", "mov", "hlg", "arib-std-b67"),
                ("hevc", "mp4", "sdr", "bt709"),
                ("hevc", "mp4", "pq", "smpte2084"),
                ("hevc", "mp4", "hlg", "arib-std-b67"),
            ]:
                with self.subTest(codec=codec, container=extension, color=program_color):
                    name = f"{codec}-{extension}-{program_color}"
                    cut = root / f"{name}.cut"
                    output = root / f"{name}.{extension}"
                    run([
                        CLI, "still", "create", "--out-project", cut, "--image", image,
                        "--width", "320", "--height", "180", "--rate", "30000/1001",
                        "--codec", codec, "--container", extension, "--color", program_color, "--frames", "5",
                    ])
                    project = json.loads(cut.read_text())
                    self.assertEqual(project["schemaVersion"], 2)
                    self.assertEqual(project["clips"][0]["kind"], "still")
                    self.assertEqual(project["stillAssets"][0]["file"], image.name)
                    self.assertEqual(project["programColorPolicy"]["transfer"], transfer)
                    run([
                        CLI, "still", "add", "--project", cut, "--image", last_image, "--insert",
                        "--clock", "sequence", "--at", "1001/6000", "--duration", "1001/30000", "--in-place", "--json",
                    ])
                    report = json.loads(run([
                        CLI, "export", "--project", cut, "--require-camera-copy", "--output", output, "--json",
                    ], allow_diagnostics=True))
                    self.assertEqual(report["copiedCameraDuration"], {"numerator": 0, "denominator": 1})
                    self.assertEqual(report["encodedCameraDuration"], {"numerator": 0, "denominator": 1})
                    self.assertEqual(report["generatedStillDuration"], {"numerator": 1001, "denominator": 5000})
                    streams = probe(output, "-show_streams", "-count_frames")["streams"]
                    self.assertEqual(len(streams), 1)
                    stream = streams[0]
                    self.assertEqual(stream["codec_name"], codec)
                    self.assertEqual(stream["color_transfer"], transfer)
                    self.assertEqual((stream["width"], stream["height"]), (320, 180))
                    self.assertEqual(int(stream["nb_read_frames"]), 6)
                    self.assertEqual(Fraction(stream["time_base"]) * int(stream["duration_ts"]), Fraction(1001, 5000))
                    frames = ffmpeg("-i", output, "-vf", "crop=2:2:160:90,format=gray", "-f", "rawvideo", "-")
                    self.assertEqual(len(frames), 6 * 4)
                    self.assertGreater(frames[0], frames[-1] + 64)

    def test_explicit_conversion_uses_stored_delivery(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-convert-") as directory:
            root = Path(directory)
            image = root / "card.png"
            cut = root / "stills.cut"
            output = root / "stills.mov"
            ffmpeg("-f", "lavfi", "-i", "color=white:size=80x80", "-frames:v", "1", image)
            run([
                CLI, "still", "create", "--out-project", cut, "--image", image,
                "--width", "320", "--height", "180", "--rate", "30000/1001",
                "--codec", "hevc", "--container", "mov", "--color", "pq", "--frames", "5", "--json",
            ])
            run([
                CLI, "export", "--project", cut, "--mode", "encode", "--require-camera-copy", "--output", output, "--json",
            ], allow_diagnostics=True)
            streams = probe(output, "-show_streams", "-count_frames")["streams"]
            self.assertEqual(len(streams), 1)
            stream = streams[0]
            self.assertEqual(stream["codec_name"], "hevc")
            self.assertEqual(stream["color_transfer"], "smpte2084")
            self.assertEqual(int(stream["nb_read_frames"]), 5)
            self.assertEqual(Fraction(stream["time_base"]) * int(stream["duration_ts"]), Fraction(1001, 6000))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cli")
    args = parser.parse_args()
    CLI = str(Path(args.cli).resolve())
    unittest.main(argv=[__file__], verbosity=2)
