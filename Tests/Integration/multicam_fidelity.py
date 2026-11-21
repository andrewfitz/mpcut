#!/usr/bin/env python3
"""Check multicam MOV decode order, edit lists, and repeated publication."""
import argparse
from fractions import Fraction
from pathlib import Path
import tempfile
import unittest

import multicam
from media_regression import ffmpeg, frames, packets, probe, run, timestamped_hashes


def camera(path, *, frequency, delay=None, audio_first=False):
    # Putting both audio tracks before picture in just one camera changes the
    # absolute index of its second audio track.
    audio = ["-itsoffset", delay] if delay else []
    audio += ["-f", "lavfi", "-i",
              f"aevalsrc=0.2*sin(2*PI*({frequency}*t+31*t*t)):s=48000:d={0.25 if delay else 4}"]
    order = ["1:a", "2:a", "0:v"] if audio_first else ["0:v", "1:a", "2:a"]
    ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=4",
           "-f", "lavfi", "-i", "sine=f=211:r=48000:d=4", *audio,
           *[item for stream in order for item in ("-map", stream)],
           "-vf", f"hue=h={frequency % 113}", "-c:v", "libx264", "-threads", "1",
           "-x264-params", "keyint=25:min-keyint=25:scenecut=0:open-gop=0:bframes=2:b-adapt=0",
           "-video_track_timescale", "90000" if audio_first else "25000",
           "-c:a", "aac", "-aac_pns", "0", path)
    return path


def ffprobe_streams(path, kind):
    return probe(path, "-show_streams", "-select_streams", kind)["streams"]


class MulticamFidelity(unittest.TestCase):
    cli = multicam.MulticamTests.cli
    export = multicam.MulticamTests.export
    project = multicam.MulticamTests.project

    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-multicam-fidelity-")
        cls.addClassCleanup(directory.cleanup)
        cls.fixtures = Path(directory.name)
        cls.wide = camera(cls.fixtures / "wide.mov", frequency=433, delay="1.75")
        cls.close = camera(cls.fixtures / "close.mov", frequency=691, audio_first=True)
        cls.lav = cls.fixtures / "lav.wav"
        ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.2*sin(2*PI*(349*t+51*t*t)):s=44100:d=4.1",
               "-c:a", "pcm_s16le", cls.lav)
        cls.decoder = cls.fixtures / "decode-audio"
        run(["swiftc", "-parse-as-library", Path(__file__).with_name("DecodeAudio.swift"),
             "-o", cls.decoder], allow_diagnostics=True)

    setUp = multicam.MulticamTests.setUp

    def decode(self, path, index=0):
        return run([self.decoder, path, str(index)])

    def assert_picture(self, output, ranges):
        expected_pts = []
        expected_frames = []
        elapsed = Fraction(0)
        for source, start, end in ranges:
            expected_pts += [(elapsed + pts - start, digest) for pts, digest in timestamped_hashes(source)
                             if start <= pts < end]
            expected_frames += frames(source)[int(start * 25):int(end * 25)]
            elapsed += end - start
        self.assertEqual(frames(output), expected_frames)
        self.assertEqual(timestamped_hashes(output), expected_pts)
        self.assertTrue(any(a[0] > b[0] for a, b in zip(expected_pts, expected_pts[1:])),
                        "fixture must have out-of-order presentation timestamps")
        video = ffprobe_streams(output, "v")[0]
        self.assertEqual(Fraction(video["time_base"]) * int(video["duration_ts"]), elapsed)
        self.assertEqual(int(video["start_pts"]), 0)
        dts = [int(packet["dts"]) for packet in packets(output)]
        self.assertTrue(all(a < b for a, b in zip(dts, dts[1:])))

    def test_delayed_second_aac_track_follow_with_different_absolute_indices(self):
        self.project(
            angles=[{"id": "wide", "file": str(self.wide), "offset": "0", "audioStream": 2},
                    {"id": "close", "file": str(self.close), "offset": "0", "audioStream": 1}],
            end="3",
            audio={"mode": "follow"},
            switches=[{"at": "0", "angle": "wide"},
                      {"at": "2", "angle": "close"}],
        )
        self.export()
        self.assert_picture(self.output, [(self.wide, 0, 2), (self.close, 2, 3)])
        delayed = self.decode(self.wide, 1)
        close = self.decode(self.close, 1)
        self.assertEqual(len(delayed), 2 * 2 * 48000)
        self.assertEqual(delayed[:3 * 48000], bytes(3 * 48000))
        actual = self.decode(self.output)
        self.assertEqual(len(actual), 3 * 2 * 48000)
        self.assertEqual(actual[:len(delayed)], delayed)
        # The AAC decoder may start a new window from different filter history.
        # Compare well inside it, at the exact source/output sample positions.
        self.assertEqual(actual[2 * 100000:2 * 108000], close[2 * 100000:2 * 108000])
        self.assertEqual(actual[-4096:], close[3 * 2 * 48000 - 4096:3 * 2 * 48000])

    def test_silent_aac_edit_on_one_absolute_index_and_audible_edit_on_another(self):
        self.project(
            angles=[{"id": "wide", "file": str(self.wide), "offset": "0", "audioStream": 2},
                    {"id": "close", "file": str(self.close), "offset": "0", "audioStream": 1}],
            end="2",
            audio={"mode": "follow"},
            switches=[{"at": "0", "angle": "wide"}, {"at": "1", "angle": "close"}],
        )
        self.export()
        actual = self.decode(self.output)
        close = self.decode(self.close, 1)
        self.assertEqual(len(actual), 2 * 2 * 48000)
        self.assertEqual(actual[:2 * 48000], bytes(2 * 48000))
        self.assertEqual(actual[-4096:], close[2 * 2 * 48000 - 4096:2 * 2 * 48000])

    def test_m4v_is_an_mp4_movie_in_copy_and_encode_modes(self):
        self.project(end="2", audio={"mode": "fixed", "source": "close", "stream": 1},
                     switches=[{"at": "0", "angle": "wide"}, {"at": "1", "angle": "close"}])
        for mode in ("copy", "encode"):
            with self.subTest(mode=mode):
                output = self.root / f"program-{mode}.m4v"
                self.export(*(["--audio", "aac"] if mode == "encode" else []), mode=mode, output=output)
                movie = probe(output, "-show_format", "-show_streams")
                self.assertIn("mp4", movie["format"]["format_name"].split(","))
                self.assertEqual(movie["format"]["tags"]["major_brand"], "isom")
                self.assertEqual([stream["codec_type"] for stream in movie["streams"]], ["video", "audio"])
                self.assertEqual(len(frames(output)), 50)
                self.assertEqual(len(self.decode(output)), 2 * 2 * 48000)
                if mode == "copy":
                    self.assert_picture(output, [(self.wide, 0, 1), (self.close, 1, 2)])

    def test_repeated_export_of_reordered_b_frames_and_44100_hz_wav(self):
        self.project(switches=[{"at": "0", "angle": "wide"}, {"at": "1", "angle": "close"}],
                     audioSources=[{"id": "lav", "file": str(self.lav), "offset": "-1/10"}],
                     assembly=[{"from": "2", "to": "4"}, {"from": "0", "to": "2"},
                               {"from": "2", "to": "3"}])
        pcm = self.decode(self.lav)
        ranges = [(self.close, 2, 4), (self.wide, 0, 1), (self.close, 1, 2), (self.close, 2, 3)]
        def source_samples(start, end):
            return pcm[2 * (start * 44100 + 4410):2 * (end * 44100 + 4410)]

        expected = source_samples(2, 4) + source_samples(0, 2) + source_samples(2, 3)
        for output in [self.output, self.root / "program-repeat.mov"]:
            self.export(output=output)
            self.assert_picture(output, ranges)
            self.assertEqual(self.decode(output), expected)
            sound = ffprobe_streams(output, "a")[0]
            self.assertEqual(sound["time_base"], "1/44100")
            self.assertEqual(int(sound["duration_ts"]), 5 * 44100)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    multicam.CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
