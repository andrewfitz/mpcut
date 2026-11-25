#!/usr/bin/env python3
"""Mixed timelines: clips with different codecs, pictures, timing and sound, written by Re-encode on one canvas.

Usage: mixed_timeline.py /path/to/mpcut
"""
import argparse
from array import array
from fractions import Fraction
import json
from math import cos, pi, sin, sqrt
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile
import time
import unittest

from media_regression import ffmpeg, probe, run, sample_hashes
from saved_project import read_project

CLI = None
CANVAS = (320, 180)
TONE_START = Fraction(1, 2)


def tone(frequency, rate, layout="stereo", seconds=2):
    """A tone that starts half a second into the clip, so each join can be timed."""
    channels = {"mono": 1, "stereo": 2, "5.1": 6}[layout]
    expression = "|".join([f"gte(t\\,{float(TONE_START)})*0.5*sin(2*PI*{frequency}*t)"] * channels)
    return ["-f", "lavfi", "-i", f"aevalsrc='{expression}':s={rate}:d={seconds}:c={layout}"]


def picture(size, rate, source="testsrc2", seconds=2):
    separator = ":" if "=" in source else "="
    return ["-f", "lavfi", "-i", f"{source}{separator}s={size}:r={rate}:d={seconds}"]


def streams(path):
    return probe(path, "-show_streams")["streams"]


def frame_count(path):
    return int(probe(path, "-select_streams", "v:0", "-count_frames", "-show_entries", "stream=nb_read_frames")
               ["streams"][0]["nb_read_frames"])


def gray(path, at, filters="", size=CANVAS):
    """One decoded luma picture at `at` seconds."""
    chain = ",".join(item for item in [filters, "format=gray"] if item)
    data = ffmpeg("-ss", str(float(at)), "-i", path, "-map", "0:v:0", "-frames:v", "1", "-vf", chain,
                  "-f", "rawvideo", "-")
    assert len(data) == size[0] * size[1], (len(data), size)
    return data


def psnr(first, second):
    error = sum((a - b) ** 2 for a, b in zip(first, second, strict=True)) / len(first)
    return 99.0 if error == 0 else 10 * __import__("math").log10(255 * 255 / error)


def fitted(width, height, canvas=CANVAS):
    """Where a display picture lands when it is fitted inside the canvas, as the rules state it."""
    def even(value, limit):
        rounded = min(limit, max(2, 2 * int(value / 2 + 0.5)))
        return limit if limit - rounded <= 2 else rounded
    if width * canvas[1] == height * canvas[0]:
        size = canvas
    elif width * canvas[1] < height * canvas[0]:
        size = (even(width * canvas[1] / height, canvas[0]), canvas[1])
    else:
        size = (canvas[0], even(height * canvas[0] / width, canvas[1]))
    return size, ((canvas[0] - size[0]) // 2 & ~1, (canvas[1] - size[1]) // 2 & ~1)


def samples(path, rate, track=0):
    data = ffmpeg("-i", path, "-map", f"0:a:{track}", "-ac", "1", "-ar", str(rate), "-c:a", "pcm_f32le", "-f", "f32le", "-")
    return array("f", data)


def power(block, frequency, rate):
    """Goertzel-style energy of one frequency in a block, normalised to its length."""
    real = sum(value * cos(2 * pi * frequency * index / rate) for index, value in enumerate(block))
    imaginary = sum(value * sin(2 * pi * frequency * index / rate) for index, value in enumerate(block))
    return sqrt(real * real + imaginary * imaginary) / max(1, len(block))


class MixedTimelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-mixed-fixtures-")
        cls.addClassCleanup(directory.cleanup)
        fx = cls.fx = Path(directory.name)
        x264 = ["-c:v", "libx264", "-preset", "ultrafast", "-g", "25", "-threads", "1"]

        def tagged(matrix="bt709", primaries="bt709", transfer="bt709", levels="limited", before=""):
            # The encoders take colour tags from the pictures they are given.
            chain = f"setparams=range={levels}:color_primaries={primaries}:color_trc={transfer}:colorspace={matrix}"
            return ["-vf", f"{before},{chain}" if before else chain]

        tags = tagged()
        # Clip 1 sets the canvas: landscape H.264, 25 fps, AAC 48 kHz stereo, MP4.
        cls.wide = fx / "wide.mp4"
        ffmpeg(*picture("320x180", 25), *tone(440, 48000), *x264, "-pix_fmt", "yuv420p", *tags, "-c:a", "aac", cls.wide)
        # Portrait HEVC, 10-bit, 30 fps, PCM 44.1 kHz mono, MOV.
        cls.portrait = fx / "portrait.mov"
        ffmpeg(*picture("96x160", 30), *tone(660, 44100, "mono"), "-c:v", "libx265", "-x265-params", "log-level=error",
               "-tag:v", "hvc1", "-pix_fmt", "yuv420p10le", *tags, "-c:a", "pcm_s16le", cls.portrait, allow_diagnostics=True)
        # Coded landscape, shown upright through a rotation tag.
        coded = fx / "coded.mp4"
        ffmpeg(*picture("320x96", 25), *tone(880, 48000), *x264, "-pix_fmt", "yuv420p", *tags, "-c:a", "aac", coded)
        cls.rotated = fx / "rotated.mp4"
        ffmpeg("-display_rotation", "90", "-i", coded, "-map", "0", "-c", "copy", cls.rotated)
        # ProRes 4:2:2, 4:3, 24 fps, 24-bit PCM at 96 kHz in 5.1.
        cls.prores = fx / "prores.mov"
        ffmpeg(*picture("640x480", 24), *tone(550, 96000, "5.1"), "-c:v", "prores_ks", "-profile:v", "2",
               "-pix_fmt", "yuv422p10le", *tags, "-c:a", "pcm_s24le", cls.prores)
        # Full-range white without sound, 50 fps, MKV.
        cls.silent = fx / "silent.mkv"
        ffmpeg(*picture("160x120", 50, "color=c=white"), *x264,
               *tagged(levels="full", before="scale=out_range=full,format=yuvj420p"), cls.silent)
        # Anamorphic: 180x180 stored, shown as 320x180.
        cls.anamorphic = fx / "anamorphic.mp4"
        ffmpeg(*picture("180x180", 25), *tone(770, 48000), *tagged(before="setsar=16/9"), *x264, "-pix_fmt", "yuv420p",
               "-c:a", "aac", cls.anamorphic)
        # Red in BT.601.
        cls.red601 = fx / "red601.mp4"
        ffmpeg(*picture("160x120", 25, "color=c=red"),
               *tagged("smpte170m", "smpte170m", "smpte170m",
                       before="scale=out_color_matrix=smpte170m:out_range=limited,format=yuv420p"), *x264, cls.red601)
        cls.pq, cls.hlg = fx / "pq.mov", fx / "hlg.mov"
        for path, transfer in ((cls.pq, "smpte2084"), (cls.hlg, "arib-std-b67")):
            ffmpeg(*picture("320x180", 25), "-c:v", "libx265", "-x265-params", "log-level=error", "-tag:v", "hvc1",
                   "-pix_fmt", "yuv420p10le", *tagged("bt2020nc", "bt2020", transfer), path, allow_diagnostics=True)
        cls.sound = fx / "sound.m4a"
        ffmpeg(*tone(330, 48000), "-c:a", "aac", cls.sound)
        # The same streams in three containers.
        cls.picture_only = [fx / f"picture.{extension}" for extension in ("mp4", "mov", "mkv")]
        for path in cls.picture_only:
            ffmpeg("-i", cls.wide, "-map", "0:v:0", "-c", "copy", path)
        cls.same_mov, cls.same_mkv = fx / "same.mov", fx / "same.mkv"
        for path in (cls.same_mov, cls.same_mkv):
            ffmpeg("-i", cls.wide, "-map", "0", "-c", "copy", path)
        # The same picture with another sound format.
        cls.other_sound = fx / "other-sound.mov"
        ffmpeg("-i", cls.wide, *tone(990, 44100, "mono"), "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy",
               "-c:a", "pcm_s16le", cls.other_sound)

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-mixed-output-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def cli(self, *args, stdin=None, ok=True):
        done = subprocess.run([CLI, "--no-sidecar", *map(str, args)], input=stdin, capture_output=True, text=True, timeout=180)
        self.assertEqual(done.returncode == 0, ok, done.stdout + done.stderr)
        report = json.loads(done.stdout)
        self.assertIs(report["ok"], ok, report)
        return report

    def export(self, output, clips, *flags, dry=False, ok=True, mode="encode"):
        args = ["export", "clips", "join", "--json", "--output", output, *flags]
        if mode:
            args += ["--mode", mode]
        if dry:
            args.append("--dry-run")
        for clip in clips:
            source, start, end = clip if isinstance(clip, tuple) else (clip, None, None)
            args += ["--clip", source]
            if start is not None:
                args += ["--from", start, "--to", end]
        report = self.cli(*args, ok=ok)
        self.assertEqual(Path(output).exists(), ok and not dry)
        return report

    def assert_clean(self):
        self.assertFalse(any(self.root.glob(".mpcut-*")), list(self.root.iterdir()))

    def assert_decodes(self, path):
        done = subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-i", str(path), "-map", "0",
                               "-fps_mode", "passthrough", "-enc_time_base:v", "1:600000", "-f", "null", "-"],
                              capture_output=True, text=True)
        self.assertTrue(done.returncode == 0 and not done.stderr, done.stderr[:800])

    # MARK: The whole mix

    def test_every_kind_of_difference_is_written_on_the_first_clips_canvas(self):
        clips = [self.wide, self.portrait, self.rotated, self.prores, self.silent, self.anamorphic]
        display = [(320, 180), (96, 160), (96, 320), (640, 480), (160, 120), (320, 180)]
        output = self.root / "mixed.mov"
        planned = self.export(output, clips, "--audio", "pcm", dry=True)
        written = self.export(output, clips, "--audio", "pcm")
        for report in (planned, written):
            report.pop("dry_run")
        self.assertEqual(planned, written, "A dry run and the export it plans report the same.")
        self.assert_clean()
        self.assert_decodes(output)

        self.assertEqual((written["width"], written["height"], written["mode"]), (*CANVAS, "encode"))
        self.assertEqual(written["canvas"]["audio"], [{"sample_rate": 48000, "channels": 2, "layout": "stereo"}])
        warnings = "\n".join(written["warnings"])
        for expected in ["Sources differ in video codec, picture size, frame rate, pixel format",
                         "(clips 1 and 2); the whole timeline is re-encoded to 320×180.",
                         "Clips 2, 3, 4 and 5 have another picture shape and are fitted inside 320×180 with black bars.",
                         "variable frame rate", "Audio track 1 is resampled to 48 kHz",
                         "Audio track 1 has different channel layouts and is mixed to stereo.",
                         "Clip 5 has no audio track 1. Silence is written there."]:
            self.assertIn(expected, warnings)
        tier = written["tier"]
        self.assertEqual((tier["id"], tier["mode"]), ("reencode", "encode"))
        mismatch = [factor for factor in tier["factors"] if factor["id"] == "join_stream_mismatch"]
        self.assertEqual(len(mismatch), 1)
        self.assertEqual(mismatch[0]["forces"], "reencode")
        self.assertIn("Clips 1 and 2 differ in video codec, picture size", mismatch[0]["message"])

        video, audio = streams(output)
        self.assertEqual((video["codec_name"], video["width"], video["height"], video["pix_fmt"]), ("h264", *CANVAS, "yuv420p"))
        self.assertEqual(video.get("sample_aspect_ratio", "1:1"), "1:1")
        self.assertFalse(any("rotation" in item for item in video.get("side_data_list", [])))
        # Some clips are AAC. Decoded lossy sound is written as float PCM, which does not clip above full scale.
        self.assertEqual((audio["codec_name"], int(audio["sample_rate"]), audio["channels"]), ("pcm_f32le", 48000, 2))
        self.assertEqual([(item["action"], item["codec"], item["bit_depth"]) for item in written["audio_actions"]],
                         [("pcm", "pcm_f32le", 32)])
        # Duration is exact for picture and sound, and no picture is dropped or repeated.
        self.assertEqual(Fraction(written["duration"]["numerator"], written["duration"]["denominator"]), 12)
        self.assertEqual(Fraction(video["duration"]), 12)
        self.assertEqual(int(audio["duration_ts"]), 12 * 48000)
        self.assertEqual(frame_count(output), sum(frame_count(clip) for clip in clips))
        self.assertNotEqual(video["r_frame_rate"], video["avg_frame_rate"], "Frame rates are kept, not converted.")

        # Each picture is fitted, never stretched or cropped: it matches a reference fit, and the bars are black.
        for index, (clip, (width, height)) in enumerate(zip(clips, display)):
            with self.subTest(clip=clip.name):
                (fw, fh), (x, y) = fitted(width, height)
                at = 2 * index + 1
                actual = gray(output, at)
                reference = gray(clip, 1, f"scale={fw}:{fh},setsar=1,pad={CANVAS[0]}:{CANVAS[1]}:{x}:{y}:black")
                self.assertGreater(psnr(actual, reference), 24, "the fitted picture")
                if (fw, fh) != CANVAS:
                    stretched = gray(clip, 1, f"scale={CANVAS[0]}:{CANVAS[1]},setsar=1")
                    self.assertGreater(psnr(actual, reference), psnr(actual, stretched) + 6)
                    rows = [actual[row * CANVAS[0]:(row + 1) * CANVAS[0]] for row in range(CANVAS[1])]
                    outside = [value for number, row in enumerate(rows) for column, value in enumerate(row)
                               if not (x + 2 <= column < x + fw - 2 and y + 2 <= number < y + fh - 2)
                               and not (x - 2 <= column < x + fw + 2 and y - 2 <= number < y + fh + 2)]
                    self.assertTrue(outside)
                    self.assertLess(max(outside), 40, "bars are black")
        # The full-range white clip is converted to the canvas range, not relabelled.
        white = gray(output, 9, "crop=100:100:110:40,extractplanes=y", size=(100, 100))
        self.assertTrue(225 <= sum(white) / len(white) <= 240, sum(white) / len(white))

        # Sound: each clip's tone starts half a second after its join, at the canvas rate, and the silent clip is silent.
        rate = 48000
        sound = samples(output, rate)
        self.assertEqual(len(sound), 12 * rate)
        for index, frequency in enumerate([440, 660, 880, 550, None, 770]):
            with self.subTest(sound=index):
                start = 2 * index * rate
                quiet = sound[start + 480:start + int(TONE_START * rate) - 480]
                loud = sound[start + int(TONE_START * rate) + 480:start + 2 * rate - 480]
                self.assertLess(max(abs(value) for value in quiet), 0.02, "silence before the tone, so the join is in sync")
                if frequency is None:
                    self.assertLess(max(abs(value) for value in loud), 0.001)
                    continue
                self.assertGreater(power(loud[:4800], frequency, rate), 0.15)
                onset = next(position for position in range(start, start + 2 * rate) if abs(sound[position]) > 0.05)
                self.assertLess(abs(onset - (start + int(TONE_START * rate))), rate // 500, "within two milliseconds")

    def test_aac_in_mp4_and_stdin_request(self):
        clips = [self.wide, self.portrait, self.silent]
        request = {"output": str(self.root / "request.mp4"), "mode": "encode",
                   "clips": [{"file": str(clip)} for clip in clips]}
        planned = self.cli("export", "clips", "join", "--json", "--stdin", "--dry-run", stdin=json.dumps(request))
        written = self.cli("export", "clips", "join", "--json", "--stdin", stdin=json.dumps(request))
        for report in (planned, written):
            report.pop("dry_run")
        self.assertEqual(planned, written)
        self.assertEqual([(item["action"], item["track"]) for item in written["audio_actions"]], [("aac", 1)])
        output = self.root / "request.mp4"
        self.assert_decodes(output)
        video, audio = streams(output)
        self.assertEqual((video["width"], video["height"]), CANVAS)
        self.assertEqual((audio["codec_name"], int(audio["sample_rate"]), audio["channels"]), ("aac", 48000, 2))
        self.assertEqual(Fraction(video["duration"]), 6)
        self.assertLess(abs(Fraction(audio["duration"]) - 6), Fraction(1024, 48000))
        rate = 48000
        sound = samples(output, rate)
        for index, frequency in enumerate([440, 660]):
            start = 2 * index * rate
            onset = next(position for position in range(start + 960, start + 2 * rate) if abs(sound[position]) > 0.05)
            self.assertLess(abs(onset - (start + int(TONE_START * rate))), rate // 250)
            self.assertGreater(power(sound[start + rate:start + rate + 4800], frequency, rate), 0.15)
        # Without sidecars or JSON, people read the same warnings.
        text = subprocess.run([CLI, "--no-sidecar", "export", "clips", "join", "--dry-run", "--mode", "encode", "--output", self.root / "text.mp4",
                               "--clip", self.wide, "--clip", self.portrait], capture_output=True, text=True)
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertIn("the whole timeline is re-encoded to 320×180", text.stdout + text.stderr)

    def test_other_codecs_and_containers(self):
        clips = [(self.portrait, "0", "1"), (self.wide, "0", "1"), (self.prores, "0", "1")]
        # One clip is AAC, so the track is not lossless: Auto writes AAC, or PCM for ProRes, as float for the decoded AAC.
        for codec, extension, pixel_format, sound in [("hevc", "mkv", "yuv420p10le", "aac"), ("prores", "mov", "yuv422p10le", "pcm_f32le"),
                                                      ("h264", "mkv", "yuv420p", "aac")]:
            with self.subTest(codec=codec):
                output = self.root / f"{codec}.{extension}"
                report = self.export(output, clips, "--video", codec)
                self.assert_decodes(output)
                video, audio = streams(output)
                # The portrait clip is first, so the canvas is portrait.
                self.assertEqual((video["codec_name"], video["width"], video["height"], video["pix_fmt"]),
                                 (codec, 96, 160, pixel_format))
                self.assertEqual(audio["codec_name"], sound)
                self.assertEqual((report["width"], report["height"]), (96, 160))
                self.assertEqual(frame_count(output), 30 + 25 + 24)
                duration = Fraction(probe(output, "-show_entries", "format=duration")["format"]["duration"])
                self.assertLess(abs(duration - 3), Fraction(1, 20))
                self.assert_clean()

    def test_auto_writes_a_track_that_is_lossless_in_every_clip_as_pcm(self):
        # Both clips carry PCM, at other rates and layouts. Auto keeps the track lossless where the container carries PCM.
        clips = [(self.portrait, "0", "1"), (self.prores, "0", "1")]
        for extension, action, codec in [("mov", "pcm", "pcm_s32le"), ("mkv", "pcm", "pcm_s32le"), ("mp4", "aac", "aac")]:
            with self.subTest(container=extension):
                output = self.root / f"lossless.{extension}"
                report = self.export(output, clips)
                planned = report["audio_actions"][0]
                self.assertEqual((planned["action"], planned["codec"], planned["track"]), (action, codec, 1))
                self.assertIn("The clips differ, so their sound is converted to one format.", planned["reason"])
                # The clips differ in rate and layout, so the track has no one source format to keep and follows the rule by category.
                self.assertIn("The lossless sources of this track, which differ in format, are written as PCM" if action == "pcm"
                              else "MP4 cannot carry PCM", planned["reason"])
                self.assertEqual(streams(output)[1]["codec_name"], codec)
        # A clip with AAC at the same position makes the track lossy, and Auto converts it as before.
        report = self.export(self.root / "lossy.mov", [(self.portrait, "0", "1"), (self.wide, "0", "1")], dry=True)
        planned = report["audio_actions"][0]
        self.assertEqual((planned["action"], planned["codec"], planned["bit_rate"]), ("aac", "aac", 192_000))
        self.assertNotIn("lossless", planned["reason"])

    def test_colour_matrix_is_converted_to_the_canvas(self):
        output = self.root / "colour.mp4"
        report = self.export(output, [self.wide, self.red601], "--audio", "remove")
        self.assertIn("different colour primaries or transfer functions", "\n".join(report["warnings"]))
        video = streams(output)[0]
        self.assertEqual(video.get("color_space"), "bt709")
        rgb = ffmpeg("-ss", "3", "-i", output, "-frames:v", "1",
                     "-vf", "crop=40:40:140:70,scale=in_color_matrix=bt709:in_range=limited,format=rgb24", "-f", "rawvideo", "-")
        red, green, blue = (sum(rgb[channel::3]) / (len(rgb) // 3) for channel in range(3))
        self.assertGreater(red, 235)
        self.assertLess(max(green, blue), 14, "Unconverted BT.601 red read as BT.709 leaves green and blue near 25.")

    def test_only_the_sound_differs(self):
        output = self.root / "sound.mov"
        report = self.export(output, [self.wide, self.other_sound])
        self.assertIn("the sound of the whole timeline is converted", report["warnings"][0])
        self.assertNotIn("fitted", "\n".join(report["warnings"]))
        video, audio = streams(output)
        self.assertEqual((video["width"], video["height"], int(audio["sample_rate"]), audio["channels"]), (*CANVAS, 48000, 2))
        self.assertEqual(frame_count(output), 100)
        sound = samples(output, 48000)
        self.assertGreater(power(sound[48000:52800], 440, 48000), 0.15)
        self.assertGreater(power(sound[3 * 48000:3 * 48000 + 4800], 990, 48000), 0.15)

    # MARK: Refusals

    def test_copy_and_smart_trim_are_refused_and_offer_the_reencode(self):
        clips = [self.wide, self.portrait]
        for mode in (None, "copy", "smart"):
            with self.subTest(mode=mode):
                output = self.root / "refused.mp4"
                refused = self.export(output, clips, dry=True, ok=False, mode=mode)["error"]
                self.assertEqual((refused["code"], refused["reason"], refused["segment"]), ("incompatible_clip", "join_stream_mismatch", 2))
                offers = refused["alternatives"]
                self.assertEqual([offer["id"] for offer in offers], ["reencode"])
                self.assertIn("the whole timeline is re-encoded", offers[0]["warnings"][0])
                # Nothing switched by itself, and the offer is what works.
                self.export(output, clips, dry=False, ok=False, mode=mode)
                self.assertFalse(output.exists())
                flags = offers[0]["arguments"]
                self.assertEqual(flags[:2], ["--mode", "encode"])
                self.export(self.root / f"offer.{offers[0]['container']}", clips, *flags, dry=True, mode=None)
        self.assert_clean()

    def test_audio_copy_is_refused_with_alternatives(self):
        refused = self.export(self.root / "copy.mov", [self.wide, self.portrait], "--audio", "copy", dry=True, ok=False)["error"]
        self.assertEqual((refused["code"], refused["reason"], refused["segment"]), ("incompatible_clip", "join_stream_mismatch", 2))
        self.assertIn("their sound cannot be copied", refused["message"])
        offers = refused["alternatives"]
        self.assertTrue(offers)
        self.assertEqual({offer["rung"] for offer in offers}, {"reencode"})
        self.assertIn(["--mode", "encode", "--audio", "auto"], [offer["arguments"] for offer in offers])
        # Only the sound differs: the same answer.
        refused = self.export(self.root / "copy.mov", [self.wide, self.other_sound], "--audio", "copy", dry=True, ok=False)["error"]
        self.assertEqual(refused["code"], "incompatible_clip")
        self.assertTrue(refused["alternatives"])

    def test_pcm_in_mp4_is_refused_even_when_the_first_clip_is_silent(self):
        refused = self.export(self.root / "pcm.mp4", [self.silent, self.wide], "--audio", "pcm", dry=True, ok=False)["error"]
        self.assertEqual(refused["code"], "unsupported_audio")
        self.assertIn("MOV or MKV", refused["message"])
        self.assertIn("reencode:mov", [offer["id"] for offer in refused["alternatives"]])
        # The silent clip is first: the later clips still give the timeline its sound.
        output = self.root / "silent-first.mov"
        report = self.export(output, [self.silent, self.wide], "--audio", "pcm")
        self.assertEqual((report["width"], report["height"]), (160, 120))
        self.assertEqual(len(streams(output)), 2)
        sound = samples(output, 48000)
        self.assertLess(max(abs(value) for value in sound[:2 * 48000]), 0.001)
        self.assertGreater(power(sound[3 * 48000:3 * 48000 + 4800], 440, 48000), 0.15)

    def test_hdr_is_never_joined_to_sdr(self):
        for first, second, words in [(self.wide, self.pq, ("SDR", "HDR (PQ)")), (self.pq, self.wide, ("HDR (PQ)", "SDR")),
                                     (self.pq, self.hlg, ("HDR (PQ)", "HDR (HLG)"))]:
            with self.subTest(first=first.name, second=second.name):
                refused = self.export(self.root / "hdr.mov", [first, second], "--video", "hevc", dry=True, ok=False)["error"]
                self.assertEqual((refused["code"], refused["reason"], refused["segment"]), ("incompatible_clip", "join_dynamic_range", 2))
                for word in (*words, first.name, second.name, "Clip 1", "clip 2"):
                    self.assertIn(word, refused["message"])
                # No mode writes it, so nothing is offered.
                refused = self.export(self.root / "hdr.mov", [first, second], dry=True, ok=False, mode=None)["error"]
                self.assertEqual(refused["code"], "incompatible_clip")
                self.assertFalse(refused.get("alternatives"))
        # Two HDR clips of one kind still join.
        report = self.export(self.root / "hdr.mov", [self.pq, self.pq], "--video", "hevc", dry=True)
        self.assertNotIn("canvas", report)

    def test_a_movie_and_a_sound_only_recording_are_refused(self):
        refused = self.export(self.root / "kinds.mp4", [self.wide, self.sound], dry=True, ok=False)["error"]
        self.assertEqual((refused["code"], refused["reason"], refused["segment"]), ("incompatible_clip", "join_media_type", 2))
        self.assertIn("sound.m4a", refused["message"])
        self.assertFalse(refused.get("alternatives"))
        for mode in (None, "copy", "smart"):
            refused = self.export(self.root / "kinds.mp4", [self.wide, self.sound], dry=True, ok=False, mode=mode)["error"]
            self.assertEqual((refused["code"], refused["reason"]), ("incompatible_clip", "join_media_type"))
            self.assertFalse(refused.get("alternatives"))
        # A recording first makes it a sound export, which has no picture to join.
        refused = self.export(self.root / "kinds.m4a", [self.sound, self.wide], dry=True, ok=False, mode=None)["error"]
        self.assertEqual((refused["code"], refused["reason"]), ("incompatible_clip", "join_media_type"))

    # MARK: Containers

    def test_the_same_streams_in_other_containers_still_copy(self):
        # The copy check compares streams, not containers.
        mp4, mov, mkv = self.picture_only
        clips = [(mp4, "0", "1"), (mov, "1", "2"), (mkv, "0", "1")]
        output = self.root / "containers.mkv"
        report = self.export(output, clips, mode="copy")
        self.assertEqual(report["mode"], "copy")
        self.assertEqual(frame_count(output), 75)
        # MP4 and MOV sources also join in MP4. A Matroska source there is a matter of its timestamps, not of the join.
        self.export(self.root / "containers.mp4", clips[:2], mode="copy")
        self.assertEqual(frame_count(self.root / "containers.mp4"), 50)
        planned = self.export(self.root / "containers-dry.mkv", clips, mode="copy", dry=True)
        self.assertEqual(planned["tier"]["id"], "true_lossless")
        # Re-encode treats them as one format too: no canvas, no warning about differences.
        encoded = self.export(self.root / "containers-encode.mp4", clips, dry=True)
        self.assertNotIn("canvas", encoded)
        self.assertFalse([warning for warning in encoded["warnings"] if "differ" in warning])

    def test_containers_that_describe_the_same_sound_differently_copy_together(self):
        # MP4 states "2 channels" for this AAC track where MOV states "stereo". The packets are identical, and the
        # copy check compares the layout the words stand for, so the two join like two files of one container.
        def layout(path):
            audio_stream = next(s for s in self.cli("media", "inspect", "--json", path)["media"]["streams"] if s["kind"] == "audio")
            return audio_stream["channel_layout"]
        self.assertEqual((layout(self.wide), layout(self.same_mov)), ("2 channels", "stereo"), "inspect reports what each file states")

        # The control: the same join made from two MP4 files, which always copied.
        twin = self.root / "twin.mp4"
        twin.write_bytes(self.wide.read_bytes())
        control = self.root / "control.mp4"
        self.export(control, [(self.wide, "0", "1"), (twin, "1", "2")], mode="copy")
        decoder = self.root / "decode-audio"
        run(["swiftc", "-parse-as-library", Path(__file__).with_name("DecodeAudio.swift"), "-o", decoder], allow_diagnostics=True)

        def native(path):
            # AVAssetReader honours the edit list that places each clip's sound, as players do.
            return array("h", run([decoder, path]))
        original, expected = native(self.wide), native(control)

        for first, second in ((self.wide, self.same_mov), (self.same_mov, self.wide)):
            for container in ("mp4", "mov"):
                with self.subTest(first=first.suffix, container=container):
                    clips = [(first, "0", "1"), (second, "1", "2")]
                    output = self.root / f"sound-{first.suffix[1:]}.{container}"
                    for mode in ("copy", "smart"):
                        planned = self.export(output, clips, mode=mode, dry=True)
                        self.assertEqual((planned["mode"], planned["tier"]["id"], planned["tier"]["factors"]), (mode, "true_lossless", []))
                    report = self.export(output, clips, mode="copy")
                    self.assertEqual((report["mode"], Fraction(report["encoded_duration"]["numerator"],
                                                               report["encoded_duration"]["denominator"])), ("copy", 0))
                    # The same pictures and the same compressed sound as the clips, in order.
                    self.assertEqual(frame_count(output), 50)
                    for track in ("v:0", "a:0"):
                        self.assertEqual(sample_hashes(output, track), sample_hashes(control, track))
                    sound = next(stream for stream in streams(output) if stream["codec_type"] == "audio")
                    self.assertEqual((sound["codec_name"], sound["channels"], sound["channel_layout"], sound["sample_rate"]),
                                     ("aac", 2, "stereo", "48000"))
                    self.assertIn(layout(output), ("2 channels", "stereo"))
                    # Decoded, it is the sound of the two clips one after the other: sample for sample the join of two
                    # MP4 files, and the first clip sample for sample as in its source. The second clip starts a new
                    # edit, which a decoder may round differently by a few units of the last bit.
                    decoded = native(output)
                    self.assertEqual(len(decoded), 2 * 2 * 48000)
                    self.assertEqual(decoded, expected)
                    self.assertEqual(decoded[:2 * 47000], original[:2 * 47000])
                    self.assertLessEqual(max(abs(a - b) for a, b in zip(decoded, original)), 8)

        # Layouts that name different speakers still do not copy together.
        refused = self.export(self.root / "other.mp4", [(self.wide, "0", "1"), (self.other_sound, "1", "2")],
                              mode="copy", dry=True, ok=False)["error"]
        self.assertEqual((refused["code"], refused["reason"]), ("incompatible_clip", "join_stream_mismatch"))
        # Nor do two layouts of one channel count that name different speakers: 5.1 with back and with side surrounds.
        def surround(name, layout):
            path = self.root / name
            mix = "|".join(f"c{channel}=c0" for channel in range(6))
            ffmpeg(*picture("320x180", 25), "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
                   "-filter_complex", f"[1:a]pan={layout}|{mix}[a]", "-map", "0:v", "-map", "[a]", "-c:v", "libx264",
                   "-preset", "ultrafast", "-g", "25", "-threads", "1", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", path)
            return path
        back, side = surround("back.mov", "5.1"), surround("side.mov", "5.1(side)")
        self.assertEqual((layout(back), layout(side)), ("5.1", "5.1(side)"))
        refused = self.export(self.root / "surround.mov", [(back, "0", "1"), (side, "1", "2")], mode="copy", dry=True, ok=False)["error"]
        self.assertEqual((refused["code"], refused["reason"], refused["segment"]), ("incompatible_clip", "join_stream_mismatch", 2))
        self.assertEqual(refused["message"], "Clip audio track 1 channel layout is 5.1(side). The sequence requires 5.1.")
        # Re-encode treats the two containers as one format, as before: no canvas.
        encoded = self.export(self.root / "sound-encode.mp4", [(self.wide, "0", "1"), (self.same_mov, "1", "2")], dry=True)
        self.assertNotIn("canvas", encoded)
        self.assertFalse([warning for warning in encoded["warnings"] if "differ" in warning])

    def test_resolve_interchange_describes_each_clip_in_its_own_format(self):
        # Interchange writes no media and already took clips in different formats: pinned, not changed.
        output = self.root / "mixed.fcpxml"
        request = {"output": str(output), "clips": [{"file": str(self.wide)}, {"file": str(self.prores)}]}
        self.cli("project", "resolve", "export", "--json", "--stdin", stdin=json.dumps(request))
        import xml.etree.ElementTree as tree
        document = tree.parse(output).getroot()
        formats = {item.get("id"): (item.get("width"), item.get("height"), item.get("frameDuration")) for item in document.iter("format")}
        sequence = next(document.iter("sequence"))
        self.assertEqual(formats[sequence.get("format")], ("320", "180", "1/25s"), "the sequence follows the first clip")
        self.assertIn(("640", "480", "1/24s"), formats.values())
        self.assertEqual([clip.get("name") for clip in document.iter("asset-clip")], ["wide.mp4", "prores.mov"])

    def test_final_cut_interchange_describes_each_clip_in_its_own_format(self):
        # The Final Cut converter writes no media either. A mixed project keeps every clip in its own format,
        # the sequence follows the first clip, nothing is warned about, and the project comes back as it was.
        clips = [{"id": "one", "file": str(self.wide), "from": "0", "to": "1"},
                 {"id": "two", "file": str(self.prores), "from": "1/2", "to": "3/2"},
                 {"id": "three", "file": str(self.portrait), "from": "0", "to": "1"}]
        project = self.root / "mixed.cut"
        project.write_text(json.dumps({"format": "mpcut", "schema_version": 9, "kind": "sequence", "clips": clips}))
        output = self.root / "mixed-fcp.fcpxml"
        self.assertEqual(self.cli("project", "convert", project, "--to", "fcp", "--output", output, "--json")["warnings"], [])
        import xml.etree.ElementTree as tree
        document = tree.parse(output).getroot()
        formats = {item.get("id"): (item.get("width"), item.get("height"), item.get("frameDuration")) for item in document.iter("format")}
        sequence = next(document.iter("sequence"))
        self.assertEqual(formats[sequence.get("format")], ("320", "180", "1/25s"), "the sequence follows the first clip")
        assets = {item.get("id"): item for item in document.iter("asset")}
        placed = [(clip.get("name"), formats[assets[clip.get("ref")].get("format")], assets[clip.get("ref")].get("audioChannels"),
                   clip.get("offset"), clip.get("start"), clip.get("duration")) for clip in document.iter("asset-clip")]
        self.assertEqual(placed, [("wide.mp4", ("320", "180", "1/25s"), "2", "0s", "0s", "1s"),
                                  ("prores.mov", ("640", "480", "1/24s"), "6", "1s", "1/2s", "1s"),
                                  ("portrait.mov", ("96", "160", "1/30s"), "1", "2s", "0s", "1s")])
        restored = self.root / "restored.cut"
        self.assertEqual(self.cli("project", "convert", output, "--output", restored, "--json")["warnings"], [])
        back = read_project(restored)["clips"]
        self.assertEqual([(Path(clip["file"]).name, clip["from"], clip["to"]) for clip in back],
                         [(Path(clip["file"]).name, clip["from"], clip["to"]) for clip in clips])

        # Clips cut on their own frames can end between frames of the sequence, which runs at the first clip's rate.
        # That is refused and names the cut. With the loss allowed the cut is rounded to a frame and warned about.
        clips[1].update({"from": "1/24", "to": "13/24"})
        clips[2].update({"from": "1/30", "to": "1"})
        project.write_text(json.dumps({"format": "mpcut", "schema_version": 9, "kind": "sequence", "clips": clips}))
        rounded = self.root / "rounded.fcpxml"
        refused = self.cli("project", "convert", project, "--to", "fcp", "--output", rounded, "--json", ok=False)["error"]
        self.assertEqual(refused["code"], "conversion_loss")
        self.assertIn("Timeline cut at 3/2s rounds to 38/25s at 25 fps.", refused["message"])
        self.assertFalse(rounded.exists())
        warnings = self.cli("project", "convert", project, "--to", "fcp", "--allow-loss", "--output", rounded, "--json")["warnings"]
        self.assertEqual(warnings, ["Timeline cut at 3/2s rounds to 38/25s at 25 fps.", "Timeline cut at 37/15s rounds to 62/25s at 25 fps."])
        document = tree.parse(rounded).getroot()
        self.assertEqual([(clip.get("offset"), clip.get("start"), clip.get("duration")) for clip in document.iter("asset-clip")],
                         [("0s", "0s", "1s"), ("1s", "1/24s", "13/25s"), ("38/25s", "1/30s", "24/25s")])

    # MARK: Seamless splits

    def test_a_split_that_removes_nothing_is_the_unsplit_copy(self):
        # 13/25 is inside the first picture group of this clip. Two pieces that meet there are still the whole clip:
        # nothing is encoded, so the timeline is True Lossless and Lossless Copy writes it, like Smart Trim.
        split = [(self.wide, "0", "13/25"), (self.wide, "13/25", "2")]
        for mode in ("copy", "smart"):
            for container in ("mp4", "mov", "mkv"):
                with self.subTest(mode=mode, container=container):
                    planned = self.export(self.root / f"split-dry.{container}", split, mode=mode, dry=True)
                    self.assertEqual((planned["mode"], planned["tier"]["id"], planned["tier"]["factors"]), (mode, "true_lossless", []))
                    self.assertEqual(planned["encoded_duration"], {"numerator": 0, "denominator": 1})
                    self.assertEqual(len(planned["segments"]), 1)
        for container in ("mp4", "mov"):
            whole, joined = self.root / f"whole.{container}", self.root / f"split.{container}"
            self.export(whole, [(self.wide, "0", "2")], mode="copy")
            self.export(joined, split, mode="copy")
            self.assertEqual(joined.read_bytes(), whole.read_bytes(), "the split copy is the unsplit copy")
            for track in ("v:0", "a:0"):
                self.assertEqual(sample_hashes(joined, track), sample_hashes(self.wide, track))

        # With one frame removed the pieces no longer meet: the second piece starts inside a picture group again.
        # The first piece may still end there, since this H.264 has no reordered pictures.
        removed = [(self.wide, "0", "13/25"), (self.wide, "14/25", "2")]
        refused = self.export(self.root / "removed.mp4", removed, mode="copy", dry=True, ok=False)["error"]
        self.assertEqual((refused["code"], refused["reason"], refused["segment"], refused["boundary"]),
                         ("unsafe_boundary", "cut_video_start", 2, "from"))
        self.assertTrue(refused["nearest"])
        encoded = self.export(self.root / "removed.mp4", removed, mode="smart", dry=True)
        self.assertEqual(encoded["tier"]["id"], "lossless")
        self.assertEqual([factor["id"] for factor in encoded["tier"]["factors"]], ["cut_video_start"])
        self.assertGreater(Fraction(encoded["encoded_duration"]["numerator"], encoded["encoded_duration"]["denominator"]), 0)

    # MARK: Batches and interruption

    def batch_arguments(self, output):
        sources = []
        for index in range(48):
            original = [self.wide, self.silent, self.portrait, self.red601][index % 4]
            link = self.root / f"source-{index}{original.suffix}"
            if not link.exists():
                os.link(original, link)
            sources.append(link)
        args = [CLI, "--no-sidecar", "export", "clips", "join", "--json", "--mode", "encode", "--audio", "aac", "--output", str(output)]
        for index, source in enumerate(sources):
            start = Fraction(index % 5, 5)
            args += ["--clip", str(source), "--from", str(start), "--to", str(start + Fraction(1, 5))]
        return args

    def test_batches_of_different_sources_share_one_canvas(self):
        # The first clip has no colour tags and no sound, so the canvas names none. Later parts open on tagged,
        # full-range and BT.601 clips, and must still give the encoder the same picture configuration.
        untagged = self.root / "untagged.mp4"
        ffmpeg(*picture("160x120", 25), "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", untagged)
        self.assertEqual(streams(untagged)[0].get("color_space", "unknown"), "unknown")
        output = self.root / "batches.mov"
        args = self.batch_arguments(output)
        first = args.index("--clip")
        args[first:first] = ["--clip", str(untagged), "--from", "0", "--to", "1/5"]
        done = subprocess.run(args, capture_output=True, text=True, timeout=300,
                              preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64)))
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        report = json.loads(done.stdout)
        self.assertEqual((report["width"], report["height"]), (160, 120))
        self.assertEqual(report["canvas"]["color_matrix"], "unknown")
        self.assert_decodes(output)
        video, audio = streams(output)
        self.assertEqual((video["width"], video["height"]), (160, 120))
        self.assertEqual(frame_count(output), 5 + 12 * (5 + 10 + 6 + 5))
        self.assertEqual(Fraction(video["duration"]), Fraction(49, 5))
        self.assertLess(abs(Fraction(audio["duration"]) - Fraction(49, 5)), Fraction(1024, 48000))
        self.assert_clean()

    def test_interrupt_leaves_no_partial_files(self):
        output = self.root / "cancelled.mov"
        args = self.batch_arguments(output)
        limit = lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
        with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=limit) as process:
            try:
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    if any(self.root.glob(".mpcut-*/part-0.mov")):
                        process.send_signal(signal.SIGINT)
                        break
                    self.assertIsNone(process.poll(), "the export ended before a second batch")
                    time.sleep(0.005)
                else:
                    self.fail("No encoded batch appeared")
                stdout, stderr = process.communicate(timeout=60)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        self.assertEqual(process.returncode, 130, stdout + stderr)
        self.assertFalse(output.exists())
        self.assert_clean()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cli")
    parser.add_argument("tests", nargs="*")
    arguments = parser.parse_args()
    CLI = str(Path(arguments.cli).resolve())
    unittest.main(argv=[__file__, *arguments.tests], verbosity=2)
