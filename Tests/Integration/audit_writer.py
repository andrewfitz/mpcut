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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
