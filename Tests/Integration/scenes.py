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
                        "-pix_fmt", "yuv420p", "-g", "100", "-sc_threshold", "0", cls.source], check=True)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name)

    def cli(self, *options, request=None, exit_code=0):
        result = subprocess.run([CLI, "scenes", "--json", *options],
                                input=json.dumps(request) if request is not None else None,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def frame_count(self, output):
        report = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                                          "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", output])
        return int(report)

    def test_detection_report_labels_exact_ranges_without_writing_video(self):
        report = self.cli(self.source)
        self.assertTrue(report["ok"])
        self.assertEqual(time(report["duration"]), Fraction(41, 25))
        self.assertEqual(report["viewCount"], 2)
        self.assertEqual(report["views"], [
            {"view": 1, "label": "A", "sceneNumbers": [1, 3]},
            {"view": 2, "label": "B", "sceneNumbers": [2]},
        ])
        self.assertEqual([scene["number"] for scene in report["scenes"]], [1, 2, 3])
        self.assertEqual([scene["viewLabel"] for scene in report["scenes"]], ["A", "B", "A"])
        self.assertEqual([time(scene["start"]) for scene in report["scenes"]],
                         [0, Fraction(11, 25), Fraction(24, 25)])
        self.assertEqual([time(scene["end"]) for scene in report["scenes"]],
                         [Fraction(11, 25), Fraction(24, 25), Fraction(41, 25)])
        self.assertEqual(list(self.source.parent.iterdir()), [self.source])

    def test_scene_files_match_chronology_and_frame_counts(self):
        report = self.cli("--export-to", self.output, self.source)
        self.assertEqual(report["groupBy"], "scene")
        outputs = report["outputs"]
        self.assertEqual([item["sceneNumbers"] for item in outputs], [[1], [2], [3]])
        self.assertEqual([Path(item["export"]["output"]).name for item in outputs],
                         ["Montage-scene-001-A.mp4", "Montage-scene-002-B.mp4", "Montage-scene-003-A.mp4"])
        self.assertEqual([self.frame_count(item["export"]["output"]) for item in outputs], [11, 13, 17])

    def test_saved_report_joins_each_view_in_source_order(self):
        detection = self.cli(self.source)
        flags = ("--stdin", "--group-by", "view", "--export-to", self.output)
        plan = self.cli(*flags, "--dry-run", request=detection)
        self.assertEqual([item["sceneNumbers"] for item in plan["outputs"]], [[1, 3], [2]])
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

    def test_saved_report_rejects_stale_source_and_overlapping_ranges(self):
        detection = self.cli(self.source)
        flags = ("--stdin", "--export-to", self.output)
        stale = {**detection, "sourceStamp": {**detection["sourceStamp"], "bytes": 1}}
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
