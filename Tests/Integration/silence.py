#!/usr/bin/env python3
"""Check the peak map, silence reports, replay and both joined export modes."""
import argparse
from fractions import Fraction
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import tempfile
import time
import unittest
from saved_project import read_project


def seconds(time):
    return Fraction(time["numerator"], time["denominator"])


def spans(report, key):
    return [(seconds(item["from"]), seconds(item["to"])) for item in report[key]]


class Silence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temp.cleanup)
        cls.source = Path(temp.name) / "Stereo.mov"
        # The channels cancel in a mono mix. Track 2 stays audible in the gap.
        tone = "0.25*sin(2*PI*440*t)*if(between(t,1,5),0,1)"
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=320x96:r=25:d=6",
                        "-f", "lavfi", "-i", f"aevalsrc='{tone}|-{tone}':s=48000:d=6",
                        "-f", "lavfi", "-i", "sine=f=500:r=48000:d=6",
                        "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264",
                        "-g", "25", "-bf", "0", "-c:a", "pcm_s16le", cls.source], check=True, timeout=120)

    def cli(self, *args, report=None, success=True):
        action = "export" if "--output" in args and "--dry-run" not in args else (
            "plan" if report is not None or "--dry-run" in args or "--pauses-file" in args or "--input" in args else "scan")
        result = subprocess.run([CLI, "silence", action, "--json", *args], input=json.dumps(report) if report else None,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def project(self, location, *, audio, switches, assembly=None):
        doc = {
            "format": "mpcut", "schema_version": 3, "kind": "multicam", "reference_angle_id": "a",
            "group_range": {"from": "0", "to": "6"},
            "angles": [
                {"id": "a", "file": self.source.name, "audio_stream_index": 1},
                {"id": "b", "file": self.source.name, "offset": "1", "audio_stream_index": 2},
            ],
            "audio_sources": [{"id": "recorder", "file": self.source.name, "offset": "0.5"}],
            "audio": audio, "switches": switches,
        }
        if assembly is not None:
            doc["assembly"] = [{"from": str(start), "to": str(end)} for start, end in assembly]
        location.write_text(json.dumps(doc))

    def intervals(self, report, key):
        return [(item["assembly_index"], seconds(item["group"]["from"]), seconds(item["group"]["to"]),
                 seconds(item["output"]["from"]), seconds(item["output"]["to"])) for item in report[key]]

    def test_padding_per_side_and_rejection_of_retired_report_keys(self):
        report = self.cli("--padding-per-side-seconds", "0.25", "--tracks", "audio", "--audio-stream", "1", self.source)
        self.assertEqual(report["padding_per_side_seconds"], 0.25)
        pause, = spans(report, "pauses")
        cut, = spans(report, "removals")
        self.assertEqual((cut[0] - pause[0], pause[1] - cut[1]), (Fraction(1, 4), Fraction(1, 4)))
        report["leave"] = 2 * report["padding_per_side_seconds"]
        self.assertEqual(self.cli("--stdin", report=report, success=False)["error"]["code"], "invalid_json")

    def test_project_pause_overrides_and_take_boundaries(self):
        sequence = self.source.parent / "take-candidates.cut"
        sequence.write_text(json.dumps({"format": "mpcut", "schema_version": 3, "kind": "sequence",
                                        "clips": [{"id": "take=one", "file": self.source.name, "from": "0", "to": "6"},
                                                  {"id": "two", "file": self.source.name, "from": "0", "to": "6"}]}))
        multicam = self.source.parent / "take-assembly.cut"
        self.project(multicam, audio={"mode": "fixed", "source_id": "a", "audio_stream_index": 1},
                     switches=[{"group_time": "0", "angle_id": "a"}], assembly=[(0, 6), (0, 6)])
        for project in (sequence, multicam):
            with self.subTest(project=project.name):
                args = ("--project", project, "--min-pause-seconds", "0.5")
                baseline = self.cli(*args)
                first, second = baseline["pauses"]
                candidates = spans(baseline, "take_candidates")
                split = sum(candidates[0]) / 2
                self.assertEqual(len(spans(self.cli(*args, "--take-boundary", str(split)), "take_candidates")),
                                 len(candidates) + 1)
                self.assertEqual(self.cli(*args, "--take-boundary", "3", success=False)["error"]["code"], "invalid_arguments")
                override = self.cli(*args, "--retain-pause", first["id"] + "=1")
                self.assertAlmostEqual(override["pauses"][0]["retained_seconds"], 1, delta=0.08)
                self.assertEqual(override["pauses"][0]["requested_retained_seconds"], 1)
                self.assertEqual(override["pauses"][1], second)
                self.assertEqual(self.cli(*args, "--retain-pause", "stale=1", success=False)["error"]["code"],
                                 "invalid_arguments")
                shortened = project.with_name(project.stem + "-shortened.cut")
                saved = subprocess.run([CLI, "silence", "shorten", "--json", *args,
                                        "--retain-pause", first["id"] + "=1", "--out-project", shortened],
                                       capture_output=True, text=True, timeout=30)
                self.assertEqual(saved.returncode, 0, saved.stdout + saved.stderr)
                self.assertTrue(shortened.is_file())
                self.assertEqual(json.loads(saved.stdout)["retained_duration"], override["retained_duration"])

    def test_sequence_shortening_rejects_removal_of_the_whole_program(self):
        project = self.source.parent / "quiet-sequence.cut"
        project.write_text(json.dumps({"format": "mpcut", "schema_version": 3, "kind": "sequence",
                                       "clips": [{"id": "quiet", "file": self.source.name, "from": "2", "to": "4"}]}))
        args = ("--project", project, "--threshold-db", "-40", "--padding-per-side-seconds", "0")
        scan = self.cli(*args)
        self.assertEqual(seconds(scan["retained_duration"]), 0)
        destination = project.with_name("quiet-shortened.cut")
        result = subprocess.run([CLI, "silence", "shorten", "--json", *args, "--out-project", destination],
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "empty_edit")
        self.assertFalse(destination.exists())

    def test_project_repeated_fixed_audio_report_dry_run_and_export(self):
        project = self.source.parent / "repeated.cut"
        self.project(project, audio={"mode": "fixed", "source_id": "a", "audio_stream_index": 1},
                     switches=[{"group_time": "0", "angle_id": "a"}, {"group_time": "4", "angle_id": "b"}],
                     assembly=[(4, 6), (0, 3), (4, 6)])
        project_before = project.read_bytes()
        args = ("--project", project, "--min-pause-seconds", "0.5")
        report = self.cli(*args)
        self.assertEqual(report["threshold_mode"], "auto")
        self.assertEqual([(item["source_id"], item["audio_stream_index"]) for item in report["thresholds"]], [("a", 1)])
        self.assertEqual(self.intervals(report, "pauses"), [(0, 4, 5, 0, 1), (1, 1, 3, 3, 5), (2, 4, 5, 5, 6)])
        self.assertEqual(self.intervals(report, "removals"), [
            (0, Fraction(21, 5), Fraction(24, 5), Fraction(1, 5), Fraction(4, 5)),
            (1, Fraction(6, 5), Fraction(14, 5), Fraction(16, 5), Fraction(24, 5)),
            (2, Fraction(21, 5), Fraction(24, 5), Fraction(26, 5), Fraction(29, 5)),
        ])
        self.assertEqual(seconds(report["removed_duration"]), Fraction(14, 5))
        output = self.source.parent / "repeated.mov"
        dry = self.cli(*args, "--output", output, "--dry-run")
        self.assertEqual(dry["clips"], report["clips"])
        self.assertTrue(dry["dry_run"])
        self.assertFalse(output.exists())
        exported = self.cli(*args, "--output", output)
        self.assertFalse(exported["dry_run"])
        self.assertTrue(output.exists())
        self.assertEqual(seconds(exported["preflight"]["duration"]), Fraction(21, 5))
        self.assertEqual({span["source"] for span in exported["preflight"]["mapping"]["picture"]}, {"a", "b"})
        lane, = exported["preflight"]["mapping"]["audio_lanes"]
        self.assertEqual({span["source"] for span in lane["spans"]}, {"a"})
        def decoded_pcm(path):
            return subprocess.check_output(["ffmpeg", "-v", "error", "-i", path, "-map", "0:a:0",
                                            "-c:a", "pcm_s16le", "-f", "s16le", "-"], timeout=30)
        original = decoded_pcm(self.source)
        # Two signed 16-bit channels at 48 kHz.
        bytes_per_second = 4 * 48_000
        expected = b"".join(original[int(start * bytes_per_second):int(end * bytes_per_second)]
                            for _, start, end, _, _ in self.intervals(report, "clips"))
        self.assertEqual(decoded_pcm(output), expected)

        copy = self.cli(*args, "--mode", "copy", "--output", self.source.parent / "copy.mov", "--dry-run")
        self.assertEqual(copy["mode"], "copy")
        self.assertEqual(copy["removals"], [])
        self.assertEqual(copy["skipped_pauses"], 3)
        self.assertEqual(seconds(copy["preflight"]["duration"]), 7)
        self.assertEqual(project.read_bytes(), project_before)

    def test_shorten_preserves_occurrence_camera_override(self):
        project = self.source.parent / "pinned.cut"
        self.project(project, audio={"mode": "fixed", "source_id": "a", "audio_stream_index": 1},
                     switches=[{"group_time": "0", "angle_id": "a"}])
        doc = read_project(project)
        doc["assembly"] = [{"kind": "group", "from": "1", "to": "5", "angle_id": "b"}]
        project.write_text(json.dumps(doc))
        destination = project.with_name("pinned-short.cut")
        result = subprocess.run([CLI, "silence", "shorten", "--json", "--project", project,
                                 "--out-project", destination], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        retained = read_project(destination)["assembly"]
        self.assertEqual([item["angle_id"] for item in retained], ["b", "b"])

    def test_project_follow_and_override_use_offsets_and_absolute_streams(self):
        project = self.source.parent / "follow.cut"
        switches = [{"group_time": "0", "angle_id": "a"}, {"group_time": "3", "angle_id": "b"}]
        self.project(project, audio={"mode": "follow"}, switches=switches)
        report = self.cli("--project", project, "--threshold-db", "-40", "--no-sidecar")
        self.assertEqual(report["threshold_mode"], "manual")
        self.assertEqual([(item["source_id"], item["audio_stream_index"]) for item in report["thresholds"]], [("a", 1), ("b", 2)])
        self.assertEqual(self.intervals(report, "pauses"), [(0, 1, 3, 1, 3)])
        switches[1]["audio"] = {"source_id": "recorder", "audio_stream_index": 1}
        switches.append({"group_time": "4", "angle_id": "b"})
        self.project(project, audio={"mode": "follow"}, switches=switches)
        report = self.cli("--project", project, "--threshold-db", "-40", "--no-sidecar")
        self.assertEqual(self.intervals(report, "pauses"), [(0, 1, 4, 1, 4)])
        self.assertEqual([(item["source_id"], item["audio_stream_index"]) for item in report["thresholds"]],
                         [("a", 1), ("recorder", 1), ("b", 2)])
        for flags in [("--stream", "1"), ("--audio-stream", "1"), ("--waveform", "16"),
                      ("--tracks", "audio"), ("--stdin",), ("--dry-run",), ("--mode", "encode")]:
            with self.subTest(flags=flags):
                error = self.cli("--project", project, *flags, success=False)["error"]
                self.assertEqual(error["code"], "invalid_arguments")

    def test_project_dry_run_rejects_sidecar_destination_before_analysis(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / self.source.name
            source.hardlink_to(self.source)
            project = Path(folder) / "edit.cut"
            self.project(project, audio={"mode": "follow"}, switches=[{"group_time": "0", "angle_id": "a"}])
            sidecar = source.with_suffix(".mov.cutdb")
            failure = self.cli("--project", project, "--output", sidecar, "--dry-run", success=False)
            self.assertEqual(failure["error"]["code"], "unsupported_container")
            self.assertFalse(sidecar.exists())

    def test_project_report_rejects_picture_changed_after_indexing(self):
        self.check_project_interruption(change_source=True)

    def test_project_cancelled_during_analysis_leaves_no_output(self):
        self.check_project_interruption(change_source=False)

    def check_project_interruption(self, *, change_source):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source = folder / self.source.name
            shutil.copyfile(self.source, source)
            audio = folder / "recorder.wav"
            # A sparse 20-minute WAV gives the report time to analyze the separate microphone.
            size = 48_000 * 2 * 1_200
            with audio.open("wb") as wav:
                wav.write(struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", size + 36, b"WAVE", b"fmt ", 16,
                                      1, 1, 48_000, 96_000, 2, 16, b"data", size))
                wav.truncate(size + 44)
            project = folder / "edit.cut"
            self.project(project, audio={"mode": "fixed", "source_id": "z", "audio_stream_index": 0},
                         switches=[{"group_time": "0", "angle_id": "a"}])
            document = read_project(project)
            document["audio_sources"] = [{"id": "z", "file": audio.name}]
            project.write_text(json.dumps(document))
            output = folder / "shortened.mov"
            args = [] if change_source else ["--output", output]
            with subprocess.Popen([CLI, "silence", "scan" if change_source else "export", "--json", "--project", project, *args],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
                try:
                    deadline = time.monotonic() + 10
                    # Source z is indexed after source a. Its sidecar marks the end of the picture scan.
                    sidecar = audio.with_suffix(".wav.cutdb")
                    while not sidecar.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.002)
                    self.assertTrue(sidecar.exists())
                    if change_source:
                        stat = source.stat()
                        os.utime(source, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))
                    else:
                        process.send_signal(signal.SIGINT)
                    stdout, stderr = process.communicate(timeout=15)
                finally:
                    if process.poll() is None:
                        process.kill()
                self.assertEqual(process.returncode, 1 if change_source else 130, stdout + stderr)
                self.assertEqual(json.loads(stdout)["error"]["code"], "source_changed" if change_source else "cancelled")
                self.assertFalse(output.exists())
                self.assertEqual(list(folder.glob(".mpcut-multicam-*")), [])

    def test_project_joins_short_quiet_runs_at_microphone_switch(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "switch.mov"
            project = Path(folder) / "switch.cut"
            before = "0.25*sin(2*PI*440*t)*if(between(t,1,3.1),0,1)"
            after = "0.25*sin(2*PI*880*t)*if(between(t,2.9,5),0,1)"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=64x64:r=25:d=6",
                            "-f", "lavfi", "-i", f"aevalsrc='{before}':s=48000:d=6",
                            "-f", "lavfi", "-i", f"aevalsrc='{after}':s=48000:d=6",
                            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264",
                            "-g", "25", "-bf", "0", "-c:a", "pcm_s16le", source], check=True, timeout=30)
            project.write_text(json.dumps({
                "format": "mpcut", "schema_version": 3, "kind": "multicam", "reference_angle_id": "a",
                "group_range": {"from": "0", "to": "6"},
                "angles": [{"id": "a", "file": source.name, "audio_stream_index": 1}],
                "audio": {"mode": "follow"},
                "switches": [{"group_time": "0", "angle_id": "a"},
                             {"group_time": "3", "angle_id": "a", "audio": {"source_id": "a", "audio_stream_index": 2}}],
            }))
            output = Path(folder) / "shortened.mov"
            report = self.cli("--project", project, "--min-pause-seconds", "3", "--padding-per-side-seconds", "0", "--no-sidecar",
                              "--output", output, "--dry-run")
            self.assertEqual(self.intervals(report, "pauses"), [(0, 1, 5, 1, 5)])
            self.assertEqual(self.intervals(report, "removals"), [(0, 1, 5, 1, 5)])
            lane, = report["preflight"]["mapping"]["audio_lanes"]
            self.assertEqual([span["stream"] for span in lane["spans"]], [1, 2])
            self.assertFalse(source.with_suffix(".mov.cutdb").exists())
            self.assertFalse(output.exists())

    def test_mix_silence_requires_all_lanes_in_each_assembly_occurrence(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "mix.mov"
            project = Path(folder) / "mix.cut"
            wide = "0.25*sin(2*PI*440*t)*(lt(t,1)+gte(t,4))"
            guest = "0.25*sin(2*PI*880*t)*(lt(t,2)+gte(t,5))"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=64x64:r=25:d=6",
                            "-f", "lavfi", "-i", f"aevalsrc='{wide}':s=48000:d=6",
                            "-f", "lavfi", "-i", f"aevalsrc='{guest}':s=48000:d=6",
                            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264",
                            "-g", "25", "-bf", "0", "-c:a", "pcm_s16le", source], check=True, timeout=30)
            project.write_text(json.dumps({
                "format": "mpcut", "schema_version": 4, "kind": "multicam", "reference_angle_id": "a",
                "group_range": {"from": "0", "to": "6"},
                "angles": [{"id": "a", "file": source.name, "audio_stream_index": 1}],
                "audio": {"mode": "mix"},
                "mix_lanes": [
                    {"id": "wide", "target": {"kind": "recording", "source_id": "a", "audio_stream_index": 1},
                     "label": "Wide", "color_slot": 0},
                    {"id": "guest", "target": {"kind": "recording", "source_id": "a", "audio_stream_index": 2},
                     "label": "Guest", "color_slot": 1},
                ],
                "switches": [{"group_time": "0", "angle_id": "a"}],
                "assembly": [{"from": "3", "to": "6"}, {"from": "0", "to": "6"}],
            }))
            report = self.cli("--project", project, "--threshold-db", "-45", "--min-pause-seconds", "0.5",
                              "--max-blip-seconds", "0", "--no-sidecar")
            self.assertEqual(self.intervals(report, "pauses"), [(0, 3, 4, 0, 1), (1, 2, 4, 5, 7)])
            self.assertEqual(sorted(track["audio_stream_index"] for track in report["thresholds"]), [1, 2])

    def test_max_blip_file_project_cache_and_replay(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "blip.mov"
            project = Path(folder) / "blip.cut"
            signal = "0.25*sin(2*PI*440*t)*gte(t,1)*lt(t,1.30)"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=64x64:r=25:d=3",
                            "-f", "lavfi", "-i", f"aevalsrc='{signal}':s=48000:d=3",
                            "-c:v", "libx264", "-c:a", "pcm_s16le", source], check=True, timeout=30)
            project.write_text(json.dumps({
                "format": "mpcut", "schema_version": 3, "kind": "multicam", "reference_angle_id": "a",
                "group_range": {"from": "0", "to": "3"},
                "angles": [{"id": "a", "file": source.name, "audio_stream_index": 1}],
                "audio": {"mode": "follow"}, "switches": [{"group_time": "0", "angle_id": "a"}],
            }))
            settings = ("--min-pause-seconds", "0.5", "--threshold-db", "-40")
            split = [(0, 1), (Fraction(13, 10), 3)]
            for limit in [0.30, 0, 1, 0.29, None, 0.30]:
                options = (*settings, "--max-blip-seconds", str(limit)) if limit is not None else settings
                expected = [(0, 3)] if limit in (0.30, 1) else split
                single = self.cli(*options, source)
                routed = self.cli(*options, "--project", project)
                self.assertEqual(spans(single, "pauses"), expected)
                self.assertEqual([(start, end) for _, start, end, _, _ in self.intervals(routed, "pauses")], expected)
                for report in [single, routed]:
                    self.assertEqual(report["max_blip_seconds"], 0.06 if limit is None else limit)
            self.assertEqual(self.cli("--stdin", report=single), single)
            legacy = self.cli(*settings, source)
            del legacy["max_blip_seconds"]
            self.assertEqual(self.cli("--stdin", report=legacy, success=False)["error"]["code"], "invalid_json")
            self.assertEqual(self.cli("--stdin", "--max-blip-seconds", "0.3", report=single, success=False)["error"]["code"],
                             "invalid_arguments")
            for invalid in ["-0.01", "1.01", "nan", "inf", "missing"]:
                self.assertEqual(self.cli("--max-blip-seconds", invalid, source, success=False)["error"]["code"],
                                 "invalid_arguments")

    def test_project_checks_blip_context_after_routing_the_microphones(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "blips.mov"
            project = Path(folder) / "blips.cut"
            blip = "0.25*sin(2*PI*440*t)*gte(t,1.5)*lt(t,1.54)"
            speech = "0.25*sin(2*PI*880*t)*gte(t,1.54)"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=64x64:r=25:d=3",
                            "-f", "lavfi", "-i", f"aevalsrc='{blip}':s=48000:d=3",
                            "-f", "lavfi", "-i", f"aevalsrc='{speech}':s=48000:d=3",
                            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono:d=3",
                            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:a",
                            "-c:v", "libx264", "-g", "25", "-bf", "0", "-c:a", "pcm_s16le", source],
                           check=True, timeout=30)
            document = {
                "format": "mpcut", "schema_version": 3, "kind": "multicam", "reference_angle_id": "a",
                "group_range": {"from": "0", "to": "3"},
                "angles": [{"id": "a", "file": source.name, "audio_stream_index": 1}],
                "audio": {"mode": "follow"},
                "switches": [{"group_time": "0", "angle_id": "a"},
                             {"group_time": "1.54", "angle_id": "a", "audio": {"source_id": "a", "audio_stream_index": 2}}],
            }
            args = ("--project", project, "--threshold-db", "-45", "--min-pause-seconds", "0.5")
            project.write_text(json.dumps(document))
            report = self.cli(*args)
            self.assertEqual(self.intervals(report, "pauses"), [(0, 0, Fraction(3, 2), 0, Fraction(3, 2))])
            self.assertEqual(self.cli(*args)["pauses"], report["pauses"])

            document["switches"][1]["audio"]["audio_stream_index"] = 3
            project.write_text(json.dumps(document))
            isolated = self.cli(*args)
            self.assertEqual(self.intervals(isolated, "pauses"), [(0, 0, 3, 0, 3)])

            document["assembly"] = [{"from": "1.5", "to": "3"}, {"from": "0", "to": "3"}]
            project.write_text(json.dumps(document))
            repeated = self.cli(*args)
            self.assertEqual(self.intervals(repeated, "pauses"), [
                (0, Fraction(77, 50), 3, Fraction(1, 25), Fraction(3, 2)),
                (1, 0, 3, Fraction(3, 2), Fraction(9, 2)),
            ])

    def test_project_uncovered_audio_is_not_silence(self):
        project = self.source.parent / "partial-coverage.cut"
        self.project(project, audio={"mode": "fixed", "source_id": "recorder", "audio_stream_index": 1},
                     switches=[{"group_time": "0", "angle_id": "a"}])
        document = read_project(project)
        document["audio_sources"][0]["offset"] = "2"
        project.write_text(json.dumps(document))
        args = ("--project", project, "--threshold-db", "-40", "--no-sidecar")
        report = self.cli(*args)
        self.assertEqual(self.intervals(report, "pauses"), [(0, 3, 6, 3, 6)])
        self.assertEqual(self.intervals(report, "clips")[0][:2], (0, 0))
        output = self.source.parent / "partial-coverage.mov"
        failure = self.cli(*args, "--output", output, "--dry-run", success=False)
        self.assertEqual(failure["error"]["code"], "uncovered_audio")
        self.assertFalse(output.exists())

    def test_project_cuts_fit_both_fractional_picture_and_sound_grids(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "fractional.mov"
            project = Path(folder) / "fractional.cut"
            tone = "0.25*sin(2*PI*440*t)*if(between(t,1,5),0,1)"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=320x96:r=30000/1001:d=6.006",
                            "-f", "lavfi", "-i", f"aevalsrc='{tone}':s=48000:d=6.006",
                            "-c:v", "libx264", "-g", "30", "-bf", "0", "-c:a", "pcm_s16le", source],
                           check=True, timeout=30)
            project.write_text(json.dumps({
                "format": "mpcut", "schema_version": 3, "kind": "multicam", "reference_angle_id": "a",
                "group_range": {"from": "0", "to": "6.006"},
                "angles": [{"id": "a", "file": source.name, "audio_stream_index": 1}],
                "audio": {"mode": "follow"}, "switches": [{"group_time": "0", "angle_id": "a"}],
            }))
            report = self.cli("--project", project, "--threshold-db", "-40", "--no-sidecar",
                              "--output", Path(folder) / "shortened.mov", "--dry-run")
            self.assertEqual(len(report["removals"]), 1)
            start, end = self.intervals(report, "removals")[0][1:3]
            self.assertEqual((start, end), (Fraction(1001, 750), Fraction(14014, 3000)))
            for cut in (start, end):
                self.assertEqual((cut * Fraction(30000, 1001)).denominator, 1)
                self.assertEqual((cut * 48000).denominator, 1)

    def test_peak_and_signed_waveforms_share_the_coarse_container_clock(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "impulse.mkv"
            # Sample 2879 is one sample before 60 ms. The containing block is
            # timestamped 43 ms on Matroska's millisecond clock (actual 42 2/3).
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=16x16:r=25:d=1",
                            "-f", "lavfi", "-i", "aevalsrc='if(eq(n,2879),0.8,0)':s=48000:d=1",
                            "-c:v", "libx264", "-c:a", "pcm_s16le", source], check=True, timeout=30)
            peaks = self.cli("--waveform", "50", source)["waveform_peak_dbfs"]
            self.assertEqual([i for i, db in enumerate(peaks) if db > -60], [2])
            detail = json.loads(subprocess.check_output([CLI, "waveform", "envelope", "read", "--json", "--columns", "50", source], timeout=30))
            self.assertEqual([i for i, value in enumerate(detail["envelope"]["high"]) if value > 0], [2])

    def test_stereo_track_threshold_minimum_and_waveform(self):
        data = self.cli("--waveform", "6", self.source)
        self.assertEqual(data["threshold_mode"], "auto")
        self.assertEqual(spans(data, "pauses"), [(1, 5)])
        self.assertEqual(spans(data, "removals"), [(Fraction(6, 5), Fraction(24, 5))])
        self.assertEqual(data["waveform_peak_dbfs"][1:5], [-120] * 4)
        self.assertAlmostEqual(data["waveform_peak_dbfs"][0], -12.0412, places=3)
        self.assertEqual(data["detection_audio_stream_index"], 1)
        self.assertEqual(self.cli("--stream", "2", self.source)["pauses"], [])
        self.assertEqual(self.cli("--min-pause-seconds", "4.1", self.source)["pauses"], [])
        manual = self.cli("--threshold-db", "-10", self.source)
        self.assertEqual(manual["threshold_mode"], "manual")
        self.assertEqual(manual["threshold_db"], -10)
        self.assertEqual(spans(manual, "pauses"), [(0, 6)])
        self.assertEqual(self.cli("--min-pause-seconds", "nan", self.source, success=False)["error"]["code"], "invalid_arguments")
        self.assertEqual(self.cli("--stream", "0", self.source, success=False)["error"]["code"], "no_audio")

    def test_replaying_audio_report_to_video_clamps_pauses_to_picture_end(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "longer-audio.mov"
            output = Path(folder) / "picture.mov"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=64x64:r=25:d=2",
                            "-f", "lavfi", "-i", "aevalsrc='0.3*sin(2*PI*440*t)*lt(t,1)':s=48000:d=4",
                            "-c:v", "libx264", "-g", "25", "-sc_threshold", "0", "-bf", "0",
                            "-c:a", "pcm_s16le", source], check=True, timeout=30)
            report = self.cli("--tracks", "audio", "--audio-stream", "1", "--min-pause-seconds", "0.5", "--padding-per-side-seconds", "0", source)
            self.assertEqual(spans(report, "pauses"), [(1, 4)])
            dry = self.cli("--stdin", "--tracks", "video", "--output", output, "--dry-run", report=report)
            self.assertEqual(dry["tracks"], "video")
            self.assertEqual(spans(dry, "segments"), [(0, 1)])
            self.assertFalse(output.exists())

    def test_per_track_calibration_ignores_an_isolated_click_and_keeps_sustained_sound(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "Different rooms.mov"
            # Both tracks carry identical foreground: a 20 ms click at 2 s and
            # a sustained 240 ms tone at 4 s. Track 2 also has a steady hum.
            active = "(lt(t,1)+between(n,96000,96959)+between(n,192000,203519)+gte(t,7))"
            foreground = f"0.3*sin(2*PI*440*t)*{active}"
            hum = "0.035*sin(2*PI*100*t)+0.005*sin(2*PI*900*t)"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=320x96:r=25:d=8",
                            "-f", "lavfi", "-i", f"aevalsrc='{foreground}':s=48000:d=8",
                            "-f", "lavfi", "-i", f"aevalsrc='{foreground}+{hum}':s=48000:d=8",
                            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264",
                            "-g", "25", "-bf", "0", "-c:a", "pcm_s16le", source], check=True, timeout=120)
            clean = self.cli(source)
            noisy = self.cli("--stream", "2", source)
            self.assertGreater(noisy["threshold_db"], clean["threshold_db"])
            for report in (clean, noisy):
                self.assertEqual(report["threshold_mode"], "auto")
                self.assertEqual(spans(report, "pauses"), [(1, 4), (Fraction(106, 25), 7)])
                self.assertEqual(len(report["removals"]), 2)
            manual = self.cli("--stream", "2", "--threshold-db", "-40", source)
            self.assertEqual(manual["pauses"], [])

            separate = Path(temp) / "Noisy room.mov"
            subprocess.run(["ffmpeg", "-v", "error", "-i", source, "-map", "0:v:0", "-map", "0:a:1",
                            "-c", "copy", separate], check=True, timeout=120)
            separate_report = self.cli(separate)
            self.assertEqual(separate_report["threshold_db"], noisy["threshold_db"])
            self.assertEqual(separate_report["pauses"], noisy["pauses"])

    def test_sparse_foreground_calibrates_against_high_room_floor(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "Sparse speech.mov"
            # One second of foreground in a 20 s take, with low-level room tone
            # during the first second and a steady louder hum thereafter.
            levels = "0.3*between(t,10,11)+if(lt(t,1),0.0003,0.03)"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=320x96:r=25:d=20",
                            "-f", "lavfi", "-i", f"aevalsrc='sin(2*PI*440*t)*({levels})':s=48000:d=20",
                            "-c:v", "libx264", "-c:a", "pcm_s16le", source], check=True, timeout=120)
            data = self.cli(source)
            self.assertEqual(spans(data, "pauses"), [(0, 10), (11, 20)])
            self.assertGreater(data["threshold_db"], -31)
            self.assertLess(data["threshold_db"], -16)

    def test_report_reuses_its_original_threshold_and_ranges(self):
        legacy = self.cli("--threshold-db", "-40", self.source)
        # Existing agents can protect part of a pause by editing the report.
        legacy["pauses"][0]["to"] = {"numerator": 3, "denominator": 1}
        replay = self.cli("--stdin", report=legacy)
        self.assertEqual(replay["threshold_mode"], "manual")
        self.assertEqual(replay["threshold_db"], -40)
        self.assertEqual(spans(replay, "pauses"), [(1, 3)])

    def test_calibration_on_digital_silence(self):
        with tempfile.TemporaryDirectory() as temp:
            silent = Path(temp) / "Silent.mov"
            subprocess.run(["ffmpeg", "-v", "error", "-i", self.source, "-map", "0:v", "-map", "0:a:0",
                            "-c:v", "copy", "-af", "volume=0", "-c:a", "pcm_s16le", silent], check=True, timeout=120)
            report = self.cli(silent)
            self.assertEqual(report["threshold_mode"], "auto")
            self.assertTrue(-120 <= report["threshold_db"] <= 0)
            self.assertEqual(spans(report, "pauses"), [(0, 6)])

    def test_transient_guardrails_and_raw_waveform(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "Short sounds.mov"
            # Each bin is 20 ms. Cover a file-edge click, another 80 ms
            # before sustained sound, closely spaced clicks, an 80 ms burst,
            # one isolated click surrounded by quiet, and a final click.
            bursts = [(0, 1), (100, 101), (105, 125), (160, 161), (165, 166),
                      (225, 229), (280, 281), (299, 300)]
            active = "+".join(f"between(n,{start*960},{end*960-1})" for start, end in bursts)
            audio = f"aevalsrc='0.3*sin(2*PI*440*t)*({active})':s=48000:d=6"
            subprocess.run(["ffmpeg", "-v", "error", "-i", self.source, "-f", "lavfi", "-i", audio,
                            "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "pcm_s16le", source],
                           check=True, timeout=120)
            report = self.cli("--min-pause-seconds", "0.04", "--waveform", "300", source)
            self.assertEqual([(a*50, b*50) for a, b in spans(report, "pauses")],
                             [(1, 100), (101, 105), (125, 160), (161, 165), (166, 225), (229, 299)])
            levels = report["waveform_peak_dbfs"]
            self.assertEqual(levels[279], -120)
            self.assertAlmostEqual(levels[280], -10.46, places=2)
            self.assertEqual(levels[281], -120)

    def test_replay_preflight_real_join_and_pcm(self):
        with tempfile.TemporaryDirectory() as temp:
            for mode, duration in [("smart", Fraction(12, 5)), ("copy", 4)]:
                data = self.cli("--mode", mode, self.source)
                path = Path(temp) / f"{mode}.mov"
                args = ["--stdin", "--output", path]
                dry = self.cli(*args, "--dry-run", report=data)
                self.assertFalse(path.exists())
                export = self.cli(*args, report=data)
                self.assertEqual(export["segments"], dry["segments"])
                self.assertEqual(export["mode"], mode)
                self.assertEqual(seconds(export["duration"]), duration)
                self.assertEqual(export["silence"]["shortened_pauses"], 1)
                self.assertEqual(export["silence"]["threshold_mode"], data["threshold_mode"])
                self.assertEqual(export["silence"]["threshold_db"], data["threshold_db"])
                self.assertEqual(seconds(export["encoded_duration"]) == 0, mode == "copy")
                for stream, channels in [("a:0", 2), ("a:1", 1)]:
                    def pcm(file):
                        return subprocess.check_output(["ffmpeg", "-v", "error", "-i", file, "-map", "0:" + stream,
                                                        "-f", "s16le", "-"], timeout=120)
                    source = pcm(self.source)
                    stride = channels * 2
                    expected = b"".join(source[int(a*48000)*stride:int(b*48000)*stride] for a,b in spans(data, "clips"))
                    self.assertEqual(pcm(path), expected)
                self.assertEqual(self.cli(*args, report=data, success=False)["error"]["code"], "output_exists")

    def test_unusable_pause_and_stale_report(self):
        data = self.cli("--mode", "copy", "--padding-per-side-seconds", "1.95", self.source)
        self.assertEqual(data["skipped_pauses"], 1)
        self.assertEqual(spans(data, "clips"), [(0, 6)])
        data["source_stamp"]["bytes"] += 1
        self.assertEqual(self.cli("--stdin", report=data, success=False)["error"]["code"], "source_changed")

    def test_default_smart_uses_copy_points_when_edges_cannot_be_encoded(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "Narrow.mov"
            output = Path(temp) / "Edited.mov"
            # The hardware H.264 edge encoder cannot match this coded width.
            subprocess.run(["ffmpeg", "-v", "error", "-i", self.source, "-map", "0",
                            "-vf", "scale=160:96", "-c:v", "libx264", "-g", "25", "-bf", "0",
                            "-c:a", "copy", source], check=True, timeout=120)
            data = self.cli(source)
            self.assertEqual(data["mode"], "smart")
            self.assertEqual(spans(data, "pauses"), [(1, 5)])
            self.assertEqual(spans(data, "removals"), [(2, 4)])
            export = self.cli("--stdin", "--output", output, report=data)
            self.assertEqual(spans(export, "segments"), spans(data, "clips"))
            self.assertEqual(seconds(export["encoded_duration"]), 0)

    def test_smart_respects_linked_track_that_cannot_join(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "Linked.mov"
            subprocess.run(["ffmpeg", "-v", "error", "-i", self.source, "-map", "0", "-c", "copy",
                            "-c:a:1", "ac3", source], check=True, timeout=120)
            data = self.cli(source)
            self.assertEqual(spans(data, "pauses"), [(1, 5)])
            self.assertEqual(spans(data, "clips"), [(0, 6)])
            self.assertEqual(data["skipped_pauses"], 1)
            export = self.cli("--stdin", "--output", Path(temp) / "joined.mov", "--dry-run", report=data)
            self.assertEqual(spans(export, "segments"), [(0, 6)])

    def test_source_edge_copy_trims_and_empty_output(self):
        data = self.cli("--threshold-db", "0", "--mode", "copy", "--padding-per-side-seconds", "0", self.source)
        self.assertEqual(spans(data, "removals"), [(0, 6)])
        self.assertEqual(data["clips"], [])
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "trim.MOV"
            self.assertEqual(self.cli("--stdin", "--output", out, report=data, success=False)["error"]["code"], "empty_edit")
            self.assertFalse(out.exists())

            # Model an agent protecting the middle of an otherwise quiet clip.
            def time(n):
                return {"numerator": n, "denominator": 1}
            data["pauses"] = [{"from": time(0), "to": time(2)}, {"from": time(4), "to": time(6)}]
            self.assertEqual(spans(self.cli("--stdin", report=data), "clips"), [(2, 4)])
            export = self.cli("--stdin", "--output", out, report=data)
            self.assertEqual(spans(export, "segments"), [(2, 4)])
            self.assertEqual(seconds(export["encoded_duration"]), 0)

    def test_replay_rejects_out_of_bounds_overlapping_and_failed_reports(self):
        data = self.cli(self.source)
        for malformed in [
            {**data, "ok": False},
            {**data, "min_pause_seconds": -1},
            {**data, "pauses": data["pauses"] * 2},
            {**data, "pauses": [{"from": data["duration"], "to": data["duration"]}]},
        ]:
            self.assertEqual(self.cli("--stdin", report=malformed, success=False)["error"]["code"], "invalid_json")

    def test_single_continuous_opus_range_can_trim_both_exteriors(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "Opus.webm"
            output = Path(temp) / "trim.webm"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=320x96:r=25:d=6",
                            "-f", "lavfi", "-i", "aevalsrc='sin(2*PI*440*t)*if(between(t,1.8,4.2),0.25,0)':s=48000:d=6",
                            "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-lag-in-frames", "0",
                            "-g", "25", "-c:a", "libopus", source], check=True, timeout=120)
            result = self.cli("--mode", "copy", "--padding-per-side-seconds", "0", "--min-pause-seconds", "1", "--output", output, source)
            self.assertEqual(spans(result, "segments"), [(1, 5)])
            self.assertEqual(result["silence"]["shortened_pauses"], 2)
            self.assertEqual(seconds(result["encoded_duration"]), 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
