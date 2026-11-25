#!/usr/bin/env python3
"""Measure copied lossy audio where two ranges meet inside one output, and the notes the plans give about it.

An AAC copy into MOV, MP4 or M4A places each range with its own edit-list entry. AVFoundation applies it to the
sample. FFmpeg applies an interior entry only at whole AAC frames: it plays the whole last frame before a join and
leaves out the partial first frame after it. Into Matroska, which has no edit list, Smart Trim encodes the few AAC
frames around each join and trims one of them with DiscardPadding, so FFmpeg decodes the join to the sample. AC-3 and
E-AC-3 joins are on frame boundaries, but the first block after a join decodes with another frame's overlap. Each test
decodes the outputs and compares them with the source.
"""
import argparse
from array import array
from fractions import Fraction
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

from audio_tracks import ffmpeg, probe, time

RATE = 48000
CHIRP = "aevalsrc=0.5*sin(2*PI*(300*t+40*t*t))|0.4*sin(2*PI*(500*t+25*t*t)):s=48000"


def decode_ffmpeg(path):
    """Interleaved 16-bit stereo, as FFmpeg decodes and concatenates every frame it keeps."""
    return array("h", ffmpeg("-i", path, "-map", "0:a:0", "-f", "s16le", "-c:a", "pcm_s16le", "-"))


def frames(samples, start, end):
    return samples[2 * start:2 * end]


def milliseconds(samples):
    return f"{samples * 1000 / RATE:.1f} ms"


def seconds(sample):
    """A time as the plans write it: three to six decimals."""
    whole, decimals = f"{sample / RATE:.6f}".split(".")
    return f"{whole}.{decimals.rstrip('0').ljust(3, '0')} s"


class AudioJoins(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.env = dict(os.environ, MPCUT_SIDECAR_HOME=str(cls.root / "preferences"))
        cls.decoder = cls.root / "decode-audio"
        subprocess.run(["swiftc", "-suppress-warnings", "-parse-as-library", Path(__file__).with_name("DecodeAudio.swift"),
                        "-o", cls.decoder], check=True, capture_output=True)
        cls.movie = cls.root / "source.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x240:r=25", "-f", "lavfi", "-i", CHIRP, "-t", "6",
               "-c:v", "libx264", "-g", "5", "-bf", "0", "-c:a", "aac", "-b:a", "160k", "-aac_pns", "0", cls.movie)
        cls.source_native = cls.native(cls.movie)
        cls.source_ffmpeg = decode_ffmpeg(cls.movie)
        packets = probe(cls.movie, "-select_streams", "a:0", "-show_entries", "packet=pts", "-show_packets")["packets"]
        cls.frame_starts = [int(packet["pts"]) for packet in packets]

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def native(cls, path):
        return array("h", subprocess.run([cls.decoder, path], check=True, capture_output=True, timeout=120).stdout)

    def export(self, output, ranges, mode, *, dry=False, tracks=None, audio=None, ok=True, source=None):
        request = {"output": str(output), "mode": mode,
                   "clips": [{"file": str(source or self.movie), "from": f"{a}/{RATE}", "to": f"{b}/{RATE}"} for a, b in ranges]}
        if tracks:
            request["tracks"] = tracks
        if audio:
            request["audio"] = audio
        args = [CLI, "export", "clips", "join", "--json", "--stdin"] + (["--dry-run"] if dry else [])
        proc = subprocess.run(args, input=json.dumps(request), env=self.env, capture_output=True, text=True, timeout=300)
        self.assertEqual(proc.returncode == 0, ok, proc.stdout + proc.stderr)
        return json.loads(proc.stdout)

    def rest(self, sample):
        """Samples from `sample` to the start of the next source AAC frame."""
        return min(start for start in self.frame_starts if start >= sample) - sample

    def expected_note(self, ranges):
        """The details the plan should give, and the sound FFmpeg should decode up to the last cut."""
        details, ffmpeg_sound, elapsed = [], array("h"), 0
        for index, (start, end) in enumerate(ranges):
            skipped = self.rest(start) if index else 0
            past = self.rest(end) if index < len(ranges) - 1 else 0
            ffmpeg_sound += frames(self.source_ffmpeg, start + skipped, end + past)
            if index:
                previous = self.rest(ranges[index - 1][1])
                parts = ([f"{milliseconds(previous)} past the cut"] if previous else []) \
                    + ([f"the first {milliseconds(skipped)} of the next range left out"] if skipped else [])
                if parts:
                    details.append(f"at {seconds(elapsed)}, " + " and ".join(parts))
            elapsed += end - start
        if self.rest(ranges[-1][1]):
            details.append(f"up to {milliseconds(self.rest(ranges[-1][1]))} past the end")
        if len(details) > 1:
            details[-1] = "and " + details[-1]
        return details, ffmpeg_sound

    def check_aac_joins(self, output, ranges, mode, tracks=None):
        dry = self.export(output, ranges, mode, dry=True, tracks=tracks)
        report = self.export(output, ranges, mode, tracks=tracks)
        self.assertEqual(dry.get("warnings"), report.get("warnings"), "the dry run and the export report different warnings")
        notes = [warning for warning in report.get("warnings", []) if warning.startswith("AAC track")]
        details, ffmpeg_sound = self.expected_note(ranges)
        self.assertEqual(len(notes), 1, report.get("warnings"))
        note = notes[0]
        self.assertIn(f"is joined at {len(ranges) - 1} points by edit-list entries.", note)
        self.assertIn("such as Apple's, play each join exactly", note)
        self.assertIn("such as FFmpeg-based ones, move the sound: " + "; ".join(details) + ".", note)

        # AVFoundation applies every edit-list entry to the sample: the output is the source's decoded ranges.
        expected = array("h")
        for start, end in ranges:
            expected += frames(self.source_native, start, end)
        decoded = self.native(output)
        self.assertEqual(len(decoded), len(expected), "AVFoundation decodes another length")
        self.assertTrue(decoded == expected, "AVFoundation decodes other samples at a join")
        # FFmpeg keeps whole frames at interior entries, as the note says, and can keep the last frame whole.
        # Its float-to-integer conversion can round a sample of a trimmed frame the other way.
        decoded = decode_ffmpeg(output)
        overrun = len(decoded) - len(ffmpeg_sound)
        self.assertTrue(0 <= overrun <= 2 * self.rest(ranges[-1][1]), f"FFmpeg plays {overrun // 2} samples past the end")
        worst = max(abs(a - b) for a, b in zip(decoded, ffmpeg_sound))
        self.assertLessEqual(worst, 1, "FFmpeg does not decode the frames the note describes")
        return report

    def test_movie_joins_are_exact_in_avfoundation_and_noted_for_whole_frame_players(self):
        # Copy cuts on the 0.2 s keyframes. Smart Trim also cuts between them and encodes the video edges only.
        copy = [(48000, 115200), (153600, 192000), (19200, 48000), (249600, 278400)]
        smart = [(49920, 120960), (161280, 195840), (21120, 44160), (245760, 282240)]
        for container in ["mov", "mp4"]:
            for mode, ranges in [("copy", copy), ("smart", smart)]:
                with self.subTest(container=container, mode=mode):
                    output = self.root / f"{mode}.{container}"
                    report = self.check_aac_joins(output, ranges, mode)
                    actions = {action["action"] for segment in report["segments"] for action in segment["track_actions"]
                               if action["kind"] == "audio"}
                    self.assertEqual(actions, {"copy"})
                    if mode == "smart":
                        self.assertGreater(time(report["encoded_duration"]), 0)

    def test_sound_only_joins_at_varied_phases(self):
        # The second join meets the source's frame boundaries on both sides, so every player places it exactly.
        start, end = self.frame_starts[150], self.frame_starts[200]
        ranges = [(48623, 115541), (153611, 192007), (start, end), (19201, 48000)]
        for mode in ["copy", "smart"]:
            with self.subTest(mode=mode):
                self.check_aac_joins(self.root / f"sound-{mode}.m4a", ranges, mode, tracks="audio")

    def test_matroska_copy_refuses_an_aac_join_and_names_smart_trim(self):
        output = self.root / "refused.mkv"
        error = self.export(output, [(0, 115200), (153600, 288000)], "copy", dry=True, ok=False)["error"]
        self.assertEqual((error["code"], error["reason"], error["track"]), ("unsafe_boundary", "join_aac_frames", 1))
        self.assertIn("Smart Trim makes the join exact", error["message"])
        self.assertIn("smart_trim", [alternative["id"] for alternative in error["alternatives"]])
        # A single range can start and end inside AAC frames: the copy keeps every frame byte for byte, a codec delay
        # hides the start with the frame before it, and DiscardPadding the end. FFmpeg decodes exactly that range.
        trimmed = self.root / "trimmed.mkv"
        report = self.export(trimmed, [(48000, 278400)], "copy")
        self.assertNotIn("encoded_audio_edges", report["segments"][0])
        self.assertNotIn("encoded_audio_duration", report)
        decoded, wanted = decode_ffmpeg(trimmed), frames(self.source_ffmpeg, 48000, 278400)
        self.assertEqual(len(decoded), len(wanted))
        self.assertLessEqual(max(abs(a - b) for a, b in zip(decoded, wanted)), 1)
        # A sound-only export has no Smart Trim, so its refusal points to a conversion.
        output = self.root / "refused.mka"
        error = self.export(output, [(48623, 96000), (144011, 192000)], "copy", ok=False, tracks="audio")["error"]
        self.assertEqual((error["code"], error["reason"]), ("unsafe_boundary", "join_decoder_history"))
        self.assertIn("converting the audio makes the join exact", error["message"])
        self.assertFalse(output.exists())

    def bridged_movie(self, name, audio):
        """A six-second H.264 movie with keyframes every 0.2 s and the given AAC file as its sound."""
        path = self.root / name
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x240:r=25", "-i", audio, "-t", "6", "-map", "0:v", "-map", "1:a",
               "-c:v", "libx264", "-g", "5", "-bf", "0", "-c:a", "copy", path)
        return path

    def check_matroska_bridges(self, source, encoder, ranges, rate=RATE):
        """`ranges` are in 1/48000 s; `rate` is the sample rate of the source."""
        output = self.root / f"bridged-{source.name}-{ranges[0][0]}.mkv"
        dry = self.export(output, ranges, "smart", dry=True, source=source)
        report = self.export(output, ranges, "smart", source=source)
        self.assertEqual(dry["segments"], report["segments"], "the dry run and the export plan different frames")
        self.assertEqual(dry.get("encoded_audio_duration"), report.get("encoded_audio_duration"))
        self.assertEqual(dry.get("warnings"), report.get("warnings"))
        segments = report["segments"]
        self.assertNotIn("encoded_audio_edges", segments[0])
        edges = []
        for segment in segments[1:]:
            self.assertEqual(len(segment["encoded_audio_edges"]), 1, segment)
            edge = segment["encoded_audio_edges"][0]
            self.assertEqual((edge["track"], edge["encoder"]), (1, encoder))
            audio = [action for action in segment["track_actions"] if action["kind"] == "audio"]
            self.assertEqual([action["action"] for action in audio], ["copy_and_encode"])
            start, end = (round(time(edge[key]) * rate) for key in ("from", "to"))
            self.assertEqual(edge["frame_count"], (end - start + 1023) // 1024)
            edges.append((start, end))
        self.assertEqual(time(report["encoded_audio_duration"]), sum(Fraction(end - start, rate) for start, end in edges))

        # AVFoundation cannot read Matroska, so FFmpeg is the reader here. It applies DiscardPadding to the sample.
        original = decode_ffmpeg(source)
        expected = array("h")
        for segment in segments:
            track = [track for track in segment["tracks"] if track["kind"] == "audio"][0]
            expected += frames(original, round(time(track["source_start"]) * rate), round(time(track["source_end"]) * rate))
        decoded = decode_ffmpeg(output)
        self.assertEqual(len(decoded), len(expected), "the bridges or the trims at the outer edges change the length")
        inside = set()
        for start, end in edges:
            inside.update(range(2 * start, 2 * (end + 1024)))
            region = range(2 * start, 2 * (end + 1024))
            error = (sum((decoded[i] - expected[i]) ** 2 for i in region) / len(region)) ** 0.5
            self.assertLess(error, 0.02 * 32768, f"the encoded frames at {start} differ beyond codec error")
            steps = max(abs(decoded[i] - decoded[i - 2]) for i in region)
            wanted = max(abs(expected[i] - expected[i - 2]) for i in region)
            self.assertLess(steps, wanted + 0.1 * 32768, f"the encoded frames at {start} click")
        outside = max(abs(decoded[i] - expected[i]) for i in range(len(expected)) if i not in inside)
        self.assertLessEqual(outside, 1, "a copied frame decodes differently")

        # The output reopens with its planned duration, and a copy of it keeps the trims.
        info = json.loads(subprocess.run([CLI, "media", "inspect", "--json", output], env=self.env, capture_output=True,
                                         text=True, check=True).stdout)
        self.assertEqual(time(info["media"]["duration"]), time(report["duration"]))
        copy = self.root / f"recopied-{source.name}-{ranges[0][0]}.mkv"
        subprocess.run([CLI, "export", "clips", "join", "--json", "--mode", "copy", "--clip", output, "--output", copy],
                       env=self.env, capture_output=True, check=True)
        self.assertTrue(decode_ffmpeg(copy) == decode_ffmpeg(output), "a copy of the output decodes differently")

    def test_smart_trim_encodes_exact_aac_joins_into_matroska(self):
        # Joins from the source's start to its end, then a start and an end inside frames, trimmed by a codec delay
        # and DiscardPadding.
        whole = [(0, 115200), (153600, 192000), (19200, 48000), (249600, 288000)]
        inner = [(48000, 115200), (153600, 192000), (19200, 48000), (249600, 278400)]
        sources = [(self.movie, "ffmpeg")]
        matroska = self.root / "source.mkv"
        ffmpeg("-i", self.movie, "-c", "copy", matroska)
        sources.append((matroska, "ffmpeg"))
        # Noise with FFmpeg's default perceptual noise substitution, which the bridge encoder leaves off.
        noisy = self.root / "noisy.m4a"
        ffmpeg("-f", "lavfi", "-i", "anoisesrc=c=pink:s=48000:a=0.3", "-f", "lavfi", "-i", CHIRP,
               "-filter_complex", "[0][1]amix=inputs=2", "-t", "6", "-ac", "2", "-c:a", "aac", "-b:a", "128k", noisy)
        sources.append((self.bridged_movie("noisy.mov", noisy), "ffmpeg"))
        if shutil.which("afconvert"):
            wave = self.root / "chirp.wav"
            ffmpeg("-f", "lavfi", "-i", CHIRP, "-t", "6", "-c:a", "pcm_s16le", wave)
            apple = self.root / "apple.m4a"
            subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "160000", wave, apple], check=True)
            sources.append((self.bridged_movie("apple.mov", apple), "apple"))
        cd = self.root / "cd.m4a"
        ffmpeg("-f", "lavfi", "-i", CHIRP.replace("s=48000", "s=44100"), "-t", "6", "-c:a", "aac", "-b:a", "128k", cd)
        rated = [(self.bridged_movie("cd.mov", cd), "ffmpeg", 44100)]
        for (source, encoder), (name, ranges) in [(pair, choice) for pair in sources for choice in [("whole", whole), ("inner", inner)]]:
            with self.subTest(source=source.name, ranges=name):
                self.check_matroska_bridges(source, encoder, ranges)
        for source, encoder, rate in rated:
            with self.subTest(source=source.name, ranges="inner"):
                self.check_matroska_bridges(source, encoder, inner, rate)

    @unittest.skipUnless(shutil.which("afconvert"), "needs afconvert for an HE-AAC source")
    def test_smart_trim_refuses_an_he_aac_join_into_matroska_with_its_reason(self):
        wave = self.root / "he.wav"
        ffmpeg("-f", "lavfi", "-i", CHIRP, "-t", "6", "-c:a", "pcm_s16le", wave)
        he = self.root / "he.m4a"
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aach", "-b", "64000", wave, he], check=True)
        source = self.bridged_movie("he.mov", he)
        error = self.export(self.root / "he.mkv", [(0, 115200), (153600, 288000)], "smart", ok=False, source=source)["error"]
        self.assertEqual((error["code"], error["reason"]), ("unsafe_boundary", "join_decoder_history"))
        self.assertIn("HE-AAC", error["message"])

    def test_converted_sound_places_every_join_for_ffmpeg(self):
        ranges = [(48623, 115541), (153611, 192007), (19201, 48000)]
        output = self.root / "converted.m4a"
        report = self.export(output, ranges, "encode", tracks="audio", audio="aac")
        self.assertFalse([warning for warning in report.get("warnings", []) if warning.startswith("AAC track")])
        decoded = decode_ffmpeg(output)
        expected = array("h")
        for start, end in ranges:
            expected += frames(self.source_ffmpeg, start, end)
        self.assertEqual(len(decoded), len(expected))
        # Each range sits where it was asked for: its middle matches the source best with no shift.
        elapsed = 0
        for start, end in ranges:
            middle = elapsed + (end - start) // 2
            def error(shift):
                return sum(abs(decoded[2 * (middle + shift + i)] - expected[2 * (middle + i)]) for i in range(0, 512, 2))
            self.assertEqual(min(range(-1100, 1101, 1), key=error), 0)
            elapsed += end - start

    def test_ac3_joins_are_noted_and_differ_only_in_the_first_block(self):
        for codec, name in [("ac3", "AC-3"), ("eac3", "E-AC-3")]:
            with self.subTest(codec=codec):
                source = self.root / f"source.{codec}"
                ffmpeg("-f", "lavfi", "-i", CHIRP, "-t", "6", "-c:a", codec, "-b:a", "192k", source)
                ranges = [(1536 * 31, 1536 * 75), (1536 * 100, 1536 * 125)]
                output = self.root / f"joined.{codec}"
                dry = self.export(output, ranges, "copy", dry=True, source=source)
                report = self.export(output, ranges, "copy", source=source)
                self.assertEqual(dry.get("warnings"), report.get("warnings"))
                join = seconds(ranges[0][1] - ranges[0][0])
                self.assertEqual(report.get("warnings"), [
                    f"{name} track 0 is copied in whole frames, so the first frame, which begins inside the source, and the first frame "
                    f"after the join (at {join}) are decoded with another overlap than in the source: up to 5.3 ms there can differ "
                    "from the source and click. Converting the audio decodes each range from its own frames."])
                original = decode_ffmpeg(source)
                expected = array("h")
                for start, end in ranges:
                    expected += frames(original, start, end)
                decoded = decode_ffmpeg(output)
                self.assertEqual(len(decoded), len(expected))
                boundary = ranges[0][1] - ranges[0][0]
                block = range(2 * boundary, 2 * (boundary + 256))
                head = range(0, 2 * 256)
                elsewhere = [abs(decoded[i] - expected[i]) for i in range(len(expected)) if i not in block and i not in head]
                self.assertLessEqual(max(elsewhere), 1, "a copied frame away from the join decodes differently")
                self.assertGreater(max(abs(decoded[i] - expected[i]) for i in block), 1000, "the first block after the join decodes as in the source")
                converted = self.root / f"joined-{codec}.wav"
                self.export(converted, ranges, "encode", source=source, audio="pcm")
                pcm = decode_ffmpeg(converted)
                self.assertEqual(len(pcm), len(expected))
                # The helper decodes to floating point. Away from rounding, every sample matches the source.
                self.assertLessEqual(max(abs(a - b) for a, b in zip(pcm, expected)), 8, "a conversion decodes another history")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args, tests = parser.parse_known_args()
    CLI = str(args.binary.resolve(strict=True))
    unittest.main(argv=[__file__, *tests])
