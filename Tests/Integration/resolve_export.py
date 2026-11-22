#!/usr/bin/env python3
"""Verify Resolve interchange with real media without opening a Resolve project."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET

from media_regression import ffmpeg, run


class ResolveExportTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.camera = self.folder / "Camera & mic.mov"
        ffmpeg("-f", "lavfi", "-i", "color=s=160x90:r=24:d=3", "-f", "lavfi", "-i",
               "sine=frequency=440:d=3", "-f", "lavfi", "-i", "sine=frequency=880:d=3",
               "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "prores_ks",
               "-c:a", "pcm_s16le", "-timecode", "01:00:00:00", self.camera)

    def check_source_start(self, source, expected):
        output = self.folder / (source.stem + ".fcpxml")
        request = dict(output=str(output), file=str(source), clips=[{"from": "0", "to": "0.5"}])
        result = subprocess.run([CLI, "resolve", "--stdin", "--no-sidecar", "--json"],
                                input=json.dumps(request), text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(json.loads(result.stdout)["ok"])
        tree = ET.parse(output)
        for path in (".//asset", ".//spine/asset-clip"):
            self.assertEqual(Fraction(tree.find(path).get("start")[:-1]), expected)

    def test_program_stream_without_timecode(self):
        source = self.folder / "program.mpg"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x90:r=25:d=1", "-c:v", "mpeg2video", "-f", "mpeg", source)
        self.check_source_start(source, 0)

    def test_drop_frame_source_timecode(self):
        source = self.folder / "drop.mov"
        ffmpeg("-f", "lavfi", "-i", "color=s=160x90:r=30000/1001:d=1", "-c:v", "libx264",
               "-timecode", "01:00:00;00", source)
        self.check_source_start(source, 107892 * Fraction(1001, 30000))

    def test_broadcast_wave_sample_reference(self):
        source = self.folder / "recorder.wav"
        ffmpeg("-f", "lavfi", "-i", "sine=sample_rate=48000:duration=1", "-write_bext", "1",
               "-metadata", "time_reference=172800001", source)
        self.check_source_start(source, Fraction(172800001, 48000))

    def test_native_switches_in_assembly_order(self):
        project = dict(format="mpcut", schemaVersion=1, kind="multicam", referenceAngle="a",
                       range={"from": "0", "to": "3"},
                       angles=[dict(id="a", name="Wide", file=self.camera.name),
                               dict(id="b", name="Close", file=self.camera.name, offset="-1")],
                       audio={"mode": "none"},
                       switches=[dict(at="0", angle="a"),
                                 dict(at="1", angle="b", audio=dict(source="a", stream=2))],
                       assembly=[{"from": "1", "to": "2"}, {"from": "0", "to": "1"},
                                 {"from": "1", "to": "2"}])
        output = self.folder / "Edit.fcpxml"
        run([CLI, "resolve", "--project", "-", "--output", output, "--no-sidecar"],
            input=json.dumps(project).encode(), cwd=self.folder)
        tree = ET.parse(output)
        self.assertEqual(tree.find(".//asset").get("start"), "3600s")
        angles = {angle.get("angleID"): angle.get("name") for angle in tree.findall(".//mc-angle")}
        clips = tree.findall(".//spine/mc-clip")
        self.assertEqual([c.get("start") for c in clips], ["2s", "1s", "2s"])
        self.assertEqual([c.get("offset") for c in clips], ["0s", "1s", "2s"])
        self.assertEqual([angles[c.find("mc-source").get("angleID")] for c in clips], ["Close", "Wide", "Close"])
        self.assertEqual([len(c.findall("mc-source")) for c in clips], [2, 1, 2])
        self.assertEqual(angles[clips[0].find("mc-source[@srcEnable='audio']").get("angleID")], "Wide · stream 2")
        files = [Path(unquote(urlparse(rep.get("src")).path)) for rep in tree.findall(".//media-rep")]
        wav, = [file for file in files if file.suffix == ".wav"]
        self.assertEqual(ffmpeg("-i", wav, "-f", "s16le", "-"),
                         ffmpeg("-i", self.camera, "-map", "0:2", "-f", "s16le", "-"))

    def test_selected_embedded_audio_extends_beyond_its_camera_picture(self):
        short_camera = self.folder / "short picture.mov"
        ffmpeg("-f", "lavfi", "-i", "color=s=160x90:r=24:d=1", "-f", "lavfi", "-i",
               "sine=frequency=440:d=3", "-map", "0:v", "-map", "1:a", "-c:v", "prores_ks",
               "-c:a", "pcm_s16le", short_camera)
        project = dict(format="mpcut", schemaVersion=1, kind="multicam", referenceAngle="a",
                       range={"from": "0", "to": "3"},
                       angles=[dict(id="a", file=self.camera.name), dict(id="b", file=short_camera.name)],
                       audio=dict(mode="fixed", source="b", stream=1),
                       switches=[dict(at="0", angle="a")])
        output = self.folder / "long mic.fcpxml"
        run([CLI, "resolve", "--project", "-", "--output", output, "--no-sidecar"],
            input=json.dumps(project).encode(), cwd=self.folder)
        tree = ET.parse(output)
        selected = tree.find(".//mc-source[@srcEnable='audio']").get("angleID")
        angle = tree.find(f".//mc-angle[@angleID='{selected}']/asset-clip")
        asset = tree.find(f".//asset[@id='{angle.get('ref')}']")
        for element in (angle, asset):
            self.assertEqual(Fraction(element.get("duration")[:-1]), 3)

    def test_cumulative_frame_positions_and_tracks(self):
        output = self.folder / "Ordinary.fcpxml"
        request = dict(output=str(output), file=str(self.camera), clips=[{"from": "1", "to": "1.06"}], order=[1] * 8)
        run([CLI, "resolve", "--stdin", "--no-sidecar"], input=json.dumps(request).encode())
        sequence = ET.parse(output).find(".//sequence")
        cursor = Fraction(0)
        clips = sequence.findall("spine/clip")
        self.assertEqual(len(clips), 8)
        for clip in clips:
            self.assertEqual(Fraction(clip.get("offset")[:-1]), cursor)
            cursor += Fraction(clip.get("duration")[:-1])
            self.assertEqual(clip.find("video").get("start"), "3601s")
            self.assertEqual([audio.get("lane") for audio in clip.findall("audio")], ["-2", "-1"])
        self.assertEqual(cursor, Fraction(12, 24))
        self.assertEqual(cursor, Fraction(sequence.get("duration")[:-1]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    binary = parser.add_mutually_exclusive_group(required=True)
    binary.add_argument("mpcut", type=Path, nargs="?")
    binary.add_argument("--cli", type=Path)
    args = parser.parse_args()
    CLI = (args.cli or args.mpcut).resolve()
    unittest.main(argv=[__file__])
