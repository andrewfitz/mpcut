#!/usr/bin/env python3
"""Verify synchronized project JPEGs, source clocks, availability, and publication."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

from frames import ratio, rgb, run
from media_regression import audio
from saved_project import read_project


class MulticamFrames(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workspace = tempfile.TemporaryDirectory()
        cls.addClassCleanup(workspace.cleanup)
        cls.root = Path(workspace.name)
        cls.media = cls.root / "media"
        cls.media.mkdir()
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "color=red:s=160x96:r=4:d=3",
             "-c:v", "ffv1", cls.media / "wide.mkv"])
        # Two different pictures on a nonzero PTS clock. The first is held
        # through the sparse portion of the VFR stream.
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "color=blue:s=160x96:r=4:d=0.25[b];color=lime:s=160x96:r=4:d=0.25[g];"
             "[b][g]concat=n=2:v=1:a=0,settb=expr=1/4,setpts='if(eq(N,0),0,3)'",
             "-enc_time_base", "1:4", "-fps_mode", "passthrough", "-c:v", "ffv1", "-output_ts_offset", "2",
             cls.media / "close.mkv"])
        (cls.media / "bad.mov").write_bytes(b"Not a recording")
        cls.project = cls.root / "interview.cut"
        cls.project.write_text(json.dumps({
            "format": "mpcut", "schema_version": 3, "kind": "multicam", "reference_angle_id": "wide",
            "group_range": {"from": "0", "to": "3"},
            "angles": [
                {"id": "wide", "file": "media/wide.mkv", "offset": "0"},
                {"id": "close", "name": "Close", "file": "media/close.mkv", "offset": "1/2"},
                {"id": "lost", "file": "media/missing.mov", "offset": "0"},
                {"id": "damaged", "file": "media/bad.mov", "offset": "0"},
            ],
            "audio": {"mode": "follow"},
            "switches": [{"group_time": "0", "angle_id": "wide"}, {"group_time": "1", "angle_id": "close"}],
            "assembly": [{"from": "2", "to": "3"}],
        }))

    def cmd(self, dest, *options):
        return [CLI, "review", "frames", "export", "--json", "--project", self.project, "--output", dest, *options]

    def restart_project(self, name):
        restart = self.media / (name + ".mkv")
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "color=blue:s=160x96:r=4:d=1",
             "-c:v", "ffv1", restart])
        project = self.root / (name + ".cut")
        document = read_project(self.project)
        document["angles"] = [document["angles"][0]]
        document["angles"][0].update({
            "group_coverage": {"from": "0", "to": "1"},
            "additional_recordings": [{"id": "restart", "file": "media/" + restart.name, "offset": "2",
                                       "group_coverage": {"from": "2", "to": "3"}}],
        })
        document["switches"] = document["switches"][:1]
        document["audio"] = {"mode": "none"}
        project.write_text(json.dumps(document))
        return project, document

    def test_restart_frames_keep_the_angle_and_report_the_recording(self):
        project, _ = self.restart_project("restart-review")
        dest = self.root / "restart-frames"
        report = json.loads(run([CLI, "review", "frames", "export", "--json", "--project", project,
                                 "--output", dest, "--at", "1/2", "--at", "3/2", "--at", "5/2"]))
        self.assertEqual([angle["id"] for angle in report["angles"]], ["wide"])
        self.assertEqual(report["angles"][0]["additional_recordings"][0]["id"], "restart")
        rows = report["frames"]
        self.assertEqual([row["angle_id"] for row in rows], ["wide", "wide", "wide"])
        self.assertEqual([row["availability"] for row in rows], ["available", "picture_gap", "available"])
        self.assertEqual([row.get("recording_id") for row in rows], ["wide", None, "restart"])
        self.assertGreater(rgb(dest / rows[0]["file"])[0], 200)
        self.assertGreater(rgb(dest / rows[2]["file"])[2], 200)

    def test_assembly_frames_follow_output_time_and_fill_recording_gaps(self):
        project, document = self.restart_project("assembly-review")
        document["assembly"] = [{"from": "2", "to": "3"}, {"from": "0", "to": "2"}]
        project.write_text(json.dumps(document))
        dest = self.root / "assembly-frames"
        report = json.loads(run([CLI, "review", "frames", "export", "--json", "--project", project,
                                 "--clock", "assembly", "--output", dest, "--at", "0", "--at", "5/2",
                                 "--at", "3", "--at", "1/10", "--at", "3/2"]))
        self.assertEqual(report, json.loads((dest / "manifest.json").read_text()))
        self.assertEqual(report["clock"], "assembly")
        rows = report["frames"]
        self.assertEqual([row.get("source") for row in rows], ["restart", None, None, "restart", "wide"])
        self.assertEqual([row.get("generated_gap", False) for row in rows], [False, True, True, False, False])
        files = [dest / row["file"] for row in rows]
        self.assertGreater(rgb(files[0])[2], 200)
        self.assertLess(max(rgb(files[1])), 10)
        self.assertGreater(rgb(files[4])[0], 200)
        self.assertEqual(files[0].read_bytes(), files[3].read_bytes())
        self.assertEqual(files[1].read_bytes(), files[2].read_bytes())

    def test_png_and_tiff_cover_the_group_and_assembly_clocks(self):
        project, document = self.restart_project("lossless-review")
        document["assembly"] = [{"from": "2", "to": "3"}, {"from": "0", "to": "2"}]
        project.write_text(json.dumps(document))
        dest = self.root / "lossless-group"
        report = json.loads(run([CLI, "review", "frames", "export", "--json", "--project", project,
                                 "--format", "png", "--output", dest, "--at", "1/2", "--at", "5/2"]))
        self.assertEqual(report["format"], "png")
        self.assertEqual([row["file"] for row in report["frames"]],
                         ["frame-000001-angle-001.png", "frame-000002-angle-001.png"])
        for row, channel in zip(report["frames"], (0, 2), strict=True):
            self.assertEqual((dest / row["file"]).read_bytes()[:4], b"\x89PNG")
            self.assertGreater(rgb(dest / row["file"])[channel], 200)
        # The assembly clock mixes camera pictures with a generated gap picture.
        dest = self.root / "lossless-assembly"
        report = json.loads(run([CLI, "review", "frames", "export", "--json", "--project", project,
                                 "--clock", "assembly", "--format", "tiff", "--output", dest,
                                 "--at", "0", "--at", "5/2", "--at", "3/2"]))
        self.assertEqual(report["format"], "tiff")
        rows = report["frames"]
        self.assertEqual([row.get("generated_gap", False) for row in rows], [False, True, False])
        self.assertEqual([row["file"] for row in rows], [f"frame-00000{n}.tiff" for n in (1, 2, 3)])
        for row in rows:
            self.assertIn((dest / row["file"]).read_bytes()[:4], (b"II*\x00", b"MM\x00*"))
        self.assertGreater(rgb(dest / rows[0]["file"])[2], 200)
        self.assertLess(max(rgb(dest / rows[1]["file"])), 10)
        self.assertGreater(rgb(dest / rows[2]["file"])[0], 200)

    def test_project_edit_adds_recording_without_adding_camera(self):
        restart = self.media / "authored-restart.mkv"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "color=blue:s=160x96:r=4:d=1",
             "-c:v", "ffv1", restart])
        original = self.root / "authoring.cut"
        document = read_project(self.project)
        document["angles"] = document["angles"][:1]
        document["switches"] = document["switches"][:1]
        original.write_text(json.dumps(document))
        project = self.root / "authored.cut"
        request = self.root / "add-recording.json"
        request.write_text(json.dumps({
            "project_path": str(original), "out_project": str(project),
            "operations": [{"action": "add_recording", "angle_id": "wide",
                            "path": str(restart), "group_start": "4"}],
        }))
        run([CLI, "project", "edit", "--input", request, "--json"])
        authored = read_project(project)
        self.assertEqual([angle["id"] for angle in authored["angles"]], ["wide"])
        self.assertEqual(authored["switches"], document["switches"])
        self.assertEqual(authored["group_range"]["to"], "5")
        primary = authored["angles"][0]
        self.assertEqual(primary["group_coverage"], {"from": "0", "to": "3"})
        self.assertEqual(primary["additional_recordings"][0]["group_coverage"], {"from": "4", "to": "5"})

    def test_restart_movie_fills_gap_with_black_and_keeps_fixed_sound(self):
        project, document = self.restart_project("restart-render")
        mic = self.media / "restart-microphone.mov"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "sine=d=3:r=48000",
             "-c:a", "pcm_s16le", mic])
        document["audio_sources"] = [{"id": "mic", "file": "media/restart-microphone.mov"}]
        document["audio"] = {"mode": "fixed", "source_id": "mic", "audio_stream_index": 0}
        document.pop("assembly")
        project.write_text(json.dumps(document))
        movie = self.root / "restart.mov"
        command = [CLI, "export", "project", "render", "--json", "--project", project, "--output", movie]
        lossless = subprocess.run([*command, "--mode", "copy", "--dry-run"], capture_output=True, timeout=120)
        self.assertNotEqual(lossless.returncode, 0)
        issue = json.loads(lossless.stdout)["error"]
        self.assertEqual(issue["code"], "recording_gap_requires_encoding")
        self.assertTrue(any(offer["mode"] == "encode" for offer in issue["alternatives"]))
        result = json.loads(run([*command, "--mode", "encode"]))
        self.assertEqual(ratio(result["duration"]), 3)
        gaps = result["generated_picture_gaps"]
        self.assertEqual([(Fraction(gap["from"]), Fraction(gap["to"])) for gap in gaps], [(1, 2)])
        self.assertEqual(audio(movie), audio(mic))
        for time, channel in [("0.5", 0), ("1.5", None), ("2.5", 2)]:
            pixel = run(["ffmpeg", "-loglevel", "error", "-ss", time, "-i", movie, "-vf",
                         "format=rgb24,crop=1:1:iw*0.5:ih*0.5", "-frames:v", "1",
                         "-c:v", "rawvideo", "-f", "rawvideo", "-"])
            self.assertEqual(len(pixel), 3)
            if channel is None:
                self.assertLess(max(pixel), 8)
            else:
                self.assertGreater(pixel[channel], 200)

    def test_restart_movie_generates_silence_when_camera_audio_follows(self):
        project, document = self.restart_project("restart-follow")
        sources = []
        camera = document["angles"][0]
        for number, (recording, color) in enumerate(zip([camera, *camera["additional_recordings"]], ["red", "blue"])):
            source = self.media / f"follow-{number}.mov"
            run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", f"color={color}:s=160x96:r=4:d=1",
                 "-f", "lavfi", "-i", f"sine=f={440 + number * 220}:d=1:r=48000",
                 "-c:v", "libx264", "-c:a", "pcm_s16le", source])
            recording["file"] = "media/" + source.name
            recording["audio_stream_index"] = 1
            sources.append(source)
        document["audio"] = {"mode": "follow"}
        document.pop("assembly")
        project.write_text(json.dumps(document))
        movie = self.root / "restart-follow-output.mov"
        run([CLI, "export", "project", "render", "--json", "--project", project, "--output", movie,
             "--mode", "encode", "--audio", "pcm"])
        self.assertEqual(audio(movie), audio(sources[0]) + bytes(48000 * 2) + audio(sources[1]))

    def test_aligned_requests_and_unavailable_angles(self):
        dest = self.root / "angles"
        requests = ["9/8", "0", "5/4", "3/2", "9/8"]
        flags = [flag for stamp in requests for flag in ("--at", stamp)]
        report = json.loads(run(self.cmd(dest, *flags)))
        self.assertEqual(json.loads((dest / "manifest.json").read_bytes()), report)
        angles = report["angles"]
        self.assertEqual([angle["id"] for angle in angles], ["wide", "close", "lost", "damaged"])
        self.assertEqual(angles[1]["file"], str(self.media / "close.mkv"))
        self.assertEqual(ratio(angles[1]["origin"]), 2)
        self.assertEqual(angles[2]["error"]["code"], "missing_source")
        self.assertEqual(angles[3]["error"]["code"], "probe_failed")
        rows = report["frames"]
        self.assertEqual([(r["request_number"], ratio(r["group_time"]), r["angle_id"]) for r in rows],
                         [(i, Fraction(t), angle["id"])
                          for i, t in enumerate(requests, 1) for angle in angles])
        self.assertEqual([r["availability"] for r in rows[1::4]],
                         ["available", "before_source", "available", "after_source", "available"])
        self.assertEqual([ratio(r["source_time"]) for r in rows[1::4]],
                         [Fraction(t) - Fraction(1, 2) for t in requests])
        self.assertTrue(all(r["availability"] == "missing_source" for r in rows[2::4]))
        self.assertTrue(all(r["availability"] == "source_error" for r in rows[3::4]))
        self.assertEqual(sorted(p.name for p in dest.glob("*.jpg")),
                         sorted(r["file"] for r in rows if r["availability"] == "available"))
        for row in rows:
            if row["availability"] != "available":
                self.assertTrue({"file", "frame_pts", "frame_time", "group_coverage"}.isdisjoint(row))
                continue
            path = dest / row["file"]
            self.assertEqual(path.read_bytes()[:2], b"\xff\xd8")
            coverage = row["group_coverage"]
            self.assertLessEqual(ratio(coverage["from"]), ratio(row["group_time"]))
            self.assertGreater(ratio(coverage["to"]), ratio(row["group_time"]))
            angle = angles[0 if row["angle_id"] == "wide" else 1]
            self.assertEqual(row["frame_pts"] * ratio(angle["time_base"]),
                             ratio(angle["origin"]) + ratio(row["frame_time"]))
        first, second, last = rows[1], rows[9], rows[17]
        self.assertEqual(ratio(first["frame_time"]), 0)
        self.assertEqual(ratio(second["frame_time"]), Fraction(3, 4))
        self.assertEqual((dest / first["file"]).read_bytes(), (dest / last["file"]).read_bytes())
        self.assertGreater(rgb(dest / rows[0]["file"])[0], 200)
        self.assertGreater(rgb(dest / first["file"])[2], 200)
        self.assertGreater(rgb(dest / second["file"])[1], 200)

    def test_group_bounds_option_errors_and_existing_folder(self):
        dest = self.root / "invalid"
        for flags, exit_status, code in [
            ([], 2, "invalid_arguments"),
            (["--at", "0", "--select", "scenes"], 2, "invalid_arguments"),
            (["--at", "0", self.media / "wide.mkv"], 2, "invalid_arguments"),
            (["--at", "-1/4"], 1, "invalid_range"),
            (["--at", "3"], 1, "invalid_range"),
        ]:
            with self.subTest(flags=flags):
                result = subprocess.run(self.cmd(dest, *flags), capture_output=True, timeout=120)
                self.assertEqual(result.returncode, exit_status, result.stdout)
                self.assertEqual(json.loads(result.stdout)["error"]["code"], code)
                self.assertFalse(dest.exists())
        dest.mkdir()
        marker = dest / "keep"
        marker.write_bytes(b"unchanged")
        result = subprocess.run(self.cmd(dest, "--at", "0"), capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "output_exists")
        self.assertEqual(list(dest.iterdir()), [marker])
        self.assertEqual(marker.read_bytes(), b"unchanged")

    def test_cancellation_removes_staged_jpegs(self):
        dest = self.root / "cancelled"
        with subprocess.Popen(self.cmd(dest, *(["--at", "1"] * 6000)),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline and process.poll() is None:
                    if next(self.root.glob(".mpcut-frames-*/*.jpg"), None) is not None:
                        process.send_signal(signal.SIGINT)
                        break
                    time.sleep(0.01)
                else:
                    self.fail("No staged JPEG observed before the process finished or timed out")
                stdout, _ = process.communicate(timeout=30)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(json.loads(stdout)["error"]["code"], "cancelled")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        self.assertFalse(dest.exists())
        self.assertFalse(list(self.root.glob(".mpcut-frames-*")))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
