#!/usr/bin/env python3
"""End-to-end still timeline release checks using synthetic camera, sound and image fixtures.

Run against the built or packaged CLI with
    python3 Tests/Integration/still_timeline.py /path/to/mpcut
Fixture creation uses FFmpeg with x264, x265, VideoToolbox and SVT-AV1. The checks also use ffprobe and
AVFoundation readers built by swiftc. Fixtures and exports live in temporary directories.
"""
import argparse
from array import array
from dataclasses import dataclass
from fractions import Fraction
import json
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import ffmpeg, frames, packets, probe, ratio, run, sample_hashes, timestamped_hashes
from saved_project import read_project
from smart_trim import CAPTION_SEI, FILM_GRAIN_SEI, film_grain_note, with_h264_sei

CLI = None
FPS = 24
SAMPLE_RATE = 48000
SIZE = (320, 180)
LENGTH = 6


@dataclass(frozen=True)
class MediaRow:
    name: str
    extension: str
    codec: str
    sound: str
    transfer: str
    video_flags: tuple

    @property
    def hdr(self):
        return self.transfer != "bt709"

    @property
    def picture_format(self):
        return {"h264": "yuv420p", "hevc": "yuv420p10le", "prores": "yuv422p10le"}[self.codec]

    @property
    def color_flags(self):
        gamut = ("bt2020", "bt2020nc") if self.hdr else ("bt709", "bt709")
        return ("-color_range", "tv", "-color_primaries", gamut[0],
                "-colorspace", gamut[1], "-color_trc", self.transfer)

    @property
    def color_filter(self):
        primaries, matrix = ("bt2020", "bt2020nc") if self.hdr else ("bt709", "bt709")
        return f"setparams=range=tv:color_primaries={primaries}:color_trc={self.transfer}:colorspace={matrix}"


ROWS = (
    MediaRow("avc", "mp4", "h264", "aac", "bt709",
             ("-c:v", "libx264", "-profile:v", "high", "-g", "24", "-sc_threshold", "0",
              "-bf", "0", "-tag:v", "avc1")),
    MediaRow("prores", "mov", "prores", "pcm_s16le", "bt709",
             ("-c:v", "prores_videotoolbox", "-profile:v", "standard", "-tag:v", "apcn")),
    *(
        MediaRow(name, "mov", "hevc", "pcm_s16le", transfer,
                 ("-c:v", "libx265", "-profile:v", "main10", "-tag:v", "hvc1",
                  "-x265-params", "keyint=24:scenecut=0:open-gop=0:bframes=0:pools=none:log-level=error"))
        for name, transfer in (("pq", "smpte2084"), ("hlg", "arib-std-b67"))
    ),
)


def camera(path, row, angle=0, extra_track=False, fps=FPS, seconds=LENGTH, *, dolby_vision=False):
    width, height = SIZE
    marker = "lime" if angle else "red"
    video = f"testsrc2=s={width}x{height}:r={fps}:d={seconds},drawbox=x=0:y=0:w=40:h=30:color={marker}:t=fill"
    # Silence for the first eighth-second makes the original onset easy to locate after a head insert.
    frequencies = (619 if angle else 419, 887)
    args = ["-f", "lavfi", "-i", video]
    for frequency in frequencies[:2 if extra_track else 1]:
        tone = f"if(gte(t\\,0.125)\\,0.6*sin(2*PI*{frequency}*t)\\,0)"
        args += ["-f", "lavfi", "-i", f"aevalsrc={tone}|{tone}:s={SAMPLE_RATE}:d={seconds}:c=stereo"]
    args += ["-map", "0:v", "-map", "1:a"]
    if extra_track:
        args += ["-map", "2:a"]
    video_flags = row.video_flags
    pixel_format = "p210le" if row.codec == "prores" else row.picture_format
    if dolby_vision:
        video_flags = ("-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-tag:v", "hvc1", "-g", "24", "-bf", "0")
        pixel_format = "p010le"
    ffmpeg(*args, "-vf", row.color_filter, *video_flags, "-pix_fmt", pixel_format, *row.color_flags,
           "-threads", "1", "-c:a", row.sound, "-ar", str(SAMPLE_RATE),
           "-video_track_timescale", str(Fraction(fps).numerator * 1000), "-movflags", "+write_colr", path,
           allow_diagnostics=row.codec == "hevc")
    # Copy cases cut on a fixed GOP grid and mid-GOP cases need to miss it.
    if row.codec != "prores" and not dolby_vision:
        stream = stream_info(path, "v:0")
        scale = Fraction(stream["time_base"])
        sync_times = {int(packet["pts"]) * scale for packet in packets(path) if "K" in packet["flags"]}
        expected = {Fraction(frame, fps) for frame in range(0, int(stream["nb_frames"]), 24)}
        if sync_times != expected:
            raise AssertionError(f"Expected sync samples at {sorted(expected)} in {path}, got {sorted(sync_times)}")



def camera_with_hevc_sei(camera, output, payload_type, payload):
    raw = output.with_suffix(".hevc")
    data = ffmpeg("-i", camera, "-map", "0:v:0", "-c:v", "copy", "-f", "hevc", "-")
    rbsp = bytes((payload_type, len(payload))) + payload + b"\x80"
    rbsp = re.sub(rb"\x00\x00(?=[\x00-\x03])", lambda match: match[0] + b"\x03", rbsp)
    first_slice = re.search(rb"\x00\x00\x01(?=[\x00-\x3f][\x01-\x07])", data).start()
    raw.write_bytes(data[:first_slice] + b"\x00\x00\x01\x4e\x01" + rbsp + data[first_slice:])
    ffmpeg("-r", str(FPS), "-f", "hevc", "-i", raw, "-map", "0:v:0", "-c:v", "copy", "-tag:v", "hvc1",
           "-video_track_timescale", str(FPS * 1_000), output)

def hdr_photo(directory, row):
    """Create three neutral legal-range 10-bit patches above SDR black."""
    width, height = SIZE
    legal_values = (560, 735, 860) if row.name == "pq" else (710, 820, 905)
    luma = array("H", (legal_values[min(column * 3 // width, 2)] for column in range(width))) * height
    chroma = array("H", [512]) * (width * height // 2)
    source = directory / f"{row.name}.raw"
    source.write_bytes(luma.tobytes() + chroma.tobytes())
    target = directory / f"{row.name}.avif"
    ffmpeg("-f", "rawvideo", "-pixel_format", "yuv420p10le", "-video_size", f"{width}x{height}",
           "-i", source, "-vf", row.color_filter, "-frames:v", "1", "-c:v", "libsvtav1",
           "-preset", "10", "-crf", "12", "-svtav1-params", "lp=1", *row.color_flags,
           "-movflags", "+write_colr", target, allow_diagnostics=True)
    info = stream_info(target, "v:0")
    if info.get("color_transfer") != row.transfer or info["pix_fmt"] != "yuv420p10le":
        raise AssertionError(f"Expected a tagged 10-bit {row.name} still in {target}: {info}")
    return target


def stream_info(path, track):
    return probe(path, "-select_streams", track, "-show_streams")["streams"][0]


def duration(stream):
    return Fraction(stream["time_base"]) * int(stream["duration_ts"])


def decoded_audio(path, ordinal=0):
    return ffmpeg("-i", path, "-map", f"0:a:{ordinal}", "-vn", "-c:a", "pcm_s16le", "-f", "s16le", "-")


def luma_at(path, position, high_depth=False):
    data = ffmpeg("-ss", str(float(position)), "-i", path, "-map", "0:v:0", "-frames:v", "1",
                  "-vf", "extractplanes=y", "-pix_fmt", "gray10le" if high_depth else "gray",
                  "-f", "rawvideo", "-")
    values = array("H", data) if high_depth else data
    width, height = SIZE
    if len(values) != width * height:
        raise AssertionError(f"No complete decoded picture at {position} in {path}")
    return [
        sum(values[y * width + x] for y in range(30, 60) for x in range(center - 8, center + 8)) / 480
        for center in (width // 6, width // 2, 5 * width // 6)
    ]


def fraction(value):
    return ratio(value) if isinstance(value, dict) else Fraction(value)


class StillTimelineAcceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix="mpcut-still-fixtures-")
        cls.addClassCleanup(temporary.cleanup)
        cls.fixtures = Path(temporary.name)
        for name in ("DecodeFrameIDs", "DecodeAudio"):
            run(["swiftc", "-suppress-warnings", "-parse-as-library", Path(__file__).with_name(f"{name}.swift"),
                 "-o", cls.fixtures / name])
        cls.sources = {}
        cls.hdr_cards = {}
        for row in ROWS:
            wide = cls.fixtures / f"{row.name}-wide.{row.extension}"
            close = cls.fixtures / f"{row.name}-close.{row.extension}"
            camera(wide, row)
            camera(close, row, angle=1)
            cls.sources[row.name] = (wide, close)
            if row.hdr:
                cls.hdr_cards[row.name] = hdr_photo(cls.fixtures, row)
        cls.sdr_card = cls.fixtures / "white.png"
        width, height = SIZE
        ffmpeg("-f", "lavfi", "-i", f"color=white:s={width}x{height}", "-frames:v", "1",
               "-threads", "1", cls.sdr_card)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="mpcut-still-acceptance-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def cli(self, *args, ok=True, stdin=None):
        result = subprocess.run([CLI, "--no-sidecar", *map(str, args), "--json"],
                                input=stdin, cwd=self.root, timeout=120, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, f"Exit {result.returncode}\n{result.stdout}{result.stderr}")
        return json.loads(result.stdout)

    def project(self, row, kind, *, sources=None, assembly=None, repeated=False, length=LENGTH, label=None):
        wide, close = self.sources[row.name] if sources is None else sources
        document = {"format": "mpcut", "schema_version": 9, "kind": kind}
        if kind == "sequence":
            document["clips"] = [{"id": "a", "file": str(wide), "from": "0", "to": str(length)}]
            if repeated:
                document["clips"].append({**document["clips"][0], "id": "b"})
        else:
            document.update({
                "reference_angle_id": "wide", "group_range": {"from": "0", "to": str(length)},
                "angles": [
                    {"id": "wide", "file": str(wide), "offset": "0", "audio_stream_index": 1},
                    {"id": "close", "file": str(close), "offset": "0", "audio_stream_index": 1},
                ],
                "audio": {"mode": "fixed", "source_id": "wide", "audio_stream_index": 1},
                "switches": [{"group_time": "0", "angle_id": "wide"}, {"group_time": "3", "angle_id": "close"}],
            })
            if assembly is not None:
                document["assembly"] = [{"from": str(lo), "to": str(hi)} for lo, hi in assembly]
        stem = "-".join(filter(None, (row.name, kind, label)))
        project = self.root / f"{stem}.cut"
        project.write_text(json.dumps(document))
        return project

    def replace(self, base, kind, start, end, *, image=None):
        target = base.with_stem(base.stem + "-replaced")
        self.cli("still", "picture", "replace", "--project", base, "--image", image or self.sdr_card, "--clock", "sequence" if kind == "sequence" else "group", "--from", start,
                 "--to", end, "--out-project", target)
        self.assertIn(read_project(target)["schema_version"], (4, 5))
        return target

    def insert(self, base, kind, at, *, image=None, count=24, rate=FPS):
        target = base.with_stem(base.stem + "-inserted")
        self.cli("still", "placement", "insert", "--project", base, "--image", image or self.sdr_card, "--clock", "sequence" if kind == "sequence" else "assembly", "--at", at,
                 "--frames", count, "--rate", rate, "--out-project", target)
        self.assertIn(read_project(target)["schema_version"], (4, 5))
        return target

    def export(self, project, output, *args, **options):
        return self.cli("export", "project", "render", "--project", project, "--output", output, *args, **options)

    def test_space_clips_sets_portable_silent_sdr_and_hdr_gaps(self):
        for row in (r for r in ROWS if r.sound == "pcm_s16le"):
            for kind in ("sequence", "multicam"):
                with self.subTest(profile=row.name, timeline=kind):
                    base = self.project(row, kind, repeated=True, assembly=[(0, 1), (2, 3)])
                    join = LENGTH if kind == "sequence" else 1
                    target = base.with_stem(base.stem + "-spaced")
                    self.cli("timeline", "clips", "space", "--project", base, "--duration", 2, "--background", "#000000",
                             "--out-project", target)
                    saved = read_project(target)
                    self.assertEqual(len(saved["still_assets"]), 1)
                    self.assertEqual(set(saved["still_assets"][0]), {"kind", "id"})
                    def spacing():
                        return self.cli("still", "placement", "list", "--project", target)["placements"]
                    before = spacing()
                    self.assertEqual(len(before), 1)
                    self.assertEqual(fraction(before[0]["duration"]), 2)
                    self.cli("timeline", "clips", "space", "--project", target, "--duration", 1, "--background", "#FFFFFF", "--in-place")
                    after = spacing()
                    self.assertEqual([item["id"] for item in after], [before[0]["id"]])
                    self.assertEqual(fraction(after[0]["authored_range"]["from"]), join)
                    self.assertEqual(after[0]["framing"]["background"], "#FFFFFF")
                    output = target.with_suffix(".mov")
                    report = self.export(target, output, "--require-camera-copy")
                    self.assertEqual(fraction(report["generated_still_duration"]), 1)
                    self.assertEqual(fraction(report["encoded_camera_duration"]), 0)
                    self.assertEqual(stream_info(output, "v:0")["color_transfer"], row.transfer)
                    # Decode the movie on its presentation clock. Verify seeking
                    # independently using the native reader used by the desktop app.
                    values = ffmpeg("-i", output, "-ss", str(join + 0.5), "-frames:v", "1", "-vf", "extractplanes=y",
                                    "-pix_fmt", "gray10le" if row.hdr else "gray", "-f", "rawvideo", "-")
                    luma = array("H", values) if row.hdr else values
                    self.assertEqual(len(luma), SIZE[0] * SIZE[1])
                    white = {"prores": 235, "pq": 572, "hlg": 721}[row.name]
                    self.assertLess(max(abs(value - white) for value in luma), 10)
                    native = self.fixtures / "DecodeFrameIDs"
                    self.assertEqual(run([native, output, str(join * 25)]), run([native, output])[join * FPS:])
                    audio = decoded_audio(output)
                    start, end = join * SAMPLE_RATE * 4, (join + 1) * SAMPLE_RATE * 4
                    self.assertEqual(audio[start:end], bytes(end - start))
                    self.assertTrue(any(audio[:start]) and any(audio[end:]))
                    self.cli("timeline", "clips", "space", "--project", target, "--duration", 0, "--in-place")
                    self.assertEqual(spacing(), [])

    def test_vfr_replacement_and_short_final_insert_sample(self):
        row = next(row for row in ROWS if row.name == "prores")
        source = self.root / "source.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=1",
               "-vf", r"select=not(eq(mod(n\,3)\,1))," + row.color_filter,
               "-fps_mode", "passthrough", *row.video_flags, "-pix_fmt", "p210le", *row.color_flags,
               "-video_track_timescale", "25000", "-movflags", "+write_colr", source)
        base = self.project(row, "sequence", sources=(source, source), length=1)
        start, end = Fraction(3, 25), Fraction(9, 25)
        replaced = self.replace(base, "sequence", start, end)
        inserted = self.root / "inserted.cut"
        self.cli("still", "placement", "insert", "--project", replaced, "--image", self.sdr_card, "--clock", "sequence", "--at", end, "--duration", "3/50", "--rate", 25,
                 "--out-project", inserted)

        def samples(file):
            tb = Fraction(stream_info(file, "v:0")["time_base"])
            packets = probe(file, "-select_streams", "v:0", "-show_packets")["packets"]
            return [(int(packet["pts"]) * tb, int(packet["duration"]) * tb) for packet in packets]

        original = samples(source)
        self.assertGreater(len({length for _, length in original}), 1)
        expected = [(at, length) for at, length in original if at < end]
        expected += [(end, Fraction(1, 25)), (end + Fraction(1, 25), Fraction(1, 50))]
        expected += [(at + Fraction(3, 50), length) for at, length in original if at >= end]
        original_hashes = dict(timestamped_hashes(source))
        for mode, flags in (("smart", ["--require-camera-copy"]), ("encode", ["--video", "prores"])):
            with self.subTest(mode=mode):
                output = self.root / f"vfr-{mode}.mov"
                planned = self.export(inserted, output, "--tracks", "video", "--mode", mode, *flags, "--dry-run")
                self.assertEqual(fraction(planned["duration"]), Fraction(53, 50))
                self.assertFalse(output.exists())
                self.export(inserted, output, "--tracks", "video", "--mode", mode, *flags)
                self.assertEqual(samples(output), expected)
                self.assertEqual(duration(stream_info(output, "v:0")), Fraction(53, 50))
                self.assert_card(output, row, start)
                self.assert_card(output, row, end + Fraction(1, 25))
                if mode == "smart":
                    retained = {at if at < start else at + Fraction(3, 50): digest
                                for at, digest in original_hashes.items() if at < start or at >= end}
                    result = dict(timestamped_hashes(output))
                    self.assertEqual({at: result[at] for at in retained}, retained)
                    decoder = self.fixtures / "DecodeFrameIDs"
                    native = run([decoder, output])
                    self.assertEqual(len(native), len(expected))
                    self.assertEqual(run([decoder, output, "3"]), native[2:])

    def test_nested_replacement_uses_the_reference_recording_covering_its_range(self):
        row = next(row for row in ROWS if row.name == "prores")
        base = self.project(row, "multicam")
        document = read_project(base)
        primary = document["angles"][0]
        primary["additional_recordings"] = [{"id": "second", "file": primary["file"], "offset": "4",
                                            "group_coverage": {"from": "4", "to": "6"}}]
        primary.update(file="offline-first-part.mov", group_coverage={"from": "0", "to": "4"})
        document["audio"] = {"mode": "none"}
        base.write_text(json.dumps(document))
        replaced = self.replace(base, "multicam", 4, 5)
        request = {"output": str(self.root / "nested.mov"), "tracks": "video",
                   "clips": [{"project_path": str(replaced), "from": "4", "to": "6"}]}
        plan = self.cli("export", "clips", "join", "--dry-run", "--stdin", stdin=json.dumps(request))
        self.assertEqual(fraction(plan["generated_still_duration"]), 1)
        self.assertEqual(fraction(plan["copied_camera_duration"]), 1)

    def test_nested_multicam_group_clip_excludes_assembly_insert(self):
        row = next(row for row in ROWS if row.name == "prores")
        base = self.project(row, "multicam", assembly=[(2, 4), (2, 4)])
        group = self.replace(base, "multicam", 2, 3)
        assembled = self.insert(group, "multicam", 2)
        direct = self.export(assembled, self.root / "assembled.mov", "--dry-run")
        self.assertEqual(fraction(direct["duration"]), 5)
        self.assertEqual(fraction(direct["generated_still_duration"]), 3)

        recording = self.sources[row.name][0]
        request = {"output": str(self.root / "nested.mov"), "clips": [
            {"file": str(recording), "to": "1"},
            {"project_path": str(assembled), "from": "2", "to": "4"},
        ], "order": [2, 1, 2, 2]}
        nested = self.cli("export", "clips", "join", "--dry-run", "--stdin", stdin=json.dumps(request))
        self.assertEqual(nested["mode"], "smart")
        self.assertEqual(fraction(nested["duration"]), 7)
        self.assertEqual(fraction(nested["generated_still_duration"]), 3)
        rendered = self.cli("export", "clips", "join", "--stdin", stdin=json.dumps(request))
        self.assertEqual(rendered["picture"], nested["picture"])
        output = Path(request["output"])
        self.assertEqual(duration(stream_info(output, "v:0")), 7)
        self.assertEqual(fraction(rendered["copied_camera_duration"]), 4)
        self.assertEqual(fraction(rendered["encoded_camera_duration"]), 0)
        close = self.sources[row.name][1]
        expected_packets = {
            offset + time - start: digest
            for source, start, end, offset in ((close, 3, 4, 1), (recording, 0, 1, 2), (close, 3, 4, 4), (close, 3, 4, 6))
            for time, digest in timestamped_hashes(source) if start <= time < end
        }
        actual_packets = dict(timestamped_hashes(output))
        self.assertEqual({time: actual_packets[time] for time in expected_packets}, expected_packets)
        input_pcm = decoded_audio(recording)
        bytes_per_second = 4 * SAMPLE_RATE
        group_pcm = input_pcm[2 * bytes_per_second:4 * bytes_per_second]
        self.assertEqual(decoded_audio(output), group_pcm + input_pcm[:bytes_per_second] + 2 * group_pcm)

    def test_project_silence_reports_card_in_rippled_assembly(self):
        row = next(row for row in ROWS if row.name == "prores")
        base = self.project(row, "multicam", assembly=[(0, 1), (0, 1)])
        assembled = self.insert(base, "multicam", 1)
        output = self.root / "retained.mov"
        options = ("silence", "plan", "--project", assembled, "--threshold-db", "-40",
                   "--min-pause-seconds", "0.07", "--padding-per-side-seconds", "0", "--output", output)
        report = self.cli(*options, "--dry-run")
        self.assertEqual(fraction(report["duration"]), 3)
        self.assertEqual(len(report["cards"]), 1)
        card = report["cards"][0]
        self.assertEqual(card["assembly_index"], 1)
        self.assertEqual(fraction(card["output"]["from"]), 1)
        self.assertEqual(fraction(card["retained_output"]["to"]) - fraction(card["retained_output"]["from"]), 1)
        removed = fraction(report["removed_duration"])
        self.assertGreater(removed, 0)
        self.assertLess(fraction(card["retained_output"]["from"]), 1)
        self.assertEqual(fraction(report["retained_duration"]), 3 - removed)
        self.assertTrue(all(item["assembly_index"] != 1 for item in report["pauses"]))
        self.assertEqual(fraction(report["still_preflight"]["generated_still_duration"]), 1)

    def test_constant_rate_rejects_fractional_insert_frame(self):
        row = next(row for row in ROWS if row.name == "prores")
        base = self.project(row, "sequence")
        inserted = self.root / "fractional.cut"
        self.cli("still", "placement", "insert", "--project", base, "--image", self.sdr_card, "--clock", "sequence", "--at", 1, "--duration", "1/16", "--rate", 24,
                 "--out-project", inserted)
        output = self.root / "unsupported.mov"
        failure = self.export(inserted, output, "--tracks", "video", "--dry-run", ok=False)
        self.assertEqual(failure["error"]["code"], "unsupported_still_timing")
        self.assertFalse(output.exists())

    def assert_picture(self, output, row, reference, parts):
        """Compare retained camera payloads and decoded frames, including after seeks across joins."""
        cursor = Fraction(0)
        expected_payloads = {}
        expected_frames = {}
        input_hashes = dict(timestamped_hashes(reference))
        input_frames = frames(reference)
        native_decoder = self.fixtures / "DecodeFrameIDs"
        input_native = run([native_decoder, reference])
        expected_native = {}
        for source_or_still_start, length in parts:
            if source_or_still_start is not None:
                start = source_or_still_start
                expected_payloads.update({cursor + at - start: digest for at, digest in input_hashes.items()
                                          if start <= at < start + length})
                expected_frames.update({int(cursor * FPS) + index: input_frames[int(start * FPS) + index]
                                        for index in range(int(length * FPS))})
                expected_native.update({int(cursor * FPS) + index: input_native[int(start * FPS) + index]
                                         for index in range(int(length * FPS))})
            cursor += length
        stream = stream_info(output, "v:0")
        self.assertEqual((stream["codec_name"], stream["pix_fmt"], stream.get("color_transfer")),
                         (row.codec, row.picture_format, row.transfer))
        self.assertEqual(duration(stream), cursor)
        time_base = Fraction(stream["time_base"])
        schedule = probe(output, "-select_streams", "v:0", "-show_packets",
                         "-show_entries", "packet=dts,duration")["packets"]
        self.assertEqual([int(packet["duration"]) * time_base for packet in schedule],
                         [Fraction(1, FPS)] * int(cursor * FPS))
        decode_times = [int(packet["dts"]) for packet in schedule]
        self.assertTrue(all(first < second for first, second in zip(decode_times, decode_times[1:])))
        result = dict(timestamped_hashes(output))
        self.assertEqual(sorted(result), [Fraction(index, FPS) for index in range(int(cursor * FPS))])
        self.assertEqual({at: result[at] for at in expected_payloads}, expected_payloads)
        decoded = frames(output)
        self.assertEqual(len(decoded), int(cursor * FPS))
        self.assertEqual({at: decoded[at] for at in expected_frames}, expected_frames)
        native = run([native_decoder, output])
        self.assertEqual(len(native), int(cursor * FPS))
        self.assertEqual({at: native[at] for at in expected_native}, expected_native)
        # ffmpeg seeks to the complete picture at or after the timestamp provided. A point
        # a quarter frame before each camera return tests the join without rounding up.
        cursor = Fraction(0)
        for start, length in parts:
            if start is not None and cursor > 0:
                self.assertEqual(frames(output, seek=float(cursor - Fraction(1, 4 * FPS)))[0],
                                 input_frames[int(start * FPS)])
                # The shared native reader represents its seek argument in 25ths.
                if (cursor * 25).denominator == 1:
                    reopened = run([native_decoder, output, str(int(cursor * 25))])
                    self.assertEqual(reopened, native[int(cursor * FPS):])
            cursor += length

    def assert_report(self, report, copied, generated):
        self.assertEqual(report["mode"], "smart")
        self.assertEqual(fraction(report["copied_camera_duration"]), copied)
        self.assertEqual(fraction(report["encoded_camera_duration"]), 0)
        self.assertEqual(fraction(report["generated_still_duration"]), generated)
        self.assertEqual(fraction(report["duration"]), copied + generated)
        self.assertEqual(fraction(report["copied_video_duration"]), copied)
        self.assertEqual(fraction(report["encoded_video_duration"]), generated)

    def assert_card(self, output, row, at, hdr=False):
        steps = luma_at(output, at, high_depth=row.hdr)
        if not row.hdr:
            self.assertGreater(min(steps), 220)
            return
        signals = [(step - 64) / 876 for step in steps]
        white = 0.58 if row.name == "pq" else 0.75
        if hdr:
            self.assertGreater(signals[1], white + 0.04, signals)
            self.assertGreater(signals[2], signals[1] + 0.025, signals)
        else:
            for signal in signals:
                self.assertAlmostEqual(signal, white, delta=0.05)

    def assert_inserted_sound(self, reference, output, row, at):
        sound = decoded_audio(output)
        original = decoded_audio(reference)
        # Each stereo PCM frame occupies four bytes.
        start = at * SAMPLE_RATE * 4
        hold = SAMPLE_RATE * 4
        audio = stream_info(output, "a:0")
        self.assertEqual((audio["codec_name"], int(audio["sample_rate"]), audio["channels"]),
                         (row.sound, SAMPLE_RATE, 2))
        if row.sound == "aac":
            self.assertEqual(audio["profile"], "LC")
        self.assertEqual(duration(audio), LENGTH + 1)
        native = run([self.fixtures / "DecodeAudio", output])
        self.assertEqual(len(native), (LENGTH + 1) * hold)
        if row.sound == "pcm_s16le":
            self.assertEqual(sound, original[:start] + bytes(hold) + original[start:])
        else:
            # AAC padding may be present on decode. The container must declare the exact
            # presentation duration and the middle of the inserted interval must be silent.
            self.assertGreaterEqual(len(sound), (LENGTH + 1) * hold)
            self.assertLess(len(sound), (LENGTH + 1) * hold + 1024 * 4)
            quiet = array("h", sound[start + 4096:start + hold - 4096])
            self.assertLess(max(abs(sample) for sample in quiet), 20)
            if at == LENGTH:
                return
            expected = (at + 1) * SAMPLE_RATE + (SAMPLE_RATE // 8 if at == 0 else 0)
            for reader in (sound, native):
                signal = array("h", reader)
                search = ((2 * at + 1) * SAMPLE_RATE)
                onset = next(index // 2 for index in range(search, len(signal)) if abs(signal[index]) > 200)
                self.assertAlmostEqual(onset, expected, delta=96)

    def matrix_case(self, row, kind, operation, video_only):
        label = f"{operation}-{'picture' if video_only else 'program'}"
        base = self.project(row, kind, label=label)
        opts = ["--tracks", "video"] if video_only else []
        stem = base.stem
        reference = self.root / f"{stem}-reference.{row.extension}"
        self.export(base, reference, *opts)
        wide, close = self.sources[row.name]
        original_camera = dict(timestamped_hashes(wide))
        if kind == "multicam":
            original_camera.update({at: digest for at, digest in timestamped_hashes(close) if at >= 3})
        self.assertEqual(dict(timestamped_hashes(reference)), original_camera)
        if operation == "replace":
            project = self.replace(base, kind, 2, 4)
            parts = [(0, 2), (None, 2), (4, 2)]
            generated, at = 2, 2
        else:
            at = 0 if operation == "head" else 2
            project = self.insert(base, kind, at, image=self.hdr_cards.get(row.name))
            parts = ([(0, at)] if at else []) + [(None, 1), (at, LENGTH - at)]
            generated = 1
            if row.sound == "aac" and not video_only:
                opts += ["--audio", "aac"]
        output = self.root / f"{stem}.{row.extension}"
        options = ["--require-camera-copy", *opts]
        planned = self.export(project, output, *options, "--dry-run")
        self.assertFalse(output.exists())
        written = self.export(project, output, *options)
        copied = LENGTH - generated if operation == "replace" else LENGTH
        for report in (planned, written):
            self.assert_report(report, copied, generated)
        self.assertNotIn("output_bytes", planned)
        self.assertEqual({**planned, "dry_run": False, "output_bytes": output.stat().st_size}, written)
        self.assert_picture(output, row, reference, parts)
        self.assert_card(output, row, at + Fraction(1, 2), hdr=row.hdr and operation != "replace")
        if video_only:
            self.assertEqual(probe(output, "-select_streams", "a", "-show_streams").get("streams", []), [])
        elif operation == "replace":
            self.assertEqual(written["sound_actions"][0]["audio"], "copy")
            self.assertEqual(decoded_audio(output), decoded_audio(reference))
            native_audio = self.fixtures / "DecodeAudio"
            self.assertEqual(run([native_audio, output]), run([native_audio, reference]))
            if row.sound == "aac":
                self.assertEqual(sample_hashes(output, "a:0"), sample_hashes(reference, "a:0"))
        else:
            action = written["sound_actions"][0]
            self.assertEqual(action["audio"], "aac" if row.sound == "aac" else "pcm")
            self.assertTrue(action["generated_silence"])
            self.assert_inserted_sound(reference, output, row, at)

    def check_media_matrix(self, row):
        for kind in ("sequence", "multicam"):
            for operation in ("head", "interior", "replace"):
                for video_only in (False, True):
                    with self.subTest(kind=kind, operation=operation, video_only=video_only):
                        self.matrix_case(row, kind, operation, video_only)

    def test_avc_aac_release_matrix(self):
        self.check_media_matrix(ROWS[0])

    def test_avc_aac_titles_at_head_interior_and_tail_in_mov(self):
        row = ROWS[0]
        reference = self.sources[row.name][0]
        for extension, times in (("mov", (0, 2, LENGTH)), ("mp4", (LENGTH,))):
            for at in times:
                with self.subTest(container=extension, at=at):
                    base = self.project(row, "sequence", label=f"{extension}-{at}")
                    project = self.insert(base, "sequence", at)
                    output = self.root / f"title-{at}.{extension}"
                    report = self.export(project, output, "--require-camera-copy", "--audio", "aac")
                    self.assert_report(report, copied=LENGTH, generated=1)
                    parts = [(start, length) for start, length in ((0, at), (None, 1), (at, LENGTH - at)) if length]
                    self.assert_picture(output, row, reference, parts)
                    self.assert_inserted_sound(reference, output, row, at)

    def test_prores_pcm_release_matrix(self):
        self.check_media_matrix(ROWS[1])

    def test_pq_main10_release_matrix(self):
        self.check_media_matrix(ROWS[2])

    def test_hlg_main10_release_matrix(self):
        self.check_media_matrix(ROWS[3])

    def test_hdr10_mastering_and_content_light(self):
        row = ROWS[2]
        source = self.sources[row.name][0]
        camera_path = self.root / "hdr10.mov"
        mastering = "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
        ffmpeg("-mastering_display:v:0", mastering, "-content_light:v:0", "1000,400",
               "-i", source, "-map", "0", "-c", "copy", "-movflags", "+write_colr", camera_path)
        source_side_data = stream_info(camera_path, "v:0")["side_data_list"]
        display = next(item for item in source_side_data if item["side_data_type"] == "Mastering display metadata")
        self.assertIn("Content light level metadata", {item["side_data_type"] for item in source_side_data})
        base = self.project(row, "sequence", sources=(camera_path, camera_path))
        # Starting with a generated sample exercises mastering data on the new
        # sample entry as well as the restored camera sample entry.
        project = self.insert(base, "sequence", 0)
        for mode in ("smart", "encode"):
            with self.subTest(mode=mode):
                output = self.root / f"hdr10-{mode}.mov"
                flags = ["--require-camera-copy"] if mode == "smart" else ["--video", "hevc"]
                report = self.export(project, output, "--mode", mode, "--tracks", "video", *flags)
                self.assertTrue(any("Content-light statistics will be omitted" in item for item in report["warnings"]))
                info = stream_info(output, "v:0")
                self.assertEqual(info["color_transfer"], "smpte2084")
                self.assertEqual(info["pix_fmt"], "yuv420p10le")
                self.assertEqual(info["side_data_list"], [display])
                if mode == "smart":
                    self.assertEqual(sample_hashes(output)[FPS:], sample_hashes(camera_path))
                    inspected = self.cli("media", "inspect", "--keyframes", output)["media"]
                    self.assertIsNone(inspected.get("copy_issue"))

    def test_hdr10_embedded_content_light_requires_conversion(self):
        row = ROWS[2]
        source = self.root / "embedded-content-light.mov"
        camera_with_hevc_sei(self.sources[row.name][0], source, 144, bytes.fromhex("03e80190"))
        first_frame = probe(source, "-select_streams", "v:0", "-read_intervals", "%+#1", "-show_frames")["frames"][0]
        self.assertTrue(any(side["side_data_type"] == "Content light level metadata"
                            for side in first_frame["side_data_list"]))
        base = self.project(row, "sequence", sources=(source, source))
        project = self.insert(base, "sequence", 0)
        output = self.root / "embedded-content-light-out.mov"
        refused = self.export(project, output, "--mode", "smart", "--tracks", "video",
                              "--require-camera-copy", "--dry-run", ok=False)["error"]
        self.assertEqual(refused["code"], "unsupported_hdr_content_light")
        self.assertTrue(any(offer["mode"] == "encode" for offer in refused["alternatives"]))
        self.assertFalse(output.exists())
        report = self.export(project, output, "--mode", "encode", "--tracks", "video", "--video", "hevc")
        self.assertTrue(any("Content-light statistics will be omitted" in item for item in report["warnings"]))
        self.assertFalse(any(side["side_data_type"] == "Content light level metadata"
                             for side in stream_info(output, "v:0").get("side_data_list", [])))

    def test_dynamic_dolby_vision_without_a_verified_alternative(self):
        row = ROWS[3]
        source = self.root / "dolby-vision.mov"
        # VideoToolbox automatically adds Dolby Vision RPU units to this HLG input.
        camera(source, row, dolby_vision=True)
        base = self.project(row, "sequence", sources=(source, source))
        project = self.insert(base, "sequence", 0)
        output = self.root / "dynamic-hlg.mov"
        for mode in ("smart", "encode"):
            with self.subTest(mode=mode):
                flags = ["--video", "hevc"] if mode == "encode" else []
                result = self.export(project, output, "--tracks", "video", "--mode", mode,
                                     "--dry-run", *flags, ok=False)
                self.assertEqual(result["error"]["code"], "unsupported_dynamic_hdr")
                self.assertIn("Dolby Vision", result["error"]["message"])
                self.assertFalse(result["error"].get("alternatives"))
        self.assertFalse(output.exists())

    def test_dynamic_hdr10plus_without_a_verified_alternative(self):
        row = ROWS[2]
        source = self.root / "hdr10plus.mov"
        camera = self.sources[row.name][0]
        # Registered T.35 ST 2094-40 application 4, version 1, with one processing window.
        payload = bytes.fromhex("b5003c0001040140001f40138809c404e20138806400")
        camera_with_hevc_sei(camera, source, 4, payload)
        first_frame = probe(source, "-select_streams", "v:0", "-read_intervals", "%+#1", "-show_frames")["frames"][0]
        self.assertTrue(any("HDR10+" in side["side_data_type"] for side in first_frame["side_data_list"]))
        base = self.project(row, "sequence", sources=(source, source))
        project = self.insert(base, "sequence", 0)
        output = self.root / "dynamic-pq.mov"
        for mode in ("smart", "encode"):
            with self.subTest(mode=mode):
                flags = ["--video", "hevc"] if mode == "encode" else []
                result = self.export(project, output, "--tracks", "video", "--mode", mode,
                                     "--dry-run", *flags, ok=False)
                self.assertEqual(result["error"]["code"], "unsupported_dynamic_hdr")
                self.assertIn("HDR10+", result["error"]["message"])
                self.assertFalse(result["error"].get("alternatives"))
        self.assertFalse(output.exists())

    def test_unregistered_hevc_sei_can_contain_hdr10plus_identifier(self):
        row = ROWS[2]
        camera = self.sources[row.name][0]
        source = self.root / "unregistered-sei.mov"
        # Use the registered HDR10+ identifier as the prefix of a type 5
        # user_data_unregistered UUID.
        payload = bytes.fromhex("b5003c000104123456789abcdef01234") + b"camera note"
        camera_with_hevc_sei(camera, source, 5, payload)
        base = self.project(row, "sequence", sources=(source, source))
        project = self.insert(base, "sequence", 0)
        output = self.root / "unregistered-sei-title.mov"
        self.export(project, output, "--require-camera-copy", "--tracks", "video")
        self.assertEqual(sample_hashes(output)[FPS:], sample_hashes(source))

    def test_mid_gop_requires_camera_boundary_review(self):
        row = ROWS[0]
        base = self.project(row, "sequence")
        project = self.replace(base, "sequence", 2, Fraction(7, 2))
        output = self.root / "mid-gop.mp4"
        refused = self.export(project, output, "--require-camera-copy", "--tracks", "video", "--dry-run", ok=False)
        self.assertEqual(refused["error"]["code"], "camera_copy_required")
        adjustments = refused["error"]["still_boundary_adjustments"]
        self.assertTrue(adjustments)
        for adjustment in adjustments:
            self.assertEqual(adjustment["boundary"], "end")
            self.assertEqual(fraction(adjustment["requested_time"]), Fraction(7, 2))
            self.assertEqual(fraction(adjustment["adjusted_time"]) - Fraction(7, 2),
                             fraction(adjustment["duration_change"]))
        self.assertFalse(output.exists())
        report = self.export(project, output, "--mode", "smart", "--tracks", "video")
        self.assertGreater(fraction(report["encoded_camera_duration"]), 0)
        self.assertEqual(fraction(report["generated_still_duration"]), Fraction(3, 2))
        self.assertEqual(duration(stream_info(output, "v:0")), LENGTH)
        decoded = frames(output)
        self.assertEqual(len(decoded), LENGTH * FPS)
        self.assert_card(output, row, 3)
        retained = {at: digest for at, digest in timestamped_hashes(self.sources[row.name][0])
                    if at < 2 or at >= 4}
        actual = dict(timestamped_hashes(output))
        self.assertEqual({at: actual[at] for at in retained}, retained)
        for seam in (2, Fraction(7, 2)):
            self.assertEqual(frames(output, seek=float(seam - Fraction(1, 4 * FPS)))[0], decoded[int(seam * FPS)])

    def test_smart_camera_edges_plan_the_export_refusals(self):
        # Captions on the camera pictures that Smart Trim would re-encode stop the export while it writes. A sequence
        # or multicam program with a still placement plans those edges itself, and refuses them the same way.
        row = ROWS[0]
        wide, close = (with_h264_sei(source, self.root / f"captioned-{source.name}", CAPTION_SEI, fps=FPS,
                                     timescale=FPS * 1_000) for source in self.sources[row.name])
        for kind in ("sequence", "multicam"):
            with self.subTest(kind=kind):
                base = self.project(row, kind, sources=(wide, close), label="captioned")
                # The camera returns mid-GOP at 3.5 s, so its first pictures are a Smart Trim edge.
                project = self.replace(base, kind, 2, Fraction(7, 2))
                output = self.root / f"captioned-{kind}.mp4"
                for dry in (True, False):
                    flags = ["--mode", "smart", "--tracks", "video"] + (["--dry-run"] if dry else [])
                    error = self.export(project, output, *flags, ok=False)["error"]
                    self.assertEqual((error["code"], error["reason"]), ("unsupported_format", "source_smart_ineligible"),
                                     (dry, error))
                    self.assertIn("captions or colour metadata", error["message"])
                    self.assertFalse(output.exists())
        # Film grain the camera edge loses is a warning in both reports. Only the returning camera has an edge.
        grain = [with_h264_sei(source, self.root / f"grain-{source.name}", FILM_GRAIN_SEI, fps=FPS, timescale=FPS * 1_000)
                 for source in self.sources[row.name]]
        for kind, edged in (("sequence", grain[0]), ("multicam", grain[1])):
            with self.subTest(kind=kind, grain=True):
                project = self.replace(self.project(row, kind, sources=grain, label="grain"), kind, 2, Fraction(7, 2))
                output = self.root / f"grain-{kind}.mp4"
                plan = self.export(project, output, "--mode", "smart", "--tracks", "video", "--dry-run")
                report = self.export(project, output, "--mode", "smart", "--tracks", "video")
                for result in (plan, report):
                    self.assertGreater(fraction(result["encoded_camera_duration"]), 0)
                    self.assertEqual([note for note in result["warnings"] if "film grain" in note], [film_grain_note(edged)])

    def test_hdr_mid_gop_requires_boundary_adjustment_or_full_conversion(self):
        for row in (row for row in ROWS if row.hdr):
            with self.subTest(row=row.name):
                base = self.project(row, "sequence")
                project = self.replace(base, "sequence", 2, Fraction(7, 2))
                output = self.root / f"{row.name}-mid-gop.mov"
                flags = ["--tracks", "video", "--dry-run"]
                strict = self.export(project, output, "--require-camera-copy", *flags, ok=False)["error"]
                self.assertEqual(strict["code"], "camera_copy_required")
                self.assertTrue(strict["still_boundary_adjustments"])
                smart = self.export(project, output, "--mode", "smart", *flags, ok=False)["error"]
                self.assertTrue(smart["still_boundary_adjustments"])
                self.assertFalse(output.exists())
                written = self.export(project, output, "--mode", "encode", "--video", "hevc", "--tracks", "video")
                self.assertEqual(fraction(written["encoded_camera_duration"]), Fraction(9, 2))
                self.assertEqual(fraction(written["generated_still_duration"]), Fraction(3, 2))
                self.assertEqual(duration(stream_info(output, "v:0")), LENGTH)
                self.assertEqual(len(frames(output)), LENGTH * FPS)

    def test_replacement_preserves_multitrack_aac_payloads(self):
        row = ROWS[0]
        two_tracks = self.root / "two-tracks.mp4"
        camera(two_tracks, row, extra_track=True)
        alternate_sound = self.sources[row.name][1]
        replacement = self.root / "replacement-sound.mp4"
        ffmpeg("-i", two_tracks, "-i", alternate_sound, "-map", "0:v", "-map", "0:a:0", "-map", "1:a:0",
               "-c", "copy", replacement)
        for label, source in (("original", two_tracks), ("replaced-soundtrack", replacement)):
            with self.subTest(source=label):
                base = self.project(row, "sequence", sources=(source, source), label=label)
                if source == replacement:
                    document = read_project(base)
                    document["clips"][0].update(original_file=str(two_tracks), track_ordinal=1,
                                                replacement_names={"1": "Close microphone"})
                    base.write_text(json.dumps(document))
                covered = self.replace(base, "sequence", 2, 4)
                reference = self.root / f"{label}-reference.mp4"
                output = self.root / f"{label}-covered.mp4"
                self.export(base, reference)
                self.export(covered, output, "--require-camera-copy")
                for track in range(2):
                    self.assertEqual(sample_hashes(output, f"a:{track}"), sample_hashes(reference, f"a:{track}"))
                    self.assertEqual(decoded_audio(output, track), decoded_audio(reference, track))

    def test_repeated_group_placement_and_single_assembly_insert(self):
        row = ROWS[1]
        wide = self.root / "wide.mov"
        close = self.root / "close.mov"
        camera(wide, row, seconds=8)
        camera(close, row, angle=1, seconds=8)
        base = self.project(row, "multicam", sources=(wide, close), assembly=[(4, 8), (4, 8)], length=8)
        project = self.replace(base, "multicam", 5, 7)
        project = self.insert(project, "multicam", 4)
        reference, output = (self.root / name for name in ("reference.mov", "covered.mov"))
        self.export(base, reference, "--tracks", "video")
        report = self.export(project, output, "--require-camera-copy", "--tracks", "video")
        self.assert_report(report, copied=4, generated=5)
        self.assert_picture(output, row, reference,
                            [(0, 1), (None, 2), (3, 1), (None, 1), (4, 1), (None, 2), (7, 1)])

    def test_multicam_audio_angle_switch_continues_under_replacement(self):
        row = ROWS[1]
        base = self.project(row, "multicam")
        document = read_project(base)
        document["audio"] = {"mode": "follow"}
        base.write_text(json.dumps(document))
        covered = self.replace(base, "multicam", 2, 4)
        reference, output = (self.root / name for name in ("reference.mov", "covered.mov"))
        self.export(base, reference)
        report = self.export(covered, output, "--require-camera-copy")
        self.assert_report(report, copied=4, generated=2)
        self.assert_picture(output, row, reference, [(0, 2), (None, 2), (4, 2)])
        wide, close = self.sources[row.name]
        switch_sample = 3 * SAMPLE_RATE * 4
        expected = decoded_audio(wide)[:switch_sample] + decoded_audio(close)[switch_sample:]
        self.assertEqual(decoded_audio(output), expected)

    def test_replacement_follows_the_second_occurrence_when_reordered(self):
        row = ROWS[1]
        base = self.project(row, "sequence", repeated=True)
        covered = self.replace(base, "sequence", 8, 10)
        reference, output = (self.root / name for name in ("reference.mov", "covered.mov"))
        self.export(base, reference, "--tracks", "video")
        self.export(covered, output, "--require-camera-copy", "--tracks", "video")
        self.assert_picture(output, row, reference, [(0, 8), (None, 2), (10, 2)])
        document = read_project(covered)
        document["clips"].reverse()
        # Drop history after moving the entries by hand. Their openable state and
        # occurrence IDs remain identical to those saved by the authoring command.
        document.pop("history", None)
        reordered = self.root / "reordered.cut"
        reordered.write_text(json.dumps(document))
        reopened = self.root / "reordered.mov"
        self.export(reordered, reopened, "--require-camera-copy", "--tracks", "video")
        self.assert_picture(reopened, row, reference, [(6, 2), (None, 2), (10, 2), (0, 6)])

    def test_fractional_frame_inserts_use_cumulative_pcm_endpoints(self):
        row = ROWS[1]
        wide = self.root / "ntsc.mov"
        fps = Fraction(30000, 1001)
        frame_duration = 1 / fps
        length = 180 * frame_duration
        camera(wide, row, fps=fps, seconds=float(length))
        project = self.project(row, "sequence", sources=(wide, wide), length=length)
        for index in range(5):
            project = self.insert(project, "sequence", index * frame_duration, count=1, rate=fps)
        output = self.root / "ntsc-title.mov"
        report = self.export(project, output, "--require-camera-copy")
        self.assert_report(report, copied=length, generated=5 * frame_duration)
        self.assertEqual(duration(stream_info(output, "v:0")), 185 * frame_duration)
        sound = decoded_audio(output)
        self.assertEqual(sound, bytes(8008 * 4) + decoded_audio(wide))
        self.assertEqual(frames(output)[5], frames(wide)[0])

    def test_audio_only_copy_ignores_offline_replacement_pixels(self):
        row = ROWS[0]
        base = self.project(row, "sequence")
        photo = self.root / "offline.png"
        photo.write_bytes(self.sdr_card.read_bytes())
        project = self.replace(base, "sequence", 2, 4, image=photo)
        photo.unlink()
        refused = self.export(project, self.root / "offline.mp4", "--dry-run", ok=False)
        self.assertIn("offline.png", refused["error"]["message"])
        output = self.root / "audio.m4a"
        self.export(project, output, "--tracks", "audio")
        self.assertEqual(sample_hashes(output, "a:0"), sample_hashes(self.sources[row.name][0], "a:0"))
        self.assertEqual(decoded_audio(output), decoded_audio(self.sources[row.name][0]))

    def test_wholly_covered_camera_still_supplies_format_and_sound(self):
        row = ROWS[1]
        base = self.project(row, "sequence")
        project = self.replace(base, "sequence", 0, LENGTH)
        output = self.root / "covered.mov"
        report = self.export(project, output, "--require-camera-copy")
        self.assert_report(report, copied=0, generated=LENGTH)
        self.assert_picture(output, row, self.sources[row.name][0], [(None, LENGTH)])
        self.assert_card(output, row, Fraction(3, 2))
        self.assertEqual(decoded_audio(output), decoded_audio(self.sources[row.name][0]))

    def test_fit_and_fill_render_different_picture_geometry(self):
        row = ROWS[1]
        base = self.project(row, "sequence")
        portrait = self.root / "portrait.png"
        ffmpeg("-f", "lavfi", "-i", "color=white:s=120x180", "-frames:v", "1", "-threads", "1", portrait)
        project = self.replace(base, "sequence", 2, 4, image=portrait)
        output = self.root / "fit.mov"
        self.export(project, output, "--require-camera-copy", "--tracks", "video")
        outside_left, center, outside_right = luma_at(output, 3)
        self.assertLess(max(outside_left, outside_right), 30)
        self.assertGreater(center, 220)

        report = self.cli("still", "placement", "list", "--project", project)
        self.cli("still", "placement", "update", "--project", project, "--placement", report["placements"][0]["id"],
                 "--fit", "fill", "--crop-x", "1/10", "--crop-y", "1/10", "--in-place")
        output = self.root / "fill.mov"
        self.export(project, output, "--require-camera-copy", "--tracks", "video")
        self.assertGreater(min(luma_at(output, 3)), 220)

    def test_trim_hides_and_widening_restores_authored_picture(self):
        row = ROWS[1]
        base = self.project(row, "sequence")
        project = self.replace(base, "sequence", 4, 5)
        document = read_project(project)
        # Retain the exact authored placement and occurrence ID while changing its
        # current trim, as a sequence editor does.
        document.pop("history", None)
        document["clips"][0]["to"] = "3"
        trimmed = self.root / "trimmed.cut"
        trimmed.write_text(json.dumps(document))
        listed = self.cli("still", "placement", "list", "--project", trimmed)["placements"][0]
        self.assertEqual(fraction(listed["visible_duration"]), 0)
        self.assertEqual(len(listed["authored_fragments"]), 1)
        trimmed_output = self.root / "trimmed.mov"
        hidden = self.export(trimmed, trimmed_output, "--tracks", "video")
        self.assertEqual(fraction(hidden["duration"]), 3)
        self.assert_picture(trimmed_output, row, self.sources[row.name][0], [(0, 3)])
        document["clips"][0]["to"] = str(LENGTH)
        widened = self.root / "widened.cut"
        widened.write_text(json.dumps(document))
        widened_output = self.root / "widened.mov"
        restored = self.export(widened, widened_output, "--require-camera-copy", "--tracks", "video")
        self.assert_report(restored, copied=5, generated=1)
        self.assert_picture(widened_output, row, self.sources[row.name][0], [(0, 4), (None, 1), (5, 1)])

    def test_strict_avc_aac_insert_requires_explicit_sound_conversion(self):
        row = ROWS[0]
        base = self.project(row, "sequence")
        project = self.insert(base, "sequence", 2)
        output = self.root / "avc-aac-title.mp4"
        request = ["--mode", "smart", "--require-camera-copy"]
        refused = self.export(project, output, *request, "--audio", "copy", "--dry-run", ok=False)
        self.assertIn("track", refused["error"]["message"].lower())
        self.assertFalse(output.exists())
        self.assertTrue(refused["error"]["alternatives"])
        alternate = next(item for item in refused["error"]["alternatives"] if item.get("audio") == "aac")
        self.assertIn("--require-camera-copy", alternate["arguments"])
        report = self.export(project, output, *alternate["arguments"])
        self.assert_report(report, copied=LENGTH, generated=1)

    def test_explicit_copy_offers_smart_and_stdin_matches_dry_run(self):
        row = ROWS[1]
        base = self.project(row, "sequence")
        project = self.replace(base, "sequence", 2, 4)
        output = self.root / "alternate.mov"
        refused = self.export(project, output, "--mode", "copy", "--tracks", "video", "--dry-run", ok=False)
        self.assertEqual(refused["error"]["code"], "still_requires_generation")
        alternate = next(item for item in refused["error"]["alternatives"] if item["mode"] == "smart")
        arguments = alternate["arguments"]
        planned = self.export(project, output, *arguments, "--dry-run")
        self.assert_report(planned, copied=4, generated=2)
        from_document = self.export("-", output, *arguments, "--dry-run", stdin=json.dumps(read_project(project)))
        from_request = self.cli("export", "project", "render", "--stdin", "--dry-run",
                                stdin=json.dumps({"project_path": str(project), "output": str(output),
                                                  "mode": "smart", "tracks": "video"}))
        self.assertEqual(planned, from_document)
        self.assertEqual(planned, from_request)
        self.assertFalse(output.exists())

    def test_smart_prores_offers_mov_when_mp4_cannot_preserve_camera(self):
        row = next(row for row in ROWS if row.name == "prores")
        project = self.replace(self.project(row, "sequence"), "sequence", 2, 4)
        output = self.root / "camera-copy.mp4"
        failure = self.export(project, output, "--mode", "smart", "--audio", "remove",
                              "--require-camera-copy", "--dry-run", ok=False)["error"]
        alternate = next(item for item in failure["alternatives"] if item["mode"] == "smart")
        self.assertEqual(alternate["container"], "mov")
        self.assertIn("--require-camera-copy", alternate["arguments"])
        planned = self.export(project, output.with_suffix(".mov"), *alternate["arguments"], "--dry-run")
        self.assert_report(planned, copied=4, generated=2)
        self.assertEqual(planned["sound_actions"], [])

    def test_prores_encode_offers_mov_for_an_incompatible_container(self):
        row = next(row for row in ROWS if row.name == "prores")
        project = self.replace(self.project(row, "sequence"), "sequence", 2, 4)
        output = self.root / "conversion.mp4"
        failure = self.export(project, output, "--mode", "encode", "--video", "prores", "--tracks", "video",
                              "--dry-run", ok=False)["error"]
        alternate = next(item for item in failure["alternatives"] if item["mode"] == "encode")
        self.assertEqual(alternate["container"], "mov")
        self.assertEqual(alternate["codec"], "prores")
        planned = self.export(project, output.with_suffix(".mov"), *alternate["arguments"], "--dry-run")
        self.assertEqual(fraction(planned["copied_camera_duration"]), 0)
        self.assertEqual(fraction(planned["encoded_camera_duration"]), 4)
        self.assertEqual(fraction(planned["generated_still_duration"]), 2)

    def test_encode_preflight_rejects_inexact_constant_rate_still_clock(self):
        row = next(row for row in ROWS if row.name == "prores")
        project = self.insert(self.project(row, "sequence"), "sequence", 2, count=3, rate="30001/1000")
        output = self.root / "inexact-clock.mov"
        failure = self.export(project, output, "--mode", "encode", "--tracks", "video",
                              "--video", "prores", "--dry-run", ok=False)["error"]
        self.assertEqual(failure["code"], "unsupported_still_timing")
        self.assertFalse(output.exists())

    def test_still_export_refuses_unsupported_sound_formats(self):
        row = next(row for row in ROWS if row.name == "prores")
        mixed = self.replace(self.project(row, "sequence"), "sequence", 2, 4)
        standalone = self.root / "standalone.cut"
        self.cli("still", "project", "create", "--out-project", standalone, "--image", self.sdr_card,
                 "--width", SIZE[0], "--height", SIZE[1], "--rate", FPS,
                 "--codec", "prores", "--container", "mov", "--color", "sdr", "--frames", FPS)
        output = self.root / "unsupported-sound.mov"
        for project in (mixed, standalone):
            for audio in ("mp3", "flac"):
                with self.subTest(project=project.name, audio=audio):
                    failure = self.export(project, output, "--mode", "smart", "--audio", audio,
                                          "--dry-run", ok=False)["error"]
                    self.assertEqual(failure["code"], "unsupported_audio")
                    self.assertFalse(output.exists())

    def test_hdr_full_conversion(self):
        for row in (row for row in ROWS if row.hdr):
            for kind in ("sequence", "multicam"):
                with self.subTest(row=row.name, kind=kind):
                    base = self.project(row, kind)
                    project = self.replace(base, kind, 2, 4)
                    project = self.insert(project, kind, 0, image=self.hdr_cards[row.name])
                    output = self.root / f"{row.name}-{kind}-converted.mov"
                    report = self.export(project, output, "--mode", "encode", "--video", "hevc", "--tracks", "video")
                    self.assertEqual(fraction(report["copied_camera_duration"]), 0)
                    self.assertEqual(fraction(report["encoded_camera_duration"]), 4)
                    self.assertEqual(fraction(report["generated_still_duration"]), 3)
                    picture = stream_info(output, "v:0")
                    self.assertEqual((picture["pix_fmt"], picture.get("color_transfer")), ("yuv420p10le", row.transfer))
                    self.assertEqual(duration(picture), 7)
                    self.assert_card(output, row, Fraction(1, 2), hdr=True)
                    self.assert_card(output, row, Fraction(7, 2))
                    self.assertEqual(len(frames(output)), 7 * FPS)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cli")
    parser.add_argument("tests", nargs="*")
    arguments = parser.parse_args()
    CLI = str(Path(arguments.cli).resolve())
    unittest.main(argv=[__file__, *arguments.tests], verbosity=2)
