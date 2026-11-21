#!/usr/bin/env python3
"""Verify that two checkouts can publish to a shared destination on macOS."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


class BuildPublicationTests(unittest.TestCase):
    def test_live_stage_survives_another_checkout(self):
        build_script = Path(__file__).resolve().parents[2] / "scripts" / "build-app.sh"
        with tempfile.TemporaryDirectory(prefix="MPCut build locks ") as temp:
            root = Path(temp)
            output = root / "shared destination"
            release = root / "continue"
            processes = []

            def start(name):
                scripts = root / name / "scripts"
                scripts.mkdir(parents=True)
                shutil.copy(build_script, scripts / "build-app.sh")
                gate = scripts / "build-ffmpeg.sh"
                gate.write_text('#!/bin/sh\ntouch "$ENTERED"\n'
                                'while [ ! -f "$RELEASE" ]; do sleep 0.02; done\nexit 19\n')
                gate.chmod(0o755)
                entered = root / (name + ".entered")
                process = subprocess.Popen(
                    ["/bin/bash", scripts / "build-app.sh", output],
                    env={"PATH": os.defpath, "ENTERED": str(entered), "RELEASE": str(release)})
                processes.append(process)
                return entered

            try:
                first = start("checkout A")
                limit = time.monotonic() + 5
                while not first.exists() and time.monotonic() < limit:
                    time.sleep(0.02)
                self.assertTrue(first.exists(), "first publisher did not acquire the destination")
                stage = output / ".MPCut-stage.ABC123"
                stage.mkdir()
                canary = stage / "active-bundle"
                canary.touch()
                second = start("checkout B")
                limit = time.monotonic() + 1
                while not second.exists() and time.monotonic() < limit:
                    time.sleep(0.02)
                self.assertTrue(canary.exists(), "second publisher removed the active stage")
                self.assertFalse(second.exists(), "second publisher started before first finished")
            finally:
                release.touch()
                for process in processes:
                    self.assertEqual(process.wait(timeout=10), 19)
            self.assertTrue(second.exists(), "waiting publisher did not continue")
            self.assertFalse(stage.exists(), "abandoned stage was never recovered")


if __name__ == "__main__":
    unittest.main()
