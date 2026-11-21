#!/usr/bin/env python3
"""Regression checks from the multicam core audit: publication, source clocks, and preflight."""
import argparse
import os
from pathlib import Path
import stat
import tempfile
import unittest

import multicam
from media_regression import audio, ffmpeg
from multicam import FPS, RATE, camera, pcm_slice, wav
from smart_trim import picture_ids

LATE = "2/5"


def late_camera(path):
    """A MOV whose picture starts 0.4 s into the movie while both microphones start at zero."""
    marker = "geq=lum='if(lt(Y,16)*lt(X,128),if(bitand(N+64,pow(2,floor(X/16))),210,32),lum(X,Y))'"
    ffmpeg("-itsoffset", "0.4", "-f", "lavfi", "-i", f"testsrc2=d=4:s=320x96:r={FPS}",
           "-f", "lavfi", "-i", f"aevalsrc=0.15*sin(2*PI*(523*t+29*t*t)):s={RATE}:d=4.4",
           "-f", "lavfi", "-i", f"aevalsrc=0.2*sin(2*PI*217*t):s={RATE}:d=4.4",
           "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0", "-vf", marker,
           "-c:v", "libx264", "-threads", "1",
           "-x264-params", f"keyint={FPS}:min-keyint={FPS}:scenecut=0:open-gop=0:bframes=0",
           "-color_range", "tv", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
           "-c:a", "pcm_s16le", "-channel_layout:a", "mono", path)
    return path


class MulticamCoreAudit(unittest.TestCase):
    cli = multicam.MulticamTests.cli
    export = multicam.MulticamTests.export
    project = multicam.MulticamTests.project
    setUp = multicam.MulticamTests.setUp

    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-multicam-audit-")
        cls.addClassCleanup(directory.cleanup)
        cls.fixtures = Path(directory.name)
        cls.wide = camera(cls.fixtures / "wide.mov", marker_base=0, frequency=419, extra_audio=True)
        cls.close = late_camera(cls.fixtures / "late.mov")
        cls.lav = wav(cls.fixtures / "lav.wav", "4")
        cls.aac = cls.fixtures / "master.m4a"
        ffmpeg("-f", "lavfi", "-i", f"aevalsrc=0.2*sin(2*PI*(349*t+51*t*t)):s={RATE}:d=4", "-c:a", "aac", cls.aac)

    def assert_nothing_staged(self):
        self.assertEqual([path.name for path in self.root.iterdir() if path.name.startswith(".mpcut")], [])

    def test_combined_movie_is_published_with_ordinary_permissions(self):
        self.project(switches=[{"at": "0", "angle": "wide"}, {"at": "2", "angle": "wide"}])
        mask = os.umask(0)
        os.umask(mask)
        expected = 0o666 & ~mask
        video_only = self.root / "picture.mov"
        self.export("--tracks", "video", output=video_only)
        self.assertEqual(stat.S_IMODE(video_only.stat().st_mode), expected)
        for mode, options in (("copy", []), ("smart", []), ("encode", ["--audio", "aac"])):
            with self.subTest(mode=mode):
                output = self.root / f"program-{mode}.mov"
                self.export(*options, mode=mode, output=output)
                self.assertEqual(stat.S_IMODE(output.stat().st_mode), expected)
        self.assert_nothing_staged()

    def test_smart_trim_edge_uses_the_movie_clock_of_a_late_starting_picture(self):
        # Group 1 is fifteen frames into the late camera: an encoded edge up to
        # its keyframe at movie time 1.4, then copied pictures.
        self.project(switches=[{"at": "0", "angle": "wide"}, {"at": "1", "angle": "close"},
                               {"at": "3", "angle": "wide"}],
                     assembly=[{"from": "2", "to": "3"}, {"from": "0", "to": "2"}, {"from": "3", "to": "4"}])
        wide, late = picture_ids(self.wide), picture_ids(self.close)
        first = FPS - 10  # Movie time 1 on a picture track that starts at 0.4.
        expected = (late[first + FPS:first + 2 * FPS] + wide[:FPS] + late[first:first + FPS]
                    + wide[3 * FPS:4 * FPS])
        report = self.export(mode="smart")
        self.assertGreater(multicam.rational_time(report["encodedVideoDuration"]), 0)
        self.assertEqual(picture_ids(self.output), expected)
        pcm = audio(self.lav)
        self.assertEqual(audio(self.output), pcm_slice(pcm, 2, 3) + pcm_slice(pcm, 0, 2) + pcm_slice(pcm, 3, 4))

        # The same pictures when the project offset puts the late camera's first frame at group zero.
        self.project(offset=f"-{LATE}", end="3",
                     switches=[{"at": "0", "angle": "close"}, {"at": "37/25", "angle": "wide"},
                               {"at": "2", "angle": "close"}])
        output = self.root / "offset.mov"
        self.export(mode="smart", output=output)
        self.assertEqual(picture_ids(output), late[:37] + wide[37:50] + late[50:75])

    def test_preflight_rejects_priming_a_program_soundtrack_cannot_keep(self):
        self.project(audioSources=[{"id": "lav", "file": str(self.aac), "offset": "0"}],
                     switches=[{"at": "0", "angle": "wide"}])
        for tracks, suffix in (("all", "mkv"), ("audio", "mka")):
            output = self.root / f"program.{suffix}"
            for options in (["--dry-run"], []):
                with self.subTest(tracks=tracks, options=options):
                    report = self.export("--tracks", tracks, *options, output=output, ok=False)
                    self.assertEqual(report["error"]["code"], "unsupported_container")
                    self.assertIn("priming", report["error"]["message"])
                    self.assertEqual(report["error"]["multicam"]["source"], "lav")
                    self.assertFalse(output.exists())
        self.assert_nothing_staged()
        # The same master keeps its priming through MOV edit lists.
        self.export()
        self.assertEqual(len(audio(self.output)), 2 * 4 * RATE)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    multicam.CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
