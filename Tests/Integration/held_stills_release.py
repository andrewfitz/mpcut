#!/usr/bin/env python3
"""Check sparse lossless still exports from a built MPCut.app.

ffprobe and ffmpeg on PATH are independent readers. The packaged CLI runs
with a restricted PATH and no development helper or library overrides.
"""
import argparse
from array import array
from fractions import Fraction
from itertools import product
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
import wave

from media_regression import ffmpeg, probe, ratio, run, sample_hashes, timestamped_hashes


COLORS = {"sdr": "bt709", "pq": "smpte2084", "hlg": "arib-std-b67"}
MATRIX = [
    ("mov", "h264", ("sdr",), ("alac", "pcm")),
    ("mov", "jpeg", ("sdr",), ("pcm",)),
    ("mov", "hevc", COLORS, ("alac", "pcm")),
    ("mov", "prores", COLORS, ("alac", "pcm")),
    ("mp4", "h264", ("sdr",), ("alac", "flac")),
    ("mp4", "hevc", COLORS, ("alac", "flac")),
    ("m4v", "h264", ("sdr",), ("alac", "flac")),
    ("m4v", "hevc", COLORS, ("alac", "flac")),
    ("mkv", "h264", ("sdr",), ("flac",)),
    ("mkv", "hevc", COLORS, ("flac",)),
    ("mkv", "prores", COLORS, ("flac",)),
]

ARGS = None


def rational(value):
    return {"numerator": value.numerator, "denominator": value.denominator}


def pcm_fixture(path, rate, count, bits=24):
    """Write two nonidentical integer channels and return exact s32le samples."""
    samples = array("i")
    for index in range(count):
        samples.append((((index * 677 + 11) & 0x3FFFFF) - 0x200000) << (32 - bits))
        samples.append((((index * 1601 + 5) & 0x1FFFFF) - 0x100000) << (32 - bits))
    if sys.byteorder != "little":
        samples.byteswap()
    decoded = samples.tobytes()
    with wave.open(str(path), "wb") as wav:
        wav.setparams((2, bits // 8, rate, count, "NONE", "not compressed"))
        if bits == 24:
            packed = bytearray(count * 6)
            for channel_byte in range(3):
                packed[channel_byte::3] = decoded[(channel_byte + 1)::4]
            wav.writeframes(packed)
        else:
            wav.writeframes(decoded)
    return decoded


def elements(data, start=0, end=None):
    """Yield EBML element ID and payload bounds without interpreting payloads."""
    if end is None:
        end = len(data)
    while start < end:
        id_width = 9 - data[start].bit_length()
        assert 1 <= id_width <= 4
        element = int.from_bytes(data[start:start + id_width], "big")
        start += id_width
        size_width = 9 - data[start].bit_length()
        assert 1 <= size_width <= 8
        size = int.from_bytes(data[start:start + size_width], "big") & ((1 << (size_width * 7)) - 1)
        start += size_width
        stop = end if size == (1 << (size_width * 7)) - 1 else start + size
        assert start <= stop <= end
        yield element, start, stop
        start = stop


def matroska_blocks(path, *, all_independent=True):
    """Read the video track's actual BlockDuration values, including the last."""
    raw = path.read_bytes()
    segment = next(elements(raw, start, end) for tag, start, end in elements(raw) if tag == 0x18538067)
    tracks = []
    clusters = []
    scale = 1_000_000
    for tag, start, end in segment:
        if tag == 0x1549A966:
            for field, first, last in elements(raw, start, end):
                if field == 0x2AD7B1:
                    scale = int.from_bytes(raw[first:last], "big")
        if tag == 0x1654AE6B:
            for field, first, last in elements(raw, start, end):
                if field != 0xAE:
                    continue
                track = {key: int.from_bytes(raw[a:b], "big") for key, a, b in elements(raw, first, last)
                         if key in (0xD7, 0x83)}
                if track[0x83] == 1:
                    tracks.append(track[0xD7])
        if tag == 0x1F43B675:
            clusters.append((start, end))
    assert len(tracks) == 1, tracks
    video_track = tracks[0]
    result = []
    for start, end in clusters:
        timestamp = 0
        for tag, first, last in elements(raw, start, end):
            if tag == 0xE7:
                timestamp = int.from_bytes(raw[first:last], "big")
                continue
            if tag not in (0xA0, 0xA3):
                continue
            group = list(elements(raw, first, last)) if tag == 0xA0 else [(0xA1, first, last)]
            block, _ = next((a, b) for key, a, b in group if key == 0xA1)
            width = 9 - raw[block].bit_length()
            track = int.from_bytes(raw[block:block + width], "big") & ((1 << (width * 7)) - 1)
            if track != video_track:
                continue
            offset = int.from_bytes(raw[block + width:block + width + 2], "big", signed=True)
            duration = next((int.from_bytes(raw[a:b], "big") for key, a, b in group if key == 0x9B), None)
            assert duration is not None, "No explicit BlockDuration for video"
            if all_independent:
                assert all(key != 0xFB for key, _, _ in group), "Video block references another block"
            result.append((Fraction((timestamp + offset) * scale, 10**9), Fraction(duration * scale, 10**9)))
    return result


class HeldStillsRelease(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        contents = ARGS.app.resolve() / "Contents"
        cls.cli_path = contents / "Helpers/mpcut"
        helper = contents / "Helpers/ffmpeg"
        for binary in (cls.cli_path, helper):
            assert binary.is_file() and os.access(binary, os.X_OK), binary
        cls.environment = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"]}
        encoders = run([helper, "-hide_banner", "-encoders"], env=cls.environment).decode()
        for encoder in ("alac", "flac", "mjpeg"):
            assert any(line.split()[1:2] == [encoder] for line in encoders.splitlines()), (helper, encoder)
        cls.root = ARGS.work_directory.resolve()
        cls.root.mkdir(parents=True, exist_ok=True)
        cls.white, cls.black = (cls.root / "cover.png", cls.root / "end.png")
        for path, color in ((cls.white, "white"), (cls.black, "black")):
            ffmpeg("-y", "-f", "lavfi", "-i", f"color={color}:size=320x180", "-frames:v", "1", path)
        cls.manifest = []
        cls.results = []
        print(f"Using packaged CLI {cls.cli_path} and helper {helper}", flush=True)

    @classmethod
    def tearDownClass(cls):
        for filename, contents in [("playback.json", cls.manifest), ("verified.json", cls.results)]:
            (cls.root / filename).write_text(json.dumps(contents, indent=2) + "\n")

    def cli(self, *arguments, error=None):
        result = subprocess.run([self.cli_path, *arguments, "--json"], env=self.environment,
                                capture_output=True, text=True, timeout=120)
        try:
            response = json.loads(result.stdout)
        except json.JSONDecodeError as issue:
            self.fail(f"{result.args} exited {result.returncode}: {issue}\n{result.stderr}\n{result.stdout}")
        if error is not None:
            self.assertNotEqual(result.returncode, 0, response)
            self.assertIn(error, json.dumps(response["error"]).lower())
        else:
            self.assertEqual(result.returncode, 0, f"{result.args}\n{response}\n{result.stderr}")
            self.assertTrue(response["ok"], response)
        return response

    def author(self, project, soundtrack, codec, color, first=None, last=None, source_range=None):
        settings = ["--soundtrack", soundtrack]
        if first is None:
            settings.append("--fit-soundtrack")
        else:
            settings += ["--duration", str(first)]
        if source_range is not None:
            settings += ["--from", str(source_range[0]), "--to", str(source_range[1])]
        creation = self.cli("still", "project", "create", "--out-project", project, "--image", self.white,
                            "--width", "320", "--height", "180", "--rate", "24", "--codec", codec,
                            "--container", "mov", "--color", color, *settings)
        if last is not None:
            self.cli("still", "placement", "insert", "--project", project, "--image", self.black,
                     "--clock", "sequence", "--at", str(first), "--duration", str(last), "--in-place")
        return creation

    def verify(self, project, output, *, codec, color, audio, mode, boundaries, expected_pcm,
               audio_rate, add_playback=True, pcm_format="s32le", use_defaults=False):
        extension = output.suffix[1:]
        command = ["export", "project", "render", "--project", project, "--output", output]
        if not use_defaults:
            command += ["--mode", mode, "--video", codec, "--audio", audio, "--still-timing", "held",
                        "--container", extension]
        dry_run = self.cli(*command, "--dry-run")
        self.assertFalse(output.exists())
        self.assertNotIn("output_bytes", dry_run)
        report = self.cli(*command)
        self.assertEqual(report["output_bytes"], output.stat().st_size)
        expected_count = len(boundaries) - 1
        published_codec = "mjpeg" if codec == "jpeg" else codec
        for result in (dry_run, report):
            self.assertEqual(result["container"], extension)
            self.assertEqual(result["mode"], mode)
            self.assertEqual(result["video_codec"], published_codec)
            self.assertEqual(result["picture_timing"], "held")
            self.assertEqual(result["generated_video_sample_count"], expected_count)
            self.assertEqual(ratio(result["generated_still_duration"]), boundaries[-1])

        streams = probe(output, "-show_streams")["streams"]
        self.assertEqual(len(streams), 2)
        video, sound = sorted(streams, key=lambda stream: stream["codec_type"], reverse=True)
        self.assertEqual(video["codec_type"], "video")
        self.assertEqual(video["codec_name"], published_codec)
        self.assertEqual((video["width"], video["height"]), (320, 180))
        self.assertEqual(video["color_transfer"], COLORS[color])
        self.assertEqual(video["color_primaries"], "bt709" if color == "sdr" else "bt2020")
        self.assertEqual(video["color_space"], "bt709" if color == "sdr" else "bt2020nc")
        if audio == "pcm":
            self.assertTrue(sound["codec_name"].startswith("pcm_"), sound)
            if pcm_format.startswith("f"):
                self.assertEqual(sound["codec_name"], f"pcm_{pcm_format}")
        else:
            self.assertEqual(sound["codec_name"], audio)
        self.assertEqual(int(sound["sample_rate"]), audio_rate)
        for result in (dry_run, report):
            self.assertEqual(len(result["sound_actions"]), 1)
            self.assertEqual(result["sound_actions"][0]["audio"], audio)
        self.assertEqual(sound["channels"], 2)
        audio_clock = Fraction(sound["time_base"])
        self.assertEqual(int(sound["start_pts"]), 0)
        audio_frames = probe(output, "-select_streams", "a:0", "-show_frames",
                             "-show_entries", "frame=pts,nb_samples")["frames"]
        audio_samples = 0
        timestamp_tolerance = audio_clock / 2 if extension == "mkv" else 0
        for frame in audio_frames:
            self.assertLessEqual(abs(int(frame["pts"]) * audio_clock - Fraction(audio_samples, audio_rate)),
                                 timestamp_tolerance, (output.name, frame))
            audio_samples += int(frame["nb_samples"])
        self.assertEqual(audio_samples, len(expected_pcm) // 8)
        if extension != "mkv":
            self.assertEqual(int(sound["duration_ts"]) * audio_clock, Fraction(audio_samples, audio_rate))

        written = boundaries
        if extension == "mkv":
            written = [Fraction(math.floor(t * 1000 + Fraction(1, 2)), 1000) for t in boundaries[:-1]]
            written.append(Fraction(math.ceil(boundaries[-1] * 1000), 1000))
        for result in (dry_run, report):
            self.assertEqual(ratio(result["written_picture_duration"]), written[-1])
        expected_timing = [(start, end - start) for start, end in zip(written, written[1:])]
        packets = probe(output, "-select_streams", "v:0", "-show_packets")["packets"]
        clock = Fraction(video["time_base"])
        self.assertEqual(len(packets), expected_count, output.name)
        for packet, (start, duration) in zip(packets, expected_timing):
            self.assertEqual(int(packet["pts"]) * clock, start, packet)
            if "dts" in packet:
                self.assertEqual(int(packet["dts"]) * clock, start, packet)
            self.assertIn("K", packet["flags"])
            if extension != "mkv":
                self.assertEqual(int(packet["duration"]) * clock, duration, packet)
        if extension == "mkv":
            self.assertEqual(clock, Fraction(1, 1000))
            self.assertEqual(matroska_blocks(output), expected_timing)

        raw = ffmpeg("-i", output, "-map", "0:a:0", "-c:a", f"pcm_{pcm_format}", "-f", pcm_format, "-")
        self.assertEqual(len(raw), len(expected_pcm))
        self.assertTrue(raw == expected_pcm, f"Decoded samples differ for {output.name}")
        pixels = ffmpeg("-skip_frame", "nokey", "-i", output, "-map", "0:v:0",
                        "-vf", "crop=2:2:160:90,format=gray", "-fps_mode", "passthrough", "-f", "rawvideo", "-")
        self.assertEqual(len(pixels), expected_count * 4)
        self.assertTrue(all(value > 64 for value in pixels[:4]), (output.name, list(pixels[:4])))
        self.assertTrue(all(value < 32 for value in pixels[4:]), (output.name, list(pixels[4:])))
        if extension == "mkv":
            for start, finish in reversed(list(zip(written, written[1:]))):
                # Seek to the interior of each hold so the reader must rewind to its cue.
                midpoint = (start + finish) / 2
                packets_at_seek = probe(output, "-read_intervals", f"{float(midpoint):.6f}%+#16",
                                        "-select_streams", "v:0", "-show_packets").get("packets", [])
                self.assertTrue(packets_at_seek, f"No picture after seek to {midpoint}")
                self.assertEqual(int(packets_at_seek[0]["pts"]) * clock, start)

        if add_playback:
            seeks = []
            for index, (start, finish) in enumerate(zip(written, written[1:])):
                values = (start, finish - min(Fraction(1, 120), (finish - start) / 2))
                seeks += [dict(rational(time), bright=index == 0, frame=rational(start)) for time in values]
            seeks.append(dict(rational(written[1] / 2), bright=True, frame=rational(written[0])))
            self.manifest.append({"file": str(output), "end": rational(written[-1]), "seeks": seeks})
        payload = sum(int(packet["size"]) for packet in packets)
        self.results.append({"file": str(output), "mode": mode, "container": extension, "picture": codec,
                             "color": color, "audio": audio, "video_samples": expected_count,
                             "video_payload_bytes": payload, "file_bytes": output.stat().st_size,
                             "audio_samples": len(expected_pcm) // 8, "audio_rate": audio_rate})
        print(f"verified {output.name}", flush=True)
        return payload

    def test_matrix(self):
        matched = 0
        fixtures = [
            ("cover", 48000, 480000, [Fraction(0), Fraction(10)]),
            ("slides", 44100, 132300, [Fraction(0), Fraction(31, 24), Fraction(3)]),
            ("off-grid", 48000, 48001, [Fraction(0), Fraction(48001, 48000)]),
        ]
        for fixture, rate, count, boundaries in fixtures:
            path = self.root / f"{fixture}.wav"
            pcm = pcm_fixture(path, rate, count)
            for extension, codec, colors, sound_codecs in MATRIX:
                for color, audio, mode in product(colors, sound_codecs, ("smart", "encode")):
                    key = f"{extension}-{codec}-{color}-{audio}-{mode}-{fixture}"
                    if ARGS.match not in key:
                        continue
                    matched += 1
                    with self.subTest(export=key):
                        project = self.root / f"{key}.cut"
                        output = self.root / f"{key}.{extension}"
                        if fixture == "slides":
                            self.author(project, path, codec, color, first=boundaries[1],
                                        last=boundaries[2] - boundaries[1])
                        else:
                            self.author(project, path, codec, color)
                        self.verify(project, output, codec=codec, color=color, audio=audio, mode=mode,
                                    boundaries=boundaries, expected_pcm=pcm, audio_rate=rate)
        self.assertGreater(matched, 0, f"No matrix rows match {ARGS.match!r}")

    def test_five_minute_cover(self):
        rate = 48000
        payloads = []
        for duration in (10, 300):
            key = f"length-{duration}"
            name = self.root / key
            pcm = pcm_fixture(name.with_suffix(".wav"), rate, duration * rate)
            project = name.with_suffix(".cut")
            self.author(project, name.with_suffix(".wav"), "h264", "sdr")
            output = name.with_suffix(".mov")
            payloads.append(self.verify(project, output, codec="h264", color="sdr", audio="alac", mode="smart",
                                        boundaries=[Fraction(0), Fraction(duration)], expected_pcm=pcm, audio_rate=rate))
            self.assertLess(output.stat().st_size, len(pcm) * 3 // 4 + 100_000)
        self.assertEqual(*payloads)

    def test_pcm_precision_and_source_edit(self):
        if ARGS.match:
            self.skipTest("matrix filter active")
        rate = 48000
        integer = self.root / "int32.wav"
        pcm = pcm_fixture(integer, rate, rate * 2, bits=32)
        floating = self.root / "float32.mov"
        ffmpeg("-y", "-i", integer, "-c:a", "pcm_f32le", floating)
        for path, precision, decoded in [
            (integer, "s32le", pcm),
            (floating, "f32le", ffmpeg("-i", floating, "-c:a", "pcm_f32le", "-f", "f32le", "-")),
        ]:
            with self.subTest(source=precision):
                project = self.root / f"{precision}.cut"
                first, last = 101, 48102
                self.author(project, path, "h264", "sdr",
                            source_range=(Fraction(first, rate), Fraction(last, rate)))
                duration = Fraction(last - first, rate)
                self.verify(project, self.root / f"{precision}-pcm.mov", codec="h264", color="sdr",
                            audio="pcm", mode="smart", boundaries=[Fraction(0), duration],
                            expected_pcm=decoded[first * 8:last * 8], audio_rate=rate, pcm_format=precision)
                for audio, extension in [("alac", "mov"), ("flac", "mkv")]:
                    output = self.root / f"{precision}-{audio}.{extension}"
                    message = self.cli("export", "project", "render", "--project", project, "--output", output,
                                       "--mode", "smart", "--audio", audio, "--dry-run", error="pcm")
                    self.assertEqual(message["error"]["code"], "unsupported_audio")
                    self.assertTrue(any(option["audio"] == "pcm" for option in message["error"]["alternatives"]))
                    self.assertFalse(output.exists())

    def test_lossless_wav_range_after_nonzero_seek(self):
        if ARGS.match:
            self.skipTest("matrix filter active")
        rate = 44_100
        source = self.root / "seek-audio.wav"
        pcm = pcm_fixture(source, rate, 5 * rate + 3)
        first, last = 2 * rate + 13, 4 * rate + 31
        project = source.with_suffix(".cut")
        self.author(project, source, "h264", "sdr",
                    source_range=(Fraction(first, rate), Fraction(last, rate)))
        for extension, sound in [("mov", "alac"), ("mp4", "alac"), ("m4v", "flac"), ("mkv", "flac")]:
            with self.subTest(extension=extension):
                self.verify(project, source.with_suffix(f".{extension}"), codec="h264", color="sdr",
                            audio=sound, mode="smart", boundaries=[Fraction(0), Fraction(last - first, rate)],
                            expected_pcm=pcm[first * 8:last * 8], audio_rate=rate)

    def test_sub_block_flac_soundtrack_range(self):
        if ARGS.match:
            self.skipTest("matrix filter active")
        rate = 44_100
        source = self.root / "flac-trim-source.wav"
        pcm = pcm_fixture(source, rate, 10_000)
        for first, last in [(115, 117), (4094, 9117)]:
            with self.subTest(first=first, last=last):
                project = self.root / f"flac-trim-{first}.cut"
                self.author(project, source, "h264", "sdr",
                            source_range=(Fraction(first, rate), Fraction(last, rate)))
                self.verify(project, project.with_suffix(".mkv"), codec="h264", color="sdr",
                            audio="flac", mode="smart", boundaries=[Fraction(0), Fraction(last - first, rate)],
                            expected_pcm=pcm[first * 8:last * 8], audio_rate=rate, use_defaults=True)

    def test_multitrack_native_precision(self):
        if ARGS.match:
            self.skipTest("matrix filter active")
        channels = [(24, 44100), (32, 48000)]
        sources = []
        for bits, rate in channels:
            path = self.root / f"microphone-{bits}.wav"
            sources.append((path, pcm_fixture(path, rate, rate * 4, bits=bits)))
        source = self.root / "multitrack.mov"
        ffmpeg("-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=4",
               "-i", sources[0][0], "-i", sources[1][0], "-map", "0:v", "-map", "1:a", "-map", "2:a",
               "-c:v", "libx264", "-g", "24", "-bf", "0", "-color_range", "tv", "-color_trc", "bt709",
               "-color_primaries", "bt709", "-colorspace", "bt709", "-c:a", "copy", source)
        sequence = self.root / "multitrack.cut"
        sequence.write_text(json.dumps({
            "format": "mpcut", "schema_version": 9, "kind": "sequence",
            "clips": [{"id": "multitrack", "file": str(source), "from": "1", "to": "3"}],
        }))
        project = self.root / "multitrack-covered.cut"
        self.cli("still", "picture", "replace", "--project", sequence, "--image", self.white,
                 "--clock", "sequence", "--from", "0", "--to", "2", "--out-project", project)
        output = self.root / "multitrack-covered.mov"
        report = self.cli("export", "project", "render", "--project", project, "--output", output,
                          "--mode", "encode", "--video", "h264", "--audio", "pcm", "--still-timing", "held")
        self.assertEqual(report["generated_video_sample_count"], 1)
        self.assertEqual(ratio(report["generated_still_duration"]), Fraction(2))
        streams = probe(output, "-select_streams", "a", "-show_streams")["streams"]
        self.assertEqual(len(streams), len(channels))
        for ordinal, ((bits, rate), (_, expected)) in enumerate(zip(channels, sources)):
            self.assertEqual(streams[ordinal]["codec_name"], f"pcm_s{bits}le")
            self.assertEqual(int(streams[ordinal]["sample_rate"]), rate)
            raw = ffmpeg("-i", output, "-map", f"0:a:{ordinal}", "-c:a", "pcm_s32le", "-f", "s32le", "-")
            self.assertTrue(raw == expected[rate * 8:rate * 3 * 8], f"Track {ordinal} differs after final mux")

    def test_held_mkv_reencode_rounds_off_tick_camera_joins(self):
        if ARGS.match:
            self.skipTest("matrix filter active")
        camera = self.root / "off-tick-camera.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x180:r=24", "-frames:v", "71",
               "-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "high", "-bf", "0",
               "-color_range", "tv", "-color_trc", "bt709", "-color_primaries", "bt709",
               "-colorspace", "bt709", camera)
        source = camera.with_suffix(".cut")
        source.write_text(json.dumps({
            "format": "mpcut", "schema_version": 9, "kind": "sequence",
            "clips": [{"id": "camera", "file": str(camera), "from": "0", "to": "71/24"}],
        }))
        project = self.root / "off-tick-held.cut"
        self.cli("still", "picture", "replace", "--project", source, "--image", self.white,
                 "--clock", "sequence", "--from", "25/24", "--to", "49/24", "--out-project", project)
        output = project.with_suffix(".mkv")
        base = ["export", "project", "render", "--project", project, "--output", output,
                "--tracks", "video", "--still-timing", "held"]
        failure = self.cli(*base, "--mode", "smart", "--require-camera-copy", "--dry-run",
                           error="unsupported_still_timing")
        self.assertEqual(failure["error"]["code"], "unsupported_still_timing")
        self.assertFalse(output.exists())
        report = self.cli(*base, "--mode", "encode", "--video", "h264")
        self.assertEqual(report["generated_video_sample_count"], 1)
        self.assertEqual(ratio(report["written_picture_duration"]), Fraction(2959, 1000))
        before, generated, after = report["picture"]
        self.assertEqual(before["written_output"], {"from": "0", "to": "521/500"})
        self.assertEqual(generated["written_output"], {"from": "521/500", "to": "1021/500"})
        self.assertEqual(after["written_output"], {"from": "1021/500", "to": "2959/1000"})
        frames = [*range(25), 25, *range(49, 71)]
        boundaries = [(index * 1000 + 12) // 24 for index in frames] + [2959]
        self.assertEqual(matroska_blocks(output, all_independent=False),
                         [(Fraction(a, 1000), Fraction(b - a, 1000)) for a, b in zip(boundaries, boundaries[1:])])
        packets = probe(output, "-select_streams", "v:0", "-show_packets")["packets"]
        self.assertIn("K", packets[25]["flags"])

    def test_source_backed_picture_return_and_audio_edit(self):
        if ARGS.match:
            self.skipTest("matrix filter active")
        rate = 48000
        wav = self.root / "camera-audio.wav"
        pcm = pcm_fixture(wav, rate, 4 * rate)
        camera = self.root / "camera.mov"
        ffmpeg("-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=4", "-i", wav,
               "-c:v", "libx264", "-profile:v", "high", "-g", "24", "-sc_threshold", "0", "-bf", "0",
               "-color_range", "tv", "-color_trc", "bt709", "-color_primaries", "bt709",
               "-colorspace", "bt709", "-c:a", "copy", camera)
        source = self.root / "camera.cut"
        source.write_text(json.dumps({
            "format": "mpcut", "schema_version": 9, "kind": "sequence",
            "clips": [{"id": "first", "file": str(camera), "from": "0", "to": "2"},
                      {"id": "second", "file": str(camera), "from": "1", "to": "3"}],
        }))
        project = self.root / "camera-replaced.cut"
        self.cli("still", "picture", "replace", "--project", source, "--image", self.white,
                 "--clock", "sequence", "--from", "1", "--to", "3", "--out-project", project)
        reference = self.root / "camera-reference.mov"
        self.cli("export", "project", "render", "--project", source, "--output", reference, "--mode", "copy")
        for mode in ("smart", "encode"):
            with self.subTest(mode=mode):
                output = self.root / f"camera-held-{mode}.mov"
                arguments = ["--require-camera-copy"] if mode == "smart" else ["--video", "h264"]
                report = self.cli("export", "project", "render", "--project", project, "--output", output,
                                  "--mode", mode, "--audio", "copy", "--still-timing", "held", *arguments)
                self.assertEqual(report["generated_video_sample_count"], 1)
                self.assertEqual(ratio(report["generated_still_duration"]), Fraction(2))
                generated = [action for action in report["picture"] if action["action"] == "generate_still"]
                self.assertEqual(len(generated), 1)
                self.assertEqual(generated[0]["source_occurrences"], ["first", "second"])
                timing = probe(output, "-select_streams", "v:0", "-show_streams", "-show_packets")
                clock = Fraction(timing["streams"][0]["time_base"])
                held = [packet for packet in timing["packets"] if 1 <= int(packet["pts"]) * clock < 3]
                self.assertEqual(len(held), 1)
                self.assertEqual(int(held[0]["pts"]) * clock, Fraction(1))
                self.assertEqual(int(held[0]["duration"]) * clock, Fraction(2))
                self.assertIn("K", held[0]["flags"])
                raw = ffmpeg("-i", output, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "s32le", "-")
                self.assertTrue(raw == pcm[:2 * rate * 8] + pcm[rate * 8:3 * rate * 8])
                if mode == "smart":
                    self.assertEqual(ratio(report["copied_camera_duration"]), Fraction(2))
                    expected = {time: digest for time, digest in timestamped_hashes(reference)
                                if time < 1 or time >= 3}
                    observed = dict(timestamped_hashes(output))
                    self.assertEqual({time: observed[time] for time in expected}, expected)
                    self.assertEqual(report["sound_actions"][0]["audio"], "copy")
                    self.assertEqual(report["sound_actions"][0]["generated_silence"], [])

        compressed = self.root / "camera-aac.mp4"
        ffmpeg("-i", camera, "-map", "0:v", "-map", "0:a", "-c:v", "copy", "-c:a", "aac", compressed)
        compressed_source = self.root / "camera-aac.cut"
        compressed_source.write_text(json.dumps({
            "format": "mpcut", "schema_version": 9, "kind": "sequence",
            "clips": [{"id": "camera-aac", "file": str(compressed), "from": "0", "to": "4"}],
        }))
        compressed_edit = self.root / "camera-aac-covered.cut"
        self.cli("still", "picture", "replace", "--project", compressed_source, "--image", self.white,
                 "--clock", "sequence", "--from", "1", "--to", "3", "--out-project", compressed_edit)
        baseline = self.root / "camera-aac-reference.mp4"
        self.cli("export", "project", "render", "--project", compressed_source, "--output", baseline, "--mode", "copy")
        covered = self.root / "camera-aac-covered.mp4"
        report = self.cli("export", "project", "render", "--project", compressed_edit, "--output", covered,
                          "--mode", "smart", "--audio", "copy", "--still-timing", "held", "--require-camera-copy")
        self.assertEqual(report["generated_video_sample_count"], 1)
        self.assertEqual(sample_hashes(covered, "a:0"), sample_hashes(baseline, "a:0"))

    def test_resized_soundtrack_uses_default_delivery(self):
        if ARGS.match:
            self.skipTest("matrix filter active")
        rate = 48000
        count = rate + 1
        soundtrack = self.root / "resize.wav"
        pcm = pcm_fixture(soundtrack, rate, count)
        baseline = self.root / "resize.cut"
        creation = self.author(baseline, soundtrack, "h264", "sdr")
        for duration_samples in (36001, 60001):
            duration = Fraction(duration_samples, rate)
            project = self.root / f"resized-{duration_samples}.cut"
            self.cli("still", "placement", "update", "--project", baseline,
                     "--placement", creation["placement_id"], "--duration", str(duration), "--out-project", project)
            expected = pcm[:duration_samples * 8] + bytes(max(0, duration_samples - count) * 8)
            snapshot = project.read_bytes()
            for extension in ("mov", "mp4", "m4v", "mkv"):
                with self.subTest(samples=duration_samples, extension=extension):
                    output = project.with_suffix(f".{extension}")
                    self.verify(project, output, codec="h264", color="sdr", audio="flac" if extension == "mkv" else "alac",
                                mode="smart", boundaries=[Fraction(0), duration], expected_pcm=expected, audio_rate=rate,
                                use_defaults=True)
                    self.assertEqual(project.read_bytes(), snapshot)

    def test_float_soundtrack_defaults_to_pcm_in_mov(self):
        if ARGS.match:
            self.skipTest("matrix filter active")
        rate = 48000
        count = rate + 1
        original = self.root / "float-reference.wav"
        pcm_fixture(original, rate, count, bits=32)
        floating = self.root / "float-source.mov"
        ffmpeg("-i", original, "-c:a", "pcm_f32le", floating)
        expected = ffmpeg("-i", floating, "-c:a", "pcm_f32le", "-f", "f32le", "-")
        project = self.root / "float-default.cut"
        self.author(project, floating, "h264", "sdr")
        self.verify(project, project.with_suffix(".mov"), codec="h264", color="sdr", audio="pcm", mode="smart",
                    boundaries=[Fraction(0), Fraction(count, rate)], expected_pcm=expected, audio_rate=rate,
                    pcm_format="f32le", use_defaults=True)

    def test_saved_project_extensions_and_defaults(self):
        if ARGS.match:
            self.skipTest("matrix filter active")
        soundtrack = self.root / "defaults.wav"
        pcm = pcm_fixture(soundtrack, 48000, 48000)
        project = self.root / "defaults.cut"
        self.author(project, soundtrack, "h264", "sdr")
        snapshot = project.read_bytes()
        for extension, audio in [("mov", "pcm"), ("mp4", "alac"), ("m4v", "flac"), ("mkv", "flac")]:
            self.verify(project, self.root / f"defaults.{extension}", codec="h264", color="sdr",
                        audio=audio, mode="smart", boundaries=[Fraction(0), Fraction(1)],
                        expected_pcm=pcm, audio_rate=48000)
            self.assertEqual(project.read_bytes(), snapshot)
        output = self.root / "unmodified-defaults.mov"
        report = self.cli("export", "project", "render", "--project", project, "--output", output)
        self.assertEqual(report["picture_timing"], "held")
        self.assertEqual(report["container"], "mov")
        self.assertEqual(report["video_codec"], "h264")
        self.assertEqual(report["sound_actions"][0]["audio"], "alac")

    def test_off_grid_44100(self):
        if ARGS.match:
            self.skipTest("matrix filter active")
        rate = 44100
        soundtrack = self.root / "fractional-44100.wav"
        pcm = pcm_fixture(soundtrack, rate, rate + 1)
        project = self.root / "fractional-44100.cut"
        self.author(project, soundtrack, "h264", "sdr")
        for extension, audio in [("mov", "alac"), ("mkv", "flac")]:
            self.verify(project, project.with_suffix("." + extension), codec="h264", color="sdr", audio=audio,
                        mode="smart", boundaries=[Fraction(0), Fraction(rate + 1, rate)],
                        expected_pcm=pcm, audio_rate=rate)

    def test_matroska_exact_tick(self):
        if ARGS.match:
            self.skipTest("matrix filter active")
        soundtrack = self.root / "tick.wav"
        pcm = pcm_fixture(soundtrack, 48000, 48000)
        project = self.root / "tick.cut"
        self.author(project, soundtrack, "h264", "sdr")
        self.verify(project, project.with_suffix(".mkv"), codec="h264", color="sdr", audio="flac",
                    mode="smart", boundaries=[Fraction(0), Fraction(1)], expected_pcm=pcm, audio_rate=48000)


    def test_mixed_smart_matroska_decoder_configuration(self):
        if ARGS.match:
            self.skipTest("matrix filter active")

        def frame_digests(path, input_options=(), packet_filter=None):
            output_options = ["-fps_mode", "passthrough"] if packet_filter is None else [
                "-c:v", "copy", "-bsf:v", packet_filter]
            output = ffmpeg("-xerror", *input_options, "-i", path, "-map", "0:v:0",
                            *output_options, "-f", "framehash", "-")
            return [line.rsplit(b",", 1)[1].strip() for line in output.splitlines()
                    if line and not line.startswith(b"#")]

        encoders = {
            "h264": ["-c:v", "libx264", "-g", "25", "-sc_threshold", "0"],
            "hevc": ["-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-profile:v", "main10", "-tag:v", "hvc1",
                     "-x265-params", "log-level=error:pools=1:keyint=25:min-keyint=25:scenecut=0:open-gop=0:"
                     "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"],
        }
        for codec, options in encoders.items():
            with self.subTest(codec=codec):
                camera = self.root / f"mixed-camera-{codec}.mov"
                primaries, transfer, matrix = ("bt2020", "smpte2084", "bt2020nc") if codec == "hevc" else (
                    "bt709", "bt709", "bt709")
                color = f"setparams=range=tv:color_primaries={primaries}:color_trc={transfer}:colorspace={matrix}"
                ffmpeg("-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=4", "-vf", color, *options, "-bf", "0",
                       "-color_range", "tv", "-color_trc", transfer, "-color_primaries", primaries,
                       "-colorspace", matrix, "-movflags", "+write_colr", camera)
                source = camera.with_suffix(".cut")
                source.write_text(json.dumps({
                    "format": "mpcut", "schema_version": 9, "kind": "sequence",
                    "clips": [{"id": "camera", "file": str(camera), "from": "0", "to": "4"}],
                }))
                project = self.root / f"mixed-held-{codec}.cut"
                self.cli("still", "picture", "replace", "--project", source, "--image", self.white,
                         "--clock", "sequence", "--from", "1", "--to", "3",
                         "--color", "pq" if codec == "hevc" else "sdr", "--out-project", project)
                output = project.with_suffix(".mkv")
                report = self.cli("export", "project", "render", "--project", project, "--output", output,
                                  "--tracks", "video", "--mode", "smart", "--require-camera-copy",
                                  "--still-timing", "held")
                self.assertEqual(ratio(report["copied_camera_duration"]), 2)
                self.assertEqual(report["generated_video_sample_count"], 1)
                table = probe(output, "-select_streams", "v:0", "-show_streams", "-show_packets")
                self.assertEqual(Fraction(table["streams"][0]["time_base"]), Fraction(1, 1000))
                self.assertEqual(len(table["packets"]), 51)
                held = table["packets"][25]
                self.assertEqual((int(held["pts"]), int(held["duration"])), (1_000, 2_000))
                self.assertIn("K", held["flags"])

                original = frame_digests(camera)
                linear = frame_digests(output)
                self.assertEqual(len(linear), 51)
                self.assertEqual(linear[:25], original[:25])
                self.assertEqual(linear[26:], original[75:])
                self.assertNotIn(linear[25], original)
                self.assertEqual(frame_digests(output, ("-ss", "1.5", "-noaccurate_seek")), linear[25:])
                self.assertEqual(frame_digests(output, ("-ss", "3")), linear[26:])
                video_coding_layer = "1-5" if codec == "h264" else "0-31"
                packet_filter = f"filter_units=pass_types={video_coding_layer}"
                source_packets = frame_digests(camera, packet_filter=packet_filter)
                output_packets = frame_digests(output, packet_filter=packet_filter)
                self.assertEqual(output_packets[:25], source_packets[:25])
                self.assertEqual(output_packets[26:], source_packets[75:])

    def test_conflicting_container_and_strict_copy(self):
        soundtrack = self.root / "refusal.wav"
        pcm_fixture(soundtrack, 48000, 48000)
        project = self.root / "refusal.cut"
        self.author(project, soundtrack, "h264", "sdr")
        output = self.root / "refused.mov"
        command = ["export", "project", "render", "--project", project, "--output", output, "--dry-run"]
        self.cli(*command, "--container", "mp4", error="container")
        self.cli(*command, "--mode", "copy", error="still")
        self.assertFalse(output.exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--work-directory", type=Path,
                        default=Path(tempfile.gettempdir()) / f"mpcut-held-{uuid.uuid4()}")
    parser.add_argument("--match", default="", help="run only matrix rows whose name contains this string")
    parser.add_argument("tests", nargs="*", help="optional unittest method names")
    ARGS = parser.parse_intermixed_args()
    unittest.main(argv=[__file__, *ARGS.tests], verbosity=2)
