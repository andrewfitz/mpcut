#!/usr/bin/env python3
"""Verify burned-in camera feed scan and extraction with a generated 2x2 video.

Run with python3 Tests/Integration/participant_feeds.py path/to/mpcut.
FFmpeg and ffprobe must be on PATH. An unbundled CLI also needs
MPCUT_FFMPEG_HELPER set to the application's FFmpeg helper.
"""

import argparse
from fractions import Fraction
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import participant_e2e as participant
from media_regression import ffmpeg
from participant_e2e import ParticipantFixtureCase, interval, plan, rational, slot
from participant_e2e_fixture import FPS, PRORES, pixel, video

CELL_SIZE = (160, 96)
FRAME_COUNT = 4 * FPS
COLORS = ((208, 49, 42), (32, 178, 83), (40, 111, 190), (214, 156, 29))
DETAIL = (224, 231, 197)
SAMPLE_POINTS = ((20, 20), (80, 48), (140, 76))


def generate_grid(path, *, margin=0, gutter=0, blank_feed=False):
    cell_width, cell_height = CELL_SIZE
    width, height = (2 * side + 2 * margin + gutter for side in CELL_SIZE)
    regions = [(margin + column * (cell_width + gutter), margin + row * (cell_height + gutter),
                cell_width, cell_height) for row in range(2) for column in range(2)]

    def frame(index):
        picture = bytearray(3 * width * height)

        def paint(x, y, w, h, color):
            row = bytes(color) * w
            for line in range(y, y + h):
                start = 3 * (line * width + x)
                picture[start:start + len(row)] = row

        for cell, (x, y, w, h) in enumerate(regions):
            if blank_feed and cell == 1 and 2 * FPS <= index < 3 * FPS:
                continue
            # Cut to entirely different imagery in each slot, including a
            # swap of upper-left and upper-right colors.
            color = COLORS[cell if index < FPS else cell ^ 1]
            paint(x, y, w, h, color)
            paint(x + 8 + index % FPS, y + 8, 28, 26, DETAIL)
        return picture

    ffmpeg("-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{width}x{height}",
           "-framerate", str(FPS), "-i", "-", *PRORES, path,
           input=b"".join(frame(index) for index in range(FRAME_COUNT)))
    return (width, height), regions


class ParticipantFeeds(ParticipantFixtureCase):
    @classmethod
    def setUpClass(cls):
        workspace = tempfile.TemporaryDirectory(prefix="mpcut-feeds-")
        cls.addClassCleanup(workspace.cleanup)
        cls.root = Path(workspace.name)
        cls.feeds = cls.root / "feeds.mov"
        cls.size, cls.regions = generate_grid(cls.feeds, blank_feed=True)
        cls.guttered = cls.root / "guttered.mov"
        cls.guttered_size, cls.guttered_regions = generate_grid(cls.guttered, margin=4, gutter=8)

    def test_scan_progress_percentages(self):
        result = subprocess.run([str(participant.CLI), "participants", "scan", "--file", str(self.feeds),
                                 "--backend", "cpu-only", "--feed-layout", "auto", "--progress", "jsonl",
                                 "--no-sidecar", "--json"], text=True, capture_output=True, timeout=90, check=True)
        self.assertEqual(json.loads(result.stdout)["state"], "completed")
        events = [json.loads(line) for line in result.stderr.splitlines() if line.startswith("{")]
        self.assertTrue(all(event["event"] == "progress" for event in events))
        fractions = [event["fraction"] for event in events]
        self.assertEqual([event["percent"] for event in events], [round(fraction * 100) for fraction in fractions])
        self.assertEqual((events[0]["phase"], fractions[0]), ("preparing", 0))
        self.assertEqual((events[-1]["phase"], fractions[-1]), ("completed", 1))
        self.assertEqual(fractions, sorted(fractions))
        self.assertTrue(any(0 < event["fraction"] < 1 for event in events if event["phase"] == "scanning"))
        self.assertTrue(all(value < 1 for value in fractions[:-1]))
        self.assertEqual(events[-2]["phase"], "writing_result")

    def test_scan_report_write_failure_does_not_report_completion(self):
        missing_parent = self.folder / "missing-directory" / "scan.json"
        result = subprocess.run([str(participant.CLI), "participants", "scan", "--file", str(self.feeds),
                                 "--backend", "cpu-only", "--feed-layout", "2x2", "--progress", "jsonl",
                                 "--output", str(missing_parent), "--no-sidecar", "--json"],
                                text=True, capture_output=True, timeout=90)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "participant_analysis_write_failed")
        events = [json.loads(line) for line in result.stderr.splitlines() if line.startswith("{")]
        self.assertEqual(events[-1]["phase"], "failed")
        self.assertTrue(all(event["percent"] < 100 for event in events))
        self.assertFalse(missing_parent.exists())

    def scan(self, path, layout=None, *, cache=False):
        args = ["participants", "scan", "--file", str(path), "--backend", "cpu-only",
                "--sampling", "every-frame", "--json"]
        if layout is not None:
            args.extend(("--feed-layout", layout))
        if not cache:
            args.append("--no-sidecar")
        result = subprocess.run([str(participant.CLI), *args], text=True, capture_output=True, timeout=180)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def assert_grid(self, scan, size, regions, tolerance, *, tracks_follow_content=False):
        self.assertEqual(scan["state"], "completed", scan)
        analysis = scan["analysis"]
        observations = analysis["observations"]
        self.assertEqual([rational(item["timestamp"]) for item in observations],
                         [Fraction(index, FPS) for index in range(FRAME_COUNT)])
        initial_regions = observations[0]["regions"]
        track_ids = [region["participant_id"] for region in initial_regions]
        initial_geometry = [region["rect"] for region in initial_regions]
        self.assertEqual(len(track_ids), 4)
        self.assertEqual(len(set(track_ids)), 4)
        self.assertEqual({track["id"] for track in analysis["tracks"]}, set(track_ids))
        for index, observation in enumerate(observations):
            with self.subTest(frame=index):
                detected = observation["regions"]
                expected_ids = track_ids
                if tracks_follow_content and index >= FPS:
                    expected_ids = [track_ids[cell ^ 1] for cell in range(4)]
                self.assertEqual([region["participant_id"] for region in detected], expected_ids)
                self.assertEqual([region["rect"] for region in detected], initial_geometry)
                self.assertEqual([region["kind"] for region in detected], ["video"] * 4)
                self.assertFalse(any(region["identity_uncertain"] for region in detected))
                for region, expected in zip(detected, regions, strict=True):
                    rect = region["rect"]
                    for field, scale, pixels in zip(("x", "y", "width", "height"), size * 2, expected):
                        self.assertAlmostEqual(rect[field] * scale, pixels, delta=tolerance,
                                               msg=f"Feed {region['participant_id']} {field} at frame {index}")

    def accept_feeds(self, path, scan):
        project = self.folder / "source.cut"
        project.write_text(json.dumps({
            "format": "mpcut", "schema_version": 9, "kind": "multicam",
            "reference_angle_id": "burned-in", "group_range": interval(0, 4),
            "angles": [{"id": "burned-in", "file": str(path)}],
            "audio": {"mode": "none"}, "switches": [{"group_time": "0", "angle_id": "burned-in"}],
        }))
        report = self.folder / "scan.json"
        report.write_text(json.dumps(scan))
        approved = self.folder / "approved.cut"
        self.cli("participants", "project", "accept", request={
            "project_path": str(project), "source_id": "burned-in",
            "analysis_file": str(report), "out_project": str(approved),
        })
        return approved

    def assert_feed_export(self, path, size, regions, scan, *, tracks_follow_content=False):
        project = self.accept_feeds(path, scan)
        accepted = self.cli("participants", "project", "inspect", request={"project_path": str(project)})
        source, = accepted["sources"]
        self.assertEqual(source["analysis_identity"], scan["analysis_identity"])
        selected = [item for item in source["appearances"]
                    if rational(item["range"]["from"]) == 0
                    and item["bounds"]["x"] >= 0.5 and item["bounds"]["y"] < 0.1]
        appearance, = selected
        feed_id = appearance["participant_id"]
        self.assertEqual(len(accepted["people"]), 4)
        self.assertTrue(all(person["name"].startswith("Feed ") for person in accepted["people"]))
        self.assertIn(feed_id, {person["id"] for person in accepted["people"]})

        output, result = self.export(project, "upper-right", plan("solo", slot(feed_id), size=CELL_SIZE))
        self.assertTrue(result["publishable"])
        frames = self.decode(output, size=CELL_SIZE, frame_count=FRAME_COUNT)
        _, source_frames = video(path)
        for index, (source_frame, frame) in enumerate(zip(source_frames, frames, strict=True)):
            cell = 0 if tracks_follow_content and index >= FPS else 1
            cell_x, cell_y, _, _ = regions[cell]
            for x, y in SAMPLE_POINTS:
                expected = pixel(source_frame, size[0], cell_x + x, cell_y + y)
                self.assert_color(frame, CELL_SIZE[0], x, y, expected, f"selected feed frame {index}")
            if not tracks_follow_content and 2 * FPS <= index < 3 * FPS:
                self.assertLessEqual(max(frame), 16, f"Black feed was covered at frame {index}")

    def test_fixed_grid_retains_feed_through_cut_and_black_and_exports_source_pixels(self):
        scan = self.scan(self.feeds, "2x2")
        self.assertEqual(scan["configuration"]["feed_layout"], "2x2")
        self.assert_grid(scan, self.size, self.regions, tolerance=0.01)
        self.assertFalse(self.feeds.with_suffix(".mov.cutcache").exists())
        self.assert_feed_export(self.feeds, self.size, self.regions, scan)

    def test_auto_detects_guttered_grid_and_exports_feed_through_slot_swap(self):
        scan = self.scan(self.guttered, "auto")
        self.assertEqual(scan["configuration"]["feed_layout"], "auto")
        self.assert_grid(scan, self.guttered_size, self.guttered_regions, tolerance=4, tracks_follow_content=True)
        self.assert_feed_export(self.guttered, self.guttered_size, self.guttered_regions, scan, tracks_follow_content=True)

    def test_feed_and_meeting_scans_have_independent_caches(self):
        recording = self.folder / self.feeds.name
        shutil.copyfile(self.feeds, recording)
        meeting = self.scan(recording, cache=True)
        feed = self.scan(recording, "2x2", cache=True)
        self.assertEqual(meeting["state"], "completed")
        self.assertEqual(feed["state"], "completed")
        self.assertNotEqual(meeting["analysis_identity"], feed["analysis_identity"])
        for layout, first in ((None, meeting), ("2x2", feed)):
            cached = self.scan(recording, layout, cache=True)
            self.assertEqual(cached["state"], "up_to_date")
            self.assertEqual(cached["analysis_identity"], first["analysis_identity"])
            self.assertEqual(cached["analysis"], first["analysis"])

        # Meeting reports written before feed selection have no feed_layout.
        meeting["configuration"].pop("feed_layout", None)
        self.accept_feeds(recording, meeting)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    options, tests = parser.parse_known_args()
    participant.CLI = options.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
