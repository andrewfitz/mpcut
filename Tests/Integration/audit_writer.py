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
        report = self.export(cropped, out, "--mode", "encode", "--audio", "auto")
        self.assertEqual(report["audio_actions"][0]["action"], "aac")
        audio_stream = probe(out, "-select_streams", "a:0", "-show_streams")["streams"][0]
        self.assertEqual(audio_stream["codec_name"], "aac")
        self.assertEqual(int(audio_stream["duration_ts"]) * Fraction(audio_stream["time_base"]), 2)

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
        # the movie also has chapters. It is still refused.
        captions = self.root / "captions.srt"
        captions.write_text("1\n00:00:00,500 --> 00:00:02,000\nHello\n")
        for name, chapter_options in [("captions.mp4", []), ("captions.mov", []),
                                      ("captions-chapters.mp4", ["-i", listing, "-map_metadata", "2", "-map_chapters", "2"])]:
            with self.subTest(name=name):
                movie = self.root / name
                ffmpeg("-i", first, "-i", captions, *chapter_options, "-map", "0:v", "-map", "0:a", "-map", "1:s",
                       "-c:v", "copy", "-c:a", "copy", "-c:s", "mov_text", *([] if chapter_options else ["-map_chapters", "-1"]), movie)
                self.assertIn("subtitle", [track["codec_type"] for track in probe(movie, "-show_streams")["streams"]])
                report = self.export(movie, self.root / ("refused-" + name), "--no-sidecar", dry_run=True, ok=False)
                self.assertEqual(report["error"]["code"], "unsupported_tracks")
                self.assertEqual(report["error"]["reason"], "source_unsupported_tracks")

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
        for source, name, selection in [(album, "one-track.m4a", ["--tracks", "audio", "--audio-stream", "0"]),
                                        (film, "film-sound.m4a", ["--tracks", "audio"]),
                                        (film, "film-picture.mp4", ["--tracks", "video"])]:
            for dry_run in [True, False]:
                with self.subTest(name=name, dry_run=dry_run):
                    report = self.export(source, self.root / name, *selection, dry_run=dry_run)
                    self.assertEqual(report["warnings"], [note])
            kinds = [track["disposition"]["attached_pic"] for track in probe(self.root / name, "-show_streams")["streams"]]
            self.assertEqual(kinds, [0])

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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
