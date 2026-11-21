#!/usr/bin/env python3
"""Verify scene scans and JPEG export around a picture whose coded data is damaged."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
# Red for three seconds, then blue. Noise gives every picture a sizable payload.
SOURCE = ("color=red:s=320x240:r=25:d=3[a];color=blue:s=320x240:r=25:d=3[b];"
          "[a][b]concat=n=2:v=1:a=0,noise=alls=20:allf=t")


def run(args, check=True):
    return subprocess.run(args, check=check, capture_output=True, timeout=120)


def packets(path):
    report = run([FFPROBE, "-loglevel", "error", "-select_streams", "v:0", "-show_packets",
                  "-of", "json", path]).stdout
    return [(int(p["pos"]), int(p["size"]), "K" in p["flags"]) for p in json.loads(report)["packets"]]


def damage_payload(path, indexes):
    """Overwrite coded picture data and keep each packet's leading header bytes.

    A hardware decoder accepts such a packet and then fails to decode it."""
    spans = packets(path)
    with open(path, "r+b") as file:
        for index in indexes:
            position, size, _ = spans[index]
            file.seek(position + 24)
            file.write(bytes((i * 197 + 91) & 255 for i in range(size - 32)))


def encode(path, codec, *options, pixels="yuv420p"):
    run([FFMPEG, "-loglevel", "error", "-f", "lavfi", "-i", SOURCE, "-c:v", codec,
         "-pix_fmt", pixels, "-g", "25", *options, path])


class DamagedPictureData(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(scratch.cleanup)
        cls.root = Path(scratch.name)
        # Keyframes at 0, 1, 2 ... seconds. The damaged picture is at 1.6 seconds.
        cls.h264 = cls.root / "h264.mp4"
        encode(cls.h264, "libx264", "-bf", "0", "-sc_threshold", "0")
        spans = packets(cls.h264)
        assert [i for i, span in enumerate(spans) if span[2]] == list(range(0, 150, 25)), spans
        damage_payload(cls.h264, [40])
        cls.matroska = cls.root / "h264.mkv"
        encode(cls.matroska, "libx264", "-bf", "0", "-sc_threshold", "0")
        damage_payload(cls.matroska, [40])
        cls.hevc = cls.root / "hevc.mp4"
        encode(cls.hevc, "libx265", "-x265-params", "bframes=0:scenecut=0:log-level=error", "-tag:v", "hvc1")
        damage_payload(cls.hevc, [40])
        # Every ProRes picture is a keyframe and is decoded in software.
        cls.prores = cls.root / "prores.mov"
        encode(cls.prores, "prores_ks", pixels="yuv422p10le")
        damage_payload(cls.prores, [40])

    def mpcut(self, *args):
        result = run([CLI, *args], check=False)
        return result.returncode, json.loads(result.stdout)

    def frames(self, source, *times):
        folder = tempfile.mkdtemp(dir=self.root)
        selection = [option for time in times for option in ("--at", time)]
        code, report = self.mpcut("frames", "--json", "--no-sidecar", *selection,
                                  "--output", Path(folder) / "frames", source)
        return code, report

    def test_fixtures_keep_their_container_and_lose_one_picture(self):
        for path in [self.h264, self.matroska, self.hevc, self.prores]:
            self.assertEqual(len(packets(path)), 150, path)
        for path in [self.h264, self.matroska, self.prores]:
            result = run([FFMPEG, "-loglevel", "error", "-xerror", "-err_detect", "explode",
                          "-i", path, "-f", "null", "-"], check=False)
            self.assertNotEqual(result.returncode, 0, path)

    def test_scenes_read_around_a_picture_the_hardware_decoder_rejects(self):
        for path in [self.h264, self.matroska, self.hevc, self.prores]:
            code, report = self.mpcut("scenes", "--json", "--no-sidecar", path)
            self.assertEqual(code, 0, (path, report))
            self.assertEqual([s["startSeconds"] for s in report["scenes"]], [0, 3], path)

    def test_default_frame_export_reads_around_the_damage(self):
        for path in [self.h264, self.matroska, self.hevc, self.prores]:
            folder = Path(tempfile.mkdtemp(dir=self.root)) / "frames"
            code, report = self.mpcut("frames", "--json", "--no-sidecar", "--output", folder, path)
            self.assertEqual(code, 0, (path, report))
            self.assertEqual([f["frameTime"] for f in report["frames"]],
                             [{"numerator": 37, "denominator": 25}, {"numerator": 112, "denominator": 25}], path)
            self.assertEqual(sorted(p.name for p in folder.iterdir()),
                             ["frame-000001.jpg", "frame-000002.jpg", "manifest.json"])

    def test_pictures_after_the_next_keyframe_are_exported(self):
        # Reading starts at the beginning and passes the damaged packet.
        for path in [self.h264, self.matroska]:
            code, report = self.frames(path, "0.5", "1.5", "2.5", "3.5", "5")
            self.assertEqual(code, 0, (path, report))
            self.assertEqual([f["frameTime"]["numerator"] / f["frameTime"]["denominator"] for f in report["frames"]],
                             [0.48, 1.48, 2.48, 3.48, 5], path)
        code, report = self.frames(self.prores, "0.5", "1.56", "1.64", "5")
        self.assertEqual(code, 0, report)
        self.assertEqual(len(report["frames"]), 4)

    def test_pictures_that_depend_on_the_damage_are_refused(self):
        # 1.7 and 1.96 follow the damaged picture inside its group. 1.6 is the picture itself.
        for path in [self.h264, self.matroska, self.hevc]:
            for time in ["1.6", "1.7", "1.96"]:
                code, report = self.frames(path, time)
                self.assertEqual((code, report["ok"], report["error"]["code"]),
                                 (1, False, "frame_export_failed"), (path, time))
        code, report = self.frames(self.prores, "1.6")
        self.assertEqual((code, report["error"]["code"]), (1, "frame_export_failed"))

    def test_a_refused_picture_leaves_no_folder(self):
        folder = Path(tempfile.mkdtemp(dir=self.root))
        code, _ = self.mpcut("frames", "--json", "--no-sidecar", "--at", "0.5", "--at", "1.7",
                             "--output", folder / "frames", self.h264)
        self.assertEqual(code, 1)
        self.assertEqual(list(folder.iterdir()), [])

    def test_video_without_a_decodable_picture_still_fails(self):
        for source in [self.h264, self.hevc]:
            garbage = self.root / ("garbage-" + source.name)
            garbage.write_bytes(source.read_bytes())
            damage_payload(garbage, range(150))
            code, report = self.mpcut("scenes", "--json", "--no-sidecar", garbage)
            self.assertEqual((code, report["ok"], report["error"]["code"]),
                             (1, False, "scene_analysis_failed"), source)
            code, report = self.frames(garbage, "3")
            self.assertEqual((code, report["error"]["code"]), (1, "frame_export_failed"), source)


class SelectedTrackIssue(unittest.TestCase):
    """Both soundtracks are unusable. The report must name the one the caller selected."""

    @classmethod
    def setUpClass(cls):
        scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(scratch.cleanup)
        cls.root = Path(scratch.name)
        clean = cls.root / "clean.mp4"
        run([FFMPEG, "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=s=320x240:r=25:d=3",
             "-f", "lavfi", "-i", "sine=f=440:r=48000:d=3", "-f", "lavfi", "-i", "sine=f=880:r=48000:d=3",
             "-map", "0", "-map", "1", "-map", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
             "-c:a", "aac", "-use_editlist", "0", clean])
        data = clean.read_bytes()
        tables, at = [], data.find(b"stts")
        while at >= 0:
            tables.append(at)
            at = data.find(b"stts", at + 4)
        assert len(tables) == 3, tables

        def without_durations(tracks):
            # A zero sample duration gives every packet of the track the same timestamp.
            edited = bytearray(data)
            for track in tracks:
                count = int.from_bytes(edited[tables[track] + 8:tables[track] + 12], "big")
                for entry in range(count):
                    start = tables[track] + 12 + entry * 8 + 4
                    edited[start:start + 4] = bytes(4)
            return edited

        cls.both = cls.root / "both.mp4"
        cls.both.write_bytes(without_durations([1, 2]))
        cls.second = cls.root / "second.mp4"
        cls.second.write_bytes(without_durations([2]))

    def export(self, source, stream, *options):
        result = run([CLI, "export", "--json", "--dry-run", *options, "--tracks", "audio", "--audio-stream", str(stream),
                      "--output", self.root / "out.m4a", "--clip", source], check=False)
        return result.returncode, json.loads(result.stdout)

    def test_each_track_reports_its_own_issue(self):
        for source, stream in [(self.both, 1), (self.both, 2), (self.second, 2)]:
            code, report = self.export(source, stream, "--no-sidecar")
            self.assertEqual((code, report["error"]["code"]), (1, "unsupported_tracks"), (source, stream))
            self.assertTrue(report["error"]["message"].startswith(f"AAC track {stream} "), report)
        code, report = self.export(self.second, 1, "--no-sidecar")
        self.assertEqual(code, 0, report)
        output = self.root / "healthy.m4a"
        run([CLI, "export", "--no-sidecar", "--tracks", "audio", "--audio-stream", "1",
             "--output", output, "--clip", self.second])

        def payload_hashes(file):
            result = run([FFPROBE, "-v", "error", "-select_streams", "a:0", "-show_packets",
                          "-show_entries", "packet=data_hash", "-show_data_hash", "sha256", "-of", "json", file])
            return [packet["data_hash"] for packet in json.loads(result.stdout)["packets"]]

        original = payload_hashes(self.second)
        self.assertTrue(original)
        self.assertEqual(payload_hashes(output), original)

    def test_saved_index_keeps_each_track_issue(self):
        result = run([CLI, "sidecar", "--json", "--only", "index", self.both], check=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(Path(str(self.both) + ".mpcut").exists())
        for stream in [1, 2]:
            code, report = self.export(self.both, stream)
            self.assertEqual(code, 1, report)
            self.assertTrue(report["error"]["message"].startswith(f"AAC track {stream} "), report)


class MissingProject(unittest.TestCase):
    def test_frames_reports_an_unreadable_project_like_inspect(self):
        with tempfile.TemporaryDirectory() as scratch:
            missing = Path(scratch) / "missing.multicam.json"
            for project in [missing, Path(scratch)]:
                codes = []
                for command in [["inspect", "--json", "--project", project],
                                ["frames", "--json", "--project", project, "--at", "1",
                                 "--output", Path(scratch) / "frames"]]:
                    result = run([CLI, *command], check=False)
                    report = json.loads(result.stdout)
                    codes.append((result.returncode, report["error"]["code"]))
                self.assertEqual(codes, [(1, "multicam_project_read_failed")] * 2, project)
            self.assertFalse((Path(scratch) / "frames").exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
