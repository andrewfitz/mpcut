#!/usr/bin/env python3
"""Verify standalone still authoring, exact picture timing, and tagged delivery."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.etree import ElementTree

from media_regression import ffmpeg, probe, run

CLI = None


class StillOnlyTests(unittest.TestCase):
    def test_single_gap_black_and_custom_color(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-color-gap-") as directory:
            root = Path(directory)
            cut = root / "background.cut"
            report = json.loads(run([CLI, "still", "project", "create", "--gap", "--out-project", cut, "--width", "160",
                                     "--height", "96", "--rate", "24", "--codec", "h264", "--container", "mov",
                                     "--frames", "12", "--json"]))
            for name, expected in [("black", (0, 0, 0)), ("red", (255, 0, 0))]:
                if name == "red":
                    run([CLI, "still", "placement", "update", "--project", cut, "--placement", report["placement_id"],
                         "--background", "#FF0000", "--in-place"])
                output = root / (name + ".mov")
                run([CLI, "export", "project", "render", "--project", cut, "--output", output], allow_diagnostics=True)
                pixels = ffmpeg("-i", output, "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-")
                self.assertEqual(len(pixels), 160 * 96 * 3)
                for channel, target in enumerate(expected):
                    self.assertLess(max(abs(value - target) for value in pixels[channel::3]), 5)

    def test_fcpxml_still_asset_clip_and_relative_media(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-fcpxml-still-") as directory:
            root = Path(directory)
            image = root / "Card #1.png"
            ffmpeg("-f", "lavfi", "-i", "color=white:size=80x80", "-frames:v", "1", image)
            cut = root / "Stills.cut"
            xml = root / "Stills.fcpxml"
            run([
                CLI, "still", "project", "create", "--out-project", cut, "--image", image,
                "--width", "320", "--height", "180", "--rate", "24",
                "--codec", "h264", "--container", "mov", "--frames", "12",
            ])
            run([CLI, "project", "convert", cut, "--output", xml])
            tree = ElementTree.parse(xml)
            tree.find(".//spine/video").tag = "asset-clip"
            tree.find(".//media-rep").set("src", "Card%20%231.png")
            tree.write(xml, encoding="utf-8", xml_declaration=True)
            sibling = root / "Sibling.cut"
            run([CLI, "project", "convert", xml, "--output", sibling])
            self.assertEqual(json.loads(sibling.read_text())["still_assets"][0]["file"], image.name)
            nested = root / "nested"
            nested.mkdir()
            restored = nested / "Restored.cut"
            run([CLI, "project", "convert", xml, "--output", restored])
            original = json.loads(cut.read_text())
            result = json.loads(restored.read_text())
            self.assertEqual(result["clips"], original["clips"])
            self.assertEqual(result["still_format"], original["still_format"])
            self.assertEqual(result["still_assets"][0]["file"], "../Card #1.png")

    def test_interchange_refuses_a_timeline_with_no_retained_material(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-conversion-") as directory:
            root = Path(directory)
            image = root / "Card.png"
            cut = root / "Stills.cut"
            ffmpeg("-f", "lavfi", "-i", "color=white:size=80x80", "-frames:v", "1", image)
            create = [
                CLI, "still", "project", "create", "--image", image,
                "--width", "320", "--height", "180", "--rate", "24",
                "--container", "mov", "--frames", "12",
            ]
            run([*create, "--out-project", cut, "--codec", "h264"])
            hdr = root / "HDR.cut"
            run([*create, "--out-project", hdr, "--codec", "hevc", "--color", "pq"])
            for source, extension in [(cut, "drp"), (cut, "drt"), (cut, "prproj"), (hdr, "fcpxml")]:
                output = root / f"Converted.{extension}"
                command = [CLI, "project", "convert", source, "--output", output, "--json"]
                for flags, code in [([], "conversion_loss"), (["--allow-loss"], "empty_sequence")]:
                    with self.subTest(extension=extension, code=code):
                        result = subprocess.run([*command, *flags], capture_output=True, timeout=60)
                        self.assertNotEqual(result.returncode, 0)
                        error = json.loads(result.stdout)["error"]
                        self.assertEqual(error["code"], code)
                        self.assertIn("Insert Still placement", error["message"])
                        self.assertFalse(output.exists())

    def test_creation_rejects_fractional_frame_and_preserves_existing_destination(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-invalid-") as directory:
            root = Path(directory)
            image = root / "first.png"
            cut = root / "stills.cut"
            ffmpeg("-f", "lavfi", "-i", "color=white:size=80x80", "-frames:v", "1", image)
            command = [
                CLI, "still", "project", "create", "--out-project", cut, "--image", image,
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
                        CLI, "still", "project", "create", "--out-project", cut, "--image", image,
                        "--width", "320", "--height", "180", "--rate", "30000/1001",
                        "--codec", codec, "--container", extension, "--color", program_color, "--frames", "5",
                    ])
                    project = json.loads(cut.read_text())
                    self.assertEqual(project["schema_version"], 4)
                    self.assertEqual(project["clips"][0]["kind"], "still")
                    self.assertEqual(project["still_assets"][0]["file"], image.name)
                    self.assertEqual(project["program_color_policy"]["transfer"], transfer)
                    run([
                        CLI, "still", "placement", "insert", "--project", cut, "--image", last_image, "--clock", "sequence", "--at", "1001/6000", "--duration", "1001/30000", "--in-place", "--json",
                    ])
                    report = json.loads(run([
                        CLI, "export", "project", "render", "--project", cut, "--require-camera-copy", "--output", output, "--json",
                    ], allow_diagnostics=True))
                    self.assertEqual(report["copied_camera_duration"], {"numerator": 0, "denominator": 1})
                    self.assertEqual(report["encoded_camera_duration"], {"numerator": 0, "denominator": 1})
                    self.assertEqual(report["generated_still_duration"], {"numerator": 1001, "denominator": 5000})
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
                CLI, "still", "project", "create", "--out-project", cut, "--image", image,
                "--width", "320", "--height", "180", "--rate", "30000/1001",
                "--codec", "hevc", "--container", "mov", "--color", "pq", "--frames", "5", "--json",
            ])
            run([
                CLI, "export", "project", "render", "--project", cut, "--mode", "encode", "--require-camera-copy", "--output", output, "--json",
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
