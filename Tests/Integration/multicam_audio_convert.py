#!/usr/bin/env python3
"""Verify multicam soundtrack conversion with real decoded output."""
import argparse
from array import array
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import audio, ffmpeg, probe, run
from multicam import camera

CLI = None
RATE = 48_000


class MulticamAudioConversionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-multicam-convert-")
        cls.addClassCleanup(directory.cleanup)
        cls.root = Path(directory.name)
        cls.angle = camera(cls.root / "angle.mov", marker_base=0, frequency=419, length="3")
        cls.mono = cls.root / "mono.wav"
        cls.stereo = cls.root / "stereo.wav"
        cls.mp3 = cls.root / "other.mp3"
        cls.aac = cls.root / "edited.m4a"
        ffmpeg("-f", "lavfi", "-i", "sine=f=440:r=48000:d=3", cls.mono)
        ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.2*sin(2*PI*500*t)|0.2*sin(2*PI*800*t):s=44100:d=3",
               cls.stereo)
        ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.15*sin(2*PI*(392*t+53*t*t)):s=48000:d=3",
               "-c:a", "libmp3lame", cls.mp3)
        ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.15*sin(2*PI*(310*t+41*t*t)):s=48000:d=3",
               "-c:a", "aac", cls.aac)
        cls.decoder = cls.root / "decode-audio"
        run(["swiftc", "-suppress-warnings", "-parse-as-library", Path(__file__).with_name("DecodeAudio.swift"), "-o", cls.decoder])

    def export(self, second, *, first=None, treatment=None, suffix="mov", mode="encode", succeed=True):
        project = self.root / f"project-{second.stem}.json"
        project.write_text(json.dumps({
            "schemaVersion": 1,
            "kind": "multicam",
            "referenceAngle": "cam",
            "range": {"from": "0", "to": "3"},
            "angles": [{"id": "cam", "file": self.angle.name}],
            "audioSources": [{"id": "first", "file": (first or self.mono).name}, {"id": "second", "file": second.name}],
            "audio": {"mode": "fixed", "source": "first", "stream": 0},
            "switches": [{"at": "0", "angle": "cam"},
                         {"at": "24/25", "angle": "cam", "audio": {"source": "second", "stream": 0}},
                         {"at": "48/25", "angle": "cam"}],
            "assembly": [{"from": "48/25", "to": "3"}, {"from": "0", "to": "48/25"}],
        }))
        output = self.root / f"{second.stem}-{treatment}-{mode}.{suffix}"
        options = ["--audio", treatment] if treatment else []
        result = subprocess.run([CLI, "export", "--project", project, "--mode", mode,
                                 *options, "--output", output, "--json"], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode == 0, succeed, result.stdout + result.stderr)
        self.assertEqual(output.exists(), succeed)
        return output, json.loads(result.stdout)

    def assert_mkv_pcm_clock(self, output, *, samples, rate, channels, seek_ms):
        track = probe(output, "-select_streams", "a:0", "-show_packets", "-show_streams")
        self.assertEqual(track["streams"][0]["time_base"], "1/1000")
        preceding_samples = 0
        pcm_packets = track["packets"]
        for packet in pcm_packets:
            self.assertEqual(int(packet["pts"]) * rate, preceding_samples * 1000)
            preceding_samples += int(packet["size"]) // (4 * channels)
        self.assertEqual(preceding_samples, samples)
        tail = pcm_packets[-1]
        self.assertEqual((int(tail["pts"]) + int(tail["duration"])) * rate, samples * 1000)
        seek = ffmpeg("-ss", f"{seek_ms / 1000:.3f}", "-i", output, "-map", "0:a:0", "-f", "s16le", "-")
        self.assertEqual(seek, audio(output)[seek_ms * rate // 1000 * channels * 2:])
        return pcm_packets

    def test_pcm_preserves_mono_and_handles_mp3_gapless_samples_at_reordered_join(self):
        self.export(self.mp3, mode="copy", succeed=False)
        self.export(self.mp3, succeed=False)
        mono, other = audio(self.mono), audio(self.mp3)
        first_cut = RATE * 24 // 25 * 2
        second_cut = RATE * 48 // 25 * 2
        prefix = mono[second_cut:] + mono[:first_cut]
        expected = prefix + other[first_cut:second_cut]
        self.assertEqual(len(expected), 3 * RATE * 2)
        # Preserve PCM exactly and allow one least-significant bit for MP3 quantization.
        reference = array("h", expected)
        for suffix in ("mov", "mkv"):
            with self.subTest(suffix=suffix):
                result, report = self.export(self.mp3, treatment="pcm", suffix=suffix)
                self.assertEqual(report["audioAction"], "pcm")
                decoded = audio(result)
                self.assertEqual(decoded[:len(prefix)], prefix)
                actual = array("h", decoded)
                self.assertEqual(len(actual), len(reference))
                self.assertLessEqual(max(abs(a - b) for a, b in zip(actual, reference)), 1)
                if suffix == "mkv":
                    pcm_packets = self.assert_mkv_pcm_clock(result, samples=len(reference), rate=RATE,
                                                            channels=1, seek_ms=21)
                    self.assertLess(int(pcm_packets[-1]["size"]), int(pcm_packets[0]["size"]))

    def test_pcm_mkv_keeps_44100_hz_stereo_samples_on_their_clock(self):
        result, _ = self.export(self.stereo, first=self.stereo, treatment="pcm", suffix="mkv")
        original = audio(self.stereo)
        cut = 44_100 * 48 // 25 * 4
        self.assertEqual(audio(result), original[cut:] + original[:cut])
        self.assert_mkv_pcm_clock(result, samples=44_100 * 3, rate=44_100, channels=2, seek_ms=100)

    def test_pcm_renders_aac_presentation_edits(self):
        result, _ = self.export(self.aac, treatment="pcm")
        mono = audio(self.mono)
        other = run([self.decoder, self.aac])
        first_cut = RATE * 24 // 25 * 2
        second_cut = RATE * 48 // 25 * 2
        prefix = mono[second_cut:] + mono[:first_cut]
        actual = run([self.decoder, result])
        self.assertEqual(len(actual), 3 * RATE * 2)
        self.assertEqual(actual[:len(prefix)], prefix)
        reference = array("h", other[first_cut:second_cut])
        decoded = array("h", actual[len(prefix):])
        # The independent reader decodes the original edit from its first packet.
        # Compare its interior to allow decoder warmup around the trimmed boundary.
        self.assertLessEqual(max(abs(a - b) for a, b in zip(decoded[2048:], reference[2048:])), 1)

    def test_pcm_uses_decoded_samples_for_continuous_aac_on_coarse_clock(self):
        coarse = self.root / "coarse.mka"
        ffmpeg("-i", self.aac, "-c:a", "copy", coarse)
        self.assertEqual(probe(coarse, "-show_streams")["streams"][0]["time_base"], "1/1000")
        result, _ = self.export(coarse, treatment="pcm")
        cut = RATE * 24 // 25
        reference = array("h", audio(coarse))[cut:2 * cut]
        decoded = array("h", audio(result))
        self.assertEqual(len(decoded), 3 * RATE)
        self.assertLessEqual(max(abs(a - b) for a, b in zip(decoded[-cut:], reference)), 1)

    def test_aac_resamples_mixed_layouts_with_gapless_duration(self):
        _, rejected = self.export(self.stereo, treatment="aac", suffix="mkv", succeed=False)
        self.assertEqual(rejected["error"]["code"], "unsupported_audio")
        result, report = self.export(self.stereo, treatment="aac", suffix="mp4")
        self.assertEqual(report["audioAction"], "aac")
        self.assertTrue(any("stereo" in warning for warning in report["warnings"]))
        self.assertTrue(any("48 kHz" in warning for warning in report["warnings"]))
        stream = probe(result, "-select_streams", "a:0", "-show_streams")["streams"][0]
        self.assertEqual((stream["codec_name"], int(stream["sample_rate"]), stream["channels"]), ("aac", RATE, 2))
        actual = array("h", run([self.decoder, result]))
        self.assertEqual(len(actual), 3 * RATE * 2)
        # The sources have distinct stereo signatures, so check both sides of the join.
        early = actual[2 * RATE:2 * RATE + 4000]
        late = actual[5 * RATE:5 * RATE + 4000]
        self.assertLess(sum(abs(a - b) for a, b in zip(early[::2], early[1::2])) / 2000, 45)
        self.assertGreater(sum(abs(a - b) for a, b in zip(late[::2], late[1::2])) / 2000, 1000)


if __name__ == "__main__":
    args = argparse.ArgumentParser()
    args.add_argument("mpcut", type=Path)
    options, remaining = args.parse_known_args()
    CLI = options.mpcut.resolve()
    unittest.main(argv=[__file__, *remaining])
