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
        project = self.root / f"project-{second.stem}.cut"
        project.write_text(json.dumps({
            "format": "mpcut",
            "schema_version": 3,
            "kind": "multicam",
            "reference_angle_id": "cam",
            "group_range": {"from": "0", "to": "3"},
            "angles": [{"id": "cam", "file": self.angle.name}],
            "audio_sources": [{"id": "first", "file": (first or self.mono).name}, {"id": "second", "file": second.name}],
            "audio": {"mode": "fixed", "source_id": "first", "audio_stream_index": 0},
            "switches": [{"group_time": "0", "angle_id": "cam"},
                         {"group_time": "24/25", "angle_id": "cam", "audio": {"source_id": "second", "audio_stream_index": 0}},
                         {"group_time": "48/25", "angle_id": "cam"}],
            "assembly": [{"from": "48/25", "to": "3"}, {"from": "0", "to": "48/25"}],
        }))
        output = self.root / f"{second.stem}-{treatment}-{mode}.{suffix}"
        options = ["--audio", treatment] if treatment else []
        result = subprocess.run([CLI, "export", "project", "render", "--project", project, "--mode", mode,
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

    def test_reordered_pcm_wav_uses_exact_samples_after_a_seek(self):
        source = self.root / "seek-noise.wav"
        ffmpeg("-f", "lavfi", "-i", "anoisesrc=sample_rate=44100:duration=3:seed=7",
               "-c:a", "pcm_s16le", source)
        output, _ = self.export(source, first=source, treatment="pcm")
        decoded = audio(source)
        cut = 48 * 44100 // 25 * 2
        self.assertEqual(audio(output), decoded[cut:] + decoded[:cut])

    def test_pcm_lane_keeps_lossy_peaks_and_double_float_and_reports_its_format(self):
        def peak(path):
            decoded = array("f", ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "pcm_f32le", "-f", "f32le", "-"))
            return max(abs(value) for value in decoded)

        # A full-scale square wave at a low rate decodes well above full scale.
        hot = self.root / "hot.m4a"
        ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.999*sgn(sin(2*PI*997*t))|0.999*sgn(sin(2*PI*1499*t)):s=48000:d=3",
               "-c:a", "aac", "-b:a", "64k", hot)
        self.assertGreater(peak(hot), 1.2)
        for suffix in ("mov", "mkv"):
            with self.subTest(source="lossy", suffix=suffix):
                output, report = self.export(hot, first=hot, treatment="pcm", suffix=suffix)
                lane, = report["audio_lanes"]
                self.assertEqual((lane["action"], lane["codec"], lane["bit_depth"]), ("pcm", "pcm_f32le", 32))
                self.assertEqual(probe(output, "-select_streams", "a:0", "-show_streams")["streams"][0]["codec_name"], "pcm_f32le")
                self.assertAlmostEqual(peak(output), peak(hot), delta=0.05)
        # A rendered AAC lane reports the rate it is encoded at.
        output, report = self.export(hot, first=hot, treatment="aac")
        lane, = report["audio_lanes"]
        self.assertEqual((lane["action"], lane["codec"], lane["bit_rate"]), ("aac", "aac", 192000))
        written = int(probe(output, "-select_streams", "a:0", "-show_streams")["streams"][0]["bit_rate"])
        self.assertLess(abs(written - 192000), 192000 // 10)

        # 64-bit float sound stays 64-bit float, sample for sample.
        double = self.root / "double.wav"
        ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.3*sin(2*PI*441*t)+0.000000001*sin(2*PI*7919*t)|0.2*sin(2*PI*659*t):s=48000:d=3",
               "-c:a", "pcm_f64le", double)

        def doubles(path):
            return ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "pcm_f64le", "-f", "f64le", "-")

        expected = doubles(double)
        cut = 48 * RATE // 25 * 2 * 8
        for suffix in ("mov", "mkv"):
            with self.subTest(source="double", suffix=suffix):
                output, report = self.export(double, first=double, treatment="pcm", suffix=suffix)
                lane, = report["audio_lanes"]
                self.assertEqual((lane["codec"], lane["bit_depth"], lane["warnings"]), ("pcm_f64le", 64, []))
                self.assertEqual(doubles(output), expected[cut:] + expected[:cut])

    def test_auto_keeps_the_single_compressed_format_of_a_rendered_lane(self):
        noise = ["-f", "lavfi", "-i", "anoisesrc=d=3:c=pink:r=48000:a=0.4:seed=3", "-ac", "2"]
        alac = self.root / "lane-alac.m4a"
        mp3 = self.root / "lane-mp3.mp3"
        opus = self.root / "lane-opus.mka"
        ffmpeg(*noise, "-c:a", "alac", "-sample_fmt", "s16p", alac)
        ffmpeg(*noise, "-c:a", "libmp3lame", "-b:a", "192k", mp3)
        ffmpeg(*noise, "-c:a", "libopus", "-b:a", "96k", opus)

        def integers(path):
            return ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "s32le", "-")

        # The reordered assembly needs a render. Auto keeps the lane's own codec where the container carries it,
        # and otherwise renders the container's codec as before.
        for source, suffix, codec, reason in [
            (alac, "mov", "alac", "The ALAC source is written as ALAC at its own word length"),
            (alac, "mp4", "alac", "The ALAC source is written as ALAC at its own word length"),
            (alac, "mkv", "pcm_s32le", None),
            (mp3, "mov", "mp3", "The MP3 source is written as MP3 at its own rate."),
            # MP3 in Matroska does not keep the planned sample range, so that lane renders PCM as before.
            (mp3, "mkv", "pcm_f32le", None),
            (opus, "mkv", "opus", "The Opus source is written as Opus at its own rate."),
            (opus, "mov", "pcm_f32le", None),
        ]:
            with self.subTest(source=source.name, suffix=suffix):
                output, report = self.export(source, first=source, treatment="auto", suffix=suffix)
                lane, = report["audio_lanes"]
                self.assertEqual(lane["codec"], codec)
                if reason:
                    self.assertIn(reason, lane.get("reason") or "", lane)
                else:
                    self.assertIsNone(lane.get("reason"), lane)
                written = probe(output, "-select_streams", "a:0", "-show_streams")["streams"][0]
                self.assertEqual(written["codec_name"], codec)
                if codec == "alac":
                    self.assertEqual(lane["bit_depth"], 16)
                    decoded = integers(source)
                    cut = 48 * RATE // 25 * 2 * 4
                    self.assertEqual(integers(output), decoded[cut:] + decoded[:cut])
                elif codec == "mp3":
                    self.assertEqual(lane["bit_rate"], 192000)

    def test_shared_compressed_decode_matches_individual_reordered_ranges(self):
        coarse = self.root / "shared-aac.mka"
        ffmpeg("-i", self.aac, "-c:a", "copy", coarse)
        for source in [self.mp3, coarse, self.aac]:
            with self.subTest(source=source.name):
                # Distinct paths force independent decoders in the reference program.
                duplicate = self.root / ("duplicate-" + source.name)
                duplicate.write_bytes(source.read_bytes())
                def render(other, label):
                    project = self.root / ("shared-" + label + ".cut")
                    project.write_text(json.dumps({
                        "format": "mpcut", "schema_version": 3, "kind": "multicam", "reference_angle_id": "cam",
                        "group_range": {"from": "0", "to": "3"},
                        "angles": [{"id": "cam", "file": self.angle.name}],
                        "audio_sources": [{"id": "a", "file": source.name}, {"id": "b", "file": other.name}],
                        "audio": {"mode": "fixed", "source_id": "a", "audio_stream_index": 0},
                        "switches": [{"group_time": "0", "angle_id": "cam"}, {"group_time": "48/25", "angle_id": "cam",
                                     "audio": {"source_id": "b", "audio_stream_index": 0}}],
                        "assembly": [{"from": "48/25", "to": "72/25"}, {"from": "6/25", "to": "18/25"}] * 2,
                    }))
                    output = self.root / (source.name + "-" + label + ".mov")
                    run([CLI, "export", "project", "render", "--project", project, "--mode", "encode", "--audio", "pcm",
                         "--output", output, "--json"], allow_diagnostics=True)
                    return ffmpeg("-i", output, "-map", "0:a:0", "-c:a", "copy", "-f", "data", "-")
                reference = render(duplicate, "independent")
                self.assertEqual(len(reference), RATE * 72 // 25 * 4)
                self.assertEqual(render(source, "shared"), reference)

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
                lane, = report["audio_lanes"]
                self.assertEqual(lane["action"], "pcm")
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
        lane, = report["audio_lanes"]
        self.assertEqual(lane["action"], "aac")
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
