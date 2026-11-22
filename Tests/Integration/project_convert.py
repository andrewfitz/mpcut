#!/usr/bin/env python3
"""Exercise project conversion and .cut playback through the installed CLI."""
import argparse
import json
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET

from media_regression import ffmpeg, frames


class ProjectConversion(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.folder = Path(scratch.name).resolve()
        self.camera = self.folder / "source & A.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=3",
               "-c:v", "prores_ks", self.camera)
        self.project = self.folder / "rough.cut"
        self.document = dict(format="mpcut", schemaVersion=1, kind="sequence", clips=[
            dict(id=name, file=self.camera.name, **{"from": a, "to": b})
            for name, a, b in [("second", "1", "2"), ("first", "0", "1"), ("repeat", "1", "2")]
        ])
        self.project.write_text(json.dumps(self.document))

    def cli(self, *args, status=0, stdin=None, sidecars=False):
        flags = [] if sidecars else ["--no-sidecar"]
        result = subprocess.run([CLI, "--json", *map(str, args), *flags], input=stdin,
                                cwd=self.folder, text=True, capture_output=True, timeout=90)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_saved_sequence_and_stdin_render_in_assembly_order(self):
        report = self.cli("inspect", "--project", "-",
                          stdin=self.project.read_text())
        self.assertEqual(report["kind"], "sequence")
        self.assertEqual(report["duration"], {"numerator": 3, "denominator": 1})
        self.assertEqual([Path(path).resolve() for path in report["sources"].values()], [self.camera] * 3)
        self.assertEqual(report["clips"], self.document["clips"])
        output = self.folder / "reordered.mov"
        self.cli("export", "--project", self.project, "--output", output)
        original = frames(self.camera)
        self.assertEqual(frames(output), original[24:48] + original[:24] + original[24:48])

    def test_cancelled_conversion_leaves_no_project(self):
        document = self.document.copy()
        document["clips"] = [dict(self.document["clips"][0], id=str(i), file=f"recording-{i}.mov")
                             for i in range(8000)]
        self.project.write_text(json.dumps(document))
        output = self.folder / "cancelled.cut"
        with subprocess.Popen([CLI, "convert", self.project, "--output", output, "--json"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            time.sleep(0.25)
            process.send_signal(signal.SIGINT)
            out, err = process.communicate(timeout=60)
        self.assertEqual(process.returncode, 130, out + err)
        self.assertEqual(json.loads(out)["error"]["code"], "cancelled")
        self.assertFalse(output.exists())
        self.assertFalse(list(self.folder.glob(".mpcut-*.cut")))

    def test_output_cannot_fill_an_offline_original_media_path(self):
        # The playable working copy still exists. A missing original remains a project reference.
        for verb, ext in [("export", "mov"), ("resolve", "fcpxml")]:
            with self.subTest(verb=verb):
                output = self.folder / ("offline-original." + ext)
                self.document["clips"][0]["originalFile"] = output.name
                error = self.cli(verb, "--project", "-", "--output", output, status=1,
                                 stdin=json.dumps(self.document))["error"]
                self.assertEqual(error["code"], "cut_project_source_collision")
                self.assertFalse(output.exists())

    def test_multicam_outputs_preserve_offline_camera_path(self):
        output = self.folder / "offline.mov"
        document = dict(format="mpcut", schemaVersion=1, kind="multicam", referenceAngle="a",
                        angles=[{"id": "a", "file": self.camera.name}, {"id": "b", "file": output.name}],
                        audio={"mode": "none"}, switches=[{"at": "0", "angle": "a"}],
                        range={"from": "0", "to": "1"})
        self.project.write_text(json.dumps(document))
        request = json.dumps({"output": output.name, "clips": [{"project": self.project.name}]})
        cases = [
            (["frames", "--project", "-", "--at", "0", "--output", output], json.dumps(document)),
            (["frames", "--project", self.project, "--at", "0", "--output", output], None),
            (["silence", "--project", self.project, "--output", output], None),
            (["export", "--stdin"], request),
        ]
        for args, stdin in cases:
            with self.subTest(args=args):
                error = self.cli(*args, status=1, stdin=stdin)["error"]
                self.assertEqual(error["code"], "cut_project_source_collision")
                self.assertFalse(output.exists())

    def test_outputs_preserve_recordings_used_only_by_history(self):
        for index, verb in enumerate(("export", "resolve")):
            for stdin in (False, True):
                with self.subTest(verb=verb, stdin=stdin):
                    ext = "mov" if verb == "export" else "fcpxml"
                    output = self.folder / f"offline-{index}-{stdin}.{ext}"
                    old_clip = dict(self.document["clips"][0], originalFile=output.name)
                    self.document["history"] = {"undo": [{"action": "Replace Audio", "clips": [old_clip, [1, 2]]}]}
                    encoded = json.dumps(self.document)
                    self.project.write_text(encoded)
                    failure = self.cli(verb, "--project", "-" if stdin else self.project,
                                       "--output", output, status=1, stdin=encoded if stdin else None)["error"]
                    self.assertEqual(failure["code"], "cut_project_source_collision")
                    self.assertFalse(output.exists())

        for operation in ("frames-stdin", "frames-file", "silence", "mixed-export"):
            with self.subTest(operation=operation):
                output = self.folder / (operation + ".mov")
                encoded = json.dumps(dict(format="mpcut", schemaVersion=1, kind="multicam", referenceAngle="a",
                    angles=[{"id": "a", "file": self.camera.name}], range={"from": "0", "to": "1"},
                    audio={"mode": "none"}, switches=[{"at": "0", "angle": "a"}],
                    history={"redo": [{"action": "Add Camera", "angles": [[0, 1], {"id": "b", "file": output.name}]}]}))
                self.project.write_text(encoded)
                stdin = None
                if operation.startswith("frames"):
                    from_stdin = operation == "frames-stdin"
                    args = ["frames", "--project", "-" if from_stdin else self.project, "--at", "0", "--output", output]
                    if from_stdin:
                        stdin = encoded
                elif operation == "silence":
                    args = ["silence", "--project", self.project, "--output", output]
                else:
                    args = ["export", "--stdin"]
                    stdin = json.dumps({"output": output.name, "clips": [{"project": self.project.name}]})
                failure = self.cli(*args, status=1, stdin=stdin)["error"]
                self.assertEqual(failure["code"], "cut_project_source_collision")
                self.assertFalse(output.exists())

    def test_frame_export_cannot_create_an_offline_history_file_inside_its_folder(self):
        output = self.folder / "review"
        history = {"undo": [{"action": "Remove Recorder", "audioSources": [{"id": "rec", "file": "review/manifest.json"}]}]}
        project = dict(format="mpcut", schemaVersion=1, kind="multicam", referenceAngle="a",
                       angles=[{"id": "a", "file": self.camera.name}], range={"from": "0", "to": "1"},
                       audio={"mode": "none"}, switches=[{"at": "0", "angle": "a"}], history=history)
        self.project.write_text(json.dumps(project))
        failure = self.cli("frames", "--project", self.project, "--at", "0", "--output", output, status=1)["error"]
        self.assertEqual(failure["code"], "cut_project_source_collision")
        self.assertFalse(output.exists())

    def test_automatic_caches_preserve_history_only_recordings(self):
        safe = self.folder / "second.mov"
        shutil.copyfile(self.camera, safe)
        clip = self.document["clips"][0]
        protected = self.camera.with_suffix(".mov.cutdb")
        self.document["clips"].append(dict(clip, id="another", file=safe.name))
        self.document["history"] = {"redo": [{"action": "Replace Audio", "clips": [
            dict(clip, originalFile=protected.name), [1, 3]
        ]}]}
        self.project.write_text(json.dumps(self.document))
        self.cli("export", "--project", self.project, "--output", "sequence.mov", "--dry-run", sidecars=True)
        self.assertFalse(protected.exists())
        self.assertEqual(safe.with_suffix(".mov.cutdb").read_bytes()[:16], b"SQLite format 3\0")
        self.cli("convert", self.project, "--output", "handoff.fcpxml", sidecars=True)
        self.assertFalse(protected.exists())

        # The first plain clip must respect the later project's offline camera.
        multicam = dict(format="mpcut", schemaVersion=1, kind="multicam", referenceAngle="a",
                        angles=[{"id": "a", "file": safe.name}], range={"from": "0", "to": "1"},
                        audio={"mode": "none"}, switches=[{"at": "0", "angle": "a"}],
                        history={"undo": [{"action": "Remove Camera", "angles": [[0, 1],
                                  {"id": "offline", "file": protected.name}]}]})
        self.project.write_text(json.dumps(multicam))
        request = dict(output="mixed.mov", clips=[{"file": self.camera.name, "from": "0", "to": "1"},
                                                  {"project": self.project.name}])
        self.cli("export", "--stdin", "--dry-run", "--tracks", "video", stdin=json.dumps(request), sidecars=True)
        self.assertFalse(protected.exists())

    def test_native_document_rebase_and_target_validation(self):
        child = self.folder / "elsewhere"
        child.mkdir()
        output = child / "new.cut"
        self.assertEqual(self.cli("convert", self.project, "--to", "mpcut", "--output", output)["warnings"], [])
        saved = json.loads(output.read_text())
        for actual, expected in zip(saved["clips"], self.document["clips"], strict=True):
            self.assertEqual((child / actual.pop("file")).resolve(), self.camera)
            self.assertEqual(actual, {k: v for k, v in expected.items() if k != "file"})
        before = output.read_bytes()
        self.assertFalse(self.cli("convert", self.project, "--output", output, status=1)["ok"])
        self.assertEqual(output.read_bytes(), before)
        error = self.cli("convert", self.project, "--to", "resolve", "--output", "bad.cut", status=2)
        self.assertEqual(error["error"]["code"], "invalid_arguments")
        self.assertFalse((self.folder / "bad.cut").exists())

    def test_flatten_requires_premiere_and_explicit_loss(self):
        for name, flags in [("edit.prproj", []), ("other.cut", ["--allow-loss"])]:
            with self.subTest(name=name):
                dest = self.folder / name
                error = self.cli("convert", self.project, "--output", dest,
                                 "--flatten-multicam", *flags, status=2)["error"]
                self.assertEqual(error["code"], "invalid_arguments")
                self.assertIn("--allow-loss", error["message"])
                self.assertIn(".prproj", error["message"])
                self.assertFalse(dest.exists())

    def test_stdin_media_paths_follow_physical_parent_traversal(self):
        assets = self.folder / "assets"
        child = assets / "child"
        child.mkdir(parents=True)
        (assets / "camera.mov").symlink_to(self.camera)
        (self.folder / "link").symlink_to(child)
        # The literal "-" in the working directory belongs to a different edit.
        unrelated = assets / "unrelated.cut"
        unrelated.write_text("{}")
        (self.folder / "-").symlink_to(unrelated)
        self.document["clips"][0]["file"] = "link/../camera.mov"
        inspected = self.cli("inspect", "--project", "-", stdin=json.dumps(self.document))
        self.assertEqual(Path(inspected["sources"]["second"]).resolve(), self.camera)
        multicam = dict(format="mpcut", schemaVersion=1, kind="multicam", referenceAngle="a",
                        angles=[{"id": "a", "file": "link/../camera.mov"}], audio={"mode": "none"},
                        switches=[{"at": "0", "angle": "a"}], range={"from": "0", "to": "1"})
        result = self.cli("frames", "--project", "-", "--at", "0", "--output", "review",
                          stdin=json.dumps(multicam))
        self.assertEqual(result["frames"][0]["availability"], "available")
        self.assertEqual(Path(result["angles"][0]["file"]).resolve(), self.camera)

    def test_interchange_roundtrip_and_explicit_loss(self):
        output = self.folder / "timeline.fcpxml"
        self.cli("convert", self.project, "--to", "fcp", "--output", output)
        restored = self.folder / "roundtrip.cut"
        self.cli("convert", output, "--output", restored)
        self.assertEqual([(c["from"], c["to"]) for c in json.loads(restored.read_text())["clips"]],
                         [(c["from"], c["to"]) for c in self.document["clips"]])
        tree = ET.parse(output)
        ET.SubElement(tree.find(".//spine/asset-clip"), "marker", start="1s", value="Comment")
        tree.write(output, encoding="utf-8", xml_declaration=True)
        lossy = self.folder / "marked.cut"
        error = self.cli("convert", output, "--output", lossy, status=1)
        self.assertIn("marker", error["error"]["message"])
        self.assertFalse(lossy.exists())
        warnings = self.cli("convert", output, "--allow-loss", "--output", lossy)["warnings"]
        self.assertTrue(any("marker" in warning for warning in warnings))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    CLI = parser.parse_args().mpcut.resolve()
    unittest.main(argv=[__file__])
