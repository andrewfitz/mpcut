#!/usr/bin/env python3
"""Regression checks for multicam project validation, CLI flags, and the help round trip."""
import argparse
import copy
from fractions import Fraction
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

from multicam import camera, wav

CLI = None


class MulticamCLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-audit2-multicam-")
        cls.addClassCleanup(directory.cleanup)
        cls.fixtures = Path(directory.name)
        # Help examples name these files. Stream 1 is each camera's microphone.
        camera(cls.fixtures / "wide.mov", marker_base=0, frequency=419)
        camera(cls.fixtures / "close.mov", marker_base=128, frequency=691)
        wav(cls.fixtures / "lav.wav", "4")
        # Four of every five 29.97 fps frame times fall between 48 kHz samples.
        camera(cls.fixtures / "ntsc.mov", marker_base=0, frequency=419, rate="30000/1001", gop=30, length="4.004")
        (cls.fixtures / "interview.mov").symlink_to(cls.fixtures / "wide.mov")
        cls.base = {
            "format": "mpcut", "schema_version": 3, "kind": "multicam", "reference_angle_id": "wide",
            "group_range": {"from": "0", "to": "4"},
            "angles": [{"id": "wide", "file": "wide.mov", "offset": "0", "audio_stream_index": 1},
                       {"id": "close", "file": "close.mov", "offset": "0", "audio_stream_index": 1}],
            "audio_sources": [{"id": "lav", "file": "lav.wav", "offset": "0"}],
            "audio": {"mode": "fixed", "source_id": "lav", "audio_stream_index": 0},
            "switches": [{"group_time": "0", "angle_id": "wide"}, {"group_time": "1", "angle_id": "close"}, {"group_time": "2", "angle_id": "wide"}],
        }

    def setUp(self):
        self.project = self.fixtures / "edit.cut"
        self.project.write_text(json.dumps(self.base))
        self.before = self.listing()

    def listing(self):
        # Reusable analysis sidecars are saved beside sources by design.
        return sorted(str(path.relative_to(self.fixtures)) for path in self.fixtures.rglob("*")
                      if path.suffix != ".cutdb")

    def run_cli(self, *args, request=None):
        text = request if request is None or isinstance(request, str) else json.dumps(request)
        return subprocess.run([CLI, *map(str, args)], input=text or "", capture_output=True, text=True,
                              cwd=self.fixtures, timeout=120)

    def failure(self, *args, request=None, status, code):
        result = self.run_cli(*args, request=request)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertIs(report["ok"], False)
        self.assertEqual(report["error"]["code"], code, report)
        self.assertEqual(self.listing(), self.before)
        return report["error"]

    def success(self, *args, request=None):
        result = self.run_cli(*args, request=request)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def write(self, change):
        document = copy.deepcopy(self.base)
        change(document)
        self.project.write_text(json.dumps(document))

    def entry_points(self):
        """Every way of reading a project, with a dry run and a real export."""
        export = ["export", "project", "render", "--project", self.project, "--output", "program.mov", "--json"]
        clip = {"clips": [{"project_path": str(self.project)}], "output": "program.mov"}
        return [(["project", "inspect", "--project", self.project, "--json"], None),
                ([*export, "--dry-run"], None), (export, None),
                (["review", "frames", "export", "--project", self.project, "--at", "1", "--output", "review", "--json"], None),
                (["export", "clips", "join", "--stdin", "--json", "--dry-run"], clip),
                (["export", "clips", "join", "--stdin", "--json"], clip)]

    def test_malformed_project_time_is_a_located_project_error_on_every_entry_point(self):
        self.write(lambda document: document["switches"][1].update(group_time="1x"))
        for args, request in self.entry_points():
            with self.subTest(args=args[:3], stdin=request is not None):
                # A malformed time is a request to correct: exit 2 and `invalid_time`, as for a time on the command line.
                error = self.failure(*args, request=request, status=2, code="invalid_time")
                self.assertIn("‘1x’ in switches[1].group_time", error["message"])
        silence = ["silence", "scan", "--project", self.project, "--json"]
        resolve = ["project", "resolve", "export", "--project", self.project, "--output", "timeline.fcpxml", "--json"]
        for args in (silence, ["silence", "plan", *silence[2:], "--output", "program.mov", "--dry-run"], resolve):
            with self.subTest(args=args[:3]):
                error = self.failure(*args, status=2, code="invalid_time")
                self.assertIn("‘1x’ in switches[1].group_time", error["message"])
        sequence = self.fixtures / "sequence.cut"
        sequence.write_text(json.dumps({"format": "mpcut", "schema_version": 3, "kind": "sequence", "clips": [
            {"id": "a", "file": "wide.mov", "from": "0", "to": "1x"}]}))
        self.addCleanup(sequence.unlink)
        self.before = self.listing()
        error = self.failure("project", "inspect", "--project", sequence, "--json", status=2, code="invalid_time")
        self.assertIn("‘1x’ in clips[0].to", error["message"])
        self.write(lambda document: document["switches"][1].update(group_time="1x"))
        self.write(lambda document: document["angles"][0].update(extra=1))
        error = self.failure("project", "inspect", "--project", self.project, "--json", status=1, code="invalid_multicam_project")
        self.assertIn("angles[0]", error["message"])

    def test_dry_run_and_real_export_report_the_same_project_errors(self):
        changes = {
            "unknown angle": lambda d: d["switches"][1].update(angle_id="lav"),
            "same-time switches": lambda d: d["switches"][2].update(group_time="2/2"),
            "first switch late": lambda d: d.update(switches=[{"group_time": "1", "angle_id": "wide"}]),
            "assembly outside": lambda d: d.update(assembly=[{"from": "3", "to": "5"}]),
            "assembly empty": lambda d: d.update(assembly=[{"from": "3", "to": "3"}]),
            "repeated id": lambda d: d["audio_sources"][0].update(id="wide"),
            "blank id": lambda d: d["angles"][1].update(id=" "),
            "future version": lambda d: d.update(schema_version=5),
            "wrong kind": lambda d: d.update(kind="edit"),
            "unknown field": lambda d: d.update(extra=True),
            "video stream as sound": lambda d: d.update(audio={"mode": "fixed", "source_id": "wide", "audio_stream_index": 0}),
            "absent stream": lambda d: d.update(audio={"mode": "fixed", "source_id": "wide", "audio_stream_index": 9}),
            "stream beyond 32 bits": lambda d: d.update(audio={"mode": "fixed", "source_id": "wide", "audio_stream_index": 2 ** 40}),
            "audio-only angle": lambda d: d["angles"][1].update(file="lav.wav"),
            "missing recording": lambda d: d["angles"][1].update(file="absent.mov"),
            "offset overflow": lambda d: d["angles"][1].update(offset="-9223372036854775808"),
        }
        export = ["export", "project", "render", "--project", self.project, "--output", "program.mov", "--json"]
        for name, change in changes.items():
            with self.subTest(name):
                self.write(change)
                reports = []
                for args in ([*export, "--dry-run"], export):
                    result = self.run_cli(*args)
                    report = json.loads(result.stdout)
                    self.assertIs(report["ok"], False, name)
                    self.assertIn(result.returncode, (1, 2))
                    self.assertTrue(report["error"]["code"] and report["error"]["message"])
                    reports.append((result.returncode, report["error"]))
                self.assertEqual(reports[0], reports[1])
                self.assertEqual(self.listing(), self.before)
        self.write(lambda d: d.update(audio={"mode": "fixed", "source_id": "wide", "audio_stream_index": 2 ** 40}))
        self.failure(*export, "--dry-run", status=1, code="invalid_multicam_project")

    def test_multicam_refusals_precede_generic_flag_advice(self):
        export = ["export", "project", "render", "--project", self.project, "--output", "program.mov", "--json", "--dry-run"]
        cases = [
            (["--audio-stream", "1"], "project audio policy"),
            (["--tracks", "audio", "--audio-stream", "1"], "project audio policy"),
            (["--replace-track", "1"], "audio_sources"),
            (["--replacement-stream", "0"], "audio_sources"),
            (["--replace-audio", "lav.wav"], "audio_sources"),
            (["--snap", "nearest"], "exact cuts"),
            (["--snap", "nearest", "--mode", "encode"], "exact cuts"),
            (["--tracks", "video", "--mode", "smart"], "choose --mode copy"),
            (["--video", "hevc"], "require --mode encode"),
            (["--order", "1"], "--stdin"),
            (["--clip", "wide.mov"], "--stdin"),
        ]
        for flags, advice in cases:
            with self.subTest(flags=flags):
                error = self.failure(*export, *flags, status=2, code="invalid_arguments")
                self.assertIn(advice, error["message"])
        request = {"clips": [{"project_path": str(self.project)}], "output": "program.mov"}
        for fields, advice in [({"tracks": "audio", "audio_stream": 1}, "project audio policy"),
                               ({"replace_track": 1}, "audio_sources"), ({"snap": "nearest", "mode": "encode"}, "exact cuts")]:
            with self.subTest(fields=fields):
                error = self.failure("export", "clips", "join", "--stdin", "--json", "--dry-run", request={**request, **fields},
                                     status=2, code="invalid_arguments")
                self.assertIn(advice, error["message"])

    def test_project_clip_faults_name_the_request_clip(self):
        stdin = ["export", "clips", "join", "--stdin", "--json", "--dry-run"]
        project = str(self.project)
        for bounds in ({"from": "3", "to": "9"}, {"from": "3", "to": "3"}, {"from": "3", "to": "2"}, {"from": "4"}):
            with self.subTest(bounds=bounds):
                request = {"clips": [{"file": "wide.mov", "to": "1"}, {"project_path": project, **bounds}],
                           "output": "program.mov"}
                error = self.failure(*stdin, request=request, status=1, code="invalid_range")
                self.assertEqual(error["segment"], 2)
                self.assertIn("Project clip 2", error["message"])
                self.assertIn("0 to 4", error["message"])
                # The clip number is the request's, whatever the playback order.
                error = self.failure(*stdin, request={**request, "order": [2, 1]}, status=1, code="invalid_range")
                self.assertEqual(error["segment"], 2)
        file_clip = self.failure(*stdin, request={"clips": [{"project_path": project}, {"file": "wide.mov", "from": "3", "to": "9"}],
                                                  "output": "program.mov"}, status=1, code="invalid_range")
        self.assertEqual(file_clip["segment"], 2)
        self.failure(*stdin, request={"clips": [{"project_path": project, "from": "-1"}], "output": "program.mov"},
                     status=2, code="invalid_time")

        broken = self.fixtures / "broken.cut"
        broken.write_text(json.dumps({**self.base, "kind": "edit"}))
        self.addCleanup(broken.unlink)
        self.before = self.listing()
        for path, code in ((broken, "invalid_multicam_project"), (self.fixtures / "absent.cut", "multicam_project_read_failed"),
                           (self.fixtures / "wide.mov", "invalid_multicam_project")):
            with self.subTest(path=path.name):
                request = {"clips": [{"project_path": project}, {"project_path": str(path)}], "output": "program.mov"}
                error = self.failure(*stdin, request=request, status=1, code=code)
                self.assertEqual(error["segment"], 2)
                self.assertIn("Project clip 2", error["message"])
                self.assertIn(path.name, error["message"])

    def test_project_and_stdin_clip_resolve_the_same_plan(self):
        direct = self.success("export", "project", "render", "--project", self.project, "--output", "program.mov", "--json", "--dry-run")
        clip = self.success("export", "clips", "join", "--stdin", "--json", "--dry-run",
                            request={"clips": [{"project_path": "edit.cut"}], "output": "program.mov"})
        for key in ("plan", "sources", "picture", "audio_lanes", "mode", "duration", "container"):
            self.assertEqual(direct[key], clip[key], key)
        self.assertEqual(direct["mode"], "smart")
        self.assertEqual(self.listing(), self.before)

    def test_oversized_or_special_project_path_fails_promptly(self):
        recording = self.fixtures / "recording.mov"
        with open(recording, "wb") as file:
            file.truncate(64 * 1024 * 1024 + 1)
        self.addCleanup(recording.unlink)
        self.before = self.listing()
        for args in (["project", "inspect", "--project", recording, "--json"],
                     ["export", "project", "render", "--project", recording, "--output", "program.mov", "--json"],
                     ["review", "frames", "export", "--project", recording, "--at", "1", "--output", "review", "--json"]):
            error = self.failure(*args, status=1, code="invalid_cut_project")
            self.assertIn("64 MB", error["message"])
        self.failure("project", "inspect", "--project", "/dev/null", "--json", status=1, code="cut_project_read_failed")
        self.failure("project", "inspect", "--project", self.fixtures, "--json", status=1, code="cut_project_read_failed")
        self.failure("project", "inspect", "--project", "", "--json", status=2, code="invalid_path")

    def test_output_never_replaces_a_source_or_the_project(self):
        link = self.fixtures / "link.mov"
        link.symlink_to(self.fixtures / "absent-target.mov")
        self.addCleanup(link.unlink)
        self.before = self.listing()
        sizes = {path: path.stat().st_size for path in self.fixtures.iterdir() if path.is_file()}
        for output in ("wide.mov", "lav.wav", self.project, link):
            for dry in ([], ["--dry-run"]):
                with self.subTest(output=str(output), dry=dry):
                    self.failure("export", "project", "render", "--project", self.project, "--output", output, "--json", *dry,
                                 status=1, code="output_exists")
        self.assertEqual(sizes, {path: path.stat().st_size for path in self.fixtures.iterdir() if path.is_file()})

    def test_every_help_form_parses_and_templates_validate(self):
        result = self.run_cli("help", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        overview = json.loads(result.stdout)
        names = sorted(overview["commands"])
        self.assertIn("multicam", names)
        self.assertEqual(json.loads(self.run_cli("--help", "--json").stdout), overview)
        # A leading --json belongs to the command that follows.
        for form in (["--json", "--help"], ["--json", "help"]):
            with self.subTest(form=form):
                self.assertEqual(self.success(*form), overview)
        self.assertEqual(self.success("--json", "help", "export", "clips", "join"), overview["commands"]["export clips join"])
        self.assertEqual(self.success("--json", "export", "clips", "join", "--help"), overview["commands"]["export clips join"])
        self.assertEqual(self.success("--json", "--version"), self.success("--version", "--json"))
        self.failure("--json", status=2, code="invalid_arguments")
        self.failure("--json", "--json", "--help", status=2, code="invalid_arguments")
        self.failure("-h", "--json", status=2, code="invalid_arguments")
        for name in names:
            invocation = name.split()
            for form in (["help", *name.split(), "--json"], [*invocation, "--help", "--json"]):
                with self.subTest(form=form):
                    result = self.run_cli(*form)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(json.loads(result.stdout), overview["commands"][name])
            for form in (["help", *name.split()], [*invocation, "--help"]):
                with self.subTest(form=form):
                    result = self.run_cli(*form)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue(result.stdout.startswith(name + " — "))
                    self.assertEqual(result.stderr, "")
        self.failure("help", "nonsense", "--json", status=2, code="invalid_arguments")

        # Each flag in a usage line is known to the command that line invokes.
        for name in names:
            for usage in overview["commands"][name]["usage"]:
                command = next((path for path in sorted(names, key=len, reverse=True)
                                if (usage + " ").startswith("mpcut " + path + " ")), None)
                if command in (None, "help", "--version", "multicam"):
                    continue
                for flag in sorted(set(re.findall(r"(?<![\w-])(--[a-z][a-z-]*)", usage)) - {"--help", "--json"}):
                    with self.subTest(command=command, flag=flag):
                        result = self.run_cli(*command.split(), flag, "1", "--json")
                        message = json.loads(result.stdout).get("error", {}).get("message", "")
                        # A flag without a value leaves the stray "1" to be refused instead.
                        self.assertNotIn("Unknown command", message)
                        self.assertNotRegex(message, r"(?i)unknown.*" + re.escape(flag))

        # Every documented flag is parsed somewhere, and every parsed flag is documented.
        sources = Path(__file__).resolve().parents[2] / "Sources/MPCutCLI"
        parsed = set()
        for file in sources.glob("*.swift"):
            if file.name not in {"CommandHelp.swift", "Transcript.swift"}:
                parsed.update(re.findall(r'"(--[a-z][a-z-]*)"', file.read_text()))
        # The transcript command maps flags to request fields by name instead of listing them
        # as literals. transcript_cli.py covers its flags.
        listed = dict(overview,
                      usage=[line for line in overview["usage"].splitlines() if "mpcut transcript " not in line],
                      commands={name: topic for name, topic in overview["commands"].items()
                                if not name.startswith("transcript ")})
        documented = set(re.findall(r"(?<![\w-])(--[a-z][a-z-]*)", json.dumps(listed, ensure_ascii=False)))
        self.assertEqual(documented - parsed, set())
        self.assertEqual(parsed - documented, set())

        topic = overview["commands"]["multicam"]
        template = topic["project_template"]
        text = self.run_cli("help", "multicam").stdout
        self.assertEqual(json.loads(text[text.index("Project template") + len("Project template"):]), template)
        snippets = "\n".join(topic["instructions"])
        embedded = [json.loads("{" + fragment + "}") for fragment in
                    re.findall(r'("(?:audio|audio_sources|assembly)":(?:\{"mode"[^{}]*\}|\[[^\]]*\]))', snippets)]
        self.assertGreaterEqual(len(embedded), 6)
        override = json.loads(re.search(r'\{"group_time":"2".*?\}\}', snippets).group(0))
        variants = [{}, {"switches": [template["switches"][0], override]}]
        pending = {}
        for fragment in embedded:
            # A recorder declaration applies together with the policy that selects it.
            pending.update(fragment)
            if "audio" in fragment or "assembly" in fragment:
                variants.append(pending)
                pending = {}
        for changes in variants:
            with self.subTest(changes=changes):
                document = {**template, **changes}
                if changes.get("audio", {}).get("mode") == "fixed":
                    document.pop("fixed_audio", None)
                if document["audio"] == {"mode": "follow"}:
                    document["angles"] = [{**angle, "audio_stream_index": 1} for angle in template["angles"]]
                self.project.write_text(json.dumps(document))
                report = self.success("project", "inspect", "--project", self.project, "--json")
                self.assertEqual(report["inspection"]["issues"], [])
                plan = self.success("export", "project", "render", "--project", self.project, "--output", "finished.mov", "--json", "--dry-run")
                self.assertIs(plan["dry_run"], True)
        self.project.write_text(json.dumps(template))

        # Embedded stdin requests validate when replayed.
        (self.fixtures / "clips").mkdir()
        self.addCleanup((self.fixtures / "clips").rmdir)
        for name in ("export clips join", "export ranges separate"):
            report = self.success(*name.split(), "--stdin", "--json", "--dry-run", request=overview["commands"][name]["stdin_example"])
            self.assertIs(report["dry_run"], True)
        for example in topic["examples"] + overview["commands"]["export clips join"]["examples"] + overview["commands"]["export ranges separate"]["examples"]:
            request = re.search(r"printf '%s' '(.*)' \| mpcut ([\w -]+) --stdin --json", example)
            if request:
                with self.subTest(example=example):
                    report = self.success(*request.group(2).split(), "--stdin", "--json", "--dry-run", request=request.group(1))
                    self.assertIs(report["dry_run"], True)
        self.assertEqual(self.listing(), sorted(self.before + ["clips"]))

    def test_saved_review_help_examples_run(self):
        overview = self.success("help", "--json")["commands"]

        def fixture(name, document):
            path = self.fixtures / name
            path.write_text(json.dumps(document))
            self.addCleanup(path.unlink)
            return path

        def example(command):
            args = shlex.split(overview[command]["examples"][0])
            self.assertEqual(args[:1], ["mpcut"])
            return self.success(*args[1:])

        multicam = fixture("interview.cut", self.base)
        sync = example("multicam sync suggest")
        self.assertEqual(sync["reference_source_id"], "wide")
        sync = self.success("multicam", "sync", "suggest", "--project", multicam,
                            "--source-id", "close", "--reference-source-id", "wide", "--metadata-only", "--json")
        self.assertIs(sync["waveform_requested"], False)
        self.assertEqual([item["source_id"] for item in sync["suggestions"]], ["close"])

        fixture("proposal.json", {"project_path": "interview.cut", "angle_id": "close", "group_time": "1"})
        coverage = example("multicam switch coverage")
        self.assertEqual(coverage["group"], {"from": "1", "to": "2"})
        self.assertEqual(coverage["picture"]["status"], "covered")

        sequence = {"format": "mpcut", "schema_version": 3, "kind": "sequence", "clips": [
            {"id": key, "file": "interview.mov", "from": "0", "to": "3"} for key in ["first", "second"]]}
        multicam.write_text(json.dumps(sequence))
        mapping = example("timeline range map")
        self.assertEqual(mapping["output_clock"], "sequence")
        mapping = self.success("timeline", "range", "map", "--project", multicam, "--space", "source",
                               "--from", "1", "--to", "2", "--file", "interview.mov", "--occurrence-index", "1", "--json")
        self.assertEqual([piece["id"] for piece in mapping["pieces"]], ["second"])

        fixture("review.cut", sequence)
        fixture("current.cut", {**sequence, "clips": sequence["clips"][:1]})
        changes = example("history compare")["changes"]
        self.assertEqual([(item["kind"], item["before"]["id"]) for item in changes], [("removed", "second")])

    def test_silent_policy_with_switch_overrides_agrees_across_inspect_dry_run_and_export(self):
        lav = {"source_id": "lav", "audio_stream_index": 0}
        export = ["export", "project", "render", "--project", self.project, "--output", "program.mov", "--json"]

        def silent(switches):
            def change(document):
                document["audio"] = {"mode": "none"}
                document["switches"] = switches
            self.write(change)

        # The desktop app can save a pinned microphone under the silent policy. It must load.
        silent([{"group_time": "0", "angle_id": "wide"}, {"group_time": "1", "angle_id": "close", "audio": lav}])
        issues = self.success("project", "inspect", "--project", self.project, "--json")["inspection"]["issues"]
        self.assertEqual([(issue["code"], issue["segment"]) for issue in issues], [("missing_audio", 1)])
        self.assertEqual(issues[0]["multicam"]["group_range"], {"from": "0", "to": "1"})
        for args in ([*export, "--dry-run"], export):
            with self.subTest(args=args[-1]):
                error = self.failure(*args, status=1, code="missing_audio")
                self.assertEqual(error["segment"], issues[0]["segment"])
                self.assertEqual(error["multicam"], issues[0]["multicam"])
        self.assertEqual(self.success(*export, "--dry-run", "--tracks", "video")["audio_lanes"], [])

        silent([{"group_time": "0", "angle_id": "wide", "audio": lav}, {"group_time": "1", "angle_id": "close", "audio": lav}])
        self.assertEqual(self.success("project", "inspect", "--project", self.project, "--json")["inspection"]["issues"], [])
        lane, = self.success(*export, "--dry-run")["audio_lanes"]
        self.assertEqual(len(lane["segments"]), 1)

        silent([{"group_time": "0", "angle_id": "wide"}, {"group_time": "1", "angle_id": "close"}])
        self.assertEqual(self.success("project", "inspect", "--project", self.project, "--json")["inspection"]["issues"], [])
        self.assertEqual(self.success(*export, "--dry-run")["audio_lanes"], [])

    def test_error_segment_is_the_request_clip_or_assembly_range_number(self):
        stdin = ["export", "clips", "join", "--stdin", "--json", "--dry-run"]
        project = str(self.project)
        # Clip 3 plays second and cannot join the others. An ordinary export names the same clip.
        clips = [{"file": "wide.mov", "to": "1"}, {"file": "wide.mov", "from": "1", "to": "2"},
                 {"file": "ntsc.mov", "to": "1001/1000"}]
        mixed = self.failure(*stdin, request={"clips": [*clips, {"project_path": project, "to": "1"}], "order": [4, 3, 1],
                                              "output": "program.mov"}, status=1, code="incompatible_clip")
        self.assertEqual(mixed["segment"], 3)
        self.assertEqual(mixed["multicam"]["source_id"], "file-3")
        ordinary = self.failure(*stdin, request={"clips": clips, "order": [1, 3], "mode": "copy", "output": "program.mov"},
                                status=1, code="incompatible_clip")
        self.assertEqual(ordinary["segment"], 3)

        # Clip 3 plays first and starts between keyframes.
        request = {"clips": [{"project_path": project, "to": "1"}, {"file": "wide.mov", "from": "1", "to": "2"},
                             {"project_path": project, "from": "1/2", "to": "1"}],
                   "order": [3, 1], "mode": "copy", "output": "program.mov"}
        error = self.failure(*stdin, request=request, status=1, code="unsafe_boundary")
        self.assertEqual((error["segment"], error["boundary"]), (3, "from"))
        self.assertEqual(error["multicam"]["edge"]["range_number"], 3)

        # A saved project numbers its assembly ranges.
        self.write(lambda document: document.update(assembly=[{"from": "0", "to": "1"}, {"from": "1/2", "to": "1"}]))
        error = self.failure("export", "project", "render", "--project", self.project, "--output", "program.mov", "--json", "--dry-run",
                             "--mode", "copy", status=1, code="unsafe_boundary")
        self.assertEqual((error["segment"], error["multicam"]["edge"]["range_number"]), (2, 2))

    def ntsc_project(self, **changes):
        document = {**self.base, "group_range": {"from": "0", "to": "4"}, "audio": {"mode": "follow"},
                    "angles": [{"id": "wide", "file": "ntsc.mov", "offset": "0", "audio_stream_index": 1}],
                    "switches": [{"group_time": "0", "angle_id": "wide"}], **changes}
        self.project.write_text(json.dumps(document))
        return document

    @staticmethod
    def fraction(time):
        return Fraction(time["numerator"], time["denominator"])

    def test_unsafe_range_edge_offers_group_times_that_no_switch_can_take(self):
        export = ["export", "project", "render", "--project", self.project, "--output", "program.mov", "--json", "--dry-run"]
        frame = Fraction(1001, 30000)

        # The program ends on frame 7, between audio samples. Only an earlier end lies inside the group.
        document = self.ntsc_project(group_range={"from": "0", "to": str(7 * frame)})
        error = self.failure(*export, status=1, code="unsafe_boundary")
        self.assertEqual((error["segment"], error["boundary"]), (1, "to"))
        self.assertNotIn("switch_group_time", error["multicam"])
        edge = error["multicam"]["edge"]
        self.assertEqual((edge["range_number"], edge["boundary"], self.fraction(edge["group_time"])), (1, "to", 7 * frame))
        self.assertEqual([self.fraction(time) for time in error["nearest"]], [5 * frame])
        self.ntsc_project(group_range=document["group_range"], assembly=[{"from": "0", "to": str(5 * frame)}])
        self.assertEqual(self.fraction(self.success(*export)["duration"]), 5 * frame)

        # A range can begin exactly on a switch. The suggestion addresses the range, so the
        # switch anchor that the desktop app applies suggestions to stays absent.
        switches = [{"group_time": "0", "angle_id": "wide"}, {"group_time": str(frame), "angle_id": "wide", "audio": {"source_id": "wide", "audio_stream_index": 1}}]
        for mode in ("smart", "copy"):
            with self.subTest(mode=mode):
                self.ntsc_project(switches=switches, assembly=[{"from": str(frame), "to": str(60 * frame)}])
                error = self.failure(*export, "--mode", mode, status=1, code="unsafe_boundary")
                self.assertNotIn("switch_group_time", error["multicam"])
                edge = error["multicam"]["edge"]
                self.assertEqual((edge["range_number"], edge["boundary"], self.fraction(edge["group_time"])), (1, "from", frame))
                self.assertEqual(error["segment"], 1)
                offered = [self.fraction(time) for time in error["nearest"]]
                # Smart Trim can start on any frame that lies on a sample. Copy needs a keyframe.
                self.assertEqual(offered, [0, 5 * frame] if mode == "smart" else [0, 30 * frame])
                for time in offered:
                    self.ntsc_project(switches=switches, assembly=[{"from": str(time), "to": str(60 * frame)}])
                    self.success(*export, "--mode", mode)

        # Two unsafe edges are reported in turn. Each suggestion settles its own edge.
        self.ntsc_project(assembly=[{"from": str(frame), "to": str(62 * frame)}])
        first = self.failure(*export, status=1, code="unsafe_boundary")
        self.assertEqual(first["multicam"]["edge"]["boundary"], "from")
        start = self.fraction(first["nearest"][-1])
        self.ntsc_project(assembly=[{"from": str(start), "to": str(62 * frame)}])
        second = self.failure(*export, status=1, code="unsafe_boundary")
        self.assertEqual(second["multicam"]["edge"]["boundary"], "to")
        self.assertEqual([self.fraction(time) for time in second["nearest"]], [60 * frame, 65 * frame])
        self.ntsc_project(assembly=[{"from": str(start), "to": str(65 * frame)}])
        self.success(*export)

        # A switch between samples keeps its anchor and its own suggestions.
        # Both angles read one recording, so only the switch time decides the outcome.
        angles = [{"id": name, "file": "ntsc.mov", "offset": "0", "audio_stream_index": 1} for name in ("wide", "close")]
        cut = [{"group_time": "0", "angle_id": "wide"}, {"group_time": str(frame), "angle_id": "close"}]
        self.ntsc_project(group_range={"from": "0", "to": str(60 * frame)}, angles=angles, switches=cut)
        error = self.failure(*export, status=1, code="unsafe_boundary")
        self.assertEqual(self.fraction(error["multicam"]["switch_group_time"]), frame)
        self.assertNotIn("edge", error["multicam"])
        self.assertEqual(error["segment"], 1)
        self.assertEqual([self.fraction(time) for time in error["nearest"]], [5 * frame])
        cut[1]["group_time"] = str(5 * frame)
        self.ntsc_project(group_range={"from": "0", "to": str(60 * frame)}, angles=angles, switches=cut)
        self.success(*export)

        # In a request the edge is the caller's clip, wherever it plays.
        self.ntsc_project()
        clips = [{"project_path": str(self.project), "to": str(5 * frame)},
                 {"project_path": str(self.project), "from": str(frame), "to": str(60 * frame)}]
        stdin = ["export", "clips", "join", "--stdin", "--json", "--dry-run"]
        error = self.failure(*stdin, request={"clips": clips, "order": [2, 1, 2], "output": "program.mov"},
                             status=1, code="unsafe_boundary")
        edge = error["multicam"]["edge"]
        self.assertEqual((error["segment"], edge["range_number"], edge["boundary"]), (2, 2, "from"))
        self.assertEqual([self.fraction(time) for time in error["nearest"]], [0, 5 * frame])
        for time in error["nearest"]:
            clips[1]["from"] = str(self.fraction(time))
            self.success(*stdin, request={"clips": clips, "order": [2, 1, 2], "output": "program.mov"})

    def test_frames_into_a_read_only_folder_is_a_structured_write_failure(self):
        locked = self.fixtures / "locked"
        locked.mkdir()
        self.addCleanup(locked.rmdir)
        self.addCleanup(os.chmod, locked, 0o755)
        os.chmod(locked, 0o555)
        self.before = self.listing()
        for source in (["wide.mov"], ["--project", self.project]):
            with self.subTest(source=source[0]):
                error = self.failure("review", "frames", "export", *source, "--at", "1", "--output", "locked/review", "--json",
                                     status=1, code="write_failed")
                self.assertIn("Permission denied", error["message"])
                self.assertIn(str(locked.resolve()), error["message"])

    def test_project_on_standard_input_resolves_sources_from_the_working_directory(self):
        document = self.project.read_text()
        saved = self.success("project", "inspect", "--project", self.project, "--json")
        for name in ("-", "/dev/stdin"):
            piped = self.success("project", "inspect", "--project", name, "--json", request=document)
            self.assertEqual(piped.pop("project_path"), "-")
            self.assertEqual(piped, {key: saved[key] for key in piped})
        export = ["--output", "program.mov", "--json", "--dry-run"]
        self.assertEqual(self.success("export", "project", "render", "--project", "-", *export, request=document),
                         self.success("export", "project", "render", "--project", self.project, *export))
        silence = self.success("silence", "scan", "--project", "-", "--json", request=document)
        self.assertEqual(silence["project_path"], "-")
        frames = self.success("review", "frames", "export", "--project", "-", "--at", "1", "--output", "review", "--json", request=document)
        self.addCleanup(lambda: [path.unlink() for path in (self.fixtures / "review").iterdir()]
                        and (self.fixtures / "review").rmdir())
        angle_files = [Path(angle["file"]) for angle in frames["angles"]]
        self.assertTrue(all(path.is_absolute() for path in angle_files))
        self.assertEqual([path.resolve(strict=True) for path in angle_files],
                         [(self.fixtures / name).resolve(strict=True) for name in ("wide.mov", "close.mov")])
        self.before = self.listing()

        # The same faults as a saved project, and the request limit of every stdin command.
        self.failure("project", "inspect", "--project", "-", "--json", request="{", status=1, code="invalid_cut_project")
        broken = json.dumps({**self.base, "switches": []})
        self.failure("export", "project", "render", "--project", "-", *export, request=broken, status=1, code="invalid_multicam_project")
        # Standard input already carries an edit request.
        error = self.failure("export", "clips", "join", "--stdin", "--json", "--dry-run",
                             request={"clips": [{"project_path": "-"}], "output": "program.mov"}, status=2, code="invalid_json")
        self.assertIn("./-", error["message"])
        elsewhere = self.fixtures / "elsewhere"
        elsewhere.mkdir()
        self.addCleanup(elsewhere.rmdir)
        result = subprocess.run([CLI, "project", "inspect", "--project", "-", "--json"], input=document, capture_output=True,
                                text=True, cwd=elsewhere, timeout=120)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(str(elsewhere.resolve() / "wide.mov"), json.loads(result.stdout)["error"]["message"])

    def test_source_offset_beyond_the_time_range_is_one_fault_for_inspect_and_export(self):
        export = ["export", "project", "render", "--project", self.project, "--output", "program.mov", "--json"]
        for offset in ("9223372036854775807", "-9223372036854775807"):
            with self.subTest(offset=offset):
                self.write(lambda document: document["angles"][0].update(offset=offset))
                messages = [self.failure(*args, status=1, code="time_overflow")["message"]
                            for args in (["project", "inspect", "--project", self.project, "--json"], [*export, "--dry-run"], export)]
                self.assertEqual(len(set(messages)), 1, messages)
                self.assertIn("Source wide", messages[0])
                self.assertIn(offset, messages[0])
        # A representable offset that leaves the picture uncovered is reported as such by both.
        self.write(lambda document: document["angles"][0].update(offset="4611686018427387904"))
        issues = self.success("project", "inspect", "--project", self.project, "--json")["inspection"]["issues"]
        self.assertEqual({issue["code"] for issue in issues}, {"uncovered_picture"})
        self.failure(*export, "--dry-run", status=1, code="uncovered_picture")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
