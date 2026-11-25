#!/usr/bin/env python3
"""Exercise Re-encode with generated video and audio against a release mpcut CLI."""
import argparse
from array import array
from fractions import Fraction
import json
import os
import resource
from math import sqrt
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

from media_regression import ffmpeg, packets, probe, ratio, run, timestamped_hashes
from smart_trim import FPS, movie, picture_ids

CLI = None


def stream(path, track):
    return probe(path, "-select_streams", track, "-show_streams")["streams"][0]


def pcm(path, rate, index=0):
    decoded = ffmpeg("-i", path, "-map", f"0:a:{index}", "-ar", str(rate),
                     "-c:a", "pcm_f32le", "-f", "f32le", "-")
    return array("f", decoded)


def correlation(first, second):
    cross = sum(a * b for a, b in zip(first, second, strict=True))
    return cross / sqrt(sum(a * a for a in first) * sum(b * b for b in second))


class ReencodeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-encode-fixtures-")
        cls.addClassCleanup(directory.cleanup)
        fixtures = Path(directory.name)
        cls.decode_native = fixtures / "DecodeFrameIDs"
        run(["swiftc", "-parse-as-library", Path(__file__).with_name("DecodeFrameIDs.swift"),
             "-o", cls.decode_native], allow_diagnostics=True)
        cls.decode_audio_native = fixtures / "DecodeAudio"
        run(["swiftc", "-parse-as-library", Path(__file__).with_name("DecodeAudio.swift"),
             "-o", cls.decode_audio_native], allow_diagnostics=True)
        cls.video = movie(fixtures / "h264.mp4", "h264")
        cls.stereo = fixtures / "stereo.mov"
        left = "0.5*sin(2*PI*(397+23*t)*t)"
        right = "0.3*sin(2*PI*(713+59*t)*t)"
        ffmpeg("-i", cls.video, "-f", "lavfi", "-i",
               f"aevalsrc={left}|{right}:s=44100:d=5:c=stereo",
               "-f", "lavfi", "-i", "aevalsrc=0.4*sin(2*PI*(271+70*t)*t):s=48000:d=5:c=mono",
               "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0", "-c:v", "copy", "-c:a", "pcm_s16le",
               cls.stereo)

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-encode-output-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def export(self, output, clips, *, video="h264", audio="remove", quality=None, dry=False, ok=True, env=None):
        args = [CLI, "export", "clips", "join", "--json", "--mode", "encode", "--video", video, "--audio", audio,
                "--output", output]
        if quality is not None:
            args += ["--quality", quality]
        if dry:
            args.append("--dry-run")
        for source, start, end in clips:
            args += ["--clip", source, "--from", str(start), "--to", str(end)]
        process = subprocess.run(args, capture_output=True, text=True, timeout=90, env=env)
        self.assertEqual(process.returncode == 0, ok, process.stdout + process.stderr)
        report = json.loads(process.stdout)
        self.assertIs(report["ok"], ok, report)
        self.assertEqual(output.exists(), ok and not dry)
        return report

    def test_reencode_converts_different_soundtracks_by_audio_order(self):
        original = self.root / "original.mov"
        working = self.root / "working.mov"
        for path, frequencies, mapping, codec in [
            (original, (330, 440), ("0:v", "1:a", "2:a"), "aac"),
            (working, (660, 880), ("1:a", "0:v", "2:a"), "pcm_f32le"),
        ]:
            ffmpeg("-i", self.video, "-f", "lavfi", "-i", f"sine=d=1:r=48000:f={frequencies[0]}",
                   "-f", "lavfi", "-i", f"sine=d=1:r=48000:f={frequencies[1]}",
                   "-map", mapping[0], "-map", mapping[1], "-map", mapping[2],
                   "-c:v", "copy", "-c:a:0", codec, "-c:a:1", "pcm_s16le",
                   "-disposition:a:0", "default", "-disposition:a:1", "0", path)
        self.assertEqual([stream(file, "a:0")["index"] for file in (original, working)], [1, 0])
        clips = [(original, 0, 1), (working, 0, 1)]
        denied = self.export(self.root / "copy.mov", clips, audio="copy", dry=True, ok=False)
        self.assertEqual(denied["error"]["code"], "incompatible_clip")
        for action in ("auto", "aac", "pcm", "remove"):
            with self.subTest(action=action):
                output = self.root / f"{action}.mov"
                # Put PCM first for Auto so it must still decline an exact PCM copy
                # when the corresponding track in the next clip is AAC.
                ordered = clips[::-1] if action == "auto" else clips
                self.export(output, ordered, audio=action)
                streams = probe(output, "-show_streams")["streams"]
                if action == "remove":
                    self.assertEqual([item["codec_type"] for item in streams], ["video"])
                    continue
                self.assertEqual([item["codec_type"] for item in streams], ["video", "audio", "audio"])
                if action == "auto":
                    self.assertEqual([item["codec_name"] for item in streams[1:]], ["aac", "pcm_s16le"])
                for index in range(2):
                    samples = pcm(output, 48_000, index)
                    self.assertGreaterEqual(len(samples), 96_000)
                    for position, (file, _, _) in enumerate(ordered):
                        start = position * 48_000
                        expected = pcm(file, 48_000, index)[:48_000]
                        actual = samples[start:start + 48_000]
                        self.assertGreater(correlation(actual, expected), 0.99)
        mismatched = self.root / "different-clock.mov"
        ffmpeg("-i", working, "-map", "0", "-c", "copy", "-c:a:0", "pcm_f32le", "-ar:a:0", "44100", mismatched)
        # Another sample rate makes the timeline mixed: its sound is converted to one format, and an exact copy is refused.
        report = self.export(self.root / "mixed-clock.mov", [(original, 0, 1), (mismatched, 0, 1)],
                             audio="pcm", dry=True)
        self.assertIn("audio sample rate", report["warnings"][0])
        self.assertIn("Audio track 1 is resampled to 48 kHz", "\n".join(report["warnings"]))
        report = self.export(self.root / "invalid.mov", [(original, 0, 1), (mismatched, 0, 1)],
                             audio="copy", dry=True, ok=False)
        self.assertEqual(report["error"]["code"], "incompatible_clip")
        self.assertIn("sample rate", report["error"]["message"])

    def test_selected_codecs_encode_every_frame_in_requested_order(self):
        src_packets = packets(self.video)
        self.assertNotEqual([int(p["pts"]) for p in src_packets],
                            sorted(int(p["pts"]) for p in src_packets), "fixture needs reordered B pictures")
        ranges = [(41, 69), (7, 23), (41, 69), (95, 96)]
        clips = [(self.video, Fraction(start, FPS), Fraction(end, FPS)) for start, end in ranges]
        expected = bytes(index for start, end in ranges for index in range(start, end))
        duration = Fraction(len(expected), FPS)
        for codec, quality, suffix in [("h264", "balanced", ".mp4"), ("hevc", "high", ".mp4"),
                                       ("hevc", "smaller", ".mkv"), ("prores", "422-hq", ".mov")]:
            with self.subTest(codec=codec, container=suffix):
                output = self.root / (codec + suffix)
                dry = self.export(output, clips, video=codec, quality=quality, dry=True)
                self.assertEqual(dry["mode"], "encode")
                self.assertEqual(dry["video"], codec)
                self.assertEqual(dry["quality"], quality)
                self.assertEqual(ratio(dry["duration"]), duration)
                self.assertEqual(ratio(dry["encoded_duration"]), duration)
                self.assertEqual(ratio(dry["copied_duration"]), 0)
                report = self.export(output, clips, video=codec, quality=quality)
                self.assertEqual(ratio(report["duration"]), duration)
                metadata = stream(output, "v:0")
                self.assertEqual(metadata["codec_name"], codec)
                self.assertEqual((metadata["width"], metadata["height"]), (320, 96))
                for key in ("color_space", "color_transfer", "color_primaries"):
                    self.assertEqual(metadata[key], "bt709")
                if codec == "prores":
                    self.assertEqual(metadata["profile"], "HQ")
                self.assertEqual(len(probe(output, "-show_streams")["streams"]), 1)
                self.assertEqual(picture_ids(output), expected)
                if suffix != ".mkv":
                    self.assertEqual(run([self.decode_native, output]), expected)
                dst = timestamped_hashes(output)
                self.assertEqual(sorted(t for t, _ in dst), [Fraction(i, FPS) for i in range(len(expected))])
                self.assertTrue({payload for _, payload in dst}.isdisjoint(p["data_hash"] for p in src_packets))
                self.assertEqual(Fraction(probe(output, "-show_format")["format"]["duration"]), duration)

    def test_adjacent_cuts_keep_every_reported_range_and_sample(self):
        frames = [*range(41, 69), *range(7, 23), *range(41, 69)]
        clips = [(self.stereo, Fraction(frame, FPS), Fraction(frame + 1, FPS)) for frame in frames]
        output = self.root / "adjacent-cuts.mov"
        report = self.export(output, clips, audio="copy")
        self.assertEqual(len(report["segments"]), len(clips))
        self.assertEqual([ratio(segment["from"]) for segment in report["segments"]], [clip[1] for clip in clips])
        self.assertEqual(picture_ids(output), bytes(frames))
        for index, rate in enumerate([44100, 48000]):
            source = pcm(self.stereo, rate, index)
            frame_samples = rate // FPS * (2 - index)
            expected = array("f")
            for frame in frames:
                expected.extend(source[frame * frame_samples:(frame + 1) * frame_samples])
            self.assertEqual(pcm(output, rate, index), expected)

    def test_long_reordered_edits_with_a_descriptor_limit(self):
        frames = [(i * 17) % 65 for i in range(72)]
        sources = []
        for i in range(len(frames)):
            path = self.root / f"source-{i}.mov"
            os.link(self.stereo, path)
            sources.append(path)
        for label, files in [("shared", [self.stereo] * len(frames)), ("distinct", sources)]:
            with self.subTest(inputs=label):
                output = self.root / f"{label}.mov"
                args = [CLI, "--no-sidecar", "export", "clips", "join", "--mode", "encode", "--audio", "copy",
                        "--output", output, "--json"]
                for source, frame in zip(files, frames):
                    args += ["--clip", source, "--from", str(Fraction(frame, FPS)),
                             "--to", str(Fraction(frame + 1, FPS))]
                run(args, preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64)),
                    allow_diagnostics=True)
                self.assertEqual(picture_ids(output), bytes(frames))
                self.assertEqual([pts for pts, _ in timestamped_hashes(output)],
                                 [Fraction(i, FPS) for i in range(len(frames))])
                for index, rate in enumerate([44100, 48000]):
                    source = pcm(self.stereo, rate, index)
                    stride = rate // FPS * (2 - index)
                    expected = array("f")
                    for frame in frames:
                        expected.extend(source[frame * stride:(frame + 1) * stride])
                    self.assertEqual(pcm(output, rate, index), expected)
                self.assertFalse(any(self.root.glob(".mpcut-*")))

        cancelled = self.root / "cancel-batch.mov"
        args[args.index("--output") + 1] = cancelled
        with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if any(self.root.glob(".mpcut-*/part-0.mov")):
                        process.send_signal(signal.SIGINT)
                        break
                    self.assertIsNone(process.poll())
                    time.sleep(0.005)
                else:
                    self.fail("No encoded batch appeared")
                stdout, stderr = process.communicate(timeout=30)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        self.assertEqual(process.returncode, 130, stdout + stderr)
        self.assertFalse(cancelled.exists())
        self.assertFalse(any(self.root.glob(".mpcut-*")))

    def test_aac_and_pcm_keep_trimmed_audio_in_sync_and_preserve_linked_tracks(self):
        ranges = [(63, 77), (15, 31), (63, 77)]
        clips = [(self.stereo, Fraction(start, FPS), Fraction(end, FPS)) for start, end in ranges]
        duration = Fraction(sum(end - start for start, end in ranges), FPS)
        for format_name, suffix in [("aac", ".mp4"), ("pcm", ".mov")]:
            with self.subTest(audio=format_name):
                output = self.root / (format_name + suffix)
                report = self.export(output, clips, audio=format_name)
                self.assertEqual([track["action"] for track in report["audio_actions"]], [format_name] * 2)
                streams = probe(output, "-select_streams", "a", "-show_streams")["streams"]
                self.assertEqual([track["channels"] for track in streams], [2, 1])
                self.assertEqual([int(track["sample_rate"]) for track in streams], [44100, 48000])
                for index, metadata in enumerate(streams):
                    if format_name == "pcm":
                        self.assertTrue(metadata["codec_name"].startswith("pcm_"))
                    else:
                        self.assertEqual(metadata["codec_name"], "aac")
                    rate, channels = int(metadata["sample_rate"]), metadata["channels"]
                    source, actual = pcm(self.stereo, rate, index), pcm(output, rate, index)
                    # FFmpeg's AAC decoder can include padding in the last packet.
                    padding = 1023 if format_name == "aac" else 1
                    self.assertLessEqual(abs(len(actual) // channels - round(duration * rate)), padding)
                    self.assertAlmostEqual(float(metadata["duration"]), float(duration), delta=1 / rate)
                    offset = 0
                    for start, end in ranges:
                        # Sample immediately inside both sides of each edit.
                        length = (end - start) * rate // FPS
                        for position in [rate // 50, length - rate // 20]:
                            source_start = start * rate // FPS + position
                            output_start = offset + position
                            window = rate // 100
                            for channel in range(channels):
                                expected = source[channels * source_start + channel:
                                                  channels * (source_start + window):channels]
                                decoded = actual[channels * output_start + channel:
                                                 channels * (output_start + window):channels]
                                self.assertGreater(correlation(expected, decoded), 0.95,
                                                   f"{format_name} at frame {start}, track {index}, channel {channel}")
                        offset += length

    def test_auto_audio_copies_when_possible_and_reports_conversion(self):
        clips = [(self.stereo, Fraction(1), Fraction(2))]
        output = self.root / "auto-copy.mov"
        dry = self.export(output, clips, audio="auto", dry=True)
        self.assertEqual([track["action"] for track in dry["audio_actions"]], ["copy", "copy"])
        self.export(output, clips, audio="auto")
        for index, rate in enumerate([44100, 48000]):
            channels = 2 - index
            source = pcm(self.stereo, rate, index)
            self.assertEqual(pcm(output, rate, index), source[rate * channels:2 * rate * channels])

        output = self.root / "auto-convert.mp4"
        dry = self.export(output, clips, audio="auto", dry=True)
        self.assertEqual([track["action"] for track in dry["audio_actions"]], ["aac", "aac"])
        self.assertTrue(all(track.get("reason") for track in dry["audio_actions"]))
        # MP4 cannot carry PCM here, so the lossless sources become AAC. The reason says so, and the report states the rate.
        self.assertTrue(all("MP4 cannot carry PCM" in track["reason"] for track in dry["audio_actions"]))
        self.assertEqual([(track["codec"], track["bit_rate"]) for track in dry["audio_actions"]],
                         [("aac", 192_000), ("aac", 96_000)])
        report = self.export(output, clips, audio="copy", dry=True, ok=False)
        self.assertEqual(report["error"]["code"], "audio_copy_unavailable")

    def ntsc_picture(self):
        # 30000/1001 fps frames fall between 48 kHz samples, so a cut on them has no exact PCM copy.
        picture = self.root / "ntsc.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=30000/1001:d=3", "-c:v", "libx264", "-g", "30", "-bf", "2",
               "-threads", "1", "-pix_fmt", "yuv420p", picture)
        return picture

    @staticmethod
    def integer_samples(path, index=0):
        return array("i", ffmpeg("-i", path, "-map", f"0:a:{index}", "-c:a", "pcm_s32le", "-f", "s32le", "-"))

    def kept_samples(self, path, start, end, index=0, channels=2, rate=48000):
        # A cut between samples moves to the nearest one, by less than a sample.
        first, count = round(start * rate), round((end - start) * rate)
        return self.integer_samples(path, index)[first * channels:(first + count) * channels]

    def test_auto_keeps_the_lossless_source_format_with_identical_samples(self):
        picture = self.ntsc_picture()
        noise = ["-f", "lavfi", "-i", "anoisesrc=d=3:c=pink:r=48000:a=0.5:seed=5"]
        frames = (Fraction(7 * 1001, 30000), Fraction(61 * 1001, 30000))
        self.assertNotEqual((frames[0] * 48000).denominator, 1)
        # Matroska states each picture to the millisecond.
        milliseconds = (Fraction(234, 1000), Fraction(2035, 1000))
        sources = {}
        # Auto keeps the source's own codec and word length where the container carries it. MOV cannot carry FLAC and
        # ALAC is not verified in Matroska, so there the lossless source is written as PCM, and the reason says why.
        for name, codec, options, source_container, cut, container, action_name, written, depth, reason in [
            ("s16", "pcm_s16le", [], "mov", frames, "mov", "pcm", "pcm_s16le", 16, "The PCM source is written as PCM"),
            ("s24", "pcm_s24le", [], "mov", frames, "mkv", "pcm", "pcm_s24le", 24, "The PCM source is written as PCM"),
            ("alac", "alac", ["-sample_fmt", "s32p"], "mov", frames, "mov", "alac", "alac", 24, "The ALAC source is written as ALAC"),
            ("alac-mp4", "alac", ["-sample_fmt", "s16p"], "mov", frames, "mp4", "alac", "alac", 16, "The ALAC source is written as ALAC"),
            ("alac-mkv", "alac", ["-sample_fmt", "s32p"], "mov", frames, "mkv", "pcm", "pcm_s24le", 24,
             "MKV cannot carry ALAC here, so the lossless ALAC source is written as PCM."),
            ("flac", "flac", ["-sample_fmt", "s16"], "mkv", milliseconds, "mov", "pcm", "pcm_s16le", 16,
             "MOV cannot carry FLAC here, so the lossless FLAC source is written as PCM."),
            ("flac-mkv", "flac", ["-sample_fmt", "s32", "-bits_per_raw_sample", "24"], "mkv", milliseconds, "mkv", "flac", "flac", 24,
             "The FLAC source is written as FLAC"),
            ("flac-mp4", "flac", ["-sample_fmt", "s16"], "mkv", milliseconds, "mp4", "flac", "flac", 16, "The FLAC source is written as FLAC"),
        ]:
            with self.subTest(source=name):
                source = sources[name] = self.root / f"{name}.{source_container}"
                ffmpeg("-i", picture, *noise, "-map", "0:v", "-map", "1:a", "-ac", "2", "-c:v", "copy",
                       "-c:a", codec, *options, source)
                output = self.root / f"{name}-auto.{container}"
                report = self.export(output, [(source, *cut)], audio="auto")
                action = report["audio_actions"][0]
                self.assertEqual((action["action"], action["codec"], action["bit_depth"]), (action_name, written, depth))
                self.assertIn("Exact audio copy could not be verified", action["reason"])
                self.assertIn(reason, action["reason"])
                written_stream = stream(output, "a:0")
                self.assertEqual(written_stream["codec_name"], written)
                if written in ("flac", "alac"):
                    self.assertEqual(int(written_stream["bits_per_raw_sample"]), depth)
                self.assertEqual(self.integer_samples(output), self.kept_samples(source, *cut))
        # MP4 cannot carry PCM here. The conversion to AAC and its reason are reported.
        action = self.export(self.root / "lossless.mp4", [(sources["s24"], *frames)], audio="auto", dry=True)["audio_actions"][0]
        self.assertEqual((action["action"], action["codec"], action["bit_rate"]), ("aac", "aac", 192_000))
        self.assertIn("MP4 cannot carry PCM", action["reason"])
        # A named format is written as asked.
        action = self.export(self.root / "named.mov", [(sources["s24"], *frames)], audio="aac", dry=True)["audio_actions"][0]
        self.assertEqual((action["action"], action["codec"], action["bit_rate"]), ("aac", "aac", 192_000))
        self.assertNotIn("reason", action)
        # Matroska states no speaker positions for PCM, so a surround track stays lossless in MOV and becomes AAC in MKV.
        surround = self.root / "surround.mov"
        ffmpeg("-i", picture, *noise, "-map", "0:v", "-map", "1:a", "-ac", "6", "-channel_layout", "5.1", "-c:v", "copy",
               "-c:a", "pcm_s24le", surround)
        action = self.export(self.root / "surround-auto.mov", [(surround, *frames)], audio="auto", dry=True)["audio_actions"][0]
        self.assertEqual((action["action"], action["codec"]), ("pcm", "pcm_s24le"))
        action = self.export(self.root / "surround-auto.mkv", [(surround, *frames)], audio="auto", dry=True)["audio_actions"][0]
        self.assertEqual((action["action"], action["codec"], action["bit_rate"]), ("aac", "aac", 512_000))
        self.assertIn("MKV cannot keep the channel layout of PCM", action["reason"])

    def test_auto_decides_each_track_and_aac_follows_the_source_bit_rate(self):
        picture = self.ntsc_picture()
        noise = ["-f", "lavfi", "-i", "anoisesrc=d=3:c=pink:r=48000:a=0.5:seed=5"]
        source = self.root / "two-tracks.mov"
        ffmpeg("-i", picture, *noise, *noise, "-map", "0:v", "-map", "1:a", "-map", "2:a", "-ac", "2", "-c:v", "copy",
               "-c:a:0", "pcm_s24le", "-c:a:1", "aac", "-b:a:1", "256k", source)
        start, end = Fraction(7 * 1001, 30000), Fraction(61 * 1001, 30000)
        for container in ("mov", "mkv"):
            with self.subTest(container=container):
                output = self.root / f"two-tracks-auto.{container}"
                lossless, lossy = self.export(output, [(source, start, end)], audio="auto")["audio_actions"]
                self.assertEqual((lossless["action"], lossless["codec"], lossless["bit_depth"]), ("pcm", "pcm_s24le", 24))
                self.assertEqual((lossy["action"], lossy["codec"], lossy["bit_rate"]), ("aac", "aac", 256_000))
                self.assertNotIn("lossless", lossy["reason"])
                self.assertEqual([stream(output, f"a:{index}")["codec_name"] for index in range(2)], ["pcm_s24le", "aac"])
                self.assertEqual(self.integer_samples(output), self.kept_samples(source, start, end))
        # Two channels get 192 kbps without a measured AAC source. This one is written at its own rate.
        self.assertGreater(int(stream(self.root / "two-tracks-auto.mov", "a:1")["bit_rate"]), 224_000)

    @staticmethod
    def coded_rate(path, seconds, index=0):
        sizes = probe(path, "-select_streams", f"a:{index}", "-show_entries", "packet=size")["packets"]
        return sum(int(packet["size"]) for packet in sizes) * 8 / float(seconds)

    def test_auto_keeps_a_lossy_source_format_at_its_rate_or_falls_back_to_aac(self):
        picture = self.ntsc_picture()
        noise44 = ["-f", "lavfi", "-i", "anoisesrc=d=3:c=pink:r=44100:a=0.5:seed=7"]
        noise48 = ["-f", "lavfi", "-i", "anoisesrc=d=3:c=pink:r=48000:a=0.5:seed=5"]
        # Two clips: an AAC or Opus track is never copied across a join, and the other codecs miss a verified boundary.
        ntsc = [(Fraction(7 * 1001, 30000), Fraction(31 * 1001, 30000)), (Fraction(40 * 1001, 30000), Fraction(70 * 1001, 30000))]
        milliseconds = [(Fraction(234, 1000), Fraction(1034, 1000)), (Fraction(1335, 1000), Fraction(2336, 1000))]
        for name, noise, codec, source_container, container, action_name, reason in [
            ("mp3", noise44, ["-c:a", "libmp3lame", "-b:a", "192k"], "mov", "mov", "mp3", "The MP3 source is written as MP3 at its own rate."),
            ("mp3", noise44, ["-c:a", "libmp3lame", "-b:a", "192k"], "mov", "mp4", "mp3", "The MP3 source is written as MP3 at its own rate."),
            ("mp3", noise44, ["-c:a", "libmp3lame", "-b:a", "192k"], "mov", "mkv", "mp3", "The MP3 source is written as MP3 at its own rate."),
            ("opus", noise48, ["-c:a", "libopus", "-b:a", "128k"], "mkv", "mkv", "opus", "The Opus source is written as Opus at its own rate."),
            ("opus", noise48, ["-c:a", "libopus", "-b:a", "128k"], "mkv", "mov", "aac",
             "MOV cannot carry Opus here, so the lossy Opus source is written as AAC."),
            ("aac", noise48, ["-c:a", "aac", "-b:a", "256k"], "mp4", "mp4", "aac", "The AAC source is written as AAC at its own rate."),
            ("ac3", noise48, ["-c:a", "ac3", "-b:a", "384k"], "mkv", "mkv", "aac",
             "The FFmpeg helper has no AC-3 encoder, so the lossy AC-3 source is written as AAC."),
        ]:
            with self.subTest(source=name, container=container):
                source = self.root / f"{name}-source.{source_container}"
                if not source.exists():
                    ffmpeg("-i", picture, *noise, "-map", "0:v", "-map", "1:a", "-ac", "2", "-c:v", "copy", *codec, source)
                cuts = milliseconds if source_container == "mkv" else ntsc
                output = self.root / f"{name}-auto.{container}"
                action = self.export(output, [(source, *cut) for cut in cuts], audio="auto")["audio_actions"][0]
                self.assertEqual((action["action"], action["codec"]), (action_name, action_name))
                self.assertIn(reason, action["reason"])
                written = stream(output, "a:0")
                self.assertEqual(written["codec_name"], action_name)
                self.assertEqual(written["sample_rate"], stream(source, "a:0")["sample_rate"])
                duration = sum(end - start for start, end in cuts)
                rate = int(written["sample_rate"])
                if action_name == name:
                    # The track is encoded at the source's own rate, measured from the packets of both files.
                    source_rate = self.coded_rate(source, 3)
                    self.assertLess(abs(self.coded_rate(output, duration) - source_rate) / source_rate, 0.12, action)
                    self.assertLess(abs(action["bit_rate"] - source_rate) / source_rate, 0.12, action)
                # The sound stays on the picture clock: it starts at zero and correlates with the kept source ranges.
                self.assertEqual(float(written["start_time"]), 0)
                expected = array("f")
                decoded = pcm(source, rate)
                total = Fraction(0)
                for start, end in cuts:
                    first = round(start * rate)
                    count = round((total + end - start) * rate) - round(total * rate)
                    expected.extend(decoded[2 * first:2 * (first + count)])
                    total += end - start
                actual = pcm(output, rate)[:len(expected)]
                self.assertGreater(correlation(actual, expected), 0.9)

    def test_auto_keeps_each_track_format_and_encodes_compressed_tracks_once_across_batches(self):
        noise44 = ["-f", "lavfi", "-i", "anoisesrc=d=5:c=pink:r=44100:a=0.5:seed=7"]
        noise48 = ["-f", "lavfi", "-i", "anoisesrc=d=5:c=pink:r=48000:a=0.5:seed=5"]
        source = self.root / "flac-mp3.mkv"
        ffmpeg("-i", self.video, *noise48, *noise44, "-map", "0:v", "-map", "1:a", "-map", "2:a", "-ac", "2", "-c:v", "copy",
               "-c:a:0", "flac", "-sample_fmt:a:0", "s16", "-c:a:1", "libmp3lame", "-b:a:1", "160k", source)
        frames = [(i * 17) % 65 for i in range(40)]
        # Distinct names of one source and a small descriptor limit make several export batches, joined in a final mux.
        links = []
        for index in range(len(frames)):
            link = self.root / f"link-{index}.mkv"
            os.link(source, link)
            links.append(link)
        output = self.root / "batches.mkv"
        args = [CLI, "--no-sidecar", "export", "clips", "join", "--json", "--mode", "encode", "--audio", "auto", "--output", output]
        for link, frame in zip(links, frames):
            args += ["--clip", link, "--from", str(Fraction(frame, FPS)), "--to", str(Fraction(frame + 1, FPS))]
        report = json.loads(run(args, preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64)),
                                allow_diagnostics=True, timeout=300))
        lossless, lossy = report["audio_actions"]
        self.assertEqual((lossless["action"], lossless["codec"], lossless["bit_depth"]), ("flac", "flac", 16))
        self.assertEqual((lossy["action"], lossy["codec"], lossy["bit_rate"]), ("mp3", "mp3", 160_000))
        self.assertEqual([stream(output, f"a:{index}")["codec_name"] for index in range(2)], ["flac", "mp3"])
        # FLAC samples are identical to the kept frames: no batch seam adds or loses a sample.
        decoded = self.integer_samples(source)
        stride = 48000 // FPS * 2
        expected = array("i")
        for frame in frames:
            expected.extend(decoded[frame * stride:(frame + 1) * stride])
        self.assertEqual(self.integer_samples(output), expected)
        self.assertFalse(any(self.root.glob(".mpcut-*")))

    def test_pcm_from_lossy_sound_is_float_and_keeps_samples_above_full_scale(self):
        source = self.root / "hot.mp4"
        ffmpeg("-i", self.video, "-f", "lavfi", "-i", "anoisesrc=d=5:c=white:r=48000:a=1.0:seed=3",
               "-map", "0:v", "-map", "1:a", "-ac", "2", "-c:v", "copy", "-c:a", "aac", "-b:a", "64k", source)
        expected = pcm(source, 48000)[2 * 48000:2 * 3 * 48000]
        self.assertGreater(max(expected), 1.05)
        output = self.root / "hot-pcm.mov"
        action = self.export(output, [(source, Fraction(1), Fraction(3))], audio="pcm")["audio_actions"][0]
        self.assertEqual((action["action"], action["codec"], action["bit_depth"]), ("pcm", "pcm_f32le", 32))
        self.assertEqual(stream(output, "a:0")["codec_name"], "pcm_f32le")
        # Integer PCM would stop at full scale.
        self.assertAlmostEqual(max(pcm(output, 48000)), max(expected), places=3)

    def test_reencode_preserves_silent_mov_audio_edits(self):
        source = self.root / "delayed.mov"
        ffmpeg("-i", self.video, "-itsoffset", "1.75", "-f", "lavfi", "-i",
               "aevalsrc='if(between(t,0.05,0.16),0.65*sin(2*PI*997*t),0)':s=48000:d=0.25",
               "-map", "0:v:0", "-map", "1:a:0", "-t", "2", "-c:v", "libx264", "-g", "25",
               "-c:a", "aac", "-aac_pns", "0", source)
        joined = self.root / "joined.mov"
        run([CLI, "export", "clips", "join", "--json", "--output", joined, *(["--clip", source] * 4)], allow_diagnostics=True)
        decoded = run([self.decode_audio_native, joined])
        self.assertEqual(len(decoded), 8 * 48000 * 2)
        self.assertEqual(decoded[2 * 48000 * 2:3 * 48000 * 2], bytes(48000 * 2))
        self.assertTrue(any(decoded[3 * 48000 * 2:4 * 48000 * 2]))

        ranges = [(Fraction(37, 25), Fraction(6)), (Fraction(49, 25), Fraction(57, 25)),
                  (Fraction(13, 5), Fraction(16, 5))]
        output = self.root / "converted.mov"
        report = self.export(output, [(joined, start, end) for start, end in ranges], audio="pcm")
        self.assertEqual([track["action"] for track in report["audio_actions"]], ["pcm"])
        expected = b"".join(decoded[int(start * 48000) * 2:int(end * 48000) * 2] for start, end in ranges)
        self.assertEqual(run([self.decode_audio_native, output]), expected)

    def test_edited_surround_aac_preserves_channel_order(self):
        source = self.root / "surround.mov"
        frequencies = [399, 433, 477, 73, 599, 657]
        tones = "|".join(f"0.5*sin(2*PI*{frequency}*t)" for frequency in frequencies)
        ffmpeg("-i", self.video, "-itsoffset", "1", "-f", "lavfi", "-i",
               f"aevalsrc={tones}:s=48000:d=0.5:c=5.1", "-map", "0:v:0", "-map", "1:a:0",
               "-c:v", "copy", "-c:a", "aac", "-aac_pns", "0", source)
        output = self.root / "surround-pcm.mov"
        self.export(output, [(source, Fraction(0), Fraction(38, 25))], audio="pcm")
        self.assertEqual(stream(output, "a:0")["channel_layout"], "5.1")
        original = pcm(source, 48000)
        converted = pcm(output, 48000)
        start, end = 4800, 19200
        offset = int(stream(source, "a:0")["start_pts"])
        for channel in range(6):
            expected = original[6 * start + channel:6 * end:6]
            actual = converted[6 * (offset + start) + channel:6 * (offset + end):6]
            self.assertGreater(correlation(expected, actual), 0.99, f"channel {channel}")

    def test_copy_original_pcm_is_independent_of_video_keyframes(self):
        shifted = self.root / "nonzero-origin.mov"
        ffmpeg("-i", self.stereo, "-map", "0", "-c", "copy", "-output_ts_offset", "3.2", shifted)
        metadata = stream(shifted, "v:0")
        self.assertEqual(int(metadata["start_pts"]) * Fraction(metadata["time_base"]), Fraction(16, 5))
        ranges = [(111, 123), (15, 31), (111, 123)]
        clips = [(shifted, Fraction(start, FPS), Fraction(end, FPS)) for start, end in ranges]
        output = self.root / "copy-pcm.mov"
        report = self.export(output, clips, audio="copy")
        self.assertEqual([track["action"] for track in report["audio_actions"]], ["copy", "copy"])
        self.assertEqual(picture_ids(output), bytes(i for start, end in ranges for i in range(start, end)))
        for index, rate in enumerate([44100, 48000]):
            channels = 2 - index
            source = pcm(self.stereo, rate, index)
            expected = array("f")
            for start, end in ranges:
                expected.extend(source[start * rate // FPS * channels:end * rate // FPS * channels])
            self.assertEqual(stream(output, f"a:{index}")["codec_name"], "pcm_s16le")
            self.assertEqual(pcm(output, rate, index), expected)

    def test_big_endian_pcm_keeps_exact_samples_in_mov(self):
        source = self.root / "big-endian.mov"
        ffmpeg("-i", self.stereo, "-map", "0:v", "-map", "0:a:0", "-c:v", "copy", "-c:a", "pcm_s24be", source)
        self.assertEqual(stream(source, "a:0")["codec_name"], "pcm_s24be")
        for video, audio in [("h264", "auto"), ("prores", "copy")]:
            with self.subTest(video=video, audio=audio):
                output = self.root / f"big-endian-{video}.mov"
                report = self.export(output, [(source, 0, 5)], video=video, audio=audio)
                self.assertEqual([track["action"] for track in report["audio_actions"]], ["copy"])
                self.assertEqual(stream(output, "a:0")["codec_name"], "pcm_s24le")
                self.assertEqual(pcm(output, 44100), pcm(source, 44100))

    def test_double_float_pcm_stays_float_and_keeps_samples_above_full_scale(self):
        source = self.root / "double.mov"
        ffmpeg("-i", self.stereo, "-map", "0:v", "-map", "0:a:0", "-c:v", "copy", "-af", "volume=3",
               "-c:a", "pcm_f64le", source)
        self.assertGreater(max(pcm(source, 44100)), 1.2)
        output = self.root / "double-pcm.mov"
        report = self.export(output, [(source, 0, 5)], audio="pcm")
        self.assertEqual([track["action"] for track in report["audio_actions"]], ["pcm"])
        self.assertTrue(any("reduced to 32-bit float" in warning for warning in report["warnings"]), report["warnings"])
        self.assertEqual(stream(output, "a:0")["codec_name"], "pcm_f32le")
        self.assertEqual(pcm(output, 44100), pcm(source, 44100))

    def test_double_float_warning_looks_at_every_clip(self):
        integer, double = self.root / "integer.mov", self.root / "double.mov"
        ffmpeg("-i", self.stereo, "-map", "0:v", "-map", "0:a:0", "-c", "copy", integer)
        ffmpeg("-i", self.stereo, "-map", "0:v", "-map", "0:a:0", "-c:v", "copy", "-c:a", "pcm_f64le", double)
        for name, clips in (("integer-first.mov", [(integer, 0, 2), (double, 2, 4)]),
                            ("double-first.mov", [(double, 0, 2), (integer, 2, 4)])):
            with self.subTest(order=name):
                report = self.export(self.root / name, clips, audio="pcm", dry=True)
                self.assertEqual(report["audio_actions"][0]["codec"], "pcm_f32le")
                self.assertTrue(any("reduced to 32-bit float" in warning for warning in report["warnings"]), report["warnings"])

    @staticmethod
    def chapters(path):
        return [(Fraction(chapter["start_time"]), Fraction(chapter["end_time"]), chapter["tags"]["title"])
                for chapter in probe(path, "-show_chapters")["chapters"]]

    def test_chapters_follow_the_kept_ranges(self):
        listed = self.root / "chapters.ffmeta"
        titles = ["Intro", "Middle; with = signs", "Late", "End"]
        listed.write_text(";FFMETADATA1\ntitle=Chaptered\n" + "".join(
            f"[CHAPTER]\nTIMEBASE=1/1000\nSTART={index * 1500}\nEND={(index + 1) * 1500}\n"
            f"title={title.replace(';', chr(92) + ';').replace('=', chr(92) + '=')}\n" for index, title in enumerate(titles)))
        plain, source = self.root / "plain.mp4", self.root / "chaptered.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=6", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=6",
               "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "25", "-keyint_min", "25", "-sc_threshold", "0", "-bf", "0",
               "-c:a", "aac", "-b:a", "96k", plain)
        ffmpeg("-i", plain, "-i", listed, "-map", "0:v", "-map", "0:a", "-map_chapters", "1", "-c", "copy", source)
        whole = [(Fraction(index * 3, 2), Fraction((index + 1) * 3, 2), title) for index, title in enumerate(titles)]
        self.assertEqual(self.chapters(source), whole)
        half = Fraction(1, 2)
        for container in ("mp4", "mov", "mkv"):
            with self.subTest(container=container):
                output = self.root / f"whole.{container}"
                self.export(output, [(source, 0, 6)], audio="aac")
                self.assertEqual(self.chapters(output), whole)
                # A chapter is clipped to each kept range and moved by that range's output offset.
                output = self.root / f"trimmed.{container}"
                self.export(output, [(source, 1, 2), (source, 4, "28/5")], audio="aac")
                self.assertEqual(self.chapters(output), [(0 * half, 1 * half, titles[0]), (1 * half, 2 * half, titles[1]),
                                                         (2 * half, 3 * half, titles[2]), (3 * half, Fraction(13, 5), titles[3])])
                # A chapter wholly inside removed material is dropped.
                output = self.root / f"skipped.{container}"
                self.export(output, [(source, 0, 1), (source, 5, 6)], audio="aac")
                self.assertEqual(self.chapters(output), [(Fraction(0), Fraction(1), titles[0]), (Fraction(1), Fraction(2), titles[3])])
                self.assertEqual(len(packets(output)), 50)
        # The same ranges through a packet copy carry the same chapters.
        copied = self.root / "copied.mp4"
        run([CLI, "export", "clips", "join", "--json", "--mode", "copy", "--output", copied,
             "--clip", source, "--from", "1", "--to", "2", "--clip", source, "--from", "4", "--to", "5"], allow_diagnostics=True)
        encoded = self.root / "encoded.mp4"
        self.export(encoded, [(source, 1, 2), (source, 4, 5)], audio="aac")
        self.assertEqual(self.chapters(encoded), self.chapters(copied))
        # A source without chapters gets none, and no chapter track.
        output = self.root / "plain-out.mp4"
        report = self.export(output, [(plain, 0, 6)], audio="aac")
        self.assertEqual((self.chapters(output), report["warnings"]), ([], []))
        self.assertEqual([item["codec_type"] for item in probe(output, "-show_streams")["streams"]], ["video", "audio"])

    def test_subtitle_and_data_tracks_follow_the_kept_ranges(self):
        # Re-encode copies subtitle cues and telemetry samples where the container holds their codec, as a copy does:
        # a cue that runs across a cut is shortened, and its text is not touched.
        captions = self.root / "captions.srt"
        captions.write_text("1\n00:00:00,500 --> 00:00:02,000\nHello\n\n2\n00:00:02,500 --> 00:00:05,500\nAcross\n\n"
                            "3\n00:00:06,000 --> 00:00:07,000\nLater\n")
        base = self.root / "base.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=8", "-f", "lavfi", "-i", "sine=r=48000:d=8",
               "-c:v", "libx264", "-g", "25", "-bf", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", base)

        def cues(path, selector="s:0"):
            listed = probe(path, "-select_streams", selector, "-show_entries", "packet=pts_time,duration_time,data_hash",
                           "-show_data_hash", "sha256")["packets"]
            # MP4 can end an empty range with a zero-length cue that has no duration.
            return [(Fraction(item["pts_time"]), Fraction(item.get("duration_time", "0")), item["data_hash"]) for item in listed]

        def kinds(path):
            return [track["codec_type"] for track in probe(path, "-show_streams")["streams"]]

        for extension, codec in [("mp4", "mov_text"), ("mov", "mov_text"), ("mkv", "srt"), ("mkv", "ass"), ("mkv", "webvtt")]:
            with self.subTest(extension=extension, codec=codec):
                source = self.root / f"captions-{codec}.{extension}"
                ffmpeg("-i", base, "-i", captions, "-map", "0", "-map", "1", "-c:v", "copy", "-c:a", "copy", "-c:s", codec,
                       "-metadata:s:s:0", "language=fra", source)
                whole = self.root / f"whole-{codec}.{extension}"
                report = self.export(whole, [(source, 0, 8)])
                self.assertEqual(report["warnings"], [])
                self.assertEqual(kinds(whole), ["video", "subtitle"])
                self.assertEqual(cues(whole), cues(source))
                self.assertEqual(stream(whole, "s:0")["tags"].get("language"), "fra")
                # 3 s to 6.4 s: "Across" starts before the cut and is shortened. "Hello" lies outside and is dropped.
                trimmed = self.root / f"trim-{codec}.{extension}"
                planned = self.export(trimmed, [(source, 3, Fraction(32, 5))], dry=True)
                self.assertEqual(self.export(trimmed, [(source, 3, Fraction(32, 5))])["warnings"], planned["warnings"])
                hello, across, later = (digest for start, _, digest in cues(source) if start in (Fraction(1, 2), Fraction(5, 2), 6))
                self.assertEqual([cue for cue in cues(trimmed) if cue[2] in (hello, across, later)],
                                 [(0, Fraction(5, 2), across), (3, Fraction(2, 5), later)])
                # Two ranges, the first without a cue: each cue moves by its own range's output offset.
                joined = self.root / f"joined-{codec}.{extension}"
                self.export(joined, [(source, Fraction(36, 5), 8), (source, Fraction(12, 25), 2)])
                self.assertEqual([cue for cue in cues(joined) if cue[2] in (hello, across, later)],
                                 [(Fraction(41, 50), Fraction(3, 2), hello)])
                self.assertEqual(len(packets(joined)), 58)
                if codec == "srt":
                    # Beside converted sound in Matroska: the picture and sound durations are finalized, the cues stay.
                    joined = self.root / "joined-aac.mkv"
                    self.export(joined, [(source, Fraction(12, 25), Fraction(13, 5)), (source, 3, Fraction(32, 5))], audio="aac")
                    self.assertEqual(kinds(joined), ["video", "audio", "subtitle"])
                    self.assertEqual([cue for cue in cues(joined) if cue[2] in (hello, across, later)],
                                     [(Fraction(1, 50), Fraction(3, 2), hello), (Fraction(101, 50), Fraction(1, 10), across),
                                      (Fraction(53, 25), Fraction(5, 2), across), (Fraction(128, 25), Fraction(2, 5), later)])
                    self.assertEqual(len(packets(joined)), 138)

        # A codec the container has no place for is left out, and named in the plan and the result alike. A helper
        # without subtitle encoders, as before text conversion, cannot make 3GPP text into SubRip for Matroska.
        millisecond = "MKV uses millisecond presentation timestamps. Sub-millisecond timing will be rounded."
        mp4_captions = self.root / "captions-mov_text.mp4"
        earlier = self.earlier_helper()
        for dry in (True, False):
            report = self.export(self.root / "no-captions.mkv", [(mp4_captions, 0, 8)], dry=dry, env=earlier)
            self.assertEqual(report["warnings"], [millisecond, "Clip 1 subtitle track 2 (mov_text) cannot be carried in MKV and is left out."])
        self.assertEqual(kinds(self.root / "no-captions.mkv"), ["video"])
        report = self.export(self.root / "no-captions.mp4", [(self.root / "captions-srt.mkv", 0, 8)], dry=True, env=earlier)
        self.assertEqual(report["warnings"], ["Clip 1 subtitle track 2 (subrip) cannot be carried in MP4 and is left out."])

        # GoPro telemetry: one-second samples. A trim keeps the samples that lie wholly inside the range, and says so.
        blob = self.root / "telemetry.bin"
        blob.write_bytes(b"".join(bytes([sample]) * 1024 for sample in range(8)))
        telemetry = self.root / "telemetry.mov"
        ffmpeg("-i", base, "-f", "data", "-raw_packet_size", "1024", "-i", blob, "-map", "0", "-map", "1", "-c", "copy",
               "-tag:d", "gpmd", "-bsf:d", "setts=ts=N*90000:duration=90000:time_base=1/90000", telemetry)
        samples = cues(telemetry, "d:0")
        self.assertEqual(len(samples), 8)
        for extension in ("mov", "mp4"):
            with self.subTest(telemetry=extension):
                whole = self.root / f"telemetry-whole.{extension}"
                self.assertEqual(self.export(whole, [(telemetry, 0, 8)])["warnings"], [])
                self.assertEqual(cues(whole, "d:0"), samples)
                self.assertEqual(stream(whole, "d:0")["codec_tag_string"], "gpmd")
                trimmed = self.root / f"telemetry-trim.{extension}"
                report = self.export(trimmed, [(telemetry, 2, 5)])
                self.assertEqual(report["warnings"], ["Data track 2 (gpmd) keeps only the samples that lie wholly inside the kept ranges."])
                self.assertEqual(cues(trimmed, "d:0"), [(start - 2, length, digest) for start, length, digest in samples[2:5]])
        report = self.export(self.root / "telemetry.mkv", [(telemetry, 0, 8)], dry=True)
        self.assertEqual(report["warnings"], [millisecond, "Clip 1 data track 2 (gpmd) cannot be carried in MKV and is left out."])

    def earlier_helper(self):
        """The environment of a helper that lists no subtitle encoder, as helpers before text conversion did. It runs
        the helper that MPCut finds for this suite: MPCUT_FFMPEG_HELPER, the one beside the CLI, or the development build."""
        candidates = [os.environ.get("MPCUT_FFMPEG_HELPER"), Path(CLI).parent / "ffmpeg",
                      Path(__file__).resolve().parents[2] / ".build/mpcut-ffmpeg/install/bin/ffmpeg"]
        real = next(Path(path) for path in candidates if path and Path(path).is_file() and os.access(path, os.X_OK))
        earlier = self.root / "earlier helper" / "ffmpeg"
        earlier.parent.mkdir()
        earlier.write_text('#!/bin/sh\ncase " $* " in\n  *" -encoders "*) "%s" "$@" | grep -v "^ S"; exit 0 ;;\n'
                           'esac\nexec "%s" "$@"\n' % (real, real))
        earlier.chmod(0o755)
        return dict(os.environ, MPCUT_FFMPEG_HELPER=str(earlier))

    @staticmethod
    def text_cues(path):
        """The cues of the first subtitle track as (start, length, text), without the empty samples between MP4 cues."""
        codec = stream(path, "s:0")["codec_name"]
        listed = probe(path, "-select_streams", "s:0", "-show_entries", "packet=pts_time,duration_time,data",
                       "-show_data")["packets"]
        cues = []
        for item in listed:
            # ffprobe dumps 16 bytes a line: an offset, eight groups of hex digits, then the characters.
            data = bytes.fromhex("".join("".join(line[10:49].split()) for line in item.get("data", "").splitlines()))
            if codec == "mov_text":
                data = data[2:2 + int.from_bytes(data[:2], "big")]
            if data:
                cues.append((Fraction(item["pts_time"]), Fraction(item.get("duration_time", "0")), data.decode()))
        return cues

    def test_text_subtitles_are_converted_where_the_container_needs_another_codec(self):
        # SubRip, ASS and WebVTT become 3GPP text in MP4 and MOV, and 3GPP text becomes SubRip in Matroska. The kept ranges
        # are staged as packet copies, as above, and then converted, so each cue keeps its text, remapped start and length.
        captions = self.root / "captions.srt"
        captions.write_text("1\n00:00:00,500 --> 00:00:02,000\nHello\n\n2\n00:00:02,500 --> 00:00:05,500\nAcross\n\n"
                            "3\n00:00:06,000 --> 00:00:07,000\nLater\n")
        base = self.root / "base.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=8", "-f", "lavfi", "-i", "sine=r=48000:d=8",
               "-c:v", "libx264", "-g", "25", "-bf", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", base)
        ranges = {"whole": [(0, 8)], "trim": [(3, Fraction(32, 5))], "joined": [(Fraction(36, 5), 8), (Fraction(12, 25), 2)]}
        expected = {"whole": [(Fraction(1, 2), Fraction(3, 2), "Hello"), (Fraction(5, 2), 3, "Across"), (6, 1, "Later")],
                    "trim": [(0, Fraction(5, 2), "Across"), (3, Fraction(2, 5), "Later")],
                    "joined": [(Fraction(41, 50), Fraction(3, 2), "Hello")]}
        millisecond = "MKV uses millisecond presentation timestamps. Sub-millisecond timing will be rounded."
        overlap = (" 3GPP text shows one cue at a time, so where cues overlap the track is split at each cue's start "
                   "and end, and each part shows every cue on screen then, one under the other in cue order.")
        kept = {"subrip": "its bold, italic, underline, colour, font and size are kept; its strikethrough, alignment and "
                          "position are not",
                "ass": "the bold, italic, underline, colour, transparency, font and size of its styles and overrides are kept; "
                       "strikethrough, outline and shadow colours, scaling, spacing, rotation, blur, positions, alignment, "
                       "margins, outlines, shadows, animation and karaoke are not",
                "webvtt": "its bold, italic and underline are kept; its cue settings, classes, voices and timed karaoke are not"}
        # The font table holds the fonts a style line can name, sizes are scaled to the picture and held in one byte,
        # ASS layers are flattened, and a 3GPP text sample has one highlight span, which only ASS sets.
        fonts = " A font whose name has a comma or is longer than 255 bytes is shown in the default font."
        clamp = "; a size above 255 pixels, the most 3GPP text holds, is written at 255."
        highlight = {"subrip": fonts + " Font sizes are measured against 288 lines and scaled to the picture's height" + clamp,
                     "ass": fonts + " Font sizes are scaled from the script's PlayResY (288 when it states none) to the "
                     "picture's height" + clamp + " Layers are flattened: lines shown at once are placed one under the other, "
                     "and identical lines on different layers appear once, in the style of the one drawn on top. Where two cues "
                     "shown together both set a highlight (secondary colour), it runs from the first to the last."}
        written = {"mp4": ("mov_text", "tx3g"), "mov": ("mov_text", "text"), "mkv": ("subrip", "[0][0][0][0]")}
        for codec, extension, target in [("srt", "mkv", "mp4"), ("srt", "mkv", "mov"), ("ass", "mkv", "mp4"), ("ass", "mkv", "mov"),
                                         ("webvtt", "mkv", "mp4"), ("webvtt", "mkv", "mov"),
                                         ("mov_text", "mp4", "mkv"), ("mov_text", "mov", "mkv")]:
            with self.subTest(codec=codec, source=extension, target=target):
                source = self.root / f"captions-{codec}.{extension}"
                if not source.exists():
                    ffmpeg("-i", base, "-i", captions, "-map", "0", "-map", "1", "-c:v", "copy", "-c:a", "copy",
                           "-c:s", codec, "-metadata:s:s:0", "language=fra", source)
                name = "subrip" if codec == "srt" else codec
                if target == "mkv":
                    # FFmpeg writes 3GPP text on a microsecond clock; Matroska keeps milliseconds.
                    note = [millisecond, "Subtitle track 2 (mov_text) is converted to SubRip for MKV. Its text and line "
                            "breaks are kept, and its bold, italic, underline, colour, font, size and alignment become SubRip "
                            "tags; its background colour, transparency, highlighting and text box are not kept. "
                            "Cue times finer than a millisecond are rounded."]
                else:
                    note = [f"Subtitle track 2 ({name}) is converted to 3GPP text for {target.upper()}. Its text and line "
                            f"breaks and {kept[name]}.{overlap}{highlight.get(name, '')}"]
                for label, spans in ranges.items():
                    output = self.root / f"{label}-{codec}-{extension}.{target}"
                    clips = [(source, start, end) for start, end in spans]
                    planned = self.export(output, clips, dry=True)
                    report = self.export(output, clips)
                    self.assertEqual(report["warnings"], planned["warnings"])
                    self.assertEqual(report["warnings"], note)
                    track = stream(output, "s:0")
                    self.assertEqual((track["codec_name"], track["codec_tag_string"]), written[target])
                    self.assertEqual(track["tags"].get("language"), "fra")
                    self.assertEqual(self.text_cues(output), expected[label])

        # Overlapping cues: 3GPP text holds one sample at a time, so the track is split at every cue start and end, and
        # each part holds the text of every cue shown then, in cue order. Each cue keeps its own styling: the italic that
        # "One" leaves open stops at its own line, and "Two" alone is bold.
        overlapping = self.root / "overlap.srt"
        overlapping.write_text("1\n00:00:01,000 --> 00:00:04,000\nOne <i>italic\n\n2\n00:00:02,000 --> 00:00:05,000\n<b>Two</b>\n\n"
                               "3\n00:00:02,000 --> 00:00:03,500\nSame start\n\n4\n00:00:06,000 --> 00:00:07,000\nLater\n")
        together, pair = "One italic\nTwo\nSame start", "One italic\nTwo"
        joined_cues = {"whole": [(0, 8)], "trim": [(3, 6)], "joined": [(3, 6), (Fraction(62, 25), Fraction(87, 25))]}
        joined_expected = {
            "whole": [(1, 1, "One italic"), (2, Fraction(3, 2), together), (Fraction(7, 2), Fraction(1, 2), pair),
                      (4, 1, "Two"), (6, 1, "Later")],
            # Three cues that all cross the start of the range land at zero together.
            "trim": [(0, Fraction(1, 2), together), (Fraction(1, 2), Fraction(1, 2), pair), (1, 1, "Two")],
            "joined": [(0, Fraction(1, 2), together), (Fraction(1, 2), Fraction(1, 2), pair), (1, 1, "Two"), (3, 1, together)]}
        for codec in ("srt", "ass", "webvtt"):
            source = self.root / f"overlap-{codec}.mkv"
            ffmpeg("-i", base, "-i", overlapping, "-map", "0:v", "-map", "1", "-c:v", "copy", "-c:s", codec, source)
            name = "subrip" if codec == "srt" else codec
            for target in ("mp4", "mov"):
                for label, spans in joined_cues.items():
                    with self.subTest(overlap=codec, target=target, range=label):
                        output = self.root / f"overlap-{label}-{codec}.{target}"
                        clips = [(source, start, end) for start, end in spans]
                        planned = self.export(output, clips, dry=True)
                        report = self.export(output, clips)
                        self.assertEqual(report["warnings"], planned["warnings"])
                        self.assertEqual(report["warnings"], [
                            f"Subtitle track 1 ({name}) is converted to 3GPP text for {target.upper()}. Its text and line "
                            f"breaks and {kept[name]}.{overlap}{highlight.get(name, '')}"])
                        self.assertEqual(self.text_cues(output), joined_expected[label])
                        if label == "whole":
                            text, records = next((text, records) for _, text, records in self.text_styles(output)
                                                 if text == together)
                            italic = set(range(4, 10))
                            bold = set(range(11, 14))
                            self.assertEqual([self.style_at(records, index)[0] for index, character in enumerate(text) if character != "\n"],
                                             [2 if index in italic else 1 if index in bold else 0
                                              for index, character in enumerate(text) if character != "\n"])

        # ASS cues of different styles keep their own style when they are shown together.
        script = self.root / "styled.ass"
        script.write_text(
            "[Script Info]\nScriptType: v4.00+\nPlayResX: 384\nPlayResY: 288\n\n[V4+ Styles]\n"
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, "
            "Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, "
            "MarginV, Encoding\n"
            "Style: Default,Arial,16,&H00FFFFFF,&H00FFFFFF,&H0,&H0,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0\n"
            "Style: Loud,Arial,16,&H000000FF,&H00FFFFFF,&H0,&H0,1,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0\n\n"
            "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
            "Dialogue: 0,0:00:01.00,0:00:03.00,Loud,,0,0,0,,Loud\n"
            "Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,Plain\n")
        source = self.root / "styled.mkv"
        ffmpeg("-i", base, "-i", script, "-map", "0:v", "-map", "1", "-c:v", "copy", "-c:s", "copy", source)
        output = self.root / "styled.mp4"
        self.export(output, [(source, 0, 8)])
        self.assertEqual(self.text_cues(output), [(1, 1, "Loud"), (2, 1, "Loud\nPlain"), (3, 1, "Plain")])
        text, records = next((text, records) for _, text, records in self.text_styles(output) if text == "Loud\nPlain")
        # Bold red from the Loud style for its own line only.
        self.assertEqual([self.style_at(records, index) for index, character in enumerate(text) if character != "\n"],
                         [(1, 0xFF0000FF)] * 4 + [(0, 0xFFFFFFFF)] * 5)
        # A reset does not clear italic in the encoder, so a later cue states its whole style: "Plain" is not italic.
        script.write_text(script.read_text().replace(",Loud,,0,0,0,,Loud\n", ",Default,,0,0,0,,{\\i1}One\n"))
        source = self.root / "unclosed.mkv"
        ffmpeg("-i", base, "-i", script, "-map", "0:v", "-map", "1", "-c:v", "copy", "-c:s", "copy", source)
        output = self.root / "unclosed.mp4"
        self.export(output, [(source, 0, 8)])
        text, records = next((text, records) for _, text, records in self.text_styles(output) if text == "One\nPlain")
        self.assertEqual([self.style_at(records, index)[0] for index, character in enumerate(text) if character != "\n"],
                         [2] * 3 + [0] * 5)

    def test_three_gpp_text_keeps_colours_sizes_and_fonts(self):
        # FFmpeg's 3GPP text encoder drops \c colours (SubRip font colours become them), writes size zero after a bare
        # \fs (a closing SubRip font size), knows only the fonts of the script's styles, and starts each style record
        # from the default style. The cues are rewritten so each character keeps its colour, size and font.
        # A 288-line picture, the height SubRip sizes and this script are measured against, keeps sizes as written.
        base = self.root / "styles-base.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=512x288:r=25:d=9", "-c:v", "libx264", "-g", "25", "-bf", "0",
               "-pix_fmt", "yuv420p", base)
        subrip = self.root / "styles.srt"
        subrip.write_text('1\n00:00:01,000 --> 00:00:02,000\na <font color="#ff0000">Red</font> b\n\n'
                          '2\n00:00:03,000 --> 00:00:04,000\na <font size="30">Big</font> b\n\n'
                          '3\n00:00:05,000 --> 00:00:06,000\na <font face="Courier">Mono</font> b\n')
        script = self.root / "styles.ass"
        script.write_text(
            "[Script Info]\nScriptType: v4.00+\nPlayResX: 384\nPlayResY: 288\n\n[V4+ Styles]\n"
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, "
            "Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, "
            "MarginV, Encoding\n"
            "Style: Default,Arial,16,&H00FFFFFF,&H00FFFFFF,&H0,&H0,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0\n"
            "Style: Green,Arial,20,&H0000FF00,&H00FFFFFF,&H0,&H0,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0\n\n"
            "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
            "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,a {\\c&H0000FF&}Red{\\c} b\n"
            "Dialogue: 0,0:00:03.00,0:00:04.00,Green,,0,0,0,,a {\\fs30}Big{\\fs} b\n"
            "Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,a {\\fnCourier}Mono{\\fn} b\n"
            "Dialogue: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,a {\\alpha&H80&}Half{\\alpha} b\n")
        white, red, green = 0xFFFFFFFF, 0xFF0000FF, 0x00FF00FF
        # (font, flags, size, RGBA colour) of each character; font 1 is Arial, the default style's font.
        plain = (1, 0, 16, white)
        expected = {"a Red b": [plain] * 2 + [(1, 0, 16, red)] * 3 + [plain] * 2,
                    "a Big b": [plain] * 2 + [(1, 0, 30, white)] * 3 + [plain] * 2,
                    "a Mono b": [plain] * 2 + [(2, 0, 16, white)] * 4 + [plain] * 2}
        for codec, captions in (("srt", subrip), ("ass", script)):
            with self.subTest(codec=codec):
                source = self.root / f"styles-{codec}.mkv"
                ffmpeg("-i", base, "-i", captions, "-map", "0:v", "-map", "1", "-c:v", "copy", "-c:s", codec, source)
                output = self.root / f"styles-{codec}.mp4"
                self.export(output, [(source, 0, 9)])
                samples = {text: records for _, text, records in self.text_styles(output)}
                wanted = dict(expected)
                if codec == "ass":
                    # Green keeps its colour and size around the override, and \alpha sets the transparency.
                    wanted["a Big b"] = [(1, 0, 20, green)] * 2 + [(1, 0, 30, green)] * 3 + [(1, 0, 20, green)] * 2
                    wanted["a Half b"] = [plain] * 2 + [(1, 0, 16, 0xFFFFFF7F)] * 4 + [plain] * 2
                for text, styles in wanted.items():
                    self.assertEqual([self.full_style_at(samples[text], index) for index in range(len(text))], styles, text)
                # Courier is in the sample description's font table, as font 2.
                dump = probe(output, "-select_streams", "s:0", "-show_streams", "-show_data")["streams"][0].get("extradata", "")
                description = bytes.fromhex("".join("".join(line[10:49].split()) for line in dump.splitlines()))
                self.assertIn(b"\x00\x02\x07Courier", description)

    def test_three_gpp_text_scales_sizes_and_flattens_layers(self):
        # 3GPP text sizes are pixels of the picture, so the script's sizes are scaled from its height (SubRip and a
        # script without PlayResY: 288 lines) to the picture's, and held in one byte: a larger size is written at 255.
        base = self.root / "tall-base.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=25:d=8", "-c:v", "libx264", "-g", "25", "-bf", "0",
               "-pix_fmt", "yuv420p", base)
        subrip = self.root / "sizes.srt"
        subrip.write_text('1\n00:00:01,000 --> 00:00:02,000\na <font size="30">Big</font> b\n')
        script = self.root / "layers.ass"
        script.write_text(
            "[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\n"
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, "
            "Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, "
            "MarginV, Encoding\n"
            "Style: Default,Arial,16,&H00FFFFFF,&H00FFFFFF,&H0,&H0,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0\n"
            "Style: Huge,Arial,100,&H00FFFFFF,&H00FFFFFF,&H0,&H0,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0\n\n"
            "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
            "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\c&H000000&\\bord4}Sign\n"
            "Dialogue: 1,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\c&H0000FF&}Sign\n"
            "Dialogue: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,Speech\n"
            "Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,a {\\fs100}Big{\\fs} b\n"
            "Dialogue: 0,0:00:06.00,0:00:07.00,Huge,,0,0,0,,Huge\n")
        white, red = 0xFFFFFFFF, 0xFF0000FF
        default = (1, 0, 60, white)  # 16 at 288 lines is 60 at 1080
        for codec, captions in (("srt", subrip), ("ass", script)):
            with self.subTest(codec=codec):
                source = self.root / f"tall-{codec}.mkv"
                ffmpeg("-i", base, "-i", captions, "-map", "0:v", "-map", "1", "-c:v", "copy", "-c:s", codec, source)
                output = self.root / f"tall-{codec}.mp4"
                self.export(output, [(source, 0, 8)])
                dump = probe(output, "-select_streams", "s:0", "-show_streams", "-show_data")["streams"][0].get("extradata", "")
                description = bytes.fromhex("".join("".join(line[10:49].split()) for line in dump.splitlines()))
                self.assertEqual(description[25], 60)  # the default style record's size
                samples = {text: records for _, text, records in self.text_styles(output)}

                def styles(text):
                    return [self.full_style_at(samples[text], index, default) for index in range(len(text))]

                if codec == "srt":
                    self.assertEqual(styles("a Big b"), [default] * 2 + [(1, 0, 113, white)] * 3 + [default] * 2)
                    continue
                # 100 at 288 lines would be 375 pixels: written at 255, where FFmpeg would have wrapped it to 119.
                self.assertEqual(styles("a Big b"), [default] * 2 + [(1, 0, 255, white)] * 3 + [default] * 2)
                self.assertEqual(styles("Huge"), [(1, 0, 255, white)] * 4)
                # The two layers of "Sign" are one line in the top layer's red; "Speech" beside it stays.
                self.assertEqual([text for _, _, text in self.text_cues(output)][:2], ["Sign", "Sign\nSpeech"])
                self.assertEqual(styles("Sign"), [(1, 0, 60, red)] * 4)

    @staticmethod
    def text_styles(path):
        """The 3GPP text samples of the first subtitle track that hold text, as (start, text, style records), each record
        (first character, end character, font, flags, size, RGBA colour) from the sample's 'styl' box."""
        listed = probe(path, "-select_streams", "s:0", "-show_entries", "packet=pts_time,data", "-show_data")["packets"]
        samples = []
        for item in listed:
            data = bytes.fromhex("".join("".join(line[10:49].split()) for line in item.get("data", "").splitlines()))
            length = int.from_bytes(data[:2], "big")
            if not length:
                continue
            text, boxes, records = data[2:2 + length].decode(), data[2 + length:], []
            while len(boxes) >= 8:
                size = int.from_bytes(boxes[:4], "big")
                if boxes[4:8] == b"styl":
                    count = int.from_bytes(boxes[8:10], "big")
                    for offset in range(10, 10 + 12 * count, 12):
                        record = boxes[offset:offset + 12]
                        records.append((int.from_bytes(record[0:2], "big"), int.from_bytes(record[2:4], "big"),
                                        int.from_bytes(record[4:6], "big"), record[6], record[7],
                                        int.from_bytes(record[8:12], "big")))
                boxes = boxes[max(size, 8):]
            samples.append((Fraction(item["pts_time"]), text, records))
        return samples

    @staticmethod
    def style_at(records, index):
        """The style flags (1 bold, 2 italic, 4 underline) and RGBA colour of the character at `index`, where no record
        covers it the white of the default style."""
        return next(((flags, color) for start, end, _, flags, _, color in records if start <= index < end), (0, 0xFFFFFFFF))

    @staticmethod
    def full_style_at(records, index, default=(1, 0, 16, 0xFFFFFFFF)):
        """The font, style flags, size and RGBA colour of the character at `index`, where no record covers it those of
        the sample description's default style, by default Arial (font 1) at 16 in white."""
        return next(((font, flags, size, color) for start, end, font, flags, size, color in records if start <= index < end),
                    default)

    def test_damaged_sound_is_named_as_sound(self):
        good, damaged = self.root / "good.mp4", self.root / "damaged.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=3", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3",
               "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "25", "-c:a", "flac", "-strict", "-2", good)
        ffmpeg("-i", good, "-c", "copy", "-bsf:a", "noise=amount=1:drop=0", "-strict", "-2", damaged, allow_diagnostics=True)
        output = self.root / "damaged-out.mov"
        report = self.export(output, [(damaged, 1, 2)], audio="pcm", ok=False)
        self.assertEqual(report["error"]["code"], "encode_failed")
        self.assertTrue(report["error"]["message"].startswith("The sound of damaged.mp4 (audio track 1) is damaged"), report["error"])
        self.assertNotIn("picture", report["error"]["message"])
        self.assertFalse(any(self.root.glob(".mpcut-*")))

    def test_chroma_reduction_is_reported_before_export(self):
        source = self.root / "prores-4444.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=128x96:r=25:d=1", "-c:v", "prores_ks", "-profile:v", "4",
               "-pix_fmt", "yuv444p10le", source)
        for video, expected in [("prores", "chroma from 4:4:4 to 4:2:2"), ("h264", "chroma from 4:4:4 to 4:2:0")]:
            with self.subTest(video=video):
                report = self.export(self.root / f"chroma-{video}.mov", [(source, 0, 1)], video=video, dry=True)
                self.assertTrue(any(expected in warning for warning in report["warnings"]), report["warnings"])
        report = self.export(self.root / "plain.mp4", [(self.video, 0, 1)], dry=True)
        self.assertFalse(any("chroma" in warning for warning in report["warnings"]), report["warnings"])

    def test_variable_frame_timing_survives_a_discontinuous_edit(self):
        for clock, frame_ticks in [(25, 1), (30000, 1001)]:
            with self.subTest(clock=clock):
                source = self.root / f"vfr-{clock}.mp4"
                ffmpeg("-i", self.video, "-an",
                       "-vf", f"settb=1/{clock},setpts='(N+floor(N/9))*{frame_ticks}'",
                       "-fps_mode", "passthrough", "-enc_time_base", f"1/{clock}",
                       "-c:v", "libx264", "-threads", "1", "-x264-params", "bframes=3", source)
                timestamps = sorted(t for t, _ in timestamped_hashes(source))
                ranges = [(46, 73), (6, 18), (46, 54)]
                clips = [(source, timestamps[start], timestamps[end]) for start, end in ranges]
                output = self.root / f"vfr-{clock}-cut.mp4"
                report = self.export(output, clips)
                expected_times = []
                previous_end = Fraction(0)
                for start, end in ranges:
                    expected_times.extend(previous_end + t - timestamps[start] for t in timestamps[start:end])
                    previous_end += timestamps[end] - timestamps[start]
                frame_duration = Fraction(frame_ticks, clock)
                self.assertEqual({b - a for a, b in zip(expected_times, expected_times[1:])},
                                 {frame_duration, 2 * frame_duration})
                self.assertEqual(previous_end - expected_times[-1], 2 * frame_duration)
                self.assertEqual(ratio(report["duration"]), previous_end)
                self.assertEqual(sorted(t for t, _ in timestamped_hashes(output)), expected_times)
                self.assertEqual(picture_ids(output), bytes(i for start, end in ranges for i in range(start, end)))
                metadata = stream(output, "v:0")
                self.assertEqual(int(metadata["duration_ts"]) * Fraction(metadata["time_base"]), previous_end)

    def test_portrait_av1_opus_source_reencodes_to_mp4(self):
        source = movie(self.root / "portrait.webm", "av1", width=180, height=320)
        ranges = [(43, 68), (7, 25)]
        clips = [(source, Fraction(start, FPS), Fraction(end, FPS)) for start, end in ranges]
        output = self.root / "portrait-av1.mp4"
        report = self.export(output, clips, audio="auto")
        # MP4 carries Opus, so Auto keeps the source's codec.
        self.assertEqual([action["action"] for action in report["audio_actions"]], ["opus"])
        self.assertIn("The Opus source is written as Opus at its own rate.", report["audio_actions"][0]["reason"])
        metadata = stream(output, "v:0")
        self.assertEqual((metadata["width"], metadata["height"]), (180, 320))
        sound = stream(output, "a:0")
        self.assertEqual(sound["codec_name"], "opus")
        self.assertEqual(int(sound["start_pts"]), 0)
        expected = bytes(i for start, end in ranges for i in range(start, end))
        self.assertEqual(int(sound["duration_ts"]) * Fraction(sound["time_base"]), Fraction(len(expected), FPS))
        self.assertEqual(picture_ids(output), expected)
        self.assertEqual(run([self.decode_native, output]), expected)

    def test_rotation_is_applied_to_pixels_and_preserves_portrait_framing(self):
        landscape = movie(self.root / "landscape.mp4", "h264", width=320, height=180)
        rotated = self.root / "rotation-tagged.mp4"
        ffmpeg("-display_rotation", "90", "-i", landscape, "-map", "0:v:0", "-c:v", "copy", rotated)
        output = self.root / "portrait.mp4"
        self.export(output, [(rotated, Fraction(7, FPS), Fraction(25, FPS))])
        metadata = stream(output, "v:0")
        self.assertEqual((metadata["width"], metadata["height"]), (180, 320))
        self.assertFalse(any(item.get("rotation") for item in metadata.get("side_data_list", [])))
        # Undo the baked 90-degree display rotation to read the source's luma markers.
        unrotated = self.root / "unrotated.mkv"
        ffmpeg("-noautorotate", "-i", output, "-vf", "transpose=clock",
               "-an", "-fps_mode", "passthrough", "-c:v", "ffv1", unrotated)
        self.assertEqual(picture_ids(unrotated), bytes(range(7, 25)))

    def test_ten_bit_hdr_and_decoder_compatibility_keep_luma_and_color(self):
        # HEVC Main 10 can share surfaces. H.264 High 10 requires the
        # compatibility decoder on Macs without hardware support for that profile.
        for codec in ["libx265", "libx264"]:
            with self.subTest(codec=codec):
                source = self.root / (codec + "-source.mp4")
                output = self.root / (codec + "-output.mp4")
                args = ["-x265-params", "log-level=error:pools=none"] if codec == "libx265" else []
                ffmpeg("-f", "lavfi", "-i",
                       "nullsrc=s=320x96:r=25:d=1,format=yuv420p10le,geq=lum='64+876*X/319':cb=512:cr=512,"
                       "setparams=range=limited:color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc",
                       "-c:v", codec, *args, "-color_range", "tv", "-color_primaries", "bt2020",
                       "-colorspace", "bt2020nc", "-color_trc", "smpte2084", source)
                self.export(output, [(source, "0", "1")], video="hevc")
                info = stream(output, "v:0")
                self.assertEqual(info["pix_fmt"], "yuv420p10le")
                self.assertEqual((info["color_range"], info["color_space"], info["color_transfer"],
                                  info["color_primaries"]), ("tv", "bt2020nc", "smpte2084", "bt2020"))
                def luma_row(path):
                    data = ffmpeg("-i", path, "-frames:v", "1", "-pix_fmt", "yuv420p10le", "-f", "rawvideo", "-")
                    pixels = array("H", data)
                    return pixels[48 * 320:49 * 320]
                src = luma_row(source)
                dst = luma_row(output)
                self.assertLess(sum(abs(a - b) for a, b in zip(src, dst, strict=True)) / len(src), 5)

    def test_full_range_export_preserves_black_and_white_levels(self):
        source = self.root / "full.mp4"
        output = self.root / "encoded.mp4"
        ffmpeg("-f", "lavfi", "-i",
               "nullsrc=s=320x96:r=25:d=1,geq=lum='255*X/319':cb=128:cr=128,setparams=range=full",
               "-c:v", "libx264", "-crf", "12", "-color_range", "pc", source)
        self.export(output, [(source, "0", "1")])
        for path in [source, output]:
            self.assertEqual(stream(path, "v:0")["color_range"], "pc")
            raw = ffmpeg("-i", path, "-frames:v", "1", "-pix_fmt", "yuvj420p", "-f", "rawvideo", "-")
            self.assertLessEqual(raw[48 * 320 + 1], 4)
            self.assertGreaterEqual(raw[48 * 320 + 318], 251)

    def test_alpha_is_rejected_without_creating_an_output(self):
        source = self.root / "alpha.mov"
        ffmpeg("-f", "lavfi", "-i", "color=red@0.4:s=320x180:r=25:d=1,format=yuva444p10le",
               "-c:v", "prores_ks", "-profile:v", "4", "-pix_fmt", "yuva444p10le", source)
        self.assertIn("yuva", stream(source, "v:0")["pix_fmt"])
        output = self.root / "alpha-output.mov"
        clips = [(source, Fraction(1, FPS), Fraction(7, FPS))]
        for dry in [True, False]:
            with self.subTest(dry=dry):
                report = self.export(output, clips, video="prores", dry=dry, ok=False)
                self.assertEqual(report["error"]["code"], "unsupported_format")
                self.assertIn("alpha", report["error"]["message"].lower())
        self.assertFalse(any(self.root.glob(".mpcut-*")))

    def test_conversion_identifies_alpha_in_sources_without_packet_pixel_format(self):
        for codec, suffix, pixels in [("qtrle", "mov", "argb"), ("png", "mov", "rgba"),
                                      ("ffv1", "mkv", "yuva444p10le")]:
            with self.subTest(codec=codec):
                source = self.root / f"transparent-{codec}.{suffix}"
                ffmpeg("-f", "lavfi", "-i", "color=red@0.4:s=320x180:r=25:d=1,format=rgba",
                       "-c:v", codec, "-pix_fmt", pixels, source)
                self.assertEqual(stream(source, "v:0")["pix_fmt"], pixels)
                output = self.root / f"transparent-{codec}.mp4"
                report = self.export(output, [(source, 0, 1)], ok=False)
                self.assertEqual(report["error"]["code"], "unsupported_format")
                self.assertIn("alpha", report["error"]["message"].lower())

        opaque = self.root / "opaque.mov"
        ffmpeg("-i", self.video, "-an", "-c:v", "qtrle", "-pix_fmt", "rgb24", opaque)
        output = self.root / "opaque.mp4"
        self.export(output, [(opaque, 0, 1)])
        self.assertEqual(picture_ids(output), bytes(range(FPS)))

    def test_mkv_reencode_keeps_copied_opus_presentation_ends(self):
        source = self.root / "source.mkv"
        ffmpeg("-i", self.video, "-f", "lavfi", "-i", "sine=f=997:r=48000:d=4",
               "-map", "1:a", "-map", "0:v", "-c:v", "copy", "-c:a", "libopus", source)
        cropped = self.root / "cropped.mkv"
        run([CLI, "export", "clips", "join", "--output", cropped, "--clip", source, "--from", "1", "--to", "3"],
            allow_diagnostics=True)
        for name, original, picture_end, sound_end in [("whole", source, 5, 4), ("crop", cropped, 2, 2)]:
            with self.subTest(edit=name):
                output = self.root / f"{name}.mkv"
                report = self.export(output, [(original, 0, picture_end)], audio="copy")
                self.assertEqual(report["audio_actions"][0]["action"], "copy")
                self.assertEqual(pcm(output, 48000), pcm(original, 48000))
                self.assertEqual(stream(output, "a:0")["tags"]["DURATION"], f"00:00:0{sound_end}.000000000")
                self.assertEqual(stream(output, "v:0")["tags"]["DURATION"], f"00:00:0{picture_end}.000000000")
                self.assertEqual(Fraction(probe(output, "-show_format")["format"]["duration"]), picture_end)

    def test_adjacent_splits_copy_vorbis_audio_into_mkv(self):
        source = self.root / "vorbis.mkv"
        ffmpeg("-i", self.video, "-f", "lavfi", "-i", "sine=f=997:r=48000:d=5", "-map", "0:v", "-map", "1:a",
               "-c:v", "copy", "-c:a", "vorbis", "-strict", "-2", "-ac", "2", source)
        whole = self.root / "whole.mkv"
        self.export(whole, [(source, 0, 5)], audio="copy")
        seam = Fraction(50, FPS)
        for audio in ["copy", "auto"]:
            with self.subTest(audio=audio):
                output = self.root / f"split-{audio}.mkv"
                report = self.export(output, [(source, 0, seam), (source, seam, 5)], audio=audio)
                self.assertEqual(report["audio_actions"], [{"action": "copy", "track": 1}])
                self.assertEqual([[t["kind"] for t in s["tracks"]] for s in report["segments"]],
                                 [["video", "audio"], ["video", "audio"]])
                self.assertEqual(ratio(report["segments"][1]["tracks"][1]["output_start"]), seam)
                self.assertEqual(pcm(output, 48000), pcm(whole, 48000))

    def test_hevc_alpha_layers_survive_copy_and_exclude_picture_encoding(self):
        source = self.root / "hevc-alpha.mov"
        ffmpeg("-f", "lavfi", "-i", "color=red@0.4:s=320x180:r=25:d=1,format=bgra",
               "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.8", "-tag:v", "hvc1", source)
        info = json.loads(run([CLI, "media", "inspect", "--json", source], allow_diagnostics=True))
        self.assertTrue(info["media"]["streams"][0]["has_additional_video_layers"])
        copied = self.root / "whole.mov"
        run([CLI, "export", "clips", "join", "--mode", "smart", "--output", copied, "--clip", source], allow_diagnostics=True)
        self.assertEqual(timestamped_hashes(source), timestamped_hashes(copied))
        report = self.export(self.root / "opaque.mp4", [(source, 0, 1)], ok=False)
        self.assertIn("HEVC layers", report["error"]["message"])
        cut = self.root / "edge.mov"
        result = subprocess.run([CLI, "export", "clips", "join", "--json", "--mode", "smart", "--output", cut,
                                 "--clip", source, "--from", "1/25", "--to", "12/25"],
                                capture_output=True, timeout=90)
        # Smart Trim encodes the edges with the alpha layer (layered_edge.m), so the cut is exact and keeps it.
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(json.loads(result.stdout)["ok"])
        edge = json.loads(run([CLI, "media", "inspect", "--json", cut], allow_diagnostics=True))
        self.assertTrue(edge["media"]["streams"][0]["has_additional_video_layers"])

    def test_conversion_checks_alpha_in_packet_data_throughout_the_source(self):
        for bits in [16, 0]:
            ffmpeg("-f", "lavfi", "-i", "color=red@0.4:s=320x180:r=25:d=0.4,format=yuva444p10le",
                   "-c:v", "prores_ks", "-profile:v", "4", "-alpha_bits", str(bits), self.root / f"{bits}.mov")
        concat = self.root / "files.txt"
        concat.write_text("file '16.mov'\nfile '0.mov'\n")
        mixed = self.root / "mixed.mov"
        ffmpeg("-f", "concat", "-i", concat, "-c", "copy", mixed)

        webm = self.root / "transparent.webm"
        ffmpeg("-f", "lavfi", "-i", "color=red@0.4:s=320x180:r=25:d=0.4,format=yuva420p",
               "-c:v", "libvpx-vp9", "-write_crc32", "0", webm)
        # Clear the track's AlphaMode while retaining the coded BlockAdditional alpha planes.
        data = webm.read_bytes()
        mode = bytes.fromhex("53c08101")
        self.assertEqual(data.count(mode), 1)
        webm.write_bytes(data.replace(mode, bytes.fromhex("53c08100")))
        for source in [mixed, webm]:
            with self.subTest(source=source.name):
                info = json.loads(run([CLI, "media", "inspect", "--json", source], allow_diagnostics=True))
                self.assertGreater(info["media"]["streams"][0]["alpha_bits"], 0)
                self.assertIn("alpha", info["media"]["copy_issue"].lower())
                result = self.export(self.root / (source.stem + ".mp4"), [(source, 0, Fraction(10, 25))], ok=False)
                self.assertIn("alpha", result["error"]["message"].lower())

    def test_cancel_during_conversion_removes_staged_files(self):
        output = self.root / "cancelled.mp4"
        args = [CLI, "export", "clips", "join", "--json", "--mode", "encode", "--audio", "remove", "--output", output]
        for _ in range(8):
            args += ["--clip", self.video, "--from", "7/25", "--to", "88/25"]
        with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
            try:
                deadline = time.monotonic() + 15
                while child.poll() is None and time.monotonic() < deadline:
                    if any(self.root.glob(".mpcut-*/filters.txt")):
                        child.send_signal(signal.SIGINT)
                        break
                    time.sleep(0.001)
                else:
                    self.fail("no staged conversion observed")
                stdout, stderr = child.communicate(timeout=30)
            finally:
                if child.poll() is None:
                    child.kill()
        self.assertEqual(child.returncode, 130, stdout + stderr)
        self.assertEqual(json.loads(stdout)["error"]["code"], "cancelled")
        self.assertEqual(list(self.root.iterdir()), [])

    def test_hardware_probe_failure_is_reported_before_output_creation(self):
        cli = Path(CLI)
        if cli.parent.name != "Helpers" or cli.parent.parent.name != "Contents":
            self.skipTest("requires the packaged CLI layout: this check copies the binary into a scratch "
                          "MPCut.app/Contents/Helpers beside a failing ffmpeg and links the bundle's Frameworks, "
                          f"but {cli} is not under Contents/Helpers. Run this suite with "
                          "dist/MPCut.app/Contents/Helpers/mpcut to exercise it")
        contents = self.root / "MPCut.app" / "Contents"
        helpers = contents / "Helpers"
        helpers.mkdir(parents=True)
        (contents / "Frameworks").symlink_to(cli.parent.parent / "Frameworks")
        copied_cli = shutil.copy2(cli, helpers / "mpcut")
        helper = helpers / "ffmpeg"
        helper.write_text("#!/bin/sh\nprintf '%s\\n' 'Hardware encoder unavailable for test' >&2\nexit 1\n")
        helper.chmod(0o755)
        env = {key: value for key, value in os.environ.items() if key != "MPCUT_FFMPEG_HELPER"}
        output = self.root / "unavailable.mp4"
        process = subprocess.run([copied_cli, "export", "clips", "join", "--json", "--dry-run", "--mode", "encode",
                                  "--audio", "remove", "--output", output, "--clip", self.video],
                                 capture_output=True, text=True, timeout=30, env=env)
        self.assertNotEqual(process.returncode, 0, process.stdout + process.stderr)
        error = json.loads(process.stdout)["error"]
        self.assertEqual(error["code"], "encoder_unavailable")
        self.assertIn("Hardware encoder unavailable for test", error["message"])
        self.assertFalse(output.exists())
        self.assertFalse(any(self.root.glob(".mpcut-*")))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = str(args.mpcut.resolve(strict=True))
    unittest.main(argv=[__file__, *tests])
