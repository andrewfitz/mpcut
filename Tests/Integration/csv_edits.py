#!/usr/bin/env python3
"""Check CSV edits through the built CLI using frame and sample comparisons."""
import argparse
import errno
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import audio, ffmpeg, frames


class CSVEdits(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.folder = Path(scratch.name)
        self.movie = self.folder / "source.mov"
        self.csv = self.folder / "selects.csv"
        self.output = self.folder / "output.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=size=128x96:rate=24:duration=1",
               "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=2",
               "-c:v", "prores_ks", "-c:a", "pcm_s16le", self.movie)

    def export(self, *args, status=0):
        result = subprocess.run([CLI, "export", "--json", "--no-sidecar", "--output",
                                 self.output, *map(str, args)], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def command(self, *args, ok=True):
        result = subprocess.run([CLI, "--json", *map(str, args), "--no-sidecar"],
                                capture_output=True, text=True, timeout=60, cwd=self.folder)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_range_files_across_commands(self):
        bulk = self.folder / "clips"
        bulk.mkdir()
        self.csv.write_text("from,to\n0.5,1\n0,0.25\n0.5,1")
        playlist = self.folder / "ranges.json"
        playlist.write_text(json.dumps([{"from": start, "to": end} for start, end in [(0.5, 1), (0, 0.25), (0.5, 1)]]))
        for path in (self.csv, playlist):
            args = ["--output", self.output, "--tracks", "video", "--dry-run"]
            joined = self.command("rearrange", self.movie, path, *args)
            exported = self.command("export", "--clip", self.movie, "--ranges", path, *args)
            self.assertEqual(joined["segments"], exported["segments"])
            separate = self.command("bulk", self.movie, "--ranges", path, "--tracks", "video",
                                    "--output", bulk, "--dry-run")
            self.assertEqual(len(separate["outputs"]), 3)
        playlist.write_text('[0.25,"1/2"]')
        self.assertEqual(len(self.command("bulk", self.movie, "--ranges", playlist, "--tracks", "video",
                                          "--output", bulk, "--dry-run")["outputs"]), 3)

    def test_batch_organization(self):
        self.csv.write_text("from,to\n0,0.25\n0.5,1")
        args = ["bulk", self.movie, "--ranges", self.csv, "--output", self.folder,
                "--container", "mov", "--tracks", "video", "--base-name", "Interview"]
        folder = self.folder / "Review 2"
        expected = [folder.resolve() / "Interview-001.mov", folder.resolve() / "Interview-002.mov"]
        plan = self.command(*args, "--subfolder", folder.name, "--dry-run")
        self.assertEqual([Path(row["output"]).resolve() for row in plan["outputs"]], expected)
        self.assertFalse(folder.exists())
        request = self.folder / "batch.json"
        request.write_text(json.dumps({"file": self.movie.name, "outputDirectory": str(self.folder),
                                       "subfolder": folder.name, "baseName": "Interview", "container": "mov",
                                       "tracks": "video", "ranges": [{"from": "0", "to": "0.25"}]}))
        row = self.command("bulk", "--input", request, "--dry-run")["outputs"][0]
        self.assertEqual(Path(row["output"]).resolve(), expected[0])
        self.command("bulk", "--input", request, "--base-name", "Different", "--dry-run", ok=False)
        scenes = self.folder / "scenes.csv"
        scenes.write_text("start,end,view\n0,0.25,1")
        scene = self.command("scenes", self.movie, "--scenes-file", scenes, "--export-to", self.folder,
                             "--tracks", "video", "--container", "mov", "--subfolder", folder.name,
                             "--base-name", "Interview", "--dry-run")["outputs"][0]
        scene_path = Path(scene["export"]["output"])
        self.assertEqual(scene_path.parent.resolve(), folder.resolve())
        self.assertEqual(scene_path.name, f"Interview-scene-001-{scene['viewLabel']}.mov")
        self.assertFalse(folder.exists())
        for invalid in ["../escape", "a/b", "."]:
            self.command(*args, "--subfolder", invalid, "--dry-run", ok=False)
        folder.symlink_to(self.folder, target_is_directory=True)
        self.command(*args, "--subfolder", folder.name, "--dry-run", ok=False)
        folder.unlink()
        self.command(*args, "--subfolder", folder.name)
        self.assertTrue(all(path.is_file() for path in expected))
        expected[0].unlink()
        self.command(*args, "--subfolder", folder.name, ok=False)
        self.assertFalse(expected[0].exists())

    def test_unicode_batch_filename(self):
        self.csv.write_text("from,to\n0,0.25")
        stem = "映" * 90
        parent_file = self.folder / (stem + "-001.mov")
        try:
            parent_file.touch()
        except OSError as error:
            if error.errno == errno.ENAMETOOLONG:
                self.skipTest("Destination filesystem limits UTF-8 filename bytes")
            raise
        args = ["bulk", self.movie, "--ranges", self.csv, "--output", self.folder,
                "--tracks", "video", "--container", "mov"]
        child = self.folder / "Review"
        self.command(*args, "--subfolder", child.name, "--base-name", "a" * 256, "--dry-run", ok=False)
        self.command(*args, "--subfolder", child.name, "--base-name", stem, "--dry-run")
        self.assertFalse(child.exists())
        self.command(*args, "--subfolder", child.name, "--base-name", stem)
        self.assertTrue((child / parent_file.name).is_file())
        self.assertEqual(parent_file.stat().st_size, 0)
        parent_file.unlink()
        self.command(*args, "--base-name", stem)
        self.assertGreater(parent_file.stat().st_size, 0)

    def test_clip_and_order_files(self):
        source = self.movie.rename(self.folder / 'talk, "one".mov')
        self.csv.write_text('file,from,to\n"talk, ""one"".mov",0,0.25\n"talk, ""one"".mov",0.5,1')
        order = self.folder / "order.json"
        order.write_text("[2,1,2]")
        self.command("export", "--clips", self.csv, "--order-file", order,
                     "--tracks", "video", "--output", self.output)
        source_frames = frames(source)
        self.assertEqual(frames(self.output), source_frames[12:] + source_frames[:6] + source_frames[12:])
        clips = self.folder / "clips.json"
        clips.write_text(json.dumps([source.name]))
        order_csv = self.folder / "order.csv"
        order_csv.write_text("order\n1\n1")
        self.assertEqual(self.command("export", "--clips", clips, "--order", order_csv, "--dry-run",
                                      "--tracks", "video", "--output", "next.mov")["order"], [1, 1])

    def test_frame_times_and_section_files(self):
        for ext, times, sections in [("csv", "time\n0\n1/2", "section\nindex"),
                                     ("json", '[0,"1/2"]', '["index"]')]:
            path = self.folder / ("list." + ext)
            path.write_text(times)
            report = self.command("frames", self.movie, "--at-file", path, "--output", "frames-" + ext)
            self.assertEqual(len(report["frames"]), 2)
            path.write_text(sections)
            self.assertTrue(self.command("sidecar", self.movie, "--only-file", path)["ok"])

    def test_reports_and_stdin_request_files(self):
        report = self.folder / "request.json"
        report.write_text(json.dumps({"file": self.movie.name, "outputDirectory": str(self.folder),
                                      "ranges": [{"from":"0","to":"1/2"}]}))
        self.assertEqual(len(self.command("bulk", "--input", report, "--dry-run")["outputs"]), 1)
        report.write_text(json.dumps({"output":"take.mov", "clips":[{"file":self.movie.name}]}))
        self.assertTrue(self.command("export", "--input", report, "--dry-run")["ok"])
        report.write_text(json.dumps({"output": "request.fcpxml", "clips": [{"file": self.movie.name}]}))
        self.assertTrue(self.command("resolve", "--input", report)["ok"])
        self.csv.write_text("file\n" + self.movie.name)
        self.assertTrue(self.command("resolve", "--clips", self.csv, "--output", "clips.fcpxml")["ok"])
        self.csv.write_text("start,end,view\n0,0.25,1")
        self.assertEqual(len(self.command("scenes", self.movie, "--scenes-file", self.csv, "--export-to",
                                          self.folder, "--tracks", "video", "--dry-run")["outputs"]), 1)
        report.write_text(json.dumps(self.command("scenes", self.movie)))
        self.assertTrue(self.command("scenes", "--input", report, "--export-to", self.folder,
                                     "--tracks", "video", "--dry-run")["ok"])
        report.write_text(json.dumps(self.command("silence", self.movie)))
        self.csv.write_text("from,to\n0.25,0.5")
        saved = self.command("silence", "--input", report, "--pauses-file", self.csv)["pauses"]
        self.assertEqual(len(saved), 1)
        self.assertEqual(self.command("silence", self.movie, "--pauses-file", self.csv)["pauses"], saved)

    def test_invalid_lists_leave_no_output(self):
        self.csv.write_text('file,from,to\n"missing,0,1')
        self.command("export", "--clips", self.csv, "--output", self.output, ok=False)
        self.assertFalse(self.output.exists())
        path = self.folder / "ranges.json"
        path.write_text('[{"from":"0","from":"0.5","to":"1"}]')
        self.command("rearrange", self.movie, "--ranges", path, "--output", self.output, ok=False)
        self.assertFalse(self.output.exists())

    def test_repeated_order_entries_repeat_the_entire_csv(self):
        self.csv.write_text("0.5,1\n0,0.25")
        self.export("--clip", self.movie, "--csv", self.csv, "--tracks", "video", "--order", "1,1")
        original = frames(self.movie)
        self.assertEqual(frames(self.output), (original[12:24] + original[:6]) * 2)

    def test_bad_second_row_reports_original_clip_after_expansion(self):
        self.csv.write_text("0,0.25\n0.42,0.5")
        error = self.export("--clip", self.movie, "--clip", self.movie, "--csv", self.csv,
                            "--order", "2,1", "--tracks", "video", "--mode", "copy", status=1)["error"]
        self.assertEqual(error["segment"], 2)
        self.assertEqual(error["boundary"], "from")
        self.assertFalse(self.output.exists())

    def test_pause_override_requires_intervals(self):
        for name, text in [("points.csv", "time\n0.25\n0.5"), ("points.json", "[0.25,0.5]")]:
            path = self.folder / name
            path.write_text(text)
            report = self.command("silence", self.movie, "--pauses-file", path,
                                  "--leave", "0", "--output", self.output, ok=False)
            self.assertIn("error", report)
            self.assertFalse(self.output.exists())

    def test_resolve_rejects_misplaced_and_duplicate_open(self):
        self.csv.write_text("file\n" + self.movie.name)
        for args in [("--clips", "--open", self.csv), ("--clips", self.csv, "--open", "--open")]:
            output = self.folder / "invalid.fcpxml"
            result = self.command("resolve", *args, "--output", output, ok=False)
            self.assertEqual(result["error"]["code"], "invalid_arguments")
            self.assertFalse(output.exists())

    def test_audio_conversion_retains_tail_after_last_picture(self):
        self.output = self.folder / "tail.wav"
        self.csv.write_text("1.5,2")
        self.export("--clip", self.movie, "--csv", self.csv, "--mode", "encode",
                    "--tracks", "audio", "--audio", "pcm")
        self.assertEqual(audio(self.output), audio(self.movie)[144000:192000])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    CLI = parser.parse_args().mpcut.resolve()
    unittest.main(argv=[__file__])
