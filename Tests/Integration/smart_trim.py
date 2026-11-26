#!/usr/bin/env python3
"""Check Smart Trim with generated camera-style GOPs and individually numbered pictures."""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re
import shutil
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
    # Keep the container's own clock. FFmpeg otherwise times a variable-rate Matroska track by its
    # average rate (3125/142 for 25 fps with held pictures), and adjacent pictures share a tick.
    data = ffmpeg(*decoder, "-i", path, "-map", "0:v:0", "-vf", ",".join(filters),
                  "-fps_mode", "passthrough", "-enc_time_base", "demux", "-pix_fmt", "gray", "-f", "rawvideo", "-")
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


# SEI messages (payload type, payload) for with_h264_sei. Closed captions: an ATSC A/53 cc_data T.35 payload with two
# caption constructs. Film grain characteristics: a frequency-filtering luma model (scale 60) that repeats.
CAPTION_SEI = (4, b"\xb5\x00\x31GA94\x03\xc2\xff\xfc\x94\x20\xfc\x94\x2c\xff")
FILM_GRAIN_SEI = (19, bytes.fromhex("00a00200ff03c04020a0"))


def with_h264_sei(source, output, sei, fps=FPS, timescale=None):
    """Copy an avc1 movie without reordered pictures, adding one SEI message before the first slice of every picture."""
    payload_type, payload = sei
    stream = ffmpeg("-i", source, "-map", "0:v:0", "-c", "copy", "-bsf:v", "h264_mp4toannexb", "-f", "h264", "-")
    rbsp = re.sub(rb"\x00\x00(?=[\x00-\x03])", lambda match: match[0] + b"\x03",
                  bytes((payload_type, len(payload))) + payload + b"\x80")
    edited = bytearray()
    position = 0
    for match in re.finditer(rb"\x00\x00\x01[\x01\x05\x21\x25\x41\x45\x61\x65]", stream):
        start = match.start()
        if stream[start + 4] & 0x80:  # first_mb_in_slice is 0: the first slice of a picture.
            cut = start - 1 if start and stream[start - 1] == 0 else start
            edited += stream[position:cut] + b"\x00\x00\x00\x01\x06" + rbsp
            position = cut
    edited += stream[position:]
    raw = output.with_suffix(".264")
    raw.write_bytes(edited)
    clock = ["-video_track_timescale", str(timescale)] if timescale else []
    ffmpeg("-r", str(fps), "-f", "h264", "-i", raw, "-i", source, "-map", "0:v:0", "-map", "1:a?", "-c", "copy",
           "-tag:v", "avc1", *clock, output)
    return output


def film_grain_note(source):
    """The plan and export warning for Smart Trim edges in a source whose pictures carry film grain parameters."""
    return (f"The pictures Smart Trim re-encodes in {Path(source).name} carry no film grain parameters, "
            "so a player that synthesizes film grain adds none to them.")


def grain_pictures(path):
    """Whether each picture, in presentation order, asks the decoder to synthesize film grain."""
    report = probe(path, "-export_side_data", "film_grain", "-select_streams", "v:0", "-show_frames",
                   "-show_entries", "frame=pts:frame_side_data=side_data_type")
    return [any(item.get("side_data_type") == "Film grain parameters" for item in frame.get("side_data_list", []))
            for frame in sorted(report["frames"], key=lambda frame: int(frame["pts"]))]


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
                # order is split, 84. AV1 copies up to 76: the keyframe's temporal unit at 75
                # codes no hidden picture, and the unit at 76 codes hidden pictures shown at 91.
                tail = (76, 87) if codec == "av1" else (84, 87)
                self.check_trim(codec, [(7, 87)], [[(7, 25), tail]])

    def test_edge_bitrate_uses_surrounding_source_video_packets(self):
        for codec, source in self.sources.items():
            with self.subTest(codec=codec):
                packets = probe(source, "-select_streams", "v:0", "-show_packets",
                                "-show_entries", "packet=pts_time,size")["packets"]
                report = self.export(self.root / ("rate" + source.suffix), [(source, 7, 87)], dry=True)
                for edge, second in zip(report["segments"][0]["encoded_edges"], [0, 3], strict=True):
                    # These fixtures have one-second closed GOPs and a separate audio track.
                    group = [(Fraction(p["pts_time"]), int(p["size"])) for p in packets
                             if second <= Fraction(p["pts_time"]) < second + 1]
                    size = sum(n for _, n in group)
                    expected = Fraction(size * 8)
                    # Where the average picture is under half the keyframe, the edge gets at least the
                    # keyframe's bytes and the source bytes of its later pictures over its own duration.
                    keyframe = next(n for time, n in group if time == second)
                    start, end = ratio(edge["from"]), ratio(edge["to"])
                    if 2 * size < keyframe * len(group):
                        later = sum(n for time, n in group if start < time < end)
                        expected = max(expected, (keyframe + later) * 8 / (end - start))
                    self.assertEqual(edge["target_bit_rate"], int(expected + Fraction(1, 2)))

    def test_held_still_edge_gets_the_source_keyframe_bytes(self):
        # The group's average rate gave a one-picture edge of a held still 39 dB (H.264) or 40 dB (HEVC)
        # against the source. With the source keyframe's bytes it measured 50 and 51 dB.
        fixtures = {
            "h264": ("still.mp4", ["-c:v", "libx264", "-crf", "18",
                                   "-x264-params", "keyint=25:min-keyint=25:scenecut=0:bframes=0"]),
            "hevc": ("still.mov", ["-c:v", "libx265", "-crf", "20", "-tag:v", "hvc1", "-x265-params",
                                   "keyint=25:min-keyint=25:scenecut=0:bframes=0:open-gop=0:log-level=error"]),
        }
        for codec, (name, settings) in fixtures.items():
            with self.subTest(codec=codec):
                source = self.root / name
                ffmpeg("-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=1",
                       "-vf", "trim=end_frame=1,loop=loop=99:size=1:start=0,setpts=N/25/TB",
                       *settings, "-pix_fmt", "yuv420p", source, allow_diagnostics=True)
                sizes = [int(p["size"]) for p in sorted(
                    probe(source, "-select_streams", "v:0", "-show_packets", "-show_entries", "packet=pts,size")["packets"],
                    key=lambda p: int(p["pts"]))]
                output = self.root / ("trimmed-" + name)
                plan = self.export(output, [(source, 24, 50)], dry=True)
                edges = plan["segments"][0]["encoded_edges"]
                self.assertEqual([edge["frame_count"] for edge in edges], [1])
                self.assertLess(4 * sum(sizes[:25]), 25 * sizes[0], "the fixture is not a held still")
                self.assertEqual(edges[0]["target_bit_rate"], sizes[0] * 8 * FPS)
                result = self.export(output, [(source, 24, 50)])
                self.assertEqual(result["segments"], plan["segments"])
                stats = ffmpeg("-i", output, "-i", source, "-filter_complex",
                               "[0:v]trim=end_frame=1,setpts=PTS-STARTPTS[e];"
                               "[1:v]trim=start_frame=24:end_frame=25,setpts=PTS-STARTPTS[s];[e][s]psnr=stats_file=-",
                               "-f", "null", "-").decode()
                self.assertGreaterEqual(float(stats.split("psnr_avg:")[1].split()[0]), 45, stats)

    def test_plan_reports_the_in_band_parameter_set_refusal(self):
        # avc3 samples that carry SPS and PPS cannot be copied into the avc1 track a splice writes.
        stream = self.root / "inband.ts"
        ffmpeg("-f", "lavfi", "-i", f"testsrc2=s=640x360:r={FPS}:d=4", "-c:v", "libx264", "-bf", "0", "-g", "25",
               "-pix_fmt", "yuv420p", "-bsf:v", "h264_mp4toannexb", "-f", "mpegts", stream, allow_diagnostics=True)
        source = self.root / "inband-avc3.mp4"
        ffmpeg("-i", stream, "-c", "copy", "-tag:v", "avc3", source)
        output = self.root / "inband-out.mp4"
        for dry in [True, False]:
            with self.subTest(dry=dry):
                report = self.export(self.root / "refused.mp4", [(source, 7, 75)], dry=dry, ok=False)
                error = report["error"]
                self.assertEqual((error["code"], error["reason"], error["segment"]),
                                 ("unsupported_format", "source_smart_ineligible", 1), report)
                self.assertIn("in-band parameter sets", error["message"])
        # A range that is all edge copies no source sample, so it is written.
        plan = self.export(output, [(source, 7, 20)], dry=True)
        self.assertEqual([edge["frame_count"] for edge in plan["segments"][0]["encoded_edges"]], [13])
        self.assertEqual(self.export(output, [(source, 7, 20)])["segments"], plan["segments"])
        self.assertEqual(len(frames(output)), 13)

    def test_plan_reports_edge_metadata_and_keeps_it_on_copied_pictures(self):
        # Mastering display and light level SEI start at the second picture group, the first IDR
        # that carries them. libavcodec attaches them to every picture of that coded sequence.
        settings = "keyint=25:min-keyint=25:open-gop=0:bframes=0:log-level=error:repeat-headers=1"
        hdr = ":master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"
        parts = []
        for name, start, extra in [("plain.hevc", 0, ""), ("hdr.hevc", 1, hdr)]:
            parts.append(self.root / name)
            ffmpeg("-f", "lavfi", "-i", f"testsrc2=s=640x360:r={FPS}:d=3",
                   "-vf", f"trim=start={start}:duration={1 if start == 0 else 2},setpts=PTS-STARTPTS",
                   "-c:v", "libx265", "-pix_fmt", "yuv420p", "-x265-params", settings + extra, "-f", "hevc", parts[-1],
                   allow_diagnostics=True)
        joined = self.root / "late-hdr.hevc"
        joined.write_bytes(b"".join(part.read_bytes() for part in parts))
        source = self.root / "late-hdr.mp4"
        ffmpeg("-r", str(FPS), "-i", joined, "-c", "copy", "-tag:v", "hvc1", source)

        def mastering(path):
            report = probe(path, "-select_streams", "v:0", "-show_frames", "-show_entries", "frame=pts:frame_side_data=side_data_type")
            return [any(item.get("side_data_type") == "Mastering display metadata" for item in frame.get("side_data_list", []))
                    for frame in report["frames"]]

        self.assertEqual(mastering(source), [False] * 25 + [True] * 50)
        output = self.root / "late-hdr-out.mp4"
        # The edge pictures 7-24 carry no metadata. The copied pictures after them keep theirs.
        plan = self.export(output, [(source, 7, 50)], dry=True)
        self.assertEqual([edge["frame_count"] for edge in plan["segments"][0]["encoded_edges"]], [18])
        self.assertEqual(self.export(output, [(source, 7, 50)])["segments"], plan["segments"])
        self.assertEqual(mastering(output), [False] * 18 + [True] * 25)
        for start, end in [(32, 50), (7, 33)]:
            for dry in [True, False]:
                with self.subTest(start=start, end=end, dry=dry):
                    refused = self.root / f"refused-{start}-{end}.mp4"
                    report = self.export(refused, [(source, start, end)], dry=dry, ok=False)
                    error = report["error"]
                    self.assertEqual((error["code"], error["reason"]), ("unsupported_format", "source_smart_ineligible"))
                    self.assertIn("captions or colour metadata", error["message"])

    def test_plan_warns_that_edges_lose_film_grain(self):
        # A re-encoded edge carries no film grain parameters, so a player synthesizes no grain on it. VideoToolbox
        # ignores H.274 grain SEI, and applies AV1 grain, which an inter edge picture's bit budget mostly smooths
        # away. Refusing would leave a full re-encode, which loses the grain everywhere, so the export writes the
        # edges and both reports say what they lose.
        av1 = self.root / "grain.webm"
        plain_av1 = self.root / "plain.webm"
        for path, params in [(av1, "lp=2:film-grain=30:film-grain-denoise=1"), (plain_av1, "lp=2")]:
            ffmpeg("-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=6", "-vf", "noise=alls=20:allf=t",
                   "-c:v", "libsvtav1", "-preset", "8", "-crf", "40", "-g", "50", "-svtav1-params", params, path,
                   allow_diagnostics=True)
        plain_avc = movie(self.root / "plain.mp4", "h264", bframes=0)
        avc = with_h264_sei(plain_avc, self.root / "grain.mp4", FILM_GRAIN_SEI)
        cases = [(av1, (49, 110), [1, 9]), (plain_av1, (49, 110), [1, 9]),
                 (avc, (7, 75), [18]), (plain_avc, (7, 75), [18])]
        for source, (start, end), counts in cases:
            with self.subTest(source=source.name):
                grain = source in (av1, avc)
                self.assertEqual(set(grain_pictures(source)), {grain})
                output = self.root / ("trimmed-" + source.name)
                plan = self.export(output, [(source, start, end)], dry=True)
                edges = plan["segments"][0]["encoded_edges"]
                self.assertEqual([edge["frame_count"] for edge in edges], counts)
                result = self.export(output, [(source, start, end)])
                self.assertEqual(result["segments"], plan["segments"])
                for report in (plan, result):
                    self.assertEqual(film_grain_note(source) in report.get("warnings", []), grain, report)
                if grain:
                    # Copied pictures keep their grain parameters. Edge pictures have none.
                    def encoded(picture):
                        return any(ratio(edge["from"]) <= Fraction(picture, FPS) < ratio(edge["to"]) for edge in edges)
                    self.assertEqual(grain_pictures(output), [not encoded(picture) for picture in range(start, end)])

    def test_low_bitrate_av1_trim_stays_smaller_than_the_source(self):
        source = self.root / "low-bitrate.webm"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=9",
               "-c:v", "libsvtav1", "-preset", "8", "-crf", "48", "-g", "50",
               "-svtav1-params", "lp=2", source, allow_diagnostics=True)
        output = self.root / "trim.webm"
        report = self.export(output, [(source, 10, 190)])
        # The copy ends at 183, where every hidden picture of the mini-GOP from 167 has been shown.
        self.assertEqual([edge["frame_count"] for edge in report["segments"][0]["encoded_edges"]], [40, 7])
        self.assertLess(output.stat().st_size, source.stat().st_size)

    def test_export_reports_what_each_edge_wrote(self):
        source = self.root / "low-bitrate.webm"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=6",
               "-c:v", "libsvtav1", "-preset", "8", "-crf", "48", "-g", "50",
               "-svtav1-params", "lp=2", source, allow_diagnostics=True)
        output = self.root / "edges.webm"
        # A one-picture head edge, copied pictures, then a nine-picture tail edge after the
        # keyframe's temporal unit at 100, which codes no hidden picture.
        plan = self.export(output, [(source, 49, 110)], dry=True)
        self.assertNotIn("encoded_edge_results", plan)
        result = self.export(output, [(source, 49, 110)])
        self.assertEqual(result["segments"], plan["segments"])
        edges = plan["segments"][0]["encoded_edges"]
        self.assertEqual([edge["frame_count"] for edge in edges], [1, 9])
        written = result["encoded_edge_results"]
        self.assertEqual([(item["segment"], item["from"], item["to"]) for item in written],
                         [(1, edge["from"], edge["to"]) for edge in edges])
        packets = probe(output, "-select_streams", "v:0", "-show_packets", "-show_entries", "packet=pts_time,size")["packets"]
        for edge, item in zip(edges, written):
            start = ratio(edge["from"]) - Fraction(49, FPS)
            end = ratio(edge["to"]) - Fraction(49, FPS)
            # The encoder's count includes a two-byte temporal delimiter per picture, which Matroska drops.
            muxed = sum(int(p["size"]) for p in packets if start <= Fraction(p["pts_time"]) < end)
            self.assertTrue(0 <= item["encoded_bytes"] - muxed <= 2 * edge["frame_count"], (item, muxed))
            # The encoder computes the budget in long double, so allow its last byte to round either way.
            self.assertLessEqual(abs(item["target_bytes"] - (end - start) * edge["target_bit_rate"] / 8), 1)
            self.assertEqual("first_attempt_bytes" in item, item["retried"])
            self.assertIn(item["max_qp"], [44, 56])
        # The QP ceiling does not bind a keyframe, so a one-picture edge is never encoded twice.
        self.assertEqual((written[0]["retried"], written[0]["max_qp"]), (False, 44))

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

    def test_reordered_pictures_end_a_copy_where_decode_order_is_split_and_hidden_ones_once_shown(self):
        # A reordered H.264 or HEVC copy can stop wherever every earlier packet also presents earlier.
        # A B picture coded after the cut would otherwise be kept without the picture it predicts from.
        # An AV1 temporal unit can code pictures that a later unit shows, so AV1 stops where every
        # picture coded since the keyframe has been shown: after the keyframe's own unit, and at the
        # end of each mini-GOP of SVT-AV1's random-access structure (16 pictures, 8 before a keyframe).
        for codec, source in self.sources.items():
            with self.subTest(codec=codec):
                if codec == "av1":
                    ends = sorted({0, 1, 17} | {key + offset for key in range(FPS, 5 * FPS, FPS) for offset in (0, 1, 17)})
                    self.assertEqual(self.end_points(source), [end for end in ends if end < 5 * FPS])
                    for start, end in [(0, 17), (25, 42), (50, 51)]:
                        copy = self.root / f"av1-{start}-{end}.webm"
                        self.export(copy, [(source, start, end)], smart=False)
                        self.assertEqual(frames(copy), frames(source)[start:end])
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

    def test_vp8_and_vp9_copies_end_where_no_hidden_picture_is_kept(self):
        # One-pass realtime libvpx codes no hidden picture, so a copy can stop before any picture.
        # Two-pass libvpx codes an alternate reference that is never shown in each group of pictures:
        # a copy then stops only before it, so that no picture of a later presentation is kept.
        passes = self.root / "passes"
        source_input = ["-f", "lavfi", "-i", f"testsrc2=s=320x180:r={FPS}:d=5"]
        realtime = ["-deadline", "realtime", "-cpu-used", "8", "-lag-in-frames", "0", "-g", "50"]
        sources = {}
        for name, encoder, rate in [("vp8", "libvpx", "400k"), ("vp9", "libvpx-vp9", "300k")]:
            sources[name] = self.root / (name + ".webm")
            ffmpeg(*source_input, "-c:v", encoder, *realtime, "-auto-alt-ref", "0", "-b:v", rate, sources[name])
        sources["vp9-mp4"] = self.root / "vp9.mp4"
        ffmpeg("-i", sources["vp9"], "-c", "copy", sources["vp9-mp4"])
        for name, source in sources.items():
            with self.subTest(source=name):
                self.assertEqual(self.end_points(source), list(range(5 * FPS)))
                for start, end in [(0, 37), (50, 99)]:
                    copy = self.root / f"{name}-{start}-{end}{source.suffix}"
                    report = self.export(copy, [(source, start, end)], smart=False)
                    self.assertEqual(ratio(report["duration"]), Fraction(end - start, FPS))
                    self.assertEqual(frames(copy), frames(source)[start:end])
        altref = self.root / "vp9-altref.webm"
        settings = ["-c:v", "libvpx-vp9", "-b:v", "300k", "-g", "50", "-lag-in-frames", "25", "-auto-alt-ref", "1",
                    "-passlogfile", passes]
        ffmpeg(*source_input, *settings, "-pass", "1", "-f", "null", "-")
        ffmpeg(*source_input, *settings, "-pass", "2", altref)
        ends = self.end_points(altref)
        self.assertTrue({0, 50, 100} <= set(ends), ends)
        self.assertLess(len(ends), 10, ends)
        rejected = self.export(self.root / "altref-end.webm", [(altref, 0, 37)], smart=False, ok=False)
        self.assertEqual((rejected["error"]["boundary"], rejected["error"]["reason"]), ("to", "cut_video_end"))

    @unittest.skipUnless(shutil.which("aomenc"), "libaom's aomenc is not installed")
    def test_libaom_av1_copies_end_where_every_coded_picture_was_shown(self):
        # libaom's random-access structure codes a hidden alternate reference that show_existing_frame shows later,
        # and its low-delay structure codes none. A copy ends only where every picture coded since the keyframe has
        # been shown, and there it decodes to exactly the source's pictures in dav1d and VideoToolbox.
        raw = self.root / "source.y4m"
        ffmpeg("-f", "lavfi", "-i", f"testsrc2=s=320x180:r={FPS}:d=5", "-pix_fmt", "yuv420p", "-f", "yuv4mpegpipe", raw)
        common = ["--kf-max-dist=50", "--kf-min-dist=50", "--end-usage=q", "--cq-level=40", "--good", "--cpu-used=6"]
        sources = {}
        for name, extra in [("random-access", []), ("low-delay", ["--lag-in-frames=0"])]:
            stream = self.root / f"aom-{name}.ivf"
            run(["aomenc", "-q", *common, *extra, "-o", stream, raw], allow_diagnostics=True)
            sources[name] = self.root / f"aom-{name}.webm"
            ffmpeg("-i", stream, "-c", "copy", sources[name])
        for name, source in sources.items():
            with self.subTest(source=name):
                ends = self.end_points(source)
                if name == "low-delay":
                    self.assertEqual(ends, list(range(5 * FPS)))
                else:
                    # Ends inside a group other than after the keyframe's own unit, and fewer than every picture.
                    self.assertTrue(any(end % 50 > 1 for end in ends), ends)
                    self.assertLess(len(ends), 5 * FPS // 2, ends)
                    unsafe = next(end for end in range(2, 50) if end not in ends)
                    rejected = self.export(self.root / "aom-unsafe.webm", [(source, 0, unsafe)], smart=False, ok=False)
                    self.assertEqual((rejected["error"]["boundary"], rejected["error"]["reason"]), ("to", "cut_video_end"))
                source_frames, source_hardware = frames(source), hardware_frames(source)
                for end in [end for end in ends if end][:12]:
                    copy = self.root / f"aom-{name}-{end}.webm"
                    self.export(copy, [(source, 0, end)], smart=False)
                    self.assertEqual(frames(copy), source_frames[:end], end)
                    self.assertEqual(hardware_frames(copy), source_hardware[:end], end)

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

    def test_lossless_copy_reschedules_decode_times_at_a_variable_rate_join(self):
        source = self.root / "reordered-vfr.mp4"
        output = self.root / "joined-vfr.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x192:r=25", "-frames:v", "75",
               "-vf", "settb=1/25,setpts='N+10*floor(N/7)'", "-fps_mode", "passthrough",
               "-enc_time_base", "1/25", "-c:v", "libx264", "-threads", "1",
               "-x264-params", "keyint=10:min-keyint=10:scenecut=0:open-gop=0:bframes=3:b-adapt=0", source)

        ranges = [(source, 0, 1), (source, 120, 175)]
        dry = self.export(output, ranges, smart=False, dry=True)
        report = self.export(output, ranges, smart=False)
        self.assertEqual(report["segments"], dry["segments"])
        self.assertEqual(report["tier"]["id"], "true_lossless")
        self.assertEqual(ratio(report["encoded_duration"]), 0)
        self.assertEqual(report["copied_duration"], report["duration"])
        self.assertEqual(ratio(report["duration"]), Fraction(56, 25))

        source_packets = timestamped_hashes(source)
        expected = source_packets[:1] + [(time - Fraction(119, 25), digest)
                                        for time, digest in source_packets if time >= Fraction(24, 5)]
        self.assertEqual(timestamped_hashes(output), expected)
        source_frames = frames(source)
        self.assertEqual(frames(output), source_frames[:1] + source_frames[50:])
        source_hardware = hardware_frames(source)
        self.assertEqual(hardware_frames(output), source_hardware[:1] + source_hardware[50:])
        self.assertEqual(Fraction(probe(output, "-show_format")["format"]["duration"]), Fraction(56, 25))

        smart_output = self.root / "joined-vfr-smart.mp4"
        smart = self.export(smart_output, ranges)
        self.assertEqual(smart["tier"]["id"], "true_lossless")
        self.assertEqual(ratio(smart["encoded_duration"]), 0)
        self.assertEqual(timestamped_hashes(smart_output), expected)
        self.assertEqual(frames(smart_output), source_frames[:1] + source_frames[50:])

    def test_variable_frame_durations_survive_splice(self):
        source = self.root / "vfr.mp4"
        output = self.root / "vfr-trim.mp4"
        ffmpeg("-i", self.sources["h264"], "-an", "-vf", "settb=1/25,setpts='N+floor(N/9)'", "-fps_mode", "passthrough",
               "-enc_time_base", "1/25", "-c:v", "libx264", "-threads", "1",
               "-x264-params", "keyint=25:min-keyint=25:scenecut=0:open-gop=0:bframes=3", source)
        timestamps = sorted(dict(timestamped_hashes(source)))
        self.assertGreater(len(set(b-a for a, b in zip(timestamps, timestamps[1:]))), 1)
        # The decode order is split inside every picture group, and a copy can end at each of these points.
        # MOV times a track by decode intervals, so after a held picture the decode clock of such a prefix
        # ends before its presentation does; the writer extends the last decoded sample to the planned end.
        ends = partition_ends(source)
        self.assertGreater(len([end for end in ends if end % FPS]), 5)
        self.assertEqual(self.end_points(source), ends)
        start, end = timestamps[6], timestamps[88]
        self.export(output, [(source, start * FPS, end * FPS)])
        self.assertEqual(sorted(dict(timestamped_hashes(output))), [t - start for t in timestamps[6:88]])
        self.assertEqual(picture_ids(output), bytes(range(6, 88)))
        self.assertEqual(run([self.fixtures / "DecodeFrameIDs", output]), bytes(range(6, 88)))

    def test_variable_frame_durations_copy_to_every_partition_end(self):
        for codec, ext in [("h264", ".mp4"), ("hevc", ".mov")]:
            source = self.root / ("vfr-" + codec + ext)
            gop = "keyint=25:min-keyint=25:scenecut=0:open-gop=0:bframes=3"
            encoder = (["-c:v", "libx264", "-threads", "1", "-x264-params", gop] if codec == "h264" else
                       ["-c:v", "libx265", "-tag:v", "hvc1", "-x265-params", "pools=1:log-level=error:" + gop])
            ffmpeg("-i", self.sources[codec], "-an", "-vf", "settb=1/25,setpts='N+floor(N/7)'",
                   "-fps_mode", "passthrough", "-enc_time_base", "1/25", *encoder, source, allow_diagnostics=True)
            timestamps = sorted(dict(timestamped_hashes(source)))
            ends = partition_ends(source)
            self.assertEqual(self.end_points(source), ends)
            group_ends = [end for end in ends if end % FPS]
            self.assertGreater(len(group_ends), 5)
            # Every end inside a picture group, from the first and a later keyframe, and a keyframe end.
            pairs = [(0, end) for end in group_ends] + [(50, end) for end in group_ends if end > 50][:6] + [(0, 75)]
            for first, end in pairs:
                with self.subTest(codec=codec, first=first, end=end):
                    begin, finish = timestamps[first], timestamps[end]
                    output = self.root / f"vfr-{codec}-{first}-{end}{ext}"
                    self.export(output, [(source, begin * FPS, finish * FPS)], smart=False)
                    planned = finish - begin
                    track = probe(output, "-select_streams", "v:0", "-show_streams")["streams"][0]
                    self.assertEqual(int(track["duration_ts"]) * Fraction(track["time_base"]), planned)
                    report = json.loads(run([CLI, "media", "inspect", "--json", "--no-sidecar", output]))
                    self.assertEqual(ratio(report["media"]["duration"]), planned)
                    self.assertEqual(sorted(dict(timestamped_hashes(output))),
                                     [t - begin for t in timestamps[first:end]])
                    self.assertEqual(picture_ids(output), bytes(range(first, end)))
                    self.assertEqual(run([self.fixtures / "DecodeFrameIDs", output]), bytes(range(first, end)))
            # A whole copy reads as the probe's presentation duration in FFmpeg too, even where the
            # source's own sample table ends a held picture early.
            whole = self.root / f"vfr-{codec}-whole{ext}"
            measured = ratio(json.loads(run([CLI, "media", "inspect", "--json", "--no-sidecar", source]))["media"]["duration"])
            planned = self.export(whole, [(source, 0, measured * FPS)], smart=False)["duration"]
            self.assertEqual(ratio(planned), measured)
            track = probe(whole, "-select_streams", "v:0", "-show_streams")["streams"][0]
            self.assertEqual(int(track["duration_ts"]) * Fraction(track["time_base"]), measured)
            self.assertEqual(picture_ids(whole), bytes(range(len(timestamps))))
            # Matroska times blocks by presentation, so the same copies keep their duration there too.
            for first, end in [(0, group_ends[0]), (50, group_ends[-1])]:
                with self.subTest(codec=codec, matroska=end):
                    output = self.root / f"vfr-{codec}-{first}-{end}.mkv"
                    begin, finish = timestamps[first], timestamps[end]
                    self.export(output, [(source, begin * FPS, finish * FPS)], smart=False)
                    report = json.loads(run([CLI, "media", "inspect", "--json", "--no-sidecar", output]))
                    self.assertEqual(ratio(report["media"]["duration"]), finish - begin)
                    self.assertEqual(picture_ids(output), bytes(range(first, end)))

    def test_matroska_variable_frame_durations_copy_to_partition_ends(self):
        # A Matroska source stores presentation times only, so MPCut reconstructs its decode times. Its
        # blocks take one duration, so a held picture's block ends before the next picture starts. The
        # picture before every keyframe is held here, so the keyframe ends meet that too.
        for codec in ("h264", "hevc"):
            source = self.root / f"vfr-{codec}.mkv"
            gop = "keyint=25:min-keyint=25:scenecut=0:open-gop=0:bframes=3"
            encoder = (["-c:v", "libx264", "-threads", "1", "-x264-params", gop] if codec == "h264" else
                       ["-c:v", "libx265", "-x265-params", "pools=1:log-level=error:" + gop])
            ffmpeg("-i", self.sources[codec], "-an", "-vf", "settb=1/25,setpts='N+floor(N/5)'",
                   "-fps_mode", "passthrough", "-enc_time_base", "1/25", *encoder, source, allow_diagnostics=True)
            timestamps = sorted(dict(timestamped_hashes(source)))
            self.assertEqual(timestamps[25] - timestamps[24], Fraction(2, FPS))
            ends = partition_ends(source)
            self.assertEqual(self.end_points(source), ends)
            group_ends = [end for end in ends if end % FPS]
            self.assertGreater(len(group_ends), 20)
            source_packets = dict(timestamped_hashes(source))
            source_hardware = hardware_frames(source)
            pairs = [(0, end) for end in group_ends[:10]] + [(50, end) for end in group_ends if end > 50][:4] + [(0, 75)]
            for ext in (".mkv", ".mp4", ".mov"):
                for first, end in pairs:
                    with self.subTest(codec=codec, container=ext, first=first, end=end):
                        begin, finish = timestamps[first], timestamps[end]
                        output = self.root / f"vfr-{codec}-{first}-{end}{ext}"
                        report = self.export(output, [(source, begin * FPS, finish * FPS)], smart=False)
                        planned = finish - begin
                        self.assertEqual(ratio(report["duration"]), planned)
                        self.assertEqual(Fraction(probe(output, "-show_format")["format"]["duration"]), planned)
                        inspected = json.loads(run([CLI, "media", "inspect", "--json", "--no-sidecar", output]))
                        self.assertEqual(ratio(inspected["media"]["duration"]), planned)
                        # Every packet is the source's, at its place on the new timeline.
                        self.assertEqual(dict(timestamped_hashes(output)),
                                         {t - begin: source_packets[t] for t in timestamps[first:end]})
                        self.assertEqual(picture_ids(output), bytes(range(first, end)))
                        self.assertEqual(hardware_frames(output), source_hardware[first:end])
                        if ext != ".mkv":
                            track = probe(output, "-select_streams", "v:0", "-show_streams")["streams"][0]
                            self.assertEqual(int(track["duration_ts"]) * Fraction(track["time_base"]), planned)
                            self.assertEqual(run([self.fixtures / "DecodeFrameIDs", output]), bytes(range(first, end)))

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
