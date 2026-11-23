#!/usr/bin/env python3
"""Check CLI path resolution, exit statuses, request diagnostics and standard-stream handling."""
import argparse
import json
import os
from fractions import Fraction
from pathlib import Path
import subprocess
import tempfile
import unittest


CLI = None
FFMPEG = "/opt/homebrew/bin/ffmpeg"


class CLIAuditFixes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(os.path.realpath(cls.temporary.name))
        subprocess.run([FFMPEG, "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=25:duration=2",
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-bf", "0", "-g", "25", "-sc_threshold", "0", "-c:a", "aac", str(cls.root / "x.mp4")],
                       check=True, timeout=60)
        (cls.root / "real/a/b").mkdir(parents=True)
        (cls.root / "link").symlink_to("real/a/b")

    def run_cli(self, *args, request=None, status=0, **options):
        if request is not None and not isinstance(request, bytes):
            request = json.dumps(request).encode()
        result = subprocess.run([CLI, *args], input=request, capture_output="stdout" not in options,
                                cwd=self.root, timeout=120, **options)
        self.assertEqual(result.returncode, status, (result.stdout or b"") + (result.stderr or b""))
        return result

    def report(self, *args, request=None, status=0):
        report = json.loads(self.run_cli(*args, request=request, status=status).stdout)
        self.assertEqual(report["ok"], status == 0)
        return report

    def failure(self, *args, request=None, status=2):
        return self.report(*args, request=request, status=status)["error"]

    def bulk(self, directory="."):
        return {"file": "x.mp4", "output_directory": directory, "ranges": [{"from": "0", "to": "1"}]}

    def test_export_requests_reject_numbers_that_round_to_integer_timestamps(self):
        rational = b'{"numerator":1,"denominator":1}'
        fractional = rational.replace(b'1,', b'1.' + b'0' * 40 + b'1,')
        join = (b'{"output":"precision.mp4","clips":[{"file":"x.mp4","to":' + rational + b'}]}')
        batch = (b'{"file":"x.mp4","output_directory":".","ranges":[{"from":"0","to":' + rational + b'}]}')
        for path, request in ((("clips", "join"), join), (("ranges", "separate"), batch)):
            with self.subTest(path=path):
                args = ("export", *path, "--stdin", "--json", "--dry-run", "--no-sidecar")
                self.report(*args, request=request)
                failure = self.failure(*args, request=request.replace(rational, fractional))
                self.assertEqual(failure["code"], "invalid_json")

    def test_ordered_export_ignores_unused_source_replacement(self):
        source = Path(__file__).resolve().parents[1] / "MPCutAppTests/Fixtures/SmartTrim-GOP.mp4"
        clips = [{"file": "omitted.mp4"}, {"file": str(source), "from": "2/25", "to": "12/25"}]
        request = {"output": "ordered.mp4", "clips": clips, "order": [2]}
        args = ["export", "clips", "join", "--no-sidecar", "--stdin", "--json", "--dry-run"]
        expected = self.report(*args, request=request)
        self.assertEqual(expected["mode"], "smart")
        args[1:3] = ["soundtrack", "replace"]
        self.assertEqual(self.report(*args, request={**request, "replace_audio": "omitted.wav"}), expected)
        clips[0]["replace_audio"] = "omitted.wav"
        self.assertEqual(self.report(*args, request=request), expected)
        clips[0]["file"] = str(source)
        error = self.failure(*args, request={**request, "mode": "smart"})
        self.assertIn("Replacement audio requires copy mode", error["message"])

    def test_parent_reference_through_a_missing_folder_is_rejected(self):
        before = set(self.root.iterdir())
        for dry_run in ([], ["--dry-run"]):
            error = self.failure("export", "clips", "join", "--json", *dry_run, "--output", "nodir/../dotdot.mp4",
                                 "--clip", "x.mp4", "--to", "1")
            self.assertEqual(error["code"], "invalid_path")
            self.assertIn("nodir/../dotdot.mp4", error["message"])
        for command in (["export", "clips", "join", "--json", "--dry-run", "--output", "o.mp4", "--clip", "nodir/../x.mp4", "--to", "1"],
                        ["media", "inspect", "--json", "nodir/../x.mp4"],
                        ["scenes", "export", "--json", "x.mp4", "--export-to", "nodir/..", "--dry-run"]):
            with self.subTest(command=command):
                self.assertEqual(self.failure(*command)["code"], "invalid_path")
        self.assertEqual(self.failure("export", "ranges", "separate", "--json", "--stdin", "--dry-run", request=self.bulk("nodir/.."))["code"],
                         "invalid_path")
        self.assertEqual(set(self.root.iterdir()), before)
        # An existing folder still resolves, with or without "." components.
        for path in ("real/../x.mp4", "real/.././x.mp4", str(self.root / "real/a/../../x.mp4")):
            with self.subTest(path=path):
                self.assertTrue(os.path.samefile(self.report("media", "inspect", "--json", path)["file"], self.root / "x.mp4"))

    def test_parent_reference_after_a_symlink_resolves_physically(self):
        physical = self.root / "real/a"
        plan = self.report("export", "clips", "join", "--json", "--dry-run", "--output", "link/../o.mp4", "--clip", "x.mp4", "--to", "1")
        self.assertEqual(Path(plan["output"]), physical / "o.mp4")
        for directory in ("link/..", "link/../", "link/../."):
            with self.subTest(directory=directory):
                plan = self.report("export", "ranges", "separate", "--json", "--stdin", "--dry-run", request=self.bulk(directory))
                self.assertEqual([Path(item["output"]).parent for item in plan["outputs"]], [physical])
                plan = self.report("scenes", "export", "--json", "x.mp4", "--export-to", directory, "--dry-run")
                self.assertTrue(plan["outputs"])
                self.assertEqual({Path(item["export"]["output"]).parent for item in plan["outputs"]}, {physical})
        self.assertEqual(list(physical.iterdir()), [physical / "b"])

    def test_request_errors_exit_2_whichever_layer_rejects_them(self):
        export = ["export", "clips", "join", "--json", "--dry-run", "--output", "o.mp4", "--clip", "x.mp4"]
        cases = [
            ("invalid_arguments", ["export", "clips", "join", "--json", "--dry-run", "--tracks", "audio", "--audio-stream", "4294967296",
                                   "--output", "o.m4a", "--clip", "x.mp4"], None),
            ("invalid_arguments", ["export", "clips", "join", "--json", "--dry-run", "--stdin"], {"output": "o.mp4", "clips": []}),
            ("invalid_time", [*export, "--from", "1x"], None),
            ("invalid_time", [*export, "--from", "-1"], None),
            ("invalid_time", ["review", "frames", "export", "--json", "--at", "abc", "x.mp4", "--output", "pictures"], None),
            ("invalid_time", ["export", "ranges", "separate", "--json", "--stdin", "--dry-run"],
             {**self.bulk(), "ranges": [{"from": "0", "to": "1x"}]}),
            ("empty_edit", ["export", "ranges", "separate", "--json", "--stdin", "--dry-run"], {**self.bulk(), "ranges": []}),
        ]
        for code, command, request in cases:
            with self.subTest(command=command, request=request):
                self.assertEqual(self.failure(*command, request=request)["code"], code)
        # Operation failures keep exit 1.
        (self.root / "taken.mp4").write_text("keep")
        self.assertEqual(self.failure("export", "clips", "join", "--json", "--output", "taken.mp4", "--clip", "x.mp4", status=1)["code"],
                         "output_exists")
        self.assertEqual((self.root / "taken.mp4").read_text(), "keep")
        self.assertFalse((self.root / "pictures").exists())

    def test_file_destinations_do_not_discard_directory_syntax(self):
        target = self.root / "directory-looking.mp4"
        for suffix in ("/", "/.", "//"):
            with self.subTest(suffix=suffix):
                error = self.failure("export", "clips", "join", "--json", "--output", target.name + suffix, "--clip", "x.mp4", status=1)
                self.assertEqual(error["code"], "invalid_output")
                self.assertFalse(target.exists())

    def test_tilde_in_a_relative_path_is_a_literal_folder_name(self):
        local_tilde = self.root / "~"
        local_tilde.mkdir()
        (local_tilde / "x.mp4").symlink_to(self.root / "x.mp4")
        report = self.report("export", "clips", "join", "--json", "--output", "~/tilde-result.mp4", "--clip", "~/x.mp4")
        self.assertEqual(Path(report["output"]), local_tilde / "tilde-result.mp4")
        self.assertTrue((local_tilde / "tilde-result.mp4").is_file())

    def test_standard_input_requires_json_without_trailing_commas(self):
        for request in (b'{"output":"bad.mp4","clips":[{"file":"x.mp4"}],}',
                        b'{"output":"bad.mp4","clips":[{"file":"x.mp4"}, \n ]}',
                        b'{"output":"bad.mp4","clips":[{"file":"x.mp4",}]}'):
            with self.subTest(request=request):
                error = self.failure("export", "clips", "join", "--json", "--stdin", "--dry-run", request=request)
                self.assertEqual(error["code"], "invalid_json")
        valid = {"output": "closing,].mp4", "clips": [{"file": "x.mp4"}]}
        self.assertEqual(Path(self.report("export", "clips", "join", "--json", "--stdin", "--dry-run", request=valid)["output"]).name,
                         valid["output"])

    def test_bulk_without_stdin_names_the_bulk_contract(self):
        for command in (["export", "ranges", "separate", "--json"], ["export", "ranges", "separate", "--json", "--dry-run"], ["export", "ranges", "separate", "--json", "--", "--stdin"]):
            with self.subTest(command=command):
                error = self.failure(*command)
                self.assertEqual((error["code"], error["message"]), ("invalid_arguments", "Use export ranges separate SOURCE --ranges LIST --output DIRECTORY, or supply a complete range export request."))
        self.assertEqual(self.run_cli("export", "ranges", "separate", status=2).stderr, b"mpcut: Use export ranges separate SOURCE --ranges LIST --output DIRECTORY, or supply a complete range export request.\n")

    def test_unknown_fields_name_the_object_that_contains_them(self):
        time = {"numerator": 1, "denominator": 1, "x": 2}
        export = {"output": "o.mp4", "clips": [{"file": "x.mp4"}, {"file": "x.mp4"}]}
        cases = [
            ("export ranges separate", {**self.bulk(), "ranges": [{"from": "0", "to": "1", "x": 1}]}, "Range 1"),
            ("export ranges separate", {**self.bulk(), "ranges": [{"from": "0", "to": "1"}, {"from": "0", "to": time}]}, "Range 2"),
            ("export ranges separate", {**self.bulk(), "x": 1}, "Bulk request"),
            ("export clips join", {**export, "x": 1}, "Export request"),
            ("export clips join", {**export, "clips": [{"file": "x.mp4"}, {"file": "x.mp4", "x": 1}]}, "Clip 2"),
            ("export clips join", {**export, "clips": [{"file": "x.mp4", "from": time}]}, "Clip 1"),
            ("export clips join", {**export, "clips": [{"file": "x.mp4"}, {"file": "x.mp4", "to": time}]}, "Clip 2"),
        ]
        for verb, request, location in cases:
            with self.subTest(verb=verb, location=location):
                error = self.failure(*verb.split(), "--json", "--stdin", "--dry-run", request=request)
                self.assertEqual((error["code"], error["message"]),
                                 ("invalid_json", f"{location} has an unknown field 'x'."))

    def test_standard_input_is_limited_to_64_megabytes(self):
        limit = 64 * 1024 * 1024
        for verb in ("export clips join", "export ranges separate"):
            with self.subTest(verb=verb):
                error = self.failure(*verb.split(), "--json", "--stdin", "--dry-run", request=b" " * (limit + 1))
                self.assertEqual(error["code"], "invalid_json")
                self.assertIn("64 MB", error["message"])
        request = json.dumps({"output": "o.mp4", "clips": [{"file": "x.mp4"}]}).encode()
        self.report("export", "clips", "join", "--json", "--stdin", "--dry-run", request=request.rjust(limit))

    def test_large_inspection_reports_preserve_order_and_half_open_windows(self):
        # Both the frame and packet reply exceed the in-memory buffer.
        source = self.root / "long.mp4"
        subprocess.run([FFMPEG, "-loglevel", "error", "-f", "lavfi", "-i", "color=s=16x16:r=60:d=180",
                        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", "180",
                        "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", source], check=True, timeout=60)
        for flag, key, expected in [("--frames", "frames", 10800), ("--audio-packets", "audio_packets", None)]:
            with self.subTest(query=flag):
                args = ("media", "inspect", "--no-sidecar", flag, str(source))
                raw = self.run_cli(*args, "--json").stdout
                self.assertGreater(len(raw), 1024 * 1024)
                rows = json.loads(raw)["media"][key]
                if expected is not None:
                    self.assertEqual(len(rows), expected)
                else:
                    probe = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "a:0",
                                                     "-show_entries", "stream=nb_frames", "-of", "csv=p=0", source], timeout=30)
                    self.assertEqual(len(rows), int(probe))
                times = [Fraction(r["time"]["numerator"], r["time"]["denominator"]) for r in rows]
                self.assertEqual(times, sorted(times))
                window = self.report(*args, "--from", "159", "--to", "160")["media"][key]
                self.assertEqual(window, [r for r, t in zip(rows, times) if 159 <= t < 160])
                self.assertEqual(self.report(*args, "--from", "200")["media"][key], [])

        with subprocess.Popen([CLI, "media", "inspect", "--no-sidecar", "--frames", "--json", source],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            self.assertTrue(process.stdout.read(256))
            process.stdout.close()
            self.assertEqual(process.wait(timeout=30), 1)
            self.assertEqual(process.stderr.read(), b"")

    def test_closed_result_pipe_ends_quietly(self):
        for command in (["media", "inspect", "--json", "--frames", "x.mp4"], ["media", "inspect", "--frames", "x.mp4"], ["--version"],
                        ["--version", "--json"], ["help"], ["help", "manual"], ["scenes", "scan", "--json", "x.mp4"]):
            with self.subTest(command=command):
                read_end, write_end = os.pipe()
                os.close(read_end)
                try:
                    result = self.run_cli(*command, status=1, stdout=write_end, stderr=subprocess.PIPE)
                finally:
                    os.close(write_end)
                self.assertEqual(result.stderr, b"")

    def test_unwritable_standard_output_fails_every_response(self):
        for command in (["--version"], ["--version", "--json"], ["help"], ["help", "manual"], ["media", "inspect", "--json", "x.mp4"]):
            with self.subTest(command=command):
                with open(os.devnull, "rb") as read_only:
                    result = self.run_cli(*command, status=1, stdout=read_only, stderr=subprocess.PIPE)
                self.assertTrue(result.stderr.startswith(b"mpcut: Unable to write to standard output."), result.stderr)
        result = self.run_cli("--version", status=1, stderr=subprocess.PIPE, stdout=subprocess.DEVNULL,
                              preexec_fn=lambda: os.close(1))
        self.assertTrue(result.stderr.startswith(b"mpcut: Unable to write to standard output."), result.stderr)
        output = self.root / "plain.mp4"
        with open(os.devnull, "rb") as read_only:
            self.run_cli("export", "clips", "join", "--output", "plain.mp4", "--clip", "x.mp4", status=1, stdout=read_only,
                         stderr=subprocess.PIPE)
        self.assertTrue(output.is_file())
        self.assertEqual(self.run_cli("--version").stdout.decode().strip(), json.loads(self.run_cli("--version", "--json").stdout)["version"])
        self.assertEqual(self.run_cli("export", "clips", "join", "--output", "said.mp4", "--clip", "x.mp4").stdout.decode(),
                         f"Exported {self.root / 'said.mp4'}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = str(args.mpcut.resolve(strict=True))
    unittest.main(argv=[__file__, *tests])
