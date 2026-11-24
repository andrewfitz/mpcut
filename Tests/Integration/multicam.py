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
from saved_project import read_project

RATE = 48_000
FPS = 25
CLI = None


def camera(path, *, marker_base, frequency, rate=FPS, gop=FPS, length="4",
           audio_codec="pcm_s16le", delay=None, extra_audio=False, bframes=0):
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
           "-x264-params", f"keyint={gop}:min-keyint={gop}:scenecut=0:open-gop=0:bframes={bframes}:b-adapt=0",
           "-color_range", "tv", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
           "-c:a", audio_codec, "-channel_layout:a", "mono", path)
    return path


def wav(path, length):
    ffmpeg("-f", "lavfi", "-i", f"aevalsrc=0.2*sin(2*PI*(349*t+51*t*t)):s={RATE}:d={length}",
           "-c:a", "pcm_s16le", path)
    return path


def picture_types(path):
    report = probe(path, "-select_streams", "v:0", "-show_entries", "frame=pict_type")
    return "".join(frame["pict_type"] for frame in report["frames"])


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
        self.project_path = self.project_dir / "edit.cut"
        self.output = self.root / "program.mov"

    def project(self, *, close=None, wide=None, lav=None, end="4", offset="0", switches=None, **changes):
        payload = {
            "format": "mpcut",
            "schema_version": 3,
            "kind": "multicam",
            "reference_angle_id": "wide",
            "group_range": {"from": "0", "to": end},
            "angles": [
                {"id": "wide", "file": str(wide or self.wide), "offset": "0", "audio_stream_index": 1},
                {"id": "close", "file": str(close or self.close), "offset": offset, "audio_stream_index": 1},
            ],
            "audio_sources": [{"id": "lav", "file": str(lav or self.lav), "offset": "0"}],
            "audio": {"mode": "fixed", "source_id": "lav", "audio_stream_index": 0},
            "switches": switches or [{"group_time": "0", "angle_id": "wide"}, {"group_time": "1", "angle_id": "close"},
                                     {"group_time": "2", "angle_id": "wide"}],
        }
        payload.update(changes)
        for source in payload["angles"] + payload["audio_sources"]:
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
        return self.cli("export", "project", "render", "--project", self.project_path, "--json", "--mode", mode,
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

    def test_audio_edge_can_rejoin_an_mp3_between_packets(self):
        mp3 = self.root / "voice.mp3"
        ffmpeg("-f", "lavfi", "-i", "sine=sample_rate=48000:duration=8", "-c:a", "libmp3lame", mp3)
        def plan(end):
            self.project(lav=mp3, end="8", switches=[{"group_time": "0", "angle_id": "wide"}],
                         assembly=[{"from": "0", "to": end}, {"from": "6", "to": "7"}])
        plan("1")
        output = self.root / "edited.mp3"
        issue = self.export("--tracks", "audio", "--dry-run", output=output, ok=False)["error"]
        self.assertEqual([rational_time(t) for t in issue["nearest"]], [Fraction(6)])
        plan("6")
        self.export("--tracks", "audio", "--dry-run", output=output)

    def test_moving_edge_across_microphone_switch_uses_new_sample_phase(self):
        camera = self.root / "all-intra.mov"
        ffmpeg("-f", "lavfi", "-i", "color=size=32x32:rate=25:duration=4",
               "-c:v", "prores_ks", "-profile:v", "proxy", camera)
        microphones = [{"id": "good", "file": str(self.lav)}, {"id": "late", "file": str(self.lav),
                                                              "offset": "-1/96000"}]
        self.project(wide=camera, audio_sources=microphones, audio={"mode": "fixed", "source_id": "good", "audio_stream_index": 0},
                     switches=[{"group_time": "0", "angle_id": "wide"}, {"group_time": "2", "angle_id": "wide",
                               "audio": {"source_id": "late", "audio_stream_index": 0}}],
                     assembly=[{"from": "5/2", "to": "19/5"}])
        issue = self.export("--dry-run", ok=False)["error"]
        self.assertEqual([rational_time(t) for t in issue["nearest"]], [Fraction(49, 25)])

    def test_range_edge_offers_shared_ntsc_and_44100_sample_boundaries(self):
        camera = self.root / "ntsc.mov"
        ffmpeg("-f", "lavfi", "-i", "color=size=64x64:rate=30000/1001:d=8",
               "-f", "lavfi", "-i", "sine=sample_rate=44100:duration=8",
               "-c:v", "prores_ks", "-profile:v", "proxy", "-c:a", "pcm_s16le", camera)
        def plan(start):
            self.project(wide=camera, audio={"mode": "follow"}, switches=[{"group_time": "0", "angle_id": "wide"}],
                         end="1001/150", assembly=[{"from": start, "to": "1001/150"}])
        plan("101101/60000")
        issue = self.export("--dry-run", ok=False)["error"]
        self.assertEqual(issue["code"], "unsafe_boundary")
        offered = [rational_time(t) for t in issue["nearest"]]
        self.assertEqual(offered, [Fraction(0), Fraction(1001, 300)])
        for t in offered:
            plan(str(t))
            self.export("--dry-run")

    def test_microphone_only_switch_off_sample_has_two_usable_alternatives(self):
        initial = {"group_time": "0", "angle_id": "wide"}
        change = {"group_time": "48001/96000", "angle_id": "wide", "audio": {"source_id": "close", "audio_stream_index": 1}}
        policy = {"mode": "fixed", "source_id": "wide", "audio_stream_index": 1}
        self.project(close=self.pcm_close, audio=policy, switches=[initial, change])
        report = self.export(mode="smart", ok=False)
        self.assertEqual(report["error"]["code"], "unsafe_boundary")
        candidates = [rational_time(value) for value in report["error"]["nearest"]]
        self.assertEqual(candidates, [Fraction(1, 2), Fraction(24001, 48000)])
        for time in candidates:
            self.project(close=self.pcm_close, audio=policy, switches=[initial, {**change, "group_time": str(time)}])
            planned = self.export("--dry-run", mode="smart")
            self.assertTrue(planned["ok"])
        self.assertFalse(self.output.exists())

    def test_copy_alternatives_validate_ranges_clipped_at_the_original_switch(self):
        wide = self.root / "select-wide.mov"
        close = self.root / "select-close.mov"
        # Reordered pictures keep both edges of a copy on keyframes: an outgoing angle ends only before one.
        # Without them every picture is a verified end, and only the incoming start would restrict the switch.
        for source, keyframes in [(wide, "0,1,2,3"), (close, "0,1,1.04,2,3")]:
            ffmpeg("-f", "lavfi", "-i", "testsrc2=d=4:s=320x96:r=25", "-c:v", "libx264",
                   "-threads", "1", "-x264-params", "keyint=100:min-keyint=1:scenecut=0:open-gop=0:bframes=3:b-adapt=0",
                   "-force_key_frames", keyframes, source)
            self.assertIn("B", picture_types(source))
        first = {"group_time": "0", "angle_id": "wide"}
        switch = {"group_time": "1.04", "angle_id": "close"}
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
                payload["switches"][1]["group_time"] = str(expected)
                self.project_path.write_text(json.dumps(payload))
                self.export("--dry-run")

    def test_encode_alternatives_validate_all_retained_frame_boundaries(self):
        first = {"group_time": "0", "angle_id": "wide"}
        switch = {"group_time": "1.02", "angle_id": "close"}
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
            payload["switches"][1]["group_time"] = str(candidate)
            self.project_path.write_text(json.dumps(payload))
            self.export("--dry-run", mode="encode")

    def test_inspect_reports_gaps_in_partial_soundtrack_overrides(self):
        self.project(audio={"mode": "none"}, switches=[
            {"group_time": "0", "angle_id": "wide"},
            {"group_time": "1", "angle_id": "wide", "audio": {"source_id": "lav", "audio_stream_index": 0}},
        ])
        inspected = self.cli("project", "inspect", "--project", self.project_path, "--json")
        issues = inspected["inspection"]["issues"]
        self.assertEqual([(issue["code"], issue["segment"]) for issue in issues], [("missing_audio", 1)])
        self.assertEqual(self.export("--dry-run", ok=False)["error"]["code"], "missing_audio")
        self.export("--dry-run", "--tracks", "video")

    def test_no_default_soundtrack_exports_picture_without_camera_audio(self):
        self.project(audio={"mode": "none"}, switches=[{"group_time": "0", "angle_id": "wide"}])
        inspected = self.cli("project", "inspect", "--project", self.project_path, "--json")["inspection"]
        self.assertEqual(inspected["issues"], [])
        self.assertEqual(inspected["mapping"]["audio_lanes"], [])
        self.export()
        streams = probe(self.output, "-show_streams")["streams"]
        self.assertEqual([stream["codec_type"] for stream in streams], ["video"])

    def test_mix_v4_format_round_trips_order_relative_offset_and_history(self):
        fixture = Path(__file__).parent / "fixtures" / "multicam" / "mix-v4.cut"
        original = fixture.read_bytes()
        self.project_path.write_bytes(original)
        copy = self.project_dir / "copy.cut"
        self.cli("project", "edit", "--stdin", "--json", request={
            "project_path": str(self.project_path), "out_project": str(copy), "operations": [],
        })
        self.assertEqual(self.project_path.read_bytes(), original)
        expected = json.loads(original)
        saved = read_project(copy)
        self.assertIn(saved["schema_version"], (4, 5))
        for step in expected["history"]["undo"]:
            step.setdefault("origin", "unknown")
        for field in ("audio", "mix_lanes", "fixed_audio", "audio_replacements", "switches", "assembly", "history"):
            self.assertEqual(saved[field], expected[field], field)

    def test_fixed_wav_continues_through_picture_switches(self):
        help_json = subprocess.run([CLI, "help", "multicam", "--json"], check=True,
                                   capture_output=True, text=True, timeout=90)
        template = json.loads(help_json.stdout)["project_template"]
        self.assertEqual((template["format"], template["schema_version"], template["kind"]), ("mpcut", 4, "multicam"))
        self.project()
        inspected = self.cli("project", "inspect", "--project", self.project_path, "--json")
        self.assertEqual(Path(inspected["project_path"]), self.project_path)
        inspection = inspected["inspection"]
        sources = {item["source"]["id"]: item for item in inspection["sources"]}
        self.assertEqual(set(sources), {"wide", "close", "lav"})
        self.assertEqual(times(sources["close"]["coverage"]), (0, 4))
        self.assertEqual(times(sources["lav"]["audio_coverage"]["0"]), (0, 4))
        report = self.export("--dry-run")
        self.assertTrue(report["dry_run"], report)
        plan = report["plan"]
        self.assertEqual([(item["angle"], times(item["group"]), times(item["output"]))
                          for item in plan["intervals"]],
                         [("wide", (0, 1), (0, 1)), ("close", (1, 2), (1, 2)), ("wide", (2, 4), (2, 4))])
        lane, = plan["audio_lanes"]
        self.assertEqual([(item["source"], item["stream"], times(item["input"]), times(item["output"]))
                          for item in lane["spans"]],
                         [("lav", 0, (0, 4), (0, 4))])
        self.assertEqual(plan, inspection["mapping"])
        self.assertFalse(self.output.exists())
        self.export()
        self.assert_program([(self.wide, 0, 25), (self.close, 25, 50), (self.wide, 50, 100)], audio(self.lav))
        streams = probe(self.output, "-show_streams")["streams"]
        self.assertEqual([stream["codec_name"] for stream in streams], ["h264", "pcm_s16le"])

    def test_follow_camera_with_explicit_override_and_absolute_stream_selection(self):
        self.project(close=self.pcm_close, audio={"mode": "follow"}, switches=[
            {"group_time": "0", "angle_id": "wide"},
            {"group_time": "1", "angle_id": "close", "audio": {"source_id": "wide", "audio_stream_index": 1}},
            {"group_time": "2", "angle_id": "close", "audio": {"source_id": "close", "audio_stream_index": 2}},
            {"group_time": "3", "angle_id": "close"},
        ])
        wide_pcm = audio(self.wide)
        close_mic_two = ffmpeg("-i", self.pcm_close, "-map", "0:2", "-c:a", "pcm_s16le", "-f", "s16le", "-")
        expected = pcm_slice(wide_pcm, 0, 2)
        expected += pcm_slice(close_mic_two, 2, 3)
        expected += pcm_slice(audio(self.pcm_close), 3, 4)
        plan = self.export("--dry-run")["plan"]
        lane, = plan["audio_lanes"]
        self.assertEqual([(item["source"], item["stream"], times(item["input"])) for item in lane["spans"]],
                         [("wide", 1, (0, 2)), ("close", 2, (2, 3)), ("close", 1, (3, 4))])
        self.export()
        self.assert_program([(self.wide, 0, 25), (self.pcm_close, 25, 100)], expected)

    def test_reordered_repeated_assembly_and_explicit_group_clip(self):
        self.project(assembly=[{"from": "2", "to": "4"}, {"from": "0", "to": "2"},
                               {"from": "1", "to": "2"}])
        lav_pcm = audio(self.lav)
        plan = self.export("--dry-run")["plan"]
        self.assertEqual(rational_time(plan["duration"]), 5)
        lane, = plan["audio_lanes"]
        self.assertEqual([(times(item["input"]), times(item["output"])) for item in lane["spans"]],
                         [((2, 4), (0, 2)), ((0, 2), (2, 4)), ((1, 2), (4, 5))])
        self.export()
        self.assert_program([(self.wide, 50, 100), (self.wide, 0, 25), (self.close, 25, 50),
                             (self.close, 25, 50)],
                            pcm_slice(lav_pcm, 2, 4) + pcm_slice(lav_pcm, 0, 2) + pcm_slice(lav_pcm, 1, 2))
        self.output = self.root / "explicit.mov"
        self.cli("export", "clips", "join", "--stdin", "--json", request={
            "clips": [{"project_path": str(self.project_path.relative_to(self.root)), "from": "1", "to": "2"}],
            "output": self.output.name, "mode": "copy",
        })
        self.assert_program([(self.close, 25, 50)], pcm_slice(lav_pcm, 1, 2))

    def test_ordered_request_combines_file_and_two_projects_with_shared_source_ids(self):
        second_payload = self.project(audio={"mode": "fixed", "source_id": "wide", "audio_stream_index": 1})
        second = self.project_dir / "second.cut"
        second_payload["angles"][0]["file"] = str(self.pcm_close)
        second.write_text(json.dumps(second_payload))
        delayed = self.root / "delayed-file-clip.mov"
        ffmpeg("-copyts", "-itsoffset", "0.4", "-i", self.wide, "-map", "0", "-c", "copy", delayed)
        request = {
            "clips": [
                {"file": str(delayed), "from": "0", "to": "1"},
                {"project_path": str(self.project_path.relative_to(self.root)), "from": "1", "to": "2"},
                {"project_path": str(second.relative_to(self.root)), "from": "2", "to": "3"},
            ],
            "order": [3, 2, 1, 2],
            "mode": "copy",
            "output": self.output.name,
        }
        report = self.cli("export", "clips", "join", "--stdin", "--json", "--dry-run", request=request)
        self.assertEqual(report["order"], [3, 2, 1, 2])
        self.assertEqual([
            (item["assembly_index"], times(item["group"]), times(item["output"]))
            for item in report["plan"]["intervals"]
        ], [(2, (2, 3), (0, 1)), (1, (1, 2), (1, 2)), (0, (0, 1), (2, 3)), (1, (1, 2), (3, 4))])
        self.assertEqual([
            (item["occurrence_number"], item["input_number"], times(item["input"]), times(item["output"]))
            for item in report["cut_map"]["occurrences"]
        ], [(1, 3, (2, 3), (0, 1)), (2, 2, (1, 2), (1, 2)), (3, 1, (0, 1), (2, 3)), (4, 2, (1, 2), (3, 4))])
        file_span = report["plan"]["picture"][2]
        self.assertEqual(times(file_span["input"]), (Fraction(2, 5), Fraction(7, 5)))
        self.assertFalse(self.output.exists())
        rendered = self.cli("export", "clips", "join", "--stdin", "--json", request=request)
        self.assertEqual(rendered["cut_map"], report["cut_map"])
        pcm = audio(self.wide)
        expected_pcm = pcm_slice(audio(self.pcm_close), 2, 3)
        expected_pcm += b"".join(pcm_slice(pcm, start, end) for start, end in [(1, 2), (0, 1), (1, 2)])
        self.assert_program([(self.pcm_close, 50, 75), (self.close, 25, 50), (self.wide, 0, 25), (self.close, 25, 50)],
                            expected_pcm)

    def test_mixed_audio_only_request_retains_audio_past_the_last_picture(self):
        long_sound = self.root / "longer-audio.mov"
        ffmpeg("-i", self.wide, "-i", self.lav, "-map", "0:v", "-map", "1:a", "-c", "copy",
               "-bsf:v", "noise=drop='gte(pts*tb,1)'", long_sound)
        self.project(wide=long_sound, audio={"mode": "fixed", "source_id": "wide", "audio_stream_index": 1})
        request = {
            "clips": [{"file": long_sound.name}, {"project_path": str(self.project_path), "to": "1"}],
            "tracks": "audio",
            "output": "assembly.wav",
        }
        result = self.cli("export", "clips", "join", "--stdin", "--json", request=request)
        self.assertEqual(rational_time(result["duration"]), 5)
        lane, = result["plan"]["audio_lanes"]
        self.assertEqual(times(lane["spans"][0]["input"]), (0, 4))
        self.assertEqual(audio(self.root / request["output"]), audio(self.lav) + pcm_slice(audio(self.lav), 0, 1))

    def test_project_source_parent_traversal_uses_the_filesystem(self):
        payload = self.project(switches=[{"group_time": "0", "angle_id": "wide"}])
        (self.root / "real" / "child").mkdir(parents=True)
        (self.root / "real" / "selected.mov").symlink_to(self.wide)
        (self.project_dir / "selected.mov").symlink_to(self.close)
        (self.project_dir / "link").symlink_to("../real/child")
        payload["angles"][0]["file"] = "link/../selected.mov"
        self.project_path.write_text(json.dumps(payload))

        plan = self.export("--dry-run")
        self.assertEqual(Path(plan["sources"]["wide"]).resolve(), self.wide.resolve())
        self.assertEqual(Path(plan["picture"][0]["file"]).resolve(), self.wide.resolve())
        review = self.cli("review", "frames", "export", "--json", "--project", self.project_path, "--at", "0", "--output", "review")
        self.assertEqual(Path(review["angles"][0]["file"]).resolve(), self.wide.resolve())
        self.assertEqual(review["frames"][0]["availability"], "available")

        payload["angles"][0]["file"] = "missing/../selected.mov"
        self.project_path.write_text(json.dumps(payload))
        error = self.export("--dry-run", ok=False)["error"]
        self.assertEqual(error["code"], "missing_source")
        self.assertIn("missing/../selected.mov", error["message"])
        review = self.cli("review", "frames", "export", "--json", "--project", self.project_path, "--at", "0", "--output", "relinked-review")
        self.assertEqual(review["angles"][0]["error"]["code"], "missing_source")
        self.assertEqual(review["frames"][0]["availability"], "missing_source")

    def test_project_json_rejects_duplicate_fields_and_trailing_commas(self):
        self.project()
        valid = self.project_path.read_text()
        malformed = (valid.replace('"file": "wide.mov"', '"file": "wide.mov", "file": "close.mov"', 1),
                     valid[:-1] + ",}")
        for project in malformed:
            with self.subTest(project=project):
                self.project_path.write_text(project)
                failure = self.export("--dry-run", ok=False)["error"]
                self.assertEqual(failure["code"], "invalid_cut_project")

    def test_smart_trim_encodes_edges_and_keeps_interior_video(self):
        # Cameras that reorder pictures end a copy only before a keyframe, so both sides of each switch are encoded.
        # The class cameras do not reorder: each may end at any picture, and only the two starts inside a picture
        # group are encoded, up to the next keyframe. Rows: cameras, encoded duration, encoded edges and action of
        # each picture interval, then the copied and the encoded pictures as (camera, picture numbers).
        reordered = [camera(self.root / f"reordered-{name}.mov", marker_base=base, frequency=frequency, bframes=3)
                     for name, base, frequency in [("wide", 0, 419), ("close", 128, 691)]]
        for source in reordered:
            self.assertIn("B", picture_types(source))
        for cameras, encoded, edges, actions, copied, replaced in [
            ([self.wide, self.close], Fraction(24, 25),
             [[], [(Fraction(32, 25), 2)], [(Fraction(69, 25), 3)]], ["copy", "copy_and_encode", "copy_and_encode"],
             [(0, range(32)), (1, range(50, 69)), (0, range(75, 100))], [(1, 32), (0, 69)]),
            (reordered, 2,
             [[(1, Fraction(32, 25))], [(Fraction(32, 25), Fraction(69, 25))], [(Fraction(69, 25), 3)]],
             ["copy_and_encode", "encode", "copy_and_encode"],
             [(0, range(25)), (0, range(75, 100))], [(0, 25), (1, 32), (1, 50), (0, 69)]),
        ]:
            with self.subTest(wide=cameras[0].name):
                self.output = self.root / f"program-{cameras[0].stem}.mov"
                self.project(wide=cameras[0], close=cameras[1], switches=[
                    {"group_time": "0", "angle_id": "wide"},
                    {"group_time": "32/25", "angle_id": "close"},
                    {"group_time": "69/25", "angle_id": "wide"},
                ])
                self.export("--dry-run", ok=False)
                self.assertFalse(self.output.exists())
                report = self.export("--dry-run", mode="smart")
                self.assertEqual(rational_time(report["encoded_video_duration"]), encoded)
                self.assertEqual(rational_time(report["copied_video_duration"]), 4 - encoded)
                self.assertEqual([[times(edge) for edge in item.get("encoded_edges", [])] for item in report["picture"]],
                                 edges)
                self.assertEqual([item["track_actions"][0]["action"] for item in report["picture"]], actions)
                lane, = report["audio_lanes"]
                self.assertEqual(lane["action"], "copy")
                segment, = lane["segments"]
                self.assertEqual([(track["index"], track["kind"]) for track in segment["tracks"]], [(0, "audio")])
                self.export(mode="smart")
                self.assert_program([(cameras[0], 0, 32), (cameras[1], 32, 69), (cameras[0], 69, 100)],
                                    audio(self.lav), copy=False)
                originals = [vcl_hashes(source, "h264") for source in cameras]
                actual = vcl_hashes(self.output, "h264")
                for source, numbers in copied:
                    for number in numbers:
                        position = Fraction(number, FPS)
                        self.assertEqual(actual[position], originals[source][position], position)
                for source, number in replaced:
                    position = Fraction(number, FPS)
                    self.assertNotEqual(actual[position], originals[source][position], position)

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
                     switches=[{"group_time": str(number * step), "angle_id": angles[number % len(angles)]}
                               for number in range(25)])
        self.export()
        spans = [(movies[number % len(movies)], number, number + 1) for number in range(24)]
        spans.append((movies[0], 24, 30))
        self.assert_program(spans, audio(lav))
        self.assertEqual([pts for pts, _ in timestamped_hashes(self.output)],
                         [number * step for number in range(30)])
        clips = [(20, 25), (5, 10)]
        saved = read_project(self.project_path)
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

        self.project(offset="1", switches=[{"group_time": "0", "angle_id": "close"}])
        late_picture = self.export(mode="smart", ok=False)["error"]
        self.assertEqual(late_picture["code"], "uncovered_picture")
        self.assertIn("close", late_picture["message"])
        self.assertFalse(self.output.exists())

        delayed = camera(self.root / "delayed.mov", marker_base=128, frequency=691,
                         audio_codec="aac", delay="0.375", length="2")
        self.project(close=delayed, audio={"mode": "fixed", "source_id": "close", "audio_stream_index": 1},
                     switches=[{"group_time": "0", "angle_id": "wide"}])
        short_aac = self.export(mode="smart", ok=False)["error"]
        self.assertEqual(short_aac["code"], "uncovered_audio")
        self.assertIn("close", short_aac["message"])
        self.assertIn("stream 1", short_aac["message"])
        self.assertFalse(self.output.exists())

    def test_csv_boundary_suggestions_move_only_the_failing_row(self):
        self.project()
        manifest = self.root / "sources.json"
        manifest.write_text(json.dumps([{"project_path": str(self.project_path), "from": "0", "to": "1"}]))
        cuts = self.root / "cuts.csv"
        cuts.write_text("from,to\n0,1\n2.5,4")
        common = ("export", "clips", "join", "--json", "--dry-run", "--output", self.output, "--clips", manifest,
                  "--mode", "copy", "--tracks", "video")
        reference = self.cli(*common, "--clip", self.wide, "--from", "0", "--to", "1",
                             "--clip", self.wide, "--from", "2.5", "--to", "4", ok=False)["error"]
        issue = self.cli(*common, "--clip", self.wide, "--ranges", cuts, ok=False)["error"]
        self.assertEqual(issue["segment"], 2)
        self.assertEqual(issue["multicam"]["edge"]["range_number"], 2)
        self.assertTrue(reference["nearest"])
        self.assertEqual(issue["nearest"], reference["nearest"])
        cuts.write_text("from,to\n0,1\n2,4")
        intervals = self.cli(*common, "--clip", self.wide, "--ranges", cuts)["plan"]["intervals"]
        self.assertEqual([row["assembly_index"] for row in intervals], [0, 1, 1])

    def test_picture_only_cut_without_alternatives_says_what_to_do(self):
        # The picture-only row of the export rules offers another container only, and no container takes a switch
        # inside the incoming camera's picture group. The refusal then says what does help, and people read its
        # times in seconds.
        self.project(switches=[{"group_time": "0", "angle_id": "wide"}, {"group_time": "57/25", "angle_id": "close"}])
        failure = self.export("--dry-run", "--tracks", "video", ok=False)["error"]
        self.assertEqual((failure["code"], failure["reason"]), ("unsafe_boundary", "cut_video_start"))
        self.assertFalse(failure.get("alternatives"))
        self.assertTrue(failure["nearest"])
        self.assertIn("boundary at 57/25. A picture-only multicam export is a Lossless Copy, which needs a verified time "
                      "at every cut. Move the cut to one of the verified times", failure["message"])
        self.assertIn("or export picture and sound together with ", failure["message"])
        together = self.export("--dry-run", ok=False)["error"]
        self.assertNotIn("picture-only", together["message"])
        self.assertTrue(all(offer["tracks"] == "all" for offer in together["alternatives"]))
        self.assertTrue(together["alternatives"])

        told = subprocess.run([CLI, "export", "project", "render", "--project", self.project_path, "--dry-run", "--mode", "copy", "--tracks", "video",
                               "--output", self.output], capture_output=True, text=True, cwd=self.root, timeout=90)
        self.assertEqual(told.returncode, 1)
        # The refused edge is the incoming camera's start: the outgoing one may end at any picture.
        self.assertIn("Source close stream 0, group 2.280–4.000 s", told.stderr)
        self.assertIn("boundary at 2.280 s. A picture-only multicam export", told.stderr)
        self.assertNotIn("57/25", told.stderr)
        self.assertIn("Verified alternatives: ", told.stderr)
        # On a keyframe the picture-only copy is written, and nothing is advised.
        self.project(switches=[{"group_time": "0", "angle_id": "wide"}, {"group_time": "2", "angle_id": "close"}])
        self.export("--dry-run", "--tracks", "video")

    def test_copy_offers_joint_boundaries_on_group_clock_without_retiming(self):
        self.project(offset="1", switches=[{"group_time": "0", "angle_id": "wide"}, {"group_time": "57/25", "angle_id": "close"}])
        original = self.project_path.read_bytes()
        failure = self.export("--dry-run", ok=False)["error"]
        self.assertEqual(failure["code"], "unsafe_boundary")
        self.assertEqual([rational_time(item) for item in failure["nearest"]], [2, 3])
        self.assertEqual(self.project_path.read_bytes(), original)
        self.assertFalse(self.output.exists())

        self.project(offset="1", switches=[{"group_time": "0", "angle_id": "wide"}, {"group_time": "2", "angle_id": "close"}])
        plan = self.export("--dry-run")["plan"]
        self.assertEqual([(times(item["input"]), times(item["output"])) for item in plan["picture"]],
                         [((0, 2), (0, 2)), ((1, 3), (2, 4))])
        self.export()
        self.assert_program([(self.wide, 0, 50), (self.close, 25, 75)], audio(self.lav))

    def test_single_track_validation_uses_only_selected_streams(self):
        self.project(offset="1/100")
        soundtrack = self.root / "soundtrack.wav"
        self.export("--tracks", "audio", output=soundtrack)
        self.assertEqual(audio(soundtrack), audio(self.lav))
        for flags in (("--mode", "smart", "--tracks", "audio"), ("--tracks", "audio", "--mode", "smart")):
            with self.subTest(flags=flags):
                conflict = self.cli("export", "project", "render", "--project", self.project_path, "--json", "--dry-run",
                                    "--output", self.output, *flags, ok=False)
                self.assertEqual(conflict["error"]["code"], "invalid_arguments")

        short_lav = wav(self.root / "short-lav.wav", "2")
        self.project(lav=short_lav)
        self.export(ok=False)
        self.assertFalse(self.output.exists())
        self.export("--tracks", "video")
        self.assertEqual([stream["codec_type"] for stream in probe(self.output, "-show_streams")["streams"]],
                         ["video"])
        self.assertEqual(picture_ids(self.output), picture_ids(self.wide)[:25]
                         + picture_ids(self.close)[25:50] + picture_ids(self.wide)[50:])

    def test_delayed_aac_master_preserves_its_leading_presentation_edit(self):
        delayed = camera(self.root / "delayed-covered.mov", marker_base=128, frequency=691,
                         audio_codec="aac", delay="0.375")
        self.project(close=delayed, audio={"mode": "fixed", "source_id": "close", "audio_stream_index": 1},
                     switches=[{"group_time": "0", "angle_id": "wide"}])
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
        lane, = report["audio_lanes"]
        self.assertEqual(lane["action"], "pcm")
        self.assertEqual([rational_time(segment["output_start"]) for segment in lane["segments"]], [0, 1, 2])
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
        manifest = self.cli("review", "frames", "export", "--project", self.project_path, "--json",
                            "--at", "1/10", "--at", "3/10", "--output", output)
        self.assertEqual(manifest, json.loads((output / "manifest.json").read_text()))
        rows = manifest["frames"]
        self.assertEqual([(item["angle_id"], rational_time(item["group_time"]), item["availability"])
                          for item in rows],
                         [("wide", Fraction(1, 10), "available"), ("close", Fraction(1, 10), "before_source"),
                          ("wide", Fraction(3, 10), "available"), ("close", Fraction(3, 10), "available")])
        self.assertEqual([rational_time(item["source_time"]) for item in rows],
                         [Fraction(1, 10), Fraction(-1, 10), Fraction(3, 10), Fraction(1, 10)])
        self.assertEqual([rational_time(item["frame_time"]) for item in rows if "frame_time" in item],
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
