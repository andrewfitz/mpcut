#!/usr/bin/env python3
"""Compare signed waveform data against independently decoded source samples."""
import argparse
import array
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import unittest
import wave


TIMEOUT = 120


def run(command, **options):
    return subprocess.run(command, timeout=TIMEOUT, **options)


def check_output(command, **options):
    return subprocess.check_output(command, timeout=TIMEOUT, **options)


class Waveform(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(scratch.cleanup)
        root = Path(scratch.name)
        cls.wav = root / "stereo.wav"
        cls.flac = root / "stereo.flac"
        cls.movie = root / "stereo.mov"
        cls.rate = 48_000
        # Positive left DC and negative right signal identify both polarities,
        # and an isolated one-sample transient distinguishes this from 20 ms peaks.
        data = b"".join(struct.pack("<hh", 30000 if n % 137 == 0 else 4000 + n % 999,
                                    -11000 + n % 509) for n in range(5 * cls.rate))
        with wave.open(str(cls.wav), "wb") as track:
            track.setparams((2, 2, cls.rate, 0, "NONE", "NONE"))
            track.writeframes(data)
        cls.pcm = array.array("h")
        cls.pcm.frombytes(data)
        run(["ffmpeg", "-loglevel", "error", "-i", cls.wav, "-c:a", "flac", cls.flac], check=True)
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "color=s=160x96:r=5:d=5",
                        "-i", cls.wav, "-map", "0:v:0", "-map", "1:a:0", "-c:v", "libx264",
                        "-c:a", "copy", cls.movie], check=True)

    def check_window(self, path, first, length, columns):
        command = [CLI, "waveform", "--json", "--from", f"{first}/{self.rate}",
                   "--to", f"{first + length}/{self.rate}", "--columns", str(columns), path]
        report = json.loads(check_output(command))
        self.assertTrue(report["ok"])
        self.assertEqual(report["sampleRate"], self.rate)
        self.assertEqual(report["columns"], columns)
        self.assertAlmostEqual(report["envelope"]["from"], first / self.rate)
        self.assertAlmostEqual(report["envelope"]["to"], (first + length) / self.rate)
        low, high = [], []
        for i in range(columns):
            a = first + (i * length + columns - 1) // columns
            b = first + ((i + 1) * length + columns - 1) // columns
            if a == b:
                a = max(0, a - 1)
                b = a + 1
            points = self.pcm[2*a:2*b]
            low.append(min(points) / 32768)
            high.append(max(points) / 32768)
        for key, reference in [("low", low), ("high", high)]:
            measured = report["envelope"][key]
            self.assertEqual(len(measured), columns)
            self.assertLess(max(abs(a-b) for a, b in zip(measured, reference)), 1e-7)

    def test_audio_video_and_seek_share_the_same_clock(self):
        for path in [self.wav, self.flac, self.movie]:
            with self.subTest(path=path):
                self.check_window(path, 204801, 3277, 321)

    def test_sample_and_subsample_detail(self):
        self.check_window(self.flac, 773, 1024, 1024)
        self.check_window(self.flac, 4606, 4, 15)
        self.check_window(self.wav, 3001, 4, 16)
        self.check_window(self.wav, 4094, 4, 15)

    def test_wav_seek_matches_decoded_samples_at_the_head_middle_and_tail(self):
        for codec in ["pcm_u8", "pcm_s24le", "pcm_s32le", "pcm_s64le", "pcm_f32le", "pcm_f64le"]:
            path = self.wav.with_name(codec + ".wav")
            run(["ffmpeg", "-loglevel", "error", "-i", self.wav, "-c:a", codec, path], check=True)
            reference = array.array("f")
            reference.frombytes(check_output(
                ["ffmpeg", "-loglevel", "error", "-i", path, "-f", "f32le", "-"]))
            for start, count in [(3, 11), (3 * self.rate + 17, 257), (5 * self.rate - 7, 7)]:
                with self.subTest(codec=codec, start=start):
                    report = json.loads(check_output(
                        [CLI, "--no-sidecar", "waveform", "--json", "--from", f"{start}/{self.rate}",
                         "--to", f"{start + count}/{self.rate}", "--columns", str(count), path]))
                    samples = [reference[i*2:i*2+2] for i in range(start, start + count)]
                    for extrema, reducer in (("low", min), ("high", max)):
                        expected = [reducer(values) for values in samples]
                        self.assertEqual(len(report["envelope"][extrema]), count)
                        self.assertLess(max(abs(a-b) for a, b in zip(report["envelope"][extrema], expected)), 1e-7)

    def test_coarse_container_clock_keeps_sample_position_in_a_late_window(self):
        matroska = self.wav.with_suffix(".mkv")
        run(["ffmpeg", "-loglevel", "error", "-i", self.wav, "-c:a", "copy", matroska], check=True)
        self.check_window(matroska, 204801, 701, 701)

    def test_coarse_lossless_clock_preserves_the_entire_last_packet(self):
        source = self.wav.with_name("pcm-44100.wav")
        rate, samples = 44_100, 44_111
        raw = b"".join(struct.pack("<h", i % 20_000) for i in range(samples))
        with wave.open(str(source), "wb") as track:
            track.setparams((1, 2, rate, 0, "NONE", "NONE"))
            track.writeframes(raw)
        duration = {"numerator": samples, "denominator": rate}
        expected = [i % 20_000 / 32768 for i in range(samples - 10, samples)]
        for encoder in ["copy", "flac"]:
            with self.subTest(encoder=encoder):
                path = source.with_name(f"{encoder}-44100.mka")
                run(["ffmpeg", "-loglevel", "error", "-i", source, "-c:a", encoder, path], check=True)
                inspect = [CLI, "inspect", "--json", path]
                self.assertEqual(json.loads(check_output(inspect))["media"]["duration"], duration)
                check_output([CLI, "sidecar", "--json", "--only", "index", path])
                self.assertEqual(json.loads(check_output(inspect))["media"]["duration"], duration)
                with sqlite3.connect(path.with_suffix(".mka.mpcut")) as cache:
                    key = "index.v1"
                    stamp = cache.execute("SELECT stamp FROM source WHERE id = 1").fetchone()[0]
                    saved = cache.execute("SELECT value FROM sections WHERE name = ?", (key,)).fetchone()[0]
                    header = plistlib.loads(saved)
                    header.update(probeRevision=2, duration={"numerator": 1, "denominator": 1})
                    saved = plistlib.dumps(header, fmt=plistlib.FMT_BINARY)
                    digest = hashlib.sha256(stamp.encode() + b"\0" + key.encode() + b"\0" + saved).digest()
                    cache.execute("UPDATE sections SET value = ?, digest = ? WHERE name = ?", (saved, digest, key))
                self.assertEqual(json.loads(check_output(inspect))["media"]["duration"], duration)
                envelope = json.loads(check_output(
                    [CLI, "waveform", "--json", "--from", f"{samples - 10}/{rate}", "--to", f"{samples}/{rate}",
                     "--columns", "10", path]
                ))["envelope"]
                for extrema in ["low", "high"]:
                    self.assertLess(max(abs(a - b) for a, b in zip(envelope[extrema], expected, strict=True)), 1e-7)

    def test_empty_sample_on_precise_clock_displays_as_zero(self):
        gap = self.wav.with_suffix(".nut")
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "aevalsrc=0.25:s=48000:d=0.01",
                        "-af", r"asetnsamples=n=1:p=0,aselect=not(eq(n\,100))", "-c:a", "pcm_s16le", gap],
                       check=True)
        envelope = json.loads(check_output(
            [CLI, "waveform", "--json", "--from", "98/48000", "--to", "104/48000", "--columns", "6", gap]
        ))["envelope"]
        self.assertEqual(envelope["low"], [0.25, 0.25, 0, 0.25, 0.25, 0.25])
        self.assertEqual(envelope["high"], envelope["low"])

    def test_cached_overview_coarsens_into_the_same_whole_and_partial_windows(self):
        # A private copy keeps the saved neighbour away from the shared fixture,
        # so no other test in this class can depend on running before this one.
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        source = Path(scratch.name) / "stereo.wav"
        shutil.copyfile(self.wav, source)
        shared_sidecar = self.wav.with_name(self.wav.name + ".mpcut")
        shared_stamp = shared_sidecar.stat().st_mtime_ns if shared_sidecar.exists() else None
        sidecar = source.with_name(source.name + ".mpcut")

        def status():
            return json.loads(check_output([CLI, "sidecar", "--json", "--status", source]))

        def window(*flags, span=()):
            return json.loads(check_output(
                [CLI, *flags, "waveform", "--json", "--columns", "1024", *span, source]))

        self.assertEqual(status()["status"], "missing")
        saved = json.loads(check_output([CLI, "sidecar", "--json", "--only", "index,audio", source]))
        self.assertEqual(saved["sidecar"], str(sidecar))
        self.assertEqual(status()["status"], "current")
        self.assertEqual(status()["inventory"]["envelopeStreams"], [0])
        self.assertIn("envelope.v2.0", status()["sections"])
        spans = [[], ["--from", "5/4", "--to", "15/4"]]
        fresh = [window("--no-sidecar", span=span) for span in spans]
        for span, expected in zip(spans, fresh, strict=True):
            self.assertEqual(len(expected["envelope"]["low"]), 1024)
            self.assertEqual(window(span=span), expected)

        # Equal reports do not show which path produced them. Rewrite the start
        # of the stored minima with a valid digest: the cached overview must now
        # differ exactly there, while a fresh read ignores the neighbour.
        key = "envelope.v2.0"
        with sqlite3.connect(sidecar) as db:
            stamp = db.execute("SELECT stamp FROM source WHERE id=1").fetchone()[0]
            payload = bytearray(db.execute("SELECT value FROM sections WHERE name=?", (key,)).fetchone()[0])
            header = bytes.fromhex("4f1200040000")  # property-list data of 65,536 float32 columns
            self.assertEqual(payload.count(header), 2)
            first = payload.index(header) + len(header)
            payload[first:first + 4 * 4096] = struct.pack("<f", -1.0) * 4096
            encoded = bytes(payload)
            digest = hashlib.sha256(stamp.encode() + b"\0" + key.encode() + b"\0" + encoded).digest()
            db.execute("UPDATE sections SET value=?, digest=? WHERE name=?", (encoded, digest, key))
        self.assertEqual(status()["status"], "current")
        cached = window()["envelope"]
        self.assertEqual(cached["low"][:8], [-1] * 8)
        self.assertEqual(cached["low"][512:], fresh[0]["envelope"]["low"][512:])
        self.assertEqual(cached["high"], fresh[0]["envelope"]["high"])
        self.assertEqual(window("--no-sidecar"), fresh[0])
        self.assertEqual(shared_sidecar.stat().st_mtime_ns if shared_sidecar.exists() else None, shared_stamp)

    def test_vbr_mp3_zoom_keeps_sample_clock_after_encoder_delay(self):
        mp3 = self.wav.with_suffix(".mp3")
        run(["ffmpeg", "-loglevel", "error", "-i", self.wav, "-c:a", "libmp3lame", "-q:a", "3", mp3],
                       check=True)
        reference = array.array("f")
        reference.frombytes(check_output(["ffmpeg", "-loglevel", "error", "-i", mp3, "-f", "f32le", "-"]))
        first = 151233
        envelope = json.loads(check_output(
            [CLI, "waveform", "--json", "--from", f"{first}/48000", "--to", f"{first+701}/48000",
             "--columns", "701", mp3]))["envelope"]
        self.assertEqual((len(envelope["low"]), len(envelope["high"])), (701, 701))
        for i, (lo, hi) in enumerate(zip(envelope["low"], envelope["high"], strict=True)):
            stereo = reference[2*(i + first):2*(i + first + 1)]
            self.assertAlmostEqual(lo, min(stereo), delta=1e-6)
            self.assertAlmostEqual(hi, max(stereo), delta=1e-6)

    def test_wave_duration_handles_an_odd_payload_and_truncated_data(self):
        with tempfile.TemporaryDirectory() as scratch:
            full = Path(scratch) / "odd.wav"
            with wave.open(str(full), "wb") as track:
                track.setparams((1, 1, self.rate, 0, "NONE", "NONE"))
                track.writeframes(bytes([64, 128, 192, 160, 96]))
            truncated = Path(scratch) / "truncated.wav"
            truncated.write_bytes(self.wav.read_bytes()[:-4])
            args = [CLI, "waveform", "--json", "--columns", "5", full]
            envelope = json.loads(check_output(args))["envelope"]
            self.assertAlmostEqual(envelope["to"], 5 / self.rate)
            self.assertEqual(envelope["low"], [-0.5, 0, 0.5, 0.25, -0.25])
            self.assertEqual(envelope["high"], envelope["low"])
            self.check_window(truncated, 5 * self.rate - 4, 3, 3)
            result = run([CLI, "waveform", "--json", "--to", "5", truncated], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)["error"]["code"], "invalid_range")

    def test_validates_stream_and_window(self):
        # Stream 0 of the movie is its picture; the clip lasts five seconds.
        for flags, status, code in [
                (["--columns", "0"], 2, "invalid_arguments"),
                (["--columns", "65537"], 2, "invalid_arguments"),
                (["--from", "1", "--to", "1"], 1, "invalid_range"),
                (["--from", "6"], 1, "invalid_range"),
                (["--stream", "0"], 1, "no_audio")]:
            with self.subTest(flags=flags):
                proc = run([CLI, "waveform", "--json", *flags, self.movie], capture_output=True)
                self.assertEqual(proc.returncode, status, proc.stdout)
                report = json.loads(proc.stdout)
                self.assertIs(report["ok"], False)
                self.assertEqual(report["error"]["code"], code, report)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, remaining = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *remaining])
