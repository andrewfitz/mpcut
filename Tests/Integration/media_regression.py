#!/usr/bin/env python3
"""Run against an absolute or relative path to a built mpcut executable."""
import argparse
from fractions import Fraction
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time
import unittest

FRAME = Fraction(1001, 30000)
RATE = 48000
CLI = None


def run(command, *, allow_diagnostics=False, **kwargs):
    result = subprocess.run(command, capture_output=True, timeout=60, **kwargs)
    if result.returncode or (result.stderr and not allow_diagnostics):
        raise AssertionError(
            f"{command} exited {result.returncode}: {result.stderr.decode()}"
        )
    return result.stdout


def ffmpeg(*args, **kwargs):
    return run(["ffmpeg", "-hide_banner", "-v", "error", "-nostdin", *args], **kwargs)


def probe(path, *args):
    return json.loads(run(["ffprobe", "-v", "error", "-of", "json", *args, path]))


def packets(path, track="v:0", demux_options=()):
    report = probe(path, *demux_options, "-select_streams", track, "-show_packets",
                   "-show_entries", "packet=pts,dts,data_hash,flags", "-show_data_hash", "sha256")
    return report["packets"]


def frames(path, seek=None):
    read_options = [] if seek is None else ["-ss", str(seek)]
    output = ffmpeg(*read_options, "-noautorotate", "-i", path, "-map", "0:v:0", "-an",
                    "-fps_mode", "passthrough", "-f", "framehash", "-")
    return [line.split(b",", 6)[5].strip() for line in output.splitlines()
            if line and not line.startswith(b"#")]


def audio(path):
    return ffmpeg("-i", path, "-map", "0:a:0", "-vn", "-c:a", "pcm_s16le", "-f", "s16le", "-")


def sample_hashes(path, track="v:0", demux_options=()):
    return [packet["data_hash"] for packet in packets(path, track, demux_options)]


def timestamped_hashes(path):
    # Copy order stays in decode order, even where presentation order differs.
    stream = probe(path, "-select_streams", "v:0", "-show_streams")["streams"][0]
    scale = Fraction(stream["time_base"])
    origin = int(stream.get("start_pts", 0))
    return [((int(packet["pts"]) - origin) * scale, packet["data_hash"])
            for packet in packets(path)]


def ratio(value):
    return Fraction(value["numerator"], value["denominator"])


class MediaRegression(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-regression-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def cli(self, *args, request=None, ok=True, env=None):
        result = subprocess.run([CLI, *args], input=None if request is None else json.dumps(request),
                                capture_output=True, text=True, timeout=60, cwd=self.root, env=env)
        self.assertEqual(result.returncode == 0, ok, result.stderr + result.stdout)
        report = json.loads(result.stdout)
        self.assertIsInstance(report, dict)
        self.assertIs(report.get("ok"), ok, report)
        if not ok:
            self.assertIsInstance(report["error"]["code"], str)
        return report

    def export(self, output, clips, *, dry_run=False, ok=True, snap=False):
        args = ["export", "--json", "--stdin"]
        if dry_run:
            args.append("--dry-run")
        if snap:
            args += ["--snap", "nearest"]
        # This suite checks the packet copy. The CLI default is Smart Trim, so the mode is named.
        return self.cli(*args, request={"output": str(output), "clips": clips, "mode": "copy"}, ok=ok)

    def native_audio_decoder(self):
        decoder = self.root / "decode-audio"
        run(["swiftc", "-parse-as-library", Path(__file__).with_name("DecodeAudio.swift"),
             "-o", decoder], allow_diagnostics=True)
        return lambda path: run([decoder, path])

    def fixture(self, name, video, *, audio_encoder=None, hue=0, width=160,
                alpha=False, rate="30000/1001", frame_count=90, sample_rate=RATE,
                audio_encoder_options=()):
        path = self.root / name
        video_filter = f"testsrc2=s={width}x96:r={rate},hue=h={hue}"
        if alpha:
            video_filter += ",format=yuva444p10le,colorchannelmixer=aa=0.5"
        duration = float(frame_count / Fraction(rate))
        audio_input = []
        if audio_encoder:
            # The periodic marker straddles each frame at the source sample clock.
            period = Fraction(sample_rate, 1) / Fraction(rate)
            expression = (f"if(lt(mod(n+8,{float(period)}),16),"
                          f"0.6*sin(2*PI*{997 + hue}*t),0)")
            audio_input = ["-f", "lavfi", "-i", f"aevalsrc='{expression}':s={sample_rate}"]
        color = ["-color_range", "tv", "-colorspace", "bt709",
                 "-color_trc", "bt709", "-color_primaries", "bt709"]
        audio_options = ["-strict", "experimental", "-ac", "2"] if audio_encoder == "vorbis" else []
        ffmpeg("-f", "lavfi", "-i", video_filter,
               *audio_input, "-t", f"{duration:.9f}", "-frames:v", str(frame_count),
               *video, *color,
               *(["-c:a", audio_encoder, "-af", f"atrim=end_sample={round(duration * sample_rate)}"]
                 if audio_encoder else []), *audio_options, *audio_encoder_options, path, allow_diagnostics=True)
        return path

    def prores(self, name, *, hue=0, **kwargs):
        return self.fixture(name, ["-c:v", "prores_ks", "-profile:v", "3",
                                   "-pix_fmt", "yuv422p10le"], hue=hue,
                            audio_encoder="pcm_s16le", **kwargs)

    def h264(self, name, *, open_gop=False, **kwargs):
        return self.fixture(name, ["-pix_fmt", "yuv420p", "-c:v", "libx264", "-threads", "1",
                                   "-x264-params", f"keyint=15:min-keyint=15:scenecut=0:"
                                   f"open-gop={int(open_gop)}:bframes=3"], **kwargs)

    @staticmethod
    def edit(file, start=None, stop=None):
        edit = {"file": file.name}
        if start is not None:
            edit["from"] = str(start)
        if stop is not None:
            edit["to"] = str(stop)
        return edit

    def assert_assembly(self, output, ranges, frame_duration=FRAME):
        files = {file for file, _, _ in ranges}
        original_frames = {file: frames(file) for file in files}
        packet_tables = {file: timestamped_hashes(file) for file in files}
        original_hashes = []
        expected = []
        for file, start, end in ranges:
            expected.extend(original_frames[file][start:end])
            original_hashes.extend(
                payload for pts, payload in packet_tables[file]
                if start * frame_duration <= pts < end * frame_duration
            )
        self.assertEqual(frames(output), expected, "decoded pictures differ around an edit")
        self.assertEqual(sample_hashes(output), original_hashes, "compressed video changed")
        timestamps = sorted(pts for pts, _ in timestamped_hashes(output))
        self.assertEqual(timestamps, [index * frame_duration for index in range(len(expected))])

    def test_mov_timecode_follows_first_retained_frame(self):
        original = self.prores("original.mov")
        source = self.root / "timecoded.mov"
        ffmpeg("-i", original, "-map", "0:v", "-map", "0:a", "-c", "copy",
               "-timecode", "00:00:59;29", source)

        ranges = [(source, 2, 15), (source, 0, 2)]
        edits = [self.edit(file, start * FRAME, end * FRAME) for file, start, end in ranges]
        output = self.root / "timecoded-edit.mov"
        self.export(output, edits)
        self.assert_assembly(output, ranges)

        streams = probe(output, "-show_streams")["streams"]
        timecode = [stream for stream in streams if stream["codec_tag_string"] == "tmcd"]
        self.assertEqual(len(timecode), 1)
        self.assertEqual(timecode[0]["tags"]["timecode"], "00:01:00;03")
        self.assertEqual(streams[0]["tags"]["timecode"], "00:01:00;03")
        self.assertEqual(int(timecode[0]["duration_ts"]) * Fraction(timecode[0]["time_base"]), 15 * FRAME)

        rejected = self.root / "timecoded-edit.mkv"
        result = self.export(rejected, edits, dry_run=True, ok=False)
        self.assertIn("timecode", result["error"]["message"])
        self.assertFalse(rejected.exists())

    def test_dry_run_checks_timecode_value_and_destination_packet_clock(self):
        original = self.prores("original.mov")
        timecoded = self.root / "timecoded.mov"
        ffmpeg("-i", original, "-map", "0:v", "-c", "copy", "-timecode", "01:00:00;00", timecoded)
        packet = probe(timecoded, "-select_streams", "d:0", "-show_packets", "-show_entries",
                       "packet=pos,size")["packets"][0]
        self.assertEqual(int(packet["size"]), 4)
        # A camera timecode count outside the writer's representable range.
        with timecoded.open("r+b") as movie:
            movie.seek(int(packet["pos"]))
            movie.write((2**31 - 1).to_bytes(4, "big"))
        output = self.root / "invalid-timecode.mov"
        report = self.export(output, [self.edit(timecoded)], dry_run=True, ok=False)
        self.assertEqual(report["error"]["code"], "unsupported_timecode")
        self.assertEqual(report["error"]["segment"], 1)
        self.assertFalse(output.exists())

        fast = self.fixture("submillisecond.mov", ["-c:v", "prores_ks", "-profile:v", "3",
                                                   "-pix_fmt", "yuv422p10le"], rate="2000", frame_count=8)
        output = self.root / "unrepresentable.mkv"
        report = self.export(output, [self.edit(fast)], dry_run=True, ok=False)
        self.assertEqual(report["error"]["code"], "unsupported_container")
        self.assertIn("output clock", report["error"]["message"])
        self.assertFalse(output.exists())

    def test_aac_coverage_error_suggests_verified_end_and_snaps(self):
        source = self.root / "short-audio.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=64x64:r=25:d=2",
               "-f", "lavfi", "-i", "sine=f=400:r=48000:d=1.05",
               "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-c:a", "aac", source)
        output = self.root / "trimmed.mov"
        report = self.export(output, [self.edit(source, "2/5")], dry_run=True, ok=False)
        self.assertEqual(report["error"]["boundary"], "to")
        choices = list(map(ratio, report["error"]["nearest"]))
        self.assertEqual(choices, [Fraction(26, 25)])
        exact = self.export(output, [self.edit(source, "2/5", str(choices[0]))])
        snapped = self.export(self.root / "snapped.mov", [self.edit(source, "2/5")], snap=True)
        self.assertEqual(exact["segments"], snapped["segments"])
        self.assertEqual(sample_hashes(output), sample_hashes(self.root / "snapped.mov"))

    def test_unsafe_start_suggests_starts_when_the_end_is_also_unsafe(self):
        source = self.root / "gop.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=64x64:r=30:d=6", "-c:v", "libx264", "-g", "60",
               "-pix_fmt", "yuv420p", source)
        output = self.root / "both-unsafe.mp4"
        report = self.export(output, [self.edit(source, "1/2", "21/20")], dry_run=True, ok=False)
        self.assertEqual(report["error"]["boundary"], "from")
        self.assertEqual(list(map(ratio, report["error"]["nearest"])), [0])
        fixed = self.export(output, [self.edit(source, "0", "21/20")], dry_run=True, ok=False)
        self.assertEqual(fixed["error"]["boundary"], "to")
        self.assertEqual(list(map(ratio, fixed["error"]["nearest"])), [2])
        later = self.export(output, [self.edit(source, "0", "21/20"), self.edit(source, "4", "21/4")],
                            dry_run=True, ok=False)
        self.assertEqual((later["error"]["segment"], later["error"]["boundary"]), (1, "to"))
        self.assertEqual(list(map(ratio, later["error"]["nearest"])), [2])

    def test_prores_reorder_repeated_ranges_and_pcm(self):
        a, b, c = [self.prores(f"{label}.mov", hue=hue, sample_rate=44100)
                   for label, hue in zip("abc", [0, 42, 94])]
        ranges = [(c, 0, 90), (a, 3, 33), (b, 0, 17), (b, 32, 90)]
        ranges += [(a, frame, frame + 1) for frame in range(3, 30)]
        output = self.root / "assembly.mov"
        edits = [self.edit(file, start * FRAME, end * FRAME)
                 for file, start, end in ranges]
        dry_run = self.export(output, edits, dry_run=True)
        duration = sum(end - start for _, start, end in ranges) * FRAME
        self.assertEqual(ratio(dry_run["duration"]), duration)
        for segment in dry_run["segments"]:
            self.assertEqual({track["kind"] for track in segment["tracks"]}, {"video", "audio"})
        self.assertFalse(output.exists())
        self.export(output, edits)
        self.assert_assembly(output, ranges)

        rate = 44100
        decoded = audio(output)
        total = sum(end - start for _, start, end in ranges)
        self.assertLessEqual(abs(len(decoded) // 2 - round(total * FRAME * rate)), 1)
        originals = {file: audio(file) for file, _, _ in ranges}
        elapsed = 0
        for file, start, end in ranges:
            source_begin = round(start * FRAME * rate)
            output_begin = round(elapsed * FRAME * rate)
            elapsed += end - start
            output_end = round(elapsed * FRAME * rate)
            # Compare marker neighborhoods on both sides of every join. A single
            # sample tolerance accommodates differing source and output rounding.
            for begin in [output_begin + 4, output_end - 96]:
                marker_window = decoded[2 * begin:2 * (begin + 92)]
                source_index = source_begin + begin - output_begin
                self.assertTrue(any(
                    originals[file][2 * (source_index + offset):2 * (source_index + offset + 92)]
                    == marker_window for offset in [-1, 0, 1]
                ), f"PCM marker drift near output sample {begin}")

    def test_repeated_fractional_pcm_tail_stays_on_sample_clock(self):
        source = self.prores("tail.mov", sample_rate=44100)
        output = self.root / "tail-repeat.mov"
        repeats = 30
        ranges = [(source, 89, 90)] * repeats
        self.export(output, [self.edit(source, 89 * FRAME)] * repeats)
        self.assert_assembly(output, ranges)

        rate = 44100
        decoded = audio(output)
        expected_samples = round(repeats * FRAME * rate)
        self.assertLessEqual(abs(len(decoded) // 2 - expected_samples), 1)
        source_marker_index = round(89 * FRAME * rate)
        original = audio(source)
        for join in range(1, repeats):
            output_marker_index = round(join * FRAME * rate)
            output_window = decoded[2 * output_marker_index:2 * (output_marker_index + 16)]
            self.assertTrue(any(
                original[2 * (source_marker_index + offset):2 * (source_marker_index + offset + 16)]
                == output_window for offset in [-1, 0, 1]
            ), f"PCM marker drift after repeated tail {join}")

    def test_pcm_track_offset_survives_edit(self):
        video = self.fixture("video.mov", ["-c:v", "prores_ks", "-profile:v", "3",
                                            "-pix_fmt", "yuv422p10le"], rate="30", frame_count=30)
        source = self.root / "offset.mov"
        ffmpeg("-i", video, "-itsoffset", "0.1", "-f", "lavfi", "-i",
               "sine=frequency=997:sample_rate=48000:duration=0.8",
               "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "pcm_s16le", source)
        output = self.root / "offset-join.mov"
        clips = [self.edit(source, stop="1/2"), self.edit(source, "1/2")]
        report = self.export(output, clips, dry_run=True)
        windows = []
        for segment in report["segments"]:
            pcm = next(track for track in segment["tracks"] if track["kind"] == "audio")
            windows.append((ratio(pcm["outputStart"]), ratio(pcm["outputEnd"])))
        self.assertEqual(windows, [(Fraction(1, 10), Fraction(1, 2)),
                                   (Fraction(1, 2), Fraction(9, 10))])

        self.export(output, clips)
        self.assertEqual(audio(output), audio(source))
        self.assertEqual(frames(output), frames(source))
        stream = probe(output, "-select_streams", "a:0", "-show_streams")["streams"][0]
        self.assertEqual(stream["start_pts"], 4800)
        self.assertEqual(stream["duration_ts"], 38400)

    def test_closed_gop_exact_cut_and_argument_equivalence(self):
        a, b, c = [self.h264(f"{label}.mp4", hue=hue)
                   for label, hue in zip("abc", [0, 42, 94])]
        ranges = [(c, 0, 90), (a, 15, 45), (b, 0, 30), (b, 60, 90)]
        edits = [self.edit(file, start * FRAME, end * FRAME) for file, start, end in ranges]
        output = self.root / "json.mp4"
        self.export(output, edits)
        self.assert_assembly(output, ranges)

        args = ["export", "--json", "--mode", "copy", "--output", "argv.mp4"]
        for edit in edits:
            args += ["--clip", edit["file"], "--from", edit["from"], "--to", edit["to"]]
        self.cli(*args)
        self.assertEqual(packets(output), packets(self.root / "argv.mp4"))

    def test_incompatible_existing_and_bad_range(self):
        source = self.prores("source.mov")
        other = self.prores("other.mov", width=128)
        audio_mismatch = self.prores("other-audio.mov", sample_rate=44100)
        output = self.root / "output.mov"
        for code, edits in [
            ("incompatible_clip", [self.edit(source), self.edit(other)]),
            ("incompatible_clip", [self.edit(source), self.edit(audio_mismatch)]),
            ("invalid_range", [self.edit(source, FRAME, FRAME)]),
            ("invalid_range", [self.edit(source, 2 * FRAME, FRAME)]),
            ("invalid_time", [self.edit(source, "1/0")]),
        ]:
            report = self.export(output, edits, ok=False)
            self.assertEqual(report["error"]["code"], code)
            self.assertFalse(output.exists())
        wrong_muxer = self.root / "invalid.webm"
        report = self.export(wrong_muxer, [self.edit(source)], ok=False)
        self.assertEqual(report["error"]["code"], "unsupported_container", report)
        self.assertFalse(wrong_muxer.exists())
        output.write_bytes(b"preserve this destination")
        report = self.export(output, [self.edit(source)], ok=False)
        self.assertEqual(report["error"]["code"], "output_exists")
        self.assertEqual(output.read_bytes(), b"preserve this destination")
        inputs = {source, other, audio_mismatch}
        self.assertEqual(set(self.root.iterdir()), inputs | {output} | {Path(str(p) + ".cutdb") for p in inputs})

    def test_prores_alpha_color_and_orientation(self):
        for profile in ["4", "5"]:
            with self.subTest(profile=profile):
                initial = self.fixture(f"initial-{profile}.mov",
                                       ["-c:v", "prores_ks", "-profile:v", profile,
                                        "-pix_fmt", "yuva444p10le"], alpha=True)
                source = self.root / f"rotated-{profile}.mov"
                ffmpeg("-display_rotation", "90", "-i", initial, "-map", "0:v:0", "-c", "copy",
                       "-color_trc", "bt709", "-color_primaries", "bt709", "-movflags", "+write_colr",
                       source)
                output = self.root / f"one-frame-{profile}.mov"
                self.export(output, [self.edit(source, FRAME, FRAME * 2)])
                self.assert_assembly(output, [(source, 1, 2)])
                source_stream, output_stream = [
                    probe(file, "-show_streams")["streams"][0] for file in [source, output]
                ]
                for field in ["pix_fmt", "color_range", "color_space", "color_transfer", "color_primaries",
                              "side_data_list", "profile", "codec_tag_string"]:
                    self.assertIn(field, source_stream)
                    self.assertEqual(output_stream.get(field), source_stream[field], field)

    def test_prores_mov_index_matches_packet_scan(self):
        initial = self.fixture("initial.mov", ["-c:v", "prores_ks", "-profile:v", "4",
                                               "-pix_fmt", "yuva444p10le"], alpha=True,
                               audio_encoder="pcm_s24le", rate="25", frame_count=25)
        indexed = self.root / "indexed.mov"
        ffmpeg("-i", initial, "-c", "copy", "-timecode", "01:00:00:00", indexed)
        scanned = self.root / "scanned.mov"
        # The extra root atom opts out of the simple MOV fast path without changing any samples.
        scanned.write_bytes(indexed.read_bytes() + b"\x00\x00\x00\x18uuidMPCut scan test\x00")
        reports = [self.cli("inspect", "--json", "--keyframes", str(source))
                   for source in (indexed, scanned)]
        for report, source in zip(reports, (indexed, scanned)):
            self.assertEqual(Path(report.pop("file")).resolve(), source.resolve())
            report["media"].pop("url")
        self.assertEqual(*reports)

        exports = [self.root / name for name in ("index-out.mov", "scan-out.mov")]
        for source, output in zip((indexed, scanned), exports):
            self.export(output, [self.edit(source, Fraction(2, 25), Fraction(16, 25))])
        self.assertEqual(timestamped_hashes(exports[0]), timestamped_hashes(exports[1]))
        self.assertEqual(audio(exports[0]), audio(exports[1]))
        streams = [probe(output, "-show_streams")["streams"] for output in exports]
        self.assertEqual(streams[0][-1]["tags"]["timecode"], "01:00:00:02")
        self.assertEqual(streams[0][-1]["tags"]["timecode"], streams[1][-1]["tags"]["timecode"])

        picture_packets = probe(indexed, "-select_streams", "v:0", "-show_packets",
                                "-show_entries", "packet=pos")["packets"]
        for path in (indexed, scanned):
            changed = self.root / ("changed-" + path.name)
            payload = bytearray(path.read_bytes())
            # The frame header, independently of the MOV sample description,
            # identifies the encoded color matrix on every ProRes picture.
            position = int(picture_packets[1]["pos"]) + 24
            payload[position] = 6 if payload[position] == 1 else 1
            changed.write_bytes(payload)
            issue = self.cli("inspect", "--json", str(changed))["media"]["copyIssue"]
            self.assertIn("color description", issue)
        with indexed.open("r+b") as movie:
            movie.seek(int(picture_packets[1]["pos"]) + 25)
            flag = movie.read(1)[0]
            movie.seek(-1, os.SEEK_CUR)
            movie.write(bytes([flag & 0xf0]))
        damaged = self.cli("inspect", "--json", "--keyframes", str(indexed))
        self.assertFalse(damaged["copy"]["eligible"])
        self.assertIn("alpha", damaged["media"]["copyIssue"])

    def test_webm_uses_video_track_end_for_fractional_packet_cadence(self):
        source = self.root / "fractional.webm"
        ffmpeg("-f", "lavfi", "-i", "color=s=64x96:r=24:d=8", "-f", "lavfi", "-i",
               "anullsrc=r=48000:cl=mono:d=9", "-c:v", "libvpx-vp9", "-deadline", "realtime",
               "-g", "24", "-c:a", "libopus", source)
        inspected = self.cli("inspect", "--json", "--keyframes", str(source))["media"]
        self.assertEqual(ratio(inspected["duration"]), 8)
        # Audio runs longer than the picture. The video track's own tag
        # resolves the final 7.958 + 0.041 second block to exactly eight seconds.
        output = self.root / "whole.webm"
        self.export(output, [self.edit(source, 0, 8)])
        self.assertEqual(ratio(self.cli("inspect", "--json", str(output))["media"]["duration"]), 8)
        self.assertEqual(sample_hashes(output), sample_hashes(source))
        silent = self.root / "silent.webm"
        ffmpeg("-f", "lavfi", "-i", "color=s=64x96:r=24:d=8", "-c:v", "libvpx-vp9",
               "-deadline", "realtime", "-g", "24", silent)
        tail = self.root / "tail.webm"
        self.export(tail, [self.edit(silent, 1, 8)])
        self.assertEqual(ratio(self.cli("inspect", "--json", str(tail))["media"]["duration"]), 7)
        self.assertEqual(sample_hashes(tail), sample_hashes(silent)[24:])
        stale = self.root / "stale.webm"
        data = source.read_bytes()
        self.assertIn(b"00:00:08.000000000", data)
        stale.write_bytes(data.replace(b"00:00:08.000000000", b"00:00:18.000000000"))
        self.assertEqual(ratio(self.cli("inspect", "--json", str(stale))["media"]["duration"]), Fraction(7999, 1000))

    def test_interlaced_avc_preserves_copy_only_cut_boundaries(self):
        source = self.fixture("fields.mp4", ["-c:v", "libx264", "-x264-params",
                              "tff=1:keyint=25:scenecut=0", "-flags", "+ilme+ildct"],
                              width=320, rate="25", frame_count=100)
        report = self.cli("inspect", "--json", str(source))
        self.assertEqual(report["media"]["streams"][0]["fieldOrder"], "tt")
        output = self.root / "fields-cut.mp4"
        result = self.cli("export", "--json", "--smart-trim", "--dry-run", "--clip", str(source),
                          "--from", "0.16", "--to", "2.8", "--output", str(output), ok=False)
        self.assertEqual(result["error"]["code"], "unsafe_boundary")
        self.export(output, [self.edit(source)], dry_run=True)

    def test_reordered_vfr_mov_preserves_presentation_extent(self):
        source = self.root / "reordered-vfr.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=30",
               "-vf", "select='not(mod(n,4))+not(mod(n,7))'", "-fps_mode", "vfr",
               "-frames:v", "28", "-c:v", "libx264", "-bf", "3",
               "-x264-params", "keyint=7:min-keyint=7:scenecut=0:open-gop=0", source)

        def presentation_duration(path):
            track = probe(path, "-select_streams", "v:0", "-show_streams")["streams"][0]
            return int(track["duration_ts"]) * Fraction(track["time_base"])

        report = self.cli("inspect", "--json", "--keyframes", str(source))["media"]
        self.assertEqual(ratio(report["duration"]), presentation_duration(source))
        source_packets = timestamped_hashes(source)
        presentation_times = sorted(time for time, _ in source_packets)
        self.assertEqual(ratio(report["frames"][0]["duration"]), presentation_times[1])

        whole = self.root / "whole-vfr.mp4"
        self.export(whole, [{"file": str(source)}])
        self.assertEqual(presentation_duration(whole), presentation_duration(source))
        self.assertEqual(timestamped_hashes(whole), source_packets)
        self.assertEqual(frames(whole), frames(source))

        matroska = self.root / "whole-vfr.mkv"
        self.export(matroska, [{"file": str(source)}])
        matroska_duration = Fraction(probe(matroska, "-show_format")["format"]["duration"])
        self.assertLessEqual(abs(matroska_duration - presentation_duration(source)), Fraction(1, 1_000))
        self.assertEqual(sample_hashes(matroska), sample_hashes(source))
        self.assertEqual(frames(matroska), frames(source))

        cuts = [ratio(point["time"]) for point in report["frames"]
                if point["canStart"] and point["canEnd"] and ratio(point["time"]) > 0]
        self.assertEqual(cuts, [Fraction(2, 3), Fraction(4, 3), Fraction(2)])
        source_frames = frames(source)
        for index, end in enumerate(cuts):
            with self.subTest(end=end):
                trimmed = self.root / f"trimmed-vfr-{index}.mp4"
                self.export(trimmed, [{"file": str(source), "to": str(end)}])
                self.assertEqual(presentation_duration(trimmed), end)
                self.assertEqual(timestamped_hashes(trimmed), [packet for packet in source_packets if packet[0] < end])
                self.assertEqual(frames(trimmed), source_frames[:presentation_times.index(end)])

        joined = self.root / "joined-vfr.mp4"
        end = cuts[0]
        self.export(joined, [{"file": str(source), "to": str(end)}] * 2)
        retained = [packet for packet in source_packets if packet[0] < end]
        self.assertEqual(presentation_duration(joined), 2 * end)
        self.assertEqual(timestamped_hashes(joined), retained + [(time + end, digest) for time, digest in retained])
        self.assertEqual(frames(joined), source_frames[:presentation_times.index(end)] * 2)

    def test_webm_vp9_alpha_is_reported_and_retained(self):
        source = self.root / "alpha.webm"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=30,format=yuva420p,colorchannelmixer=aa=0.5",
               "-frames:v", "30", "-c:v", "libvpx-vp9", "-pix_fmt", "yuva420p",
               "-g", "15", "-lag-in-frames", "0", source)
        report = self.cli("inspect", "--json", "--keyframes", str(source))["media"]
        self.assertEqual(report["streams"][0]["alphaBits"], 8)
        self.assertTrue(report["sourceStartSafe"])
        self.assertTrue(any(point["canStart"] and ratio(point["time"]) == Fraction(1, 2)
                            for point in report["frames"]))

        def alpha_frames(path):
            return ffmpeg("-c:v", "libvpx-vp9", "-i", path, "-vf", "alphaextract",
                          "-f", "rawvideo", "-pix_fmt", "gray", "-")

        trimmed = self.root / "alpha-trim.webm"
        self.export(trimmed, [{"file": str(source), "from": "1/2"}])
        self.assertEqual(alpha_frames(trimmed), alpha_frames(source)[15 * 160 * 96:])

    def test_avc_rgb_pixel_format_is_reported(self):
        source = self.root / "rgb.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc=s=160x96:r=30",
               "-frames:v", "4", "-c:v", "libx264rgb", "-colorspace", "rgb", "-color_range", "pc", source)
        stream = self.cli("inspect", "--json", str(source))["media"]["streams"][0]
        self.assertEqual(stream["pixelFormat"], "gbrp")
        self.assertEqual(stream["colorMatrix"], "gbr")
        self.assertEqual(stream["colorRange"], "pc")

    def test_raw_video_is_excluded_after_content_probe(self):
        source = self.root / "raw.avi"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=160x96:r=30",
               "-frames:v", "4", "-c:v", "rawvideo", "-threads", "1", source)
        renamed = source.with_suffix(".mov")
        source.rename(renamed)
        result = self.cli("inspect", "--json", str(renamed))
        self.assertEqual(result["media"]["format"], "avi")
        self.assertIn("RAW video", result["media"]["copyIssue"])
        output = self.root / "raw-copy.mkv"
        report = self.export(output, [{"file": str(renamed)}], ok=False)
        self.assertEqual(report["error"]["code"], "unsupported_tracks", report)
        self.assertIn("RAW video", report["error"]["message"])
        self.assertFalse(output.exists())

    def test_open_gop_cuts_and_snap(self):
        encoders = {
            "h264": lambda: self.h264("open-avc.mp4", open_gop=True),
            "hevc": lambda: self.fixture(
                "open-hevc.mp4",
                ["-pix_fmt", "yuv420p", "-c:v", "libx265", "-tag:v", "hvc1",
                 "-x265-params", "keyint=15:min-keyint=15:scenecut=0:open-gop=1:"
                 "bframes=3:log-level=error:pools=1"],
            ),
        }
        for codec, encoder in encoders.items():
            with self.subTest(codec=codec):
                source = encoder()
                inspected = self.cli("inspect", "--json", "--keyframes", source.name)["media"]
                self.assertEqual(ratio(inspected["duration"]), 90 * FRAME)
                self.assertGreater(ratio(inspected["streams"][0]["timeBase"]), 0)
                self.assertEqual(inspected["streams"][0]["codec"], codec)
                access_points = [ratio(frame["time"]) for frame in inspected["frames"] if frame["keyframe"]]
                self.assertIn(Fraction(0), access_points)
                self.assertIn(15 * FRAME, access_points)
                # Frame 1 is a reordered inter picture, so decoding from it is unsafe.
                output = self.root / f"{codec}-bad.mp4"
                rejected = self.export(output, [self.edit(source, FRAME)], ok=False)["error"]
                self.assertEqual(rejected["code"], "unsafe_boundary", rejected)
                self.assertEqual(rejected["segment"], 1)
                self.assertIn(rejected["boundary"], ["start", "from"])
                self.assertFalse(output.exists())
                self.assertTrue(rejected["nearest"], rejected)
                # unsafe_boundary is the copy's answer. Asked as Smart Trim, which is also the default without a mode,
                # the same cut is Smart Trim's to answer: every picture group of the HEVC source is open, so it has no
                # keyframe to resume copying at and says unsafe_smart_join. A copy request never reports that code.
                for named in ({"mode": "smart"}, {}):
                    smart = self.cli("export", "--json", "--stdin", "--dry-run", ok=False,
                                     request={"output": str(output), "clips": [self.edit(source, FRAME)], **named})["error"]
                    self.assertEqual((smart["code"], smart["reason"]),
                                     {"h264": ("unsafe_boundary", "cut.videoStart"),
                                      "hevc": ("unsafe_smart_join", "join.smartOpenGOP")}[codec], smart)
                for index, nearest in enumerate(rejected["nearest"]):
                    start = ratio(nearest)
                    alternative = self.root / f"{codec}-alternative-{index}.mp4"
                    self.export(alternative, [self.edit(source, start)])
                    self.assert_assembly(alternative, [(source, int(start / FRAME), 90)])
                self.export(output, [self.edit(source, FRAME)], snap=True)
                self.assert_assembly(output, [(source, 0, 90)])

                # Try the key-marked open-GOP point. A flagged packet alone does
                # not establish that both sides of this cut are displayable.
                cue = next(
                    (int(packet["pts"]) * Fraction(
                        probe(source, "-select_streams", "v:0", "-show_streams")
                        ["streams"][0]["time_base"]
                    ) for packet in packets(source) if "K" in packet["flags"] and int(packet["pts"]) > 0)
                )
                for position, edit in [("start", self.edit(source, cue)),
                                       ("end", self.edit(source, stop=cue))]:
                    target = self.root / f"{codec}-{position}.mp4"
                    request = {"output": str(target), "clips": [edit], "mode": "copy"}
                    result = subprocess.run(
                        [CLI, "export", "--json", "--stdin"], input=json.dumps(request),
                        capture_output=True, text=True, timeout=60, cwd=self.root
                    )
                    report = json.loads(result.stdout)
                    if result.returncode:
                        self.assertFalse(target.exists())
                        self.assertEqual(report["error"]["code"], "unsafe_boundary", report)
                        self.assertTrue(report["error"]["nearest"], report)
                        for index, option in enumerate(report["error"]["nearest"]):
                            alternate = ratio(option)
                            alternate_target = self.root / f"{codec}-{position}-alt-{index}.mp4"
                            alternate_edit = (self.edit(source, alternate) if position == "start"
                                              else self.edit(source, stop=alternate))
                            self.export(alternate_target, [alternate_edit])
                            frame_index = int(alternate / FRAME)
                            span = (frame_index, 90) if position == "start" else (0, frame_index)
                            self.assert_assembly(alternate_target, [(source, *span)])
                    else:
                        frame_index = int(cue / FRAME)
                        index = (frame_index, 90) if position == "start" else (0, frame_index)
                        self.assert_assembly(target, [(source, *index)])

    def test_aac_whole_copy_and_repeated_fractional_trims(self):
        source = self.h264("aac.mp4", audio_encoder="aac")
        output = self.root / "aac-copy.mp4"
        self.export(output, [self.edit(source)])
        self.assertEqual(sample_hashes(source, "a:0"), sample_hashes(output, "a:0"))
        self.assertEqual(audio(source), audio(output), "AAC priming or padding changed")

        a, b, c = [self.h264(f"{label}.mov", hue=hue, audio_encoder="aac")
                   for label, hue in zip("abc", [0, 42, 94])]
        ranges = [(c, 0, 30), (a, 15, 30), (b, 30, 45), (c, 60, 75)]
        edits = [self.edit(file, start * FRAME, end * FRAME)
                 for file, start, end in ranges]
        joined = self.root / "aac-edits.mov"
        self.export(joined, edits, dry_run=True)
        self.export(joined, edits)
        self.assert_assembly(joined, ranges)

        # AVAssetReader honors MOV track edits on the decoded sample clock.
        decode = self.native_audio_decoder()
        originals = {file: decode(file) for file in [a, b, c]}
        decoded = decode(joined)
        self.assertEqual(len(decoded) // 2, round(75 * FRAME * RATE))
        elapsed = 0
        for file, start, end in ranges:
            output_start = round(elapsed * FRAME * RATE)
            elapsed += end - start
            output_end = round(elapsed * FRAME * RATE)
            source_start = round(start * FRAME * RATE)
            for begin in [output_start, output_end - 128]:
                source_index = source_start + begin - output_start
                self.assertEqual(
                    decoded[2 * begin:2 * (begin + 128)],
                    originals[file][2 * source_index:2 * (source_index + 128)],
                    f"AAC marker or priming mismatch near output sample {begin}",
                )

        # These cuts are inside AAC packets. MKV has no equivalent edit list.
        unsupported = self.root / "aac-edits.mkv"
        report = self.export(unsupported, edits, dry_run=True, ok=False)
        self.assertEqual((report["error"]["code"], report["error"]["track"]), ("unsafe_boundary", 1), report)
        self.assertFalse(unsupported.exists())

    def test_aac_edits_with_independent_media_clock(self):
        source = self.root / "tone.m4a"
        ffmpeg("-f", "lavfi", "-i", "sine=f=567:r=48000:d=4", "-c:a", "aac", "-aac_pns", "0", source)
        control = self.root / "edited.m4a"
        self.export(control, [self.edit(source, "0.1", "0.9"), self.edit(source, "1.1", "1.9")])
        scaled = self.root / "scaled.m4a"
        data = bytearray(control.read_bytes())

        # This audio-only fixture has one mdhd, stts and elst. Double only
        # fields expressed in media ticks, leaving movie times and AAC unchanged.
        def value(offset, width):
            return int.from_bytes(data[offset:offset + width], "big")

        def double(offset, width):
            data[offset:offset + width] = (2 * value(offset, width)).to_bytes(width, "big")

        def payload(tag):
            self.assertEqual(data.count(tag), 1)
            return data.index(tag) + 4

        mdhd = payload(b"mdhd")
        wide = data[mdhd] == 1
        clock = mdhd + (20 if wide else 12)
        self.assertEqual(value(clock, 4), 48000)
        double(clock, 4)
        double(clock + 4, 8 if wide else 4)
        stts = payload(b"stts")
        for i in range(value(stts + 4, 4)):
            double(stts + 12 + 8 * i, 4)
        elst = payload(b"elst")
        width = 8 if data[elst] == 1 else 4
        self.assertEqual(value(elst + 4, 4), 2)
        for i in range(2):
            double(elst + 8 + i * (2 * width + 4) + width, width)
        scaled.write_bytes(data)

        info = self.cli("inspect", "--json", scaled)
        self.assertEqual(ratio(info["media"]["duration"]), Fraction(8, 5))
        decode = self.native_audio_decoder()
        expected = decode(control)
        self.assertEqual(len(expected), 2 * 76800)
        self.assertEqual(decode(scaled), expected)
        for name, bounds in [("whole", (None, None)), ("across-join", ("0.4", "1.2"))]:
            baseline, output = (self.root / f"{name}-{stem}.m4a" for stem in ("base", "scaled"))
            self.export(baseline, [self.edit(control, *bounds)])
            self.export(output, [self.edit(scaled, *bounds)])
            self.assertEqual(sample_hashes(output, "a:0"), sample_hashes(baseline, "a:0"))
            self.assertEqual(decode(output), decode(baseline))
            self.assertEqual(decode(output), expected if name == "whole" else expected[2 * 19200:2 * 57600])

        half_sample = self.root / "half-sample.m4a"
        first_offset = elst + 8 + width
        data[first_offset:first_offset + width] = (value(first_offset, width) + 1).to_bytes(width, "big")
        half_sample.write_bytes(data)
        refused = self.root / "unrepresentable.m4a"
        self.export(refused, [self.edit(half_sample)], dry_run=True, ok=False)
        self.assertFalse(refused.exists())

    def test_aac_whole_clip_joins_preserve_priming_and_tail_padding(self):
        # Disable random perceptual noise substitution for byte-exact decode
        # comparisons across both fresh and continuously running AAC decoders.
        sources = [self.h264(f"full-{hue}.mov", hue=hue, audio_encoder="aac",
                             audio_encoder_options=["-aac_pns", "0"],
                             rate="25", frame_count=75) for hue in [0, 42, 94]]
        output = self.root / "full-aac-join.mov"
        self.export(output, [self.edit(source) for source in sources])
        self.assertEqual(frames(output), [frame for source in sources for frame in frames(source)])
        for track in ["v:0", "a:0"]:
            # The unedited media tables retain each AAC priming packet.
            options = ["-ignore_editlist", "1"]
            expected = [digest for source in sources for digest in sample_hashes(source, track, options)]
            self.assertEqual(sample_hashes(output, track, options), expected)

        decode = self.native_audio_decoder()
        source_bytes = [decode(source) for source in sources]
        output_bytes = decode(output)
        self.assertEqual([len(data) for data in source_bytes], [2 * 3 * RATE] * len(sources))
        self.assertEqual(output_bytes, b"".join(source_bytes))

    def test_reimport_aac_with_empty_presentation_edits(self):
        source = self.root / "aac-with-delay.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=size=160x96:rate=25:duration=2",
               "-itsoffset", "1.75", "-f", "lavfi", "-i",
               "aevalsrc='if(between(t,0.05,0.16),0.65*sin(2*PI*997*t),0)':s=48000:d=0.25",
               "-c:v", "libx264", "-g", "25", "-sc_threshold", "0",
               "-c:a", "aac", "-aac_pns", "0", source)
        joined = self.root / "aac-with-four-delays.mov"
        self.export(joined, [self.edit(source)] * 4)
        self.assert_assembly(joined, [(source, 0, 50)] * 4, Fraction(1, 25))

        decode = self.native_audio_decoder()
        decoded = decode(source)
        self.assertEqual(len(decoded), 2 * 2 * RATE)
        self.assertEqual(decoded[:3 * RATE], bytes(3 * RATE))
        self.assertTrue(any(decoded[-RATE // 2:]))
        # Eight seconds of presentation requires a wider track duration even
        # though the muxer initially wrote under two seconds of coded AAC.
        self.assertEqual(decode(joined), decoded * 4)
        # Hidden AAC decoder history in each empty edit must not appear as a
        # second copy of the tone. Compare every 20 ms waveform bin against
        # the native presentation, including the explicitly silent bins.
        wave = self.cli("silence", "--json", "--waveform", "400", joined)["waveformPeakDBFS"]
        presented = memoryview(decoded * 4).cast("h")
        self.assertEqual(len(wave), 400)
        for bin_index, level in enumerate(wave):
            samples = presented[bin_index * (RATE // 50):(bin_index + 1) * (RATE // 50)]
            amplitude = max(map(abs, samples)) / 32768
            self.assertIsNotNone(level)
            self.assertAlmostEqual(10 ** (level / 20), amplitude, delta=0.0001)

        # Zoom through a MOV empty edit into the following tone. The signed
        # envelope uses the same source clock as both movie playback and trimming.
        detail = self.cli("waveform", "--json", "--from", "1.5", "--to", "4", "--columns", "2500", joined)["envelope"]
        start = 3 * RATE // 2
        self.assertEqual((len(detail["low"]), len(detail["high"])), (2500, 2500))
        for i, (low, high) in enumerate(zip(detail["low"], detail["high"], strict=True)):
            block = presented[start + i * 48:start + (i + 1) * 48]
            self.assertAlmostEqual(low, min(block) / 32768, delta=0.0001)
            self.assertAlmostEqual(high, max(block) / 32768, delta=0.0001)

        reopened = self.root / "aac-delay-reopened.mov"
        self.export(reopened, [self.edit(joined, 1, 6)])
        self.assert_assembly(reopened, [(joined, 25, 150)], Fraction(1, 25))
        self.assertEqual(decode(reopened), (decoded * 4)[2 * RATE:12 * RATE])

    def test_whole_copy_aac_edits_keeps_audio_outside_picture(self):
        source = self.root / "aac-with-offset-picture.mov"
        ffmpeg("-itsoffset", "0.2", "-f", "lavfi", "-i", "testsrc2=size=160x96:rate=25:duration=2",
               "-itsoffset", "0.05", "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=2.25",
               "-c:v", "libx264", "-c:a", "aac", "-aac_pns", "0", source)
        output = self.root / "aac-offset-copy.mov"
        self.export(output, [self.edit(source)])
        self.assertEqual(sample_hashes(output), sample_hashes(source))
        options = ["-ignore_editlist", "1"]
        self.assertEqual(sample_hashes(output, "a:0", options), sample_hashes(source, "a:0", options))

        source_streams = probe(source, "-show_streams")["streams"]
        output_streams = probe(output, "-show_streams")["streams"]
        source_audio, output_audio = source_streams[1], output_streams[1]
        self.assertGreater(Fraction(source_audio["start_time"]), 0)
        self.assertEqual(Fraction(output_audio["start_time"]), 0)
        self.assertEqual(output_audio["duration_ts"], source_audio["duration_ts"])
        source_offset = Fraction(source_streams[0]["start_time"]) - Fraction(source_audio["start_time"])
        output_offset = Fraction(output_streams[0]["start_time"])
        self.assertLessEqual(abs(source_offset - output_offset), Fraction(output_streams[0]["time_base"]))
        decode = self.native_audio_decoder()
        leading_samples = int(source_audio["start_pts"])
        self.assertEqual(decode(output), decode(source)[2 * leading_samples:])

    def test_reimport_and_trim_across_an_aac_join(self):
        sources = [self.h264(f"reimport-{hue}.mov", hue=hue, audio_encoder="aac",
                             audio_encoder_options=["-aac_pns", "0"],
                             rate="25", frame_count=75) for hue in [0, 42, 94]]
        a, b, c = sources
        assembly = self.root / "assembly.mov"
        self.export(assembly, [self.edit(a), self.edit(b)])

        output = self.root / "reimport.mov"
        clips = [self.edit(assembly, "2.4", "3.6"), self.edit(c, "0.6", "2.4")]
        report = self.export(output, clips, dry_run=True)
        self.assertEqual(ratio(report["duration"]), 3)
        self.export(output, clips)

        ranges = [(a, 60, 75), (b, 0, 15), (c, 15, 60)]
        self.assert_assembly(output, ranges, Fraction(1, 25))
        options = ["-ignore_editlist", "1"]
        source_aac = {digest for source in sources for digest in sample_hashes(source, "a:0", options)}
        copied_aac = sample_hashes(output, "a:0", options)
        self.assertTrue(copied_aac)
        self.assertTrue(set(copied_aac) <= source_aac, "AAC payload changed on reimport")

        decode = self.native_audio_decoder()
        expected = b"".join(decode(file)[2 * start * RATE // 25:2 * end * RATE // 25]
                            for file, start, end in ranges)
        decoded = decode(output)
        self.assertEqual(len(decoded), 2 * 3 * RATE)
        self.assertEqual(decoded, expected)

    def test_webm_whole_copy_with_audio(self):
        formats = [
            ("vp9", ["-c:v", "libvpx-vp9", "-deadline", "realtime"], "libopus"),
            ("vp8", ["-c:v", "libvpx", "-deadline", "realtime"], "vorbis"),
            ("av1", ["-c:v", "libsvtav1", "-preset", "11", "-svtav1-params", "lp=2"], "libopus"),
        ]
        for codec, settings, audio_encoder in formats:
            with self.subTest(codec=codec):
                source = self.fixture(f"{codec}.webm",
                                      ["-pix_fmt", "yuv420p", "-g", "15", *settings],
                                      audio_encoder=audio_encoder)
                output = self.root / f"{codec}-copy.webm"
                self.export(output, [self.edit(source)])
                reference = frames(source)
                self.assertEqual(frames(output), reference)
                seeked = frames(output, seek=1)
                self.assertIn(len(seeked), [60, 61])
                self.assertEqual(seeked, reference[-len(seeked):])
                for track in ["v:0", "a:0"]:
                    self.assertEqual(sample_hashes(output, track), sample_hashes(source, track))
                self.assertEqual(audio(output), audio(source), "WebM priming or padding changed")

    def test_webm_opus_range_trims_and_unsupported_join(self):
        source = self.fixture("opus-prefix.webm",
                              ["-c:v", "libvpx-vp9", "-deadline", "realtime",
                               "-pix_fmt", "yuv420p", "-g", "25"],
                              audio_encoder="libopus", rate="25", frame_count=100)
        output = self.root / "prefix.webm"
        edits = [self.edit(source, stop="1")]
        dry_run = self.export(output, edits, dry_run=True)
        self.assertEqual(ratio(dry_run["duration"]), 1)
        self.export(output, edits)
        self.assertEqual(frames(output), frames(source)[:25])
        self.assertEqual(sample_hashes(output), sample_hashes(source)[:25])
        self.assertEqual(audio(output), audio(source)[:2 * RATE])
        opus_hashes = sample_hashes(output, "a:0")
        self.assertEqual(opus_hashes, sample_hashes(source, "a:0")[:len(opus_hashes)])

        adjacent = self.root / "adjacent.webm"
        contiguous = [self.edit(source, stop="1"), self.edit(source, "1", "2")]
        self.export(adjacent, contiguous)
        self.assertEqual(frames(adjacent), frames(source)[:50])
        self.assertEqual(audio(adjacent), audio(source)[:4 * RATE])

        trimmed = self.root / "head-trim.webm"
        self.export(trimmed, [self.edit(source, "1")])
        self.assertEqual(sample_hashes(trimmed), sample_hashes(source)[25:])
        self.assertEqual(frames(trimmed), frames(source)[25:])
        self.assertEqual(audio(trimmed), audio(source)[2 * RATE:])
        original_audio = sample_hashes(source, "a:0")
        kept_audio = sample_hashes(trimmed, "a:0")
        first_packet = original_audio.index(kept_audio[0])
        self.assertEqual(kept_audio, original_audio[first_packet:])

        interior = self.root / "interior.mkv"
        self.export(interior, [self.edit(source, "2", "3")])
        self.assertEqual(Fraction(probe(interior, "-show_format")["format"]["duration"]), 1)
        self.assertEqual(audio(interior), audio(source)[4 * RATE:6 * RATE])
        reopened = self.root / "reopened.webm"
        self.export(reopened, [self.edit(trimmed, "1", "2")])
        self.assertEqual(Fraction(probe(reopened, "-show_format")["format"]["duration"]), 1)
        self.assertEqual(audio(reopened), audio(interior))
        self.assertEqual(sample_hashes(reopened), sample_hashes(interior))

        invalid = self.root / "discontinuous.webm"
        report = self.export(invalid, [self.edit(source, stop="1"), self.edit(source, stop="1")],
                             dry_run=True, ok=False)
        self.assertEqual(report["error"]["code"], "unsafe_boundary", report)
        self.assertIn("Opus", report["error"]["message"])
        self.assertFalse(invalid.exists())

    def test_silent_webm_interior_cuts_and_joins(self):
        for encoder in ["libvpx", "libvpx-vp9"]:
            with self.subTest(encoder=encoder):
                settings = ["-c:v", encoder, "-deadline", "realtime", "-lag-in-frames", "0",
                            "-pix_fmt", "yuv420p", "-g", "25"]
                a, b = [self.fixture(f"{encoder}-{label}.webm", settings, rate="25",
                                     frame_count=75, hue=hue)
                        for label, hue in zip("ab", [0, 42])]
                output = self.root / f"{encoder}-join.webm"
                self.export(output, [self.edit(b, "1", "2"), self.edit(a, stop="1")])
                self.assertEqual(frames(output), frames(b)[25:50] + frames(a)[:25])
                self.assertEqual(sample_hashes(output),
                                 sample_hashes(b)[25:50] + sample_hashes(a)[:25])

    def test_smart_export_offers_packet_copy_in_another_container(self):
        source = self.h264("recording.mov", width=320, rate="25", audio_encoder="aac")
        rejected = self.root / "recording.webm"
        problem = self.cli("export", "--json", "--mode", "smart", "--clip", source,
                           "--output", rejected, ok=False)
        self.assertFalse(rejected.exists())
        offers = problem["error"]["alternatives"]
        self.assertEqual(offers[0]["rung"], "copyOtherContainer")
        remux = next(offer for offer in offers if offer["id"] == "copyOtherContainer:mp4")
        self.assertEqual(remux["mode"], "copy")
        output = self.root / "remux.mp4"
        report = self.cli("export", "--json", *remux["arguments"], "--clip", source, "--output", output)
        self.assertEqual(ratio(report["encodedDuration"]), 0)
        for track in ["v:0", "a:0"]:
            original = sample_hashes(source, track)
            self.assertTrue(original)
            self.assertEqual(sample_hashes(output, track), original)

    def test_multicam_lossless_container_offer_uses_copy_mode(self):
        source = self.h264("angle.mov", width=320, rate="25", frame_count=50)
        project = self.root / "switches.cut"
        project.write_text(json.dumps({
            "format": "mpcut", "schemaVersion": 1, "kind": "multicam",
            "angles": [{"id": "a", "file": source.name}], "referenceAngle": "a",
            "range": {"from": "0", "to": "2"}, "audio": {"mode": "none"},
            "switches": [{"at": "0", "angle": "a"}],
        }))
        command = ["export", "--project", project, "--json"]
        problem = self.cli(*command, "--mode", "smart", "--output", "program.webm", ok=False)
        offers = problem["error"]["alternatives"]
        remux = next(offer for offer in offers if offer["id"] == "copyOtherContainer:mp4")
        self.assertEqual(remux["mode"], "copy")
        output = self.root / "program.mp4"
        report = self.cli(*command, *remux["arguments"], "--output", output)
        self.assertEqual(ratio(report["encodedVideoDuration"]), 0)
        self.assertEqual(sample_hashes(output), sample_hashes(source))

        edit = json.loads(project.read_text())
        edit["assembly"] = [{"from": "7/25", "to": "2"}]
        project.write_text(json.dumps(edit))
        cut = self.cli(*command, "--mode", "smart", "--output", "program.webm", ok=False)
        ids = [offer["id"] for offer in cut["error"].get("alternatives", [])]
        self.assertNotIn("copyOtherContainer:mp4", ids)
        self.assertIn("smartTrim:mp4", ids)

    def test_other_containers_and_probe_by_content(self):
        source = self.h264("source.mp4")
        for extension in ["mkv", "ts"]:
            with self.subTest(extension=extension):
                wrapped = self.root / f"actual.{extension}"
                ffmpeg("-i", source, "-c", "copy", wrapped)
                unknown = self.root / f"{extension}.unknown"
                wrapped.rename(unknown)
                self.cli("inspect", "--json", unknown.name)
                output = self.root / f"round-trip.{extension}"
                self.export(output, [self.edit(unknown)])
                self.assertEqual(frames(output), frames(unknown))
                self.assertEqual(sample_hashes(output), sample_hashes(unknown))
                if extension == "ts":
                    fallback = self.root / "ts-to-mkv.mkv"
                    self.export(fallback, [self.edit(unknown)])
                    self.assertEqual(frames(fallback), frames(unknown))

    def test_clean_shell_headless_and_clock_timestamps(self):
        source = self.fixture("clock.mov", ["-c:v", "prores_ks", "-profile:v", "3",
                                            "-pix_fmt", "yuv422p10le"], rate="25")
        env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"]}
        inspected = self.cli("inspect", "--json", source.name, env=env)
        self.assertEqual(inspected["preview"], "unchecked")
        args = ["export", "--json", "--mode", "copy", "--output", "clock-cut.mov", "--clip", source.name,
                "--from", "00:00:00.04", "--to", "0.08"]
        dry_run = self.cli(*args, "--dry-run", env=env)
        self.assertEqual(ratio(dry_run["duration"]), Fraction(1, 25))
        output = self.root / "clock-cut.mov"
        self.assertFalse(output.exists())
        self.cli(*args, env=env)
        self.assertEqual(frames(output), frames(source)[1:2])

    def test_json_rejects_unknown_request_fields(self):
        source = self.prores("source.mov")
        args = ("export", "--json", "--stdin")
        request = {"output": "output.mov", "clips": [self.edit(source)]}
        for invalid, field, location in [
            ({**request, "dry_run": True}, "dry_run", "Export request"),
            ({**request, "clips": [self.edit(source), {"file": source.name, "form": "1"}]},
             "form", "Clip 2"),
        ]:
            with self.subTest(field=field):
                report = self.cli(*args, request=invalid, ok=False)
                self.assertEqual(report["error"]["code"], "invalid_json")
                self.assertIn(location, report["error"]["message"])
                self.assertIn(field, report["error"]["message"])
                self.assertFalse((self.root / request["output"]).exists())

    def test_json_rejects_repeated_request_fields(self):
        source = self.prores("source.mov").name
        clip = '{"file": "%s", "to": "1001/1000"}' % source
        for field, text in [
            ("clips", '{"output": "out.mov", "clips": [%s, %s], "clips": [%s]}' % (clip, clip, clip)),
            ("to", '{"output": "out.mov", "clips": [{"file": "%s", "to": "1001/1000", "to": "2002/1000"}]}' % source),
            ("mode", '{"output": "out.mov", "mode": "copy", "mo\\u0064e": "smart", "clips": [%s]}' % clip),
        ]:
            with self.subTest(field=field):
                result = subprocess.run([CLI, "export", "--json", "--stdin", "--dry-run"], input=text,
                                        capture_output=True, text=True, timeout=60, cwd=self.root)
                self.assertEqual(result.returncode, 2, result.stdout)
                error = json.loads(result.stdout)["error"]
                self.assertEqual(error["code"], "invalid_json")
                self.assertIn(f"'{field}'", error["message"])
        text = '{"output": "o {\\"a\\", \\"a\\"}.mov", "clips": [%s, %s]}' % (clip, clip)
        result = subprocess.run([CLI, "export", "--json", "--stdin", "--dry-run"], input=text,
                                capture_output=True, text=True, timeout=60, cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_times_outside_the_source_are_rejected_in_every_mode(self):
        source = self.prores("source.mov")
        for args, code in [(["--from", "-1"], "invalid_time"), (["--from", "-1", "--snap", "nearest"], "invalid_time"),
                           (["--to", "100"], "invalid_range"), (["--to", "100", "--snap", "nearest"], "invalid_range")]:
            with self.subTest(args=args):
                report = self.cli("export", "--json", "--dry-run", "--output", "out.mov",
                                  "--clip", source.name, *args, ok=False)
                self.assertEqual(report["error"]["code"], code)
        report = self.cli("export", "--json", "--dry-run", "--output", "out.mov", "--clip", source.name,
                          "--from", "-0", "--to", "1001/30000")
        self.assertEqual(ratio(report["duration"]), Fraction(1001, 30000))

    def test_parent_of_a_symlinked_folder_resolves_physically(self):
        source = self.prores("source.mov")
        inner = self.root / "real" / "inner"
        inner.mkdir(parents=True)
        source.rename(self.root / "real" / source.name)
        (self.root / "link").symlink_to(inner, target_is_directory=True)
        report = self.cli("export", "--json", "--output", "link/../out.mov", "--clip", f"link/../{source.name}")
        written = Path(report["output"])
        self.assertEqual(written.resolve(), (self.root / "real" / "out.mov").resolve())
        self.assertTrue((self.root / "real" / "out.mov").exists())
        self.assertFalse((self.root / "out.mov").exists())

    def test_join_requires_matching_field_order_and_chroma_location(self):
        prores = ["-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le"]
        settings = dict(rate="25", frame_count=10)
        progressive = self.fixture("progressive.mov", prores, **settings)
        top, bottom = (self.fixture(order + ".mov", [*prores, "-flags", "+ilme+ildct",
                                                     "-vf", "setfield=" + order], **settings)
                       for order in ["tff", "bff"])
        left, center = (self.fixture(place + ".webm", ["-c:v", "libvpx-vp9", "-threads", "1",
                                                       "-deadline", "realtime", "-chroma_sample_location", place],
                                     **settings) for place in ["left", "center"])
        for first, second, label in [(progressive, top, "field order"), (top, bottom, "field order"),
                                     (left, center, "chroma location")]:
            with self.subTest(first=first.name, second=second.name):
                output = self.root / ("joined" + first.suffix)
                rejected = self.export(output, [self.edit(first), self.edit(second)], dry_run=True, ok=False)
                self.assertEqual(rejected["error"]["code"], "incompatible_clip")
                self.assertIn(label, rejected["error"]["message"])
                self.assertEqual(rejected["error"]["segment"], 2)
                self.assertFalse(output.exists())

    def test_parallel_audio_tracks_keep_their_language_order(self):
        source = self.prores("source.mov", rate="25", frame_count=25)
        bilingual = self.root / "bilingual.mov"
        swapped = self.root / "swapped.mov"
        ffmpeg("-i", source, "-map", "0:v", "-map", "0:a", "-map", "0:a", "-c", "copy",
               "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=fra", bilingual)
        ffmpeg("-i", bilingual, "-map", "0:v", "-map", "0:a:1", "-map", "0:a:0",
               "-c", "copy", swapped)
        output = self.root / "result.mov"
        self.export(output, [self.edit(bilingual), self.edit(bilingual)], dry_run=True)
        rejected = self.export(output, [self.edit(bilingual), self.edit(swapped)], ok=False)
        self.assertEqual(rejected["error"]["code"], "incompatible_clip")
        self.assertIn("audio track 1 language", rejected["error"]["message"])
        self.assertFalse(output.exists())

    def test_large_keyframe_report_and_blocked_reader_cancellation(self):
        source = self.prores("intra.mov", rate="25", frame_count=12)
        long = self.root / "many-frames.mov"
        ffmpeg("-stream_loop", "399", "-i", source, "-map", "0:v", "-c", "copy", long)
        args = ["inspect", "--json", "--keyframes", str(long)]
        report = self.cli(*args)
        indexed = report["media"]["frames"]
        self.assertEqual(len(indexed), 4800)
        self.assertTrue(all(f["keyframe"] and f["canStart"] for f in indexed))
        self.assertEqual([ratio(f["time"]) for f in indexed], [Fraction(i, 25) for i in range(4800)])
        # Leave stdout open and unread once the result starts filling the pipe.
        with subprocess.Popen([CLI, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            try:
                self.assertTrue(select.select([process.stdout], [], [], 10)[0])
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=3), 130)
            finally:
                if process.poll() is None:
                    process.kill()

    def test_export_with_full_progress_pipe(self):
        source = self.prores("progress.mov")
        output = self.root / "result.mov"
        read_end, write_end = os.pipe()
        try:
            os.set_blocking(write_end, False)
            with self.assertRaises(BlockingIOError):
                while True:
                    os.write(write_end, b"x" * 512)
            os.set_blocking(write_end, True)
            result = subprocess.run([CLI, "export", "--json", "--output", output, "--clip", source],
                                    stdout=subprocess.PIPE, stderr=write_end, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertTrue(json.loads(result.stdout)["ok"])
            self.assertEqual(frames(output), frames(source))
        finally:
            os.close(read_end)
            os.close(write_end)

    def test_stdin_requires_utf8_json(self):
        request = json.dumps({"output": "unexpected.mov", "clips": [self.edit(self.prores("clip.mov"))]})
        for encoding in ["utf-16-le", "utf-32-be"]:
            with self.subTest(encoding=encoding):
                result = subprocess.run([CLI, "export", "--stdin", "--json"], input=request.encode(encoding),
                                        capture_output=True, timeout=60, cwd=self.root)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertEqual(json.loads(result.stdout)["error"]["code"], "invalid_json")
                self.assertFalse((self.root / "unexpected.mov").exists())

    def test_cli_missing_input_and_literal_inspect_paths(self):
        absent = self.cli("inspect", "--json", ok=False)
        self.assertEqual(absent["error"]["code"], "invalid_arguments")
        empty = self.cli("inspect", "--json", "", ok=False)
        self.assertEqual(empty["error"]["code"], "invalid_path")
        literal = self.prores("literal.mov")
        literal.rename(self.root / "--help")
        report = self.cli("inspect", "--json", "--", "--help")
        self.assertEqual(report["media"]["streams"][0]["codec"], "prores")

    def test_cancellation_cleans_destination(self):
        source = self.prores("source.mov")
        output = self.root / "canceled.mov"
        request = {"output": str(output), "clips": [self.edit(source)] * 1000}
        request_file = self.root / "request.json"
        request_file.write_text(json.dumps(request))
        # Watch for a staging file to send SIGINT during the writer, after the
        # process has installed its handler and passed argument validation.
        with request_file.open() as request_input, tempfile.TemporaryFile() as progress:
            process = subprocess.Popen([CLI, "--no-sidecar", "export", "--json", "--stdin"],
                                       stdin=request_input, stdout=subprocess.PIPE,
                                       stderr=progress, cwd=self.root)
            try:
                deadline = time.monotonic() + 15
                while process.poll() is None and time.monotonic() < deadline:
                    if set(self.root.iterdir()) - {source, request_file, output}:
                        process.send_signal(signal.SIGINT)
                        break
                    time.sleep(0.001)
                else:
                    self.fail("did not observe export staging before cancellation")
                stdout, _ = process.communicate(timeout=15)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        # The destination is named "canceled", so match the code, not a substring.
        self.assertEqual(process.returncode, 130, stdout)
        report = json.loads(stdout)
        self.assertIs(report["ok"], False)
        self.assertEqual(report["error"]["code"], "cancelled", report)
        self.assertEqual(set(self.root.iterdir()), {source, request_file})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = str(args.mpcut.resolve(strict=True))
    unittest.main(argv=[__file__, *tests])
