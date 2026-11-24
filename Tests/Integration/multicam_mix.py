#!/usr/bin/env python3
"""Check multicam Mix across picture copy, camera rollover, and audio delivery."""
import argparse
from array import array
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

from media_regression import ffmpeg, packets, probe, sample_hashes, timestamped_hashes
from multicam import camera, pcm_slice, rational_time, times
from saved_project import read_project

CLI = None
RATE = 48_000


def pcm(path, track=0):
    return ffmpeg("-i", path, "-map", f"0:a:{track}", "-c:a", "pcm_s16le", "-f", "s16le", "-")


def tracks(path):
    return probe(path, "-select_streams", "a", "-show_streams")["streams"]


def track_time(track, field):
    return Fraction(track["time_base"]) * int(track[field])


def boxes(data, start=0, end=None):
    cursor = start
    end = len(data) if end is None else end
    while cursor < end:
        size, kind = struct.unpack_from(">I4s", data, cursor)
        header = 8
        if size == 1:
            size, = struct.unpack_from(">Q", data, cursor + header)
            header += 8
        if size == 0:
            size = end - cursor
        if not header <= size <= end - cursor:
            raise AssertionError(f"invalid {kind} box at {cursor}")
        yield kind, cursor + header, cursor + size
        cursor += size


def selection_metadata(path):
    """Read the enabled flag and alternate group directly from MOV track headers."""
    data = path.read_bytes()
    _, moov, moov_end = next(box for box in boxes(data) if box[0] == b"moov")
    result = {}
    for kind, track, track_end in boxes(data, moov, moov_end):
        if kind != b"trak":
            continue
        _, header, _ = next(box for box in boxes(data, track, track_end) if box[0] == b"tkhd")
        flags = int.from_bytes(data[header + 1:header + 4], "big")
        if data[header] not in (0, 1):
            raise AssertionError(f"unknown tkhd version {data[header]}")
        track_id_offset, alternate_group_offset = (20, 46) if data[header] == 1 else (12, 34)
        track_id, = struct.unpack_from(">I", data, header + track_id_offset)
        alternate_group, = struct.unpack_from(">H", data, header + alternate_group_offset)
        result[track_id] = (bool(flags & 1), alternate_group)
    return result


class MulticamMixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-mix-media-")
        cls.addClassCleanup(directory.cleanup)
        root = Path(directory.name)
        cls.a = camera(root / "a.mov", marker_base=0, frequency=419)
        cls.b1 = camera(root / "b1.mov", marker_base=128, frequency=697, length="3")
        cls.b2 = camera(root / "b2.mov", marker_base=256, frequency=881, length="2")
        cls.replacement = root / "replacement.mov"
        # Stream zero is a decoy. The chosen stream has two single-sample cues near
        # the ends of the section covered by the binding.
        ffmpeg("-f", "lavfi", "-i", f"aevalsrc=0.8*eq(n\\,36000):s={RATE}:d=3",
               "-f", "lavfi", "-i", f"aevalsrc=0.8*eq(n\\,24000)-0.8*eq(n\\,96000):s={RATE}:d=3",
               "-map", "0:a:0", "-map", "1:a:0", "-c:a", "pcm_s16le", cls.replacement)
        cls.peak = root / "peak.mov"
        cls.peak_b = root / "peak-b.mov"
        cls.silence = root / "silence.mov"
        for source, expression in ((cls.peak, "0.7*cos(2*PI*500*t)"), (cls.silence, "0")):
            ffmpeg("-f", "lavfi", "-i", f"aevalsrc={expression}:s={RATE}:d=4",
                   "-c:a", "pcm_s16le", "-movflags", "+faststart", source)
        cls.peak_b.write_bytes(cls.peak.read_bytes())
        cls.surround = root / "surround.m4a"
        surround = "|".join(f"0.1*sin(2*PI*{frequency}*t)" for frequency in (99, 187, 263, 71, 343, 461))
        ffmpeg("-f", "lavfi", "-i", f"aevalsrc={surround}:s=44100:d=4:c=5.1",
               "-c:a", "aac", "-b:a", "320k", cls.surround)
        cls.stereo = root / "stereo.m4a"
        ffmpeg("-f", "lavfi", "-i", f"aevalsrc=0.2*sin(2*PI*173*t)|0.2*sin(2*PI*593*t):s={RATE}:d=4:c=stereo",
               "-c:a", "aac", cls.stereo)

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-mix-output-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.project_path = self.root / "edit.cut"

    def project(self, *, gap=False, replacement=True, second_peak=None, surround=False, still=False):
        payload = {
            "format": "mpcut",
            "schema_version": 4,
            "kind": "multicam",
            "reference_angle_id": "a",
            "group_range": {"from": "0", "to": "4"},
            "angles": [
                {"id": "a", "file": str(self.a), "audio_stream_index": 1},
                {"id": "b", "file": str(self.b1), "offset": "-1", "audio_stream_index": 1,
                 "group_coverage": {"from": "0", "to": "1" if gap else "2"},
                 "additional_recordings": [
                     {"id": "b2", "file": str(self.b2), "offset": "2", "audio_stream_index": 1,
                      "group_coverage": {"from": "2", "to": "4"}}
                 ]},
            ],
            "audio": {"mode": "mix"},
            "switches": [{"group_time": "0", "angle_id": "a"}],
            "mix_lanes": [
                {"id": "lane-a", "target": {"kind": "camera", "angle_id": "a"},
                 "label": "Camera A", "color_slot": 0},
                {"id": "lane-b", "target": {"kind": "camera", "angle_id": "b"},
                 "label": "Camera B", "color_slot": 1},
            ],
        }
        if replacement:
            payload["audio_sources"] = [{"id": "external", "file": str(self.replacement)}]
            payload["audio_replacements"] = [
                {"id": "replacement-b2", "original": {"source_id": "b2", "audio_stream_index": 1},
                 "replacement": {"source_id": "external", "audio_stream_index": 1},
                 "relative_offset": "-1/4", "uncovered": "leave_uncovered"},
            ]
        if second_peak is not None:
            payload["audio_sources"] = [
                {"id": "peak-a", "file": str(self.peak)},
                {"id": "peak-b", "file": str(second_peak)},
            ]
            for lane, source in zip(payload["mix_lanes"], ("peak-a", "peak-b")):
                lane["target"] = {"kind": "recording", "source_id": source, "audio_stream_index": 0}
            # Reorder copy-safe picture spans. Both audio lanes must
            # follow the same output clock at each assembly splice.
            payload["assembly"] = [{"from": "2", "to": "4"}, {"from": "0", "to": "1"}]
        if surround:
            payload["audio_sources"] = [{"id": "surround", "file": str(self.surround)}]
            payload["mix_lanes"][1]["target"] = {
                "kind": "recording", "source_id": "surround", "audio_stream_index": 0,
            }
        if still:
            payload["still_assets"] = [{"kind": "gap", "id": "title"}]
            payload["assembly"] = [
                {"from": "0", "to": "1"},
                {"kind": "still", "still": {
                    "id": "insert", "asset_id": "title", "duration": "1", "cadence": "1/25",
                    "framing": {"mode": "fit", "background": "#000000"},
                }},
                {"from": "2", "to": "4"},
            ]
        self.project_path.write_text(json.dumps(payload))

    def export(self, name, *args, ok=True, dry_run=False, mode="copy"):
        output = self.root / name
        command = [CLI, "export", "project", "render", "--project", self.project_path,
                   "--mode", mode, "--output", output, "--json", *args]
        if dry_run:
            command.append("--dry-run")
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode == 0, ok, f"Exit {result.returncode}\n{result.stdout}{result.stderr}")
        report = json.loads(result.stdout)
        self.assertIs(report["ok"], ok, report)
        self.assertEqual(output.exists(), ok and not dry_run)
        return output, report

    def join(self, name, clips, *args, ok=True, dry_run=False, mode="copy"):
        output = self.root / name
        request = {"output": str(output), "mode": mode, "clips": clips}
        command = [CLI, "export", "clips", "join", "--stdin", "--json", *args]
        if dry_run:
            command.append("--dry-run")
        result = subprocess.run(command, input=json.dumps(request), capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        self.assertEqual(output.exists(), ok and not dry_run)
        return output, json.loads(result.stdout)

    def assert_stereo_mix(self, path, a, b):
        stream, = tracks(path)
        self.assertEqual(stream["channels"], 2)
        self.assertEqual(int(stream["sample_rate"]), RATE)
        left = array("h", a)
        right = array("h", b)
        actual = array("h", pcm(path))
        self.assertEqual(len(left), len(right))
        self.assertEqual(len(actual), 2 * len(left))
        # A signed 16-bit decode can round the exact average by half a sample unit.
        for channel in (actual[::2], actual[1::2]):
            self.assertLessEqual(max(abs(2 * sample - a - b) for sample, a, b in zip(channel, left, right)), 1)

    def expected_b(self, *, gap=False, replacement=True):
        b1_end = 2 if gap else 3
        first = pcm_slice(pcm(self.b1), 1, b1_end)
        if gap:
            first += bytes(RATE * 2)
        second = pcm_slice(pcm(self.replacement, 1), Fraction(1, 4), Fraction(9, 4)) if replacement else pcm(self.b2)
        return first + second

    def assert_separate_tracks(self, output, b):
        audio_tracks = tracks(output)
        self.assertEqual([track["channels"] for track in audio_tracks], [1, 1])
        self.assertEqual([int(track["sample_rate"]) for track in audio_tracks], [RATE, RATE])
        self.assertEqual([track["disposition"]["default"] for track in audio_tracks], [1, 0])
        self.assertEqual([track_time(track, "start_pts") for track in audio_tracks], [0, 0])
        self.assertEqual([track_time(track, "duration_ts") for track in audio_tracks], [4, 4])
        self.assert_alternate_group(output, audio_tracks)
        self.assertEqual(pcm(output), pcm(self.a))
        self.assertEqual(pcm(output, 1), b)

    def assert_alternate_group(self, path, audio_tracks):
        headers = selection_metadata(path)
        selected, unselected = [headers[int(track["id"], 0)] for track in audio_tracks]
        self.assertTrue(selected[0])
        self.assertFalse(unselected[0])
        self.assertGreater(selected[1], 0)
        self.assertEqual(unselected[1], selected[1])

    def assert_copied_aac(self, output, ordinal, source):
        original = packets(source, "a:0")
        copy = packets(output, f"a:{ordinal}")
        self.assertEqual([packet["data_hash"] for packet in copy], [packet["data_hash"] for packet in original])
        source_scale = Fraction(tracks(source)[0]["time_base"])
        output_scale = Fraction(tracks(output)[ordinal]["time_base"])
        for clock in ("pts", "dts"):
            self.assertEqual([int(packet[clock]) * output_scale for packet in copy],
                             [int(packet[clock]) * source_scale for packet in original])

    def test_separate_copy_rolls_offscreen_camera(self):
        self.project(replacement=False)
        output, report = self.export("rollover.mov", "--audio", "copy")
        a, b = report["plan"]["audio_lanes"]
        self.assertEqual((a["id"], b["id"]), ("lane-a", "lane-b"))
        self.assertEqual(len(a["spans"]), 1)
        self.assertEqual([(span["source"], times(span["input"]), times(span["output"])) for span in b["spans"]],
                         [("b", (1, 3), (0, 2)), ("b2", (0, 2), (2, 4))])
        self.assertEqual(timestamped_hashes(output), timestamped_hashes(self.a))
        self.assert_separate_tracks(output, self.expected_b(replacement=False))

    def test_separate_copy_keeps_pcm_and_surround_aac_formats_and_payload(self):
        self.project(replacement=False, surround=True)
        output, _ = self.export("mixed-formats.mov", "--audio", "copy")
        audio_tracks = tracks(output)
        self.assertEqual([track["codec_name"] for track in audio_tracks], ["pcm_s16le", "aac"])
        self.assertEqual([track["channels"] for track in audio_tracks], [1, 6])
        self.assertEqual([int(track["sample_rate"]) for track in audio_tracks], [RATE, 44_100])
        self.assertEqual([track["disposition"]["default"] for track in audio_tracks], [1, 0])
        self.assertEqual(audio_tracks[1]["channel_layout"], tracks(self.surround)[0]["channel_layout"])
        self.assertEqual([track_time(track, "start_pts") for track in audio_tracks], [0, 0])
        self.assertEqual([track_time(track, "duration_ts") for track in audio_tracks], [4, 4])
        self.assert_alternate_group(output, audio_tracks)
        self.assertEqual(pcm(output), pcm(self.a))
        self.assert_copied_aac(output, 1, self.surround)
        self.assertEqual(timestamped_hashes(output), timestamped_hashes(self.a))

    def test_mixed_sample_rates_copy_across_a_picture_only_boundary_between_samples(self):
        rate = "30000/1001"
        wide = camera(self.root / "wide.mov", marker_base=0, frequency=419, rate=rate, gop=30, length="10.01")
        close = camera(self.root / "close.mov", marker_base=128, frequency=697, rate=rate, gop=30, length="10.01")
        recorder = self.root / "recorder.mov"
        ffmpeg("-f", "lavfi", "-i", "anoisesrc=sample_rate=44100:duration=10.01:seed=23",
               "-c:a", "pcm_s16le", "-movflags", "+faststart", recorder)
        self.project(replacement=False)
        payload = read_project(self.project_path)
        payload["group_range"]["to"] = "1001/100"
        payload["angles"] = [
            {"id": "a", "file": str(wide), "audio_stream_index": 1},
            {"id": "b", "file": str(close), "audio_stream_index": 1},
        ]
        payload["audio_sources"] = [{"id": "recorder", "file": str(recorder)}]
        payload["mix_lanes"][1]["target"] = {"kind": "recording", "source_id": "recorder", "audio_stream_index": 0}
        # At NTSC frame 30 the 48 kHz route is sample-aligned, but the 44.1 kHz
        # route is between samples. Only the picture stream should cut there.
        payload["switches"].append({"group_time": "1001/1000", "angle_id": "b"})
        self.project_path.write_text(json.dumps(payload))
        output, report = self.export("between-samples.mov", "--audio", "copy")
        self.assertEqual([len(lane["spans"]) for lane in report["plan"]["audio_lanes"]], [1, 1])
        self.assertEqual([int(track["sample_rate"]) for track in tracks(output)], [RATE, 44_100])
        self.assertEqual(timestamped_hashes(output), timestamped_hashes(wide)[:30] + timestamped_hashes(close)[30:])
        self.assertEqual(pcm(output), pcm(wide))
        self.assertEqual(pcm(output, 1), pcm(recorder))

    def test_mp4_and_matroska_mark_the_first_lane_as_default(self):
        self.project(replacement=False, surround=True)
        payload = read_project(self.project_path)
        payload["audio_sources"].append({"id": "stereo", "file": str(self.stereo)})
        payload["mix_lanes"][0]["target"] = {"kind": "recording", "source_id": "stereo", "audio_stream_index": 0}
        self.project_path.write_text(json.dumps(payload))
        output, _ = self.export("selection.mp4", "--audio", "copy")
        audio_tracks = tracks(output)
        self.assertEqual([track["channels"] for track in audio_tracks], [2, 6])
        self.assertEqual([track["disposition"]["default"] for track in audio_tracks], [1, 0])
        self.assert_alternate_group(output, audio_tracks)
        self.assert_copied_aac(output, 0, self.stereo)
        self.assert_copied_aac(output, 1, self.surround)

        self.project(replacement=False)
        output, _ = self.export("selection.mkv", "--audio", "pcm")
        self.assertEqual([track["disposition"]["default"] for track in tracks(output)], [1, 0])
        self.assertEqual(pcm(output), pcm(self.a))
        self.assertEqual(pcm(output, 1), self.expected_b(replacement=False))

    def test_refuses_incompatible_container_and_audio_delivery(self):
        self.project(replacement=False)
        _, result = self.export("unsupported.mp4", "--audio", "pcm", ok=False, dry_run=True)
        self.assertIn("MP4", result["error"]["message"])
        # Audio-only preflight isolates the WebM audio rule from H.264 picture support.
        _, result = self.export("unsupported.webm", "--tracks", "audio", "--audio", "auto",
                                "--audio-output", "downmix_mono", ok=False, dry_run=True)
        self.assertIn("WEBM", result["error"]["message"].upper())

    def test_matroska_pcm_layout_is_checked_before_export(self):
        self.project(replacement=False)
        project = read_project(self.project_path)
        surround = self.root / "pcm-surround.mov"
        project["audio_sources"] = [{"id": "surround", "file": str(surround)}]
        project["mix_lanes"][1]["target"] = {
            "kind": "recording", "source_id": "surround", "audio_stream_index": 0,
        }
        self.project_path.write_text(json.dumps(project))

        ffmpeg("-f", "lavfi", "-i", f"anullsrc=r={RATE}:cl=5.1(side)", "-t", "4",
               "-c:a", "pcm_s16le", surround)
        self.assertEqual(tracks(surround)[0]["channel_layout"], "5.1(side)")
        for action in ("pcm", "auto"):
            with self.subTest(action=action):
                _, result = self.export(f"side-{action}.mkv", "--audio", action, ok=False, dry_run=True)
                self.assertEqual(result["error"]["lane_id"], "lane-b")
                self.assertIn("5.1(side)", result["error"]["message"])
                self.assertIn("MKV", result["error"]["message"])

        surround.unlink()
        ffmpeg("-f", "lavfi", "-i", f"anullsrc=r={RATE}:cl=5.1", "-t", "4", "-c:a", "pcm_s16le", surround)
        output, report = self.export("standard-surround.mkv", "--audio", "pcm")
        self.assertEqual(report["audio_lanes"][1]["channel_layout"], "5.1")
        self.assertEqual([track["channels"] for track in tracks(output)], [1, 6])
        self.assertEqual(pcm(output, 1), pcm(surround))

    def test_copy_downmix_offers_rendered_audio_with_copied_picture(self):
        self.project(replacement=False)
        _, result = self.export("downmix-copy.mov", "--audio", "copy",
                                "--audio-output", "downmix_stereo", ok=False, dry_run=True)
        self.assertEqual(result["error"]["code"], "unsupported_audio")
        offered = {offer["audio"]: offer for offer in result["error"]["alternatives"]
                   if offer["mode"] == "copy" and offer["container"] == "mov"}
        self.assertEqual(set(offered), {"pcm", "aac"})
        for codec, offer in offered.items():
            self.assertIn("downmix_stereo", offer["arguments"])
            _, preflight = self.export(f"downmix-{codec}.mov", "--audio", codec,
                                       "--audio-output", "downmix_stereo", dry_run=True)
            lane, = preflight["audio_lanes"]
            self.assertEqual(lane["action"], codec)

    def test_pcm_offer_tries_a_container_that_can_copy_the_picture(self):
        self.project(replacement=False)
        picture = self.root / "vp8.webm"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=d=4:s=96x64:r=25",
               "-vf", "format=yuva420p,colorchannelmixer=aa=0.5", "-c:v", "libvpx",
               "-pix_fmt", "yuva420p", "-auto-alt-ref", "0", "-an", picture)
        project = read_project(self.project_path)
        project["angles"][0] = {"id": "a", "file": str(picture)}
        project["mix_lanes"].pop(0)
        self.project_path.write_text(json.dumps(project))

        _, result = self.export("downmix.webm", "--audio", "copy",
                                "--audio-output", "downmix_stereo", ok=False, dry_run=True)
        offer, = [offer for offer in result["error"]["alternatives"]
                  if offer["audio"] == "pcm" and offer["mode"] == "copy"]
        self.assertEqual(offer["container"], "mkv")
        _, preflight = self.export("downmix.mkv", "--audio", "pcm",
                                   "--audio-output", "downmix_stereo", dry_run=True)
        self.assertEqual(rational_time(preflight["encoded_video_duration"]), 0)

    def test_replacement_copy_and_stereo_downmix_keep_the_same_clap_positions(self):
        self.project()
        separate, _ = self.export("separate.mov", "--audio", "copy")
        _, preflight = self.export("stereo.mov", "--audio", "pcm", "--audio-output", "downmix_stereo", dry_run=True)
        lane, = preflight["audio_lanes"]
        self.assertEqual(preflight["audio_output"], "downmix_stereo")
        self.assertEqual(lane["source_lane_ids"], ["lane-a", "lane-b"])
        self.assertEqual(lane["action"], "pcm")
        self.assertEqual(lane["channel_layout"], "stereo")
        stereo, _ = self.export("stereo.mov", "--audio", "pcm", "--audio-output", "downmix_stereo")

        expected_b = self.expected_b()
        self.assert_separate_tracks(separate, expected_b)
        b = array("h", pcm(separate, 1))
        for position, polarity in ((Fraction(9, 4), 1), (Fraction(15, 4), -1)):
            sample = int(position * RATE)
            self.assertEqual(b[sample - 1], 0)
            self.assertGreater(polarity * b[sample], 25_000)
            self.assertEqual(b[sample + 1], 0)
        self.assert_stereo_mix(stereo, pcm(self.a), expected_b)
        self.assertEqual(timestamped_hashes(separate), timestamped_hashes(self.a))
        self.assertEqual(timestamped_hashes(stereo), timestamped_hashes(self.a))

    def test_nested_mix_join_keeps_ordered_lanes_and_bound_audio(self):
        self.project()
        clips = [{"project_path": str(self.project_path), "from": start, "to": end}
                 for start, end in (("2", "4"), ("0", "2"), ("2", "4"))]
        output, report = self.join("nested.mov", clips)
        self.assertEqual([lane["id"] for lane in report["audio_lanes"]], ["lane-a", "lane-b"])
        self.assertEqual([lane["id"] for lane in report["plan"]["audio_lanes"]], ["lane-a", "lane-b"])
        binding_spans = [span for span in report["plan"]["audio_lanes"][1]["spans"]
                         if span.get("replacement_binding_id") == "replacement-b2"]
        self.assertEqual(len(binding_spans), 2)
        expected_a = pcm_slice(pcm(self.a), 2, 4) + pcm_slice(pcm(self.a), 0, 2) + pcm_slice(pcm(self.a), 2, 4)
        original_b = self.expected_b()
        replacement = pcm_slice(original_b, 2, 4)
        expected_b = replacement + pcm_slice(original_b, 0, 2) + replacement
        self.assertEqual(pcm(output), expected_a)
        self.assertEqual(pcm(output, 1), expected_b)

        stereo, report = self.join("nested-stereo.mov", clips, "--audio-output", "downmix_stereo", "--audio", "pcm")
        self.assertEqual(report["audio_lanes"][0]["source_lane_ids"], ["lane-a", "lane-b"])
        self.assert_stereo_mix(stereo, expected_a, expected_b)
        self.assertEqual(timestamped_hashes(output), timestamped_hashes(stereo))

    def test_join_with_a_different_lane_layout_can_remove_audio(self):
        self.project()
        clips = [{"project_path": str(self.project_path)}, {"file": str(self.a)}]
        _, result = self.join("incompatible.mov", clips, ok=False)
        self.assertEqual(result["error"]["code"], "multicam_audio_join_unsupported")
        self.assertEqual(result["error"]["segment"], 2)
        for name, options in (("remove.mov", ["--audio", "remove"]),
                              ("video.mov", ["--tracks", "video"])):
            output, report = self.join(name, clips, *options)
            self.assertEqual(tracks(output), [])
            self.assertEqual(report["audio_lanes"], [])

        clips[0]["from"] = "1/2"
        _, result = self.join("off-keyframe.mov", clips, "--tracks", "video", ok=False, dry_run=True)
        nearest = result["error"]["nearest"]
        self.assertTrue(nearest, result)
        for time in nearest:
            clips[0]["from"] = str(rational_time(time))
            self.join("verified-cut.mov", clips, "--tracks", "video", dry_run=True)

    def test_nested_mix_with_visible_still_preserves_bound_audio(self):
        self.project()
        project = read_project(self.project_path)
        title = self.root / "title.png"
        ffmpeg("-i", self.a, "-an", "-frames:v", "1", title)
        project["still_assets"] = [{
            "id": "title", "file": str(title), "display_name": "Title",
            "fingerprint": hashlib.sha256(title.read_bytes()).hexdigest(),
        }]
        project["still_replacements"] = [{
            "id": "still", "asset_id": "title", "framing": {"mode": "fit", "background": "#000000"},
            "group": {"from": "2", "to": "3"},
        }]
        self.project_path.write_text(json.dumps(project))
        clip = {"project_path": str(self.project_path), "from": "2", "to": "4"}
        output, _ = self.join("visible.mov", [clip, clip], mode="smart")
        self.assertEqual(pcm(output), pcm_slice(pcm(self.a), 2, 4) * 2)
        self.assertEqual(pcm(output, 1), pcm_slice(self.expected_b(), 2, 4) * 2)

    def test_nested_follow_with_bound_audio_can_join_an_ordinary_recording(self):
        self.project()
        project = read_project(self.project_path)
        del project["mix_lanes"]
        project["audio"] = {"mode": "follow"}
        project["switches"].append({"group_time": "2", "angle_id": "b"})
        self.project_path.write_text(json.dumps(project))
        clip = {"project_path": str(self.project_path), "from": "2", "to": "4"}
        output, _ = self.join("single-bound.mov", [clip, {"file": str(self.b2)}])
        self.assertEqual(pcm(output), pcm_slice(self.expected_b(), 2, 4) + pcm(self.b2))

    def test_interior_gap_refuses_copy_and_retains_the_other_lane(self):
        self.project(gap=True)
        _, report = self.export("cannot-copy.mov", "--audio", "copy", ok=False, dry_run=True)
        error = report["error"]
        self.assertEqual(error["lane_id"], "lane-b")
        gap = error["multicam"]["assembly_range"]
        self.assertEqual((rational_time(gap["from"]), rational_time(gap["to"])), (1, 2))

        _, plan = self.export("filled.mov", "--audio", "auto", dry_run=True)
        copy, filled = plan["audio_lanes"]
        self.assertEqual((copy["id"], filled["id"]), ("lane-a", "lane-b"))
        self.assertEqual(copy["action"], "copy")
        self.assertTrue(filled["retained_pcm"])
        gap, = filled["generated_silence"]
        self.assertEqual((rational_time(gap["from"]), rational_time(gap["to"])), (1, 2))
        output, _ = self.export("filled.mov", "--audio", "auto")
        expected_b = self.expected_b(gap=True)
        self.assert_separate_tracks(output, expected_b)
        rendered, _ = self.export("rendered-lanes.mov", "--audio", "pcm")
        self.assertEqual(pcm(rendered), pcm(self.a))
        self.assertEqual(pcm(rendered, 1), expected_b)
        stereo, _ = self.export("gap-stereo.mov", "--audio", "pcm", "--audio-output", "downmix_stereo")
        self.assert_stereo_mix(stereo, pcm(self.a), expected_b)
        self.assertEqual(timestamped_hashes(stereo), timestamped_hashes(self.a))

    def test_inserted_still_shifts_both_lanes_and_adds_one_second_of_silence(self):
        self.project(still=True)
        separate, _ = self.export("still-separate.mov", "--audio", "pcm", mode="smart")
        stereo, _ = self.export("still-stereo.mov", "--audio", "pcm", "--audio-output", "downmix_stereo", mode="smart")
        a, b = pcm(self.a), self.expected_b()
        silence = bytes(RATE * 2)
        expected_a = pcm_slice(a, 0, 1) + silence + pcm_slice(a, 2, 4)
        expected_b = pcm_slice(b, 0, 1) + silence + pcm_slice(b, 2, 4)
        self.assertEqual(pcm(separate), expected_a)
        self.assertEqual(pcm(separate, 1), expected_b)
        self.assert_stereo_mix(stereo, expected_a, expected_b)
        for output in (separate, stereo):
            stream, = probe(output, "-select_streams", "v", "-show_streams")["streams"]
            self.assertEqual(track_time(stream, "duration_ts"), 4)

    def test_pcm_downmix_averages_at_unity_and_does_not_renormalize_silence(self):
        for second in (self.peak_b, self.silence):
            self.project(replacement=False, second_peak=second)
            first = pcm(self.peak)
            expected_first = pcm_slice(first, 2, 4) + pcm_slice(first, 0, 1)
            second_audio = pcm(second)
            expected_second = pcm_slice(second_audio, 2, 4) + pcm_slice(second_audio, 0, 1)
            for delivery, channels in (("downmix_mono", 1), ("downmix_stereo", 2)):
                with self.subTest(second=second.name, delivery=delivery):
                    output, _ = self.export(f"{second.stem}-{delivery}.mov", "--audio", "pcm",
                                            "--audio-output", delivery)
                    track, = tracks(output)
                    self.assertEqual(track["channels"], channels)
                    self.assertEqual(int(track["sample_rate"]), RATE)
                    actual = array("h", pcm(output))
                    self.assertEqual(len(actual), channels * 3 * RATE)
                    reference = [a + b for a, b in zip(array("h", expected_first), array("h", expected_second))]
                    for channel in range(channels):
                        self.assertLessEqual(max(abs(2 * a - b) for a, b in zip(actual[channel::channels], reference)), 1)
                    expected_peak = 0.7 if second == self.peak_b else 0.35
                    self.assertAlmostEqual(max(actual) / 32768, expected_peak, delta=0.00005)
                    source_frames = sample_hashes(self.a)
                    self.assertEqual(sample_hashes(output), source_frames[50:100] + source_frames[:25])

    def test_legacy_multicam_modes_keep_the_same_routes_after_saving_v4(self):
        self.project(replacement=False)
        original_path = self.project_path
        payload = read_project(original_path)
        del payload["mix_lanes"]
        payload["schema_version"] = 3
        for mode in ("fixed", "follow", "none"):
            with self.subTest(mode=mode):
                payload["audio"] = {"mode": mode}
                if mode == "fixed":
                    payload["audio"].update(source_id="a", audio_stream_index=1)
                payload["switches"] = [
                    {"group_time": "0", "angle_id": "a"},
                    {"group_time": "1", "angle_id": "b"},
                    {"group_time": "2", "angle_id": "a"},
                ]
                if mode != "none":
                    payload["switches"][1]["audio"] = {
                        "source_id": "b" if mode == "fixed" else "a",
                        "audio_stream_index": 1,
                    }
                self.project_path = original_path
                contents = json.dumps(payload).encode()
                self.project_path.write_bytes(contents)
                original_output, before = self.export(f"v3-{mode}.mov")
                self.assertEqual(self.project_path.read_bytes(), contents)
                upgraded = self.root / f"v4-{mode}.cut"
                request = {"project_path": str(original_path), "out_project": str(upgraded), "operations": []}
                command = [CLI, "project", "edit", "--stdin", "--json"]
                saved = subprocess.run(command, input=json.dumps(request), capture_output=True, text=True, timeout=90)
                self.assertEqual(saved.returncode, 0, saved.stdout + saved.stderr)
                self.assertEqual(original_path.read_bytes(), contents)
                reopened = read_project(upgraded)
                self.assertEqual(reopened["schema_version"], 4)
                self.assertEqual(reopened["switches"], payload["switches"])
                self.project_path = upgraded
                upgraded_output, after = self.export(f"v4-{mode}.mov")
                self.assertEqual(before["plan"], after["plan"])
                self.assertEqual(timestamped_hashes(original_output), timestamped_hashes(upgraded_output))
                if mode == "none":
                    self.assertEqual(probe(upgraded_output, "-select_streams", "a", "-show_streams").get("streams", []), [])
                else:
                    self.assertEqual(pcm(original_output), pcm(upgraded_output))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
