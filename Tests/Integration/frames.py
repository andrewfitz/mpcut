#!/usr/bin/env python3
"""Verify frame manifests against decoded JPEG pixels, ranges and source clocks."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


def run(args):
    return subprocess.run(args, check=True, capture_output=True, timeout=120).stdout


def ratio(value):
    return Fraction(value["numerator"], value["denominator"])


def rgb(path, xfrac=0.5, yfrac=0.5):
    data = run(["ffmpeg", "-loglevel", "error", "-i", path, "-vf",
                f"format=rgb24,crop=1:1:iw*{xfrac}:ih*{yfrac}", "-frames:v", "1",
                "-c:v", "rawvideo", "-f", "rawvideo", "-"])
    return tuple(data)


class Frames(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.source = cls.root / "five.mov"
        graphs = [f"color={color}:s=720x240:r=25:d=1[v{i}]" for i, color in enumerate(
            ["red", "blue", "red", "blue", "yellow"])]
        graphs += ["[v0][v1][v2][v3][v4]concat=n=5:v=1:a=0[v]",
                   "aevalsrc='if(between(t,1,2)+between(t,3,4),sin(440*2*PI*t)*0.35,0)':s=48000:d=5[a]"]
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", ";".join(graphs) + ";[v]null[out0];[a]anull[out1]",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "25", "-c:a", "pcm_s16le", cls.source])

    def export(self, name, *flags, count, source=None):
        dest = self.root / name
        stdout = run([CLI, "frames", "--json", "--output", dest, *flags, source or self.source])
        report = json.loads(stdout)
        self.assertEqual(json.loads((dest / "manifest.json").read_bytes()), report)
        # Every caller states how many pictures it expects, so the per-frame
        # checks below and in the tests cannot pass on a short or empty list.
        self.assertEqual(len(report["frames"]), count, report)
        for frame in report["frames"]:
            file = dest / frame["file"]
            self.assertEqual(file.read_bytes()[:2], b"\xff\xd8")
            dims = run(["ffprobe", "-loglevel", "error", "-show_entries", "stream=width,height",
                        "-of", "csv=p=0:s=x", file]).decode().strip()
            self.assertEqual(dims, f"{frame['width']}x{frame['height']}")
        return dest, report

    def test_scene_samples_and_budget(self):
        dest, report = self.export("budget", "--limit", "2", count=2)
        self.assertEqual(report["rangeCount"], 5)
        self.assertEqual([f["sceneNumber"] for f in report["frames"]], [1, 5])
        self.assertEqual([ratio(f["frameTime"]) for f in report["frames"]], [Fraction(12,25), Fraction(112,25)])
        self.assertEqual([(f["width"], f["height"]) for f in report["frames"]], [(640,213)]*2)
        r, g, b = rgb(dest / report["frames"][1]["file"])
        self.assertTrue(r > 180 and g > 180 and b < 50)
        _, single = self.export("middle", "--limit", "1", "--sample", "first", "--preset", "full", count=1)
        first = single["frames"][0]
        self.assertEqual((first["sceneNumber"], ratio(first["frameTime"]), first["width"]), (3,2,720))

    def test_requested_order_duplicates_and_refusal(self):
        dest, report = self.export("times", "--at", "17/5", "--at", "0.4", "--at", "3.41", count=3)
        frames = report["frames"]
        self.assertEqual([ratio(f["frameTime"]) for f in frames], [Fraction(17,5), Fraction(2,5), Fraction(17,5)])
        self.assertEqual((dest / frames[0]["file"]).read_bytes(), (dest / frames[2]["file"]).read_bytes())
        self.assertGreater(rgb(dest / frames[0]["file"])[2], 200)
        self.assertGreater(rgb(dest / frames[1]["file"])[0], 200)
        kept = sorted(path.name for path in dest.iterdir())
        for output, flags, status, code in [
                (dest, [], 1, "output_exists"),
                (self.root / "badtime", ["--at","5"], 1, "invalid_range"),
                (self.root / "badlimit", ["--at","0","--limit","1"], 2, "invalid_arguments")]:
            with self.subTest(code=code, flags=flags):
                result = subprocess.run([CLI, "frames", "--json", "--output", output, *flags, self.source],
                                        capture_output=True, timeout=120)
                self.assertEqual(result.returncode, status, result.stdout)
                report = json.loads(result.stdout)
                self.assertIs(report["ok"], False)
                self.assertEqual(report["error"]["code"], code, report)
                if output != dest:
                    self.assertFalse(output.exists())
        self.assertEqual(sorted(path.name for path in dest.iterdir()), kept)

    def test_non_silent_ranges_and_empty_manifest(self):
        _, report = self.export("audible", "--select", "non-silent", "--min-pause", "0.35",
                                "--threshold-db", "-45", "--sample", "first", count=2)
        self.assertEqual(report["stream"], 1)
        self.assertEqual(report["rangeCount"], 2)
        for f, expected in zip(report["frames"], [1,3], strict=True):
            self.assertAlmostEqual(float(ratio(f["from"])), expected, delta=.021)
            self.assertAlmostEqual(float(ratio(f["to"])), expected + 1, delta=.021)
            self.assertLessEqual(ratio(f["clipFrom"]), ratio(f["from"]))
            self.assertGreaterEqual(ratio(f["clipTo"]), ratio(f["to"]))
        dest, empty = self.export("empty", "--select", "non-silent", "--threshold-db", "0", "--min-pause", "0.1", count=0)
        self.assertEqual(empty["frames"], [])
        self.assertEqual(list(dest.iterdir()), [dest / "manifest.json"])

    def test_vfr_held_frame_and_nonzero_origin(self):
        source = self.root / "offset.mkv"
        run(["ffmpeg", "-loglevel", "error", "-i", self.source, "-an", "-vf", "setpts='(N+if(gte(N,25),9,0))/(25*TB)'",
             "-fps_mode", "vfr", "-c:v", "ffv1", "-output_ts_offset", "2", source])
        dest, report = self.export("vfr", "--at", "1.15", "--at", "1.38", count=2, source=source)
        self.assertEqual(ratio(report["origin"]), 2)
        for f, time, channel in zip(report["frames"], [Fraction(24,25), Fraction(34,25)], [0,2], strict=True):
            self.assertEqual(ratio(f["frameTime"]), time)
            self.assertEqual(f["framePTS"] * ratio(report["timeBase"]), 2 + time)
            self.assertGreater(rgb(dest / f["file"])[channel], 200)

    def test_duplicate_presentation_timestamp_cannot_select_a_picture(self):
        source = self.root / "duplicate-pts.mkv"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "color=red:s=320x180:r=1:d=1[r];color=blue:s=320x180:r=1:d=1[b];"
             "color=lime:s=320x180:r=1:d=1[g];"
             "[r][b][g]concat=n=3:v=1:a=0,setpts='if(lt(N,2),0,1/TB)'",
             "-fps_mode", "passthrough", "-c:v", "ffv1", source])
        dest = self.root / "duplicate-pictures"
        result = subprocess.run([CLI, "frames", "--json", "--at", "0", "--output", dest, source],
                                capture_output=True, timeout=120)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "ambiguous_frame")
        self.assertFalse(dest.exists())
        self.assertFalse(list(self.root.glob(".mpcut-frames-*")))
        dest, report = self.export("unique-picture", "--at", "1", count=1, source=source)
        frame = report["frames"][0]
        self.assertEqual(ratio(frame["frameTime"]), 1)
        self.assertGreater(rgb(dest / frame["file"])[1], 200)

    def test_portrait_rotation_changes_pixels_and_dimensions(self):
        base = self.root / "split.mp4"
        source = self.root / "portrait.mov"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "color=red:s=320x160:d=1,drawbox=x=160:y=0:w=160:h=160:c=blue:t=fill", "-c:v", "libx264", base])
        run(["ffmpeg", "-loglevel", "error", "-display_rotation", "90", "-i", base, "-c", "copy", source])
        dest, result = self.export("portrait", "--at", "0", "--preset", "full", count=1, source=source)
        f = result["frames"][0]
        self.assertEqual((f["width"], f["height"]), (160,320))
        self.assertGreater(rgb(dest / f["file"], yfrac=.2)[2], 200)
        self.assertGreater(rgb(dest / f["file"], yfrac=.8)[0], 200)

    def test_review_keeps_rows_of_horizontally_squeezed_software_picture(self):
        source = self.root / "squeezed.mkv"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "nullsrc=s=1280x400:r=1:d=1,format=gray,geq=lum='255*mod(Y,2)',setsar=1/4",
             "-c:v", "ffv1", source])
        dest, report = self.export("squeezed-review", "--at", "0", count=1, source=source)
        frame = report["frames"][0]
        self.assertEqual((frame["width"], frame["height"]), (320, 400))
        image = dest / frame["file"]
        adjacent_rows = sorted(rgb(image, yfrac=(y + 0.1) / 400)[0] for y in (198, 199))
        self.assertLess(adjacent_rows[0], 40)
        self.assertGreater(adjacent_rows[1], 215)

    def test_untagged_yuv_has_same_colors_across_decoders(self):
        hardware = self.root / "untagged.mp4"
        software = self.root / "untagged.mkv"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "color=red:s=320x240:r=1:d=1[r];color=lime:s=320x240:r=1:d=1[g];"
             "[r][g]concat=n=2:v=1:a=0", "-c:v", "libx264", hardware])
        # FFV1 stores the H.264 software decoder's exact YUV samples.
        run(["ffmpeg", "-loglevel", "error", "-i", hardware, "-c:v", "ffv1", software])
        rgb_by_decoder = []
        for source in (hardware, software):
            dest, report = self.export(f"untagged-{source.suffix[1:]}", "--at", "0", "--at", "1",
                                       "--preset", "full", count=2, source=source)
            rgb_by_decoder.append([rgb(dest / frame["file"]) for frame in report["frames"]])
        for hardware_pixel, software_pixel in zip(*rgb_by_decoder, strict=True):
            for hardware_channel, software_channel in zip(hardware_pixel, software_pixel, strict=True):
                self.assertAlmostEqual(hardware_channel, software_channel, delta=4)

    def test_anamorphic_bitstream_rotation_survives_first_seek(self):
        # The H.264 display orientation SEI occurs on the first decoded picture.
        # The MOV container has no display matrix. Seek past several closed GOPs.
        source = self.root / "bitstream.mp4"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "color=red:s=240x160:r=12:d=6,drawbox=x=120:y=0:w=120:h=160:c=blue:t=fill,setsar=4/3",
             "-c:v", "libx264", "-g", "12", "-bsf:v", "h264_metadata=display_orientation=insert:rotate=90", source])
        dest, result = self.export("bitstream", "--at", "5.5", "--preset", "full", count=1, source=source)
        f = result["frames"][0]
        self.assertEqual((f["width"], f["height"]), (160, 320))
        self.assertGreater(rgb(dest / f["file"], yfrac=.2)[2], 200)
        self.assertGreater(rgb(dest / f["file"], yfrac=.8)[0], 200)

    def test_full_preset_follows_midstream_resolution_change(self):
        source = self.root / "switch.ts"
        with source.open("xb") as stream:
            for second, (size, color) in enumerate([("320x192", "red"), ("640x288", "blue")]):
                stream.write(run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                                  f"color={color}:s={size}:r=12:d=1", "-c:v", "libx264",
                                  "-bf", "0", "-g", "12", "-muxdelay", "0", "-output_ts_offset",
                                  str(second), "-f", "mpegts", "-"]))
        dest, result = self.export("switch-pictures", "--at", "0.5", "--at", "1.5",
                                   "--preset", "full", count=2, source=source)
        self.assertEqual([(f["width"], f["height"]) for f in result["frames"]], [(320, 192), (640, 288)])
        for frame, channel in zip(result["frames"], [0, 2], strict=True):
            self.assertGreater(rgb(dest / frame["file"])[channel], 200)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
