#!/usr/bin/env python3
"""Verify sound-only conversion of ordinary edits with real decoded output."""
import argparse
from array import array
from fractions import Fraction
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import signal
import sqlite3
import struct
import subprocess
import tempfile
import time
import unittest

from sidecar_payload import section_bytes

from media_regression import audio, ffmpeg, probe, run

CLI = None
RATE = 44_100
TONES = "aevalsrc=0.3*sin(2*PI*(300*t+40*t*t))|0.25*sin(2*PI*(500*t+25*t*t)):s={rate}:d={length}"
# Two ranges with a removed middle. The first range ends between source samples.
CUTS = [("1", "5.10001"), ("9", "11.5")]


def samples(time_text, rate=RATE):
    return int(Fraction(time_text) * rate + Fraction(1, 2))


def kept(decoded, cuts, rate=RATE, channels=2):
    """The decoded source ranges, concatenated in playback order."""
    result = array(decoded.typecode)
    for start, end in cuts:
        result.extend(decoded[samples(start, rate) * channels:samples(end, rate) * channels])
    return result


def pcm16(path):
    return array("h", audio(path))


def pcm32(path):
    return array("i", ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "s32le", "-"))


def difference(actual, expected):
    return max(abs(a - b) for a, b in zip(actual, expected))


def snr(actual, expected):
    signal_power = sum(value * value for value in expected)
    noise = sum((a - b) * (a - b) for a, b in zip(actual, expected))
    return float("inf") if noise == 0 else signal_power / noise


# Each surround layout Vorbis and Opus define: its WAVE speaker mask, one tone for each speaker in WAVE order, and the
# WAVE position of each channel in the order the two codecs carry them. The low-frequency channel takes 60 Hz.
SURROUND = {
    # Front left, front right, centre. Coded as left, centre, right.
    "3.0": (0x7, [300, 500, 700], [0, 2, 1]),
    # Front left, front right, back left, back right.
    "quad": (0x33, [300, 500, 900, 1100], [0, 1, 2, 3]),
    # Front left, front right, centre, back left, back right. Coded with the centre second.
    "5.0": (0x37, [300, 500, 700, 900, 1100], [0, 2, 1, 3, 4]),
    # Front left, front right, centre, low frequency, back left, back right. Coded with the low frequency last.
    "5.1": (0x3F, [300, 500, 700, 60, 1100, 1300], [0, 2, 1, 4, 5, 3]),
    # Front left, front right, centre, low frequency, back centre, side left, side right.
    # Coded as left, centre, right, side left, side right, back centre, low frequency.
    "6.1": (0x70F, [300, 500, 700, 60, 900, 1100, 1300], [0, 2, 1, 5, 6, 4, 3]),
    # Front left, front right, centre, low frequency, back left, back right, side left, side right.
    # Coded as left, centre, right, side left, side right, back left, back right, low frequency.
    "7.1": (0x63F, [300, 500, 700, 60, 1100, 1300, 1500, 1700], [0, 2, 1, 6, 7, 4, 5, 3]),
}
SPEAKER_MASK, SPEAKER_TONES, CODED_ORDER = SURROUND["5.1"]


def six_tones(layout="5.1", tones=SPEAKER_TONES):
    channels = "|".join(f"0.3*sin(2*PI*{tone}*t)" for tone in tones)
    return f"aevalsrc={channels}:s=48000:d=12:c={layout}"


class Wave:
    """An integer PCM WAVE file, read without a decoder."""

    def __init__(self, path):
        data = Path(path).read_bytes()
        position = 12
        while position + 8 <= len(data):
            name, size = data[position:position + 4], struct.unpack_from("<I", data, position + 4)[0]
            body = data[position + 8:position + 8 + size]
            if name == b"fmt ":
                tag, self.channels, _, _, self.align, bits = struct.unpack_from("<HHIIHH", body)
                self.width = bits // 8
                self.mask = struct.unpack_from("<I", body, 20)[0] if tag == 0xFFFE else None
            elif name == b"data":
                self.body = body
                self.frames = len(body) // self.align
                return
            position += 8 + size + (size & 1)
        raise AssertionError(f"{path} has no WAVE data")

    def window(self, channel, start, count):
        scale = float(1 << (8 * self.width - 1))
        first = start * self.align + channel * self.width
        return [int.from_bytes(self.body[at:at + self.width], "little", signed=True) / scale
                for at in range(first, first + count * self.align, self.align)]


def tone_powers(values, tones, rate=48_000):
    """The power of each speaker tone in one channel."""
    powers = []
    for tone in tones:
        k = 2 * math.cos(2 * math.pi * tone / rate)
        a = b = 0.0
        for value in values:
            a, b = value + k * a - b, a
        powers.append((a * a + b * b - k * a * b) / len(values) ** 2)
    return powers


def opus_head(path):
    """The channel count and channel mapping family of an Ogg Opus file."""
    data = Path(path).read_bytes()
    at = data.index(b"OpusHead")
    return data[at + 9], data[at + 18]


class AudioConversionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-audio-convert-")
        cls.addClassCleanup(directory.cleanup)
        cls.root = Path(directory.name)
        tones = TONES.format(rate=RATE, length=12)
        cls.mp3 = cls.root / "constant.mp3"
        cls.vbr = cls.root / "variable.mp3"
        cls.flac = cls.root / "sixteen.flac"
        cls.flac24 = cls.root / "twentyfour.flac"
        cls.m4a = cls.root / "sound.m4a"
        cls.adts = cls.root / "raw.aac"
        cls.opus = cls.root / "sound.opus"
        cls.vorbis = cls.root / "sound.ogg"
        cls.movie = cls.root / "movie.mov"
        ffmpeg("-f", "lavfi", "-i", tones, "-c:a", "libmp3lame", "-b:a", "128k", cls.mp3)
        ffmpeg("-f", "lavfi", "-i", tones, "-c:a", "libmp3lame", "-q:a", "4", cls.vbr)
        ffmpeg("-f", "lavfi", "-i", "anoisesrc=sample_rate=44100:duration=12:seed=3:amplitude=0.4", "-ac", "2",
               "-c:a", "flac", "-sample_fmt", "s16", cls.flac)
        ffmpeg("-f", "lavfi", "-i", "anoisesrc=sample_rate=48000:duration=12:seed=5:amplitude=0.4",
               "-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24", cls.flac24)
        ffmpeg("-f", "lavfi", "-i", tones, "-c:a", "aac", "-b:a", "128k", cls.m4a)
        ffmpeg("-f", "lavfi", "-i", tones, "-c:a", "aac", "-b:a", "128k", "-f", "adts", cls.adts)
        ffmpeg("-f", "lavfi", "-i", TONES.format(rate=48_000, length=12), "-c:a", "libopus", cls.opus)
        cls.steady = cls.root / "steady.opus"
        ffmpeg("-f", "lavfi", "-i", TONES.format(rate=48_000, length=12), "-c:a", "libopus", "-b:a", "80k", "-vbr", "off",
               cls.steady)
        cls.six = cls.root / "six.wav"
        cls.surround = cls.root / "surround.opus"
        ffmpeg("-f", "lavfi", "-i", six_tones(), "-c:a", "pcm_s16le", cls.six)
        ffmpeg("-i", cls.six, "-c:a", "libopus", "-b:a", "256k", cls.surround)
        ffmpeg("-f", "lavfi", "-i", tones, "-c:a", "vorbis", "-strict", "experimental", cls.vorbis)
        ffmpeg("-f", "lavfi", "-i", "testsrc2=size=160x90:rate=25:duration=12", "-f", "lavfi", "-i", tones,
               "-c:v", "libx264", "-g", "25", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", cls.movie)
        cls.decoder = cls.root / "decode-audio"
        run(["swiftc", "-suppress-warnings", "-parse-as-library",
             Path(__file__).with_name("DecodeAudio.swift"), "-o", cls.decoder])

    def cli(self, *args, ok=True, env=None, stdin=None):
        result = subprocess.run([CLI, *map(str, args)], capture_output=True, text=True, timeout=120,
                                env=env, input=stdin)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def export(self, source, name, *options, cuts=CUTS, ok=True, dry_run=False, env=None):
        output = self.root / name
        clips = []
        for start, end in cuts:
            clips += ["--clip", source, "--from", start, "--to", end]
        flags = ["--dry-run"] if dry_run else []
        report = self.cli("export", "clips", "join", "--json", "--no-sidecar", *flags, "--mode", "encode", *options,
                          "--output", output, *clips, ok=ok, env=env)
        return output, report

    def stream(self, path):
        return probe(path, "-select_streams", "a:0", "-show_streams")["streams"][0]

    def assert_no_staging(self):
        self.assertFalse(any(self.root.glob(".mpcut-*")))
        self.assertFalse(any(self.root.glob("*.raw")))

    def assert_speakers(self, path, frames=None, level=True, tones=SPEAKER_TONES, mask=SPEAKER_MASK):
        """Each channel carries the tone of its own speaker and no other, on both sides of the join."""
        wave = Wave(path)
        self.assertEqual((wave.channels, wave.mask), (len(tones), mask), path.name)
        if frames is not None:
            self.assertEqual(wave.frames, frames, path.name)
        for start in (48_000, wave.frames - 60_000):
            for channel, tone in enumerate(tones):
                powers = tone_powers(wave.window(channel, start, 12_000), tones)
                others = max(power for index, power in enumerate(powers) if index != channel)
                self.assertLess(others, powers[channel] / 1000, (path.name, start, channel, tone, powers))
                if level:
                    # A sine of amplitude 0.3 has this power at its own frequency.
                    self.assertLess(abs(powers[channel] - 0.0225), 0.003, (path.name, start, channel, tone, powers))

    def decoded_wave(self, path):
        output = self.root / (path.name + ".decoded.wav")
        ffmpeg("-i", path, "-c:a", "pcm_s16le", output)
        return output

    def layout(self, path, *flags):
        stream = self.cli("media", "inspect", "--json", *flags, path)["media"]["streams"]
        return next((item["channels"], item["channel_layout"]) for item in stream if item["kind"] == "audio")

    def test_mp3_join_converts_to_exact_pcm_and_matches_dry_run(self):
        output = self.root / "copy.mp3"
        clips = [item for start, end in CUTS for item in ("--clip", self.mp3, "--from", start, "--to", end)]
        refused = self.cli("export", "clips", "join", "--json", "--no-sidecar", "--dry-run", "--output", output, *clips, ok=False)
        self.assertEqual(refused["error"]["code"], "unsafe_boundary")

        _, planned = self.export(self.mp3, "join.wav", "--audio", "pcm", dry_run=True)
        self.assertFalse((self.root / "join.wav").exists())
        result, report = self.export(self.mp3, "join.wav", "--audio", "pcm")
        self.assertEqual({**planned, "dry_run": False}, report)
        self.assertEqual((report["mode"], report["tracks"], report["container"]), ("encode", "audio", "wav"))
        action = report["audio_actions"][0]
        self.assertEqual((action["action"], action["codec"], action["bit_depth"]), ("pcm", "pcm_s24le", 24))
        self.assertEqual([s["track_actions"][0]["action"] for s in report["segments"]], ["encode", "encode"])
        self.assertEqual(self.stream(result)["codec_name"], "pcm_s24le")
        expected = kept(pcm16(self.mp3), CUTS)
        decoded = pcm16(result)
        self.assertEqual(len(decoded), len(expected))
        self.assertEqual(Fraction(report["duration"]["numerator"], report["duration"]["denominator"]),
                         Fraction(len(expected) // 2, RATE))
        # The MP3 decoder produces floating-point samples. Allow one 16-bit step for their rounding.
        self.assertLessEqual(difference(decoded, expected), 1)
        self.assertEqual(result.stat().st_mode & 0o777, 0o666 & ~self.umask())
        self.assert_no_staging()

    @staticmethod
    def umask():
        mask = os.umask(0)
        os.umask(mask)
        return mask

    def test_reordered_and_repeated_ranges_keep_their_samples(self):
        cuts = [("9", "11.5"), ("1", "3"), ("9", "10")]
        result, _ = self.export(self.mp3, "reordered.wav", "--audio", "pcm", cuts=cuts)
        expected = kept(pcm16(self.mp3), cuts)
        decoded = pcm16(result)
        self.assertEqual(len(decoded), len(expected))
        self.assertLessEqual(difference(decoded, expected), 1)

    def test_auto_keeps_mp3_at_the_source_bit_rate_with_exact_gapless_length(self):
        result, report = self.export(self.mp3, "join.mp3")
        action = report["audio_actions"][0]
        self.assertEqual((report["mode"], report["container"], report["audio"]), ("encode", "mp3", "auto"))
        self.assertEqual((action["action"], action["codec"], action["bit_rate"]), ("mp3", "mp3", 128_000))
        # Auto applied the first alternative of the shared ladder that fits .mp3.
        self.assertEqual(report["applied"], "convert_same_format")
        self.assertTrue(any("128 kbps" in warning for warning in report["warnings"]))
        written = self.stream(result)
        source = self.stream(self.mp3)
        self.assertEqual((written["codec_name"], written["sample_rate"], written["channels"], written["bit_rate"]),
                         ("mp3", source["sample_rate"], source["channels"], "128000"))
        expected = kept(pcm16(self.mp3), CUTS)
        decoded = pcm16(result)
        # The Info header records the encoder delay and padding, so decoding returns exactly the kept samples.
        self.assertEqual(len(decoded), len(expected))
        self.assertGreater(snr(decoded, expected), 100)
        # The join is no worse than the rest of the encode: no click beyond the edit itself.
        join = (samples(CUTS[0][1]) - samples(CUTS[0][0])) * 2
        window = slice(join - 1024, join + 1024)
        whole = sum((a - b) * (a - b) for a, b in zip(decoded, expected)) / len(expected)
        local = sum((a - b) * (a - b) for a, b in zip(decoded[window], expected[window])) / 2048
        self.assertLess(local, 16 * whole + 4)
        self.assertEqual(self.cli("media", "inspect", "--json", "--no-sidecar", result)["media"]["duration"], report["duration"])

    def test_variable_rate_mp3_reports_the_lame_setting_it_uses(self):
        _, planned = self.export(self.vbr, "variable-join.mp3", dry_run=True)
        result, report = self.export(self.vbr, "variable-join.mp3")
        self.assertEqual({**planned, "dry_run": False}, report)
        action = report["audio_actions"][0]
        self.assertEqual(action["action"], "mp3")
        self.assertIn(action["quality"], range(10))
        self.assertNotIn("bit_rate", action)
        self.assertTrue(any(f"LAME V{action['quality']}" in warning for warning in report["warnings"]))
        expected = kept(pcm16(self.vbr), CUTS)
        decoded = pcm16(result)
        self.assertEqual(len(decoded), len(expected))
        self.assertGreater(snr(decoded, expected), 50)
        source_rate = int(probe(self.vbr, "-show_format")["format"]["bit_rate"])
        written_rate = int(probe(result, "-show_format")["format"]["bit_rate"])
        self.assertLess(abs(written_rate - source_rate), source_rate * 0.4)

    def test_unavailable_copy_lists_the_ladder_and_each_alternative_resolves_as_listed(self):
        def refuse(source, name, cuts=CUTS):
            clips = [item for start, end in cuts for item in ("--clip", source, "--from", start, "--to", end)]
            return self.cli("export", "clips", "join", "--json", "--no-sidecar", "--dry-run", "--mode", "copy",
                            "--output", self.root / name, *clips, ok=False)["error"]

        error = refuse(self.mp3, "ladder.mp3")
        self.assertEqual(error["code"], "unsafe_boundary")
        offers = error["alternatives"]
        self.assertEqual([item["id"] for item in offers], ["convert_same_format", "convert_pcm", "convert_aac"])
        self.assertEqual([item["label"] for item in offers],
                         ["Convert to MP3 (same format)", "Convert to WAV (no further quality loss)",
                          "Convert to AAC (.m4a, smaller)"])
        self.assertEqual([(item["container"], item["lossless"]) for item in offers],
                         [("mp3", False), ("wav", False), ("m4a", False)])
        self.assertEqual(offers[0]["bit_rate"], 128_000)
        for item in offers:
            clips = [part for start, end in CUTS for part in ("--clip", self.mp3, "--from", start, "--to", end)]
            report = self.cli("export", "clips", "join", "--json", "--no-sidecar", "--dry-run", *item["arguments"],
                              "--output", self.root / ("offer." + item["container"]), *clips)
            action = report["audio_actions"][0]
            self.assertEqual((report["mode"], report["container"], action["action"], action.get("bit_rate")),
                             (item["mode"], item["container"], item["audio"], item.get("bit_rate")))

        # A cut between samples copies exactly once it sits on the sample clock. That ranks before any conversion.
        error = refuse(self.m4a, "ladder.m4a")
        first = error["alternatives"][0]
        self.assertEqual((first["id"], first["lossless"], first["mode"]), ("copy_sample_aligned", True, "copy"))
        self.assertEqual(first["label"], "Copy with cuts on the nearest audio sample (lossless)")
        self.assertIn("convert_same_format", [item["id"] for item in error["alternatives"]])
        clips = [part for clip in first["clips"] for part in ("--clip", clip["file"], "--from", clip["from"], "--to", clip["to"])]
        report = self.cli("export", "clips", "join", "--json", "--no-sidecar", "--dry-run", *first["arguments"],
                          "--output", self.root / "ladder.m4a", *clips)
        self.assertEqual(report["mode"], "copy")
        # FLAC cut inside its frames cannot be copied anywhere, so encoding FLAC again comes first.
        ids = [item["id"] for item in refuse(self.flac, "ladder.flac")["alternatives"]]
        self.assertEqual(ids[0], "convert_same_format")
        # A request that is wrong in itself has no alternatives.
        self.assertNotIn("alternatives", refuse(self.mp3, "ladder.mp3", cuts=[("5", "1")]))

    def test_lame_tag_supplies_the_variable_or_average_rate_setting(self):
        if shutil.which("lame") is None:
            self.skipTest("The LAME command is not installed.")
        wave = self.root / "tones.wav"
        ffmpeg("-f", "lavfi", "-i", TONES.format(rate=RATE, length=12), wave)
        for options, name, expected in [(["-V", "3"], "v3", {"quality": 3}),
                                        (["--abr", "150"], "abr", {"bit_rate": 150_000}),
                                        (["-b", "96"], "cbr", {"bit_rate": 96_000})]:
            with self.subTest(name=name):
                source = self.root / f"lame-{name}.mp3"
                run(["lame", "--quiet", "--resample", "44.1", *options, wave, source])
                result, report = self.export(source, f"lame-{name}-join.mp3")
                action = report["audio_actions"][0]
                self.assertEqual({key: action.get(key) for key in ("quality", "bit_rate")},
                                 {"quality": None, "bit_rate": None, **expected})
                self.assertEqual(len(pcm16(result)), len(kept(pcm16(source), CUTS)))

    def test_explicit_mp3_and_flac_convert_other_sources(self):
        result, report = self.export(self.opus, "from-opus.mp3", "--audio", "mp3")
        self.assertEqual(report["audio_actions"][0]["bit_rate"], 192_000)
        self.assertEqual(self.stream(result)["sample_rate"], "48000")
        self.assertEqual(len(pcm16(result)), len(kept(pcm16(self.opus), CUTS, rate=48_000)))
        result, report = self.export(self.mp3, "from-mp3.flac", "--audio", "flac")
        self.assertEqual((report["audio_actions"][0]["codec"], report["audio_actions"][0]["bit_depth"]), ("flac", 24))
        self.assertLessEqual(difference(pcm16(result), kept(pcm16(self.mp3), CUTS)), 1)

    def test_flac_join_stays_flac_and_decodes_bit_identical(self):
        result, report = self.export(self.flac, "join.flac")
        action = report["audio_actions"][0]
        self.assertEqual((report["mode"], action["action"], action["bit_depth"]), ("encode", "flac", 16))
        written = self.stream(result)
        self.assertEqual((written["codec_name"], written["sample_fmt"], written["sample_rate"], written["channels"]),
                         ("flac", "s16", "44100", 2))
        self.assertEqual(pcm16(result), kept(pcm16(self.flac), CUTS))

        result, report = self.export(self.flac24, "join24.flac")
        self.assertEqual(report["audio_actions"][0]["bit_depth"], 24)
        written = self.stream(result)
        self.assertEqual((written["sample_fmt"], written["bits_per_raw_sample"], written["channels"]), ("s32", "24", 1))
        self.assertEqual(pcm32(result), kept(pcm32(self.flac24), CUTS, rate=48_000, channels=1))

        # The same lossless samples as WAV keep the source word length.
        result, report = self.export(self.flac, "join-flac.wav")
        self.assertEqual(report["audio_actions"][0]["codec"], "pcm_s16le")
        self.assertEqual(pcm16(result), kept(pcm16(self.flac), CUTS))
        # Matroska carries the copied FLAC packets, so auto does not convert.
        _, report = self.export(self.flac, "join.mka", cuts=[("0", "12")])
        self.assertEqual((report["mode"], report["audio_actions"][0]["action"]), ("copy", "copy"))

    def test_auto_copies_when_copy_is_exact(self):
        # AAC in M4A carries sample-aligned joins through its edit list.
        result, report = self.export(self.m4a, "copied.m4a", cuts=[("1", "5.1"), ("9", "11.5")])
        self.assertEqual((report["mode"], report["audio"]), ("copy", "auto"))
        self.assertEqual(report["audio_actions"], [{"action": "copy", "track": 0}])
        self.assertNotIn("applied", report)
        self.assertEqual([s["track_actions"][0]["action"] for s in report["segments"]], ["copy"] * len(report["segments"]))
        self.assertTrue(result.exists())
        single = [("0", "6")]
        _, report = self.export(self.mp3, "prefix.mp3", cuts=single)
        self.assertEqual((report["mode"], report["audio_actions"][0]["action"]), ("copy", "copy"))
        _, refused = self.export(self.mp3, "copy-only.mp3", "--audio", "copy", ok=False)
        self.assertEqual(refused["error"]["code"], "audio_copy_unavailable")
        self.assertFalse((self.root / "copy-only.mp3").exists())

    def test_aac_conversion_keeps_parameters_and_sample_count(self):
        result, report = self.export(self.m4a, "encoded.m4a", "--audio", "aac")
        action = report["audio_actions"][0]
        self.assertEqual((report["mode"], action["action"], action["bit_rate"]), ("encode", "aac", 128_000))
        written = self.stream(result)
        self.assertEqual((written["codec_name"], written["sample_rate"], written["channels"]), ("aac", "44100", 2))
        self.assertLess(abs(int(written["bit_rate"]) - 128_000), 32_000)
        expected = kept(array("h", run([self.decoder, self.m4a])), CUTS)
        decoded = array("h", run([self.decoder, result]))
        self.assertEqual(len(decoded), len(expected))
        self.assertGreater(snr(decoded[8192:], expected[8192:]), 50)
        # ffmpeg applies the same edit list, so both readers agree on the length.
        self.assertEqual(len(pcm16(result)), len(expected))

        # A cut between samples is placed on the sample clock, where the copy is exact.
        _, report = self.export(self.m4a, "between-samples.m4a")
        self.assertEqual((report["mode"], report["audio_actions"][0]["action"]), ("copy", "copy"))
        self.assertTrue(any("nearest audio sample" in warning for warning in report["warnings"]))
        self.assertEqual(Fraction(report["duration"]["numerator"], report["duration"]["denominator"]),
                         Fraction(len(kept(pcm16(self.m4a), CUTS)) // 2, RATE))
        # The decoded AAC ranges are the PCM that a conversion writes.
        result, _ = self.export(self.m4a, "aac-join.wav", "--audio", "pcm")
        reference = kept(pcm16(self.m4a), CUTS)
        decoded = pcm16(result)
        self.assertEqual(len(decoded), len(reference))
        self.assertLessEqual(difference(decoded, reference), 1)
        # The index records the size of a movie soundtrack's packets, so AAC keeps the 96 kbps of the source.
        movie = self.root / "aac-movie.mp4"
        ffmpeg("-i", self.movie, "-c:v", "copy", "-c:a", "aac", "-b:a", "96k", movie)
        _, report = self.export(movie, "aac-movie.m4a", "--tracks", "audio", "--audio", "aac", dry_run=True)
        self.assertEqual(report["audio_actions"][0]["bit_rate"], 96_000)
        # A raw ADTS stream copies into M4A, whose edit list carries the joins.
        _, report = self.export(self.adts, "adts.m4a", cuts=[("1", "5.1"), ("9", "11.5")])
        self.assertEqual(report["mode"], "copy")
        # Another codec written to M4A becomes AAC at the default rate for its channels.
        result, report = self.export(self.mp3, "mp3-as.m4a")
        self.assertEqual((report["audio_actions"][0]["action"], report["audio_actions"][0]["bit_rate"]), ("aac", 192_000))
        self.assertEqual(len(array("h", run([self.decoder, result]))), len(kept(pcm16(self.mp3), CUTS)))

    def test_opus_join_stays_opus_at_the_source_average_rate(self):
        _, planned = self.export(self.steady, "join.opus", dry_run=True)
        self.assertFalse((self.root / "join.opus").exists())
        result, report = self.export(self.steady, "join.opus")
        self.assertEqual({**planned, "dry_run": False}, report)
        action = report["audio_actions"][0]
        self.assertEqual((report["mode"], report["container"], report["audio"]), ("encode", "opus", "auto"))
        self.assertEqual(report["applied"], "convert_same_format")
        # An Opus stream states no rate. The size of the source's packets gives 80 kbps.
        self.assertEqual((action["action"], action["codec"], action["bit_rate"]), ("opus", "opus", 80_000))
        self.assertTrue(any("Opus is encoded at 80 kbps. The source averages 8" in warning for warning in report["warnings"]))
        written = self.stream(result)
        self.assertEqual((written["codec_name"], written["sample_rate"], written["channels"]), ("opus", "48000", 2))
        # The rate is held, so the file is the size the plan reports.
        written_rate = int(probe(result, "-show_format")["format"]["bit_rate"])
        self.assertLess(abs(written_rate - 80_000), 8_000)
        expected = kept(pcm16(self.steady), CUTS, rate=48_000)
        decoded = pcm16(result)
        # OpusHead records the encoder's pre-skip and the last page ends the stream, so decoding returns exactly
        # the kept samples. A displacement of one sample lowers this ratio below 100.
        self.assertEqual(len(decoded), len(expected))
        self.assertGreater(snr(decoded, expected), 1000)
        self.assertEqual(Fraction(report["duration"]["numerator"], report["duration"]["denominator"]),
                         Fraction(len(expected) // 2, 48_000))
        self.assertEqual(self.cli("media", "inspect", "--json", "--no-sidecar", result)["media"]["duration"], report["duration"])
        self.assert_no_staging()

        # A variable-rate source is matched at the customary rate nearest its average.
        average = self.opus.stat().st_size * 8 / 12
        _, report = self.export(self.opus, "variable-join.opus", dry_run=True)
        rate = report["audio_actions"][0]["bit_rate"]
        self.assertIn(rate // 1000, (8, 12, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 510))
        self.assertLess(abs(rate - average), 0.15 * average)
        # A rate below the floor for two channels is raised to it, and one above the ceiling is lowered.
        for name, options, expected_rate in [("low", ["-b:a", "8k"], 24_000), ("high", ["-b:a", "500k", "-vbr", "off"], 510_000)]:
            source = self.root / f"{name}.opus"
            ffmpeg("-f", "lavfi", "-i", TONES.format(rate=48_000, length=12), "-c:a", "libopus", *options, source)
            _, report = self.export(source, f"{name}-join.opus", dry_run=True)
            self.assertEqual(report["audio_actions"][0]["bit_rate"], expected_rate, name)

    def test_opus_conversion_keeps_its_container_and_lists_the_ladder(self):
        clips = [item for start, end in CUTS for item in ("--clip", self.steady, "--from", start, "--to", end)]
        error = self.cli("export", "clips", "join", "--json", "--no-sidecar", "--dry-run", "--mode", "copy",
                         "--output", self.root / "ladder.opus", *clips, ok=False)["error"]
        offers = error["alternatives"]
        self.assertEqual([item["id"] for item in offers], ["convert_same_format", "convert_pcm", "convert_aac"])
        self.assertEqual(offers[0]["label"], "Convert to Opus (same format)")
        self.assertEqual((offers[0]["container"], offers[0]["lossless"], offers[0]["audio"], offers[0]["bit_rate"]),
                         ("opus", False, "opus", 80_000))
        for item in offers:
            report = self.cli("export", "clips", "join", "--json", "--no-sidecar", "--dry-run", *item["arguments"],
                              "--output", self.root / ("opus-offer." + item["container"]), *clips)
            action = report["audio_actions"][0]
            self.assertEqual((report["mode"], report["container"], action["action"], action.get("bit_rate")),
                             (item["mode"], item["container"], item["audio"], item.get("bit_rate")))

        # Ogg, WebM and Matroska Audio carry the converted stream with the same samples.
        expected = kept(pcm16(self.steady), CUTS, rate=48_000)
        matroska = self.root / "sound.webm"
        ffmpeg("-i", self.steady, "-c", "copy", matroska)
        for source, name in [(self.steady, "opus-join.ogg"), (self.steady, "opus-join.webm"), (self.steady, "opus-join.mka"),
                             (matroska, "matroska-join.webm"), (matroska, "matroska-join.opus")]:
            with self.subTest(name=name):
                result, report = self.export(source, name)
                self.assertEqual((report["applied"], report["container"], report["audio_actions"][0]["action"]),
                                 ("convert_same_format", name.rsplit(".", 1)[1], "opus"))
                self.assertEqual(self.stream(result)["codec_name"], "opus")
                decoded = pcm16(result)
                self.assertEqual(len(decoded), len(expected))
                self.assertGreater(snr(decoded, expected), 1000)
        # A container that takes no Opus leaves the format in the source's own.
        clips = [item for start, end in CUTS for item in ("--clip", matroska, "--from", start, "--to", end)]
        error = self.cli("export", "clips", "join", "--json", "--no-sidecar", "--dry-run", "--mode", "copy",
                         "--output", self.root / "ladder.wav", *clips, ok=False)["error"]
        same = [item for item in error["alternatives"] if item["id"] == "convert_same_format"]
        self.assertEqual([(item["container"], item["audio"]) for item in same], [("webm", "opus")])

    def test_explicit_opus_resamples_other_rates_and_writes_the_surround_opus_states(self):
        # Opus decodes at 48 kHz whatever its encoder was given, so every other rate is resampled to it.
        low = self.root / "sixteen-kilohertz.wav"
        ffmpeg("-f", "lavfi", "-i", TONES.format(rate=16_000, length=12), low)
        for source, name, rate in [(self.mp3, "from-mp3.opus", RATE), (low, "from-16k.opus", 16_000)]:
            with self.subTest(name=name):
                _, planned = self.export(source, name, "--audio", "opus", dry_run=True)
                result, report = self.export(source, name, "--audio", "opus")
                self.assertEqual({**planned, "dry_run": False}, report)
                action = report["audio_actions"][0]
                self.assertEqual((action["action"], action["codec"], action["bit_rate"]), ("opus", "opus", 96_000))
                self.assertNotIn("applied", report)
                self.assertTrue(any("resampled to 48 kHz" in warning for warning in report["warnings"]))
                self.assertTrue(any("Opus is encoded at 96 kbps." == warning for warning in report["warnings"]))
                self.assertEqual(self.stream(result)["sample_rate"], "48000")
                duration = Fraction(report["duration"]["numerator"], report["duration"]["denominator"])
                self.assertEqual(duration, Fraction(len(kept(pcm16(source), CUTS, rate=rate)) // 2, rate))
                self.assertEqual(len(pcm16(result)) // 2, int(duration * 48_000 + Fraction(1, 2)))
        # A 48 kHz source keeps its samples, and one channel takes the lower default rate.
        mono = self.root / "mono.flac"
        ffmpeg("-f", "lavfi", "-i", "sine=f=330:r=48000:d=12", "-c:a", "flac", mono)
        result, report = self.export(mono, "from-mono.opus", "--audio", "opus")
        self.assertEqual(report["audio_actions"][0]["bit_rate"], 64_000)
        self.assertEqual(report["warnings"], ["Opus is encoded at 64 kbps."])
        self.assertEqual((self.stream(result)["channels"], len(pcm16(result))),
                         (1, len(kept(pcm16(mono), CUTS, rate=48_000, channels=1))))
        result, report = self.export(self.movie, "movie.opus", "--tracks", "audio", "--audio", "opus")
        self.assertEqual((report["tracks"], report["audio_actions"][0]["action"]), ("audio", "opus"))
        self.assertEqual(len(probe(result, "-show_streams")["streams"]), 1)

        # Opus states 5.1 through channel mapping family 1, at the libopus default rate for four streams and two pairs.
        _, planned = self.export(self.six, "from-wave.opus", "--audio", "opus", dry_run=True)
        result, report = self.export(self.six, "from-wave.opus", "--audio", "opus")
        self.assertEqual({**planned, "dry_run": False}, report)
        self.assertEqual(report["audio_actions"][0]["bit_rate"], 320_000)
        self.assertEqual(report["warnings"], ["Opus is encoded at 320 kbps."])
        self.assertEqual(opus_head(result), (6, 1))
        self.assertEqual(self.layout(result, "--no-sidecar"), (6, "5.1"))
        frames = sum(samples(end, 48_000) - samples(start, 48_000) for start, end in CUTS)
        self.assert_speakers(self.decoded_wave(result), frames)

        # Opus states no side-speaker 5.1, so that layout is refused before writing.
        side = self.root / "side.wav"
        ffmpeg("-i", self.six, "-af", "aformat=channel_layouts=5.1(side)", "-c:a", "pcm_s16le", side)
        self.assertEqual(self.layout(side, "--no-sidecar"), (6, "5.1(side)"))
        for dry_run in (True, False):
            _, refused = self.export(side, "side.opus", "--audio", "opus", ok=False, dry_run=dry_run)
            self.assertEqual(refused["error"]["code"], "unsupported_audio")
            self.assertIn("5.1, 6.1 or 7.1 sound. Choose PCM", refused["error"]["message"])
            self.assertFalse((self.root / "side.opus").exists())
        self.assert_no_staging()

    def test_surround_opus_converts_with_every_channel_in_its_place(self):
        # OpusHead names the speakers of a surround stream, in Ogg and in Matroska.
        matroska = self.root / "surround.mka"
        ffmpeg("-i", self.surround, "-c", "copy", matroska)
        self.assertEqual(opus_head(self.surround), (6, 1))
        self.assertEqual(self.layout(self.surround, "--no-sidecar"), (6, "5.1"))
        self.assertEqual(self.layout(matroska, "--no-sidecar"), (6, "5.1"))
        self.assert_speakers(self.six, 12 * 48_000)

        # A join cannot be copied. Every conversion on the ladder resolves as listed.
        clips = [item for start, end in CUTS for item in ("--clip", self.surround, "--from", start, "--to", end)]
        error = self.cli("export", "clips", "join", "--json", "--no-sidecar", "--dry-run", "--mode", "copy",
                         "--output", self.root / "surround-ladder.opus", *clips, ok=False)["error"]
        self.assertEqual(error["code"], "unsafe_boundary")
        offers = error["alternatives"]
        self.assertEqual([item["id"] for item in offers], ["convert_same_format", "convert_pcm", "convert_aac"])
        for item in offers:
            report = self.cli("export", "clips", "join", "--json", "--no-sidecar", "--dry-run", *item["arguments"],
                              "--output", self.root / ("surround-offer." + item["container"]), *clips)
            action = report["audio_actions"][0]
            self.assertEqual((report["mode"], report["container"], action["action"], action.get("bit_rate")),
                             (item["mode"], item["container"], item["audio"], item.get("bit_rate")))

        frames = sum(samples(end, 48_000) - samples(start, 48_000) for start, end in CUTS)
        for source, name in [(self.surround, "surround-join.wav"), (matroska, "matroska-surround-join.wav")]:
            with self.subTest(name=name):
                result, report = self.export(source, name)
                self.assertEqual((report["applied"], report["audio_actions"][0]["action"]), ("convert_pcm", "pcm"))
                self.assertEqual(self.stream(result)["channel_layout"], "5.1")
                # The WAVE file itself places each tone on its speaker.
                self.assert_speakers(result, frames)
        # CAF has one tag for 5.1 with back or side surrounds and reads it as the side layout.
        result, report = self.export(self.surround, "surround-join.caf", "--audio", "pcm")
        self.assertEqual(report["audio_actions"][0]["action"], "pcm")
        self.assertEqual(self.stream(result)["channel_layout"], "5.1(side)")
        self.assert_speakers(self.decoded_wave(result), frames, mask=0x60F)

        _, planned = self.export(self.surround, "surround-join.opus", dry_run=True)
        result, report = self.export(self.surround, "surround-join.opus")
        self.assertEqual({**planned, "dry_run": False}, report)
        action = report["audio_actions"][0]
        self.assertEqual((report["applied"], action["action"], action["codec"]), ("convert_same_format", "opus", "opus"))
        average = self.surround.stat().st_size * 8 / 12
        self.assertLess(abs(action["bit_rate"] - average), 0.15 * average)
        self.assertEqual(opus_head(result), (6, 1))
        self.assertEqual(self.layout(result, "--no-sidecar"), (6, "5.1"))
        self.assert_speakers(self.decoded_wave(result), frames)
        # Ogg, WebM and Matroska Audio state the same layout for the converted stream.
        for name in ("surround-join.ogg", "surround-join.webm", "surround-join.mka"):
            with self.subTest(name=name):
                result, report = self.export(self.surround, name)
                self.assertEqual((report["applied"], report["audio_actions"][0]["action"]), ("convert_same_format", "opus"))
                self.assertEqual(opus_head(result), (6, 1))
                self.assertEqual(self.layout(result, "--no-sidecar"), (6, "5.1"))
                self.assert_speakers(self.decoded_wave(result), frames)
        self.assert_no_staging()

    def test_every_surround_layout_opus_defines_keeps_its_channel_order(self):
        frames = sum(samples(end, 48_000) - samples(start, 48_000) for start, end in CUTS)
        # The helper's encoder misplaces 5.0 and 6.1 unless it is given the mapping family, so every layout is checked.
        for layout, (mask, tones, _) in SURROUND.items():
            with self.subTest(layout=layout):
                source = self.root / f"layout-{layout}.wav"
                ffmpeg("-f", "lavfi", "-i", six_tones(layout, tones), "-c:a", "pcm_s16le", source)
                self.assert_speakers(source, 12 * 48_000, tones=tones, mask=mask)
                self.assertEqual(self.layout(source, "--no-sidecar"), (len(tones), layout))
                result, _ = self.export(source, f"layout-{layout}.opus", "--audio", "opus")
                self.assertEqual(opus_head(result), (len(tones), 1))
                self.assertEqual(self.layout(result, "--no-sidecar"), (len(tones), layout))
                self.assert_speakers(self.decoded_wave(result), frames, tones=tones, mask=mask)
                # The written Opus converts on to PCM with the same speakers.
                back, _ = self.export(result, f"layout-{layout}-back.wav", "--audio", "pcm", cuts=[("1", "3"), ("4", "6")])
                self.assert_speakers(back, 4 * 48_000, tones=tones, mask=mask)

    def test_seven_point_one_pcm_writes_caf_with_every_speaker_in_its_place(self):
        mask, tones, _ = SURROUND["7.1"]
        frames = sum(samples(end, 48_000) - samples(start, 48_000) for start, end in CUTS)
        source = self.root / "caf-7.1.wav"
        ffmpeg("-f", "lavfi", "-i", six_tones("7.1", tones), "-c:a", "pcm_s16le", source)
        self.assert_speakers(source, 12 * 48_000, tones=tones, mask=mask)
        result, report = self.export(source, "caf-7.1.caf", "--audio", "pcm")
        self.assertEqual(report["audio_actions"][0]["action"], "pcm")
        # The 7.1 tag of CAF carries the side surrounds before the back ones, an order that has no layout name.
        self.assertEqual(self.layout(result, "--no-sidecar"), (8, "8 channels (FL+FR+FC+LFE+SL+SR+BL+BR)"))
        # The helper places the channels by name, and Core Audio reads the same speakers from the tag.
        named = self.root / "caf-7.1.named.wav"
        ffmpeg("-i", result, "-af", "aformat=channel_layouts=7.1", "-c:a", "pcm_s16le", named)
        self.assert_speakers(named, frames, tones=tones, mask=mask)
        apple = self.root / "caf-7.1.apple.wav"
        run(["afconvert", "-f", "WAVE", "-d", "LEI16", "-l", "WAVE_7_1", result, apple])
        self.assert_speakers(apple, frames, tones=tones, mask=mask)
        self.assert_no_staging()

    def test_opus_without_stated_speakers_stays_refused(self):
        # Channel mapping family 255 gives six channels and no speakers. No layout is assumed for them.
        unnamed = self.root / "unnamed.opus"
        ffmpeg("-i", self.six, "-c:a", "libopus", "-mapping_family", "255", unnamed)
        self.assertEqual(opus_head(unnamed), (6, 255))
        self.assertEqual(self.layout(unnamed, "--no-sidecar"), (6, "6 channels"))
        for name, options in [("unnamed.wav", ["--audio", "pcm"]), ("unnamed-join.opus", ["--audio", "opus"]),
                              ("unnamed.m4a", ["--audio", "aac"])]:
            for dry_run in (True, False):
                with self.subTest(name=name, dry_run=dry_run):
                    _, refused = self.export(unnamed, name, *options, ok=False, dry_run=dry_run)
                    self.assertEqual(refused["error"]["code"], "unsupported_audio")
                    self.assertIn("unspecified or unsupported channel layout", refused["error"]["message"])
                    self.assertFalse((self.root / name).exists())
        _, refused = self.export(unnamed, "unnamed-auto.opus", ok=False, dry_run=True)
        self.assertEqual(refused["error"].get("alternatives", []), [])
        self.assert_no_staging()

    def test_surround_vorbis_reports_its_layout_and_converts_in_place(self):
        if shutil.which("sox") is None:
            self.skipTest("SoX is not installed to write surround Vorbis.")
        # SoX writes its channels in the order Vorbis codes them, with an encoder that is not FFmpeg's.
        frames = sum(samples(end, 48_000) - samples(start, 48_000) for start, end in CUTS)
        for layout, (mask, tones, coded) in SURROUND.items():
            with self.subTest(layout=layout):
                source = self.root / f"surround-{layout}.ogg"
                synth = [part for index in coded for part in ("sine", str(tones[index]))]
                run(["sox", "-n", "-r", "48000", "-c", str(len(tones)), source, "synth", "12", *synth, "vol", "0.3"],
                    allow_diagnostics=True)
                self.assertEqual(self.stream(source)["codec_name"], "vorbis")
                self.assertEqual(self.layout(source, "--no-sidecar"), (len(tones), layout))
                result, report = self.export(source, f"vorbis-{layout}-join.wav")
                self.assertEqual((report["applied"], report["audio_actions"][0]["action"]), ("convert_pcm", "pcm"))
                self.assert_speakers(result, frames, level=False, tones=tones, mask=mask)

    def test_opus_and_vorbis_joins_convert_to_pcm_or_aac(self):
        # Vorbis has no encoder in the helper, so its own extension has no conversion.
        _, refused = self.export(self.vorbis, "same.ogg", ok=False)
        self.assertEqual(refused["error"]["code"], "unsupported_container")
        self.assertIn(".wav", refused["error"]["message"])
        self.assertIn(".m4a", refused["error"]["message"])
        for source, rate in [(self.opus, 48_000), (self.vorbis, RATE)]:
            with self.subTest(source=source.name):
                name = source.suffix[1:]
                result, report = self.export(source, name + "-join.wav")
                self.assertEqual(report["audio_actions"][0]["action"], "pcm")
                expected = kept(pcm16(source), CUTS, rate=rate)
                decoded = pcm16(result)
                self.assertEqual(len(decoded), len(expected))
                self.assertLessEqual(difference(decoded, expected), 1)
                result, report = self.export(source, name + "-join.m4a")
                self.assertEqual(report["audio_actions"][0]["action"], "aac")
                self.assertEqual(len(array("h", run([self.decoder, result]))), len(expected))

    def test_movie_soundtrack_converts_with_tracks_audio(self):
        result, report = self.export(self.movie, "movie.mp3", "--tracks", "audio", "--audio", "mp3")
        self.assertEqual((report["tracks"], report["audio_actions"][0]["action"]), ("audio", "mp3"))
        expected = kept(pcm16(self.movie), CUTS)
        decoded = pcm16(result)
        self.assertEqual(len(decoded), len(expected))
        self.assertGreater(snr(decoded, expected), 100)
        self.assertEqual(self.stream(result)["codec_name"], "mp3")
        self.assertEqual(len(probe(result, "-show_streams")["streams"]), 1)
        result, _ = self.export(self.movie, "movie.flac", "--tracks", "audio", "--audio", "flac")
        self.assertEqual(pcm16(result), expected)
        # A movie without a track selection keeps the video re-encode contract.
        _, refused = self.export(self.movie, "movie-all.mp3", "--audio", "mp3", ok=False)
        self.assertEqual(refused["error"]["code"], "unsupported_container")
        _, refused = self.export(self.movie, "movie-all.mov", "--audio", "mp3", ok=False)
        self.assertEqual(refused["error"]["code"], "unsupported_audio")
        _, refused = self.export(self.movie, "movie-video.mov", "--tracks", "video", ok=False)
        self.assertEqual(refused["error"]["code"], "invalid_arguments")

    def test_movie_soundtrack_keeps_the_average_rate_of_its_own_packets(self):
        # A soundtrack shares its file with the picture, so its rate is measured from its own packets.
        opus = self.root / "opus-movie.mkv"
        aac = self.root / "aac-movie.mkv"
        ffmpeg("-i", self.movie, "-c:v", "copy", "-c:a", "libopus", "-b:a", "80k", "-vbr", "off", opus)
        ffmpeg("-i", self.movie, "-c:v", "copy", "-c:a", "aac", "-b:a", "96k", aac)
        _, planned = self.export(opus, "movie-join.opus", "--tracks", "audio", dry_run=True)
        result, report = self.export(opus, "movie-join.opus", "--tracks", "audio")
        self.assertEqual({**planned, "dry_run": False}, report)
        action = report["audio_actions"][0]
        self.assertEqual((report["applied"], action["action"], action["bit_rate"]), ("convert_same_format", "opus", 80_000))
        self.assertIn("Opus is encoded at 80 kbps. The source averages 80 kbps.", report["warnings"])
        self.assertLess(abs(int(probe(result, "-show_format")["format"]["bit_rate"]) - 80_000), 8_000)
        _, report = self.export(aac, "movie-join.m4a", "--tracks", "audio", "--audio", "aac", dry_run=True)
        self.assertEqual(report["audio_actions"][0]["bit_rate"], 96_000)
        # An MP3 soundtrack has no tag to read. It is encoded at the average rate of its packets.
        mp3 = self.root / "mp3-movie.mkv"
        ffmpeg("-i", self.movie, "-c:v", "copy", "-c:a", "libmp3lame", "-b:a", "128k", mp3)
        _, planned = self.export(mp3, "movie-join.mp3", "--tracks", "audio", dry_run=True)
        result, report = self.export(mp3, "movie-join.mp3", "--tracks", "audio")
        self.assertEqual({**planned, "dry_run": False}, report)
        action = report["audio_actions"][0]
        self.assertEqual((report["applied"], action["action"], action["bit_rate"]), ("convert_same_format", "mp3", 128_000))
        self.assertIn("MP3 is encoded at the source's average 128 kbps (ABR).", report["warnings"])
        # LAME holds an average loosely over a few seconds of sound.
        self.assertLess(abs(int(probe(result, "-show_format")["format"]["bit_rate"]) - 128_000), 26_000)
        self.assertEqual(len(pcm16(result)), len(kept(pcm16(mp3), CUTS)))
        # A soundtrack in another codec has no rate to keep.
        _, report = self.export(self.movie, "pcm-movie.opus", "--tracks", "audio", "--audio", "opus", dry_run=True)
        self.assertEqual(report["audio_actions"][0]["bit_rate"], 96_000)
        _, report = self.export(self.movie, "pcm-movie.m4a", "--tracks", "audio", "--audio", "aac", dry_run=True)
        self.assertEqual(report["audio_actions"][0]["bit_rate"], 192_000)

    def index_header(self, source, change=None):
        """The saved index header of a source. `change` edits it in place, as an earlier build's index."""
        key = "media_index.v1"
        with sqlite3.connect(str(source) + ".cutdb") as db:
            value = section_bytes(db, key)
            header = plistlib.loads(value)
            if change is not None:
                change(header)
                stamp, = db.execute("SELECT stamp FROM source").fetchone()
                value = plistlib.dumps(header, fmt=plistlib.FMT_BINARY)
                # A section's digest covers the source stamp, its own name and its bytes.
                digest = hashlib.sha256(stamp.encode() + b"\0" + key.encode() + b"\0" + value).digest()
                db.execute("UPDATE sections SET logical_size=0, value=?, digest=? WHERE name=?", (value, digest, key))
        return header

    def test_saved_index_gives_the_same_layout_and_rate_as_a_fresh_one(self):
        folder = self.root / "indexed"
        folder.mkdir()
        surround = folder / "surround.opus"
        aac = folder / "aac-movie.mp4"
        opus = folder / "opus-movie.mkv"
        shutil.copyfile(self.surround, surround)
        ffmpeg("-i", self.movie, "-c:v", "copy", "-c:a", "aac", "-b:a", "96k", aac)
        ffmpeg("-i", self.movie, "-c:v", "copy", "-c:a", "libopus", "-b:a", "80k", "-vbr", "off", opus)

        def rate(source, audio, *flags):
            clips = [item for start, end in CUTS for item in ("--clip", source, "--from", start, "--to", end)]
            extension = "m4a" if audio == "aac" else "opus"
            report = self.cli("export", "clips", "join", "--json", *flags, "--dry-run", "--mode", "encode", "--tracks", "audio",
                              "--audio", audio, "--output", folder / f"planned.{extension}", *clips)
            return report["audio_actions"][0]["bit_rate"]

        for source, audio, known in [(surround, "opus", None), (aac, "aac", 96_000), (opus, "opus", 80_000)]:
            with self.subTest(source=source.name):
                saved = Path(str(source) + ".cutdb")
                fresh = (self.layout(source, "--no-sidecar"), rate(source, audio, "--no-sidecar"))
                self.assertFalse(saved.exists())
                if known is None:
                    self.assertEqual(fresh[0], (6, "5.1"))
                else:
                    self.assertEqual(fresh[1], known)
                # The first run saves the index and the second reads it.
                first = (self.layout(source), rate(source, audio))
                self.assertTrue(saved.exists())
                track = self.index_header(source)["audio"][0]
                self.assertGreater(track["coded_bytes"], 0)
                second = (self.layout(source), rate(source, audio))
                self.assertEqual((first, second), (fresh, fresh))

        # The rate comes from the saved size: doubling it there doubles the rate that is matched.
        def double(header): header["audio"][0]["coded_bytes"] *= 2
        self.index_header(aac, double)
        self.assertEqual(rate(aac, "aac"), 192_000)
        self.assertEqual(rate(aac, "aac", "--no-sidecar"), 96_000)

        # An index of surround Opus from before the layout was read is indexed again.
        def earlier(header):
            header["probe_revision"] = 6
            for stream in header["streams"]:
                if stream["info"]["codec"] == "opus" and stream["info"]["channels"] > 2:
                    stream["info"]["channel_layout"] = f"{stream['info']['channels']} channels"
            for track in header["audio"]:
                track.pop("coded_bytes", None)
        self.index_header(surround, earlier)
        self.assertEqual(self.layout(surround), (6, "5.1"))
        renewed = self.index_header(surround)
        self.assertEqual((renewed["probe_revision"], renewed["streams"][0]["info"]["channel_layout"]), (7, "5.1"))
        self.assertGreater(renewed["audio"][0]["coded_bytes"], 0)
        # Every retired probe revision is rebuilt, including ordinary AAC movies.
        self.index_header(aac, earlier)
        self.assertEqual(rate(aac, "aac"), 96_000)
        self.assertEqual(self.index_header(aac)["probe_revision"], 7)

    def test_wrong_extension_and_settings_are_structured_errors(self):
        for options, name, code, words in [
            (["--audio", "pcm"], "wrong.m4a", "unsupported_container", [".wav"]),
            (["--audio", "aac"], "wrong.wav", "unsupported_container", [".m4a"]),
            (["--audio", "mp3"], "wrong.wav", "unsupported_container", [".mp3"]),
            (["--audio", "flac"], "wrong.mp3", "unsupported_container", [".flac"]),
            (["--audio", "opus"], "wrong.wav", "unsupported_container", ["Opus conversion", ".opus, .ogg, .webm, .mka"]),
            ([], "wrong.xyz", "unsupported_container", [".wav", ".m4a", ".mp3"]),
            ([], "no-extension", "unsupported_container", [".wav", ".m4a", ".mp3", ".flac", ".opus"]),
            (["--audio", "remove"], "wrong.wav", "invalid_arguments", []),
            (["--video", "h264"], "wrong.mp4", "invalid_arguments", []),
        ]:
            with self.subTest(name=name, options=options):
                for dry_run in (True, False):
                    _, report = self.export(self.mp3, name, *options, ok=False, dry_run=dry_run)
                    self.assertEqual(report["error"]["code"], code, report)
                    for word in words:
                        self.assertIn(word, report["error"]["message"])
                    self.assertFalse((self.root / name).exists())
        self.assert_no_staging()

    def test_existing_output_is_preserved(self):
        existing = self.root / "existing.wav"
        existing.write_bytes(b"keep")
        for dry_run in (True, False):
            _, report = self.export(self.mp3, existing.name, ok=False, dry_run=dry_run)
            self.assertEqual(report["error"]["code"], "output_exists")
        self.assertEqual(existing.read_bytes(), b"keep")
        self.assert_no_staging()

    def test_stdin_and_bulk_requests_accept_the_same_fields(self):
        request = {"output": str(self.root / "request.mp3"), "mode": "encode", "audio": "mp3",
                   "clips": [{"file": str(self.mp3), "from": start, "to": end} for start, end in CUTS]}
        report = self.cli("export", "clips", "join", "--json", "--stdin", "--no-sidecar", stdin=json.dumps(request))
        self.assertEqual(report["audio_actions"][0]["bit_rate"], 128_000)
        self.assertEqual(len(pcm16(self.root / "request.mp3")), len(kept(pcm16(self.mp3), CUTS)))

        folder = self.root / "bulk"
        folder.mkdir()
        bulk = {"file": str(self.mp3), "output_directory": str(folder), "mode": "encode", "audio": "pcm",
                "container": "wav", "ranges": [{"from": "1", "to": "2"}, {"from": "9", "to": "11.5"}]}
        planned = self.cli("export", "ranges", "separate", "--json", "--stdin", "--no-sidecar", "--dry-run", stdin=json.dumps(bulk))
        self.assertEqual(list(folder.iterdir()), [])
        report = self.cli("export", "ranges", "separate", "--json", "--stdin", "--no-sidecar", stdin=json.dumps(bulk))
        self.assertEqual([{**item, "dry_run": False} for item in planned["outputs"]], report["outputs"])
        decoded = pcm16(self.mp3)
        for item, cut in zip(report["outputs"], [("1", "2"), ("9", "11.5")]):
            self.assertEqual((item["mode"], item["audio_actions"][0]["action"]), ("encode", "pcm"))
            self.assertLessEqual(difference(pcm16(Path(item["output"])), kept(decoded, [cut])), 1)
        # A range that cannot be copied lists the same alternatives as a single export.
        joined = {"file": str(self.mp3), "output_directory": str(folder), "mode": "copy", "container": "wav",
                  "tracks": "audio", "ranges": [{"from": "1", "to": "2"}]}
        refused = self.cli("export", "ranges", "separate", "--json", "--stdin", "--no-sidecar", "--dry-run", stdin=json.dumps(joined), ok=False)
        self.assertEqual([item["id"] for item in refused["error"]["alternatives"]][-2:], ["convert_pcm", "convert_aac"])
        # Without a container, auto keeps the source format of each range.
        del bulk["container"], bulk["audio"]
        bulk["ranges"] = [{"from": "1", "to": "2"}]
        report = self.cli("export", "ranges", "separate", "--json", "--stdin", "--no-sidecar", "--dry-run", stdin=json.dumps(bulk))
        self.assertEqual(report["outputs"][0]["container"], "mp3")

    def test_interrupt_leaves_no_partial_or_staging_files(self):
        source = self.root / "long.mp3"
        ffmpeg("-f", "lavfi", "-i", "sine=f=330:r=22050:d=2400", "-c:a", "libmp3lame", "-b:a", "32k", source)
        for name in ("cancelled.wav", "cancelled.mp3"):
            with self.subTest(name=name):
                output = self.root / name
                args = [CLI, "export", "clips", "join", "--json", "--no-sidecar", "--mode", "encode", "--output", output,
                        "--clip", source, "--from", "1", "--to", "1100", "--clip", source, "--from", "1200"]
                with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                    try:
                        deadline = time.monotonic() + 30
                        while time.monotonic() < deadline:
                            if any(self.root.glob(".mpcut-audio-*/*.raw")):
                                process.send_signal(signal.SIGINT)
                                break
                            self.assertIsNone(process.poll())
                            time.sleep(0.002)
                        else:
                            self.fail("No staged audio appeared")
                        stdout, stderr = process.communicate(timeout=30)
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.wait()
                self.assertEqual(process.returncode, 130, stdout + stderr)
                self.assertFalse(output.exists())
                self.assert_no_staging()

    def test_helper_without_the_encoder_is_refused_before_writing(self):
        # Stand in for an earlier helper: the same program, reporting no MP3, FLAC or Opus encoder.
        built = Path(__file__).resolve().parents[2] / ".build/mpcut-ffmpeg/install/bin/ffmpeg"
        real = Path(os.environ.get("MPCUT_FFMPEG_HELPER", built))
        if not real.exists():
            self.skipTest("The FFmpeg helper is not built.")
        old = self.root / "earlier helper" / "ffmpeg"
        old.parent.mkdir()
        old.write_text('#!/bin/sh\ncase " $* " in\n  *" -encoders "*) "%s" "$@" | grep -v -e libmp3lame -e " flac " -e libopus; exit 0 ;;\n'
                       'esac\nexec "%s" "$@"\n' % (real, real))
        old.chmod(0o755)
        env = dict(os.environ, MPCUT_FFMPEG_HELPER=str(old))
        for dry_run in (True, False):
            # A named format is refused. Auto skips the rung and lists the alternatives that still work.
            _, report = self.export(self.mp3, "old-helper.mp3", "--audio", "mp3", ok=False, dry_run=dry_run, env=env)
            self.assertEqual(report["error"]["code"], "encoder_unavailable")
            _, report = self.export(self.flac, "old-helper.flac", "--audio", "flac", ok=False, dry_run=dry_run, env=env)
            self.assertEqual(report["error"]["code"], "encoder_unavailable")
            _, report = self.export(self.steady, "old-helper.opus", "--audio", "opus", ok=False, dry_run=dry_run, env=env)
            self.assertEqual(report["error"]["code"], "encoder_unavailable")
            self.assertIn("no Opus encoder", report["error"]["message"])
            for source, name in [(self.mp3, "old-helper.mp3"), (self.steady, "old-helper.opus")]:
                _, report = self.export(source, name, ok=False, dry_run=dry_run, env=env)
                self.assertEqual(report["error"]["code"], "unsupported_container")
                self.assertEqual([item["id"] for item in report["error"]["alternatives"]], ["convert_pcm", "convert_aac"])
                self.assertFalse((self.root / name).exists())
        # The same helper still converts to PCM.
        result, report = self.export(self.mp3, "old-helper.wav", env=env)
        self.assertEqual(report["audio_actions"][0]["action"], "pcm")
        self.assertLessEqual(difference(pcm16(result), kept(pcm16(self.mp3), CUTS)), 1)
        self.assert_no_staging()


if __name__ == "__main__":
    args = argparse.ArgumentParser()
    args.add_argument("mpcut", type=Path)
    options, remaining = args.parse_known_args()
    CLI = options.mpcut.resolve()
    unittest.main(argv=[__file__, *remaining])
