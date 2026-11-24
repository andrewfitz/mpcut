#!/usr/bin/env python3
"""Check Smart Trim with generated camera-style GOPs and individually numbered pictures."""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

from media_regression import audio, ffmpeg, frames, probe, ratio, run, sample_hashes, timestamped_hashes

FPS = 25
SAMPLE_RATE = 48_000
CLI = None


def movie(path, codec, width=320, transfer="bt709", height=96, pixel_format="yuv420p", bframes=3):
    # Eight luma blocks encode the picture number, surviving both lossy encoders.
    marker = "geq=lum='if(lt(Y,16)*lt(X,128),if(bitand(N,pow(2,floor(X/16))),210,32),lum(X,Y))'"
    marker += f",setparams=range=limited:color_primaries=bt709:color_trc={transfer}:colorspace=bt709"
    gop = f"keyint=25:min-keyint=25:scenecut=0:open-gop=0:bframes={bframes}:b-adapt=0"
    settings = {
        "h264": ["-c:v", "libx264", "-x264-params", gop, "-threads", "1"],
        "hevc": ["-c:v", "libx265", "-x265-params", gop + ":pools=1:log-level=error", "-tag:v", "hvc1"],
        "av1": ["-c:v", "libsvtav1", "-preset", "10", "-g", "25", "-svtav1-params", "lp=2"],
    }
    sound = ["-c:a", "libopus"] if codec == "av1" else ["-c:a", "aac", "-aac_pns", "0"]
    ffmpeg("-f", "lavfi", "-i", f"testsrc2=s={width}x{height}:r={FPS}:d=5",
           "-f", "lavfi", "-i", f"sine=r={SAMPLE_RATE}:d=5:f=930",
           "-vf", marker, *settings[codec], "-pix_fmt", pixel_format, "-color_range", "tv",
           "-color_trc", transfer, "-color_primaries", "bt709", "-colorspace", "bt709",
           *sound, path, allow_diagnostics=True)
    return path


def picture_ids(path, hardware_av1=False):
    width, height = 128, 16
    decoder = ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld", "-c:v", "av1"] if hardware_av1 else []
    filters = ["hwdownload", "format=nv12", "format=yuv420p"] if hardware_av1 else []
    filters += [f"crop={width}:{height}:0:0", "extractplanes=y"]
    data = ffmpeg(*decoder, "-i", path, "-map", "0:v:0", "-vf", ",".join(filters),
                  "-fps_mode", "passthrough", "-pix_fmt", "gray", "-f", "rawvideo", "-")
    stride = width * height
    if len(data) % stride:
        raise AssertionError(f"incomplete picture in {path}")
    return bytes(sum(1 << bit for bit in range(8) if data[start + 8 * width + bit * 16 + 8] > 120)
                 for start in range(0, len(data), stride))


def vcl_hashes(path, codec):
    """Fingerprint VCL payloads; a restart packet can repeat the source parameter sets."""
    report = probe(path, "-select_streams", "v:0", "-show_packets", "-show_entries", "packet=pts,data",
                   "-show_data")
    stream = probe(path, "-select_streams", "v:0", "-show_streams")["streams"][0]
    scale = Fraction(stream["time_base"])
    origin = int(stream.get("start_pts", 0))
    hashes = {}
    for item in report["packets"]:
        data = bytes.fromhex(" ".join(line.split(": ", 1)[1].split("  ", 1)[0]
                                     for line in item["data"].splitlines() if ": " in line))
        payload = hashlib.sha256()
        cursor = 0
        count = 0
        while cursor < len(data):
            size = int.from_bytes(data[cursor:cursor+4], "big")
            cursor += 4
            if size < 1 or cursor + size > len(data):
                raise AssertionError(f"malformed length-prefixed NAL in {path}")
            nal = data[cursor:cursor+size]
            kind = nal[0] & 31 if codec == "h264" else (nal[0] >> 1) & 63
            is_vcl = 1 <= kind <= 5 if codec == "h264" else kind <= 31
            if is_vcl:
                payload.update(size.to_bytes(4, "big"))
                payload.update(nal)
                count += 1
            cursor += size
        if not count:
            raise AssertionError(f"picture without VCL payload in {path}")
        timestamp = (int(item["pts"]) - origin) * scale
        if timestamp in hashes:
            raise AssertionError(f"duplicate picture timestamp {timestamp} in {path}")
        hashes[timestamp] = payload.digest()
    return hashes


def partition_ends(path):
    """Picture numbers where the decode order is split by presentation time, from the packet order alone.

    Every packet before such a point presents before every packet from it on, so the pictures
    before it are a complete decode prefix. Picture 0 is the source start."""
    order = [int(packet["pts"]) for packet in
             probe(path, "-select_streams", "v:0", "-show_packets", "-show_entries", "packet=pts")["packets"]]
    number = {pts: index for index, pts in enumerate(sorted(order))}
    ends = []
    for index in range(len(order)):
        if index == 0 or max(order[:index]) < min(order[index:]):
            ends.append(number[min(order[index:])])
    return ends


def hardware_frames(path):
    """Hash each picture from VideoToolbox. Requiring hardware surfaces makes a software fallback fail."""
    output = ffmpeg("-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld", "-i", path,
                    "-map", "0:v:0", "-vf", "hwdownload,format=nv12", "-fps_mode", "passthrough",
                    "-f", "framehash", "-")
    return [line.split(b",", 6)[5].strip() for line in output.splitlines() if line and not line.startswith(b"#")]


class SmartTrimTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-smart-fixtures-")
        cls.addClassCleanup(directory.cleanup)
        cls.fixtures = Path(directory.name)
        cls.sources = {codec: movie(cls.fixtures / (codec + ext), codec)
                       for codec, ext in [("av1", ".webm"), ("h264", ".mp4"), ("hevc", ".mov")]}
        for name in ["DecodeAudio", "DecodeFrameIDs"]:
            run(["swiftc", "-parse-as-library", Path(__file__).with_name(name + ".swift"),
                 "-o", cls.fixtures / name], allow_diagnostics=True)

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-smart-output-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def export(self, output, ranges, *, smart=True, dry=False, ok=True):
        args = [CLI, "export", "clips", "join", "--json", "--output", output]
        # Smart Trim is the default, so the tests of Lossless Copy name it.
        args += ["--mode", "smart"] if smart else ["--mode", "copy"]
        if dry:
            args.append("--dry-run")
        for source, start, end in ranges:
            args.extend(["--clip", source, "--from", str(Fraction(start, FPS)), "--to", str(Fraction(end, FPS))])
        result = subprocess.run(args, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0 if ok else 1, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertIs(report["ok"], ok, report)
        if dry or not ok:
            self.assertFalse(output.exists())
        return report

    def test_json_order_joins_the_selected_ranges_and_preserves_copied_gops(self):
        source = self.sources["h264"]
        output = self.root / "reordered.mp4"
        ranges = [(7, 32), (39, 51), (54, 112)]
        order = [3, 1, 3]
        request = {
            "file": str(source),
            "output": str(output),
            "clips": [{"from": {"numerator": start, "denominator": FPS}, "to": str(Fraction(end, FPS))}
                      for start, end in ranges],
            "order": order,
        }
        command = [CLI, "export", "clips", "join", "--json", "--stdin"]
        dry = subprocess.run([*command, "--dry-run"], input=json.dumps(request), capture_output=True,
                             text=True, check=True, timeout=90)
        plan = json.loads(dry.stdout)
        self.assertFalse(output.exists())
        self.assertEqual(plan["mode"], "smart")
        self.assertEqual(plan["order"], order)
        self.assertGreater(ratio(plan["copied_duration"]), 0)
        self.assertGreater(ratio(plan["encoded_duration"]), 0)
        result = subprocess.run(command, input=json.dumps(request), capture_output=True, text=True,
                                check=True, timeout=90)
        self.assertEqual(json.loads(result.stdout)["segments"], plan["segments"])
        expected = bytes(frame for index in order for frame in range(*ranges[index - 1]))
        self.assertEqual(picture_ids(output), expected)
        self.assertEqual(run([self.fixtures / "DecodeFrameIDs", output]), expected)
        source_hashes, output_hashes = vcl_hashes(source, "h264"), vcl_hashes(output, "h264")
        copied_frames = 0
        for segment, index in zip(plan["segments"], order, strict=True):
            start, end = ranges[index - 1]
            edges = [(ratio(edge["from"]), ratio(edge["to"])) for edge in segment.get("encoded_edges", [])]
            for frame in range(start, end):
                source_time = Fraction(frame, FPS)
                if any(left <= source_time < right for left, right in edges):
                    continue
                output_time = ratio(segment["output_start"]) + Fraction(frame - start, FPS)
                self.assertEqual(output_hashes[output_time], source_hashes[source_time])
                copied_frames += 1
        self.assertEqual(copied_frames, ratio(plan["copied_duration"]) * FPS)

    def check_trim(self, codec, ranges, edges):
        source = self.sources[codec]
        name = "-".join(f"{start}-{end}" for start, end in ranges)
        output = self.root / (codec + "-" + name + source.suffix)
        requests = [(source, start, end) for start, end in ranges]
        dry = self.export(output, requests, dry=True)
        self.assertEqual(len(dry["segments"]), len(edges))
        for segment, expected in zip(dry["segments"], edges):
            actual = [(ratio(edge["from"]) * FPS, ratio(edge["to"]) * FPS, edge["frame_count"])
                      for edge in segment.get("encoded_edges", [])]
            self.assertEqual(actual, [(start, end, end-start) for start, end in expected])
        total = sum(end - start for start, end in ranges)
        self.assertEqual(ratio(dry["duration"]), Fraction(total, FPS))
        self.assertEqual(self.export(output, requests)["segments"], dry["segments"])

        sequence = [i for start, end in ranges for i in range(start, end)]
        self.assertEqual(picture_ids(output), bytes(sequence), "wrong frame order or trim endpoint")
        native = picture_ids(output, hardware_av1=True) if codec == "av1" else run(
            [self.fixtures / "DecodeFrameIDs", output])
        self.assertEqual(native, bytes(sequence), "native playback lost pictures at a splice")
        if codec != "av1":
            # Enter both the copied run and the encoded tail at a seek point.
            for offset in [total // 2, total - 3]:
                seeked = run([self.fixtures / "DecodeFrameIDs", output, str(offset)])
                self.assertEqual(seeked, bytes(sequence[offset:]), f"native seek at picture {offset}")
        self.assertEqual(sorted(t for t, _ in timestamped_hashes(output)),
                         [Fraction(i, FPS) for i in range(total)], "presentation timestamps moved")
        self.assertEqual(Fraction(probe(output, "-show_format")["format"]["duration"]), Fraction(total, FPS))
        src_frames, dst_frames = frames(source), frames(output)
        src_packets, dst_packets = dict(timestamped_hashes(source)), dict(timestamped_hashes(output))
        if codec in ("h264", "hevc"):
            src_vcl, dst_vcl = vcl_hashes(source, codec), vcl_hashes(output, codec)
        stream_keys = ["codec_name", "width", "height", "pix_fmt", "color_range", "color_space",
                       "color_transfer", "color_primaries"]
        metadata = [probe(path, "-select_streams", "v:0", "-show_streams")["streams"][0]
                    for path in [source, output]]
        for field in stream_keys:
            self.assertEqual(metadata[0].get(field), metadata[1].get(field), field)
        out_index = 0
        for (start, end), encoded in zip(ranges, edges, strict=True):
            for index in range(start, end):
                if all(index < lo or index >= hi for lo, hi in encoded):
                    self.assertEqual(dst_frames[out_index], src_frames[index], f"copied picture {index}")
                    src_t, dst_t = Fraction(index, FPS), Fraction(out_index, FPS)
                    if codec == "av1" or all(index != hi for _, hi in encoded) and index != start:
                        self.assertEqual(dst_packets[dst_t], src_packets[src_t], f"copied packet {index}")
                    else:
                        self.assertEqual(dst_vcl[dst_t], src_vcl[src_t], f"copied slices {index}")
                out_index += 1
        source_audio = set(sample_hashes(source, "a:0"))
        self.assertTrue(set(sample_hashes(output, "a:0")) <= source_audio, "audio payload changed")
        decode_audio = audio if codec == "av1" else lambda p: run([self.fixtures / "DecodeAudio", p])
        pcm = decode_audio(source)
        expected = b"".join(pcm[2*start*SAMPLE_RATE//FPS:2*end*SAMPLE_RATE//FPS] for start, end in ranges)
        decoded = decode_audio(output)
        self.assertEqual(len(decoded), len(expected), "audible duration changed")
        self.assertTrue(decoded == expected, "decoded audio changed or shifted")

    def test_edges_for_each_codec(self):
        for codec in self.sources:
            with self.subTest(codec=codec):
                # Picture 87 follows a B picture that is coded after it, so no copy can stop there.
                # Reordered H.264 and HEVC copy up to the last point before it where the decode
                # order is split, 84. AV1 copies up to the keyframe at 75.
                tail = (75, 87) if codec == "av1" else (84, 87)
                self.check_trim(codec, [(7, 87)], [[(7, 25), tail]])

    def test_edge_bitrate_uses_surrounding_source_video_packets(self):
        for codec, source in self.sources.items():
            with self.subTest(codec=codec):
                packets = probe(source, "-select_streams", "v:0", "-show_packets",
                                "-show_entries", "packet=pts_time,size")["packets"]
                report = self.export(self.root / ("rate" + source.suffix), [(source, 7, 87)], dry=True)
                for edge, second in zip(report["segments"][0]["encoded_edges"], [0, 3], strict=True):
                    # These fixtures have one-second closed GOPs and a separate audio track.
                    size = sum(int(p["size"]) for p in packets if second <= Fraction(p["pts_time"]) < second + 1)
                    self.assertEqual(edge["target_bit_rate"], size * 8)

    def test_low_bitrate_av1_trim_stays_smaller_than_the_source(self):
        source = self.root / "low-bitrate.webm"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=9",
               "-c:v", "libsvtav1", "-preset", "8", "-crf", "48", "-g", "50",
               "-svtav1-params", "lp=2", source, allow_diagnostics=True)
        output = self.root / "trim.webm"
        report = self.export(output, [(source, 10, 190)])
        self.assertEqual([edge["frame_count"] for edge in report["segments"][0]["encoded_edges"]], [40, 40])
        self.assertLess(output.stat().st_size, source.stat().st_size)

    def test_only_the_unsafe_end_is_encoded(self):
        self.check_trim("h264", [(0, 87)], [[(84, 87)]])
        self.check_trim("h264", [(7, 125)], [[(7, 25)]])

    def test_h264_reordered_join_and_short_same_gop_range(self):
        # The first range copies 50 to 84 and encodes the two pictures after that end point.
        # The second has no start-safe keyframe, so all of it is encoded.
        self.check_trim("h264", [(35, 86), (5, 13)], [[(35, 50), (84, 86)], [(5, 13)]])

    def test_lossless_default_and_aligned_smart_range(self):
        src = self.sources["av1"]
        rejected = self.export(self.root / "lossless.webm", [(src, 7, 88)], smart=False, ok=False)
        self.assertEqual(rejected["error"]["code"], "unsafe_boundary")
        self.check_trim("av1", [(25, 75)], [[]])

    def end_points(self, source):
        info = json.loads(run([CLI, "media", "inspect", "--json", "--frames", source]))
        self.assertEqual(len(info["media"]["frames"]), 5 * FPS)
        return [index for index, picture in enumerate(info["media"]["frames"]) if picture["can_end"]]

    def test_presentation_ordered_pictures_end_a_copy_at_every_picture(self):
        # Without B pictures each packet depends only on earlier packets, so a copy can stop before any picture.
        self.sources = {codec: movie(self.root / ("ordered-" + codec + ext), codec, bframes=0)
                        for codec, ext in [("h264", ".mp4"), ("hevc", ".mov")]}
        ranges = [(0, 88), (25, 37), (75, 99), (50, 51)]
        for codec, source in self.sources.items():
            with self.subTest(codec=codec):
                self.assertEqual(self.end_points(source), list(range(5 * FPS)))
                # Every range starts on a keyframe and ends inside a picture group. Nothing is encoded.
                self.check_trim(codec, ranges, [[]] * len(ranges))
                smart = self.root / (codec + "-" + "-".join(f"{a}-{b}" for a, b in ranges) + source.suffix)
                copy = self.root / ("copy-" + codec + source.suffix)
                requests = [(source, start, end) for start, end in ranges]
                for report in [self.export(copy, requests, smart=False, dry=True), self.export(copy, requests, smart=False)]:
                    self.assertEqual(ratio(report["encoded_duration"]), 0)
                    self.assertEqual(report["copied_duration"], report["duration"])
                self.assertEqual(timestamped_hashes(copy), timestamped_hashes(smart))
                # The start of a copy still needs a keyframe. Smart Trim encodes up to the next one only.
                refused = self.export(self.root / ("refused" + source.suffix), [(source, 7, 88)], smart=False, ok=False)
                self.assertEqual((refused["error"]["boundary"], refused["error"]["reason"]), ("from", "cut_video_start"))
                self.check_trim(codec, [(7, 88)], [[(7, 25)]])

    def test_reordered_pictures_end_a_copy_where_decode_order_is_split_and_hidden_ones_at_keyframes(self):
        # A reordered H.264 or HEVC copy can stop wherever every earlier packet also presents earlier.
        # A B picture coded after the cut would otherwise be kept without the picture it predicts from.
        # An AV1 packet can carry a picture that is shown later, so AV1 stops at keyframes only.
        for codec, source in self.sources.items():
            with self.subTest(codec=codec):
                if codec == "av1":
                    self.assertEqual(self.end_points(source), list(range(0, 5 * FPS, FPS)))
                    unsafe = 88
                else:
                    ends = partition_ends(source)
                    # Three B pictures between anchors: after the keyframe alone, then every fourth picture.
                    self.assertEqual(ends[:8], [0, 1, 5, 9, 13, 17, 21, 25])
                    self.assertEqual(self.end_points(source), ends)
                    unsafe = 87
                rejected = self.export(self.root / ("end" + source.suffix), [(source, 0, unsafe)], smart=False, ok=False)
                self.assertEqual((rejected["error"]["boundary"], rejected["error"]["reason"]), ("to", "cut_video_end"))
                if codec != "av1":
                    self.assertEqual([ratio(time) * FPS for time in rejected["error"]["nearest"]], [84, 88])

    def test_lossless_copy_joins_ranges_that_end_inside_picture_groups(self):
        # Every range starts on a keyframe and ends inside a picture group, out of source order: the
        # keyframe alone, a range that crosses a keyframe, and ends early and late in a group.
        ordered = {codec: movie(self.root / ("ordered-" + codec + ext), codec, bframes=0)
                   for codec, ext in [("h264", ".mp4"), ("hevc", ".mov")]}
        cases = [(codec, source, [(50, 62), (0, 20), (75, 76), (25, 57)]) for codec, source in ordered.items()]
        cases += [(codec, self.sources[codec], [(50, 63), (0, 21), (75, 76), (25, 55)]) for codec in ("h264", "hevc")]
        for codec, source, ranges in cases:
            with self.subTest(codec=codec, source=source.name):
                ends = partition_ends(source)
                for start, end in ranges:
                    self.assertEqual(start % FPS, 0)
                    self.assertNotEqual(end % FPS, 0, "the range must end inside a picture group")
                    self.assertIn(end, ends)
                output = self.root / ("lossless-" + source.name)
                requests = [(source, start, end) for start, end in ranges]
                dry = self.export(output, requests, smart=False, dry=True)
                report = self.export(output, requests, smart=False)
                self.assertEqual(report["segments"], dry["segments"])
                self.assertEqual(report["mode"], "copy")
                self.assertEqual(ratio(report["encoded_duration"]), 0)
                self.assertEqual(report["copied_duration"], report["duration"])
                self.assertFalse(any(segment.get("encoded_edges") for segment in report["segments"]))
                sequence = [index for start, end in ranges for index in range(start, end)]
                self.assertEqual(ratio(report["duration"]), Fraction(len(sequence), FPS))
                # Every video packet is the source packet, byte for byte, at its place on the new timeline.
                source_packets, output_packets = dict(timestamped_hashes(source)), dict(timestamped_hashes(output))
                self.assertEqual(len(timestamped_hashes(output)), len(sequence))
                self.assertEqual(output_packets, {Fraction(position, FPS): source_packets[Fraction(index, FPS)]
                                                  for position, index in enumerate(sequence)})
                self.assertEqual(Fraction(probe(output, "-show_format")["format"]["duration"]),
                                 Fraction(len(sequence), FPS))
                # Each decoder returns exactly the source's own pictures, including those before each join.
                source_frames, source_hardware = frames(source), hardware_frames(source)
                self.assertEqual(len(source_hardware), 5 * FPS)
                self.assertEqual(frames(output), [source_frames[index] for index in sequence])
                self.assertEqual(hardware_frames(output), [source_hardware[index] for index in sequence])
                self.assertEqual(picture_ids(output), bytes(sequence))
                self.assertEqual(run([self.fixtures / "DecodeFrameIDs", output]), bytes(sequence))

    def test_adjacent_source_ranges_copy_through_a_nonkeyframe_seam(self):
        for codec in ["av1", "h264"]:
            with self.subTest(codec=codec):
                source = self.sources[codec]
                output = self.root / ("continuous-" + codec + source.suffix)
                report = self.export(output, [(source, 25, 53), (source, 53, 75)])
                self.assertEqual(len(report["segments"]), 1)
                self.assertFalse(report["segments"][0].get("encoded_edges"))
                expected = {t - 1: data for t, data in timestamped_hashes(source) if 1 <= t < 3}
                self.assertEqual(dict(timestamped_hashes(output)), expected)
                self.assertEqual(picture_ids(output), bytes(range(25, 75)))

    def test_variable_frame_durations_survive_splice(self):
        source = self.root / "vfr.mp4"
        output = self.root / "vfr-trim.mp4"
        ffmpeg("-i", self.sources["h264"], "-an", "-vf", "settb=1/25,setpts='N+floor(N/9)'", "-fps_mode", "passthrough",
               "-enc_time_base", "1/25", "-c:v", "libx264", "-threads", "1",
               "-x264-params", "keyint=25:min-keyint=25:scenecut=0:open-gop=0:bframes=3", source)
        timestamps = sorted(dict(timestamped_hashes(source)))
        self.assertGreater(len(set(b-a for a, b in zip(timestamps, timestamps[1:]))), 1)
        # The decode order is split inside every picture group, but a copy of this source ends on keyframes
        # only. MOV times a track by decode intervals, and after a held picture the decode clock of a
        # prefix that stops inside a group ends before its presentation does.
        self.assertGreater(len(partition_ends(source)), 5)
        self.assertEqual(self.end_points(source), list(range(0, 5 * FPS, FPS)))
        start, end = timestamps[6], timestamps[88]
        self.export(output, [(source, start * FPS, end * FPS)])
        self.assertEqual(sorted(dict(timestamped_hashes(output))), [t - start for t in timestamps[6:88]])
        self.assertEqual(picture_ids(output), bytes(range(6, 88)))
        self.assertEqual(run([self.fixtures / "DecodeFrameIDs", output]), bytes(range(6, 88)))

    def test_reopen_and_copy_mixed_sample_descriptions(self):
        for codec in ["h264", "hevc"]:
            with self.subTest(codec=codec):
                source = self.sources[codec]
                mixed = self.root / ("mixed-" + codec + source.suffix)
                plan = self.export(mixed, [(source, 7, 87)])
                # The tail is encoded from picture 84, the last end point before 87.
                self.assertEqual([(ratio(edge["from"]) * FPS, ratio(edge["to"]) * FPS)
                                  for edge in plan["segments"][0]["encoded_edges"]], [(7, 25), (84, 87)])
                info = json.loads(run([CLI, "media", "inspect", "--json", "--keyframes", mixed]))
                self.assertTrue(info["ok"], info)
                self.assertFalse(info["media"].get("copy_issue"), info.get("copy"))
                # Start at each description: head encoder, original camera, tail encoder.
                for offset in [0, 18, 77]:
                    reopened = self.root / (f"reopen-{codec}-{offset}" + source.suffix)
                    result = self.export(reopened, [(mixed, offset, 80)], smart=False)
                    self.assertFalse(result["segments"][0].get("encoded_edges"))
                    self.assertEqual(run([self.fixtures / "DecodeFrameIDs", reopened]), bytes(range(7 + offset, 87)))
                    expected = {t - Fraction(offset, FPS): data for t, data in timestamped_hashes(mixed)
                                if t >= Fraction(offset, FPS)}
                    self.assertEqual(dict(timestamped_hashes(reopened)), expected, "re-open changed picture packets")

    def test_main10_hevc_smart_edges_keep_the_source_profile_and_frame_order(self):
        source = movie(self.root / "main10.mov", "hevc", pixel_format="yuv420p10le")
        self.sources = {**self.sources, "hevc": source}
        self.check_trim("hevc", [(7, 87)], [[(7, 25), (84, 87)]])
        output = self.root / "hevc-7-87.mov"
        pictures = probe(output, "-select_streams", "v:0", "-show_frames",
                         "-show_entries", "frame=pix_fmt")["frames"]
        self.assertEqual([picture["pix_fmt"] for picture in pictures], ["yuv420p10le"] * 80)

    def test_hevc_bottom_padding_change_decodes_seeks_and_reopens(self):
        source = movie(self.root / "unpadded-hevc.mov", "hevc", width=640, height=360)
        output = self.root / "cut.mov"
        plan = self.export(output, [(source, 7, 87)])
        # Both encoded runs change the padding: the head before picture 25 and the tail from picture 84.
        self.assertEqual([(ratio(edge["from"]) * FPS, ratio(edge["to"]) * FPS)
                          for edge in plan["segments"][0]["encoded_edges"]], [(7, 25), (84, 87)])
        sequence = bytes(range(7, 87))
        for offset in (0, 18, 77):
            self.assertEqual(run([self.fixtures / "DecodeFrameIDs", output, str(offset)]), sequence[offset:])
        # Independently decoded copied pictures retain all visible luma and chroma.
        self.assertEqual(frames(output)[18:77], frames(source)[25:84])
        reopened = self.root / "reopened.mov"
        self.export(reopened, [(output, 18, 80)], smart=False)
        self.assertEqual(run([self.fixtures / "DecodeFrameIDs", reopened]), sequence[18:])

    def test_hardware_splices_keep_independent_starts_and_copied_keyframes(self):
        for codec in ("h264", "hevc"):
            with self.subTest(codec=codec):
                source = self.sources[codec]
                output = self.root / (codec + source.suffix)
                self.export(output, [(source, 7, 87)])
                packets = probe(output, "-select_streams", "v:0", "-show_packets",
                                "-show_entries", "packet=pts_time,flags")["packets"]
                keys = sorted(Fraction(p["pts_time"]) * FPS for p in packets if "K" in p["flags"])
                self.assertIn(0, keys)
                # The copied run keeps its three source keyframes. The encoded tail starts its own at picture 84.
                self.assertEqual([key for key in keys if 18 <= key < 77], [18, 43, 68])
                self.assertIn(77, keys)

    def test_hardware_edges_avoid_periodic_keyframes_inside_short_gops(self):
        for codec in ("h264", "hevc"):
            with self.subTest(codec=codec):
                source = self.root / f"still-{codec}.mp4"
                gop = "keyint=100:min-keyint=100:scenecut=0:open-gop=0"
                settings = (["-c:v", "libx264", "-x264-params", gop] if codec == "h264" else
                            ["-c:v", "libx265", "-x265-params", gop + ":pools=1:log-level=error", "-tag:v", "hvc1"])
                ffmpeg("-f", "lavfi", "-i", "smptebars=size=320x96:rate=25:duration=4",
                       "-threads", "1", *settings, source, allow_diagnostics=True)
                output = self.root / f"edge-{codec}.mp4"
                plan = self.export(output, [(source, 5, 75)])
                self.assertEqual([edge["frame_count"] for edge in plan["segments"][0]["encoded_edges"]], [70])
                packets = probe(output, "-select_streams", "v:0", "-show_packets",
                                "-show_entries", "packet=pts_time,flags")["packets"]
                self.assertEqual(len(packets), 70)
                keys = sorted(Fraction(packet["pts_time"]) * FPS for packet in packets if "K" in packet["flags"])
                self.assertEqual(keys[0], 0)
                # VideoToolbox may independently add a sync frame. A forced interval
                # of 12 would cap every run at 12, even on this unchanging picture.
                self.assertGreater(max(b - a for a, b in zip(keys, keys[1:] + [70])), 12, keys)

    def test_avc_coded_width_change_is_native_playable_or_rejected(self):
        # Some VideoToolbox encoders pad 160px AVC to a 192px coded picture.
        # FFmpeg decodes such a mixed stream even when AVFoundation cannot.
        source = movie(self.root / "narrow.mp4", "h264", width=160)
        output = self.root / "narrow-cut.mp4"
        process = subprocess.run([CLI, "export", "clips", "join", "--json", "--mode", "smart", "--clip", source,
                                  "--from", "7/25", "--to", "88/25", "--output", output],
                                 capture_output=True, text=True, timeout=60)
        report = json.loads(process.stdout)
        if process.returncode == 0:
            self.assertTrue(report["ok"])
            self.assertEqual(run([self.fixtures / "DecodeFrameIDs", output]), bytes(range(7, 88)))
        else:
            # Narrow AVC is ineligible for an encoded edge, so the request falls
            # back to copy boundaries: frame 7 is refused with both neighbours.
            self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
            self.assertIs(report["ok"], False, report)
            error = report["error"]
            self.assertEqual((error["code"], error["boundary"], error["segment"]),
                             ("unsafe_boundary", "from", 1), report)
            self.assertEqual([Fraction(t["numerator"], t["denominator"]) for t in error["nearest"]], [0, 1], report)
            self.assertFalse(output.exists())
            self.assertFalse(any(self.root.glob(".mpcut-*")))

    def test_mismatched_source_rejected_before_export(self):
        for name, settings in [("size", {"width": 192}), ("transfer", {"transfer": "smpte170m"})]:
            with self.subTest(name=name):
                other = movie(self.root / (name + ".mp4"), "h264", **settings)
                report = self.export(self.root / "joined.mp4", [(self.sources["h264"], 7, 88), (other, 5, 35)],
                                     dry=True, ok=False)
                self.assertEqual(report["error"]["code"], "incompatible_clip")

    def test_cancel_during_staging(self):
        output = self.root / "cancel.webm"
        command = [CLI, "export", "clips", "join", "--json", "--mode", "smart", "--clip", self.sources["av1"],
                   "--from", "7/25", "--to", "88/25", "--output", output]
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
            try:
                deadline = time.monotonic() + 15
                while child.poll() is None and time.monotonic() < deadline:
                    if any(self.root.glob(".mpcut-*")):
                        child.send_signal(signal.SIGINT)
                        break
                    time.sleep(0.001)
                else:
                    self.fail("no staged export observed")
                stdout, stderr = child.communicate(timeout=30)
            finally:
                if child.poll() is None:
                    child.kill()
            self.assertEqual(child.returncode, 130, stdout + stderr)
            self.assertEqual(json.loads(stdout)["error"]["code"], "cancelled")
        self.assertEqual(list(self.root.iterdir()), [])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = str(args.mpcut.resolve(strict=True))
    unittest.main(argv=[__file__, *tests])
