#!/usr/bin/env python3
"""Verify Smart Trim and Re-encode around one picture whose coded data is damaged.

An export either writes exactly the selected pictures or fails with a structured
error. It never writes a picture decoded from damaged data."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
FPS = 25
CLI = None


def run(args, check=True):
    return subprocess.run([str(arg) for arg in args], check=check, capture_output=True, timeout=180)


def packets(path):
    report = run([FFPROBE, "-loglevel", "error", "-select_streams", "v:0", "-show_packets",
                  "-of", "json", path]).stdout
    return [(int(p["pos"]), int(p["size"]), "K" in p["flags"], round(float(p["pts_time"]) * FPS))
            for p in json.loads(report)["packets"]]


def damage_picture(path, picture):
    """Overwrite coded picture data and keep the packet's leading header bytes.

    A hardware decoder accepts such a packet and then fails to decode it."""
    position, size, _, _ = next(span for span in packets(path) if span[3] == picture)
    assert size > 64, size
    with open(path, "r+b") as file:
        file.seek(position + 24)
        file.write(bytes((i * 197 + 91) & 255 for i in range(size - 32)))


def movie(path, codec, b_frames):
    """Six seconds with a keyframe every second. Eight luma blocks number each picture."""
    marker = "geq=lum='if(lt(Y,16)*lt(X,128),if(bitand(N,pow(2,floor(X/16))),210,32),lum(X,Y))'"
    gop = f"keyint={FPS}:min-keyint={FPS}:scenecut=0:open-gop=0:bframes={b_frames}:b-adapt=0"
    settings = {
        "h264": ["-c:v", "libx264", "-x264-params", gop, "-threads", "1"],
        "hevc": ["-c:v", "libx265", "-x265-params", gop + ":pools=1:log-level=error", "-tag:v", "hvc1"],
    }
    run([FFMPEG, "-loglevel", "error", "-f", "lavfi", "-i", f"testsrc2=s=320x96:r={FPS}:d=6",
         "-f", "lavfi", "-i", "sine=r=48000:d=6:f=930", "-vf", "noise=alls=12:allf=t," + marker,
         *settings[codec], "-pix_fmt", "yuv420p", "-c:a", "aac", path])


def picture_ids(path):
    """Software decoding conceals damage, so callers compare only intact groups."""
    width, height = 128, 16
    data = run([FFMPEG, "-loglevel", "quiet", "-i", path, "-map", "0:v:0",
                "-vf", f"crop={width}:{height}:0:0,extractplanes=y", "-fps_mode", "passthrough",
                "-pix_fmt", "gray", "-f", "rawvideo", "-"], check=False).stdout
    stride = width * height
    return [sum(1 << bit for bit in range(8) if data[start + 8 * width + bit * 16 + 8] > 120)
            for start in range(0, len(data) - stride + 1, stride)]


P_PICTURE = 41   # A P picture in the group of pictures 25 ..< 50.
KEYFRAME = 50    # The keyframe of the group 50 ..< 75.
OK, DAMAGED = "ok", "damaged"

# (from, to, Smart Trim without B pictures, Smart Trim with B pictures, Re-encode, Re-encode with B pictures)
# Re-encode decodes from a keyframe two seconds before the start. Its helper also reads a few
# pictures past the end, on a schedule that varies between runs. None accepts either safe result.
P_CASES = [
    (35, 100, DAMAGED, DAMAGED, DAMAGED, DAMAGED),  # The leading edge is re-encoded from the damaged group.
    (45, 100, DAMAGED, DAMAGED, DAMAGED, DAMAGED),  # The damage precedes the cut and is a reference for it.
    (10, 115, OK, OK, DAMAGED, DAMAGED),            # Smart Trim copies the damaged group. Re-encode decodes it.
    (60, 115, OK, OK, DAMAGED, DAMAGED),            # A keyframe follows the damage. Re-encode's preroll reaches it.
    (110, 140, OK, OK, OK, OK),                     # Clear of the preroll.
    (0, 12, OK, OK, OK, OK),
    (0, 35, OK, OK, None, None),                    # The trailing edge ends before the damage.
    (0, 41, OK, DAMAGED, None, DAMAGED),            # The damaged picture is the first one after the end.
    (0, 39, OK, DAMAGED, None, DAMAGED),            # With B pictures, 38 is predicted from the damaged 41.
]
KEY_CASES = [
    (60, 115, DAMAGED, DAMAGED, DAMAGED, DAMAGED),
    (10, 115, OK, OK, DAMAGED, DAMAGED),
    (0, 30, OK, OK, OK, OK),
    (85, 140, OK, OK, DAMAGED, DAMAGED),            # Re-encode's preroll starts at picture 25.
    (130, 148, OK, OK, OK, OK),
    # The leading edge ends at the damaged keyframe, which is copied. The H.264 decoder can withhold
    # a reordered picture that was due when it read the damage, and the edge is then refused.
    (35, 115, OK, None, DAMAGED, DAMAGED),
    (10, 50, OK, OK, None, None),                   # The export ends at the damaged keyframe.
]


def luma(path):
    data = run([FFMPEG, "-loglevel", "quiet", "-i", path, "-map", "0:v:0", "-fps_mode", "passthrough",
                "-pix_fmt", "gray", "-f", "rawvideo", "-"], check=False).stdout
    stride = 320 * 96
    return [data[start:start + stride] for start in range(0, len(data) - stride + 1, stride)]


def difference(a, b):
    return sum(abs(x - y) for x, y in zip(a[::7], b[::7])) / len(a[::7])


class DamagedExport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(scratch.cleanup)
        cls.root = Path(scratch.name)
        cls.sources = {}
        for codec, b_frames, container in [("h264", 0, "mp4"), ("h264", 0, "mov"), ("h264", 3, "mp4"),
                                           ("hevc", 0, "mp4"), ("hevc", 0, "mov"), ("hevc", 3, "mp4")]:
            clean = cls.root / f"{codec}-{b_frames}.{container}"
            movie(clean, codec, b_frames)
            spans = packets(clean)
            assert sorted(s[3] for s in spans if s[2]) == list(range(0, 150, FPS)), spans
            assert picture_ids(clean) == list(range(150)), clean
            for name, picture in [("p", P_PICTURE), ("key", KEYFRAME)]:
                damaged = cls.root / f"{codec}-{b_frames}-{name}.{container}"
                shutil.copyfile(clean, damaged)
                damage_picture(damaged, picture)
                cls.sources[codec, b_frames, container, name] = damaged
            cls.sources[codec, b_frames, container, "clean"] = clean

    def export(self, mode, source, start, end):
        output = Path(tempfile.mkdtemp(dir=self.root)) / ("out" + source.suffix)
        result = run([CLI, "export", "--json", "--no-sidecar", "--mode", mode, "--output", output,
                      "--clip", source, "--from", f"{start}/{FPS}", "--to", f"{end}/{FPS}"], check=False)
        return result.returncode, json.loads(result.stdout), output

    def check(self, mode, key, start, end, expected):
        source = self.sources[key]
        label = (mode, source.name, start, end)
        code, report, output = self.export(mode, source, start, end)
        if expected is None:
            # Reading ahead of the end may reach the damage. Either result is safe.
            expected = OK if code == 0 else DAMAGED
        if expected == DAMAGED:
            self.assertEqual((code, report["ok"]), (1, False), label)
            self.assertFalse(output.exists(), label)
            self.assertEqual(list(output.parent.iterdir()), [], label)
            message = report["error"]["message"]
            self.assertEqual(report["error"]["code"], "write_failed" if mode == "smart" else "encode_failed", label)
            self.assertIn("damaged", message, label)
            for noise in ["Unknown error", "Generic error", "0x", "\n"]:
                self.assertNotIn(noise, message, label)
            return
        self.assertEqual((code, report["ok"]), (0, True), (label, report))
        wanted = list(range(start, end))
        # Smart Trim copies whole groups, so a copied group can still hold the damaged packet.
        # Every picture outside that group must be the intact source picture.
        group = range(25, 50) if key[3] == "p" else range(50, 75)
        damaged = P_PICTURE if key[3] == "p" else KEYFRAME
        skipped = group if mode == "smart" and damaged in wanted else range(0)
        self.assertEqual(len(packets(output)), len(wanted), label)
        ids = picture_ids(output)
        self.assertEqual(len(ids), len(wanted), label)
        clean = self.sources[key[:3] + ("clean",)]
        code, report, reference = self.export(mode, clean, start, end)
        self.assertEqual(code, 0, (label, report))
        pictures, intact = luma(output), luma(reference)
        self.assertEqual(len(intact), len(wanted), label)
        for position, picture in enumerate(wanted):
            if picture in skipped:
                continue
            self.assertEqual(ids[position], picture, (label, position))
            self.assertLess(difference(pictures[position], intact[position]), 3, (label, picture))

    def cases(self, mode, column):
        for key in self.sources:
            if key[3] == "clean":
                continue
            table = P_CASES if key[3] == "p" else KEY_CASES
            for case in table:
                with self.subTest(mode=mode, source=self.sources[key].name, start=case[0], end=case[1]):
                    self.check(mode, key, case[0], case[1], case[column + (1 if key[1] else 0)])

    def test_smart_trim_fails_only_when_an_edge_needs_the_damaged_picture(self):
        self.cases("smart", 2)

    def test_reencode_never_writes_pictures_decoded_from_damage(self):
        self.cases("encode", 4)

    def test_damage_at_the_start_of_the_file_is_not_taken_for_a_missing_hardware_decoder(self):
        # A failed hardware decode of the first picture must not select the software decoder.
        for codec in ["h264", "hevc"]:
            for picture in [0, 2]:
                source = self.root / f"{codec}-start-{picture}.mp4"
                shutil.copyfile(self.sources[codec, 0, "mp4", "clean"], source)
                damage_picture(source, picture)
                for mode in ["encode", "smart"]:
                    label = (mode, source.name)
                    code, report, output = self.export(mode, source, 0, 35)
                    if mode == "smart" and code == 0:
                        # The first group is copied whole and later pictures are re-encoded.
                        self.assertEqual(picture_ids(output)[25:], list(range(25, 35)), label)
                        continue
                    self.assertEqual((code, report["ok"]), (1, False), label)
                    self.assertFalse(output.exists(), label)
                    if mode == "encode":
                        # Smart Trim's index can already refuse a first keyframe it cannot verify.
                        self.assertIn("damaged", report["error"]["message"], label)
                code, report, output = self.export("encode", source, 110, 140)
                self.assertEqual((code, report["ok"]), (0, True), (source.name, report))
                self.assertEqual(picture_ids(output), list(range(110, 140)), source.name)

    def test_hardware_decoding_rejects_the_fixtures_and_software_hevc_does_not(self):
        # Re-encode must not fall back to a decoder that reads the damage without an error.
        helper = os.environ.get("MPCUT_FFMPEG_HELPER", FFMPEG)
        for key, source in self.sources.items():
            if key[3] == "clean":
                continue

            def decode(*options):
                return run([helper, "-nostdin", "-loglevel", "error", "-xerror", *options, "-i", source,
                            "-map", "0:v:0", "-f", "null", "-"], check=False)
            hardware = decode("-hwaccel", "videotoolbox")
            self.assertNotEqual(hardware.returncode, 0, source)
            self.assertIn(b"hardware accelerator failed to decode picture", hardware.stderr, source)
            if key[0] == "hevc":
                self.assertEqual(decode().returncode, 0, source)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
