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
        result = subprocess.run([CLI, "silence", "--json", *args], input=json.dumps(report) if report else None,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def project(self, location, *, audio, switches, assembly=None):
        doc = {
            "format": "mpcut", "schemaVersion": 1, "kind": "multicam", "referenceAngle": "a",
            "range": {"from": "0", "to": "6"},
            "angles": [
                {"id": "a", "file": self.source.name, "audioStream": 1},
                {"id": "b", "file": self.source.name, "offset": "1", "audioStream": 2},
            ],
            "audioSources": [{"id": "recorder", "file": self.source.name, "offset": "0.5"}],
            "audio": audio, "switches": switches,
        }
        if assembly is not None:
            doc["assembly"] = [{"from": str(start), "to": str(end)} for start, end in assembly]
        location.write_text(json.dumps(doc))

    def intervals(self, report, key):
        return [(item["assemblyIndex"], seconds(item["group"]["from"]), seconds(item["group"]["to"]),
                 seconds(item["output"]["from"]), seconds(item["output"]["to"])) for item in report[key]]

    def test_project_repeated_fixed_audio_report_dry_run_and_export(self):
        project = self.source.parent / "repeated.cut"
        self.project(project, audio={"mode": "fixed", "source": "a", "stream": 1},
                     switches=[{"at": "0", "angle": "a"}, {"at": "4", "angle": "b"}],
                     assembly=[(4, 6), (0, 3), (4, 6)])
        project_before = project.read_bytes()
        args = ("--project", project, "--min-pause", "0.5")
        report = self.cli(*args)
        self.assertEqual(report["thresholdMode"], "auto")
        self.assertEqual([(item["source"], item["stream"]) for item in report["thresholds"]], [("a", 1)])
        self.assertEqual(self.intervals(report, "pauses"), [(0, 4, 5, 0, 1), (1, 1, 3, 3, 5), (2, 4, 5, 5, 6)])
        self.assertEqual(self.intervals(report, "removals"), [
            (0, Fraction(21, 5), Fraction(24, 5), Fraction(1, 5), Fraction(4, 5)),
            (1, Fraction(6, 5), Fraction(14, 5), Fraction(16, 5), Fraction(24, 5)),
            (2, Fraction(21, 5), Fraction(24, 5), Fraction(26, 5), Fraction(29, 5)),
        ])
        self.assertEqual(seconds(report["removedDuration"]), Fraction(14, 5))
        output = self.source.parent / "repeated.mov"
        dry = self.cli(*args, "--output", output, "--dry-run")
        self.assertEqual(dry["clips"], report["clips"])
        self.assertTrue(dry["dryRun"])
        self.assertFalse(output.exists())
        exported = self.cli(*args, "--output", output)
        self.assertFalse(exported["dryRun"])
        self.assertTrue(output.exists())
        self.assertEqual(seconds(exported["preflight"]["duration"]), Fraction(21, 5))
        self.assertEqual({span["source"] for span in exported["preflight"]["mapping"]["picture"]}, {"a", "b"})
        self.assertEqual({span["source"] for span in exported["preflight"]["mapping"]["audio"]}, {"a"})
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
        self.assertEqual(copy["skippedPauses"], 3)
        self.assertEqual(seconds(copy["preflight"]["duration"]), 7)
        self.assertEqual(project.read_bytes(), project_before)

    def test_project_follow_and_override_use_offsets_and_absolute_streams(self):
        project = self.source.parent / "follow.cut"
        switches = [{"at": "0", "angle": "a"}, {"at": "3", "angle": "b"}]
        self.project(project, audio={"mode": "follow"}, switches=switches)
        report = self.cli("--project", project, "--threshold-db", "-40", "--no-sidecar")
        self.assertEqual(report["thresholdMode"], "manual")
        self.assertEqual([(item["source"], item["stream"]) for item in report["thresholds"]], [("a", 1), ("b", 2)])
        self.assertEqual(self.intervals(report, "pauses"), [(0, 1, 3, 1, 3)])
        switches[1]["audio"] = {"source": "recorder", "stream": 1}
        switches.append({"at": "4", "angle": "b"})
        self.project(project, audio={"mode": "follow"}, switches=switches)
        report = self.cli("--project", project, "--threshold-db", "-40", "--no-sidecar")
        self.assertEqual(self.intervals(report, "pauses"), [(0, 1, 4, 1, 4)])
        self.assertEqual([(item["source"], item["stream"]) for item in report["thresholds"]],
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
            self.project(project, audio={"mode": "follow"}, switches=[{"at": "0", "angle": "a"}])
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
            self.project(project, audio={"mode": "fixed", "source": "z", "stream": 0},
                         switches=[{"at": "0", "angle": "a"}])
            document = json.loads(project.read_text())
            document["audioSources"] = [{"id": "z", "file": audio.name}]
            project.write_text(json.dumps(document))
            output = folder / "shortened.mov"
            args = [] if change_source else ["--output", output]
            with subprocess.Popen([CLI, "silence", "--json", "--project", project, *args],
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
                "format": "mpcut", "schemaVersion": 1, "kind": "multicam", "referenceAngle": "a",
                "range": {"from": "0", "to": "6"},
                "angles": [{"id": "a", "file": source.name, "audioStream": 1}],
                "audio": {"mode": "follow"},
                "switches": [{"at": "0", "angle": "a"},
                             {"at": "3", "angle": "a", "audio": {"source": "a", "stream": 2}}],
            }))
            output = Path(folder) / "shortened.mov"
            report = self.cli("--project", project, "--min-pause", "3", "--leave", "0", "--no-sidecar",
                              "--output", output, "--dry-run")
            self.assertEqual(self.intervals(report, "pauses"), [(0, 1, 5, 1, 5)])
            self.assertEqual(self.intervals(report, "removals"), [(0, 1, 5, 1, 5)])
            self.assertEqual([span["stream"] for span in report["preflight"]["mapping"]["audio"]], [1, 2])
            self.assertFalse(source.with_suffix(".mov.cutdb").exists())
            self.assertFalse(output.exists())

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
                "format": "mpcut", "schemaVersion": 1, "kind": "multicam", "referenceAngle": "a",
                "range": {"from": "0", "to": "3"},
                "angles": [{"id": "a", "file": source.name, "audioStream": 1}],
                "audio": {"mode": "follow"},
                "switches": [{"at": "0", "angle": "a"},
                             {"at": "1.54", "angle": "a", "audio": {"source": "a", "stream": 2}}],
            }
            args = ("--project", project, "--threshold-db", "-45", "--min-pause", "0.5")
            project.write_text(json.dumps(document))
            report = self.cli(*args)
            self.assertEqual(self.intervals(report, "pauses"), [(0, 0, Fraction(3, 2), 0, Fraction(3, 2))])
            self.assertEqual(self.cli(*args)["pauses"], report["pauses"])

            document["switches"][1]["audio"]["stream"] = 3
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
        self.project(project, audio={"mode": "fixed", "source": "recorder", "stream": 1},
                     switches=[{"at": "0", "angle": "a"}])
        document = json.loads(project.read_text())
        document["audioSources"][0]["offset"] = "2"
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
                "format": "mpcut", "schemaVersion": 1, "kind": "multicam", "referenceAngle": "a",
                "range": {"from": "0", "to": "6.006"},
                "angles": [{"id": "a", "file": source.name, "audioStream": 1}],
                "audio": {"mode": "follow"}, "switches": [{"at": "0", "angle": "a"}],
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
            peaks = self.cli("--waveform", "50", source)["waveformPeakDBFS"]
            self.assertEqual([i for i, db in enumerate(peaks) if db > -60], [2])
            detail = json.loads(subprocess.check_output([CLI, "waveform", "--json", "--columns", "50", source], timeout=30))
            self.assertEqual([i for i, value in enumerate(detail["envelope"]["high"]) if value > 0], [2])

    def test_stereo_track_threshold_minimum_and_waveform(self):
        data = self.cli("--waveform", "6", self.source)
        self.assertEqual(data["thresholdMode"], "auto")
        self.assertEqual(spans(data, "pauses"), [(1, 5)])
        self.assertEqual(spans(data, "removals"), [(Fraction(6, 5), Fraction(24, 5))])
        self.assertEqual(data["waveformPeakDBFS"][1:5], [-120] * 4)
        self.assertAlmostEqual(data["waveformPeakDBFS"][0], -12.0412, places=3)
        self.assertEqual(data["stream"], 1)
        self.assertEqual(self.cli("--stream", "2", self.source)["pauses"], [])
        self.assertEqual(self.cli("--min-pause", "4.1", self.source)["pauses"], [])
        manual = self.cli("--threshold-db", "-10", self.source)
        self.assertEqual(manual["thresholdMode"], "manual")
        self.assertEqual(manual["thresholdDB"], -10)
        self.assertEqual(spans(manual, "pauses"), [(0, 6)])
        self.assertEqual(self.cli("--min-pause", "nan", self.source, success=False)["error"]["code"], "invalid_arguments")
        self.assertEqual(self.cli("--stream", "0", self.source, success=False)["error"]["code"], "no_audio")

    def test_replaying_audio_report_to_video_clamps_pauses_to_picture_end(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "longer-audio.mov"
            output = Path(folder) / "picture.mov"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=64x64:r=25:d=2",
                            "-f", "lavfi", "-i", "aevalsrc='0.3*sin(2*PI*440*t)*lt(t,1)':s=48000:d=4",
                            "-c:v", "libx264", "-g", "25", "-sc_threshold", "0", "-bf", "0",
                            "-c:a", "pcm_s16le", source], check=True, timeout=30)
            report = self.cli("--tracks", "audio", "--audio-stream", "1", "--min-pause", "0.5", "--leave", "0", source)
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
            self.assertGreater(noisy["thresholdDB"], clean["thresholdDB"])
            for report in (clean, noisy):
                self.assertEqual(report["thresholdMode"], "auto")
                self.assertEqual(spans(report, "pauses"), [(1, 4), (Fraction(106, 25), 7)])
                self.assertEqual(len(report["removals"]), 2)
            manual = self.cli("--stream", "2", "--threshold-db", "-40", source)
            self.assertEqual(manual["pauses"], [])

            separate = Path(temp) / "Noisy room.mov"
            subprocess.run(["ffmpeg", "-v", "error", "-i", source, "-map", "0:v:0", "-map", "0:a:1",
                            "-c", "copy", separate], check=True, timeout=120)
            separate_report = self.cli(separate)
            self.assertEqual(separate_report["thresholdDB"], noisy["thresholdDB"])
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
            self.assertGreater(data["thresholdDB"], -31)
            self.assertLess(data["thresholdDB"], -16)

    def test_legacy_report_reuses_its_original_threshold_and_ranges(self):
        legacy = self.cli("--threshold-db", "-40", self.source)
        del legacy["thresholdMode"]
        # Existing agents can protect part of a pause by editing the report.
        legacy["pauses"][0]["to"] = {"numerator": 3, "denominator": 1}
        replay = self.cli("--stdin", report=legacy)
        self.assertEqual(replay["thresholdMode"], "manual")
        self.assertEqual(replay["thresholdDB"], -40)
        self.assertEqual(spans(replay, "pauses"), [(1, 3)])

    def test_calibration_on_digital_silence(self):
        with tempfile.TemporaryDirectory() as temp:
            silent = Path(temp) / "Silent.mov"
            subprocess.run(["ffmpeg", "-v", "error", "-i", self.source, "-map", "0:v", "-map", "0:a:0",
                            "-c:v", "copy", "-af", "volume=0", "-c:a", "pcm_s16le", silent], check=True, timeout=120)
            report = self.cli(silent)
            self.assertEqual(report["thresholdMode"], "auto")
            self.assertTrue(-120 <= report["thresholdDB"] <= 0)
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
            report = self.cli("--min-pause", "0.04", "--waveform", "300", source)
            self.assertEqual([(a*50, b*50) for a, b in spans(report, "pauses")],
                             [(1, 100), (101, 105), (125, 160), (161, 165), (166, 225), (229, 299)])
            levels = report["waveformPeakDBFS"]
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
                self.assertEqual(export["silence"]["shortenedPauses"], 1)
                self.assertEqual(export["silence"]["thresholdMode"], data["thresholdMode"])
                self.assertEqual(export["silence"]["thresholdDB"], data["thresholdDB"])
                self.assertEqual(seconds(export["encodedDuration"]) == 0, mode == "copy")
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
        data = self.cli("--mode", "copy", "--leave", "3.9", self.source)
        self.assertEqual(data["skippedPauses"], 1)
        self.assertEqual(spans(data, "clips"), [(0, 6)])
        data["sourceStamp"]["bytes"] += 1
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
            self.assertEqual(seconds(export["encodedDuration"]), 0)

    def test_smart_respects_linked_track_that_cannot_join(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "Linked.mov"
            subprocess.run(["ffmpeg", "-v", "error", "-i", self.source, "-map", "0", "-c", "copy",
                            "-c:a:1", "ac3", source], check=True, timeout=120)
            data = self.cli(source)
            self.assertEqual(spans(data, "pauses"), [(1, 5)])
            self.assertEqual(spans(data, "clips"), [(0, 6)])
            self.assertEqual(data["skippedPauses"], 1)
            export = self.cli("--stdin", "--output", Path(temp) / "joined.mov", "--dry-run", report=data)
            self.assertEqual(spans(export, "segments"), [(0, 6)])

    def test_source_edge_copy_trims_and_empty_output(self):
        data = self.cli("--threshold-db", "0", "--mode", "copy", "--leave", "0", self.source)
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
            self.assertEqual(seconds(export["encodedDuration"]), 0)

    def test_replay_rejects_out_of_bounds_overlapping_and_failed_reports(self):
        data = self.cli(self.source)
        for malformed in [
            {**data, "ok": False},
            {**data, "minimumPause": -1},
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
            result = self.cli("--mode", "copy", "--leave", "0", "--min-pause", "1", "--output", output, source)
            self.assertEqual(spans(result, "segments"), [(1, 5)])
            self.assertEqual(result["silence"]["shortenedPauses"], 2)
            self.assertEqual(seconds(result["encodedDuration"]), 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
