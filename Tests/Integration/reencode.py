#!/usr/bin/env python3
"""Exercise Re-encode with generated video and audio against a release mpcut CLI."""
import argparse
from array import array
from fractions import Fraction
import json
import os
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

    def export(self, output, clips, *, video="h264", audio="remove", quality=None, dry=False, ok=True):
        args = [CLI, "export", "--json", "--mode", "encode", "--video", video, "--audio", audio,
                "--output", output]
        if quality is not None:
            args += ["--quality", quality]
        if dry:
            args.append("--dry-run")
        for source, start, end in clips:
            args += ["--clip", source, "--from", str(start), "--to", str(end)]
        process = subprocess.run(args, capture_output=True, text=True, timeout=90)
        self.assertEqual(process.returncode == 0, ok, process.stdout + process.stderr)
        report = json.loads(process.stdout)
        self.assertIs(report["ok"], ok, report)
        self.assertEqual(output.exists(), ok and not dry)
        return report

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
                self.assertEqual(ratio(dry["encodedDuration"]), duration)
                self.assertEqual(ratio(dry["copiedDuration"]), 0)
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

    def test_aac_and_pcm_keep_trimmed_audio_in_sync_and_preserve_linked_tracks(self):
        ranges = [(63, 77), (15, 31), (63, 77)]
        clips = [(self.stereo, Fraction(start, FPS), Fraction(end, FPS)) for start, end in ranges]
        duration = Fraction(sum(end - start for start, end in ranges), FPS)
        for format_name, suffix in [("aac", ".mp4"), ("pcm", ".mov")]:
            with self.subTest(audio=format_name):
                output = self.root / (format_name + suffix)
                report = self.export(output, clips, audio=format_name)
                self.assertEqual([track["action"] for track in report["audioActions"]], [format_name] * 2)
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
        self.assertEqual([track["action"] for track in dry["audioActions"]], ["copy", "copy"])
        self.export(output, clips, audio="auto")
        for index, rate in enumerate([44100, 48000]):
            channels = 2 - index
            source = pcm(self.stereo, rate, index)
            self.assertEqual(pcm(output, rate, index), source[rate * channels:2 * rate * channels])

        output = self.root / "auto-convert.mp4"
        dry = self.export(output, clips, audio="auto", dry=True)
        self.assertEqual([track["action"] for track in dry["audioActions"]], ["aac", "aac"])
        self.assertTrue(all(track.get("reason") for track in dry["audioActions"]))
        report = self.export(output, clips, audio="copy", dry=True, ok=False)
        self.assertEqual(report["error"]["code"], "audio_copy_unavailable")

    def test_reencode_preserves_silent_mov_audio_edits(self):
        source = self.root / "delayed.mov"
        ffmpeg("-i", self.video, "-itsoffset", "1.75", "-f", "lavfi", "-i",
               "aevalsrc='if(between(t,0.05,0.16),0.65*sin(2*PI*997*t),0)':s=48000:d=0.25",
               "-map", "0:v:0", "-map", "1:a:0", "-t", "2", "-c:v", "libx264", "-g", "25",
               "-c:a", "aac", "-aac_pns", "0", source)
        joined = self.root / "joined.mov"
        run([CLI, "export", "--json", "--output", joined, *(["--clip", source] * 4)], allow_diagnostics=True)
        decoded = run([self.decode_audio_native, joined])
        self.assertEqual(len(decoded), 8 * 48000 * 2)
        self.assertEqual(decoded[2 * 48000 * 2:3 * 48000 * 2], bytes(48000 * 2))
        self.assertTrue(any(decoded[3 * 48000 * 2:4 * 48000 * 2]))

        ranges = [(Fraction(37, 25), Fraction(6)), (Fraction(49, 25), Fraction(57, 25)),
                  (Fraction(13, 5), Fraction(16, 5))]
        output = self.root / "converted.mov"
        report = self.export(output, [(joined, start, end) for start, end in ranges], audio="pcm")
        self.assertEqual([track["action"] for track in report["audioActions"]], ["pcm"])
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
        self.assertEqual([track["action"] for track in report["audioActions"]], ["copy", "copy"])
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
                self.assertEqual([track["action"] for track in report["audioActions"]], ["copy"])
                self.assertEqual(stream(output, "a:0")["codec_name"], "pcm_s24le")
                self.assertEqual(pcm(output, 44100), pcm(source, 44100))

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
        self.assertEqual([action["action"] for action in report["audioActions"]], ["aac"])
        metadata = stream(output, "v:0")
        self.assertEqual((metadata["width"], metadata["height"]), (180, 320))
        sound = stream(output, "a:0")
        self.assertEqual(sound["codec_name"], "aac")
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
        run([CLI, "export", "--output", cropped, "--clip", source, "--from", "1", "--to", "3"],
            allow_diagnostics=True)
        for name, original, picture_end, sound_end in [("whole", source, 5, 4), ("crop", cropped, 2, 2)]:
            with self.subTest(edit=name):
                output = self.root / f"{name}.mkv"
                report = self.export(output, [(original, 0, picture_end)], audio="copy")
                self.assertEqual(report["audioActions"][0]["action"], "copy")
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
                self.assertEqual(report["audioActions"], [{"action": "copy", "track": 1}])
                self.assertEqual([[t["kind"] for t in s["tracks"]] for s in report["segments"]],
                                 [["video", "audio"], ["video", "audio"]])
                self.assertEqual(ratio(report["segments"][1]["tracks"][1]["outputStart"]), seam)
                self.assertEqual(pcm(output, 48000), pcm(whole, 48000))

    def test_hevc_alpha_layers_survive_copy_and_exclude_picture_encoding(self):
        source = self.root / "hevc-alpha.mov"
        ffmpeg("-f", "lavfi", "-i", "color=red@0.4:s=320x180:r=25:d=1,format=bgra",
               "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.8", "-tag:v", "hvc1", source)
        info = json.loads(run([CLI, "inspect", "--json", source], allow_diagnostics=True))
        self.assertTrue(info["media"]["streams"][0]["hasAdditionalVideoLayers"])
        copied = self.root / "whole.mov"
        run([CLI, "export", "--mode", "smart", "--output", copied, "--clip", source], allow_diagnostics=True)
        self.assertEqual(timestamped_hashes(source), timestamped_hashes(copied))
        report = self.export(self.root / "opaque.mp4", [(source, 0, 1)], ok=False)
        self.assertIn("HEVC layers", report["error"]["message"])
        cut = self.root / "edge.mov"
        result = subprocess.run([CLI, "export", "--json", "--mode", "smart", "--output", cut,
                                 "--clip", source, "--from", "1/25", "--to", "12/25"],
                                capture_output=True, timeout=90)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "unsafe_boundary")
        self.assertFalse(cut.exists())

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
                info = json.loads(run([CLI, "inspect", "--json", source], allow_diagnostics=True))
                self.assertGreater(info["media"]["streams"][0]["alphaBits"], 0)
                self.assertIn("alpha", info["media"]["copyIssue"].lower())
                result = self.export(self.root / (source.stem + ".mp4"), [(source, 0, Fraction(10, 25))], ok=False)
                self.assertIn("alpha", result["error"]["message"].lower())

    def test_cancel_during_conversion_removes_staged_files(self):
        output = self.root / "cancelled.mp4"
        args = [CLI, "export", "--json", "--mode", "encode", "--audio", "remove", "--output", output]
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
        process = subprocess.run([copied_cli, "export", "--json", "--dry-run", "--mode", "encode",
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
