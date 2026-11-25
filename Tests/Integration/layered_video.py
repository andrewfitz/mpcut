#!/usr/bin/env python3
"""Pictures with more than one layer against a built mpcut CLI: MV-HEVC spatial video, HEVC with alpha, and H.264
with auxiliary (alpha) pictures. Each export mode keeps every layer and its signalling, or says what it cannot keep.

Apple's own encoder and reader make and check the HEVC fixtures (LayeredVideo.swift): every frame carries an 8-bit
barcode in each view, inverted in the right view, and again in the alpha of an alpha clip, so a view or an alpha
plane that is lost, duplicated or out of step fails."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import ffmpeg, ratio, run

CLI = None
FRAMES = 120  # 4 s at 30 fps, a keyframe every second.


def h264_auxiliary(destination, root, extension=bytes([0x6d, 0xa9, 0xfe, 0x00, 0x40])):
    """H.264 whose access units each add an auxiliary coded picture (NAL 19) to the primary picture, described by a
    sequence parameter set extension with aux_format_idc 1 (alpha) after each sequence parameter set. The auxiliary
    pictures repeat the primary slices; readers of the primary pictures skip them either way.

    The default extension is seq_parameter_set_id 0, aux_format_idc 1, bit_depth_aux_minus8 0, alpha_incr_flag 0,
    alpha_opaque_value 255, alpha_transparent_value 0, additional_extension_flag 0 and the stop bit."""
    plain = root / f"{destination.stem}-plain.h264"
    ffmpeg("-f", "lavfi", "-i", "testsrc2=s=256x144:r=30:d=4", "-c:v", "libx264", "-profile:v", "high",
           "-pix_fmt", "yuv420p", "-g", "30", "-keyint_min", "30", "-sc_threshold", "0", "-bf", "0",
           "-bsf:v", "h264_mp4toannexb", "-f", "h264", plain)
    data = plain.read_bytes()
    starts, at = [], 0
    while (at := data.find(b"\0\0\1", at)) >= 0:
        at += 3
        starts.append(at)
    out = bytearray()
    for index, start in enumerate(starts):
        nal = data[start:starts[index + 1] - 3 if index + 1 < len(starts) else len(data)].rstrip(b"\0")
        out += b"\0\0\0\1" + nal
        if nal[0] & 31 == 7:
            out += b"\0\0\0\1" + extension
        elif nal[0] & 31 in (1, 5):
            out += b"\0\0\0\1" + bytes([(nal[0] & 0x60) | 19]) + nal[1:]
    annexb = root / f"{destination.stem}.h264"
    annexb.write_bytes(bytes(out))
    ffmpeg("-r", "30", "-f", "h264", "-i", annexb, "-c", "copy", "-tag:v", "avc1", destination)
    return destination


class LayeredVideoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-layers-")
        cls.addClassCleanup(directory.cleanup)
        cls.fixtures = Path(directory.name)
        cls.tool = cls.fixtures / "LayeredVideo"
        run(["swiftc", "-parse-as-library", "-suppress-warnings", Path(__file__).with_name("LayeredVideo.swift"),
             "-o", cls.tool], allow_diagnostics=True, timeout=300)
        cls.stereo = cls.fixtures / "stereo.mov"
        cls.alpha = cls.fixtures / "alpha.mov"
        cls.straight = cls.fixtures / "straight.mov"
        for kind, path in [("make-stereo", cls.stereo), ("make-alpha", cls.alpha), ("make-alpha-straight", cls.straight)]:
            run([cls.tool, kind, path], allow_diagnostics=True, timeout=120)
        cls.auxiliary = h264_auxiliary(cls.fixtures / "auxiliary.mov", cls.fixtures)

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-layers-out-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def inspect(self, path):
        return json.loads(run([self.tool, "inspect", path], allow_diagnostics=True, timeout=120))

    def export(self, *args, ok=True):
        process = subprocess.run([CLI, "export", "clips", "join", "--json", *map(str, args)],
                                 capture_output=True, text=True, timeout=120)
        report = json.loads(process.stdout)
        self.assertEqual(report["ok"], ok, report)
        self.assertEqual(process.returncode == 0, ok, process.stderr)
        return report

    def media(self, path):
        return json.loads(run([CLI, "media", "inspect", "--json", path], allow_diagnostics=True))

    @staticmethod
    def spatial(report):
        return {key: value for key, value in report.items() if key.startswith("stereo_") and key != "stereo_multiview"}

    def assert_views(self, path, first, count):
        report = self.inspect(path)
        self.assertEqual(report["read_status"], "completed", report)
        self.assertTrue(report["stereo_multiview"], report)
        self.assertEqual(report["views_per_frame"], [2])
        self.assertEqual(report["ids"], list(range(first, first + count)))
        self.assertEqual(report["right_ids"], report["ids"])
        self.assertEqual(self.spatial(report), self.spatial(self.inspect(self.stereo)))
        self.assertIn("lhvC", report["sample_entry_boxes"])
        return report

    def assert_alpha(self, path, source, first, count):
        report = self.inspect(path)
        self.assertEqual(report["read_status"], "completed", report)
        self.assertEqual(report["ids"], list(range(first, first + count)))
        self.assertEqual(report["alpha_ids"], report["ids"])
        self.assertEqual(report["translucent_frames"], count)
        self.assertEqual(report["alpha_mode"], self.inspect(source)["alpha_mode"])
        return report

    def test_probe_finds_every_layered_picture_and_mv_hevc_starts_at_its_keyframes(self):
        for source in [self.stereo, self.alpha, self.auxiliary]:
            with self.subTest(source=source.name):
                info = self.media(source)
                self.assertTrue(info["media"]["streams"][0]["has_additional_video_layers"])
                # Matroska cannot describe an HEVC layer. H.264 keeps its extension sets in avcC and in the samples.
                self.assertEqual("mkv" in info["copy"]["containers"], source == self.auxiliary)
        # The second view of each keyframe starts with CRA beside an IDR_N_LP base picture, which has no leading pictures.
        frames = self.media_frames(self.stereo)
        self.assertEqual([ratio(frame["time"]) for frame in frames if frame["can_start"]], [0, 1, 2, 3])

    def media_frames(self, path):
        return json.loads(run([CLI, "media", "inspect", "--json", "--keyframes", path], allow_diagnostics=True))["media"]["frames"]

    def test_copy_keeps_both_views_and_spatial_metadata_in_mov_and_mp4(self):
        for container in ["mov", "mp4"]:
            for name, ranges, first, count in [("whole", [], 0, FRAMES), ("cut", ["--from", "1", "--to", "3"], 30, 60)]:
                with self.subTest(container=container, range=name):
                    output = self.root / f"{name}.{container}"
                    report = self.export("--mode", "copy", "--output", output, "--clip", self.stereo, *ranges)
                    self.assertEqual(report.get("warnings", []), [])
                    self.assert_views(output, first, count)
        # Two ranges of one recording join with both views in step.
        joined = self.root / "joined.mov"
        self.export("--mode", "copy", "--output", joined, "--clip", self.stereo, "--from", "0", "--to", "1",
                    "--clip", self.stereo, "--from", "2", "--to", "3")
        report = self.inspect(joined)
        self.assertEqual(report["ids"], [*range(0, 30), *range(60, 90)])
        self.assertEqual(report["right_ids"], report["ids"])

    def test_copy_keeps_alpha_readable_in_mov_and_mp4(self):
        for source in [self.alpha, self.straight]:
            for container in ["mov", "mp4"]:
                for name, ranges, first, count in [("whole", [], 0, FRAMES), ("cut", ["--from", "1", "--to", "3"], 30, 60)]:
                    with self.subTest(source=source.name, container=container, range=name):
                        output = self.root / f"{source.stem}-{name}.{container}"
                        report = self.export("--mode", "copy", "--output", output, "--clip", source, *ranges)
                        self.assertEqual(report.get("warnings", []), [])
                        # The alpha layer's parameter sets move from hvcC to lhvC, which AVFoundation reads.
                        self.assertIn("lhvC", self.assert_alpha(output, source, first, count)["sample_entry_boxes"])

    def test_matroska_refuses_a_layer_it_cannot_describe(self):
        for source, layer in [(self.stereo, "the second view"), (self.alpha, "the alpha layer")]:
            with self.subTest(source=source.name):
                output = self.root / f"{source.stem}.mkv"
                report = self.export("--mode", "copy", "--output", output, "--clip", source, ok=False)
                self.assertIn(layer, report["error"]["message"])
                self.assertIn("MOV or MP4", report["error"]["message"])
                self.assertFalse(output.exists())

    def test_smart_trim_encodes_edges_with_alpha_and_both_views(self):
        # AVFoundation decodes every layer of an edge and VideoToolbox encodes them again, so the cut is exact.
        for source in [self.stereo, self.alpha, self.straight]:
            for container in ["mov", "mp4"]:
                with self.subTest(source=source.name, container=container):
                    output = self.root / f"{source.stem}-smart.{container}"
                    report = self.export("--mode", "smart", "--output", output, "--clip", source,
                                         "--from", "0.5", "--to", "2.5")
                    self.assertEqual(ratio(report["encoded_duration"]), 1)
                    self.assertEqual(report.get("warnings", []), [])
                    if source == self.stereo:
                        self.assert_views(output, 15, 60)
                    else:
                        self.assert_alpha(output, source, 15, 60)

    def test_smart_trim_cuts_h264_auxiliary_pictures_at_keyframes_and_says_why(self):
        output = self.root / "auxiliary-smart.mov"
        report = self.export("--mode", "smart", "--output", output, "--clip", self.auxiliary,
                             "--from", "0.5", "--to", "2.5", ok=False)
        self.assertEqual(report["error"]["code"], "unsafe_boundary")
        self.assertIn("Smart Trim does not re-encode the edges", report["error"]["message"])
        report = self.export("--mode", "smart", "--snap", "nearest", "--output", output, "--clip", self.auxiliary,
                             "--from", "0.5", "--to", "2.5")
        self.assertEqual(ratio(report["encoded_duration"]), 0)
        self.assertTrue(any("Smart Trim does not re-encode the edges" in warning for warning in report["warnings"]),
                        report)

    def test_reencode_refuses_to_drop_a_layer(self):
        for source, words in [(self.stereo, "HEVC layers"), (self.alpha, "HEVC layers"),
                              (self.auxiliary, "auxiliary (alpha), MVC or SVC")]:
            with self.subTest(source=source.name):
                output = self.root / f"{source.stem}-encoded.mov"
                report = self.export("--mode", "encode", "--output", output, "--clip", source,
                                     "--from", "1", "--to", "2", ok=False)
                self.assertIn(words, report["error"]["message"])
                self.assertFalse(output.exists())

    def test_sets_the_copy_cannot_follow_are_named(self):
        # A sequence parameter set extension whose ID (40) is out of range cannot be keyed as a decoder keys it.
        source = h264_auxiliary(self.root / "unreadable.mov", self.root, extension=bytes([0x6d, 0x05, 0x30]))
        output = self.root / "unreadable-cut.mov"
        report = self.export("--mode", "copy", "--output", output, "--clip", source, "--from", "1", "--to", "3")
        self.assertTrue(any("cannot follow the parameter sets" in warning for warning in report.get("warnings", [])),
                        report)
        # The sets of every layer of a well-formed stream are followed, so its copy says nothing.
        report = self.export("--mode", "copy", "--output", self.root / "auxiliary-cut.mov", "--clip", self.auxiliary,
                             "--from", "1", "--to", "3")
        self.assertEqual(report.get("warnings", []), [])

    def test_h264_auxiliary_pictures_survive_copy(self):
        output = self.root / "auxiliary.mov"
        self.export("--mode", "copy", "--output", output, "--clip", self.auxiliary, "--from", "1", "--to", "3")
        report = json.loads(run(["ffprobe", "-v", "error", "-of", "json", "-select_streams", "v:0", "-show_packets",
                                 "-show_data", output]))
        # Every copied access unit still carries its auxiliary picture.
        for packet in report["packets"]:
            data = bytes.fromhex("".join(line.split(":", 1)[1][:40].replace(" ", "")
                                         for line in packet["data"].splitlines() if ":" in line))
            types, at = [], 0
            while at + 4 <= len(data):
                size = int.from_bytes(data[at:at + 4], "big")
                types.append(data[at + 4] & 31)
                at += 4 + size
            self.assertIn(19, types)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = str(args.mpcut.resolve(strict=True))
    unittest.main(argv=[__file__, *tests])
