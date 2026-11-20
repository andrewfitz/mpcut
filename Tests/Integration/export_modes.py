#!/usr/bin/env python3
"""Check the CLI contract for copy, Smart Trim and hardware re-encode."""
import argparse
from fractions import Fraction
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import ratio


CLI = None
FIXTURE = Path(__file__).resolve().parents[1] / "MPCutAppTests/Fixtures/SmartTrim-GOP.mp4"


class ExportModes(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name) / "output.mp4"

    def export(self, *flags, start=None, request=None, dry_run=True, exit_code=0, env=None):
        command = [CLI, "export", "--json", *flags]
        if dry_run:
            command.append("--dry-run")
        if request is not None:
            command.append("--stdin")
        else:
            command.extend(["--output", str(self.output), "--clip", str(FIXTURE)])
            if start is not None:
                command.extend(["--from", start])
        result = subprocess.run(command, input=json.dumps(request) if request is not None else None,
                                text=True, capture_output=True, timeout=30, env=env)
        self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["ok"], exit_code == 0)
        if dry_run or exit_code:
            self.assertFalse(self.output.exists())
        return report

    def test_agent_can_discover_inspect_preflight_and_export_exact_frames(self):
        help_report = json.loads(subprocess.check_output([CLI, "help", "--json"]))
        self.assertEqual(set(help_report["exportModes"]), {"copy", "smart", "encode"})
        report = json.loads(subprocess.check_output([CLI, "inspect", "--json", "--frames",
                                                     "--from", "0.2", "--to", "0.4", FIXTURE]))
        frames = report["media"]["frames"]
        self.assertEqual([ratio(frame["time"]) for frame in frames], [Fraction(i, 25) for i in range(5, 10)])
        self.assertFalse(frames[0]["keyframe"])
        clips = [{"file": str(FIXTURE), "from": frames[2]["time"], "to": frames[4]["time"]},
                 {"file": str(FIXTURE), "from": frames[0]["time"], "to": frames[1]["time"]}]
        edit = {"mode": "smart", "snap": "exact", "clips": clips, "output": str(self.output)}
        self.assertEqual(self.export("--snap", "nearest", request=edit, exit_code=2)["error"]["code"],
                         "invalid_arguments")
        invalid = {**edit, "clips": [{**clips[0], "from": {"numerator": 1, "denominator": 0}}]}
        self.assertEqual(self.export(request=invalid, exit_code=2)["error"]["code"], "invalid_json")
        plan = self.export(request=edit)
        self.assertEqual(ratio(plan["duration"]), Fraction(3, 25))
        self.assertEqual([part["from"] for part in plan["segments"]], [clip["from"] for clip in clips])
        result = self.export(request=edit, dry_run=False)
        self.assertEqual(result["segments"], plan["segments"])
        self.assertTrue(self.output.is_file())

    def test_copy_remains_the_default(self):
        default = self.export()
        self.assertEqual(default, self.export("--mode", "copy"))
        self.assertEqual(default["mode"], "copy")
        self.assertEqual(ratio(default["encodedDuration"]), 0)
        self.assertEqual(ratio(default["copiedDuration"]), ratio(default["duration"]))
        self.assertEqual(default["segments"][0]["trackActions"][0]["action"], "copy")
        self.export(start="0.28", exit_code=1)

    def test_order_flags_and_json_validate_before_writing(self):
        request = {"output": str(self.output), "file": str(FIXTURE),
                   "clips": [{"from": "2/25", "to": "5/25"}, {"from": "14/25", "to": "19/25"}]}
        plan = self.export("--order", "2,1", request=request)
        self.assertEqual(plan, self.export(request={**request, "order": [2, 1]}))
        result = subprocess.run([CLI, "export", "--json", "--dry-run", "--order", "2,1", "--output", self.output,
                                 "--clip", FIXTURE, "--from", "2/25", "--to", "5/25",
                                 "--clip", FIXTURE, "--from", "14/25", "--to", "19/25"],
                                capture_output=True, text=True, check=True, timeout=30)
        self.assertEqual(plan, json.loads(result.stdout))
        self.assertEqual([ratio(part["from"]) for part in plan["segments"]], [Fraction(14, 25), Fraction(2, 25)])
        for bad in ([], [0], [3], [-1]):
            self.assertEqual(self.export(request={**request, "order": bad}, dry_run=False, exit_code=2)["error"]["code"],
                             "invalid_order")
        for bad in ([1.25], ["2"]):
            self.assertEqual(self.export(request={**request, "order": bad}, exit_code=2)["error"]["code"], "invalid_json")
        self.assertEqual(self.export("--order", "2,1", request={**request, "order": [1, 2]}, exit_code=2)["error"]["code"],
                         "invalid_arguments")
        self.assertEqual(self.export("--order", "2,,1", request=request, exit_code=2)["error"]["code"], "invalid_order")
        copy = {**request, "clips": [{}], "order": [1], "mode": "copy"}
        self.assertEqual(self.export(request=copy)["mode"], "copy")

    def test_rearrange_joins_clock_ranges_in_the_written_order(self):
        command = [CLI, "rearrange", "--json", FIXTURE, "--output", self.output]
        request = "00:01.361–00:01.559, 0:00.12-0:00.28"
        preflight = subprocess.run([*command, "--dry-run", request], capture_output=True, text=True,
                                   check=True, timeout=30)
        plan = json.loads(preflight.stdout)
        self.assertFalse(self.output.exists())
        self.assertEqual(plan["mode"], "smart")
        self.assertEqual([(ratio(item["from"]), ratio(item["to"])) for item in plan["segments"]],
                         [(Fraction(34, 25), Fraction(39, 25)), (Fraction(3, 25), Fraction(7, 25))])
        exact = subprocess.run([*command, "--snap", "exact", request], capture_output=True, text=True, timeout=30)
        self.assertNotEqual(exact.returncode, 0)
        self.assertFalse(self.output.exists())
        for malformed in ("", "0:01-0:00", "0:00-0:01,", "0:00-0:60", "0:00"):
            with self.subTest(malformed=malformed):
                failure = subprocess.run([*command, malformed], capture_output=True, text=True, timeout=30)
                self.assertEqual(failure.returncode, 2)
                self.assertEqual(json.loads(failure.stdout)["error"]["code"], "invalid_range")
                self.assertFalse(self.output.exists())
        result = subprocess.run([*command, request], capture_output=True, text=True, check=True, timeout=30)
        self.assertEqual(json.loads(result.stdout)["segments"], plan["segments"])
        self.assertTrue(self.output.is_file())

    def test_bulk_exports_six_ranges_and_preflights_every_destination(self):
        directory = self.output.parent
        ranges = [{"from": {"numerator": i, "denominator": 25}, "to": f"{i + 4}/25"}
                  for i in (2, 6, 10, 15, 22, 29)]
        request = {"file": str(FIXTURE), "outputDirectory": str(directory), "ranges": ranges}
        names = [f"{FIXTURE.stem}-{i:03d}.mp4" for i in range(1, 7)]

        def bulk(*flags, payload=request, exit_code=0):
            result = subprocess.run([CLI, "bulk", "--json", "--stdin", *flags], input=json.dumps(payload),
                                    text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
            return json.loads(result.stdout)

        self.assertEqual(json.loads(subprocess.check_output([CLI, "help", "--json"]))["defaultBulkMode"], "smart")
        plan = bulk("--dry-run")
        self.assertEqual([Path(item["output"]).name for item in plan["outputs"]], names)
        self.assertTrue(all(item["mode"] == "smart" for item in plan["outputs"]))
        self.assertEqual(list(directory.iterdir()), [])

        bad = {**request, "ranges": [*ranges[:-1], {"from": "28", "to": "29"}]}
        failure = bulk(payload=bad, exit_code=1)
        self.assertEqual(failure["error"]["segment"], 6)
        self.assertEqual(list(directory.iterdir()), [])

        existing = directory / names[-1]
        existing.write_text("keep")
        self.assertEqual(bulk(exit_code=1)["error"]["code"], "output_exists")
        self.assertEqual(list(directory.iterdir()), [existing])
        self.assertEqual(existing.read_text(), "keep")
        existing.unlink()

        exported = bulk()
        self.assertEqual([item["segments"] for item in exported["outputs"]],
                         [item["segments"] for item in plan["outputs"]])
        for name in names:
            target = directory / name
            inspection = json.loads(subprocess.check_output([CLI, "inspect", "--json", "--frames", target]))
            self.assertEqual(len(inspection["media"]["frames"]), 4)

    def test_unsafe_cut_messages_name_start_and_end(self):
        for field, edge in [("from", "start"), ("to", "end")]:
            with self.subTest(field=field):
                report = self.export(request={
                    "output": str(self.output), "clips": [{"file": str(FIXTURE), field: "7/25"}],
                }, exit_code=1)
                self.assertEqual(report["error"]["boundary"], field)
                self.assertEqual(report["error"]["message"], f"There is no verified video {edge} boundary at 7/25.")

    def test_smart_alias_and_stdin_report_same_exact_cut(self):
        smart = self.export("--mode", "smart", start="0.28")
        self.assertEqual(smart, self.export("--smart-trim", start="0.28"))
        self.assertEqual(smart, self.export(request={
            "mode": "smart", "output": str(self.output),
            "clips": [{"file": str(FIXTURE), "from": "0.28"}],
        }))
        self.assertEqual(smart["mode"], "smart")
        self.assertEqual(ratio(smart["segments"][0]["from"]), Fraction(7, 25))
        self.assertEqual(ratio(smart["encodedDuration"]), Fraction(18, 25))
        self.assertEqual(ratio(smart["copiedDuration"]), 1)
        self.assertEqual(smart["segments"][0]["trackActions"][0]["action"], "copyAndEncode")

        single_frame = self.export(request={
            "mode": "smart", "output": str(self.output),
            "clips": [{"file": str(FIXTURE), "from": "0.28", "to": "0.32"}],
        })
        self.assertEqual(ratio(single_frame["encodedDuration"]), Fraction(1, 25))
        self.assertEqual(ratio(single_frame["copiedDuration"]), 0)
        self.assertEqual(single_frame["segments"][0]["trackActions"][0]["action"], "encode")

    def test_encode_settings_reach_dry_run(self):
        request = {
            "mode": "encode", "video": "h264", "quality": "high", "audio": "remove",
            "output": str(self.output), "clips": [{"file": str(FIXTURE), "from": "0.28"}],
        }
        report = self.export(request=request)
        self.assertEqual(report, self.export("--mode", "encode", "--video", "h264",
                                             "--quality", "high", "--audio", "remove", start="0.28"))
        self.assertEqual(report["mode"], "encode")
        self.assertEqual(report["video"], "h264")
        self.assertEqual(report["quality"], "high")
        self.assertEqual(report["audio"], "remove")
        self.assertEqual((report["width"], report["height"]), (320, 96))
        self.assertEqual(ratio(report["segments"][0]["from"]), Fraction(7, 25))
        self.assertEqual(ratio(report["encodedDuration"]), Fraction(43, 25))
        self.assertEqual(ratio(report["copiedDuration"]), 0)
        self.assertEqual(report["segments"][0]["trackActions"][0]["action"], "encode")

    def test_encode_writes_the_planned_timeline(self):
        report = self.export("--mode", "encode", start="7/25", dry_run=False)
        self.assertFalse(report["dryRun"])
        self.assertTrue(self.output.is_file())
        result = subprocess.run([CLI, "inspect", "--json", str(self.output)], check=True,
                                text=True, capture_output=True, timeout=30)
        media = json.loads(result.stdout)["media"]
        self.assertEqual(ratio(media["duration"]), ratio(report["duration"]))

    def test_encode_dry_run_probes_hardware(self):
        env = {**os.environ, "MPCUT_FFMPEG_HELPER": "/usr/bin/false"}
        report = self.export("--mode", "encode", env=env, exit_code=1)
        self.assertEqual(report["error"]["code"], "encoder_unavailable")

    def test_encode_finds_its_helper_when_cli_is_launched_via_path(self):
        # Installations commonly expose only the mpcut symlink on PATH.
        command = self.output.parent / "commands" / "mpcut"
        command.parent.mkdir()
        command.symlink_to(CLI)
        env = {**os.environ, "PATH": str(command.parent) + ":/usr/bin:/bin"}
        env.pop("MPCUT_FFMPEG_HELPER", None)
        result = subprocess.run(["mpcut", "export", "--json", "--mode", "encode",
                                 "--output", self.output, "--clip", FIXTURE, "--to", "1/25"],
                                cwd=self.output.parent, env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(ratio(json.loads(result.stdout)["duration"]), Fraction(1, 25))
        self.assertTrue(self.output.is_file())

    def test_rejects_conflicting_or_invalid_settings(self):
        for flags in [
            ["--mode", "reencode"],
            ["--smart-trim", "--mode", "copy"],
            ["--mode", "copy", "--audio", "aac"],
            ["--mode", "encode", "--snap", "nearest"],
            ["--mode", "encode", "--video", "vp9"],
            ["--mode", "encode", "--audio", "auto", "--audio", "aac"],
        ]:
            with self.subTest(flags=flags):
                self.assertEqual(self.export(*flags, exit_code=2)["error"]["code"], "invalid_arguments")

        request = {"mode": "smart", "output": str(self.output), "clips": [{"file": str(FIXTURE)}]}
        self.assertEqual(self.export("--mode", "copy", request=request, exit_code=2)["error"]["code"],
                         "invalid_arguments")
        self.assertEqual(self.export(request={**request, "mode": "bad"}, exit_code=2)["error"]["code"],
                         "invalid_json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = str(args.mpcut.resolve(strict=True))
    unittest.main(argv=[__file__, *tests])
