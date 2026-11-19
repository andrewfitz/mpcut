#!/usr/bin/env python3
"""Packet-writer regressions against a built mpcut executable."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import audio, ffmpeg, frames, probe, ratio, sample_hashes

CLI = None


class WriterRegression(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-writer-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def export(self, source, destination, *range_args, dry_run=False, ok=True):
        args = [CLI, "export", "--json", "--output", destination, "--clip", source, *range_args]
        if dry_run:
            args.append("--dry-run")
        process = subprocess.run(args, capture_output=True, text=True, timeout=30)
        self.assertEqual(process.returncode == 0, ok, process.stderr + process.stdout)
        report = json.loads(process.stdout)
        self.assertIs(report["ok"], ok, report)
        return report

    def test_audible_lead_and_tail_survive_whole_mov_copy(self):
        for codec in ["pcm_s16le", "aac"]:
            with self.subTest(codec=codec):
                source = self.root / f"{codec}.mov"
                output = self.root / f"{codec}-copy.mov"
                ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=1",
                       "-f", "lavfi", "-i", "sine=d=1.3:r=48000",
                       "-vf", "setpts=PTS+5", "-fps_mode", "passthrough",
                       "-c:v", "prores_ks", "-c:a", codec, source)
                report = self.export(source, output, dry_run=True)
                segment = report["segments"][0]
                video, linked_audio = segment["tracks"]
                self.assertEqual(ratio(segment["outputStart"]), Fraction(1, 5))
                self.assertEqual(ratio(video["outputStart"]), Fraction(1, 5))
                self.assertEqual(ratio(video["outputEnd"]), Fraction(6, 5))
                self.assertEqual(ratio(linked_audio["sourceStart"]), Fraction(-1, 5))
                self.assertEqual(ratio(linked_audio["sourceEnd"]), Fraction(11, 10))
                self.assertEqual(ratio(linked_audio["outputStart"]), 0)
                self.assertEqual(ratio(linked_audio["outputEnd"]), Fraction(13, 10))
                self.export(source, output)
                self.assertEqual(frames(output), frames(source))
                self.assertEqual(audio(output), audio(source))
                for selector in ["v:0", "a:0"]:
                    self.assertEqual(sample_hashes(output, selector), sample_hashes(source, selector))
                starts = [tuple(Fraction(track["start_time"]) for track in probe(path, "-show_streams")["streams"])
                          for path in (source, output)]
                self.assertEqual(starts, [(Fraction(1, 5), 0)] * 2)

    def test_leading_audio_with_timecode_cannot_cut_off_timecode_tail(self):
        source = self.root / "delayed-tc.mov"
        output = self.root / "delayed-tc-copy.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=1",
               "-f", "lavfi", "-i", "sine=d=1.3:r=48000",
               "-vf", "setpts=PTS+5", "-fps_mode", "passthrough",
               "-c:v", "prores_ks", "-c:a", "pcm_s16le", "-timecode", "01:23:45:00", source)
        for dry_run in [True, False]:
            result = self.export(source, output, dry_run=dry_run, ok=False)
            self.assertIn("timecode", result["error"]["message"].lower())
            self.assertFalse(output.exists())

        self.export(source, output, "--to", "0.8")
        self.assertEqual(frames(output), frames(source)[:20])
        timecode = probe(output, "-select_streams", "d:0", "-show_streams")["streams"][0]
        self.assertEqual(timecode["tags"]["timecode"], "01:23:45:05")

    def test_vp9_alpha_requires_a_muxer_that_carries_it(self):
        source = self.root / "alpha.webm"
        output = self.root / "alpha-copy.webm"
        rejected = self.root / "alpha-lost.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=1",
               "-vf", "format=yuva420p,colorchannelmixer=aa=0.5", "-pix_fmt", "yuva420p",
               "-c:v", "libvpx-vp9", "-deadline", "realtime", "-auto-alt-ref", "0", source)
        self.export(source, output)

        def decoded_alpha(path):
            return ffmpeg("-c:v", "libvpx-vp9", "-i", path, "-vf", "alphaextract",
                          "-f", "rawvideo", "-pix_fmt", "gray", "-")

        reference = decoded_alpha(source)
        self.assertEqual(len(reference), 160 * 96 * 25)
        self.assertEqual(decoded_alpha(output), reference)
        report = self.export(source, rejected, dry_run=True, ok=False)
        self.assertIn("alpha", report["error"]["message"].lower())
        self.assertFalse(rejected.exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
