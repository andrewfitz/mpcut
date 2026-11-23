#!/usr/bin/env python3
"""Verify scene reports, replay, and exact Smart Trim exports."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


CLI = None


def time(value):
    return Fraction(value["numerator"], value["denominator"])


class Scenes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        cls.source = Path(temporary.name) / "Montage.mp4"
        graph = ("color=red:s=320x96:r=25:d=0.44[v0];color=blue:s=320x96:r=25:d=0.52[v1];"
                 "color=red:s=320x96:r=25:d=0.68[v2];[v0][v1][v2]concat=n=3:v=1:a=0")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", graph, "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", "-g", "100", "-sc_threshold", "0", cls.source], check=True, timeout=120)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name)

    def cli(self, *options, request=None, exit_code=0):
        action = "export" if "--export-to" in options else "scan"
        result = subprocess.run([CLI, "scenes", action, "--json", *options],
                                input=json.dumps(request) if request is not None else None,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def frame_count(self, output):
        report = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                                          "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", output],
                                         timeout=120)
        return int(report)

    def test_detection_report_labels_exact_ranges_without_writing_video(self):
        report = self.cli(self.source)
        self.assertTrue(report["ok"])
        self.assertEqual(time(report["duration"]), Fraction(41, 25))
        self.assertEqual(report["view_count"], 2)
        self.assertEqual(report["views"], [
            {"view": 1, "label": "A", "scene_numbers": [1, 3]},
            {"view": 2, "label": "B", "scene_numbers": [2]},
        ])
        self.assertEqual([scene["number"] for scene in report["scenes"]], [1, 2, 3])
        self.assertEqual([scene["view_label"] for scene in report["scenes"]], ["A", "B", "A"])
        self.assertEqual([time(scene["start"]) for scene in report["scenes"]],
                         [0, Fraction(11, 25), Fraction(24, 25)])
        self.assertEqual([time(scene["end"]) for scene in report["scenes"]],
                         [Fraction(11, 25), Fraction(24, 25), Fraction(41, 25)])
        self.assertEqual(set(self.source.parent.iterdir()), {self.source, Path(str(self.source) + ".cutdb")})

    def test_scene_files_match_chronology_and_frame_counts(self):
        report = self.cli("--export-to", self.output, self.source)
        self.assertEqual(report["group_by"], "scene")
        outputs = report["outputs"]
        self.assertEqual([item["scene_numbers"] for item in outputs], [[1], [2], [3]])
        self.assertEqual([Path(item["export"]["output"]).name for item in outputs],
                         ["Montage-scene-001-A.mp4", "Montage-scene-002-B.mp4", "Montage-scene-003-A.mp4"])
        self.assertEqual([self.frame_count(item["export"]["output"]) for item in outputs], [11, 13, 17])

    def test_flash_recovery_before_a_two_frame_insert(self):
        source = self.output / "flash-and-insert.mp4"
        angle_a = ("color=c=0x273d55:s=320x180:r=25,drawgrid=w=40:h=30:t=2:c=white@0.15,"
                   "drawbox=x=80:y=45:w=55:h=70:c=orange:t=fill")
        angle_b = ("color=c=0x5f3d29:s=320x180:r=25,drawgrid=w=54:h=36:t=2:c=white@0.15,"
                   "drawbox=x=176:y=62:w=51:h=58:c=tan:t=fill")
        # Both flashes return to the same picture. The second returns just
        # one frame before a genuine cut to B; neither flash should be a cut.
        graph = (f"{angle_a},drawbox=c=white:t=fill:enable='eq(n,8)+eq(n,23)',trim=end_frame=25[a];"
                 f"{angle_b},trim=end_frame=2[b];{angle_a},trim=end_frame=12[c];"
                 "[a][b][c]concat=n=3:v=1:a=0")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", graph, "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", "-g", "100", "-sc_threshold", "0", source], check=True, timeout=120)
        scenes = self.cli(source)["scenes"]
        self.assertEqual([(time(scene["start"]), scene["view_label"]) for scene in scenes],
                         [(0, "A"), (1, "B"), (Fraction(27, 25), "A")])

    def test_h264_mp4_preserves_cut_after_timestamp_gap(self):
        source = self.output / "irregular.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-i", self.source, "-vf",
                        "setpts='(N+if(gte(N,18),7,0))/(25*TB)'", "-fps_mode", "vfr",
                        "-c:v", "libx264", "-g", "100", "-sc_threshold", "0", source], check=True, timeout=120)
        scenes = self.cli(source)["scenes"]
        self.assertEqual([time(scene["start"]) for scene in scenes], [0, Fraction(11, 25), Fraction(31, 25)])
        self.assertEqual([scene["view_label"] for scene in scenes], ["A", "B", "A"])

    def test_software_decode_tracks_vfr_offset_and_last_frame_cut(self):
        source = self.output / "vfr-offset.mkv"
        # The gap starts at frame 18. A new shot begins on the final frame.
        filters = ("drawbox=c=white:t=fill:enable='eq(n,40)',"
                   "setpts='(N+if(gte(N,18),7,0))/(25*TB)'")
        subprocess.run(["ffmpeg", "-v", "error", "-i", self.source, "-vf", filters, "-fps_mode", "vfr",
                        "-c:v", "ffv1", "-pix_fmt", "yuv444p10le", "-output_ts_offset", "2", source],
                       check=True, timeout=120)
        report = self.cli(source)
        self.assertEqual(time(report["origin"]), 2)
        starts = [0, Fraction(11, 25), Fraction(31, 25), Fraction(47, 25)]
        self.assertEqual([time(scene["start"]) for scene in report["scenes"]], starts)
        self.assertEqual([scene["start_pts"] * time(report["time_base"]) for scene in report["scenes"]],
                         [start + 2 for start in starts])
        self.assertEqual([scene["view_label"] for scene in report["scenes"]], ["A", "B", "A", "C"])
        self.assertEqual(time(report["scenes"][-1]["end"]), Fraction(48, 25))

    def test_full_range_luma_cut_agrees_across_readers(self):
        raw = self.output / "full-range.yuv"
        width, height = 320, 180
        chroma = bytes([128]) * (width * height // 2)
        first = bytes([32]) * (width * height) + chroma
        second = bytes([56]) * (width * height) + chroma
        raw.write_bytes(9 * first + 9 * second + 9 * first)
        # The 24-code luma step crosses the 22-code cut threshold. Treating
        # these full-range samples as scaled video-range luma hides the cut.
        for codec, filename in [("libx264", "full-range.mp4"), ("mjpeg", "full-range.avi")]:
            with self.subTest(codec=codec):
                source = self.output / filename
                subprocess.run(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pixel_format", "yuv420p",
                                "-color_range", "pc", "-video_size", f"{width}x{height}", "-framerate", "25",
                                "-i", raw, "-c:v", codec, "-color_range", "pc", source], check=True, timeout=120)
                report = self.cli(source)
                self.assertEqual([time(scene["start"]) for scene in report["scenes"]],
                                 [0, Fraction(9, 25), Fraction(18, 25)])
                self.assertEqual([scene["view_label"] for scene in report["scenes"]], ["A", "A", "A"])
                self.assertEqual(time(report["scenes"][-1]["end"]), Fraction(27, 25))

    def test_saved_report_joins_each_view_in_source_order(self):
        detection = self.cli(self.source)
        flags = ("--stdin", "--group-by", "view", "--export-to", self.output)
        plan = self.cli(*flags, "--dry-run", request=detection)
        self.assertEqual([item["scene_numbers"] for item in plan["outputs"]], [[1, 3], [2]])
        self.assertEqual(list(self.output.iterdir()), [])
        existing = self.output / "Montage-view-002-B.mp4"
        existing.write_text("leave intact")
        self.assertEqual(self.cli(*flags, request=detection, exit_code=1)["error"]["code"], "output_exists")
        self.assertEqual(list(self.output.iterdir()), [existing])
        self.assertEqual(existing.read_text(), "leave intact")
        existing.unlink()
        report = self.cli(*flags, request=detection)
        outputs = report["outputs"]
        self.assertEqual([item["export"]["segments"] for item in outputs],
                         [item["export"]["segments"] for item in plan["outputs"]])
        self.assertEqual([time(segment["from"]) for segment in outputs[0]["export"]["segments"]],
                         [0, Fraction(24, 25)])
        self.assertEqual([self.frame_count(item["export"]["output"]) for item in outputs], [28, 13])

    def test_short_video_clock_with_longer_audio_and_no_track_duration_tags(self):
        source = self.output / "long-audio.mkv"
        subprocess.run(["ffmpeg", "-v", "error", "-i", self.source, "-f", "lavfi", "-i",
                        "anullsrc=r=48000:cl=mono:d=3", "-map", "0:v", "-map", "1:a", "-c:v", "copy",
                        "-c:a", "pcm_s16le", source], check=True, timeout=120)
        # Keep the Matroska segment duration (3 s) but remove the optional
        # per-track DURATION tags. The video presentation still ends at 1.64 s.
        data = source.read_bytes()
        self.assertIn(b"DURATION", data)
        source.write_bytes(data.replace(b"DURATION", b"UNTAGGED"))
        report = self.cli(source)
        self.assertEqual(time(report["duration"]), Fraction(41, 25))
        self.assertEqual(time(report["scenes"][-1]["end"]), Fraction(41, 25))
        self.assertEqual([time(scene["start"]) for scene in report["scenes"]],
                         [0, Fraction(11, 25), Fraction(24, 25)])

    def test_short_header_estimate_preserves_later_cuts(self):
        source = self.output / "short-tag.mkv"
        subprocess.run(["ffmpeg", "-v", "error", "-i", self.source, "-c", "copy", source], check=True, timeout=120)
        data = source.read_bytes()
        declared_end = b"00:00:01.640000000"
        self.assertEqual(data.count(declared_end), 1)
        source.write_bytes(data.replace(declared_end, b"00:00:00.400000000"))
        report = self.cli(source)
        self.assertEqual(time(report["duration"]), Fraction(41, 25))
        self.assertEqual([time(scene["start"]) for scene in report["scenes"]],
                         [0, Fraction(11, 25), Fraction(24, 25)])

    def test_saved_report_rejects_stale_source_and_overlapping_ranges(self):
        detection = self.cli(self.source)
        flags = ("--stdin", "--export-to", self.output)
        mixed = {**detection, "sourceStamp": detection["source_stamp"]}
        self.assertEqual(self.cli(*flags, request=mixed, exit_code=2)["error"]["code"], "invalid_json")
        stale = {**detection, "source_stamp": {**detection["source_stamp"], "bytes": 1}}
        self.assertEqual(self.cli(*flags, request=stale, exit_code=1)["error"]["code"], "source_changed")
        detection["scenes"][1]["start"] = detection["scenes"][0]["start"]
        self.assertEqual(self.cli(*flags, request=detection, exit_code=1)["error"]["code"], "invalid_range")
        self.assertEqual(list(self.output.iterdir()), [])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
