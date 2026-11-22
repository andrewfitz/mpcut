#!/usr/bin/env python3
"""Verify sound-only conversion of ordinary edits with real decoded output."""
import argparse
from array import array
from fractions import Fraction
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

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
        report = self.cli("export", "--json", "--no-sidecar", *flags, "--mode", "encode", *options,
                          "--output", output, *clips, ok=ok, env=env)
        return output, report

    def stream(self, path):
        return probe(path, "-select_streams", "a:0", "-show_streams")["streams"][0]

    def assert_no_staging(self):
        self.assertFalse(any(self.root.glob(".mpcut-*")))
        self.assertFalse(any(self.root.glob("*.raw")))

    def test_mp3_join_converts_to_exact_pcm_and_matches_dry_run(self):
        output = self.root / "copy.mp3"
        clips = [item for start, end in CUTS for item in ("--clip", self.mp3, "--from", start, "--to", end)]
        refused = self.cli("export", "--json", "--no-sidecar", "--dry-run", "--output", output, *clips, ok=False)
        self.assertEqual(refused["error"]["code"], "unsafe_boundary")

        _, planned = self.export(self.mp3, "join.wav", "--audio", "pcm", dry_run=True)
        self.assertFalse((self.root / "join.wav").exists())
        result, report = self.export(self.mp3, "join.wav", "--audio", "pcm")
        self.assertEqual({**planned, "dryRun": False}, report)
        self.assertEqual((report["mode"], report["tracks"], report["container"]), ("encode", "audio", "wav"))
        action = report["audioActions"][0]
        self.assertEqual((action["action"], action["codec"], action["bitDepth"]), ("pcm", "pcm_s24le", 24))
        self.assertEqual([s["trackActions"][0]["action"] for s in report["segments"]], ["encode", "encode"])
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
        action = report["audioActions"][0]
        self.assertEqual((report["mode"], report["container"], report["audio"]), ("encode", "mp3", "auto"))
        self.assertEqual((action["action"], action["codec"], action["bitRate"]), ("mp3", "mp3", 128_000))
        # Auto applied the first alternative of the shared ladder that fits .mp3.
        self.assertEqual(report["applied"], "convertSameFormat")
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
        self.assertEqual(self.cli("inspect", "--json", "--no-sidecar", result)["media"]["duration"], report["duration"])

    def test_variable_rate_mp3_reports_the_lame_setting_it_uses(self):
        _, planned = self.export(self.vbr, "variable-join.mp3", dry_run=True)
        result, report = self.export(self.vbr, "variable-join.mp3")
        self.assertEqual({**planned, "dryRun": False}, report)
        action = report["audioActions"][0]
        self.assertEqual(action["action"], "mp3")
        self.assertIn(action["quality"], range(10))
        self.assertNotIn("bitRate", action)
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
            return self.cli("export", "--json", "--no-sidecar", "--dry-run", "--mode", "copy",
                            "--output", self.root / name, *clips, ok=False)["error"]

        error = refuse(self.mp3, "ladder.mp3")
        self.assertEqual(error["code"], "unsafe_boundary")
        offers = error["alternatives"]
        self.assertEqual([item["id"] for item in offers], ["convertSameFormat", "convertPCM", "convertAAC"])
        self.assertEqual([item["label"] for item in offers],
                         ["Convert to MP3 (same format)", "Convert to WAV (no further quality loss)",
                          "Convert to AAC (.m4a, smaller)"])
        self.assertEqual([(item["container"], item["lossless"]) for item in offers],
                         [("mp3", False), ("wav", False), ("m4a", False)])
        self.assertEqual(offers[0]["bitRate"], 128_000)
        for item in offers:
            clips = [part for start, end in CUTS for part in ("--clip", self.mp3, "--from", start, "--to", end)]
            report = self.cli("export", "--json", "--no-sidecar", "--dry-run", *item["arguments"],
                              "--output", self.root / ("offer." + item["container"]), *clips)
            action = report["audioActions"][0]
            self.assertEqual((report["mode"], report["container"], action["action"], action.get("bitRate")),
                             (item["mode"], item["container"], item["audio"], item.get("bitRate")))

        # A cut between samples copies exactly once it sits on the sample clock. That ranks before any conversion.
        error = refuse(self.m4a, "ladder.m4a")
        first = error["alternatives"][0]
        self.assertEqual((first["id"], first["lossless"], first["mode"]), ("copySampleAligned", True, "copy"))
        self.assertEqual(first["label"], "Copy with cuts on the nearest audio sample (lossless)")
        self.assertIn("convertSameFormat", [item["id"] for item in error["alternatives"]])
        clips = [part for clip in first["clips"] for part in ("--clip", clip["file"], "--from", clip["from"], "--to", clip["to"])]
        report = self.cli("export", "--json", "--no-sidecar", "--dry-run", *first["arguments"],
                          "--output", self.root / "ladder.m4a", *clips)
        self.assertEqual(report["mode"], "copy")
        # FLAC cut inside its frames cannot be copied anywhere, so encoding FLAC again comes first.
        ids = [item["id"] for item in refuse(self.flac, "ladder.flac")["alternatives"]]
        self.assertEqual(ids[0], "convertSameFormat")
        # A request that is wrong in itself has no alternatives.
        self.assertNotIn("alternatives", refuse(self.mp3, "ladder.mp3", cuts=[("5", "1")]))

    def test_lame_tag_supplies_the_variable_or_average_rate_setting(self):
        if shutil.which("lame") is None:
            self.skipTest("The LAME command is not installed.")
        wave = self.root / "tones.wav"
        ffmpeg("-f", "lavfi", "-i", TONES.format(rate=RATE, length=12), wave)
        for options, name, expected in [(["-V", "3"], "v3", {"quality": 3}),
                                        (["--abr", "150"], "abr", {"bitRate": 150_000}),
                                        (["-b", "96"], "cbr", {"bitRate": 96_000})]:
            with self.subTest(name=name):
                source = self.root / f"lame-{name}.mp3"
                run(["lame", "--quiet", "--resample", "44.1", *options, wave, source])
                result, report = self.export(source, f"lame-{name}-join.mp3")
                action = report["audioActions"][0]
                self.assertEqual({key: action.get(key) for key in ("quality", "bitRate")},
                                 {"quality": None, "bitRate": None, **expected})
                self.assertEqual(len(pcm16(result)), len(kept(pcm16(source), CUTS)))

    def test_explicit_mp3_and_flac_convert_other_sources(self):
        result, report = self.export(self.opus, "from-opus.mp3", "--audio", "mp3")
        self.assertEqual(report["audioActions"][0]["bitRate"], 192_000)
        self.assertEqual(self.stream(result)["sample_rate"], "48000")
        self.assertEqual(len(pcm16(result)), len(kept(pcm16(self.opus), CUTS, rate=48_000)))
        result, report = self.export(self.mp3, "from-mp3.flac", "--audio", "flac")
        self.assertEqual((report["audioActions"][0]["codec"], report["audioActions"][0]["bitDepth"]), ("flac", 24))
        self.assertLessEqual(difference(pcm16(result), kept(pcm16(self.mp3), CUTS)), 1)

    def test_flac_join_stays_flac_and_decodes_bit_identical(self):
        result, report = self.export(self.flac, "join.flac")
        action = report["audioActions"][0]
        self.assertEqual((report["mode"], action["action"], action["bitDepth"]), ("encode", "flac", 16))
        written = self.stream(result)
        self.assertEqual((written["codec_name"], written["sample_fmt"], written["sample_rate"], written["channels"]),
                         ("flac", "s16", "44100", 2))
        self.assertEqual(pcm16(result), kept(pcm16(self.flac), CUTS))

        result, report = self.export(self.flac24, "join24.flac")
        self.assertEqual(report["audioActions"][0]["bitDepth"], 24)
        written = self.stream(result)
        self.assertEqual((written["sample_fmt"], written["bits_per_raw_sample"], written["channels"]), ("s32", "24", 1))
        self.assertEqual(pcm32(result), kept(pcm32(self.flac24), CUTS, rate=48_000, channels=1))

        # The same lossless samples as WAV keep the source word length.
        result, report = self.export(self.flac, "join-flac.wav")
        self.assertEqual(report["audioActions"][0]["codec"], "pcm_s16le")
        self.assertEqual(pcm16(result), kept(pcm16(self.flac), CUTS))
        # Matroska carries the copied FLAC packets, so auto does not convert.
        _, report = self.export(self.flac, "join.mka", cuts=[("0", "12")])
        self.assertEqual((report["mode"], report["audioActions"][0]["action"]), ("copy", "copy"))

    def test_auto_copies_when_copy_is_exact(self):
        # AAC in M4A carries sample-aligned joins through its edit list.
        result, report = self.export(self.m4a, "copied.m4a", cuts=[("1", "5.1"), ("9", "11.5")])
        self.assertEqual((report["mode"], report["audio"]), ("copy", "auto"))
        self.assertEqual(report["audioActions"], [{"action": "copy", "track": 0}])
        self.assertNotIn("applied", report)
        self.assertEqual([s["trackActions"][0]["action"] for s in report["segments"]], ["copy"] * len(report["segments"]))
        self.assertTrue(result.exists())
        single = [("0", "6")]
        _, report = self.export(self.mp3, "prefix.mp3", cuts=single)
        self.assertEqual((report["mode"], report["audioActions"][0]["action"]), ("copy", "copy"))
        _, refused = self.export(self.mp3, "copy-only.mp3", "--audio", "copy", ok=False)
        self.assertEqual(refused["error"]["code"], "audio_copy_unavailable")
        self.assertFalse((self.root / "copy-only.mp3").exists())

    def test_aac_conversion_keeps_parameters_and_sample_count(self):
        result, report = self.export(self.m4a, "encoded.m4a", "--audio", "aac")
        action = report["audioActions"][0]
        self.assertEqual((report["mode"], action["action"], action["bitRate"]), ("encode", "aac", 128_000))
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
        self.assertEqual((report["mode"], report["audioActions"][0]["action"]), ("copy", "copy"))
        self.assertTrue(any("nearest audio sample" in warning for warning in report["warnings"]))
        self.assertEqual(Fraction(report["duration"]["numerator"], report["duration"]["denominator"]),
                         Fraction(len(kept(pcm16(self.m4a), CUTS)) // 2, RATE))
        # The decoded AAC ranges are the PCM that a conversion writes.
        result, _ = self.export(self.m4a, "aac-join.wav", "--audio", "pcm")
        reference = kept(pcm16(self.m4a), CUTS)
        decoded = pcm16(result)
        self.assertEqual(len(decoded), len(reference))
        self.assertLessEqual(difference(decoded, reference), 1)
        # The soundtrack of a movie has no file size of its own, so AAC uses the default rate for its channels.
        movie = self.root / "aac-movie.mp4"
        ffmpeg("-i", self.movie, "-c:v", "copy", "-c:a", "aac", "-b:a", "96k", movie)
        _, report = self.export(movie, "aac-movie.m4a", "--tracks", "audio", "--audio", "aac", dry_run=True)
        self.assertEqual(report["audioActions"][0]["bitRate"], 192_000)
        # A raw ADTS stream copies into M4A, whose edit list carries the joins.
        _, report = self.export(self.adts, "adts.m4a", cuts=[("1", "5.1"), ("9", "11.5")])
        self.assertEqual(report["mode"], "copy")
        # Another codec written to M4A becomes AAC at the default rate for its channels.
        result, report = self.export(self.mp3, "mp3-as.m4a")
        self.assertEqual((report["audioActions"][0]["action"], report["audioActions"][0]["bitRate"]), ("aac", 192_000))
        self.assertEqual(len(array("h", run([self.decoder, result]))), len(kept(pcm16(self.mp3), CUTS)))

    def test_opus_and_vorbis_joins_convert_to_pcm_or_aac(self):
        for source, rate in [(self.opus, 48_000), (self.vorbis, RATE)]:
            with self.subTest(source=source.name):
                name = source.suffix[1:]
                _, refused = self.export(source, "same" + source.suffix, ok=False)
                self.assertEqual(refused["error"]["code"], "unsupported_container")
                self.assertIn(".wav", refused["error"]["message"])
                self.assertIn(".m4a", refused["error"]["message"])
                result, report = self.export(source, name + "-join.wav")
                self.assertEqual(report["audioActions"][0]["action"], "pcm")
                expected = kept(pcm16(source), CUTS, rate=rate)
                decoded = pcm16(result)
                self.assertEqual(len(decoded), len(expected))
                self.assertLessEqual(difference(decoded, expected), 1)
                result, report = self.export(source, name + "-join.m4a")
                self.assertEqual(report["audioActions"][0]["action"], "aac")
                self.assertEqual(len(array("h", run([self.decoder, result]))), len(expected))

    def test_movie_soundtrack_converts_with_tracks_audio(self):
        result, report = self.export(self.movie, "movie.mp3", "--tracks", "audio", "--audio", "mp3")
        self.assertEqual((report["tracks"], report["audioActions"][0]["action"]), ("audio", "mp3"))
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

    def test_wrong_extension_and_settings_are_structured_errors(self):
        for options, name, code, words in [
            (["--audio", "pcm"], "wrong.m4a", "unsupported_container", [".wav"]),
            (["--audio", "aac"], "wrong.wav", "unsupported_container", [".m4a"]),
            (["--audio", "mp3"], "wrong.wav", "unsupported_container", [".mp3"]),
            (["--audio", "flac"], "wrong.mp3", "unsupported_container", [".flac"]),
            ([], "wrong.xyz", "unsupported_container", [".wav", ".m4a", ".mp3"]),
            ([], "no-extension", "unsupported_container", [".wav", ".m4a", ".mp3", ".flac"]),
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
        report = self.cli("export", "--json", "--stdin", "--no-sidecar", stdin=json.dumps(request))
        self.assertEqual(report["audioActions"][0]["bitRate"], 128_000)
        self.assertEqual(len(pcm16(self.root / "request.mp3")), len(kept(pcm16(self.mp3), CUTS)))

        folder = self.root / "bulk"
        folder.mkdir()
        bulk = {"file": str(self.mp3), "outputDirectory": str(folder), "mode": "encode", "audio": "pcm",
                "container": "wav", "ranges": [{"from": "1", "to": "2"}, {"from": "9", "to": "11.5"}]}
        planned = self.cli("bulk", "--json", "--stdin", "--no-sidecar", "--dry-run", stdin=json.dumps(bulk))
        self.assertEqual(list(folder.iterdir()), [])
        report = self.cli("bulk", "--json", "--stdin", "--no-sidecar", stdin=json.dumps(bulk))
        self.assertEqual([{**item, "dryRun": False} for item in planned["outputs"]], report["outputs"])
        decoded = pcm16(self.mp3)
        for item, cut in zip(report["outputs"], [("1", "2"), ("9", "11.5")]):
            self.assertEqual((item["mode"], item["audioActions"][0]["action"]), ("encode", "pcm"))
            self.assertLessEqual(difference(pcm16(Path(item["output"])), kept(decoded, [cut])), 1)
        # A range that cannot be copied lists the same alternatives as a single export.
        joined = {"file": str(self.mp3), "outputDirectory": str(folder), "mode": "copy", "container": "wav",
                  "tracks": "audio", "ranges": [{"from": "1", "to": "2"}]}
        refused = self.cli("bulk", "--json", "--stdin", "--no-sidecar", "--dry-run", stdin=json.dumps(joined), ok=False)
        self.assertEqual([item["id"] for item in refused["error"]["alternatives"]][-2:], ["convertPCM", "convertAAC"])
        # Without a container, auto keeps the source format of each range.
        del bulk["container"], bulk["audio"]
        bulk["ranges"] = [{"from": "1", "to": "2"}]
        report = self.cli("bulk", "--json", "--stdin", "--no-sidecar", "--dry-run", stdin=json.dumps(bulk))
        self.assertEqual(report["outputs"][0]["container"], "mp3")

    def test_interrupt_leaves_no_partial_or_staging_files(self):
        source = self.root / "long.mp3"
        ffmpeg("-f", "lavfi", "-i", "sine=f=330:r=22050:d=2400", "-c:a", "libmp3lame", "-b:a", "32k", source)
        for name in ("cancelled.wav", "cancelled.mp3"):
            with self.subTest(name=name):
                output = self.root / name
                args = [CLI, "export", "--json", "--no-sidecar", "--mode", "encode", "--output", output,
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
        # Stand in for an earlier helper: the same program, reporting no MP3 or FLAC encoder.
        built = Path(__file__).resolve().parents[2] / ".build/mpcut-ffmpeg/install/bin/ffmpeg"
        real = Path(os.environ.get("MPCUT_FFMPEG_HELPER", built))
        if not real.exists():
            self.skipTest("The FFmpeg helper is not built.")
        old = self.root / "earlier helper" / "ffmpeg"
        old.parent.mkdir()
        old.write_text('#!/bin/sh\ncase " $* " in\n  *" -encoders "*) "%s" "$@" | grep -v -e libmp3lame -e " flac "; exit 0 ;;\n'
                       'esac\nexec "%s" "$@"\n' % (real, real))
        old.chmod(0o755)
        env = dict(os.environ, MPCUT_FFMPEG_HELPER=str(old))
        for dry_run in (True, False):
            # A named format is refused. Auto skips the rung and lists the alternatives that still work.
            _, report = self.export(self.mp3, "old-helper.mp3", "--audio", "mp3", ok=False, dry_run=dry_run, env=env)
            self.assertEqual(report["error"]["code"], "encoder_unavailable")
            _, report = self.export(self.flac, "old-helper.flac", "--audio", "flac", ok=False, dry_run=dry_run, env=env)
            self.assertEqual(report["error"]["code"], "encoder_unavailable")
            _, report = self.export(self.mp3, "old-helper.mp3", ok=False, dry_run=dry_run, env=env)
            self.assertEqual(report["error"]["code"], "unsupported_container")
            self.assertEqual([item["id"] for item in report["error"]["alternatives"]], ["convertPCM", "convertAAC"])
        # The same helper still converts to PCM.
        result, report = self.export(self.mp3, "old-helper.wav", env=env)
        self.assertEqual(report["audioActions"][0]["action"], "pcm")
        self.assertLessEqual(difference(pcm16(result), kept(pcm16(self.mp3), CUTS)), 1)
        self.assert_no_staging()


if __name__ == "__main__":
    args = argparse.ArgumentParser()
    args.add_argument("mpcut", type=Path)
    options, remaining = args.parse_known_args()
    CLI = options.mpcut.resolve()
    unittest.main(argv=[__file__, *remaining])
