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


CLI = None


def read_time(value):
    if isinstance(value, dict):
        return Fraction(value["numerator"], value["denominator"])
    return Fraction(value)


def ranges(placement):
    return [(read_time(span["output"]["from"]), read_time(span["output"]["to"]))
            for span in placement["visibleOccurrences"]]


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
        return {"format": "mpcut", "schemaVersion": 1, "kind": "sequence",
                "clips": [{"id": identity, "file": "offline.mov", "from": "0", "to": "6"}
                          for identity in ("first", "second")]}

    def test_sequence_save_as_stdin_relink_and_conflicts(self):
        self.project.write_text(json.dumps(self.sequence()))
        destination = self.root / "versions" / "covered.cut"
        destination.parent.mkdir()
        cover = self.run_json("still", "add", "--project", "-", "--image", "photo.png",
                              "--replace", "--clock", "sequence", "--from", "8", "--to", "10",
                              "--out-project", destination, data=self.project.read_text())
        self.assertEqual(cover["duration"], {"numerator": 12, "denominator": 1})
        self.assertEqual(ranges(cover["placements"][0]), [(8, 10)])
        self.assertEqual(cover["placements"][0]["authoredFragments"][0]["clipID"], "second")
        self.assertEqual(cover["assets"][0]["file"], "../photo.png")
        saved = json.loads(destination.read_text())
        self.assertEqual(saved["schemaVersion"], 2)
        self.assertEqual([entry["source"]["id"] for entry in saved["clips"]], ["first", "second"])
        before = destination.read_bytes()
        issue = self.run_json("still", "add", "--project", destination, "--asset", cover["assetID"],
                              "--replace", "--clock", "sequence", "--from", "9", "--to", "11",
                              "--in-place", success=False)["error"]
        self.assertIn(cover["placementID"], issue["placementIDs"])
        self.assertEqual(destination.read_bytes(), before)

        title = self.run_json("still", "add", "--project", destination, "--asset", cover["assetID"],
                              "--insert", "--clock", "sequence", "--at", "9", "--frames", "1",
                              "--rate", "30000/1001", "--in-place")
        insert_id = title["placementID"]
        self.assertEqual(read_time(title["duration"]), Fraction(361001, 30000))
        placements = {p["id"]: p for p in title["placements"]}
        self.assertEqual(ranges(placements[cover["placementID"]]), [(8, 9),
                         (Fraction(271001, 30000), Fraction(301001, 30000))])
        self.assertEqual(ranges(placements[insert_id]), [(9, Fraction(271001, 30000))])

        self.image.unlink()
        offline = self.run_json("still", "list", "--project", destination)
        self.assertTrue(offline["assets"][0]["offline"])
        repaired = self.root / "renamed.png"
        repaired.write_bytes(png((0, 170, 67)))
        relinked = self.run_json("still", "relink", "--project", destination, "--asset", cover["assetID"],
                                 "--image", repaired, "--in-place")
        self.assertFalse(relinked["assets"][0]["offline"])
        self.assertEqual(relinked["assets"][0]["id"], cover["assetID"])
        self.assertEqual(len(relinked["placements"]), 2)

        reframed = self.run_json("still", "update", "--project", destination, "--placement",
                                 cover["placementID"], "--fit", "fill", "--crop-x", "1/2",
                                 "--crop-y", "0.3", "--in-place")
        cover_row = next(row for row in reframed["placements"] if row["id"] == cover["placementID"])
        self.assertEqual(cover_row["framing"]["mode"], "fill")
        self.assertEqual(read_time(cover_row["framing"]["crop"]["x"]), Fraction(1, 2))
        self.assertEqual(read_time(cover_row["framing"]["crop"]["y"]), Fraction(3, 10))

        deleted = self.run_json("still", "remove", "--project", destination, "--placement", insert_id, "--in-place")
        self.assertEqual(read_time(deleted["duration"]), 12)
        self.assertEqual(len(deleted["placements"]), 1)

    def test_group_replacement_repeats_while_assembly_insert_appears_once(self):
        project = {"format": "mpcut", "schemaVersion": 1, "kind": "multicam",
                   "referenceAngle": "wide", "range": {"from": "0", "to": "8"},
                   "angles": [{"id": "wide", "file": "camera.mov", "offset": "0"}],
                   "audio": {"mode": "none"}, "switches": [{"at": "0", "angle": "wide"}],
                   "assembly": [{"from": "4", "to": "8"}] * 2}
        self.project.write_text(json.dumps(project))
        photo = self.run_json("still", "add", "--project", self.project, "--image", self.image,
                              "--replace", "--clock", "group", "--from", "5", "--to", "7", "--in-place")
        title = self.run_json("still", "add", "--project", self.project, "--asset", photo["assetID"],
                              "--insert", "--clock", "assembly", "--at", "4", "--duration", "1",
                              "--rate", "25", "--in-place")
        report = self.run_json("inspect", "--project", self.project)
        self.assertEqual(read_time(report["duration"]), 9)
        placements = {p["id"]: p for p in report["placements"]}
        self.assertEqual(ranges(placements[photo["placementID"]]), [(1, 3), (6, 8)])
        self.assertEqual(ranges(placements[title["placementID"]]), [(4, 5)])

    def test_offline_replacement_preserves_audio_and_stdin_parity(self):
        fixtures = Path(__file__).resolve().parents[1] / "MPCutAppTests" / "Fixtures"
        camera = fixtures / "Pause-Quiet.mov"
        payload = self.sequence()
        payload["clips"] = [{"id": "source", "file": str(camera), "from": "0", "to": "4"}]
        self.project.write_text(json.dumps(payload))
        before = self.project.read_bytes()
        issue = self.run_json("still", "add", "--project", self.project, "--image", self.image,
                              "--replace", "--clock", "sequence", "--from", "1/20", "--to", "3/10",
                              "--in-place", success=False)["error"]
        self.assertEqual(issue["code"], "invalid_still_boundary")
        self.assertEqual(self.project.read_bytes(), before)
        authoring = self.run_json("still", "add", "--project", self.project, "--image", self.image,
                                  "--replace", "--clock", "sequence", "--from", "1/10", "--to", "3/10",
                                  "--in-place")
        self.assertEqual(authoring["colorPolicy"]["transfer"], "bt709")
        self.image.unlink()
        output = self.root / "sound.m4a"
        preflight = self.run_json("export", "--project", self.project, "--tracks", "audio",
                                   "--output", output, "--dry-run")
        stdin = self.run_json("export", "--stdin", "--dry-run", data=json.dumps({
            "project": str(self.project), "tracks": "audio", "output": str(output)}))
        self.assertEqual(preflight, stdin)
        self.assertFalse(output.exists())
        self.assertEqual(read_time(preflight["duration"]), 4)
        self.assertEqual(read_time(preflight["generatedStillDuration"]), 0)
        self.assertEqual([action["audio"] for action in preflight["audioActions"]], ["copy", "copy"])

    def test_still_only_project_review_with_two_times(self):
        result = self.run_json("still", "create", "--out-project", self.project, "--image", self.image,
                               "--width", 320, "--height", 180, "--rate", "25", "--codec", "h264",
                               "--container", "mp4", "--frames", 25)
        output = self.root / "review"
        review = self.run_json("frames", "--project", self.project, "--clock", "sequence",
                               "--at", "0", "--at", "1", "--output", output)
        self.assertEqual(review, json.loads((output / "manifest.json").read_text()))
        self.assertEqual([frame["placementID"] for frame in review["frames"]], [result["placementID"]] * 2)
        for frame in review["frames"]:
            self.assertEqual((frame["width"], frame["height"]), (320, 180))
            self.assertEqual((output / frame["file"]).read_bytes()[:2], b"\xff\xd8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
