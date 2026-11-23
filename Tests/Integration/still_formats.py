#!/usr/bin/env python3
"""Exercise still image detection using the public inspect command of a built CLI."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

FIXTURES = Path(__file__).with_name("fixtures") / "stills"
CLI = None


class StillFormatTests(unittest.TestCase):
    def inspect(self, source, *options, expected_success=True):
        result = subprocess.run([CLI, "media", "inspect", "--json", *options, source],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, expected_success, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["ok"], expected_success, report)
        return report

    def test_supported_formats(self):
        for codec in ("png", "jpeg", "tiff", "webp", "heic", "avif"):
            with self.subTest(codec=codec):
                image = self.inspect(FIXTURES / f"patch.{codec}")["image"]
                self.assertEqual(image["codec"], codec)
                self.assertEqual((image["width"], image["height"]), (32, 32))
                self.assertEqual(image["rendition"], "sdr")
                if codec in ("png", "webp"):
                    self.assertTrue(image["has_alpha"])

    def test_explicit_gain_map_rendition(self):
        for codec in ("jpeg", "heic"):
            with self.subTest(codec=codec):
                image = self.inspect(FIXTURES / f"gain-map.{codec}")["image"]
                self.assertEqual(image["rendition"], "gain_map")
                self.assertIn("iso_gain_map", image["auxiliary_images"])

    def test_jxl_high_precision_pq(self):
        image = self.inspect(FIXTURES / "pq_gradient.jxl")["image"]
        self.assertEqual((image["codec"], image["width"], image["height"]), ("jxl", 1088, 64))
        self.assertGreaterEqual(image["bits_per_component"], 10)
        self.assertIn(image["rendition"], ("pq", "linear_hdr"))

    def test_jxl_container_is_sdr(self):
        image = self.inspect(FIXTURES / "square-extended-size-container.jxl")["image"]
        self.assertEqual((image["codec"], image["width"], image["height"]), ("jxl", 8, 8))
        self.assertEqual(image["rendition"], "sdr")

    def test_decoded_codec_and_damaged_input(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.jpg"
            shutil.copyfile(FIXTURES / "patch.webp", path)
            self.assertEqual(self.inspect(path)["image"]["codec"], "webp")
            path.write_bytes(b"no valid image")
            error = self.inspect(path, expected_success=False)["error"]
            self.assertIn(error["code"], ("still_decode", "still_format"))

    def test_tagged_hdr_avif(self):
        for rendition in ("pq", "hlg"):
            with self.subTest(rendition=rendition):
                image = self.inspect(FIXTURES / f"hdr-{rendition}.avif")["image"]
                self.assertEqual((image["codec"], image["rendition"]), ("avif", rendition))

    def test_animated_images(self):
        for codec in ("webp", "jxl"):
            with self.subTest(codec=codec):
                error = self.inspect(FIXTURES / f"animated.{codec}", expected_success=False)["error"]
                self.assertEqual(error["code"], "still_animated")

    def test_extensionless_jxl_and_named_pipe(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "untitled"
            shutil.copyfile(FIXTURES / "square-extended-size-container.jxl", source)
            self.assertEqual(self.inspect(source)["image"]["codec"], "jxl")
            pipe = source.with_suffix(".png")
            os.mkfifo(pipe)
            self.assertEqual(self.inspect(pipe, expected_success=False)["error"]["code"], "still_format")

    def test_frame_options_rejected_for_untimed_image(self):
        error = self.inspect(FIXTURES / "patch.avif", "--frames", expected_success=False)["error"]
        self.assertEqual(error["code"], "invalid_arguments")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", type=Path)
    args, remaining = parser.parse_known_args()
    CLI = args.cli.resolve()
    unittest.main(argv=[__file__, *remaining])
