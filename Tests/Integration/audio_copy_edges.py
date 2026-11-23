#!/usr/bin/env python3
"""Check audible extents and codec delay when copying edited audio tracks."""
import argparse
from fractions import Fraction
import hashlib
import json
import plistlib
import sqlite3
from pathlib import Path
import subprocess
import tempfile
import unittest

from sidecar_payload import section_bytes

from audio_tracks import ffmpeg, hashes, pcm, probe, time


class CopyEdges(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.wave = self.root / "source.wav"
        ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.4*sin(2*PI*(227*t+201*t*t)):s=44100:d=3.33",
               "-c:a", "pcm_s16le", self.wave)

    def run_cli(self, *args, success=True):
        proc = subprocess.run([CLI, *args, "--json"], capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode == 0, success, proc.stdout + proc.stderr)
        return json.loads(proc.stdout)

    def test_flac_reordered_packets_get_an_accurate_matroska_clock(self):
        source = self.root / "input.flac"
        ffmpeg("-i", self.wave, "-c:a", "flac", source)
        packets = probe(source, "-show_packets", "-show_data_hash", "sha256",
                        "-show_entries", "packet=pts,duration,data_hash")["packets"]
        slices = [(15, 22), (2, 5)]
        flags = []
        for first, end in slices:
            flags += ["--clip", source, "--from", f"{packets[first]['pts']}/44100", "--to", f"{packets[end]['pts']}/44100"]
        bad = self.root / "edit.flac"
        error = self.run_cli("export", "clips", "join", "--dry-run", "--output", bad, *flags, success=False)
        self.assertEqual(error["error"]["code"], "unsupported_container")
        self.assertIn("mka", error["error"]["message"])
        self.assertFalse(bad.exists())
        output = self.root / "edit.mka"
        report = self.run_cli("export", "clips", "join", "--output", output, *flags)
        expected_packets = [p for first, end in slices for p in packets[first:end]]
        self.assertEqual(hashes(output, "a:0"), [p["data_hash"] for p in expected_packets])
        source_pcm = pcm(source)
        expected_pcm = b"".join(source_pcm[2 * packets[a]["pts"]:2 * packets[b]["pts"]] for a, b in slices)
        self.assertEqual(pcm(output), expected_pcm)
        self.assertEqual(time(report["duration"]), Fraction(len(expected_pcm), 2 * 44100))
        output_info = probe(output, "-show_format", "-show_entries", "format=duration")
        self.assertLess(abs(Fraction(output_info["format"]["duration"]) - time(report["duration"])), Fraction(1, 1000))
        restored = self.run_cli("media", "inspect", output)
        self.assertLess(abs(time(restored["media"]["duration"]) - time(report["duration"])), Fraction(1, 1000))
        last_sample = packets[-1]["pts"] + packets[-1]["duration"]
        near_end = self.run_cli("export", "clips", "join", "--dry-run", "--output", self.root / "tail.mka", "--snap", "nearest",
                                "--clip", source, "--from", f"{packets[5]['pts']}/44100", "--to", f"{last_sample - 1}/44100")
        self.assertEqual(time(near_end["segments"][0]["to"]), Fraction(last_sample, 44100))

    def test_joins_independently_recorded_flac_tracks_without_changing_packets(self):
        first, second = self.root / "first.flac", self.root / "second.flac"
        ffmpeg("-i", self.wave, "-c:a", "flac", first)
        ffmpeg("-i", self.wave, "-af", "volume=0.5", "-sample_fmt", "s16", "-c:a", "flac", second)
        output = self.root / "joined.mka"
        self.run_cli("export", "clips", "join", "--output", output, "--clip", second, "--clip", first)
        self.assertEqual(hashes(output, "a:0"), hashes(second, "a:0") + hashes(first, "a:0"))
        self.assertEqual(pcm(output), pcm(second) + pcm(first))

        other_depth = self.root / "24bit.flac"
        ffmpeg("-i", self.wave, "-sample_fmt", "s32", "-c:a", "flac", other_depth)
        result = self.run_cli("export", "clips", "join", "--dry-run", "--output", self.root / "mismatch.mka",
                              "--clip", first, "--clip", other_depth, success=False)
        self.assertEqual(result["error"]["code"], "incompatible_clip")

    def test_preserves_mp3_gapless_extent_and_rejects_an_interior_splice(self):
        source = self.root / "input.mp3"
        output = self.root / "copy.mp3"
        ffmpeg("-i", self.wave, "-c:a", "libmp3lame", "-q:a", "2", source)
        report = self.run_cli("export", "clips", "join", "--output", output, "--clip", source)
        self.assertEqual(hashes(output, "a:0"), hashes(source, "a:0"))
        decoded = pcm(source)
        self.assertEqual(pcm(output), decoded)
        self.assertEqual(time(report["duration"]), Fraction(len(decoded), 2 * 44100))
        error = self.run_cli("export", "clips", "join", "--dry-run", "--clip", source, "--output", self.root / "bad.mka", success=False)
        self.assertEqual(error["error"]["code"], "unsupported_container")
        error = self.run_cli("export", "clips", "join", "--dry-run", "--snap", "nearest", "--clip", source, "--to", "0.7",
                             "--clip", source, "--from", "1", "--output", self.root / "join.mp3", success=False)
        self.assertEqual(error["error"]["code"], "unsafe_boundary")

    def test_mp3_copy_trims_preserve_exact_samples_and_original_packets(self):
        for name, options, ranges in [
            ("cbr", ["-b:a", "128k"], [(0, 3), (44223, 47556)]),
            ("vbr", ["-q:a", "2"], [(123, 12457)]),
        ]:
            source = self.root / f"{name}.mp3"
            ffmpeg("-i", self.wave, "-c:a", "libmp3lame", *options, source)
            original = ffmpeg("-i", source, "-f", "f32le", "-")
            packets = hashes(source, "a:0")
            for start, end in ranges:
                with self.subTest(name=name, start=start, end=end):
                    output = self.root / f"{name}-{start}.mp3"
                    report = self.run_cli("export", "clips", "join", "--clip", source, "--from", f"{start}/44100",
                                          "--to", f"{end}/44100", "--output", output)
                    self.assertEqual(time(report["duration"]), Fraction(end - start, 44100))
                    self.assertEqual(ffmpeg("-i", output, "-f", "f32le", "-"), original[4 * start:4 * end])
                    copied = hashes(output, "a:0")
                    first = packets.index(copied[0])
                    self.assertEqual(copied, packets[first:first + len(copied)])
                    # The hidden decoder history or tail padding can span several frames.
                    # Reopening the crop should advertise and retain only its audible samples.
                    saved = self.root / f"{name}-{start}-saved.mp3"
                    again = self.run_cli("export", "clips", "join", "--clip", output, "--output", saved)
                    self.assertEqual(time(again["duration"]), Fraction(end - start, 44100))
                    self.assertEqual(time(again["segments"][0]["from"]), 0)
                    self.assertEqual(ffmpeg("-i", saved, "-f", "f32le", "-"), original[4 * start:4 * end])

        # This tonal VBR stream uses more reservoir history than Xing delay can hide.
        output = self.root / "unsafe.mp3"
        for start, end in [(44223, 47556), (93001, 93998)]:
            error = self.run_cli("export", "clips", "join", "--clip", self.root / "vbr.mp3", "--from", f"{start}/44100",
                                 "--to", f"{end}/44100", "--output", output, success=False)
            self.assertEqual(error["error"]["code"], "unsafe_boundary")
            self.assertFalse(output.exists())

    def test_indexed_mp3_seek_matches_sequential_decode_and_old_sidecars(self):
        for name, options in [("cbr", ["-b:a", "128k"]), ("vbr", ["-q:a", "2"])]:
            source = self.root / f"{name}.mp3"
            ffmpeg("-i", self.wave, "-c:a", "libmp3lame", "-reservoir", "0", *options, source)
            start, end = 103123, 129057
            expected = ffmpeg("-i", source, "-f", "f32le", "-")[4 * start:4 * end]
            self.run_cli("analysis", "sidecar", "build", "--only", "index", source)
            for mode in ["indexed", "bad_checksum", "legacy"]:
                with self.subTest(name=name, mode=mode):
                    if mode != "indexed":
                        with sqlite3.connect(str(source) + ".cutdb") as db:
                            value = section_bytes(db, "media_index.v1")
                            stamp, = db.execute("SELECT stamp FROM source").fetchone()
                            header = plistlib.loads(value)
                            anchors = header["audio"][0]["mp3_anchors"]
                            self.assertGreater(len(anchors), 1)
                            if mode == "bad_checksum":
                                for anchor in anchors:
                                    anchor["checksum"] ^= 1
                            else:
                                del header["audio"][0]["mp3_anchors"]
                            value = plistlib.dumps(header, fmt=plistlib.FMT_BINARY)
                            digest = hashlib.sha256(stamp.encode() + b"\0media_index.v1\0" + value).digest()
                            db.execute("UPDATE sections SET logical_size=0, value=?, digest=? WHERE name='media_index.v1'", (value, digest))
                    output = self.root / f"{name}-{mode}.mp3"
                    self.run_cli("export", "clips", "join", "--clip", source, "--from", f"{start}/44100",
                                 "--to", f"{end}/44100", "--output", output)
                    self.assertEqual(ffmpeg("-i", output, "-f", "f32le", "-"), expected)

    def test_untagged_mp3_whole_copy_keeps_all_samples(self):
        source = self.root / "untagged.mp3"
        output = self.root / "copy.mp3"
        ffmpeg("-i", self.wave, "-c:a", "libmp3lame", "-b:a", "128k", "-write_xing", "0", source)
        report = self.run_cli("export", "clips", "join", "--output", output, "--clip", source)
        decoded = ffmpeg("-i", source, "-f", "f32le", "-")
        self.assertEqual(hashes(output, "a:0"), hashes(source, "a:0"))
        self.assertEqual(time(report["duration"]), Fraction(len(decoded), 4 * 44100))
        self.assertEqual(ffmpeg("-i", output, "-f", "f32le", "-"), decoded)

    def test_selected_pcm_track_duration_excludes_absent_movie_audio(self):
        movie = self.root / "delayed.mov"
        ffmpeg("-f", "lavfi", "-i", "color=s=192x96:r=25:d=5", "-itsoffset", "0.4", "-i", self.wave,
               "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-c:a", "copy", movie)
        source_bytes = pcm(self.wave)
        for i, (args, start, end) in enumerate([
            ([], 0, len(source_bytes) // 2),
            (["--from", "0", "--to", "0.5"], 0, 4410),
            (["--from", "3", "--to", "5"], 114660, len(source_bytes) // 2),
        ]):
            with self.subTest(args=args):
                output = self.root / f"extracted-{i}.wav"
                report = self.run_cli("export", "clips", "join", "--tracks", "audio", "--audio-stream", "1",
                                      "--output", output, "--clip", movie, *args)
                self.assertEqual(time(report["duration"]), Fraction(end - start, 44100))
                self.assertEqual(pcm(output), source_bytes[2 * start:2 * end])
                track = report["segments"][0]["tracks"][0]
                self.assertEqual(time(track["output_start"]), 0)
                self.assertEqual(time(track["output_end"]), time(report["duration"]))

    def test_delayed_aac_extract_preserves_short_last_packet(self):
        audio = self.root / "audio.m4a"
        movie = self.root / "delayed-aac.mov"
        output = self.root / "extracted.m4a"
        ffmpeg("-i", self.wave, "-c:a", "aac", audio)
        ffmpeg("-f", "lavfi", "-i", "color=s=192x96:r=25:d=5", "-itsoffset", "0.4", "-i", audio,
               "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-c:a", "copy", movie)
        fields = ("-select_streams", "a:0", "-show_streams", "-show_entries", "stream=start_pts,duration_ts,time_base")
        original = probe(movie, *fields)["streams"][0]
        self.assertGreater(original["start_pts"], 0)
        self.assertNotEqual(original["duration_ts"] % 1024, 0)
        result = self.run_cli("export", "clips", "join", "--tracks", "audio", "--audio-stream", "1", "--clip", movie, "--output", output)
        extracted = probe(output, *fields)["streams"][0]
        self.assertEqual(extracted["start_pts"], 0)
        self.assertEqual(extracted["duration_ts"], original["duration_ts"])
        self.assertEqual(time(result["duration"]), original["duration_ts"] * Fraction(original["time_base"]))
        self.assertEqual(hashes(output, "a:0"), hashes(movie, "a:0"))

    def test_one_opus_packet_with_both_trims_keeps_its_audible_extent(self):
        source = self.root / "short.opus"
        ffmpeg("-f", "lavfi", "-i", "sine=sample_rate=48000:duration=0.005", "-c:a", "libopus", source)
        decoded = pcm(source)
        self.assertEqual(len(decoded), 240 * 2)
        info = self.run_cli("media", "inspect", source)
        self.assertEqual(time(info["media"]["duration"]), Fraction(240, 48000))
        for ext in ["mka", "webm"]:
            output = self.root / f"short.{ext}"
            result = self.run_cli("export", "clips", "join", "--clip", source, "--output", output, success=False)
            self.assertEqual(result["error"]["code"], "unsupported_container")
            self.assertFalse(output.exists())

        output = self.root / "copy.opus"
        self.run_cli("export", "clips", "join", "--clip", source, "--output", output)
        self.assertEqual(pcm(output), decoded)
        self.assertEqual(hashes(output, "a:0"), hashes(source, "a:0"))

    def test_ogg_opus_crop_uses_hidden_preroll_and_exact_tail(self):
        source = self.root / "input.opus"
        output = self.root / "trim.mka"
        ffmpeg("-i", self.wave, "-ar", "48000", "-c:a", "libopus", source)
        start, end = 101904, 132557
        report = self.run_cli("export", "clips", "join", "--output", output, "--clip", source,
                              "--from", f"{start}/48000", "--to", f"{end}/48000")
        self.assertEqual(time(report["duration"]), Fraction(end - start, 48000))
        self.assertEqual(pcm(output), pcm(source)[2 * start:2 * end])
        original = hashes(source, "a:0")
        copied = hashes(output, "a:0")
        first = original.index(copied[0])
        self.assertEqual(copied, original[first:first + len(copied)])

    def test_omitting_subtitle_does_not_mask_a_corrupt_selected_track(self):
        source = self.root / "subtitled.mov"
        subtitle = self.root / "caption.srt"
        subtitle.write_text("1\n00:00:00,000 --> 00:00:00,300\nCaption\n")
        picture = Path(__file__).resolve().parents[1] / "MPCutAppTests/Fixtures/ProRes-2997.mov"
        ffmpeg("-i", picture, "-i", subtitle, "-map", "0:v", "-map", "1:s",
               "-c:v", "copy", "-c:s", "mov_text", source)
        output = self.root / "video.mov"
        command = ("export", "clips", "join", "--dry-run", "--tracks", "video", "--clip", source, "--output", output)
        self.run_cli(*command)
        packets = probe(source, "-select_streams", "v:0", "-show_packets",
                        "-show_entries", "packet=pos")["packets"]
        with source.open("r+b") as packet:
            packet.seek(int(packets[len(packets) // 2]["pos"]) + 4)
            self.assertEqual(packet.read(4), b"icpf")
            packet.seek(-4, 1)
            packet.write(b"xxxx")
        result = self.run_cli(*command, success=False)
        self.assertIn("frame header", result["error"]["message"])

    def test_vorbis_prefix_counts_the_first_audible_overlap(self):
        source = self.root / "input.ogg"
        output = self.root / "prefix.ogg"
        ffmpeg("-i", self.wave, "-ac", "2", "-c:a", "vorbis", "-strict", "experimental", source)
        original = pcm(source)
        info = self.run_cli("media", "inspect", source)
        self.assertEqual(time(info["media"]["duration"]), Fraction(len(original), 4 * 44100))
        report = self.run_cli("export", "clips", "join", "--clip", source, "--to", "2.01", "--snap", "nearest", "--output", output)
        samples = time(report["duration"]) * 44100
        self.assertEqual(samples.denominator, 1)
        self.assertEqual(pcm(output), original[:4 * int(samples)])
        track = report["segments"][0]["tracks"][0]
        self.assertEqual(time(track["output_start"]), 0)
        self.assertEqual(time(track["output_end"]), time(report["duration"]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args, tests = parser.parse_known_args()
    CLI = str(args.binary.resolve(strict=True))
    unittest.main(argv=[__file__, *tests])
