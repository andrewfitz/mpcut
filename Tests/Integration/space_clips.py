#!/usr/bin/env python3
"""Verify CLI clip spacing against decoded gaps and copied camera packets."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import audio, ffmpeg, probe, ratio, timestamped_hashes


CLI = None
FRAME_RATE = 25
FRAME_SIZE = 160 * 96
SAMPLE_RATE = 48_000
CLIPS = ((10, 20), (40, 50))


class SpaceClips(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix="mpcut-spacing-source-")
        cls.addClassCleanup(temporary.cleanup)
        cls.source = Path(temporary.name) / "camera.mov"
        ffmpeg("-f", "lavfi", "-i", f"testsrc2=s=160x96:r={FRAME_RATE}",
               "-f", "lavfi", "-i", f"sine=frequency=997:sample_rate={SAMPLE_RATE}",
               "-t", "3", "-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le",
               "-color_range", "tv", "-colorspace", "bt709", "-color_trc", "bt709",
               "-color_primaries", "bt709", "-c:a", "pcm_s16le", "-movflags", "+write_colr", cls.source)
        cls.source_packets = dict(timestamped_hashes(cls.source))
        cls.source_audio = audio(cls.source)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="mpcut-spacing-output-")
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name) / "output.mov"

    def run_export(self, *options, request=None, succeeds=True):
        path = ["project", "render"] if "--project" in options else ["clips", "join"]
        command = [CLI, "export", *path, "--json", "--snap", "exact", "--output", self.output, *options]
        if request is not None:
            path = ["project", "render"] if "project_path" in request else ["clips", "join"]
            command = [CLI, "export", *path, "--json", "--stdin", *options]
            request = json.dumps({"output": str(self.output), "snap": "exact", **request})
        result = subprocess.run(command, input=request, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertIs(report["ok"], succeeds)
        if "--dry-run" in options or not succeeds:
            self.assertFalse(self.output.exists())
        return report

    def export(self, *options, clips=CLIPS, succeeds=True):
        arguments = list(options)
        for start, end in clips:
            arguments.extend(["--clip", self.source, "--from", str(Fraction(start, FRAME_RATE)),
                              "--to", str(Fraction(end, FRAME_RATE))])
        return self.run_export(*arguments, succeeds=succeeds)

    def assert_rendered(self, gap_frames, clips=CLIPS):
        total_frames = sum(end - start for start, end in clips) + gap_frames * (len(clips) - 1)
        expected_times = [Fraction(i, FRAME_RATE) for i in range(total_frames)]
        rendered_packets = timestamped_hashes(self.output)
        self.assertEqual([timestamp for timestamp, _ in rendered_packets], expected_times)
        video = probe(self.output, "-select_streams", "v:0", "-show_streams")["streams"][0]
        self.assertEqual(int(video["duration_ts"]) * Fraction(video["time_base"]),
                         Fraction(total_frames, FRAME_RATE))

        rendered_hashes = dict(rendered_packets)
        offset = 0
        for start, end in clips:
            for frame in range(start, end):
                self.assertEqual(rendered_hashes[Fraction(offset + frame - start, FRAME_RATE)],
                                 self.source_packets[Fraction(frame, FRAME_RATE)])
            offset += end - start + gap_frames

    def assert_black_and_silent(self, gap_frames):
        first, second = CLIPS
        first_clip_frames = first[1] - first[0]
        gap_end = first_clip_frames + gap_frames
        decoded = ffmpeg("-i", self.output, "-map", "0:v:0", "-pix_fmt", "gray", "-f", "rawvideo", "-")
        gap = decoded[first_clip_frames * FRAME_SIZE:gap_end * FRAME_SIZE]
        self.assertEqual(len(gap), gap_frames * FRAME_SIZE)
        self.assertLessEqual(max(gap), 2)
        self.assertGreater(max(decoded[(first_clip_frames - 1) * FRAME_SIZE:first_clip_frames * FRAME_SIZE]), 32)
        self.assertGreater(max(decoded[gap_end * FRAME_SIZE:(gap_end + 1) * FRAME_SIZE]), 32)

        bytes_per_frame = 2 * SAMPLE_RATE // FRAME_RATE

        def source_pcm(start, end):
            return self.source_audio[start * bytes_per_frame:end * bytes_per_frame]

        self.assertEqual(audio(self.output),
                         source_pcm(*first) + bytes(gap_frames * bytes_per_frame) + source_pcm(*second))

    def test_source_spacing_uses_the_removed_source_duration(self):
        plan = self.export("--space-clips", "source", "--dry-run")
        self.assertEqual(ratio(plan["duration"]), Fraction(8, 5))
        self.assertEqual(ratio(plan["generated_still_duration"]), Fraction(4, 5))
        self.assertEqual(ratio(plan["copied_camera_duration"]), Fraction(4, 5))
        self.assertEqual(ratio(plan["encoded_camera_duration"]), 0)
        result = self.export("--space-clips", "source")
        self.assertEqual(result["duration"], plan["duration"])
        self.assert_rendered(20)
        self.assert_black_and_silent(20)

    def test_fixed_spacing_inserts_the_requested_duration(self):
        plan = self.run_export("--dry-run", request={
            "file": str(self.source), "space_clips": {"numerator": 1, "denominator": 5},
            "clips": [{"from": str(Fraction(start, FRAME_RATE)), "to": str(Fraction(end, FRAME_RATE))}
                      for start, end in CLIPS],
        })
        result = self.export("--space-clips", "1/5")
        self.assertEqual(ratio(result["duration"]), 1)
        self.assertEqual(result["duration"], plan["duration"])
        self.assert_rendered(5)
        self.assert_black_and_silent(5)

    def test_spacing_uses_requested_playback_order(self):
        rejected = self.export("--space-clips", "source", "--order", "2,1", "--dry-run", succeeds=False)
        self.assertEqual(rejected["error"]["code"], "invalid_still_project")
        self.export("--space-clips", "1/5", "--order", "2,1")
        self.assert_rendered(5, clips=tuple(reversed(CLIPS)))

    def test_compressed_sound_needs_explicit_conversion_for_silence(self):
        camera = self.output.with_name("camera-aac.mov")
        ffmpeg("-i", self.source, "-c:v", "copy", "-c:a", "aac", camera)
        self.source = camera
        # Copy cannot generate silence, so it refuses.
        with self.subTest(audio_mode="copy"):
            rejected = self.export("--space-clips", "source", "--audio", "copy", "--dry-run", succeeds=False)
            self.assertEqual(rejected["error"]["code"], "generated_audio_required")
        # Auto matches the original: it converts the track in its source codec, AAC at the source sample rate and at
        # the movie rule's bit rate (the first customary step not under the source's average, and at least 96 kbps for
        # each channel), and reports the conversion.
        with self.subTest(audio_mode="auto"):
            written_source = probe(camera, "-select_streams", "a:0", "-show_streams")["streams"][0]
            sizes = probe(camera, "-select_streams", "a:0", "-show_entries", "packet=size")["packets"]
            average = sum(int(packet["size"]) for packet in sizes) * 8 / float(written_source["duration"])
            steps = [32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512]
            channels = int(written_source["channels"])
            expected_rate = max(max(96, min(512, channels * 96)), next((step for step in steps if step * 100 >= average / 1000 * 97), 512)) * 1000
            planned = self.export("--space-clips", "source", "--audio", "auto", "--dry-run")
            converted = self.export("--space-clips", "source", "--audio", "auto")
            try:
                self.assertEqual(converted["sound_actions"], planned["sound_actions"])
                action, = converted["sound_actions"]
                self.assertEqual((action["audio"], action["codec"], action["sample_rate"], action["bit_rate"]),
                                 ("aac", "aac", SAMPLE_RATE, expected_rate))
                self.assertEqual(action["reason"], "The AAC source is written as AAC at its own rate.")
                self.assertEqual(action["generated_silence"], [{"from": "2/5", "to": "6/5"}])
                self.assertIn("Audio track 1, output 2/5–6/5: This interval requires generated silence, so the track is converted.",
                              action["warnings"])
                self.assert_rendered(20)
                track = probe(self.output, "-select_streams", "a:0", "-show_streams")["streams"][0]
                self.assertEqual((track["codec_name"], int(track["sample_rate"])), ("aac", SAMPLE_RATE))
            finally:
                # The PCM export below writes to the same path.
                self.output.unlink(missing_ok=True)
        converted = self.export("--space-clips", "source", "--audio", "pcm")
        action, = converted["sound_actions"]
        self.assertEqual(action["audio"], "pcm")
        self.assertEqual(action["generated_silence"], [{"from": "2/5", "to": "6/5"}])
        self.assert_rendered(20)
        bytes_per_frame = 2 * SAMPLE_RATE // FRAME_RATE
        decoded = audio(self.output)
        silence = decoded[10 * bytes_per_frame:30 * bytes_per_frame]
        self.assertEqual(silence, bytes(20 * bytes_per_frame))

    def test_export_spacing_leaves_the_saved_project_intact(self):
        project = self.output.with_name("original.cut")
        project.write_text(json.dumps({
            "format": "mpcut", "schema_version": 3, "kind": "sequence",
            "clips": [{"id": f"clip-{index}", "file": str(self.source), "from": str(Fraction(start, FRAME_RATE)),
                       "to": str(Fraction(end, FRAME_RATE))} for index, (start, end) in enumerate(CLIPS)],
        }))
        original = project.read_bytes()
        self.run_export("--project", project, "--space-clips", "source")
        self.assert_rendered(20)
        self.assertEqual(project.read_bytes(), original)

    def test_source_spacing_accepts_aliases_for_the_same_recording(self):
        alias = self.output.with_name("camera alias.mov")
        alias.symlink_to(self.source)
        clips = [
            {"file": str(file), "from": str(Fraction(start, FRAME_RATE)), "to": str(Fraction(end, FRAME_RATE))}
            for file, (start, end) in zip((self.source, alias), CLIPS)
        ]
        self.run_export(request={"clips": clips, "space_clips": "source"})
        self.assert_rendered(20)
        self.output.unlink()

        clips[1]["file"] = alias.name
        project = self.output.with_name("original.cut")
        project.write_text(json.dumps({
            "format": "mpcut", "schema_version": 3, "kind": "sequence",
            "clips": [dict(clip, id=f"clip-{index}") for index, clip in enumerate(clips)],
        }))
        original = project.read_bytes()
        self.run_export("--project", project, "--space-clips", "source")
        self.assert_rendered(20)
        self.assertEqual(project.read_bytes(), original)

        spaced = project.with_name("spaced.cut")
        result = subprocess.run([CLI, "timeline", "clips", "space", "--project", project, "--source-timing",
                                 "--out-project", spaced, "--json"],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        gap, = report["assets"]
        self.assertEqual(gap["kind"], "gap")
        self.assertFalse(gap["offline"])
        self.assertNotIn("file", gap)

    def test_omitting_spacing_joins_the_same_clips(self):
        result = self.export()
        self.assertEqual(ratio(result["duration"]), Fraction(4, 5))
        self.assert_rendered(0)

    def test_single_clip_has_no_spacing_boundaries(self):
        for spacing in ("source", "2"):
            with self.subTest(spacing=spacing):
                clips = CLIPS[:1]
                result = self.export("--space-clips", spacing, clips=clips)
                self.assertEqual(ratio(result["duration"]), Fraction(2, 5))
                self.assert_rendered(0, clips=clips)
                self.output.unlink()

    def test_source_spacing_requires_copy_safe_camera_return(self):
        camera = self.output.with_name("long-gop.mp4")
        ffmpeg("-i", self.source, "-an", "-c:v", "libx264", "-profile:v", "high",
               "-pix_fmt", "yuv420p", "-g", str(FRAME_RATE), "-keyint_min", str(FRAME_RATE),
               "-sc_threshold", "0", "-bf", "0", camera)
        self.source = camera
        self.source_packets = dict(timestamped_hashes(camera))
        first = (0, 25)
        plan = self.export("--space-clips", "source", "--dry-run",
                           clips=(first, (51, 75)), succeeds=False)
        self.assertEqual(plan["error"]["code"], "camera_copy_required")
        alternatives = plan["error"]["alternatives"]
        self.assertTrue(alternatives)
        for alternative in alternatives:
            self.assertTrue("--require-camera-copy" in alternative["arguments"] or alternative["mode"] == "encode")
            self.output = self.output.with_suffix("." + alternative["container"])
            self.export("--space-clips", "source", "--dry-run", *alternative["arguments"], clips=(first, (51, 75)))
        self.output = self.output.with_suffix(".mov")
        safe = (first, (50, 75))
        self.export("--space-clips", "source", clips=safe)
        self.assert_rendered(25, clips=safe)

    def test_no_generated_gap_preserves_the_ordinary_camera_copy_policy(self):
        camera = self.output.with_name("long-gop.mp4")
        ffmpeg("-i", self.source, "-an", "-vf", "scale=256:144", "-c:v", "libx264", "-profile:v", "high",
               "-pix_fmt", "yuv420p", "-g", str(FRAME_RATE), "-sc_threshold", "0", "-bf", "0", camera)
        self.source = camera
        clips = ((1, 13), (13, 25))
        ordinary = self.export("--mode", "smart", "--dry-run", clips=clips)
        self.assertGreater(ratio(ordinary["encoded_duration"]), 0)
        for spacing in ("source", "0"):
            with self.subTest(spacing=spacing):
                spaced = self.export("--space-clips", spacing, "--mode", "smart", "--dry-run", clips=clips)
                self.assertEqual(spaced, ordinary)
                constrained = self.export("--space-clips", spacing, "--mode", "smart", "--dry-run",
                                          "--require-camera-copy", clips=clips, succeeds=False)
                self.assertEqual(constrained["error"]["code"], "camera_copy_required")

    def test_source_spacing_rejects_overlap_and_reverse_order(self):
        for clips in [((10, 30), (20, 40)), tuple(reversed(CLIPS))]:
            with self.subTest(clips=clips):
                report = self.export("--space-clips", "source", clips=clips, succeeds=False)
                self.assertEqual(report["error"]["code"], "invalid_still_project")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = str(args.mpcut.resolve(strict=True))
    unittest.main(argv=[__file__, *tests])
