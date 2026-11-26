#!/usr/bin/env python3
"""Exercise the Git merge driver through the installed CLI: its exit status, its message and what it leaves in OURS."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


def project(*clips):
    return json.dumps(dict(format="mpcut", schema_version=9, kind="sequence", clips=[
        dict(id=name, file="camera.mov", **{"from": start, "to": end}) for name, start, end in clips
    ]))


BASE = [("a", "0", "1"), ("b", "1", "2"), ("c", "2", "3"), ("d", "3", "4"), ("e", "4", "5")]


def changed(index, clip):
    return BASE[:index] + [clip] + BASE[index + 1:]


def added(index, clip):
    return BASE[:index] + [clip] + BASE[index:]


class ProjectMerge(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.folder = Path(scratch.name).resolve()

    def merge(self, ours, theirs, environment=None):
        for name, clips in (("base", BASE), ("ours", ours), ("theirs", theirs)):
            (self.folder / f"{name}.cut").write_text(project(*clips))
        self.before = (self.folder / "ours.cut").read_bytes()
        result = subprocess.run([CLI, "project", "merge", "base.cut", "ours.cut", "theirs.cut"], cwd=self.folder,
                                env=environment, text=True, capture_output=True, timeout=90)
        return result.returncode, result.stderr, (self.folder / "ours.cut").read_text()

    def clips(self):
        result = subprocess.run([CLI, "--json", "project", "inspect", "--project", "ours.cut", "--no-sidecar"],
                                cwd=self.folder, text=True, capture_output=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return [(clip["id"], clip["from"], clip["to"]) for clip in json.loads(result.stdout)["clips"]]

    def test_separate_changes_merge_and_exit_0(self):
        status, message, _ = self.merge(changed(0, ("a", "0", "1/2")), changed(4, ("e", "4", "9/2")))
        self.assertEqual((status, message), (0, ""))
        self.assertEqual(self.clips(), [("a", "0", "1/2"), *BASE[1:4], ("e", "4", "9/2")])

    def test_changes_to_the_same_line_exit_1_and_leave_both_marked(self):
        status, message, ours = self.merge(changed(0, ("a", "0", "1/2")), changed(0, ("a", "0", "3/4")))
        self.assertEqual(status, 1, message)
        self.assertIn("Both branches changed the same lines", message)
        for expected in ("<<<<<<< ours", '"to": "1/2"', "=======", '"to": "3/4"', ">>>>>>> theirs"):
            self.assertIn(expected, ours)

    def test_a_merge_that_cannot_be_opened_exits_1_and_leaves_the_merged_text(self):
        status, message, ours = self.merge(added(1, ("new", "5", "6")), added(4, ("new", "7", "8")))
        self.assertEqual(status, 1, message)
        self.assertIn("cannot open the result", message)
        self.assertNotIn("<<<<<<<", ours)
        self.assertEqual(ours.count('"id": "new"'), 2)

    def test_a_failed_line_merge_exits_above_128_and_leaves_ours_alone(self):
        tools = self.folder / "tools"
        tools.mkdir()
        git = tools / "git"
        git.write_text("#!/bin/sh\nexit 255\n")
        git.chmod(0o755)
        environment = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}"}
        status, message, _ = self.merge(changed(0, ("a", "0", "1/2")), changed(4, ("e", "4", "9/2")), environment)
        # Git reads a status above 128 as a merge that failed, and any other nonzero status as a conflict left in OURS.
        self.assertGreater(status, 128, message)
        self.assertNotEqual(status, 130, message)
        self.assertIn("could not merge", message)
        self.assertEqual((self.folder / "ours.cut").read_bytes(), self.before)

    def test_git_that_cannot_run_exits_above_128_and_leaves_ours_alone(self):
        status, message, _ = self.merge(changed(0, ("a", "0", "1/2")), changed(0, ("a", "0", "3/4")),
                                        {**os.environ, "PATH": str(self.folder)})
        self.assertGreater(status, 128, message)
        self.assertIn("could not merge", message)
        self.assertEqual((self.folder / "ours.cut").read_bytes(), self.before)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    CLI = parser.parse_args().mpcut.resolve()
    unittest.main(argv=[__file__])
