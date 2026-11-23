#!/usr/bin/env python3
"""Exercise multicam sync suggestions with real recording metadata and shifted audio."""
import argparse
from array import array
from fractions import Fraction
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest
import wave

from media_regression import ffmpeg


def rational(value):
    return Fraction(value["numerator"], value["denominator"])


class MulticamSyncTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-sync-")
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.project = self.directory / "sync.cut"

    def camera(self, name, timecode=None, audio=None):
        path = self.directory / name
        audio_options = ["-i", audio, "-map", "0:v", "-map", "1:a", "-c:a", "pcm_s16le", "-shortest"] if audio else []
        timecode_options = ["-timecode", timecode] if timecode else []
        ffmpeg("-f", "lavfi", "-i", "color=black:s=32x32:r=25:d=70",
               *audio_options, "-c:v", "libx264", "-threads", "1", "-preset", "ultrafast", *timecode_options, path)
        return path.name

    def write_project(self, reference, target, recorder=None):
        sources = [{"id": "recorder", "file": recorder, "offset": "0"}] if recorder else []
        self.project.write_text(json.dumps({
            "format": "mpcut", "schema_version": 3, "kind": "multicam",
            "reference_angle_id": "wide", "group_range": {"from": "0", "to": "6"},
            "angles": [{"id": "wide", "file": reference, "offset": "1"},
                       {"id": "close", "file": target, "offset": "0"}],
            "audio_sources": sources,
            "audio": {"mode": "none"},
            "switches": [{"group_time": "0", "angle_id": "wide"}],
        }))

    def suggest(self, *options):
        before = self.project.read_bytes()
        result = subprocess.run([CLI, "multicam", "sync", "suggest", "--project", str(self.project),
                                 "--json", *options], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.project.read_bytes(), before)
        return json.loads(result.stdout)

    def test_timecode_when_preview_probe_cannot_establish_mpeg4_clock(self):
        source = self.directory / "mpeg4.mov"
        ffmpeg("-f", "lavfi", "-i", "color=black:s=32x32:r=25:d=2",
               "-c:v", "mpeg4", "-timecode", "00:00:02:01", source)
        self.write_project(source.name, source.name)
        report = self.suggest("--metadata-only")
        self.assertEqual(rational(report["reference_stamp"]["start"]), Fraction(51, 25))
        self.assertEqual(rational(report["suggestions"][0]["metadata_offset"]), 1)

    def test_timecode_zero_and_missing_stamp(self):
        reference = self.camera("wide.mov", "00:00:00:00")
        target = self.camera("close.mov", "00:00:02:01")
        # Broadcast Wave time-reference zero is also present.
        recorder = self.directory / "recorder.wav"
        ffmpeg("-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono:d=1", "-write_bext", "1", recorder)
        self.write_project(reference, target, recorder.name)
        report = self.suggest("--metadata-only")
        self.assertEqual(rational(report["reference_stamp"]["start"]), 0)
        close, recorder_suggestion = report["suggestions"]
        self.assertEqual(rational(close["metadata_offset"]), Fraction(76, 25))
        self.assertEqual(recorder_suggestion["stamp"], {"kind": "broadcast_wave", "start": {"numerator": 0, "denominator": 1}})
        self.assertEqual(rational(recorder_suggestion["metadata_offset"]), 1)
        self.assertIn("same time-of-day", recorder_suggestion["metadata_issue"])
        target = self.camera("missing.mov")
        self.write_project(reference, target)
        close = self.suggest("--metadata-only", "--source-id", "close")["suggestions"][0]
        self.assertNotIn("stamp", close)
        self.assertNotIn("metadata_offset", close)
        self.assertIn("metadata_issue", close)

    def test_shifted_waveform_and_late_agreement(self):
        randomizer = random.Random(36)
        levels = [randomizer.randrange(1000, 26000) for _ in range(3450)]
        for name, samples in [("wide.wav", levels), ("close.wav", levels[110:])]:
            with wave.open(str(self.directory / name), "wb") as stream:
                stream.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
                stream.writeframes(array("h", (value for level in samples for value in (level, -level) * 80)).tobytes())
        reference = self.camera("wide.mov", audio=self.directory / "wide.wav")
        target = self.camera("close.mov", audio=self.directory / "close.wav")
        self.write_project(reference, target)
        close = self.suggest()["suggestions"][0]
        self.assertEqual(rational(close["waveform_offset"]), Fraction(16, 5))
        self.assertEqual(rational(close["drift"]), 0)
        self.assertGreaterEqual(len(close["matches"]), 2)

    def test_timecode_uses_movie_clock_with_delayed_picture(self):
        reference = self.camera("wide.mov", "00:00:00:00")
        target = self.directory / "close.mov"
        ffmpeg("-itsoffset", "0.4", "-f", "lavfi", "-i", "color=black:s=32x32:r=25:d=2",
               "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono:d=2.4",
               "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-threads", "1", "-preset", "ultrafast", "-c:a", "pcm_s16le",
               "-timecode", "00:00:02:01", target)
        self.write_project(reference, target.name)
        close = self.suggest("--metadata-only")["suggestions"][0]
        self.assertEqual(rational(close["stamp"]["start"]), Fraction(41, 25))
        self.assertEqual(rational(close["metadata_offset"]), Fraction(66, 25))

    def test_waveform_can_use_a_later_recording_on_reference_camera(self):
        randomizer = random.Random(58)
        levels = [randomizer.randrange(1000, 26000) for _ in range(400)]
        for name, samples in [("restart.wav", levels), ("target.wav", levels[100:])]:
            with wave.open(str(self.directory / name), "wb") as stream:
                stream.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
                stream.writeframes(array("h", (value for level in samples for value in (level, -level) * 80)).tobytes())
        reference = self.camera("wide.mov")
        restart = self.camera("restart.mov", audio=self.directory / "restart.wav")
        target = self.camera("close.mov", audio=self.directory / "target.wav")
        self.write_project(reference, target)
        project = json.loads(self.project.read_text())
        project["group_range"]["to"] = "80"
        project["angles"][0].update({
            "group_coverage": {"from": "1", "to": "71"},
            "additional_recordings": [{"id": "restart", "file": restart, "offset": "72",
                                       "group_coverage": {"from": "72", "to": "80"}}]
        })
        project["angles"][1]["offset"] = "73"
        self.project.write_text(json.dumps(project))
        default = self.suggest("--source-id", "close")
        self.assertEqual(default["reference_source_id"], "wide")
        self.assertNotIn("waveform_offset", default["suggestions"][0])
        report = self.suggest("--source-id", "close", "--reference-source-id", "restart")
        self.assertEqual(report["reference_source_id"], "restart")
        self.assertEqual(rational(report["suggestions"][0]["waveform_offset"]), 74)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mpcut", type=Path)
    args = parser.parse_args()
    CLI = str(args.mpcut.resolve())
    unittest.main(argv=sys.argv[:1])
