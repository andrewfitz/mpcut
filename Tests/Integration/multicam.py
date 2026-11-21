#!/usr/bin/env python3
"""Exercise multicam project inspection, planning, and export with real media."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import audio, ffmpeg, frames, probe, ratio, run, sample_hashes, timestamped_hashes
from smart_trim import picture_ids, vcl_hashes

RATE = 48_000
FPS = 25
CLI = None


def camera(path, *, marker_base, frequency, rate=FPS, gop=FPS, length="4",
           audio_codec="pcm_s16le", delay=None, extra_audio=False):
    # Encode the camera and frame identity in luma so it survives Smart Trim.
    marker = ("geq=lum='if(lt(Y,16)*lt(X,128),"
              f"if(bitand(N+{marker_base},pow(2,floor(X/16))),210,32),lum(X,Y))'")
    audio_input = ["-itsoffset", delay] if delay is not None else []
    audio_input += ["-f", "lavfi", "-i",
                    f"aevalsrc=0.15*sin(2*PI*({frequency}*t+31*t*t)):s={RATE}:d={length}"]
    if extra_audio:
        audio_input += ["-f", "lavfi", "-i", f"aevalsrc=0.2*sin(2*PI*217*t):s={RATE}:d={length}"]
    ffmpeg("-f", "lavfi", "-i", f"testsrc2=d={length}:s=320x96:r={rate}",
           *audio_input, "-map", "0:v:0", "-map", "1:a:0",
           *(["-map", "2:a:0"] if extra_audio else []),
           "-vf", marker, "-c:v", "libx264", "-threads", "1",
           "-x264-params", f"keyint={gop}:min-keyint={gop}:scenecut=0:open-gop=0:bframes=0",
           "-color_range", "tv", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
           "-c:a", audio_codec, "-channel_layout:a", "mono", path)
    return path


def wav(path, length):
    ffmpeg("-f", "lavfi", "-i", f"aevalsrc=0.2*sin(2*PI*(349*t+51*t*t)):s={RATE}:d={length}",
           "-c:a", "pcm_s16le", path)
    return path


def pcm_slice(pcm, start, end):
    boundaries = [Fraction(time) * RATE for time in (start, end)]
    if any(sample.denominator != 1 for sample in boundaries):
        raise AssertionError(f"fixture times {start}, {end} are off the sample grid")
    return pcm[int(boundaries[0]) * 2:int(boundaries[1]) * 2]


def rational_time(value):
    return ratio(value) if isinstance(value, dict) else Fraction(value)


def times(span):
    return rational_time(span["from"]), rational_time(span["to"])


class MulticamTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-multicam-")
        cls.addClassCleanup(directory.cleanup)
        cls.fixtures = Path(directory.name)
        cls.wide = camera(cls.fixtures / "wide.mov", marker_base=0, frequency=419, extra_audio=True)
        cls.close = camera(cls.fixtures / "close.mov", marker_base=128, frequency=691, audio_codec="aac")
        cls.pcm_close = camera(cls.fixtures / "pcm-close.mov", marker_base=128, frequency=691, extra_audio=True)
        cls.lav = wav(cls.fixtures / "lav.wav", "4")

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-multicam-output-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        # Run from a different directory to prove that source paths belong to the project.
        self.project_dir = self.root / "project"
        self.project_dir.mkdir()
        self.project_path = self.project_dir / "edit.multicam.json"
        self.output = self.root / "program.mov"

    def project(self, *, close=None, wide=None, lav=None, end="4", offset="0", switches=None, **changes):
        payload = {
            "schemaVersion": 1,
            "kind": "multicam",
            "referenceAngle": "wide",
            "range": {"from": "0", "to": end},
            "angles": [
                {"id": "wide", "file": str(wide or self.wide), "offset": "0", "audioStream": 1},
                {"id": "close", "file": str(close or self.close), "offset": offset, "audioStream": 1},
            ],
            "audioSources": [{"id": "lav", "file": str(lav or self.lav), "offset": "0"}],
            "audio": {"mode": "fixed", "source": "lav", "stream": 0},
            "switches": switches or [{"at": "0", "angle": "wide"}, {"at": "1", "angle": "close"},
                                     {"at": "2", "angle": "wide"}],
        }
        payload.update(changes)
        for source in payload["angles"] + payload["audioSources"]:
            path = Path(source["file"]).resolve()
            link = self.project_dir / path.name
            if not link.exists():
                link.symlink_to(path)
            source["file"] = link.name
        self.project_path.write_text(json.dumps(payload))
        return payload

    def cli(self, *args, request=None, ok=True):
        result = subprocess.run([CLI, *args], input=None if request is None else json.dumps(request),
                                capture_output=True, text=True, cwd=self.root, timeout=90)
        self.assertEqual(result.returncode == 0, ok, result.stderr + result.stdout)
        report = json.loads(result.stdout)
        self.assertIs(report["ok"], ok, report)
        return report

    def export(self, *args, mode="copy", ok=True, output=None):
        return self.cli("export", "--project", self.project_path, "--json", "--mode", mode,
                        "--output", output or self.output, *args, ok=ok)

    def assert_program(self, spans, expected_pcm, *, copy=True):
        sources = {source for source, _, _ in spans}
        ids = {source: picture_ids(source) for source in sources}
        expected_ids = b"".join(ids[source][start:end] for source, start, end in spans)
        self.assertEqual(picture_ids(self.output), expected_ids)
        self.assertEqual(audio(self.output), expected_pcm)
        if copy:
            decoded = {source: frames(source) for source in sources}
            packets = {source: sample_hashes(source) for source in sources}
            expected_frames = [frame for source, start, end in spans for frame in decoded[source][start:end]]
            expected_packets = [packet for source, start, end in spans for packet in packets[source][start:end]]
            self.assertEqual(frames(self.output), expected_frames)
            self.assertEqual(sample_hashes(self.output), expected_packets)

    def test_microphone_only_switch_off_sample_has_two_usable_alternatives(self):
        initial = {"at": "0", "angle": "wide"}
        change = {"at": "48001/96000", "angle": "wide", "audio": {"source": "close", "stream": 1}}
        policy = {"mode": "fixed", "source": "wide", "stream": 1}
        self.project(close=self.pcm_close, audio=policy, switches=[initial, change])
        report = self.export(mode="smart", ok=False)
        self.assertEqual(report["error"]["code"], "unsafe_boundary")
        candidates = [rational_time(value) for value in report["error"]["nearest"]]
        self.assertEqual(candidates, [Fraction(1, 2), Fraction(24001, 48000)])
        for time in candidates:
            self.project(close=self.pcm_close, audio=policy, switches=[initial, {**change, "at": str(time)}])
            planned = self.export("--dry-run", mode="smart")
            self.assertTrue(planned["ok"])
        self.assertFalse(self.output.exists())

    def test_copy_alternatives_validate_ranges_clipped_at_the_original_switch(self):
        wide = self.root / "select-wide.mov"
        close = self.root / "select-close.mov"
        for source, keyframes in [(wide, "0,1,2,3"), (close, "0,1,1.04,2,3")]:
            ffmpeg("-f", "lavfi", "-i", "testsrc2=d=4:s=320x96:r=25", "-c:v", "libx264",
                   "-threads", "1", "-x264-params", "keyint=100:min-keyint=1:scenecut=0:open-gop=0:bframes=0",
                   "-force_key_frames", keyframes, source)
        first = {"at": "0", "angle": "wide"}
        switch = {"at": "1.04", "angle": "close"}
        for outgoing, incoming, clipped, expected in [
            (wide, close, {"from": "1.04", "to": "3"}, 1),
            (close, wide, {"from": "0", "to": "1.04"}, 2),
        ]:
            with self.subTest(clipped=clipped):
                ranges = [{"from": "0", "to": "3"}, clipped]
                payload = self.project(wide=outgoing, close=incoming, audio={"mode": "none"},
                                       switches=[first, dict(switch)], assembly=ranges)
                error = self.export("--dry-run", ok=False)["error"]
                self.assertEqual(error["code"], "unsafe_boundary")
                self.assertEqual([rational_time(value) for value in error["nearest"]], [Fraction(expected)])
                payload["switches"][1]["at"] = str(expected)
                self.project_path.write_text(json.dumps(payload))
                self.export("--dry-run")

    def test_encode_alternatives_validate_all_retained_frame_boundaries(self):
        first = {"at": "0", "angle": "wide"}
        switch = {"at": "1.02", "angle": "close"}
        payload = self.project(close=self.pcm_close, audio={"mode": "none"},
                               switches=[first, switch], assembly=[{"from": "0", "to": "3.02"}])
        error = self.export("--dry-run", mode="encode", ok=False)["error"]
        self.assertEqual(error["code"], "invalid_frame_boundary")
        self.assertEqual(error["nearest"], [])
        payload["assembly"][0]["to"] = "3"
        self.project_path.write_text(json.dumps(payload))
        error = self.export("--dry-run", mode="encode", ok=False)["error"]
        candidates = [rational_time(value) for value in error["nearest"]]
        self.assertEqual(candidates, [Fraction(1), Fraction(26, 25)])
        for candidate in candidates:
            payload["switches"][1]["at"] = str(candidate)
            self.project_path.write_text(json.dumps(payload))
            self.export("--dry-run", mode="encode")

    def test_inspect_reports_gaps_in_partial_soundtrack_overrides(self):
        self.project(audio={"mode": "none"}, switches=[
            {"at": "0", "angle": "wide"},
            {"at": "1", "angle": "wide", "audio": {"source": "lav", "stream": 0}},
        ])
        inspected = self.cli("inspect", "--project", self.project_path, "--json")
        issues = inspected["inspection"]["issues"]
        self.assertEqual([(issue["code"], issue["segment"]) for issue in issues], [("missing_audio", 1)])
        self.assertEqual(self.export("--dry-run", ok=False)["error"]["code"], "missing_audio")
        self.export("--dry-run", "--tracks", "video")

    def test_no_default_soundtrack_exports_picture_without_camera_audio(self):
        self.project(audio={"mode": "none"}, switches=[{"at": "0", "angle": "wide"}])
        inspected = self.cli("inspect", "--project", self.project_path, "--json")["inspection"]
        self.assertEqual(inspected["issues"], [])
        self.assertEqual(inspected["mapping"]["audio"], [])
        self.export()
        streams = probe(self.output, "-show_streams")["streams"]
        self.assertEqual([stream["codec_type"] for stream in streams], ["video"])

    def test_fixed_wav_continues_through_picture_switches(self):
        help_json = subprocess.run([CLI, "help", "multicam", "--json"], check=True,
                                   capture_output=True, text=True, timeout=90)
        template = json.loads(help_json.stdout)["projectTemplate"]
        self.assertEqual((template["schemaVersion"], template["kind"]), (1, "multicam"))
        self.project()
        inspected = self.cli("inspect", "--project", self.project_path, "--json")
        self.assertEqual(Path(inspected["project"]), self.project_path)
        inspection = inspected["inspection"]
        sources = {item["source"]["id"]: item for item in inspection["sources"]}
        self.assertEqual(set(sources), {"wide", "close", "lav"})
        self.assertEqual(times(sources["close"]["coverage"]), (0, 4))
        self.assertEqual(times(sources["lav"]["audioCoverage"]["0"]), (0, 4))
        report = self.export("--dry-run")
        self.assertTrue(report["dryRun"], report)
        plan = report["plan"]
        self.assertEqual([(item["angle"], times(item["group"]), times(item["output"]))
                          for item in plan["intervals"]],
                         [("wide", (0, 1), (0, 1)), ("close", (1, 2), (1, 2)), ("wide", (2, 4), (2, 4))])
        self.assertEqual([(item["source"], item["stream"], times(item["input"]), times(item["output"]))
                          for item in plan["audio"]],
                         [("lav", 0, (0, 4), (0, 4))])
        self.assertEqual(plan, inspection["mapping"])
        self.assertFalse(self.output.exists())
        self.export()
        self.assert_program([(self.wide, 0, 25), (self.close, 25, 50), (self.wide, 50, 100)], audio(self.lav))
        streams = probe(self.output, "-show_streams")["streams"]
        self.assertEqual([stream["codec_name"] for stream in streams], ["h264", "pcm_s16le"])

    def test_follow_camera_with_explicit_override_and_absolute_stream_selection(self):
        self.project(close=self.pcm_close, audio={"mode": "follow"}, switches=[
            {"at": "0", "angle": "wide"},
            {"at": "1", "angle": "close", "audio": {"source": "wide", "stream": 1}},
            {"at": "2", "angle": "close", "audio": {"source": "close", "stream": 2}},
            {"at": "3", "angle": "close"},
        ])
        wide_pcm = audio(self.wide)
        close_mic_two = ffmpeg("-i", self.pcm_close, "-map", "0:2", "-c:a", "pcm_s16le", "-f", "s16le", "-")
        expected = pcm_slice(wide_pcm, 0, 2)
        expected += pcm_slice(close_mic_two, 2, 3)
        expected += pcm_slice(audio(self.pcm_close), 3, 4)
        plan = self.export("--dry-run")["plan"]
        self.assertEqual([(item["source"], item["stream"], times(item["input"])) for item in plan["audio"]],
                         [("wide", 1, (0, 2)), ("close", 2, (2, 3)), ("close", 1, (3, 4))])
        self.export()
        self.assert_program([(self.wide, 0, 25), (self.pcm_close, 25, 100)], expected)

    def test_reordered_repeated_assembly_and_explicit_group_clip(self):
        self.project(assembly=[{"from": "2", "to": "4"}, {"from": "0", "to": "2"},
                               {"from": "1", "to": "2"}])
        lav_pcm = audio(self.lav)
        plan = self.export("--dry-run")["plan"]
        self.assertEqual(rational_time(plan["duration"]), 5)
        self.assertEqual([(times(item["input"]), times(item["output"])) for item in plan["audio"]],
                         [((2, 4), (0, 2)), ((0, 2), (2, 4)), ((1, 2), (4, 5))])
        self.export()
        self.assert_program([(self.wide, 50, 100), (self.wide, 0, 25), (self.close, 25, 50),
                             (self.close, 25, 50)],
                            pcm_slice(lav_pcm, 2, 4) + pcm_slice(lav_pcm, 0, 2) + pcm_slice(lav_pcm, 1, 2))
        self.output = self.root / "explicit.mov"
        self.cli("export", "--stdin", "--json", request={
            "clips": [{"project": str(self.project_path.relative_to(self.root)), "from": "1", "to": "2"}],
            "output": self.output.name, "mode": "copy",
        })
        self.assert_program([(self.close, 25, 50)], pcm_slice(lav_pcm, 1, 2))

    def test_ordered_request_combines_file_and_two_projects_with_shared_source_ids(self):
        second_payload = self.project(audio={"mode": "fixed", "source": "wide", "stream": 1})
        second = self.project_dir / "second.multicam.json"
        second_payload["angles"][0]["file"] = str(self.pcm_close)
        second.write_text(json.dumps(second_payload))
        delayed = self.root / "delayed-file-clip.mov"
        ffmpeg("-copyts", "-itsoffset", "0.4", "-i", self.wide, "-map", "0", "-c", "copy", delayed)
        request = {
            "clips": [
                {"file": str(delayed), "from": "0", "to": "1"},
                {"project": str(self.project_path.relative_to(self.root)), "from": "1", "to": "2"},
                {"project": str(second.relative_to(self.root)), "from": "2", "to": "3"},
            ],
            "order": [3, 2, 1, 2],
            "mode": "copy",
            "output": self.output.name,
        }
        report = self.cli("export", "--stdin", "--json", "--dry-run", request=request)
        self.assertEqual(report["order"], [3, 2, 1, 2])
        self.assertEqual([
            (item["assemblyIndex"], times(item["group"]), times(item["output"]))
            for item in report["plan"]["intervals"]
        ], [(2, (2, 3), (0, 1)), (1, (1, 2), (1, 2)), (0, (0, 1), (2, 3)), (1, (1, 2), (3, 4))])
        file_span = report["plan"]["picture"][2]
        self.assertEqual(times(file_span["input"]), (Fraction(2, 5), Fraction(7, 5)))
        self.assertFalse(self.output.exists())
        self.cli("export", "--stdin", "--json", request=request)
        pcm = audio(self.wide)
        expected_pcm = pcm_slice(audio(self.pcm_close), 2, 3)
        expected_pcm += b"".join(pcm_slice(pcm, start, end) for start, end in [(1, 2), (0, 1), (1, 2)])
        self.assert_program([(self.pcm_close, 50, 75), (self.close, 25, 50), (self.wide, 0, 25), (self.close, 25, 50)],
                            expected_pcm)

    def test_mixed_audio_only_request_retains_audio_past_the_last_picture(self):
        long_sound = self.root / "longer-audio.mov"
        ffmpeg("-i", self.wide, "-i", self.lav, "-map", "0:v", "-map", "1:a", "-c", "copy",
               "-bsf:v", "noise=drop='gte(pts*tb,1)'", long_sound)
        self.project(wide=long_sound, audio={"mode": "fixed", "source": "wide", "stream": 1})
        request = {
            "clips": [{"file": long_sound.name}, {"project": str(self.project_path), "to": "1"}],
            "tracks": "audio",
            "output": "assembly.wav",
        }
        result = self.cli("export", "--stdin", "--json", request=request)
        self.assertEqual(rational_time(result["duration"]), 5)
        self.assertEqual(times(result["plan"]["audio"][0]["input"]), (0, 4))
        self.assertEqual(audio(self.root / request["output"]), audio(self.lav) + pcm_slice(audio(self.lav), 0, 1))

    def test_project_source_parent_traversal_uses_the_filesystem(self):
        payload = self.project(switches=[{"at": "0", "angle": "wide"}])
        (self.root / "real" / "child").mkdir(parents=True)
        (self.root / "real" / "selected.mov").symlink_to(self.wide)
        (self.project_dir / "selected.mov").symlink_to(self.close)
        (self.project_dir / "link").symlink_to("../real/child")
        payload["angles"][0]["file"] = "link/../selected.mov"
        self.project_path.write_text(json.dumps(payload))

        plan = self.export("--dry-run")
        self.assertEqual(Path(plan["sources"]["wide"]).resolve(), self.wide.resolve())
        self.assertEqual(Path(plan["picture"][0]["file"]).resolve(), self.wide.resolve())
        review = self.cli("frames", "--json", "--project", self.project_path, "--at", "0", "--output", "review")
        self.assertEqual(Path(review["angles"][0]["file"]).resolve(), self.wide.resolve())
        self.assertEqual(review["frames"][0]["availability"], "available")

        payload["angles"][0]["file"] = "missing/../selected.mov"
        self.project_path.write_text(json.dumps(payload))
        error = self.export("--dry-run", ok=False)["error"]
        self.assertEqual(error["code"], "missing_source")
        self.assertIn("missing/../selected.mov", error["message"])
        review = self.cli("frames", "--json", "--project", self.project_path, "--at", "0", "--output", "relinked-review")
        self.assertEqual(review["angles"][0]["error"]["code"], "missing_source")
        self.assertEqual(review["frames"][0]["availability"], "missingSource")

    def test_project_json_rejects_duplicate_fields_and_trailing_commas(self):
        self.project()
        valid = self.project_path.read_text()
        malformed = (valid.replace('"file": "wide.mov"', '"file": "wide.mov", "file": "close.mov"', 1),
                     valid[:-1] + ",}")
        for project in malformed:
            with self.subTest(project=project):
                self.project_path.write_text(project)
                failure = self.export("--dry-run", ok=False)["error"]
                self.assertEqual(failure["code"], "invalid_multicam_project")

    def test_smart_trim_encodes_edges_and_keeps_interior_video(self):
        self.project(switches=[
            {"at": "0", "angle": "wide"},
            {"at": "32/25", "angle": "close"},
            {"at": "69/25", "angle": "wide"},
        ])
        self.export("--dry-run", ok=False)
        self.assertFalse(self.output.exists())
        report = self.export("--dry-run", mode="smart")
        self.assertEqual(rational_time(report["encodedVideoDuration"]), 2)
        self.assertEqual(rational_time(report["copiedVideoDuration"]), 2)
        self.assertEqual([[times(edge) for edge in item.get("encodedEdges", [])] for item in report["picture"]],
                         [[(1, Fraction(32, 25))], [(Fraction(32, 25), Fraction(69, 25))],
                          [(Fraction(69, 25), 3)]])
        self.assertEqual([item["trackActions"][0]["action"] for item in report["picture"]],
                         ["copyAndEncode", "encode", "copyAndEncode"])
        self.assertEqual(report["audio"][0]["trackActions"], [{"index": 0, "kind": "audio", "action": "copy"}])
        self.export(mode="smart")
        self.assert_program([(self.wide, 0, 32), (self.close, 32, 69), (self.wide, 69, 100)],
                            audio(self.lav), copy=False)
        wide = vcl_hashes(self.wide, "h264")
        actual = vcl_hashes(self.output, "h264")
        for number in list(range(25)) + list(range(75, 100)):
            position = Fraction(number, FPS)
            self.assertEqual(actual[position], wide[position], position)
        self.assertNotEqual(actual[Fraction(69, FPS)], wide[Fraction(69, FPS)])

    def test_fractional_frame_switches_keep_sample_exact_wav(self):
        rate = "30000/1001"
        step = Fraction(1001, 30000)
        angles = ["wide", "close", "left", "right"]
        movies = [camera(self.root / f"{angle}.mov", marker_base=index * 64, frequency=419 + index * 73,
                         rate=rate, gop=1, length="1.001") for index, angle in enumerate(angles)]
        lav = wav(self.root / "ntsc-lav.wav", "1.001")
        self.project(lav=lav, end="1001/1000",
                     angles=[{"id": angle, "file": str(movie), "offset": "0"}
                             for angle, movie in zip(angles, movies)],
                     switches=[{"at": str(number * step), "angle": angles[number % len(angles)]}
                               for number in range(25)])
        self.export()
        spans = [(movies[number % len(movies)], number, number + 1) for number in range(24)]
        spans.append((movies[0], 24, 30))
        self.assert_program(spans, audio(lav))
        self.assertEqual([pts for pts, _ in timestamped_hashes(self.output)],
                         [number * step for number in range(30)])
        clips = [(20, 25), (5, 10)]
        saved = json.loads(self.project_path.read_text())
        saved["assembly"] = [{"from": str(start * step), "to": str(end * step)} for start, end in clips]
        self.project_path.write_text(json.dumps(saved))
        self.output = self.root / "ntsc-highlights.mov"
        self.export()
        spans = [(movies[number % len(movies)], number, number + 1)
                 for start, end in clips for number in range(start, end)]
        source_pcm = audio(lav)
        expected_pcm = b"".join(pcm_slice(source_pcm, start * step, end * step) for start, end in clips)
        self.assertEqual(len(expected_pcm) // 2, 2 * 8008)
        self.assert_program(spans, expected_pcm)
        self.assertEqual([pts for pts, _ in timestamped_hashes(self.output)],
                         [number * step for number in range(10)])

    def test_off_grid_switch_and_delayed_or_truncated_source_fail_without_output(self):
        self.project(offset="1/100")
        off_grid = self.export("--dry-run", mode="smart", ok=False)["error"]
        self.assertIn("group", off_grid["message"])
        self.assertFalse(off_grid.get("nearest"))
        self.assertFalse(self.output.exists())
        self.output.write_bytes(b"Existing destination")
        occupied = self.export(mode="smart", ok=False)["error"]
        self.assertEqual(occupied["code"], "output_exists")
        self.assertEqual(self.output.read_bytes(), b"Existing destination")
        self.assertEqual(set(self.root.iterdir()), {self.project_dir, self.output})
        self.output.unlink()

        self.project(offset="1", switches=[{"at": "0", "angle": "close"}])
        late_picture = self.export(mode="smart", ok=False)["error"]
        self.assertEqual(late_picture["code"], "uncovered_picture")
        self.assertIn("close", late_picture["message"])
        self.assertFalse(self.output.exists())

        delayed = camera(self.root / "delayed.mov", marker_base=128, frequency=691,
                         audio_codec="aac", delay="0.375", length="2")
        self.project(close=delayed, audio={"mode": "fixed", "source": "close", "stream": 1},
                     switches=[{"at": "0", "angle": "wide"}])
        short_aac = self.export(mode="smart", ok=False)["error"]
        self.assertEqual(short_aac["code"], "uncovered_audio")
        self.assertIn("close", short_aac["message"])
        self.assertIn("stream 1", short_aac["message"])
        self.assertFalse(self.output.exists())

    def test_copy_offers_joint_boundaries_on_group_clock_without_retiming(self):
        self.project(offset="1", switches=[{"at": "0", "angle": "wide"}, {"at": "57/25", "angle": "close"}])
        original = self.project_path.read_bytes()
        failure = self.export("--dry-run", ok=False)["error"]
        self.assertEqual(failure["code"], "unsafe_boundary")
        self.assertEqual([rational_time(item) for item in failure["nearest"]], [2, 3])
        self.assertEqual(self.project_path.read_bytes(), original)
        self.assertFalse(self.output.exists())

        self.project(offset="1", switches=[{"at": "0", "angle": "wide"}, {"at": "2", "angle": "close"}])
        plan = self.export("--dry-run")["plan"]
        self.assertEqual([(times(item["input"]), times(item["output"])) for item in plan["picture"]],
                         [((0, 2), (0, 2)), ((1, 3), (2, 4))])
        self.export()
        self.assert_program([(self.wide, 0, 50), (self.close, 25, 75)], audio(self.lav))

    def test_single_track_validation_uses_only_selected_streams(self):
        self.project(offset="1/100")
        soundtrack = self.root / "soundtrack.wav"
        self.export("--audio-only", output=soundtrack)
        self.assertEqual(audio(soundtrack), audio(self.lav))
        for flags in (("--mode", "smart", "--audio-only"), ("--audio-only", "--mode", "smart")):
            with self.subTest(flags=flags):
                conflict = self.cli("export", "--project", self.project_path, "--json", "--dry-run",
                                    "--output", self.output, *flags, ok=False)
                self.assertEqual(conflict["error"]["code"], "invalid_arguments")

        short_lav = wav(self.root / "short-lav.wav", "2")
        self.project(lav=short_lav)
        self.export(ok=False)
        self.assertFalse(self.output.exists())
        self.export("--video-only")
        self.assertEqual([stream["codec_type"] for stream in probe(self.output, "-show_streams")["streams"]],
                         ["video"])
        self.assertEqual(picture_ids(self.output), picture_ids(self.wide)[:25]
                         + picture_ids(self.close)[25:50] + picture_ids(self.wide)[50:])

    def test_delayed_aac_master_preserves_its_leading_presentation_edit(self):
        delayed = camera(self.root / "delayed-covered.mov", marker_base=128, frequency=691,
                         audio_codec="aac", delay="0.375")
        self.project(close=delayed, audio={"mode": "fixed", "source": "close", "stream": 1},
                     switches=[{"at": "0", "angle": "wide"}])
        self.export()
        decoder = self.root / "decode-audio"
        run(["xcrun", "swiftc", "-parse-as-library", Path(__file__).with_name("DecodeAudio.swift"),
             "-o", decoder], allow_diagnostics=True)
        # AVFoundation renders the leading empty MOV edit as silence.
        source_pcm = pcm_slice(run([decoder, delayed]), 0, 4)
        self.assertEqual(source_pcm[:RATE // 2], bytes(RATE // 2))
        self.assertEqual(run([decoder, self.output]), source_pcm)
        self.assertEqual(sample_hashes(self.output), sample_hashes(self.wide))

    def test_reencode_requires_audio_conversion_choice_for_incompatible_follow_mics(self):
        self.project(audio={"mode": "follow"})
        self.export("--dry-run", mode="encode", ok=False)
        self.assertFalse(self.output.exists())
        report = self.export("--dry-run", "--audio", "pcm", mode="encode")
        self.assertEqual(report["audioAction"], "pcm")
        self.assertEqual([item["trackActions"][0]["action"] for item in report["audio"]],
                         ["encode", "encode", "encode"])
        self.export("--audio", "pcm", mode="encode")
        self.assertEqual(picture_ids(self.output), picture_ids(self.wide)[:25]
                         + picture_ids(self.close)[25:50] + picture_ids(self.wide)[50:])
        actual = audio(self.output)
        wide_pcm = audio(self.wide)
        self.assertEqual(len(actual), 4 * RATE * 2)
        self.assertEqual(pcm_slice(actual, 0, 1), pcm_slice(wide_pcm, 0, 1))
        self.assertNotEqual(pcm_slice(actual, 1, 2), pcm_slice(wide_pcm, 1, 2))
        self.assertEqual(pcm_slice(actual, 2, 4), pcm_slice(wide_pcm, 2, 4))

    def test_aligned_frame_review_reports_offset_and_unavailable_angles(self):
        self.project(offset="1/5", assembly=[{"from": "2", "to": "3"}])
        output = self.root / "review"
        manifest = self.cli("frames", "--project", self.project_path, "--json",
                            "--at", "1/10", "--at", "3/10", "--output", output)
        self.assertEqual(manifest, json.loads((output / "manifest.json").read_text()))
        rows = manifest["frames"]
        self.assertEqual([(item["angleID"], rational_time(item["groupTime"]), item["availability"])
                          for item in rows],
                         [("wide", Fraction(1, 10), "available"), ("close", Fraction(1, 10), "beforeSource"),
                          ("wide", Fraction(3, 10), "available"), ("close", Fraction(3, 10), "available")])
        self.assertEqual([rational_time(item["sourceTime"]) for item in rows],
                         [Fraction(1, 10), Fraction(-1, 10), Fraction(3, 10), Fraction(1, 10)])
        self.assertEqual([rational_time(item["frameTime"]) for item in rows if "frameTime" in item],
                         [Fraction(2, 25), Fraction(7, 25), Fraction(2, 25)])
        self.assertNotIn("file", rows[1])
        for row in (rows[0], rows[2], rows[3]):
            self.assertTrue((output / row["file"]).read_bytes().startswith(b"\xff\xd8"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
