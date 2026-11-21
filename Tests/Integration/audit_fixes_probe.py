#!/usr/bin/env python3
"""Verify that analysis survives one damaged packet and still rejects an undecodable file."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"


def run(args, check=True):
    return subprocess.run(args, check=check, capture_output=True, timeout=120)


def packets(path, stream):
    report = run([FFPROBE, "-loglevel", "error", "-select_streams", stream, "-show_packets",
                  "-of", "json", path]).stdout
    return [(int(p["pos"]), int(p["size"])) for p in json.loads(report)["packets"]]


def damage(path, spans):
    with open(path, "r+b") as file:
        for position, size in spans:
            file.seek(position)
            file.write(bytes((i * 197 + 91) & 255 for i in range(size)))


class DamagedPackets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(scratch.cleanup)
        cls.root = Path(scratch.name)
        # Sound, a pause, then sound. The damaged packet lies in the first tone.
        cls.audio = cls.root / "damaged.m4a"
        run([FFMPEG, "-loglevel", "error", "-f", "lavfi", "-i",
             "aevalsrc='if(between(t,3,4),0,sin(440*2*PI*t)*0.35)':s=48000:d=6",
             "-c:a", "aac", "-b:a", "96k", cls.audio])
        spans = packets(cls.audio, "a:0")
        cls.audio_packets = len(spans)
        damage(cls.audio, [spans[len(spans) // 6]])
        # A cut at three seconds, with the damaged picture a second earlier.
        cls.video = cls.root / "damaged.mp4"
        run([FFMPEG, "-loglevel", "error", "-f", "lavfi", "-i",
             "color=red:s=320x240:r=25:d=3[a];color=blue:s=320x240:r=25:d=3[b];[a][b]concat=n=2:v=1:a=0",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "25", "-bf", "0", cls.video])
        spans = packets(cls.video, "v:0")
        damage(cls.video, [spans[len(spans) // 3]])

    def mpcut(self, *args):
        result = run([CLI, *args], check=False)
        return result.returncode, json.loads(result.stdout)

    def test_fixtures_contain_a_packet_ffmpeg_rejects(self):
        for path in [self.audio, self.video]:
            result = run([FFMPEG, "-loglevel", "error", "-xerror", "-err_detect", "explode",
                          "-i", path, "-f", "null", "-"], check=False)
            self.assertNotEqual(result.returncode, 0, path)

    def test_waveform_reads_around_a_damaged_audio_packet(self):
        code, report = self.mpcut("waveform", "--json", "--no-sidecar", "--columns", "60", self.audio)
        self.assertEqual(code, 0, report)
        self.assertTrue(report["ok"])
        high = report["envelope"]["high"]
        self.assertEqual(len(high), 60)
        # Columns are 100 ms. Tone on both sides of the damage and after the pause.
        for column in [2, 8, 15, 25, 45, 55]:
            self.assertGreater(high[column], 0.25, column)
        self.assertLess(max(high[32:38]), 0.01)
        # A window that opens with a seek also decodes through the damage.
        code, window = self.mpcut("waveform", "--json", "--no-sidecar", "--from", "0.5", "--to", "5.5",
                                  "--columns", "50", self.audio)
        self.assertEqual(code, 0, window)
        self.assertGreater(window["envelope"]["high"][45], 0.25)

    def test_silence_reads_around_a_damaged_audio_packet(self):
        code, report = self.mpcut("silence", "--json", "--no-sidecar", "--min-pause", "0.5", self.audio)
        self.assertEqual(code, 0, report)
        # The unobserved packet is far shorter than a pause and must not become one.
        pauses = [(p["from"]["numerator"] / p["from"]["denominator"],
                   p["to"]["numerator"] / p["to"]["denominator"]) for p in report["pauses"]]
        self.assertEqual(len(pauses), 1, pauses)
        self.assertAlmostEqual(pauses[0][0], 3, delta=0.05)
        self.assertAlmostEqual(pauses[0][1], 4, delta=0.05)

    def test_scenes_read_around_a_damaged_picture(self):
        code, report = self.mpcut("scenes", "--json", "--no-sidecar", self.video)
        self.assertEqual(code, 0, report)
        starts = [s["startSeconds"] for s in report["scenes"]]
        self.assertEqual(starts[0], 0)
        self.assertIn(3, starts)

    def test_undecodable_streams_still_fail(self):
        audio = self.root / "garbage.m4a"
        audio.write_bytes(self.audio.read_bytes())
        damage(audio, packets(audio, "a:0"))
        for command in [["waveform", "--columns", "60"], ["silence"]]:
            code, report = self.mpcut(*command, "--json", "--no-sidecar", audio)
            self.assertEqual((code, report["ok"], report["error"]["code"]),
                             (1, False, "audio_analysis_failed"), command)
        video = self.root / "garbage.mp4"
        video.write_bytes(self.video.read_bytes())
        damage(video, packets(video, "v:0"))
        code, report = self.mpcut("scenes", "--json", "--no-sidecar", video)
        self.assertEqual((code, report["ok"], report["error"]["code"]), (1, False, "scene_analysis_failed"))
        noise = self.root / "noise.m4a"
        noise.write_bytes(bytes((i * 131 + 17) & 255 for i in range(65536)))
        for command in ["waveform", "silence", "scenes"]:
            result = run([CLI, command, "--json", "--no-sidecar", noise], check=False)
            self.assertEqual(result.returncode, 1, command)
            self.assertFalse(json.loads(result.stdout)["ok"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
