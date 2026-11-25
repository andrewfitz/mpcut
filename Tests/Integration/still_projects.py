#!/usr/bin/env python3
"""Exercise saved still placement authoring, inspection, and review through the CLI."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib

from saved_project import read_project


CLI = None


def read_time(value):
    if isinstance(value, dict):
        return Fraction(value["numerator"], value["denominator"])
    return Fraction(value)


def ranges(placement):
    return [(read_time(span["output"]["from"]), read_time(span["output"]["to"]))
            for span in placement["visible_occurrences"]]


def png(color):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data)))
    header = struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0)
    pixels = (b"\x00" + bytes(color) * 2) * 2
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) +
            chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


class StillProjectCLI(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="mpcut-still-cli-")
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.image = self.root / "photo.png"
        self.image.write_bytes(png((250, 90, 20)))
        self.project = self.root / "project.cut"

    def run_json(self, *arguments, data=None, success=True):
        result = subprocess.run([CLI, "--no-sidecar", *map(str, arguments), "--json"],
                                cwd=self.root, input=data, text=True, capture_output=True, timeout=90)
        self.assertEqual(result.returncode == 0, success, result.stderr + result.stdout)
        reply = json.loads(result.stdout)
        self.assertEqual(reply["ok"], success)
        return reply

    def sequence(self):
        return {"format": "mpcut", "schema_version": 9, "kind": "sequence",
                "clips": [{"id": identity, "file": "offline.mov", "from": "0", "to": "6"}
                          for identity in ("first", "second")]}

    def test_sequence_save_as_stdin_relink_and_conflicts(self):
        self.project.write_text(json.dumps(self.sequence()))
        destination = self.root / "versions" / "covered.cut"
        destination.parent.mkdir()
        cover = self.run_json("still", "picture", "replace", "--project", "-", "--image", "photo.png",
                              "--clock", "sequence", "--from", "8", "--to", "10",
                              "--out-project", destination, data=self.project.read_text())
        self.assertEqual(cover["duration"], {"numerator": 12, "denominator": 1})
        self.assertEqual(ranges(cover["placements"][0]), [(8, 10)])
        self.assertEqual(cover["placements"][0]["authored_fragments"][0]["clip_id"], "second")
        self.assertEqual(cover["assets"][0]["file"], "../photo.png")
        saved = read_project(destination)
        self.assertEqual(saved["schema_version"], 9)
        self.assertEqual([entry["id"] for entry in saved["clips"]], ["first", "second"])
        before = destination.read_bytes()
        issue = self.run_json("still", "picture", "replace", "--project", destination, "--asset", cover["asset_id"],
                              "--clock", "sequence", "--from", "9", "--to", "11",
                              "--in-place", success=False)["error"]
        self.assertIn(cover["placement_id"], issue["placement_i_ds"])
        self.assertEqual(destination.read_bytes(), before)

        title = self.run_json("still", "placement", "insert", "--project", destination, "--asset", cover["asset_id"],
                              "--clock", "sequence", "--at", "9", "--frames", "1",
                              "--rate", "30000/1001", "--in-place")
        insert_id = title["placement_id"]
        self.assertEqual(read_time(title["duration"]), Fraction(361001, 30000))
        placements = {p["id"]: p for p in title["placements"]}
        self.assertEqual(ranges(placements[cover["placement_id"]]), [(8, 9),
                         (Fraction(271001, 30000), Fraction(301001, 30000))])
        self.assertEqual(ranges(placements[insert_id]), [(9, Fraction(271001, 30000))])

        repaired = self.root / "renamed.png"
        self.image.rename(repaired)
        offline = self.run_json("still", "placement", "list", "--project", destination)
        self.assertTrue(offline["assets"][0]["offline"])
        relinked = self.run_json("still", "asset", "relink", "--project", destination, "--asset", cover["asset_id"],
                                 "--image", repaired, "--in-place")
        self.assertFalse(relinked["assets"][0]["offline"])
        self.assertEqual(relinked["assets"][0]["id"], cover["asset_id"])
        self.assertEqual(relinked["assets"][0]["file"], "../renamed.png")
        self.assertEqual(relinked["assets"][0]["fingerprint"], cover["assets"][0]["fingerprint"])
        self.assertEqual(len(relinked["placements"]), 2)

        reframed = self.run_json("still", "placement", "update", "--project", destination, "--placement",
                                 cover["placement_id"], "--fit", "fill", "--crop-x", "1/2",
                                 "--crop-y", "0.3", "--in-place")
        cover_row = next(row for row in reframed["placements"] if row["id"] == cover["placement_id"])
        self.assertEqual(cover_row["framing"]["mode"], "fill")
        self.assertEqual(read_time(cover_row["framing"]["crop"]["x"]), Fraction(1, 2))
        self.assertEqual(read_time(cover_row["framing"]["crop"]["y"]), Fraction(3, 10))

        replacement = self.root / "replacement.png"
        replacement.write_bytes(png((0, 170, 67)))
        report = self.run_json("project", "media", "replace", destination, "--source", repaired,
                               "--with", replacement, "--in-place")["report"]
        self.assertTrue(report["can_apply"])
        replaced = self.run_json("still", "placement", "list", "--project", destination)
        self.assertFalse(replaced["assets"][0]["offline"])
        self.assertEqual(replaced["assets"][0]["id"], cover["asset_id"])
        self.assertEqual(replaced["assets"][0]["file"], "../replacement.png")
        self.assertNotEqual(replaced["assets"][0]["fingerprint"], cover["assets"][0]["fingerprint"])
        self.assertEqual(replaced["placements"], reframed["placements"])

        deleted = self.run_json("still", "placement", "remove", "--project", destination, "--placement", insert_id, "--in-place")
        self.assertEqual(read_time(deleted["duration"]), 12)
        self.assertEqual(len(deleted["placements"]), 1)

    def test_gap_save_as_copies_transcripts_only_when_published(self):
        source = Path(__file__).resolve().parents[1] / "MPCutAppTests" / "Fixtures" / "Pause-Quiet.mov"
        project = self.sequence()
        project["clips"] = [{"id": "take", "file": str(source), "from": "0", "to": "2"}]
        self.project.write_text(json.dumps(project))
        subtitles = self.root / "take.srt"
        subtitles.write_text("1\n00:00:00,000 --> 00:00:01,000\nOpening line.\n")
        self.run_json("transcript", "attachment", "import", "--project", self.project,
                      "--transcript", subtitles, "--in-place")
        original = self.project.read_bytes()
        blocked = self.root / "blocked.cut"
        blocked.write_bytes(b"Keep this project unchanged")
        insert = ("timeline", "gap", "insert", "--project", self.project, "--clock", "sequence",
                  "--at", "0", "--frames", "3", "--rate", "30", "--out-project")
        refused = self.run_json(*insert, blocked, success=False)
        self.assertEqual(refused["error"]["code"], "destination_exists")
        self.assertEqual(blocked.read_bytes(), b"Keep this project unchanged")
        self.assertFalse(blocked.with_name(blocked.name + ".transcripts").exists())
        copy = self.root / "gap.cut"
        report = self.run_json(*insert, copy)
        asset = report["timeline"]["transcripts"]["attachments"][0]["asset"]
        saved = read_project(copy)
        saved_asset = saved["transcripts"]["attachments"][0]["asset"]
        self.assertEqual(asset, saved_asset)
        self.assertTrue(saved["embedded_assets"]["transcripts"][asset["sha256"]]["words"])
        self.assertFalse(copy.with_name(copy.name + ".transcripts").exists())
        self.assertEqual(self.project.read_bytes(), original)

    def test_group_replacement_repeats_while_assembly_insert_appears_once(self):
        project = {"format": "mpcut", "schema_version": 9, "kind": "multicam",
                   "reference_angle_id": "wide", "group_range": {"from": "0", "to": "8"},
                   "angles": [{"id": "wide", "file": "camera.mov", "offset": "0"}],
                   "audio": {"mode": "none"}, "switches": [{"group_time": "0", "angle_id": "wide"}],
                   "assembly": [{"from": "4", "to": "8"}] * 2}
        self.project.write_text(json.dumps(project))
        photo = self.run_json("still", "picture", "replace", "--project", self.project, "--image", self.image,
                              "--clock", "group", "--from", "5", "--to", "7", "--in-place")
        title = self.run_json("still", "placement", "insert", "--project", self.project, "--asset", photo["asset_id"],
                              "--clock", "assembly", "--at", "4", "--duration", "1",
                              "--rate", "25", "--in-place")
        report = self.run_json("project", "inspect", "--project", self.project)
        self.assertEqual(read_time(report["duration"]), 9)
        placements = {p["id"]: p for p in report["placements"]}
        self.assertEqual(ranges(placements[photo["placement_id"]]), [(1, 3), (6, 8)])
        self.assertEqual(ranges(placements[title["placement_id"]]), [(4, 5)])

    def test_insert_checks_the_overridden_occurrence_camera(self):
        camera = Path(__file__).resolve().parents[1] / "MPCutAppTests" / "Fixtures" / "ProRes-2997.mov"
        project = {"format": "mpcut", "schema_version": 9, "kind": "multicam",
                   "reference_angle_id": "wide", "group_range": {"from": "0", "to": "1/10"},
                   "angles": [{"id": "wide", "file": "offline.mov"}, {"id": "close", "file": str(camera)}],
                   "audio": {"mode": "none"}, "switches": [{"group_time": "0", "angle_id": "wide"}],
                   "assembly": [{"kind": "group", "from": "0", "to": "1/10", "angle_id": "close"}]}
        self.project.write_text(json.dumps(project))
        result = self.run_json("timeline", "gap", "insert", "--project", self.project,
                               "--clock", "assembly", "--at", "1/100", "--frames", "1",
                               "--rate", "30", "--in-place", success=False)
        self.assertEqual(result["error"]["code"], "invalid_still_boundary", result)
        self.assertEqual(read_project(self.project), project)

    def test_offline_replacement_preserves_audio_and_stdin_parity(self):
        fixtures = Path(__file__).resolve().parents[1] / "MPCutAppTests" / "Fixtures"
        camera = fixtures / "Pause-Quiet.mov"
        payload = self.sequence()
        payload["clips"] = [{"id": "source", "file": str(camera), "from": "0", "to": "4"}]
        self.project.write_text(json.dumps(payload))
        before = self.project.read_bytes()
        issue = self.run_json("still", "picture", "replace", "--project", self.project, "--image", self.image,
                              "--clock", "sequence", "--from", "1/20", "--to", "3/10",
                              "--in-place", success=False)["error"]
        self.assertEqual(issue["code"], "invalid_still_boundary")
        self.assertEqual(self.project.read_bytes(), before)
        authoring = self.run_json("still", "picture", "replace", "--project", self.project, "--image", self.image,
                                  "--clock", "sequence", "--from", "1/10", "--to", "3/10",
                                  "--in-place")
        self.assertEqual(authoring["color_policy"]["transfer"], "bt709")
        self.image.unlink()
        output = self.root / "sound.m4a"
        preflight = self.run_json("export", "project", "render", "--project", self.project, "--tracks", "audio",
                                   "--output", output, "--dry-run")
        stdin = self.run_json("export", "project", "render", "--stdin", "--dry-run", data=json.dumps({
            "project_path": str(self.project), "tracks": "audio", "output": str(output)}))
        self.assertEqual(preflight, stdin)
        self.assertFalse(output.exists())
        self.assertEqual(read_time(preflight["duration"]), 4)
        self.assertEqual(read_time(preflight["generated_still_duration"]), 0)
        self.assertEqual([action["audio"] for action in preflight["audio_actions"]], ["copy", "copy"])

    def test_still_only_project_review_with_two_times(self):
        result = self.run_json("still", "project", "create", "--out-project", self.project, "--image", self.image,
                               "--width", 320, "--height", 180, "--rate", "25", "--codec", "h264",
                               "--container", "mp4", "--frames", 25)
        output = self.root / "review"
        review = self.run_json("review", "frames", "export", "--project", self.project, "--clock", "sequence",
                               "--at", "0", "--at", "1", "--output", output)
        self.assertEqual(review, json.loads((output / "manifest.json").read_text()))
        self.assertEqual([frame["placement_id"] for frame in review["frames"]], [result["placement_id"]] * 2)
        for frame in review["frames"]:
            self.assertEqual((frame["width"], frame["height"]), (320, 180))
            self.assertEqual((output / frame["file"]).read_bytes()[:2], b"\xff\xd8")

    def create_sdr_still_project(self, image):
        return self.run_json("still", "project", "create", "--out-project", self.project, "--image", image,
                             "--width", 64, "--height", 64, "--rate", "30", "--codec", "h264",
                             "--container", "mp4", "--color", "sdr", "--frames", 30)

    def test_rendition_policy_two_is_saved_and_policy_one_projects_open_under_it(self):
        # Rendition policy 2 shows a gain-map image on an SDR program as its SDR base. A project saved
        # under policy 1 opens and is saved under policy 2, and a later policy is refused.
        created = self.create_sdr_still_project(self.image)
        saved = read_project(self.project)
        self.assertEqual(saved["program_color_policy"]["rendition_policy_version"], 2)
        saved["program_color_policy"]["rendition_policy_version"] = 1
        self.project.write_text(json.dumps(saved))
        self.assertEqual(len(self.run_json("still", "placement", "list", "--project", self.project)["placements"]), 1)
        self.run_json("still", "placement", "update", "--project", self.project, "--placement",
                      created["placement_id"], "--fit", "fill", "--in-place")
        self.assertEqual(read_project(self.project)["program_color_policy"]["rendition_policy_version"], 2)
        saved = read_project(self.project)
        saved["program_color_policy"]["rendition_policy_version"] = 3
        self.project.write_text(json.dumps(saved))
        error = self.run_json("still", "placement", "list", "--project", self.project, success=False)["error"]
        self.assertEqual(error["code"], "invalid_still_project")
        self.assertIn("rendition policy 3", error["message"])

    def test_apple_gain_map_shows_its_sdr_base_on_an_sdr_timeline(self):
        # An iPhone-style Apple gain map (no ISO gain map). Its SDR base holds linear 0.5 and SDR
        # white; its HDR rendition holds 0.5 and 4.0, which the SDR shoulder would put below white.
        fixture = Path(__file__).with_name("fixtures") / "stills" / "apple-gain-map.heic"
        self.create_sdr_still_project(fixture)
        review = self.root / "review"
        report = self.run_json("review", "frames", "export", "--project", self.project, "--preset", "full",
                               "--at", "0", "--output", review)
        movie = self.root / "apple-gain-map.mp4"
        self.run_json("export", "project", "render", "--project", self.project, "--output", movie)
        for picture in (review / report["frames"][0]["file"], movie):
            pixels = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", picture, "-frames:v", "1",
                                     "-pix_fmt", "rgb24", "-f", "rawvideo", "-"],
                                    check=True, capture_output=True, timeout=60).stdout
            self.assertEqual(len(pixels), 64 * 64 * 3)
            middle, white = (pixels[(32 * 64 + x) * 3] for x in (16, 48))
            self.assertAlmostEqual(middle, 185, delta=6, msg=picture.name)
            self.assertGreaterEqual(white, 253, msg=picture.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
