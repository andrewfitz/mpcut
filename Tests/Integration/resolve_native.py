#!/usr/bin/env python3
"""Exercise native archives using the installed, running Resolve host."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

from media_regression import ffmpeg
from saved_project import read_project


def media_path(project, entry):
    """A saved project lists each media path once and an entry gives its position."""
    file = entry["file"]
    return project["files"][file] if isinstance(file, int) else file


class ResolveNativeTests(unittest.TestCase):
    def convert(self, source, destination, *flags, succeeds=True):
        process = subprocess.run([CLI, "project", "convert", str(source), "--output", str(destination), "--json", *flags],
                                 text=True, capture_output=True, timeout=240)
        self.assertEqual(process.returncode == 0, succeeds, process.stdout + process.stderr)
        return json.loads(process.stdout)

    def test_reopen_archives_and_preserve_repeated_source_ranges(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            media = folder / "Camera & sound.mov"
            ffmpeg("-f", "lavfi", "-i", "testsrc2=s=512x288:r=24:d=4",
                   "-f", "lavfi", "-i", "sine=frequency=440:d=4", "-map", "0:v", "-map", "1:a",
                   "-c:v", "prores_ks", "-c:a", "pcm_s16le", media)
            ranges = [("2", "3"), ("0", "2"), ("2", "3")]
            source = folder / "Test.cut"
            source.write_text(json.dumps(dict(format="mpcut", schema_version=9, kind="sequence", clips=[
                {"id": str(i), "file": media.name, "from": a, "to": b} for i, (a, b) in enumerate(ranges)])))
            for ext in ("drp", "drt"):
                with self.subTest(ext=ext):
                    native = source.with_suffix("." + ext)
                    self.convert(source, native)
                    self.assertGreater(native.stat().st_size, 0)
                    restored = folder / f"back-{ext}.cut"
                    blocked = self.convert(native, restored, succeeds=False)
                    self.assertEqual(blocked["error"]["code"], "conversion_loss")
                    self.assertFalse(restored.exists())
                    self.convert(native, restored, "--allow-loss")
                    saved = read_project(restored)
                    clips = saved["clips"]
                    self.assertEqual([(c["from"], c["to"]) for c in clips], ranges)
                    for clip in clips:
                        self.assertEqual((folder / media_path(saved, clip)).resolve(), media.resolve())

    def test_host_timebase_and_raster_substitutions(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            source = folder / "Timeline.cut"
            output = folder / "Timeline.drp"
            for rate in (7, 24):
                media = folder / f"Camera-{rate}.mov"
                ffmpeg("-f", "lavfi", "-i", f"testsrc2=s=160x90:r={rate}:d=2", "-c:v", "prores_ks", media)
                source.write_text(json.dumps(dict(format="mpcut", schema_version=9, kind="sequence", clips=[
                    {"id": "take", "file": media.name, "from": "0", "to": "1"}])))
                error = self.convert(source, output, succeeds=False)["error"]
                self.assertEqual(error["code"], "resolve_timebase_changed" if rate == 7 else "conversion_loss")
                self.assertFalse(output.exists())
                self.assertFalse(list(folder.glob("* Media *")))
            warnings = self.convert(source, output, "--allow-loss")["warnings"]
            self.assertTrue(any("160×90" in w and "256×256" in w for w in warnings), warnings)

    def test_multifile_angle_gap_and_occurrence_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            for name, color in (("wide", "blue"), ("close-first", "red"), ("close-second", "green")):
                ffmpeg("-f", "lavfi", "-i", f"color={color}:s=512x288:r=24:d=3",
                       "-c:v", "prores_ks", folder / f"{name}.mov")
            ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:d=3",
                   "-c:a", "pcm_s16le", folder / "microphone.wav")
            source = folder / "Multi.cut"
            end = {"from": "2", "to": "3"}
            source.write_text(json.dumps(dict(format="mpcut", schema_version=9, kind="multicam",
                reference_angle_id="wide", group_range={"from": "0", "to": "3"},
                angles=[dict(id="close", name="Close", file="close-first.mov",
                             group_coverage={"from": "0", "to": "1"},
                             additional_recordings=[dict(id="second", file="close-second.mov", offset="2",
                                                         group_coverage=end)]),
                        dict(id="wide", name="Wide", file="wide.mov")],
                audio_sources=[dict(id="mic", name="Microphone", file="microphone.wav", audio_stream_index=0)],
                audio=dict(mode="fixed", source_id="mic", audio_stream_index=0),
                switches=[dict(group_time="0", angle_id="close")],
                assembly=[{"from": "0", "to": "3"}, dict(end, kind="group", angle_id="wide"), end])))
            for ext in ("drp", "drt"):
                with self.subTest(ext=ext):
                    native = source.with_suffix("." + ext)
                    self.convert(source, native)
                    restored = folder / f"multi-back-{ext}.cut"
                    self.convert(native, restored, "--allow-loss")
                    project = read_project(restored)
                    close = next(angle for angle in project["angles"] if angle["name"] == "Close")
                    for entry, file, bounds in [(close, "close-first.mov", {"from": "0", "to": "1"}),
                                                 (close["additional_recordings"][0], "close-second.mov", end)]:
                        self.assertEqual((folder / media_path(project, entry)).resolve(), (folder / file).resolve())
                        self.assertEqual(entry["group_coverage"], bounds)
                    # Verify the reconstructed program through the normal Resolve handoff.
                    # Native interchange regenerates angle and recording IDs.
                    handoff = folder / f"back-{ext}.fcpxml"
                    process = subprocess.run([CLI, "project", "resolve", "export", "--project", str(restored),
                                              "--output", str(handoff), "--no-sidecar"],
                                             text=True, capture_output=True, timeout=60)
                    self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
                    tree = ET.parse(handoff)
                    angles = {angle.get("angleID"): angle.get("name") for angle in tree.findall(".//mc-angle")}
                    clips = tree.findall(".//spine/mc-clip")
                    self.assertEqual([c.get("start") for c in clips], ["0s", "1s", "2s", "2s", "2s"])
                    self.assertEqual([c.get("offset") for c in clips], ["0s", "1s", "2s", "3s", "4s"])
                    self.assertEqual([angles[c.find("mc-source[@srcEnable='video']").get("angleID")] for c in clips],
                                     ["Close", "Close", "Close", "Wide", "Close"])
                    self.assertEqual([angles[c.find("mc-source[@srcEnable='audio']").get("angleID")] for c in clips],
                                     ["Microphone"] * 5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True, type=Path)
    args, remaining = parser.parse_known_args()
    CLI = args.cli.resolve()
    unittest.main(argv=[__file__, *remaining])
