#!/usr/bin/env python3
"""Exercise participant picture and ISO workflows against a TileTrail-enabled mpcut.

Run with python3 Tests/Integration/participant_e2e.py path/to/mpcut.
Add --benchmark-runs 3 to repeat scan and encode commands with macOS time(1).
Use the bundled CLI, or set MPCUT_FFMPEG_HELPER for an unbundled development build.
The fixture generator and independent decoder use ffmpeg and ffprobe on PATH.
"""

import argparse
from collections import defaultdict
from fractions import Fraction
from itertools import groupby
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from participant_e2e_fixture import (
    CARD, COVER, FPS, FRAME_COUNT, GAP, GUEST, HEIGHT, HOST, RATE, STAGE, THUMB, WIDTH,
    frame_times, generate, generate_camera, pixel, probe, sound, tiles_at, video,
)

CLI = None
BENCHMARK_RUNS = 0
BENCHMARK = defaultdict(list)
SIZE = (160, 90)


def rational(value):
    if isinstance(value, dict):
        return Fraction(value["numerator"], value["denominator"])
    return Fraction(value)


def interval(start, end):
    return {"from": str(start), "to": str(end)}


def color(rgb):
    return int.from_bytes(bytes(rgb), "big")


def canvas(size=SIZE):
    width, height = size
    return {"width": width, "height": height, "frame_rate": {"numerator": FPS, "denominator": 1},
            "background": color(GAP)}


def slot(participant, *, target="participant", include_card=False, framing="fill"):
    return {"id": participant, "target": target, "framing": framing, "anchor_x": 0.5, "anchor_y": 0.5,
            "include_camera_off": include_card}


def shot(layout, *slots, **kwargs):
    return {"layout": layout, "slots": list(slots), "clock": "output", "compact": False, **kwargs}


def plan(layout, *slots, audio="silence", ids=(), size=SIZE, redactions=(), unresolved="stop"):
    return {"canvas": canvas(size), "shots": [shot(layout, *slots)], "audio": {"mode": audio, "ids": list(ids)},
            "redactions": list(redactions), "unresolved_privacy": unresolved}


def bounds(rect):
    return dict(zip(("x", "y", "width", "height"),
                    (coordinate / dimension for coordinate, dimension in zip(rect, (WIDTH, HEIGHT, WIDTH, HEIGHT)))))


def geometry():
    frames_by_tile = defaultdict(list)
    for index in range(FRAME_COUNT):
        for tile in tiles_at(index):
            frames_by_tile[tile].append(index)
    appearances = []
    for tile, indices in frames_by_tile.items():
        for _, run in groupby(enumerate(indices), key=lambda item: item[1] - item[0]):
            consecutive = [index for _, index in run]
            begin, end = consecutive[0], consecutive[-1] + 1
            appearances.append({
                "id": f"{tile.appearance}-{begin}",
                "participant_id": tile.participant,
                "range": interval(Fraction(begin, FPS), Fraction(end, FPS)),
                "bounds": bounds(tile.rect),
                "role": tile.role,
                "state": "camera_off" if tile.camera_off else "video",
            })
    return {"source_id": "gallery", "appearances": appearances,
            "coverage": [{"range": interval(0, 5), "state": "verified"}]}


class ParticipantE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workspace = tempfile.TemporaryDirectory(prefix="mpcut-participant-")
        cls.addClassCleanup(workspace.cleanup)
        cls.root = Path(workspace.name)
        cls.gallery, cls.recorder, cls.iso_offset = generate(cls.root)

    def setUp(self):
        self.folder = self.root / self._testMethodName
        self.folder.mkdir()

    def cli(self, *args, request=None, ok=True, measurement=None, outputs=()):
        command = [str(CLI), *args, "--no-sidecar", "--json"]
        body = None
        if request is not None:
            command.append("--stdin")
            body = json.dumps(request)

        measured = measurement and BENCHMARK_RUNS
        for run in range(BENCHMARK_RUNS if measured else 1):
            if run:
                for output in outputs:
                    output.unlink()
            invocation = ["/usr/bin/time", "-lp", *command] if measured else command
            result = subprocess.run(invocation, input=body, text=True, capture_output=True, timeout=180)
            if ok:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            else:
                self.assertIn(result.returncode, (1, 2), result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertIsInstance(report, dict)
            if not ok:
                self.assertFalse(report["ok"], report)
                self.assertIsInstance(report["error"]["code"], str)
            if measured:
                elapsed = re.search(r"^real ([0-9.]+)$", result.stderr, re.MULTILINE)
                rss = re.search(r"^\s*(\d+)\s+maximum resident set size$", result.stderr, re.MULTILINE)
                self.assertTrue(elapsed and rss, result.stderr)
                BENCHMARK[measurement].append({"wall_seconds": float(elapsed[1]), "max_rss_bytes": int(rss[1])})
        return report

    def base(self, name="base", assembly=None):
        base = self.folder / f"{name}.cut"
        payload = {
            "format": "mpcut",
            "schema_version": 4,
            "kind": "multicam",
            "reference_angle_id": "gallery",
            "group_range": interval(0, 5),
            "angles": [{"id": "gallery", "file": str(self.gallery), "audio_stream_index": 1}],
            "audio_sources": [{"id": "recorder", "file": str(self.recorder), "offset": str(self.iso_offset)}],
            "audio": {"mode": "fixed", "source_id": "gallery", "audio_stream_index": 1},
            "switches": [{"group_time": "0", "angle_id": "gallery"}],
        }
        if assembly is not None:
            payload["assembly"] = assembly
        base.write_text(json.dumps(payload))
        return base

    def approved(self, base, name="approved", *, edited_geometry=None, overrides=(), render=None):
        path = self.folder / f"{name}.cut"
        participants = {
            "people": [
                {"id": "host", "name": "Host", "speakers": []},
                {"id": "guest", "name": "Guest", "speakers": [],
                 "audio": {"selection": {"source_id": "recorder", "audio_stream_index": 1}}},
            ],
            "sources": [geometry() if edited_geometry is None else edited_geometry],
            "appearance_overrides": list(overrides),
        }
        if render is not None:
            participants["render"] = render
        original = base.read_bytes()
        self.cli("participants", "project", "apply",
                 request={"project_path": str(base), "out_project": str(path), "participants": participants})
        self.assertEqual(base.read_bytes(), original)
        self.assertTrue(path.is_file())
        return path

    def export(self, path, name, render=None, *, ok=True, measurement=None):
        output = self.folder / f"{name}.mov"
        request = {"project_path": str(path), "output": str(output)}
        if render is not None:
            request["plan"] = render
        report = self.cli("participants", "render", "export", request=request, ok=ok,
                          measurement=measurement, outputs=(output,))
        self.assertEqual(output.exists(), ok, report)
        return output, report

    def decode(self, path, size=SIZE, frame_count=FRAME_COUNT, codec="h264"):
        stream, frames = video(path)
        self.assertEqual(stream["codec_name"], codec)
        self.assertEqual((stream["width"], stream["height"]), size)
        self.assertEqual(frame_times(path, stream), [Fraction(index, FPS) for index in range(frame_count)])
        self.assertEqual(len(frames), frame_count)
        self.assertEqual(Fraction(stream["time_base"]) * int(stream["duration_ts"]), Fraction(frame_count, FPS))
        return frames

    def assert_color(self, frame, width, x, y, expected, context, tolerance=22):
        actual = pixel(frame, width, x, y)
        self.assertLessEqual(max(abs(value - target) for value, target in zip(actual, expected)), tolerance,
                             f"{context}, pixel ({x}, {y}): {actual} != {expected}")

    def iso_pcm(self):
        return bytes(2 * int(self.iso_offset * RATE)) + sound(self.recorder, 1)

    def test_sequence_iso_accepts_another_path_to_the_same_recording(self):
        alias = self.folder / "linked-gallery.mov"
        os.link(self.gallery, alias)
        document = self.folder / "sequence.cut"
        document.write_text(json.dumps({
            "format": "mpcut", "schema_version": 4, "kind": "sequence",
            "clips": [{"id": "gallery", "file": str(self.gallery), "from": "0", "to": "5"}],
            "participants": {
                "people": [{"id": "host", "name": "Host",
                            "audio": {"selection": {"source_id": str(alias), "audio_stream_index": 1}}}],
            },
        }))
        output, report = self.export(document, "linked", plan("original", audio="iso", ids=("host",)))
        self.assertEqual(report["audio_actions"][0]["generated_silence"], [])
        self.assertEqual(sound(output), sound(self.gallery))

    def test_materialized_angles_share_clock_and_one_meeting_mix(self):
        approved = self.approved(self.base())
        request = {"project_path": str(approved), "source_id": "gallery",
                   "participant_ids": ["guest", "host"], "range": interval(0, 5)}
        virtual = self.cli("participants", "angles", "list", request=request)["angles"]
        self.assertEqual([(angle["id"], angle["kind"], angle["range"]) for angle in virtual],
                         [(person, "participant", interval(0, 5)) for person in ("guest", "host")])

        delivery = self.folder / "delivery"
        self.cli("participants", "angles", "render",
                 request={**request, "canvas": canvas(), "output_directory": str(delivery)})
        reopened = delivery / "multicam.cut"
        payload = json.loads(reopened.read_text())
        self.assertEqual(payload["group_range"], interval(0, 5))
        self.assertEqual([angle["id"] for angle in payload["angles"]], ["guest", "host"])
        for person, angle in zip(("guest", "host"), payload["angles"]):
            output = delivery / angle["file"]
            frames = self.decode(output)
            self.assertEqual(probe(output, "-select_streams", "a", "-show_streams")["streams"], [])
            expected = GUEST if person == "guest" else HOST
            self.assert_color(frames[0], SIZE[0], SIZE[0] // 2, SIZE[1] // 2, expected, person)
        audio_source, = payload["audio_sources"]
        self.assertEqual(payload["audio"]["mode"], "fixed")
        self.assertEqual(payload["audio"]["source_id"], audio_source["id"])
        self.assertEqual(sound(delivery / audio_source["file"]), sound(self.gallery))
        self.cli("project", "inspect", "--project", str(reopened))

        isolated = self.folder / "delivery-with-iso"
        self.cli("participants", "angles", "render",
                 request={**request, "canvas": canvas(), "audio": {"include_isos": True},
                          "output_directory": str(isolated)})
        payload = json.loads((isolated / "multicam.cut").read_text())
        guest, host = payload["angles"]
        self.assertNotIn("audio_stream_index", host)
        self.assertEqual(sound(isolated / guest["file"]), self.iso_pcm())
        lane, = payload["mix_lanes"]
        self.assertEqual(lane["target"], {"kind": "recording", "source_id": "guest",
                                          "audio_stream_index": guest["audio_stream_index"]})
        audio_source, = payload["audio_sources"]
        self.assertEqual(sound(isolated / audio_source["file"]), sound(self.gallery))

    def test_scan_generated_gallery(self):
        report = self.cli("participants", "scan", "--file", str(self.gallery), "--backend", "cpu-only",
                          "--sampling", "every-frame", measurement="scan_cpu_every_frame")
        self.assertEqual(report["state"], "completed", report)
        analysis = report["analysis"]
        self.assertEqual([rational(item["timestamp"]) for item in analysis["observations"]],
                         [Fraction(index, FPS) for index in range(FRAME_COUNT)])
        self.assertEqual({item["backend"] for item in analysis["diagnostics"]}, {"cpu"})
        self.assertFalse(self.gallery.with_name("gallery.mov.cutdb").exists())

    def test_extraction_reopens_with_accepted_geometry_and_late_iso(self):
        # The approved project contains all geometry. No machine scan is run for
        # this case, and each CLI invocation opens the document in a fresh process.
        solo = plan("solo", slot("guest"), audio="iso", ids=("guest",))
        base = self.base()
        approved = self.approved(base, render=solo)
        output, _ = self.export(approved, "guest", measurement="extract_guest_iso")
        for index, frame in enumerate(self.decode(output)):
            expected = GUEST
            if 16 <= index < 24:
                expected = STAGE
            elif 24 <= index < 32 and index != 27:
                expected = GAP
            self.assert_color(frame, SIZE[0], SIZE[0] // 2, SIZE[1] // 2, expected, f"solo frame {index}")

        audio, = probe(output, "-select_streams", "a", "-show_streams")["streams"]
        self.assertEqual((audio["channels"], int(audio["sample_rate"])), (1, RATE))
        self.assertEqual(sound(output), self.iso_pcm())

        pinned = {"participant_id": "guest", "source_id": "gallery", "appearance_id": "guest-thumb-16",
                  "range": interval(2, Fraction(7, 2))}
        approved = self.approved(base, "pinned", overrides=(pinned,))
        output, _ = self.export(approved, "pinned", plan("solo", slot("guest", include_card=True)))
        frames = self.decode(output)
        for index, expected in ((16, THUMB), (23, THUMB), (24, GAP), (27, GAP), (30, CARD), (31, CARD), (32, GUEST)):
            self.assert_color(frames[index], SIZE[0], SIZE[0] // 2, SIZE[1] // 2, expected, f"pin frame {index}")

    def test_opaque_redaction_covers_all_appearances_and_unresolved_frames(self):
        base = self.base()
        accepted = geometry()
        frames = self.decode(self.gallery, size=(WIDTH, HEIGHT), codec="prores")
        self.assert_color(frames[27], WIDTH, 240, 90, GUEST, "guest in the encoded source")
        # The actual gallery has a one-frame return inside this part of the scan.
        # Simulate a sampled result with no confirmed identity on that frame.
        accepted["appearances"] = [a for a in accepted["appearances"] if a["id"] != "guest-flash-27"]
        accepted["coverage"] = [
            {"range": interval(0, Fraction(27, FPS)), "state": "verified"},
            {"range": interval(Fraction(27, FPS), Fraction(28, FPS)), "state": "inferred"},
            {"range": interval(Fraction(28, FPS), 5), "state": "verified"},
        ]
        approved = self.approved(base, edited_geometry=accepted)
        opaque = plan("original", size=(WIDTH, HEIGHT),
                      redactions=({"participant_id": "guest", "treatment": "opaque", "color": color(COVER)},))
        opaque["canvas"]["background"] = color(COVER)
        preflight = self.cli("participants", "render", "plan",
                             request={"project_path": str(approved), "plan": opaque})
        self.assertFalse(preflight["publishable"])
        self.assertEqual(preflight["privacy_issues"], [
            {"source_id": "gallery", "source": interval(Fraction(27, FPS), Fraction(28, FPS)),
             "output": interval(Fraction(27, FPS), Fraction(28, FPS))},
        ])
        _, refusal = self.export(approved, "must-stop", opaque, ok=False)
        self.assertEqual(refusal["error"]["code"], "unresolved_participant_privacy")
        opaque["unresolved_privacy"] = "cover"
        output, report = self.export(approved, "covered", opaque, measurement="encode_opaque_gallery")
        self.assertTrue(report["publishable"])
        self.assertEqual(report["privacy_issues"], preflight["privacy_issues"])
        for index, frame in enumerate(self.decode(output, size=(WIDTH, HEIGHT))):
            if index == 27:
                self.assertLessEqual(max(frame), 14, "Opaque fallback exposed a pixel on the unresolved frame")
                continue
            for tile in tiles_at(index):
                x, y, width, height = tile.rect
                if tile.participant == "host":
                    self.assert_color(frame, WIDTH, x + width // 2, y + height // 2, HOST, f"host frame {index}")
                    continue
                # Leave a two-pixel margin for chroma subsampling at the mask edge.
                # This checks all remaining tile pixels, including the nameplate.
                for line in range(y + 2, y + height - 2):
                    start = 3 * (line * WIDTH + x + 2)
                    end = start + 3 * (width - 4)
                    self.assertLessEqual(max(frame[start:end]), 14, f"frame {index}: exposed {tile.appearance}")

    def test_two_camera_interview_pads_only_the_missing_camera(self):
        host = generate_camera(self.folder / "host.mov", HOST, 5)
        guest = generate_camera(self.folder / "guest.mov", GUEST, 2)
        project = self.folder / "cameras.cut"
        project.write_text(json.dumps({
            "format": "mpcut", "schema_version": 4, "kind": "multicam",
            "reference_angle_id": "host-camera", "group_range": interval(0, 5),
            "angles": [{"id": "host-camera", "file": str(host)},
                       {"id": "guest-camera", "file": str(guest), "offset": "1",
                        "group_coverage": interval(1, 3)}],
            "audio": {"mode": "none"},
            "switches": [{"group_time": "0", "angle_id": "host-camera"}],
        }))
        render = plan("pair", slot("host-camera", target="camera", framing="fit"),
                      slot("guest-camera", target="camera"), size=(320, 90))
        output, _ = self.export(project, "two-cameras", render, measurement="encode_two_cameras")
        frames = self.decode(output, size=(320, 90))
        for index, frame in enumerate(frames):
            self.assert_color(frame, 320, 80, 45, HOST, f"host camera frame {index}")
            expected = GUEST if FPS <= index < 3 * FPS else GAP
            self.assert_color(frame, 320, 240, 45, expected, f"guest camera frame {index}")

    def test_repeated_source_uses_occurrence_shot_and_one_program_mix(self):
        base = self.base(assembly=[interval(1, 3), interval(1, 3)])
        approved = self.approved(base)
        render = plan("solo", slot("guest"), audio="program", size=(320, 90))
        render["shots"].append(shot("pair", slot("host", framing="fit"), slot("guest"),
                                    range=interval(2, 4), occurrence=1))
        output, _ = self.export(approved, "interview", render)
        frames = self.decode(output, size=(320, 90), frame_count=4 * FPS)
        for index, frame in enumerate(frames):
            guest = STAGE if index % 16 >= 8 else GUEST
            left = guest if index < 16 else HOST
            self.assert_color(frame, 320, 80, 45, left, f"left frame {index}")
            self.assert_color(frame, 320, 240, 45, guest, f"right frame {index}")
            if index >= 16:
                self.assert_color(frame, 320, 6, 45, GAP, f"host fit frame {index}")
                self.assert_color(frame, 320, 314, 45, guest, f"guest fill frame {index}")
        self.assertEqual(len(probe(output, "-select_streams", "a", "-show_streams")["streams"]), 1)
        expected = sound(self.gallery)[2 * RATE: 6 * RATE] * 2
        self.assertEqual(sound(output), expected)

        render["redactions"] = [{"participant_id": "guest", "treatment": "opaque", "color": color(COVER)}]
        output, _ = self.export(approved, "interview-redacted", render)
        frames = self.decode(output, size=(320, 90), frame_count=4 * FPS)
        for index, frame in enumerate(frames):
            left = COVER if index < 16 else HOST
            self.assert_color(frame, 320, 80, 45, left, f"redacted left frame {index}")
            self.assert_color(frame, 320, 240, 45, COVER, f"redacted right frame {index}")

    def test_ordinary_project_export_keeps_saved_privacy(self):
        redaction = {"participant_id": "guest", "treatment": "opaque", "color": color(COVER)}
        render = plan("original", size=(WIDTH, HEIGHT), redactions=[redaction])
        multicam = self.approved(self.base(), render=render)
        sequence = self.folder / "sequence.cut"
        participants = json.loads(multicam.read_text())["participants"]
        participants["sources"][0]["source_id"] = str(self.gallery)
        participants["people"][1].pop("audio")
        sequence.write_text(json.dumps({"format": "mpcut", "schema_version": 4, "kind": "sequence",
                                        "clips": [{"id": "gallery", "file": str(self.gallery), **interval(0, 5)}],
                                        "participants": participants}))
        for project in (multicam, sequence):
            with self.subTest(project=project.name):
                frames = self.folder / (project.stem + "-frames")
                refused = self.cli("review", "frames", "export", "--project", str(project), "--at", "0",
                                   "--output", str(frames), ok=False)
                self.assertEqual(refused["error"]["code"], "participant_render_unavailable", refused)
                self.assertFalse(frames.exists())
                output = self.folder / (project.stem + ".mov")
                args = ("export", "project", "render", "--project", str(project), "--output", str(output))
                for mode in ("copy", "smart"):
                    refused = self.cli(*args, "--mode", mode, ok=False)
                    self.assertEqual(refused["error"]["code"], "participant_render_requires_encoding", refused)
                refused = self.cli(*args, "--require-camera-copy", ok=False)
                self.assertEqual(refused["error"]["code"], "camera_copy_required", refused)
                dry_run = self.cli(*args, "--dry-run")
                self.assertEqual(dry_run["mode"], "encode")
                self.assertEqual(dry_run["tier"]["id"], "reencode")
                self.assertTrue(dry_run["participant_render"]["publishable"])
                self.assertFalse(output.exists())
                result = self.cli(*args)
                self.assertTrue(result["participant_render"]["publishable"])
                first = self.decode(output, size=(WIDTH, HEIGHT))[0]
                guest = next(tile for tile in tiles_at(0) if tile.participant == "guest")
                x, y, width, height = guest.rect
                self.assert_color(first, WIDTH, x + width // 2, y + height // 2, COVER, "ordinary project export")

        unknown = geometry()
        unknown["coverage"] = [{"range": interval(0, 5), "state": "inferred"}]
        blocked = self.approved(self.base("blocked-base"), "blocked", edited_geometry=unknown, render=render)
        output = self.folder / "blocked.mov"
        args = ("export", "project", "render", "--project", str(blocked), "--output", str(output))
        for options in (("--dry-run",), ()):
            refused = self.cli(*args, *options, ok=False)
            self.assertEqual(refused["error"]["code"], "unresolved_participant_privacy", refused)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    parser.add_argument("--benchmark-runs", type=int, default=0,
                        help="Repeat selected CLI commands and report wall time and peak RSS (macOS)")
    options, tests = parser.parse_known_args()
    if options.benchmark_runs < 0:
        parser.error("--benchmark-runs must be nonnegative")
    CLI = options.mpcut.resolve(strict=True)
    BENCHMARK_RUNS = options.benchmark_runs
    suite = unittest.main(argv=[__file__, *tests], exit=False)
    if BENCHMARK:
        print(json.dumps(BENCHMARK, indent=2, sort_keys=True))
    raise SystemExit(not suite.result.wasSuccessful())
