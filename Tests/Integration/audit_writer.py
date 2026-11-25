#!/usr/bin/env python3
"""Packet-writer regressions against a built mpcut executable."""
import argparse
from fractions import Fraction
import json
import math
from pathlib import Path
import re
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
        # The writer audit is about the packet copy. The CLI default is Smart Trim, so the mode is named.
        named = any(flag in ("--mode", "--mode", "smart") for flag in range_args)
        args = [CLI, "export", "clips", "join", "--json", *([] if named else ["--mode", "copy"]), "--output", destination, "--clip", source, *range_args]
        if dry_run:
            args.append("--dry-run")
        process = subprocess.run(args, capture_output=True, text=True, timeout=30)
        self.assertEqual(process.returncode == 0, ok, process.stderr + process.stdout)
        report = json.loads(process.stdout)
        self.assertIs(report["ok"], ok, report)
        return report

    def test_mp4_export_respects_cropped_webm_opus_padding(self):
        fixture = Path(__file__).resolve().parents[1] / "MPCutAppTests/Fixtures/WebM-Opus-GOP.webm"
        source = self.root / fixture.name
        source.write_bytes(fixture.read_bytes())
        cropped = self.root / "cropped.webm"
        self.export(source, cropped, "--from", "1", "--to", "3")
        out = self.root / "assembly.mp4"
        for flags in [("--mode", "copy"), ("--mode", "smart"), ("--mode", "encode", "--audio", "copy")]:
            with self.subTest(flags=flags):
                report = self.export(cropped, out, *flags, dry_run=True, ok=False)
                self.assertIn("audible range", report["error"]["message"])
                self.assertFalse(out.exists())
        # Auto converts the track in its own codec: Opus is written again as Opus, trimmed to the audible range.
        report = self.export(cropped, out, "--mode", "encode", "--audio", "auto")
        self.assertEqual(report["audio_actions"][0]["action"], "opus")
        audio_stream = probe(out, "-select_streams", "a:0", "-show_streams")["streams"][0]
        self.assertEqual(audio_stream["codec_name"], "opus")
        self.assertEqual(int(audio_stream["duration_ts"]) * Fraction(audio_stream["time_base"]), 2)
        # A reader decodes exactly that range: the edit list ends inside the final packet, before its encoder padding.
        self.assertEqual(len(audio(out)), 2 * 48_000 * 2 * audio_stream["channels"])

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
                self.assertEqual(ratio(segment["output_start"]), Fraction(1, 5))
                self.assertEqual(ratio(video["output_start"]), Fraction(1, 5))
                self.assertEqual(ratio(video["output_end"]), Fraction(6, 5))
                self.assertEqual(ratio(linked_audio["source_start"]), Fraction(-1, 5))
                self.assertEqual(ratio(linked_audio["source_end"]), Fraction(11, 10))
                self.assertEqual(ratio(linked_audio["output_start"]), 0)
                self.assertEqual(ratio(linked_audio["output_end"]), Fraction(13, 10))
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

    def test_prefix_opus_trim_reports_exact_presentation_duration(self):
        source = self.root / "source.webm"
        output = self.root / "prefix.webm"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=3", "-f", "lavfi", "-i",
               "sine=r=48000:d=3", "-c:v", "libvpx-vp9", "-deadline", "realtime", "-g", "25",
               "-c:a", "libopus", source)
        self.export(source, output, "--to", "1")
        self.assertEqual(audio(output), audio(source)[:2 * 48_000])
        info = probe(output, "-show_format", "-show_streams")
        self.assertEqual(Fraction(info["format"]["duration"]), 1)
        self.assertEqual([s["tags"]["DURATION"] for s in info["streams"]],
                         ["00:00:01.000000000"] * 2)
        reopened = self.root / "reopened.webm"
        plan = self.export(output, reopened, dry_run=True)
        self.assertEqual(ratio(plan["duration"]), 1)
        self.export(output, reopened)
        self.assertEqual(Fraction(probe(reopened, "-show_format")["format"]["duration"]), 1)
        self.assertEqual(audio(reopened), audio(output))

    def test_matroska_statistics_tags_do_not_survive_a_cut(self):
        source = self.root / "statistics.mkv"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=6", "-f", "lavfi", "-i", "sine=r=48000:d=6",
               "-c:v", "libvpx-vp9", "-deadline", "realtime", "-g", "25", "-c:a", "libopus",
               "-metadata:s:v:0", "DURATION-eng=00:10:00.000000000", "-metadata:s:v:0", "BPS-eng=1000",
               "-metadata:s:a:0", "DURATION-eng=00:10:00.000000000", "-metadata:s:a:0", "language=eng", source)
        for name, args, seconds in [("middle", ("--from", "2", "--to", "4"), 2), ("tail", ("--from", "2"), 4)]:
            with self.subTest(edit=name):
                output = self.root / f"{name}.mkv"
                self.export(source, output, *args)
                streams = probe(output, "-show_streams")["streams"]
                for stream in streams:
                    tags = stream["tags"]
                    self.assertFalse([key for key in tags if key.upper().startswith(("DURATION-", "BPS"))], tags)
                    self.assertEqual(tags["DURATION"], f"00:00:0{seconds}.000000000")
                self.assertEqual(streams[1]["tags"].get("language"), "eng")

    def test_preserves_dolby_vision_configuration_record(self):
        source = self.root / "dolby.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=1", "-vf", "setsar=1",
               "-c:v", "libx265", "-x265-params", "log-level=error:pools=1", "-pix_fmt", "yuv420p10le",
               "-tag:v", "hvc1", source, allow_diagnostics=True)
        # Replace our fixture's square-pixel box with an equally sized profile-8
        # display configuration. Its coded frames and sample offsets stay intact.
        data = source.read_bytes()
        square_pixels = bytes.fromhex("00000010") + b"pasp" + bytes.fromhex("0000000100000001")
        dovi = bytes.fromhex("00000010") + b"dvvC" + bytes.fromhex("0100103540000000")
        self.assertEqual(data.count(square_pixels), 1)
        source.write_bytes(data.replace(square_pixels, dovi))
        def configurations(path):
            return probe(path, "-select_streams", "v:0", "-show_entries",
                         "stream_side_data")["streams"][0]["side_data_list"]
        expected = configurations(source)
        self.assertTrue(expected)
        for ext in ["mp4", "mkv"]:
            with self.subTest(container=ext):
                output = self.root / ("dolby-copy." + ext)
                self.export(source, output)
                self.assertEqual(configurations(output), expected)
                self.assertEqual(sample_hashes(output), sample_hashes(source))
        rejected = self.export(source, self.root / "dolby.mov", dry_run=True, ok=False)
        self.assertIn("Dolby Vision", rejected["error"]["message"])

    def test_reordered_matroska_keeps_coded_order_and_display_timing(self):
        for codec, options in [
            ("libx264", ["-x264-params", "keyint=25:min-keyint=25:scenecut=0:bframes=3:b-adapt=0"]),
            ("libx265", ["-x265-params", "keyint=25:min-keyint=25:scenecut=0:bframes=3:b-adapt=0:open-gop=0:pools=1:log-level=error"]),
        ]:
            source = self.root / (codec + ".mkv")
            ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x192:r=25:d=3", "-c:v", codec,
                   *options, source, allow_diagnostics=True)
            original = frames(source)
            for ext in ["mp4", "mkv"]:
                with self.subTest(codec=codec, ext=ext):
                    output = self.root / (codec + "." + ext + "." + ext)
                    self.export(source, output, "--from", "1", "--to", "2", "--clip", source, "--to", "1")
                    self.assertEqual(frames(output), original[25:50] + original[:25])
                    self.assertEqual(sample_hashes(output), sample_hashes(source)[25:50] + sample_hashes(source)[:25])
                    pts = probe(output, "-show_packets", "-show_entries", "packet=pts_time")["packets"]
                    self.assertEqual(sorted(Fraction(p["pts_time"]) for p in pts), [Fraction(i, 25) for i in range(50)])

    def test_matroska_join_declares_the_reorder_depth_of_videotoolbox_h264(self):
        # VideoToolbox H.264 parameter sets declare no reorder depth. MOV gives a reader the depth in its composition
        # offsets; Matroska does not, so libavcodec guessed it from the first range's pictures and dropped one where a
        # later range reordered deeper. The copy declares the depth in the parameter sets and leaves the samples alone.
        source = self.root / "videotoolbox.mkv"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x192:r=25:d=4", "-c:v", "h264_videotoolbox", "-g", "25", "-bf", "2", source)
        original, coded = frames(source), sample_hashes(source)
        self.assertEqual(len(original), 100)
        for first, second in [((3, 4), (0, 1)), ((1, 2), (0, 1)), ((2, 4), (0, 2))]:
            with self.subTest(first=first, second=second):
                output = self.root / "videotoolbox-join.mkv"
                output.unlink(missing_ok=True)
                self.export(source, output, "--from", str(first[0]), "--to", str(first[1]),
                            "--clip", source, "--from", str(second[0]), "--to", str(second[1]))
                kept = [slice(25 * start, 25 * end) for start, end in (first, second)]
                self.assertEqual(sample_hashes(output), coded[kept[0]] + coded[kept[1]])
                self.assertEqual(frames(output), original[kept[0]] + original[kept[1]])
        # A parameter set that already declares its depth is copied as it was.
        declared = self.root / "x264.mkv"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x192:r=25:d=2", "-c:v", "libx264",
               "-x264-params", "keyint=25:min-keyint=25:scenecut=0:bframes=3", declared)
        output = self.root / "x264-join.mkv"
        self.export(declared, output, "--from", "1", "--to", "2", "--clip", declared, "--to", "1")

        def configuration(path):
            return probe(path, "-select_streams", "v:0", "-show_entries", "stream=extradata", "-show_data")["streams"][0]["extradata"]

        self.assertEqual(configuration(output), configuration(declared))
        self.assertEqual(len(frames(output)), 50)

    def test_copied_dolby_audio_ends_at_its_last_audible_sample(self):
        # An encoder pads the final AC-3 or E-AC-3 frame, and the source's edit list hides the padding. The MOV muxer
        # ignores the demuxer's mark for it, so the copy played the padding (768 samples here) until the writer ended
        # the last sample, and with it the edit, at the last audible sample.
        for codec in ("ac3", "eac3"):
            source = self.root / f"{codec}.mp4"
            ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.4*sin(2*PI*440*t)|0.3*sin(2*PI*661*t):s=44100:d=1.37", "-c:a", codec, source)
            decoded = audio(source)
            self.assertEqual(len(decoded), 60417 * 2 * 2)
            for ext in ("mov", "mp4"):
                with self.subTest(codec=codec, container=ext):
                    output = self.root / f"{codec}-copy.{ext}"
                    output.unlink(missing_ok=True)
                    self.export(source, output)
                    self.assertEqual(sample_hashes(output, "a:0"), sample_hashes(source, "a:0"))
                    self.assertEqual(audio(output), decoded)

    def test_preserves_packed_stereo_layout(self):
        source = self.root / "stereo.mkv"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x192:r=25:d=1", "-c:v", "libx264",
               "-metadata:s:v", "stereo_mode=left_right", source)
        for ext in ["mov", "mp4"]:
            rejected = self.export(source, self.root / ("stereo." + ext), dry_run=True, ok=False)
            self.assertIn("stereo layout", rejected["error"]["message"])
        output = self.root / "stereo-copy.mkv"
        self.export(source, output)
        track = probe(output, "-show_streams")["streams"][0]
        self.assertTrue(any(side.get("type") == "side by side" for side in track["side_data_list"]))

    def test_fractional_pixel_aspect_ratio_survives_copy_and_smart_trim(self):
        source = self.root / "anamorphic.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=3", "-vf", "setsar=16/15",
               "-c:v", "libx264", "-x264-params", "keyint=25:min-keyint=25:scenecut=0:open-gop=0",
               "-pix_fmt", "yuv420p", source)
        for label, options in [("copy", []), ("smart", ["--mode", "smart", "--from", "0.4", "--to", "2.6"])]:
            with self.subTest(label=label):
                output = self.root / (label + ".mp4")
                self.export(source, output, *options)
                track = probe(output, "-show_streams")["streams"][0]
                self.assertEqual(track["sample_aspect_ratio"], "16:15")
                self.assertEqual(track["display_aspect_ratio"], "256:135")

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

    def chapters(self, path):
        return [(Fraction(chapter["start_time"]), Fraction(chapter["end_time"]), chapter.get("tags", {}).get("title"))
                for chapter in probe(path, "-show_chapters")["chapters"]]

    def chapter_list(self, *spans):
        listing = self.root / "chapters.txt"
        listing.write_text(";FFMETADATA1\n" + "".join(
            f"[CHAPTER]\nTIMEBASE=1/1000\nSTART={start * 1000}\nEND={end * 1000}\ntitle={title}\n"
            for start, end, title in spans))
        return listing

    def test_sound_only_copy_keeps_cover_art(self):
        cover = self.root / "cover.jpg"
        source = self.root / "album.m4a"
        ffmpeg("-f", "lavfi", "-i", "color=c=red:s=96x96:d=1", "-frames:v", "1", cover)
        ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=3", "-i", cover,
               "-map", "0:a", "-map", "1:v", "-c:a", "aac", "-c:v", "copy", "-disposition:v", "attached_pic", source)

        def art(path):
            return ffmpeg("-i", path, "-map", "0:v", "-c", "copy", "-f", "image2pipe", "-")

        for name in ["copy.m4a", "copy.mp4", "copy.mka"]:
            with self.subTest(name=name):
                output = self.root / name
                report = self.export(source, output)
                self.assertNotIn("warnings", report)
                kinds = [(track["codec_name"], track["disposition"]["attached_pic"])
                         for track in probe(output, "-show_streams")["streams"]]
                self.assertEqual(kinds, [("aac", 0), ("mjpeg", 1)])
                self.assertEqual(art(output), cover.read_bytes())
                self.assertEqual(sample_hashes(output, "a:0"), sample_hashes(source, "a:0"))
        # The MOV muxer has no cover atom. The picture is left out, and the report says so.
        for dry_run in [True, False]:
            report = self.export(source, self.root / "copy.mov", dry_run=dry_run)
            self.assertEqual(len(report["warnings"]), 1, report)
            self.assertIn("Cover art cannot be written to MOV", report["warnings"][0])
        self.assertEqual([track["codec_name"] for track in probe(self.root / "copy.mov", "-show_streams")["streams"]], ["aac"])

    def test_copy_without_art_or_chapters_adds_nothing(self):
        source = self.root / "plain.m4a"
        ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=3", "-c:a", "aac", source)
        for name in ["plain-copy.m4a", "plain-copy.mka"]:
            with self.subTest(name=name):
                output = self.root / name
                report = self.export(source, output)
                self.assertNotIn("warnings", report)
                described = probe(output, "-show_streams", "-show_chapters")
                self.assertEqual([track["codec_type"] for track in described["streams"]], ["audio"])
                self.assertEqual(described["chapters"], [])

    def test_copy_places_chapters_on_the_output_timeline(self):
        spans = [(0, 4, "One"), (4, 9, "Two"), (9, 12, "Three")]
        listing = self.chapter_list(*spans)
        movie = self.root / "chapters.mkv"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=12", "-i", listing, "-map", "0:v",
               "-map_metadata", "1", "-map_chapters", "1", "-c:v", "libx264", "-bf", "0",
               "-x264-params", "keyint=25:min-keyint=25:scenecut=0", "-pix_fmt", "yuv420p", movie)
        whole = self.root / "whole.mkv"
        self.assertNotIn("warnings", self.export(movie, whole))
        self.assertEqual(self.chapters(whole), spans)
        self.assertEqual(sample_hashes(whole), sample_hashes(movie))
        # Two kept ranges: each chapter is clipped and moved, and the two pieces of "Two" meet again.
        joined = self.root / "joined.mkv"
        self.export(movie, joined, "--from", "2", "--to", "6", "--clip", movie, "--from", "8", "--to", "11")
        self.assertEqual(self.chapters(joined), [(0, 2, "One"), (2, 5, "Two"), (5, 7, "Three")])
        # A chapter that lies wholly in removed material has no place in the output.
        outer = self.root / "outer.mkv"
        self.export(movie, outer, "--from", "0", "--to", "3", "--clip", movie, "--from", "10", "--to", "12")
        self.assertEqual(self.chapters(outer), [(0, 3, "One"), (3, 5, "Three")])
        # Playing the ranges out of order keeps each chapter with its material.
        swapped = self.root / "swapped.mkv"
        self.export(movie, swapped, "--from", "8", "--to", "11", "--clip", movie, "--from", "2", "--to", "6")
        self.assertEqual(self.chapters(swapped), [(0, 1, "Two"), (1, 3, "Three"), (3, 5, "One"), (5, 7, "Two")])

    def test_audiobook_chapters_survive_copy_and_trim(self):
        # A chapter longer than three seconds does not fit a 32-bit sample duration on the writer's movie clock.
        spans = [(0, 5, "One"), (5, 9, "Two"), (9, 12, "Three")]
        listing = self.chapter_list(*spans)
        source = self.root / "book.m4b"
        ffmpeg("-f", "lavfi", "-i", "sine=frequency=330:sample_rate=44100:duration=12", "-i", listing, "-map", "0:a",
               "-map_metadata", "1", "-map_chapters", "1", "-c:a", "aac", "-f", "ipod", source)
        self.assertEqual(self.chapters(source), spans)
        for name in ["book-copy.m4b", "book-copy.m4a", "book-copy.mov", "book-copy.mka"]:
            with self.subTest(name=name):
                output = self.root / name
                self.assertNotIn("warnings", self.export(source, output))
                self.assertEqual(self.chapters(output), spans)
                self.assertEqual(sample_hashes(output, "a:0"), sample_hashes(source, "a:0"))
                # One chapter track, and none for Matroska, which lists chapters in its header.
                kinds = [track["codec_type"] for track in probe(output, "-show_streams")["streams"]]
                self.assertEqual(kinds, ["audio"] if name.endswith(".mka") else ["audio", "data"])
        trimmed = self.root / "book-trim.m4a"
        report = self.export(source, trimmed, "--snap", "nearest", "--from", "2", "--to", "10")
        start, end = (ratio(report["segments"][0][key]) for key in ("from", "to"))

        def rounded(value):
            return Fraction(round(value * 1000), 1000)

        self.assertEqual(self.chapters(trimmed), [(0, rounded(5 - start), "One"), (rounded(5 - start), rounded(9 - start), "Two"),
                                                  (rounded(9 - start), rounded(end - start), "Three")])
        # FLAC has no chapters. The copy still succeeds and says what it left out.
        lossless = self.root / "book.flac"
        ffmpeg("-f", "lavfi", "-i", "sine=frequency=330:sample_rate=44100:duration=12", "-i", listing, "-map", "0:a",
               "-map_metadata", "1", "-map_chapters", "1", "-c:a", "flac", self.root / "book.mka")
        report = self.export(self.root / "book.mka", lossless)
        self.assertEqual(report["warnings"], ["Chapters cannot be written to FLAC. 3 chapters are not copied."])

    def test_picture_only_copy_keeps_mov_timecode(self):
        source = self.root / "timecode.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=30:d=4", "-f", "lavfi", "-i", "sine=d=4:r=48000",
               "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", "-timecode", "01:00:00:00", source)

        def tags(path):
            return [track["codec_tag_string"] for track in probe(path, "-show_streams")["streams"]]

        def timecode(path):
            return probe(path, "-select_streams", "v:0", "-show_streams")["streams"][0].get("tags", {}).get("timecode")

        for name in ["picture.mov", "picture.mp4"]:
            with self.subTest(name=name):
                output = self.root / name
                self.assertNotIn("warnings", self.export(source, output, "--tracks", "video"))
                self.assertEqual(tags(output), ["avc1", "tmcd"])
                self.assertEqual(timecode(output), "01:00:00:00")
                self.assertEqual(sample_hashes(output), sample_hashes(source))
        trimmed = self.root / "picture-trim.mov"
        self.export(source, trimmed, "--tracks", "video", "--from", "1", "--to", "3")
        self.assertEqual(tags(trimmed), ["avc1", "tmcd"])
        self.assertEqual(timecode(trimmed), "01:00:01:00")
        # Matroska has no timecode track. A picture-only copy is still written, and the report says so.
        report = self.export(source, self.root / "picture.mkv", "--tracks", "video")
        self.assertEqual(len(report["warnings"]), 1, report)
        self.assertIn("timecode track is not copied", report["warnings"][0])
        # Timecode describes the picture, so a sound-only selection leaves it behind.
        sound = self.root / "sound.m4a"
        self.assertNotIn("warnings", self.export(source, sound, "--tracks", "audio"))
        self.assertEqual(tags(sound), ["mp4a"])

    def test_movie_with_chapter_track_is_a_copy_source(self):
        # An MP4 or MOV lists chapters in a text track that the other tracks reference. The copy reads the
        # chapters and writes a new chapter track, so a chaptered movie, mpcut's own output included, can be cut again.
        spans = [(0, 5, "One"), (5, 9, "Two"), (9, 12, "Three")]
        listing = self.chapter_list(*spans)
        first = self.root / "first.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x180:r=30:d=12", "-f", "lavfi", "-i", "sine=d=12:r=48000", "-i", listing,
               "-map", "0:v", "-map", "1:a", "-map_metadata", "2", "-map_chapters", "2",
               "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", first)

        def tags(path):
            return [track["codec_tag_string"] for track in probe(path, "-show_streams")["streams"]]

        self.assertEqual(tags(first), ["avc1", "mp4a", "text"])
        source = first
        for name in ["second.mp4", "third.mov", "fourth.mp4"]:
            with self.subTest(name=name):
                output = self.root / name
                self.assertNotIn("warnings", self.export(source, output, "--no-sidecar"))
                self.assertEqual(tags(output), ["avc1", "mp4a", "text"])
                self.assertEqual(self.chapters(output), spans)
                for selector in ["v:0", "a:0"]:
                    self.assertEqual(sample_hashes(output, selector), sample_hashes(first, selector))
                source = output

        def rounded(value):
            return Fraction(round(value * 1000), 1000)

        def placed(report):
            start, end = (ratio(report["segments"][0][key]) for key in ("from", "to"))
            return [(0, rounded(5 - start), "One"), (rounded(5 - start), rounded(9 - start), "Two"),
                    (rounded(9 - start), rounded(end - start), "Three")]

        second = self.root / "second.mp4"
        trimmed = self.root / "trimmed.mp4"
        report = self.export(second, trimmed, "--no-sidecar", "--snap", "nearest", "--from", "2", "--to", "10")
        self.assertEqual(self.chapters(trimmed), placed(report))
        self.assertEqual(tags(trimmed), ["avc1", "mp4a", "text"])
        smart = self.root / "smart.mp4"
        report = self.export(second, smart, "--no-sidecar", "--mode", "smart", "--from", "2.5", "--to", "10.2")
        self.assertEqual(report["mode"], "smart")
        self.assertGreater(ratio(report["encoded_duration"]), 0)
        self.assertEqual(self.chapters(smart), [(0, Fraction(5, 2), "One"), (Fraction(5, 2), Fraction(13, 2), "Two"),
                                                (Fraction(13, 2), Fraction(77, 10), "Three")])
        self.assertEqual(tags(smart), ["avc1", "mp4a", "text"])

        # A subtitle track is not a chapter track, whatever its sample entry is called and whether or not
        # the movie also has chapters. It is copied as a subtitle track, beside a new chapter track.
        captions = self.root / "captions.srt"
        captions.write_text("1\n00:00:00,500 --> 00:00:02,000\nHello\n")
        for name, chapter_options, expected in [
                ("captions.mp4", [], ["avc1", "mp4a", "tx3g"]), ("captions.mov", [], ["avc1", "mp4a", "text"]),
                ("captions-chapters.mp4", ["-i", listing, "-map_metadata", "2", "-map_chapters", "2"],
                 ["avc1", "mp4a", "tx3g", "text"])]:
            with self.subTest(name=name):
                movie = self.root / name
                ffmpeg("-i", first, "-i", captions, *chapter_options, "-map", "0:v", "-map", "0:a", "-map", "1:s",
                       "-c:v", "copy", "-c:a", "copy", "-c:s", "mov_text", *([] if chapter_options else ["-map_chapters", "-1"]), movie)
                self.assertIn("subtitle", [track["codec_type"] for track in probe(movie, "-show_streams")["streams"]])
                output = self.root / ("copied-" + name)
                self.assertNotIn("warnings", self.export(movie, output, "--no-sidecar"))
                self.assertEqual(tags(output), expected)
                self.assertEqual(self.chapters(output), spans if chapter_options else [])
                for selector in ["v:0", "a:0", "s:0"]:
                    self.assertEqual(sample_hashes(output, selector), sample_hashes(movie, selector))

    def test_sound_only_copy_keeps_attached_files(self):
        # Matroska can hold any file beside the sound: fonts, notes. They travel as cover art does.
        font, notes = self.root / "font.ttf", self.root / "notes.txt"
        font.write_bytes(bytes(range(256)) * 12)
        notes.write_text("liner notes\n")
        source = self.root / "album.mka"
        ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4", "-c:a", "libopus",
               "-attach", font, "-metadata:s:t:0", "mimetype=application/x-truetype-font",
               "-attach", notes, "-metadata:s:t:1", "mimetype=text/plain", source)

        def files(path):
            listed = []
            for index, track in enumerate(probe(path, "-show_streams")["streams"]):
                if track["codec_type"] != "attachment":
                    continue
                dumped = self.root / "dumped"
                dumped.unlink(missing_ok=True)
                # This form of the command writes the file and then stops for want of an output.
                subprocess.run(["ffmpeg", "-v", "quiet", f"-dump_attachment:{index}", dumped, "-i", path], timeout=30)
                listed.append((track["tags"]["filename"], track["tags"]["mimetype"], dumped.read_bytes()))
            return listed

        expected = [("font.ttf", "application/x-truetype-font", font.read_bytes()), ("notes.txt", "text/plain", notes.read_bytes())]
        self.assertEqual(files(source), expected)
        whole = self.root / "copy.mka"
        self.assertNotIn("warnings", self.export(source, whole))
        self.assertEqual(files(whole), expected)
        self.assertEqual(sample_hashes(whole, "a:0"), sample_hashes(source, "a:0"))
        trimmed = self.root / "trim.mka"
        self.assertNotIn("warnings", self.export(source, trimmed, "--from", "1", "--to", "3"))
        self.assertEqual(files(trimmed), expected)
        # No other container stores them, and one chosen track is copied without them. Both reports say so.
        for dry_run in [True, False]:
            report = self.export(source, self.root / "copy.opus", dry_run=dry_run)
            self.assertEqual(report["warnings"], ["Attached files cannot be written to OPUS. 2 attached files are not copied."])
            report = self.export(source, self.root / "one.mka", "--tracks", "audio", "--audio-stream", "0", dry_run=dry_run)
            self.assertEqual(report["warnings"], ["Attached files are copied only with all the audio tracks of a sound-only file. "
                                                  "2 attached files are not copied."])
        self.assertEqual(files(self.root / "one.mka"), [])

    def test_explicit_selection_reports_cover_art_left_behind(self):
        cover = self.root / "cover.jpg"
        album = self.root / "album.m4a"
        film = self.root / "film.mp4"
        ffmpeg("-f", "lavfi", "-i", "color=c=red:s=96x96:d=1", "-frames:v", "1", cover)
        ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=3", "-i", cover,
               "-map", "0:a", "-map", "1:v", "-c:a", "aac", "-c:v", "copy", "-disposition:v", "attached_pic", album)
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=3", "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=3", "-i", cover,
               "-map", "0:v", "-map", "1:a", "-map", "2:v", "-c:v:0", "libx264", "-g", "25", "-pix_fmt", "yuv420p", "-c:a", "aac",
               "-c:v:1", "copy", "-disposition:v:1", "attached_pic", film)
        note = "Cover art is copied only with all the audio tracks of a sound-only file. 1 embedded picture is not copied."
        # A movie's cover art travels with its picture and sound together (test_movie_copy_keeps_extra_tracks).
        film_note = "Cover art is copied only with both the picture and the sound of a movie. 1 embedded picture is not copied."
        for source, name, selection, expected in [
                (album, "one-track.m4a", ["--tracks", "audio", "--audio-stream", "0"], note),
                (film, "film-sound.m4a", ["--tracks", "audio"], film_note),
                (film, "film-picture.mp4", ["--tracks", "video"], film_note)]:
            for dry_run in [True, False]:
                with self.subTest(name=name, dry_run=dry_run):
                    report = self.export(source, self.root / name, *selection, dry_run=dry_run)
                    self.assertEqual(report["warnings"], [expected])
            kinds = [track["disposition"]["attached_pic"] for track in probe(self.root / name, "-show_streams")["streams"]]
            self.assertEqual(kinds, [0])

    def test_movie_copy_keeps_extra_tracks(self):
        # Subtitles, telemetry, cover art and attached files travel with a movie's picture and sound where the
        # container holds them. A cue that runs across a cut is shortened; its text is not touched.
        captions = self.root / "captions.srt"
        captions.write_text("1\n00:00:00,500 --> 00:00:02,000\nHello\n\n2\n00:00:02,500 --> 00:00:05,500\nAcross\n\n"
                            "3\n00:00:06,000 --> 00:00:07,000\nLater\n")
        base = self.root / "base.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=8", "-f", "lavfi", "-i", "sine=r=48000:d=8",
               "-c:v", "libx264", "-g", "25", "-bf", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", base)

        def cues(path, selector="s:0"):
            listed = probe(path, "-select_streams", selector, "-show_entries", "packet=pts_time,duration_time,data_hash",
                           "-show_data_hash", "sha256")["packets"]
            return [(Fraction(item["pts_time"]), Fraction(item["duration_time"]), item["data_hash"]) for item in listed]

        def codecs(path):
            return [(track["codec_type"], track["codec_name"]) for track in probe(path, "-show_streams")["streams"]]

        for extension, codec in [("mp4", "mov_text"), ("mov", "mov_text"), ("mkv", "srt"), ("mkv", "ass")]:
            with self.subTest(extension=extension, codec=codec):
                source = self.root / f"captions-{codec}.{extension}"
                ffmpeg("-i", base, "-i", captions, *(["-map", "0"] if extension != "mkv" else ["-map", "0:v"]), "-map", "1", "-c:v", "copy", "-c:a", "copy", "-c:s", codec, source)
                whole = self.root / f"whole-{codec}.{extension}"
                self.assertNotIn("warnings", self.export(source, whole, "--no-sidecar"))
                self.assertEqual(cues(whole), cues(source))
                # 3 s to 6.4 s lies on picture frames and on AAC packets. "Across" starts before the cut and is shortened.
                trimmed = self.root / f"trim-{codec}.{extension}"
                self.assertNotIn("warnings", self.export(source, trimmed, "--no-sidecar", "--from", "3", "--to", "32/5"))
                across, later = (digest for start, _, digest in cues(source) if start in (Fraction(5, 2), 6))
                timed = [(start, length, digest) for start, length, digest in cues(trimmed) if digest in (across, later)]
                self.assertEqual(timed, [(0, Fraction(5, 2), across), (3, Fraction(2, 5), later)])
                self.assertEqual(len(sample_hashes(trimmed, "v:0")), 85)

        # Smart Trim writes the same cues: the encoded edge pictures change nothing about them.
        smart_base = self.root / "smart-base.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x180:r=30:d=8", "-f", "lavfi", "-i", "sine=r=48000:d=8",
               "-c:v", "libx264", "-g", "30", "-bf", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", smart_base)
        smart_source = self.root / "smart-captions.mp4"
        ffmpeg("-i", smart_base, "-i", captions, "-map", "0", "-map", "1", "-c:v", "copy", "-c:a", "copy", "-c:s", "mov_text", smart_source)
        smart = self.root / "smart-captions-trim.mp4"
        report = self.export(smart_source, smart, "--no-sidecar", "--mode", "smart", "--from", "2.5", "--to", "6.2")
        self.assertEqual(report["mode"], "smart")
        across, later = (digest for start, _, digest in cues(smart_source) if start in (Fraction(5, 2), 6))
        self.assertEqual([cue for cue in cues(smart) if cue[2] in (across, later)],
                         [(0, 3, across), (Fraction(7, 2), Fraction(1, 5), later)])

        # A subtitle codec the container has no place for is left out, and named.
        mp4_captions = self.root / "captions-mov_text.mp4"
        for dry_run in [True, False]:
            report = self.export(mp4_captions, self.root / "no-captions.mkv", "--no-sidecar", dry_run=dry_run)
            self.assertEqual(report["warnings"], ["Subtitle track 2 (mov_text) cannot be copied to MKV and is left out."])
        self.assertEqual([kind for kind, _ in codecs(self.root / "no-captions.mkv")], ["video", "audio"])
        # An explicit selection copies the chosen track alone, and says what it leaves.
        report = self.export(mp4_captions, self.root / "sound.m4a", "--no-sidecar", "--tracks", "audio")
        self.assertEqual(report["warnings"], ["Subtitle and data tracks are copied only with both the picture and the sound "
                                              "of a movie. 1 track is not copied."])

        # GoPro telemetry: one-second samples. A trim keeps the samples that lie wholly inside the range.
        blob = self.root / "telemetry.bin"
        blob.write_bytes(b"".join(bytes([sample]) * 1024 for sample in range(8)))
        telemetry = self.root / "telemetry.mov"
        ffmpeg("-i", base, "-f", "data", "-raw_packet_size", "1024", "-i", blob, "-map", "0", "-map", "1", "-c", "copy",
               "-tag:d", "gpmd", "-bsf:d", "setts=ts=N*90000:duration=90000:time_base=1/90000", telemetry)
        samples = cues(telemetry, "d:0")
        self.assertEqual(len(samples), 8)
        for extension in ["mov", "mp4"]:
            with self.subTest(telemetry=extension):
                whole = self.root / f"telemetry-whole.{extension}"
                self.assertNotIn("warnings", self.export(telemetry, whole, "--no-sidecar"))
                self.assertEqual(cues(whole, "d:0"), samples)
                self.assertEqual(probe(whole, "-select_streams", "d:0", "-show_streams")["streams"][0]["codec_tag_string"], "gpmd")
                trimmed = self.root / f"telemetry-trim.{extension}"
                report = self.export(telemetry, trimmed, "--no-sidecar", "--from", "2", "--to", "5")
                self.assertEqual(report["warnings"], ["Data track 2 (gpmd) keeps only the samples that lie wholly inside the kept ranges."])
                self.assertEqual(cues(trimmed, "d:0"), [(start - 2, length, digest) for start, length, digest in samples[2:5]])
        report = self.export(telemetry, self.root / "telemetry.mkv", "--no-sidecar", dry_run=True)
        self.assertEqual(report["warnings"], ["Data track 2 (gpmd) cannot be copied to MKV and is left out."])

        # Cover art of a movie: MP4 stores it as a cover picture, Matroska as an attached file, MOV not at all.
        cover = self.root / "cover.png"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=64x64:d=1", "-frames:v", "1", cover)
        film = self.root / "film.mp4"
        ffmpeg("-i", base, "-i", cover, "-map", "0", "-map", "1", "-c", "copy", "-disposition:v:1", "attached_pic", film)

        def art(path):
            return ffmpeg("-i", path, "-map", "0:v:1", "-c", "copy", "-f", "image2pipe", "-")

        for name in ["film-copy.mp4", "film-trim.mp4", "film-copy.mkv"]:
            with self.subTest(name=name):
                output = self.root / name
                self.assertNotIn("warnings", self.export(film, output, "--no-sidecar", *(["--from", "1", "--to", "4"] if "trim" in name else [])))
                self.assertEqual(art(output), cover.read_bytes())
        report = self.export(film, self.root / "film.mov", "--no-sidecar")
        self.assertEqual(report["warnings"], ["Cover art cannot be written to MOV. 1 embedded picture is not copied."])
        self.assertEqual([kind for kind, _ in codecs(self.root / "film.mov")], ["video", "audio"])

        # A font attached to a Matroska movie stays attached.
        font = self.root / "font.ttf"
        font.write_bytes(bytes(range(256)) * 12)
        attached = self.root / "attached.mkv"
        ffmpeg("-i", base, "-map", "0:v", "-c", "copy", "-attach", font, "-metadata:s:t:0", "mimetype=application/x-truetype-font", attached)
        output = self.root / "attached-trim.mkv"
        self.assertNotIn("warnings", self.export(attached, output, "--no-sidecar", "--from", "3", "--to", "32/5"))
        index = next(track["index"] for track in probe(output, "-show_streams")["streams"] if track["codec_type"] == "attachment")
        dumped = self.root / "dumped.ttf"
        subprocess.run(["ffmpeg", "-v", "quiet", f"-dump_attachment:{index}", dumped, "-i", output], timeout=30)
        self.assertEqual(dumped.read_bytes(), font.read_bytes())

    def test_join_reports_timecode_that_counts_on(self):
        source = self.root / "timecode.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=30:d=6", "-f", "lavfi", "-i", "sine=d=6:r=48000",
               "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-timecode", "01:00:00:00", source)

        def timecode(path):
            return probe(path, "-select_streams", "v:0", "-show_streams")["streams"][0]["tags"]["timecode"]

        # One run of the source keeps a true timecode, in one range or in two that meet.
        self.assertNotIn("warnings", self.export(source, self.root / "trim.mov", "--from", "1", "--to", "3"))
        self.assertNotIn("warnings", self.export(source, self.root / "meeting.mov", "--from", "1", "--to", "2",
                                                 "--clip", source, "--from", "2", "--to", "3"))
        # The output has one timecode track. After a jump in the source it no longer states the source's timecode.
        note = "The timecode track counts on from the first range. 1 later range does not keep its source timecode."
        for name, selection in [("join.mov", []), ("join-picture.mov", ["--tracks", "video"])]:
            for dry_run in [True, False]:
                with self.subTest(name=name, dry_run=dry_run):
                    report = self.export(source, self.root / name, *selection, "--from", "1", "--to", "2",
                                         "--clip", source, "--from", "4", "--to", "5", dry_run=dry_run)
                    self.assertEqual(report["warnings"], [note])
            self.assertEqual(timecode(self.root / name), "01:00:01:00")

    def test_chapter_gap_is_reported_where_a_chapter_cannot_end_early(self):
        spans = [(0, 3, "One"), (5, 8, "Two"), (8, 12, "Three")]
        listing = self.chapter_list(*spans)

        def rounded(path):
            return [(round(start, 2), round(end, 2), title) for start, end, title in self.chapters(path)]

        for codec, kept, others in [("aac", "gap.mka", ["gap.m4a", "gap.mov"]), ("libopus", "gap-opus.mka", ["gap.opus"])]:
            source = self.root / f"source-{codec}.mka"
            ffmpeg("-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=12", "-i", listing, "-map", "0:a",
                   "-map_metadata", "1", "-map_chapters", "1", "-c:a", codec, source)
            self.assertNotIn("warnings", self.export(source, self.root / kept))
            self.assertEqual(rounded(self.root / kept), spans)
            for name in others:
                with self.subTest(name=name):
                    container = name.rsplit(".", 1)[1].upper()
                    for dry_run in [True, False]:
                        report = self.export(source, self.root / name, dry_run=dry_run)
                        self.assertEqual(report["warnings"], [f"{container} chapters follow one another without a gap, "
                                                              "so 1 chapter runs on to the start of the next."])
                    self.assertEqual(rounded(self.root / name)[:2], [(0, 5, "One"), (5, 8, "Two")])

    def test_opus_copy_keeps_chapters(self):
        spans = [(0, 4, "One"), (4, 8, "Two"), (8, 12, "Three")]
        listing = self.chapter_list(*spans)
        sources = {}
        for name in ["book.mka", "book.opus"]:
            sources[name] = self.root / name
            ffmpeg("-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=12", "-i", listing,
                   "-map", "0:a", "-map_metadata", "1", "-map_chapters", "1", "-c:a", "libopus", sources[name])
        for origin, name in [("book.mka", "from-matroska.opus"), ("book.opus", "from-ogg.opus")]:
            with self.subTest(name=name):
                source, output = sources[origin], self.root / name
                self.assertNotIn("warnings", self.export(source, output))
                # An Ogg chapter states its start. It lasts until the next one, and the last until the sound ends.
                placed = self.chapters(output)
                self.assertEqual([(start, title) for start, _, title in placed], [(start, title) for start, _, title in spans])
                self.assertEqual([end for _, end, _ in placed[:-1]], [4, 8])
                self.assertEqual(sample_hashes(output, "a:0"), sample_hashes(source, "a:0"))
                if origin == "book.opus":
                    self.assertEqual(audio(output), audio(source))
        # mpcut reads them back: a second copy into Matroska still has every chapter.
        back = self.root / "back.mka"
        self.export(self.root / "from-matroska.opus", back)
        self.assertEqual([(round(start, 2), title) for start, _, title in self.chapters(back)], [(0, "One"), (4, "Two"), (8, "Three")])
        # FFmpeg lists chapters for an Opus stream and for no other Ogg codec. Only .opus is sure to hold
        # Opus, so a general Ogg file still leaves the chapters out and says so.
        report = self.export(sources["book.opus"], self.root / "plain.ogg")
        self.assertEqual(report["warnings"], ["Chapters cannot be written to OGG. 3 chapters are not copied."])
        self.assertEqual(self.chapters(self.root / "plain.ogg"), [])

    def test_matroska_opus_copies_to_ogg_with_its_own_samples(self):
        # Matroska rounds each Opus block to the millisecond. Ogg granules count samples, so
        # a copy that reused the rounded clock decoded 24 extra samples (0.5 ms) at the end.
        cases = [("mono.mkv", ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=12"], []),
                 ("stereo.webm", ["-f", "lavfi", "-i", "sine=frequency=300:sample_rate=48000:duration=7.0123"],
                  ["-ac", "2", "-frame_duration", "10"])]
        for name, inputs, options in cases:
            source = self.root / name
            ffmpeg(*inputs, *options, "-c:a", "libopus", "-b:a", "96k", source)
            pcm = ffmpeg("-i", source, "-f", "s16le", "-")
            for ext in ["opus", "ogg"]:
                with self.subTest(source=name, container=ext):
                    output = self.root / (source.stem + "." + ext)
                    self.export(source, output)
                    self.assertEqual(sample_hashes(output, "a:0"), sample_hashes(source, "a:0"))
                    decoded = ffmpeg("-i", output, "-f", "s16le", "-")
                    self.assertEqual(len(decoded), len(pcm))
                    self.assertEqual(decoded, pcm)
                    stream = probe(output, "-select_streams", "a:0", "-show_streams")["streams"][0]
                    self.assertEqual(Fraction(stream["start_time"]), 0)
        self.assertEqual(len(ffmpeg("-i", self.root / "mono.opus", "-f", "s16le", "-")), 2 * 576000)
        info = json.loads(subprocess.run([CLI, "media", "inspect", "--json", "--no-sidecar", self.root / "mono.opus"],
                                         capture_output=True, text=True, timeout=30).stdout)
        self.assertEqual(ratio(info["media"]["duration"]), 12)

    def test_matroska_hevc_copies_to_an_hvc1_sample_entry(self):
        # FFmpeg labels HEVC without a MOV sample entry 'hev1', which AVFoundation cannot decode.
        helper = self.root / "DecodeFrameIDs"
        subprocess.run(["swiftc", "-parse-as-library", Path(__file__).with_name("DecodeFrameIDs.swift"), "-o", helper],
                       check=True, capture_output=True, timeout=300)
        marker = "geq=lum='if(lt(Y,16)*lt(X,128),if(bitand(N,pow(2,floor(X/16))),210,32),lum(X,Y))'"
        gop = "keyint=25:min-keyint=25:scenecut=0:open-gop=0:bframes=3:pools=1:log-level=error"
        for name, extra in [("plain.mkv", ""), ("repeated.mkv", ":repeat-headers=1")]:
            source = self.root / name
            ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x96:r=25:d=3", "-vf", marker, "-c:v", "libx265",
                   "-x265-params", gop + extra, source, allow_diagnostics=True)
            for ext in ["mp4", "mov"]:
                with self.subTest(source=name, container=ext):
                    output = self.root / (source.stem + "." + ext)
                    self.export(source, output)
                    stream = probe(output, "-select_streams", "v:0", "-show_streams")["streams"][0]
                    self.assertEqual(stream["codec_tag_string"], "hvc1")
                    self.assertEqual(sample_hashes(output), sample_hashes(source))
                    self.assertEqual(frames(output), frames(source))
                    decoded = subprocess.run([helper, output], capture_output=True, timeout=60)
                    self.assertEqual(decoded.returncode, 0, decoded.stderr)
                    self.assertEqual(decoded.stdout, bytes(range(75)))
            trimmed = self.root / (source.stem + "-trim.mov")
            self.export(source, trimmed, "--from", "1", "--to", "2", "--clip", source, "--to", "1")
            self.assertEqual(probe(trimmed, "-select_streams", "v:0", "-show_streams")["streams"][0]["codec_tag_string"], "hvc1")
            self.assertEqual(subprocess.run([helper, trimmed], capture_output=True, timeout=60).stdout,
                             bytes(range(25, 50)) + bytes(range(25)))
        # Parameter sets that change at a keyframe start a new 'hvc1' sample entry that holds every set then active,
        # so Apple's reader decodes every picture. (The copy used to stay 'hev1', which it cannot decode.)
        parts = []
        for index, offsets in enumerate(["", ":cbqpoffs=3:crqpoffs=-2"]):
            part = self.root / f"part{index}.hevc"
            ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x96:r=25:d=2", "-c:v", "libx265",
                   "-x265-params", gop.replace("bframes=3", "bframes=0") + ":repeat-headers=1" + offsets, part,
                   allow_diagnostics=True)
            parts.append(part.read_bytes())
        joined = self.root / "changing.hevc"
        joined.write_bytes(b"".join(parts))
        changing = self.root / "changing.mkv"
        ffmpeg("-r", "25", "-i", joined, "-c", "copy", changing)
        units = b"".join(parts).replace(b"\x00\x00\x00\x01", b"\x00\x00\x01").split(b"\x00\x00\x01")
        self.assertEqual(len({unit.rstrip(b"\x00") for unit in units if unit and (unit[0] >> 1) & 0x3f == 34}), 2)
        for ext, ranges in [("mp4", ()), ("mov", ("--from", "3", "--to", "4", "--clip", changing, "--to", "1"))]:
            with self.subTest(changing=ext):
                output = self.root / ("changing." + ext)
                self.export(changing, output, *ranges)
                self.assertEqual(probe(output, "-select_streams", "v:0", "-show_streams")["streams"][0]["codec_tag_string"], "hvc1")
                expected = sample_hashes(changing)
                self.assertEqual(sample_hashes(output), expected[75:] + expected[:25] if ranges else expected)
                self.assertEqual(len(frames(output)), 50 if ranges else 100)
                self.assertGreater(output.read_bytes().count(b"hvcC"), 1)
                decoded = subprocess.run([helper, output], capture_output=True, timeout=60)
                self.assertEqual(decoded.returncode, 0, decoded.stderr)
                self.assertEqual(len(decoded.stdout), 50 if ranges else 100)

    def test_matroska_hevc_parameter_set_change_inside_a_group_is_reported(self):
        # A new 'hvc1' sample entry starts only at a keyframe (test_matroska_hevc_copies_to_an_hvc1_sample_entry). A
        # picture parameter set brought inside a picture group with an ID no set holds is put in the entry the range
        # starts with, so the sample only repeats it. Any other set brought inside a group keeps the copy 'hev1', which
        # Apple's readers cannot decode, so the plan and the export say so. (They used to say nothing.)
        helper = self.root / "DecodeFrameIDs"
        subprocess.run(["swiftc", "-parse-as-library", Path(__file__).with_name("DecodeFrameIDs.swift"), "-o", helper],
                       check=True, capture_output=True, timeout=300)

        def renumbered(pps):
            # The same picture parameter set with ID 1: its leading Exp-Golomb code grows from 1 to 3 bits.
            bits = "".join(f"{byte:08b}" for byte in pps[2:].replace(b"\x00\x00\x03", b"\x00\x00"))
            self.assertEqual(bits[0], "1")
            bits = "010" + bits[1:bits.rindex("1")] + "1"
            data = int(bits + "0" * (-len(bits) % 8), 2).to_bytes((len(bits) + 7) // 8, "big")
            return pps[:2] + re.sub(rb"\x00\x00(?=[\x00-\x03])", lambda match: match[0] + b"\x03", data)

        marker = "geq=lum='if(lt(Y,16)*lt(X,128),if(bitand(N,pow(2,floor(X/16))),210,32),lum(X,Y))'"
        gop = "keyint=25:min-keyint=25:scenecut=0:open-gop=0:bframes=0:pools=1:log-level=error"
        pictures = {}
        # The second encode differs in its picture parameter set only: wavefronts, transform skip, sign hiding, chroma.
        for name, extra in [("a", ""), ("c", ":wpp=0:signhide=0:tskip=1:cbqpoffs=2")]:
            part = self.root / f"{name}.hevc"
            ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x96:r=25:d=4", "-vf", marker, "-c:v", "libx265",
                   "-x265-params", gop + extra, part, allow_diagnostics=True)
            units = [unit.rstrip(b"\x00") for unit in
                     part.read_bytes().replace(b"\x00\x00\x00\x01", b"\x00\x00\x01").split(b"\x00\x00\x01") if unit]
            groups, pending = [], []
            for unit in units:
                pending.append(unit)
                if (unit[0] >> 1) & 63 < 32:  # One slice per picture: its VCL unit ends the access unit.
                    groups.append(pending)
                    pending = []
            pictures[name] = groups
        sets = {name: {(unit[0] >> 1) & 63: unit for unit in groups[0] if 32 <= (unit[0] >> 1) & 63 <= 34}
                for name, groups in pictures.items()}
        self.assertEqual((sets["a"][32], sets["a"][33]), (sets["c"][32], sets["c"][33]))
        self.assertNotEqual(sets["a"][34], sets["c"][34])
        vps = sets["a"][32]
        changes = {
            # Picture 37, a P picture, brings the second encode's picture parameter set, and every later picture uses it.
            "pps": pictures["a"][:37] + [[sets["c"][34]] + pictures["c"][37]] + pictures["c"][38:],
            # Picture 37 brings a video parameter set with another ID, which nothing uses.
            "vps": pictures["a"][:37] + [[vps[:2] + bytes([vps[2] & 0x0F | 0x10]) + vps[3:]] + pictures["a"][37]]
                   + pictures["a"][38:],
            # Picture 37 brings the second encode's picture parameter set as ID 1, which no set holds and nothing uses.
            "new-id": pictures["a"][:37] + [[renumbered(sets["c"][34])] + pictures["a"][37]] + pictures["a"][38:],
        }
        for name, groups in changes.items():
            raw = self.root / f"{name}.hevc"
            raw.write_bytes(b"".join(b"\x00\x00\x00\x01" + unit for group in groups for unit in group))
            source = self.root / f"{name}.mkv"
            # A raw stream states no field order; MPCut ends inside a picture group only for progressive pictures.
            ffmpeg("-r", "25", "-i", raw, "-c", "copy", "-field_order", "progressive", source)
            source_hashes, source_frames = sample_hashes(source), frames(source)
            note = (f"HEVC parameter sets change mid-picture-group in {source.name}, so the copy uses an hev1 "
                    "description that AVFoundation and QuickTime cannot play; FFmpeg-based players can.")
            for ext, ranges, kept, warned in [
                    ("mp4", (), range(100), True),
                    ("mov", ("--from", "1", "--to", "2", "--clip", source, "--to", "1"), [*range(25, 50), *range(25)], True),
                    # Ranges that leave out picture 37 copy as 'hvc1' with nothing to report.
                    ("mov", ("--from", "1", "--to", "1.48", "--clip", source, "--to", "1"), [*range(25, 37), *range(25)], False)]:
                warned = warned and name != "new-id"
                with self.subTest(change=name, container=ext, ranges=ranges):
                    output = self.root / f"{name}-{len(kept)}.{ext}"
                    plan = self.export(source, output, *ranges, dry_run=True)
                    report = self.export(source, output, *ranges)
                    self.assertEqual(sample_hashes(output), [source_hashes[index] for index in kept])
                    self.assertEqual(frames(output), [source_frames[index] for index in kept])
                    tag = probe(output, "-select_streams", "v:0", "-show_streams")["streams"][0]["codec_tag_string"]
                    self.assertEqual(tag, "hev1" if warned else "hvc1")
                    self.assertEqual(note in plan.get("warnings", []), warned)
                    self.assertEqual(note in report.get("warnings", []), warned)
                    if not warned:
                        # One sample entry, which a new ID joins: no entry starts inside a picture group.
                        self.assertEqual(output.read_bytes().count(b"hvcC"), 1)
                        decoded = subprocess.run([helper, output], capture_output=True, timeout=60)
                        self.assertEqual(decoded.returncode, 0, decoded.stderr)
                        self.assertEqual(decoded.stdout, bytes(kept))

    def test_copies_start_from_the_parameter_sets_the_source_holds_there(self):
        # A keyframe after an in-band parameter set change that later keyframes do not repeat is offered as a start.
        # Decoded from the start of the source it uses the changed sets, but a copy that started there, or a join whose
        # earlier range left other sets in the decoder, kept the sets of the description and decoded with errors. Each
        # range now starts from the sets its source holds there: in an 'hvc1' sample entry, or repeated before the
        # source's own bytes in the range's first sample (Matroska, hev1 and avc1), where the decoder lacks them.
        helper = self.root / "DecodeFrameIDs"
        subprocess.run(["swiftc", "-parse-as-library", Path(__file__).with_name("DecodeFrameIDs.swift"), "-o", helper],
                       check=True, capture_output=True, timeout=300)
        marker = "geq=lum='if(lt(Y,16)*lt(X,128),if(bitand(N,pow(2,floor(X/16))),210,32),lum(X,Y))'"
        # Per codec: encoder arguments, those of a second encode that differs in its picture parameter set only, the
        # NAL unit type, whether a type is a picture (VCL) unit, and the parameter set types in decoder order.
        codecs = {
            "h264": (["-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-x264-params",
                      "keyint=25:min-keyint=25:scenecut=0:bframes=0:threads=1"], ":cabac=0:chroma-qp-offset=3",
                     lambda unit: unit[0] & 31, lambda kind: 1 <= kind <= 5, [7, 8]),
            "hevc": (["-c:v", "libx265", "-x265-params",
                      "keyint=25:min-keyint=25:scenecut=0:open-gop=0:bframes=0:pools=1:log-level=error"],
                     ":wpp=0:signhide=0:tskip=1:cbqpoffs=2", lambda unit: (unit[0] >> 1) & 63, lambda kind: kind < 32,
                     [32, 33, 34]),
        }

        def lengthed(units):
            return b"".join(len(unit).to_bytes(4, "big") + unit for unit in units)

        def samples(path):
            sizes = [int(packet["size"]) for packet in
                     probe(path, "-select_streams", "v:0", "-show_packets", "-show_entries", "packet=size")["packets"]]
            data = ffmpeg("-i", path, "-map", "0:v:0", "-c", "copy", "-f", "data", "-")
            self.assertEqual(sum(sizes), len(data))
            starts = [sum(sizes[:index]) for index in range(len(sizes))]
            return [data[start:start + size] for start, size in zip(starts, sizes)]

        for codec, (encoder, other, kind, picture, kinds) in codecs.items():
            pictures = {}
            for name, extra in [("a", ""), ("c", other)]:
                part = self.root / f"{codec}-{name}.{codec}"
                ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x96:r=25:d=4", "-vf", marker, *encoder[:-1], encoder[-1] + extra,
                       part, allow_diagnostics=True)
                units = [unit.rstrip(b"\x00") for unit in
                         part.read_bytes().replace(b"\x00\x00\x00\x01", b"\x00\x00\x01").split(b"\x00\x00\x01") if unit]
                groups, pending = [], []
                for unit in units:
                    pending.append(unit)
                    if picture(kind(unit)):  # One slice per picture: its VCL unit ends the access unit.
                        groups.append(pending)
                        pending = []
                self.assertEqual(len(groups), 100)
                pictures[name] = groups
            sets = {name: {kind(unit): unit for unit in groups[0] if kind(unit) in kinds} for name, groups in pictures.items()}
            self.assertEqual([sets["a"][k] for k in kinds[:-1]], [sets["c"][k] for k in kinds[:-1]])
            self.assertNotEqual(sets["a"][kinds[-1]], sets["c"][kinds[-1]])
            # The sets a decoder holds before and after the change, in the order a copy repeats them.
            state = {"a": [sets["a"][k] for k in kinds], "c": [sets["a"][k] for k in kinds[:-1]] + [sets["c"][kinds[-1]]]}

            # Only the first picture carries the stream's sets: an encoder may repeat them at every keyframe.
            a, c = ([groups[0]] + [[unit for unit in group if kind(unit) not in kinds] for group in groups[1:]]
                    for groups in (pictures["a"], pictures["c"]))
            changes = {
                # Keyframe 25 brings the second encode's picture parameter set, which every later picture uses.
                "key": a[:25] + [[sets["c"][kinds[-1]]] + c[25]] + c[26:],
                # Picture 37, a P picture, brings it.
                "group": a[:37] + [[sets["c"][kinds[-1]]] + c[37]] + c[38:],
                # Keyframe 25 brings it, and so do the later keyframes, which then need nothing more.
                "repeated": a[:25] + [[sets["c"][kinds[-1]]] + group if index % 25 == 0 else group
                                      for index, group in enumerate(c[25:], 25)],
            }
            for change, groups in changes.items():
                raw = self.root / f"{codec}-{change}.{codec}"
                raw.write_bytes(b"".join(b"\x00\x00\x00\x01" + unit for group in groups for unit in group))
                sources = [self.root / f"{codec}-{change}.{ext}" for ext in ("mkv", "mp4", "mov")]
                ffmpeg("-r", "25", "-i", raw, "-c", "copy", sources[0])
                for other_source in sources[1:]:
                    ffmpeg("-i", sources[0], "-c", "copy", other_source)
                for source in sources:
                    source_frames, source_samples = frames(source), samples(source)
                    self.assertEqual(len(source_frames), 100)
                    # Ranges, the pictures each keeps, and the sets its keyframes repeat where it has no entry of its own.
                    plans = [(("--from", "2", "--to", "3"), [range(50, 75)], ["c"]),
                             (("--from", "2", "--to", "4"), [range(50, 100)], ["c"]),
                             (("--to", "1", "--clip", source, "--from", "2", "--to", "3"), [range(25), range(50, 75)],
                              [None, "c"]),
                             (("--from", "2", "--to", "3", "--clip", source, "--from", "1", "--to", "2"),
                              [range(50, 75), range(25, 50)], ["c", "a" if change == "group" else None])]
                    if change == "repeated":
                        plans = [(ranges, kept, [None]) for ranges, kept, _ in plans[:2]]
                    for number, (ranges, kept, repeated) in enumerate(plans):
                        for ext in ("mkv", "mp4", "mov"):
                            with self.subTest(codec=codec, change=change, source=source.suffix, plan=number, container=ext):
                                output = self.root / f"{codec}-{change}-{source.suffix[1:]}-{number}.{ext}"
                                report = self.export(source, output, *ranges)
                                self.assertEqual(frames(output), [source_frames[index] for span in kept for index in span])
                                tag = "" if ext == "mkv" else \
                                    probe(output, "-select_streams", "v:0", "-show_streams")["streams"][0]["codec_tag_string"]
                                # Matroska HEVC copies to 'hvc1' sample entries, which describe each range's start. A
                                # set that changes inside a copied picture group relabels the track 'hev1' after them.
                                group_change = codec == "hevc" and change == "group" and number == 3  # Keeps picture 37.
                                described = codec == "hevc" and source.suffix == ".mkv" and ext != "mkv"
                                if described:
                                    self.assertEqual(tag, "hev1" if group_change else "hvc1")
                                if described and change == "repeated":
                                    # The one entry holds the sets the range starts from, which its keyframes repeat.
                                    # (The copy used to begin with the description's entry, then switch at once.)
                                    self.assertEqual(output.read_bytes().count(b"hvcC"), 1)
                                note = (f"HEVC parameter sets change mid-picture-group in {source.name}, so the copy uses an "
                                        "hev1 description that AVFoundation and QuickTime cannot play; FFmpeg-based players can.")
                                self.assertEqual(note in report.get("warnings", []),
                                                 group_change and source.suffix == ".mkv" and ext != "mkv")
                                # A range that starts with repeated sets repeats them at each of its keyframes (one
                                # every 25 pictures), whose description and own bytes lack them, so a reader can start
                                # there too.
                                expected = []
                                for span, sets in zip(kept, repeated):
                                    for index in span:
                                        prefix = lengthed(state[sets]) if sets and index % 25 == 0 and not described else b""
                                        expected.append(prefix + source_samples[index])
                                self.assertEqual(samples(output), expected)
                                if tag in ("hvc1", "avc1"):
                                    order = bytes(index for span in kept for index in span)
                                    decoded = subprocess.run([helper, output], capture_output=True, timeout=60)
                                    self.assertEqual(decoded.returncode, 0, decoded.stderr)
                                    self.assertEqual(decoded.stdout, order)
                                    # Apple's reader starting at the second keyframe of the copy.
                                    decoded = subprocess.run([helper, output, "25"], capture_output=True, timeout=60)
                                    self.assertEqual(decoded.returncode, 0, decoded.stderr)
                                    self.assertEqual(decoded.stdout, order[25:])

    def test_smart_trim_edges_and_copies_start_from_the_parameter_sets_the_source_holds(self):
        # Smart Trim re-encodes the pictures before the first keyframe it can copy from, and after the last point it can
        # copy to. After an in-band parameter set change that later keyframes do not repeat, its edge decoder started at
        # the edge's keyframe with the sets of the description, and refused the edge as damaged; the pictures copied after
        # an edge switched back to the description and decoded with errors, which nothing reported. Edges and copies now
        # start from the sets the source's decoder holds there.
        helper = self.root / "DecodeFrameIDs"
        subprocess.run(["swiftc", "-parse-as-library", Path(__file__).with_name("DecodeFrameIDs.swift"), "-o", helper],
                       check=True, capture_output=True, timeout=300)
        marker = "geq=lum='if(lt(Y,16)*lt(X,128),if(bitand(N,pow(2,floor(X/16))),210,32),lum(X,Y))'"
        # Three B pictures between anchors, so that ends between keyframes leave pictures for a tail edge to encode.
        codecs = {
            "h264": (["-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-x264-params",
                      "keyint=25:min-keyint=25:scenecut=0:bframes=3:b-adapt=0:threads=1"], ":cabac=0:chroma-qp-offset=3",
                     lambda unit: unit[0] & 31, 8, b"V_MPEG4/ISO/AVC"),
            "hevc": (["-c:v", "libx265", "-x265-params",
                      "keyint=25:min-keyint=25:scenecut=0:open-gop=0:bframes=3:b-adapt=0:pools=1:log-level=error"],
                     ":wpp=0:signhide=0:tskip=1:cbqpoffs=2", lambda unit: (unit[0] >> 1) & 63, 34, b"V_MPEGH/ISO/HEVC"),
        }

        def packets(path):
            entries = probe(path, "-select_streams", "v:0", "-show_packets", "-show_entries", "packet=pts,size,flags")["packets"]
            data = ffmpeg("-i", path, "-map", "0:v:0", "-c", "copy", "-f", "data", "-")
            samples, at = [], 0
            for entry in entries:
                size = int(entry["size"])
                samples.append((int(entry["pts"]), "K" in entry["flags"], data[at:at + size]))
                at += size
            self.assertEqual(at, len(data))
            return samples

        def extradata(path):
            dump = probe(path, "-select_streams", "v:0", "-show_streams", "-show_data")["streams"][0]["extradata"]
            return bytes.fromhex("".join(line[10:49].replace(" ", "") for line in dump.strip().splitlines()))

        def element(ident, payload):
            return ident + (1 << 56 | len(payload)).to_bytes(8, "big") + payload

        def unsigned(ident, value):
            return element(ident, value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big"))

        def matroska(path, codec_id, private, samples):
            # The smallest Matroska file FFmpeg reads: one progressive 320x96 track, one cluster, millisecond block times.
            header = element(b"\x1a\x45\xdf\xa3", unsigned(b"\x42\x86", 1) + unsigned(b"\x42\xf7", 1) + unsigned(b"\x42\xf2", 4)
                             + unsigned(b"\x42\xf3", 8) + element(b"\x42\x82", b"matroska") + unsigned(b"\x42\x87", 4)
                             + unsigned(b"\x42\x85", 2))
            info = element(b"\x15\x49\xa9\x66", unsigned(b"\x2a\xd7\xb1", 1_000_000) + element(b"\x4d\x80", b"audit")
                           + element(b"\x57\x41", b"audit"))
            track = element(b"\xae", unsigned(b"\xd7", 1) + unsigned(b"\x73\xc5", 1) + unsigned(b"\x83", 1) + element(b"\x86", codec_id)
                            + element(b"\x63\xa2", private) + unsigned(b"\x23\xe3\x83", 40_000_000)
                            + element(b"\xe0", unsigned(b"\xb0", 320) + unsigned(b"\xba", 96) + unsigned(b"\x9a", 2)))
            blocks = b"".join(element(b"\xa3", b"\x81" + pts.to_bytes(2, "big", signed=True) + (b"\x80" if key else b"\x00")
                                      + data) for pts, key, data in samples)
            path.write_bytes(header + element(b"\x18\x53\x80\x67", info + element(b"\x16\x54\xae\x6b", track)
                                              + element(b"\x1f\x43\xb6\x75", unsigned(b"\xe7", 0) + blocks)))

        def pictures(path):
            data = ffmpeg("-i", path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "nv12", "-")
            size = 320 * 96 * 3 // 2
            return [data[at:at + size] for at in range(0, len(data), size)]

        def psnr(a, b):
            error = sum((x - y) * (x - y) for x, y in zip(a, b))
            return 99.0 if not error else 10 * math.log10(255 * 255 * len(a) / error)

        for codec, (encoder, other, kind, pps_type, codec_id) in codecs.items():
            encodes = {}
            for name, extra in [("a", ""), ("c", other)]:
                encode = self.root / f"smart-{codec}-{name}.mkv"
                ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x96:r=25:d=4", "-vf", marker, *encoder[:-1], encoder[-1] + extra,
                       encode, allow_diagnostics=True)
                encodes[name] = packets(encode)
            private = extradata(self.root / f"smart-{codec}-a.mkv")
            pps = extradata(self.root / f"smart-{codec}-c.mkv")
            # The second encode's picture parameter set, from its hvcC or avcC record.
            pps = next(unit for unit in self.record_units(pps, codec) if kind(unit) == pps_type)
            self.assertEqual([pts for pts, _, _ in encodes["a"]], [pts for pts, _, _ in encodes["c"]])
            # Decode position 25 is keyframe 25 (1 s); position 37 a picture inside its group. The pictures from there on
            # come from the second encode, which needs its own picture parameter set, brought there and never again.
            for change, split in [("key", 25), ("group", 37)]:
                samples = [(pts, key, (len(pps).to_bytes(4, "big") + pps if index == split else b"") + data)
                           for index, ((pts, key, _), (_, _, data)) in
                           enumerate(zip(encodes["a"], encodes["a"][:split] + encodes["c"][split:]))]
                spliced = self.root / f"smart-{codec}-{change}.mkv"
                matroska(spliced, codec_id, private, samples)
                for ext in ("mp4", "mov"):
                    # Smart Trim takes MOV-family sources: hev1 or avc1, keeping the set in the sample that brings it.
                    source = self.root / f"smart-{codec}-{change}.{ext}"
                    ffmpeg("-i", spliced, "-c", "copy", source)
                    reference = pictures(source)
                    self.assertEqual(len(reference), 100)
                    # Ranges, the pictures kept, and the number of edges each range gets: head only, tail only, both, one
                    # edge for the whole range, and joins after a tail edge and before a head edge.
                    plans = [(("--from", "1.2", "--to", "3"), [range(30, 75)], [1]),
                             (("--from", "2", "--to", "2.88"), [range(50, 72)], [1]),
                             (("--from", "2.2", "--to", "3.64"), [range(55, 91)], [2]),
                             (("--from", "2.2", "--to", "2.8"), [range(55, 70)], [1]),
                             (("--from", "2", "--to", "2.88", "--clip", source, "--to", "1"), [range(50, 72), range(25)],
                              [1, 0]),
                             (("--to", "1", "--clip", source, "--from", "2.2", "--to", "3.64"), [range(25), range(55, 91)],
                              [0, 2]),
                             # A head edge, then copied keyframes 50 and 75: a reader can start at either.
                             (("--from", "1.2", "--to", "4"), [range(30, 100)], [1])]
                    # A copy that keeps the sample bringing the set: an hvc1 entry cannot hold it, so Smart Trim says so.
                    plans.append((("--from", "1", "--to", "2.88"), [range(25, 72)], None))
                    for number, (ranges, kept, edge_counts) in enumerate(plans):
                        with self.subTest(codec=codec, change=change, source=ext, plan=number):
                            output = self.root / f"smart-{codec}-{change}-{ext}-{number}.mp4"
                            refused = edge_counts is None and codec == "hevc"
                            report = self.export(source, output, "--mode", "smart", *ranges, ok=not refused)
                            if refused:
                                self.assertIn("in-band parameter sets", report["error"]["message"])
                                continue
                            self.assertEqual(report["mode"], "smart")
                            edges = [[(ratio(edge["from"]), ratio(edge["to"])) for edge in segment.get("encoded_edges", [])]
                                     for segment in report["segments"]]
                            if edge_counts is not None:
                                self.assertEqual([len(found) for found in edges], edge_counts)
                            decoded = pictures(output)
                            order = [index for span in kept for index in span]
                            self.assertEqual(len(decoded), len(order))
                            for position, (index, picture) in enumerate(zip(order, decoded)):
                                time = Fraction(index, 25)
                                if any(start <= time < end for found in edges for start, end in found):
                                    self.assertGreater(psnr(picture, reference[index]), 28, (position, index))
                                else:
                                    self.assertEqual(picture, reference[index], (position, index))
                            ids = subprocess.run([helper, output], capture_output=True, timeout=60)
                            self.assertEqual(ids.returncode, 0, ids.stderr)
                            self.assertEqual(ids.stdout, bytes(order))
                            if order[-1] == 99:
                                # Apple's reader starting at the second copied keyframe (75), output time 1.8 s.
                                ids = subprocess.run([helper, output, str(order.index(75))], capture_output=True, timeout=60)
                                self.assertEqual(ids.returncode, 0, ids.stderr)
                                self.assertEqual(ids.stdout, bytes(range(75, 100)))

    @staticmethod
    def record_units(record, codec):
        """The parameter sets of an avcC or hvcC record."""
        units = []
        if codec == "h264":
            at = 5
            for kind in range(2):
                count, at = (record[at] & 31 if kind == 0 else record[at]), at + 1
                for _ in range(count):
                    length = int.from_bytes(record[at:at + 2], "big")
                    units.append(record[at + 2:at + 2 + length])
                    at += 2 + length
            return units
        at = 23
        for _ in range(record[22]):
            count, at = int.from_bytes(record[at + 1:at + 3], "big"), at + 3
            for _ in range(count):
                length = int.from_bytes(record[at:at + 2], "big")
                units.append(record[at + 2:at + 2 + length])
                at += 2 + length
        return units

    def test_cropped_mp3_places_chapters_on_its_audible_samples(self):
        spans = [(0, 4, "One"), (4, 8, "Two"), (8, 12, "Three")]
        source = self.root / "book.mp3"
        ffmpeg("-f", "lavfi", "-i", "sine=frequency=330:sample_rate=44100:duration=12", "-i", self.chapter_list(*spans),
               "-map", "0:a", "-map_metadata", "1", "-map_chapters", "1", "-c:a", "libmp3lame", "-b:a", "128k", source)

        def marks(path):
            # MP3 chapter times count from the first frame, and the track's start time is its first audible sample.
            audible = Fraction(probe(path, "-select_streams", "a:0", "-show_streams")["streams"][0]["start_time"])
            return [(start, start - audible, title) for start, _, title in self.chapters(path)]

        original = marks(source)
        self.assertEqual([title for _, _, title in original], ["One", "Two", "Three"])
        crop = self.root / "crop.mp3"
        self.assertNotIn("warnings", self.export(source, crop, "--from", "2", "--to", "10"))
        again = self.root / "again.mp3"
        self.assertNotIn("warnings", self.export(crop, again))
        for output in [crop, again]:
            with self.subTest(output=output.name):
                placed = marks(output)
                self.assertEqual([title for _, _, title in placed], ["One", "Two", "Three"])
                # The chapter that is playing at the cut starts with the file, hidden decoder history included.
                self.assertEqual(placed[0][0], 0)
                for (_, expected, _), (_, found, _) in zip(original[1:], placed[1:]):
                    self.assertLess(abs(found - (expected - 2)), Fraction(1, 1000))

    def test_movie_metadata_the_container_cannot_hold_is_named(self):
        # A camera writes its make, model and capture date as QuickTime metadata keys. Without that key form the
        # MOV muxer keeps only the classic user-data fields, so a copy names the keys it leaves behind.
        source = self.root / "camera.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc=d=2:s=160x90:r=25", "-c:v", "libx264", "-g", "25",
               "-metadata", "com.apple.quicktime.make=Apple", "-metadata", "com.apple.quicktime.model=iPhone",
               "-metadata", "title=Take 1", "-movflags", "+use_metadata_tags", source)
        for name in ["copy.mov", "copy.mp4"]:
            with self.subTest(output=name):
                out = self.root / name
                planned = self.export(source, out, "--from", "0", "--to", "1", dry_run=True)
                written = self.export(source, out, "--from", "0", "--to", "1")
                # A dry run and the export name the same keys. The title has a field and is not named.
                for report in [planned, written]:
                    note = next((warning for warning in report.get("warnings", []) if "movie metadata" in warning), None)
                    self.assertIsNotNone(note, report.get("warnings"))
                    self.assertIn("com.apple.quicktime.make", note)
                    self.assertIn("com.apple.quicktime.model", note)
                    self.assertNotIn("title", note)
                tags = probe(out, "-show_entries", "format_tags")["format"].get("tags", {})
                self.assertNotIn("com.apple.quicktime.make", tags)
                self.assertEqual(tags.get("title"), "Take 1")
        # A re-encode writes no source metadata, so it names every key, the title among them.
        encoded = self.root / "encoded.mov"
        for report in [self.export(source, encoded, "--from", "0", "--to", "1", "--mode", "encode", dry_run=True),
                       self.export(source, encoded, "--from", "0", "--to", "1", "--mode", "encode")]:
            note = next((warning for warning in report.get("warnings", []) if "does not carry the movie metadata" in warning), None)
            self.assertIsNotNone(note, report.get("warnings"))
            for key in ["com.apple.quicktime.make", "com.apple.quicktime.model", "title"]:
                self.assertIn(key, note)
        # A recording with only the fields every container has, or that the muxer writes itself, names nothing.
        plain = self.root / "plain.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc=d=2:s=160x90:r=25", "-c:v", "libx264", "-g", "25", "-metadata", "title=Plain", plain)
        report = self.export(plain, self.root / "plain-copy.mp4", "--from", "0", "--to", "1", dry_run=True)
        self.assertFalse(any("movie metadata" in warning for warning in report.get("warnings", [])), report)
        bare = self.root / "bare.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc=d=2:s=160x90:r=25", "-c:v", "libx264", "-g", "25", bare)
        report = self.export(bare, self.root / "bare-encoded.mov", "--from", "0", "--to", "1", "--mode", "encode", dry_run=True)
        self.assertFalse(any("movie metadata" in warning for warning in report.get("warnings", [])), report)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
