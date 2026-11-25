#!/usr/bin/env python3
"""Verify standalone still authoring, exact picture timing, and tagged delivery."""
import argparse
from array import array
from fractions import Fraction
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import wave
from xml.etree import ElementTree

from media_regression import ffmpeg, probe, run, sample_hashes
from saved_project import read_project

CLI = None


class StillOnlyTests(unittest.TestCase):
    def test_saved_soundtrack_identity_only_gates_sound(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-soundtrack-identity-") as directory:
            root = Path(directory)
            cover = root / "cover.png"
            project = root / "cover.cut"
            recording = root / "recording.wav"
            ffmpeg("-f", "lavfi", "-i", "color=red:size=64x36", "-frames:v", "1", cover)
            with wave.open(str(recording), "wb") as wav:
                wav.setparams((1, 2, 48000, 48001, "NONE", "not compressed"))
                wav.writeframes(bytes(48001 * 2))
            run([CLI, "still", "project", "create", "--out-project", project, "--image", cover,
                 "--width", "64", "--height", "36", "--rate", "30",
                 "--soundtrack", recording, "--fit-soundtrack", "--json"])
            command = [CLI, "export", "project", "render", "--project", project,
                       "--output", root / "cover.mov", "--audio", "pcm", "--dry-run", "--json"]
            run(command)
            original = recording.stat()
            # Keep the audio format, sample count and file size while replacing the media generation.
            with recording.open("r+b") as changed:
                changed.seek(-2, os.SEEK_END)
                changed.write(bytes([1, 0]))
            os.utime(recording, ns=(original.st_atime_ns, original.st_mtime_ns + 2_000_000_000))
            self.assertEqual(recording.stat().st_size, original.st_size)
            rejected = subprocess.run(command, capture_output=True, text=True, check=False, timeout=30)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(json.loads(rejected.stdout)["error"]["code"], "source_changed")
            video_plan = json.loads(run([*command, "--tracks", "video"]))
            self.assertEqual(video_plan["generated_video_sample_count"], 1)
            self.assertEqual(video_plan["sound_actions"], [])

    def test_single_gap_black_and_custom_color(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-color-gap-") as directory:
            root = Path(directory)
            cut = root / "background.cut"
            report = json.loads(run([CLI, "still", "project", "create", "--gap", "--out-project", cut, "--width", "160",
                                     "--height", "96", "--rate", "24", "--codec", "h264", "--container", "mov",
                                     "--frames", "12", "--json"]))
            for name, expected in [("black", (0, 0, 0)), ("red", (255, 0, 0))]:
                if name == "red":
                    run([CLI, "still", "placement", "update", "--project", cut, "--placement", report["placement_id"],
                         "--background", "#FF0000", "--in-place"])
                output = root / (name + ".mov")
                command = [CLI, "export", "project", "render", "--project", cut, "--output", output, "--json"]
                dry_run = json.loads(run([*command, "--dry-run"], allow_diagnostics=True))
                self.assertNotIn("output_bytes", dry_run)
                self.assertFalse(output.exists())
                result = json.loads(run(command, allow_diagnostics=True))
                self.assertEqual(result["output_bytes"], output.stat().st_size)
                pixels = ffmpeg("-i", output, "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-")
                self.assertEqual(len(pixels), 160 * 96 * 3)
                for channel, target in enumerate(expected):
                    self.assertLess(max(abs(value - target) for value in pixels[channel::3]), 5)

    def test_fcpxml_still_asset_clip_and_relative_media(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-fcpxml-still-") as directory:
            root = Path(directory)
            image = root / "Card #1.png"
            ffmpeg("-f", "lavfi", "-i", "color=white:size=80x80", "-frames:v", "1", image)
            cut = root / "Stills.cut"
            xml = root / "Stills.fcpxml"
            run([
                CLI, "still", "project", "create", "--out-project", cut, "--image", image,
                "--width", "320", "--height", "180", "--rate", "24",
                "--codec", "h264", "--container", "mov", "--frames", "12",
            ])
            run([CLI, "project", "convert", cut, "--output", xml])
            tree = ElementTree.parse(xml)
            tree.find(".//spine/video").tag = "asset-clip"
            tree.find(".//media-rep").set("src", "Card%20%231.png")
            tree.write(xml, encoding="utf-8", xml_declaration=True)
            sibling = root / "Sibling.cut"
            run([CLI, "project", "convert", xml, "--output", sibling])
            sibling_project = read_project(sibling)
            self.assertEqual(sibling_project["still_assets"][0]["file"], image.name)
            nested = root / "nested"
            nested.mkdir()
            restored = nested / "Restored.cut"
            run([CLI, "project", "convert", xml, "--output", restored])
            original = read_project(cut)
            result = read_project(restored)
            self.assertEqual(result["clips"], original["clips"])
            self.assertEqual(result["still_format"], original["still_format"])
            self.assertEqual(result["still_assets"][0]["file"], "../Card #1.png")

    def test_interchange_refuses_a_timeline_with_no_retained_material(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-conversion-") as directory:
            root = Path(directory)
            image = root / "Card.png"
            cut = root / "Stills.cut"
            ffmpeg("-f", "lavfi", "-i", "color=white:size=80x80", "-frames:v", "1", image)
            create = [
                CLI, "still", "project", "create", "--image", image,
                "--width", "320", "--height", "180", "--rate", "24",
                "--container", "mov", "--frames", "12",
            ]
            run([*create, "--out-project", cut, "--codec", "h264"])
            hdr = root / "HDR.cut"
            run([*create, "--out-project", hdr, "--codec", "hevc", "--color", "pq"])
            for source, extension in [(cut, "drp"), (cut, "drt"), (cut, "prproj"), (hdr, "fcpxml")]:
                output = root / f"Converted.{extension}"
                command = [CLI, "project", "convert", source, "--output", output, "--json"]
                for flags, code in [([], "conversion_loss"), (["--allow-loss"], "empty_sequence")]:
                    with self.subTest(extension=extension, code=code):
                        result = subprocess.run([*command, *flags], capture_output=True, timeout=60)
                        self.assertNotEqual(result.returncode, 0)
                        error = json.loads(result.stdout)["error"]
                        self.assertEqual(error["code"], code)
                        self.assertIn("Insert Still placement", error["message"])
                        self.assertFalse(output.exists())

    def test_creation_rejects_fractional_frame_and_preserves_existing_destination(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-invalid-") as directory:
            root = Path(directory)
            image = root / "first.png"
            cut = root / "stills.cut"
            ffmpeg("-f", "lavfi", "-i", "color=white:size=80x80", "-frames:v", "1", image)
            command = [
                CLI, "still", "project", "create", "--out-project", cut, "--image", image,
                "--width", "320", "--height", "180", "--rate", "30000/1001",
                "--codec", "h264", "--container", "mp4", "--duration",
            ]
            result = subprocess.run([*command, "1", "--json"], capture_output=True, timeout=60)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(cut.exists())
            run([*command, "1001/30000"])
            original = cut.read_bytes()
            result = subprocess.run([*command, "1001/15000", "--json"], capture_output=True, timeout=60)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(cut.read_bytes(), original)

    def test_gain_map_still_shows_its_sdr_base_on_an_sdr_timeline(self):
        # The fixtures' SDR base holds linear 0.5 and SDR white. Their HDR rendition holds 0.5 and 4.0,
        # which the SDR shoulder would put at 248 instead of white.
        fixtures = Path(__file__).with_name("fixtures") / "stills"
        with tempfile.TemporaryDirectory(prefix="mpcut-gain-map-sdr-") as directory:
            root = Path(directory)
            for suffix in ("jpeg", "heic"):
                with self.subTest(codec=suffix):
                    cut = root / f"{suffix}.cut"
                    run([CLI, "still", "project", "create", "--out-project", cut, "--image", fixtures / f"gain-map.{suffix}",
                         "--width", "64", "--height", "64", "--rate", "30", "--codec", "h264", "--container", "mp4",
                         "--color", "sdr", "--frames", "30", "--json"])
                    review = root / f"{suffix}-review"
                    report = json.loads(run([CLI, "review", "frames", "export", "--json", "--project", cut,
                                             "--preset", "full", "--at", "0", "--output", review]))
                    movie = root / f"{suffix}.mp4"
                    run([CLI, "export", "project", "render", "--project", cut, "--output", movie, "--json"],
                        allow_diagnostics=True)
                    for picture in (review / report["frames"][0]["file"], movie):
                        pixels = ffmpeg("-i", picture, "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-")
                        self.assertEqual(len(pixels), 64 * 64 * 3)
                        middle, white = (pixels[(32 * 64 + x) * 3] for x in (16, 48))
                        self.assertAlmostEqual(middle, 185, delta=6, msg=picture.name)
                        self.assertGreaterEqual(white, 253, msg=picture.name)

    def test_generated_delivery(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-only-") as directory:
            root = Path(directory)
            image = root / "first.png"
            ffmpeg("-f", "lavfi", "-i", "color=white:size=80x80", "-frames:v", "1", image)
            last_image = root / "last.png"
            ffmpeg("-f", "lavfi", "-i", "color=black:size=80x80", "-frames:v", "1", last_image)
            for codec, extension, program_color, transfer in [
                ("h264", "mp4", "sdr", "bt709"),
                ("h264", "mov", "sdr", "bt709"),
                ("prores", "mov", "sdr", "bt709"),
                ("prores", "mov", "pq", "smpte2084"),
                ("prores", "mov", "hlg", "arib-std-b67"),
                ("hevc", "mov", "sdr", "bt709"),
                ("hevc", "mov", "pq", "smpte2084"),
                ("hevc", "mov", "hlg", "arib-std-b67"),
                ("hevc", "mp4", "sdr", "bt709"),
                ("hevc", "mp4", "pq", "smpte2084"),
                ("hevc", "mp4", "hlg", "arib-std-b67"),
            ]:
                with self.subTest(codec=codec, container=extension, color=program_color):
                    name = f"{codec}-{extension}-{program_color}"
                    cut = root / f"{name}.cut"
                    output = root / f"{name}.{extension}"
                    run([
                        CLI, "still", "project", "create", "--out-project", cut, "--image", image,
                        "--width", "320", "--height", "180", "--rate", "30000/1001",
                        "--codec", codec, "--container", extension, "--color", program_color, "--frames", "5",
                    ])
                    project = read_project(cut)
                    self.assertEqual(project["schema_version"], 9)
                    self.assertEqual(project["clips"][0]["kind"], "still")
                    self.assertEqual(project["still_assets"][0]["file"], image.name)
                    self.assertEqual(project["program_color_policy"]["transfer"], transfer)
                    run([
                        CLI, "still", "placement", "insert", "--project", cut, "--image", last_image, "--clock", "sequence", "--at", "1001/6000", "--duration", "1001/30000", "--in-place", "--json",
                    ])
                    report = json.loads(run([
                        CLI, "export", "project", "render", "--project", cut, "--require-camera-copy", "--output", output, "--json",
                    ], allow_diagnostics=True))
                    self.assertEqual(report["copied_camera_duration"], {"numerator": 0, "denominator": 1})
                    self.assertEqual(report["encoded_camera_duration"], {"numerator": 0, "denominator": 1})
                    self.assertEqual(report["generated_still_duration"], {"numerator": 1001, "denominator": 5000})
                    streams = probe(output, "-show_streams", "-count_frames")["streams"]
                    self.assertEqual(len(streams), 1)
                    stream = streams[0]
                    self.assertEqual(stream["codec_name"], codec)
                    self.assertEqual(stream["color_transfer"], transfer)
                    self.assertEqual((stream["width"], stream["height"]), (320, 180))
                    self.assertEqual(int(stream["nb_read_frames"]), 6)
                    self.assertEqual(Fraction(stream["time_base"]) * int(stream["duration_ts"]), Fraction(1001, 5000))
                    frames = ffmpeg("-i", output, "-vf", "crop=2:2:160:90,format=gray", "-f", "rawvideo", "-")
                    self.assertEqual(len(frames), 6 * 4)
                    self.assertGreater(frames[0], frames[-1] + 64)

    def test_still_only_hevc_keeps_deep_images_in_main_10(self):
        # A 16-bit ramp across four 8-bit codes. HEVC Main keeps 4 levels of it, Main 10 about 14.
        with tempfile.TemporaryDirectory(prefix="mpcut-still-depth-") as directory:
            root = Path(directory)
            deep = root / "ramp16.png"
            shallow = root / "ramp8.png"
            ffmpeg("-f", "lavfi", "-i", "nullsrc=s=320x180,format=gray16le,geq=lum='32382+1028*X/W'",
                   "-frames:v", "1", "-pix_fmt", "rgb48be", deep)
            ffmpeg("-i", deep, "-pix_fmt", "rgb24", shallow)
            for image, profile, pixel_format, minimum_levels in ((deep, "Main 10", "yuv420p10le", 10),
                                                                  (shallow, "Main", "yuv420p", 1)):
                with self.subTest(image=image.name):
                    cut = root / f"{image.stem}.cut"
                    output = root / f"{image.stem}.mov"
                    run([CLI, "still", "project", "create", "--out-project", cut, "--image", image,
                         "--width", "320", "--height", "180", "--rate", "30", "--codec", "hevc",
                         "--container", "mov", "--frames", "5"])
                    run([CLI, "export", "project", "render", "--project", cut, "--require-camera-copy",
                         "--output", output, "--json"], allow_diagnostics=True)
                    stream = probe(output, "-show_streams")["streams"][0]
                    self.assertEqual((stream["profile"], stream["pix_fmt"]), (profile, pixel_format))
                    self.assertEqual(stream["color_transfer"], "bt709")
                    row = ffmpeg("-i", output, "-frames:v", "1", "-vf", "format=gray16le,crop=iw:1:0:ih/2",
                                 "-f", "rawvideo", "-")
                    levels = len(set(array("H", row)))
                    self.assertGreaterEqual(levels, minimum_levels)
                    if profile == "Main":
                        self.assertLessEqual(levels, 5)

    def test_still_only_quality_chooses_prores_profile_and_compression(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-quality-") as directory:
            root = Path(directory)
            image = root / "pattern.png"
            ffmpeg("-f", "lavfi", "-i", "testsrc2=s=640x360", "-frames:v", "1", image)
            sizes = {}
            for codec, quality, tag in (("prores", None, "apcn"), ("prores", "422-lt", "apcs"),
                                        ("prores", "422-hq", "apch"), ("h264", None, "avc1"),
                                        ("h264", "smaller", "avc1"), ("h264", "balanced", "avc1"),
                                        ("h264", "high", "avc1"), ("hevc", None, "hvc1"),
                                        ("hevc", "smaller", "hvc1"), ("hevc", "balanced", "hvc1"),
                                        ("hevc", "high", "hvc1")):
                with self.subTest(codec=codec, quality=quality):
                    name = f"{codec}-{quality or 'default'}"
                    cut = root / f"{name}.cut"
                    output = root / f"{name}.mov"
                    run([CLI, "still", "project", "create", "--out-project", cut, "--image", image,
                         "--width", "640", "--height", "360", "--rate", "30", "--codec", codec,
                         "--container", "mov", "--frames", "30"])
                    run([CLI, "export", "project", "render", "--project", cut, "--require-camera-copy",
                         "--output", output, "--json", *(["--quality", quality] if quality else [])],
                        allow_diagnostics=True)
                    stream = probe(output, "-show_streams")["streams"][0]
                    self.assertEqual((stream["codec_name"], stream["codec_tag_string"]), (codec, tag))
                    sizes[(codec, quality)] = output.stat().st_size
            self.assertLess(sizes[("prores", "422-lt")], sizes[("prores", None)])
            self.assertGreater(sizes[("prores", "422-hq")], sizes[("prores", None)])
            for codec in ("h264", "hevc"):
                self.assertLess(sizes[(codec, "smaller")], sizes[(codec, None)] * 0.8)
                # No --quality keeps the still default, which is Re-encode's High Quality: the same encode, byte for byte.
                # An explicit Balanced is Re-encode's Balanced (q60 against q75: about three quarters of the size here),
                # between Smaller File and High Quality.
                self.assertEqual(sizes[(codec, "high")], sizes[(codec, None)])
                self.assertLess(sizes[(codec, "balanced")], sizes[(codec, None)] * 0.9)
                self.assertLess(sizes[(codec, "smaller")], sizes[(codec, "balanced")] * 0.9)

    def test_explicit_conversion_uses_stored_delivery(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-convert-") as directory:
            root = Path(directory)
            image = root / "card.png"
            cut = root / "stills.cut"
            output = root / "stills.mov"
            ffmpeg("-f", "lavfi", "-i", "color=white:size=80x80", "-frames:v", "1", image)
            run([
                CLI, "still", "project", "create", "--out-project", cut, "--image", image,
                "--width", "320", "--height", "180", "--rate", "30000/1001",
                "--codec", "hevc", "--container", "mov", "--color", "pq", "--frames", "5", "--json",
            ])
            run([
                CLI, "export", "project", "render", "--project", cut, "--mode", "encode", "--require-camera-copy", "--output", output, "--json",
            ], allow_diagnostics=True)
            streams = probe(output, "-show_streams", "-count_frames")["streams"]
            self.assertEqual(len(streams), 1)
            stream = streams[0]
            self.assertEqual(stream["codec_name"], "hevc")
            self.assertEqual(stream["color_transfer"], "smpte2084")
            self.assertEqual(int(stream["nb_read_frames"]), 5)
            self.assertEqual(Fraction(stream["time_base"]) * int(stream["duration_ts"]), Fraction(1001, 6000))

    def soundtrack_export(self, root, cover, recording, container, *options, codec="h264"):
        """Renders a one-picture project whose soundtrack is `recording`, and returns the movie and its sound action."""
        folder = Path(tempfile.mkdtemp(dir=root))
        project = folder / "cover.cut"
        run([CLI, "still", "project", "create", "--out-project", project, "--image", cover, "--width", "64", "--height", "36",
             "--rate", "30", "--codec", codec, "--container", container, "--soundtrack", recording, "--fit-soundtrack", "--json"],
            allow_diagnostics=True)
        output = folder / f"cover.{container}"
        report = json.loads(run([CLI, "export", "project", "render", "--project", project, "--output", output,
                                 "--no-sidecar", "--json", *options], allow_diagnostics=True, timeout=120))
        action, = report["sound_actions"]
        return output, action

    def test_lossless_soundtracks_keep_every_sample_in_each_still_target(self):
        def samples(path):
            return ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "s32le", "-")

        with tempfile.TemporaryDirectory(prefix="mpcut-still-lossless-soundtrack-") as directory:
            root = Path(directory)
            cover = root / "cover.png"
            ffmpeg("-f", "lavfi", "-i", "color=blue:size=64x36", "-frames:v", "1", cover)
            # Each channel has its own tone, and detail below 16 bits that a 24-bit path must keep.
            tones = ("aevalsrc=0.6*sin(2*PI*440*t)+0.0000311*sin(2*PI*7919*t)"
                     "|0.5*sin(2*PI*661*t)+0.0000207*sin(2*PI*5003*t):s=48000:d=1")
            wide = ["-sample_fmt", "s32", "-bits_per_raw_sample", "24"]
            planar = ["-sample_fmt", "s32p", "-bits_per_raw_sample", "24"]
            recordings = [("flac16.mka", 16, ["-c:a", "flac", "-sample_fmt", "s16"]),
                          ("flac24.mka", 24, ["-c:a", "flac", *wide]),
                          ("flac24.m4a", 24, ["-c:a", "flac", *wide, "-strict", "-2", "-f", "mp4"]),
                          ("alac16.m4a", 16, ["-c:a", "alac", "-sample_fmt", "s16p"]),
                          ("alac24.mov", 24, ["-c:a", "alac", *planar]),
                          ("alac24.mka", 24, ["-c:a", "alac", *planar])]
            # By default a soundtrack keeps its own lossless codec where the container carries it. MOV cannot carry FLAC,
            # so a FLAC soundtrack becomes ALAC there, and ALAC is not verified in Matroska, so it becomes FLAC there.
            targets = [("mov", [], "alac"), ("mov", ["--audio", "pcm"], "pcm_s{depth}le"), ("mp4", [], "{native}"),
                       ("m4v", ["--audio", "alac"], "alac"), ("mp4", ["--audio", "flac"], "flac"), ("mkv", [], "flac")]
            for name, depth, encoder in recordings:
                recording = root / name
                ffmpeg("-f", "lavfi", "-i", tones, *encoder, recording)
                expected = samples(recording)
                self.assertEqual(len(expected), 48000 * 2 * 4)
                if depth == 24:
                    # The fixture uses the low byte of its 24 bits, so a 16-bit path would fail the comparison.
                    self.assertTrue(any(expected[1::4]))
                native = name.split("1")[0].split("2")[0]
                for container, options, codec in targets:
                    with self.subTest(recording=name, container=container, options=options):
                        output, action = self.soundtrack_export(root, cover, recording, container, *options)
                        written = probe(output, "-select_streams", "a:0", "-show_streams")["streams"][0]
                        codec = codec.format(depth=depth, native=native)
                        self.assertEqual(written["codec_name"], codec)
                        self.assertEqual(samples(output), expected)
                        self.assertEqual(action["warnings"], [])
                        if action["audio"] != "copy":
                            self.assertEqual((action["codec"], action["bit_depth"]), (codec, depth))
                        if not options and codec == native and action["audio"] != "copy":
                            self.assertIn(f"The {native.upper()} source is written as {native.upper()}", action["reason"])

    def test_mpeg_audio_in_matroska_fits_and_renders_every_whole_sample(self):
        # Matroska states the end of an MP3 or MP2 track to the millisecond, between two 44.1 kHz samples. The whole
        # track is attached up to its last complete sample, and every kept sample is rendered.
        with tempfile.TemporaryDirectory(prefix="mpcut-still-mpeg-mka-") as directory:
            root = Path(directory)
            cover = root / "cover.png"
            ffmpeg("-f", "lavfi", "-i", "color=blue:size=64x36", "-frames:v", "1", cover)
            for codec, name in (("libmp3lame", "mp3.mka"), ("mp2", "mp2.mka")):
                with self.subTest(codec=codec):
                    recording = root / name
                    ffmpeg("-f", "lavfi", "-i", "anoisesrc=d=3:c=pink:r=44100:a=0.4:seed=4", "-ac", "2", "-c:a", codec, recording)
                    for container in ("mkv", "mov"):
                        output, action = self.soundtrack_export(root, cover, recording, container)
                        self.assertNotEqual(action["audio"], "copy", action)
                        renders = [output]
                        if action["audio"] == "mp3":
                            # Auto writes an MP3 source to MOV as MP3 again, a second lossy encoding. A PCM render
                            # keeps every decoded sample to compare.
                            renders.append(self.soundtrack_export(root, cover, recording, container, "--audio", "pcm")[0])

                        def decoded(path):
                            return array("f", ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "pcm_f32le", "-f", "f32le", "-"))

                        source = decoded(recording)
                        for render in renders:
                            written = decoded(render)
                            # Whole samples only: the written track ends within a packet of the decoded source.
                            self.assertLessEqual(abs(len(source) - len(written)), 2 * 1152)
                            self.assertGreater(len(written), 2 * 44100 * 2)
                        count = min(len(source), len(written))
                        cross = sum(a * b for a, b in zip(source[:count], written[:count]))
                        power = (sum(a * a for a in source[:count]) * sum(b * b for b in written[:count])) ** 0.5
                        self.assertGreater(cross / power, 0.999)

    def test_soundtrack_copies_that_cannot_be_written_are_refused_when_planned(self):
        # Each of these copies used to plan and then fail while writing. The dry run and the export now agree.
        with tempfile.TemporaryDirectory(prefix="mpcut-still-copy-refusals-") as directory:
            root = Path(directory)
            cover = root / "cover.png"
            ffmpeg("-f", "lavfi", "-i", "color=blue:size=64x36", "-frames:v", "1", cover)
            tone = ["-f", "lavfi", "-i", "aevalsrc=0.6*sin(2*PI*440*t)|0.5*sin(2*PI*661*t):s=48000:d=2"]
            for name, codec, container, works in [("sound.flac", "flac", "mov", "MP4 or MKV"), ("sound.opus", "libopus", "mov", "MP4 or MKV"),
                                                  ("sound.opus", "libopus", "mkv", "MP4"), ("sound.mp2", "mp2", "mp4", "MOV or MKV"),
                                                  ("sound.m4a", "alac", "mkv", "MOV, MP4 or M4A"), ("sound.wav", "pcm_s16le", "mp4", "MOV or MKV")]:
                with self.subTest(source=name, container=container):
                    recording = root / name
                    if not recording.exists():
                        ffmpeg(*tone, "-c:a", codec, recording)
                    folder = Path(tempfile.mkdtemp(dir=root))
                    project = folder / "cover.cut"
                    run([CLI, "still", "project", "create", "--out-project", project, "--image", cover, "--width", "64", "--height", "36",
                         "--rate", "30", "--codec", "h264", "--container", container, "--soundtrack", recording, "--fit-soundtrack", "--json"],
                        allow_diagnostics=True)
                    output = folder / f"cover.{container}"
                    for dry in (["--dry-run"], []):
                        result = subprocess.run([CLI, "export", "project", "render", "--project", project, "--output", output, "--no-sidecar",
                                                 "--json", "--audio", "copy", *dry], capture_output=True, text=True, timeout=120)
                        report = json.loads(result.stdout)
                        self.assertFalse(report["ok"], report)
                        self.assertIn(report["error"]["code"], ("unsupported_container", "audio_copy_unavailable"), report)
                        self.assertIn(works, report["error"]["message"])
                        self.assertFalse(output.exists())

    def test_lossy_soundtrack_is_copied_by_default_and_converted_without_clipping(self):
        with tempfile.TemporaryDirectory(prefix="mpcut-still-lossy-soundtrack-") as directory:
            root = Path(directory)
            cover = root / "cover.png"
            recording = root / "recording.m4a"
            ffmpeg("-f", "lavfi", "-i", "color=blue:size=64x36", "-frames:v", "1", cover)
            # A full-scale square wave at a low rate decodes well above full scale.
            ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.999*sgn(sin(2*PI*997*t))|0.999*sgn(sin(2*PI*1499*t)):s=48000:d=2",
                   "-c:a", "aac", "-b:a", "64k", recording)

            def peak(path):
                decoded = array("f", ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "pcm_f32le", "-f", "f32le", "-"))
                return max(abs(value) for value in decoded)

            self.assertGreater(peak(recording), 1.2)
            source_packets = sample_hashes(recording, "a:0")
            for container in ("mov", "mp4", "mkv"):
                with self.subTest(container=container):
                    output, action = self.soundtrack_export(root, cover, recording, container)
                    self.assertEqual((action["audio"], action["codec"], action["treatment"]), ("copy", "aac", "copied packets"))
                    self.assertEqual(sample_hashes(output, "a:0"), source_packets)
            # AC-3 is copied too, from a raw stream and from a transport stream.
            for name, muxer in (("dolby.ac3", []), ("dolby.ts", ["-f", "mpegts"])):
                dolby = root / name
                ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.4*sin(2*PI*440*t)|0.3*sin(2*PI*661*t):s=48000:d=2", "-c:a", "ac3", *muxer, dolby)
                dolby_packets = sample_hashes(dolby, "a:0")
                for container in ("mov", "mkv"):
                    with self.subTest(recording=name, container=container):
                        output, action = self.soundtrack_export(root, cover, dolby, container)
                        self.assertEqual((action["audio"], action["codec"]), ("copy", "ac3"))
                        self.assertEqual(sample_hashes(output, "a:0"), dolby_packets)

            # PCM from a lossy decoder is float, so the peaks above full scale survive.
            output, action = self.soundtrack_export(root, cover, recording, "mov", "--audio", "pcm")
            self.assertEqual((action["audio"], action["codec"], action["bit_depth"]), ("pcm", "pcm_f32le", 32))
            self.assertEqual(probe(output, "-select_streams", "a:0", "-show_streams")["streams"][0]["codec_name"], "pcm_f32le")
            self.assertAlmostEqual(peak(output), peak(recording), places=4)
            # ALAC and FLAC hold integers. The plan says that the peaks clip there.
            for container, treatment in (("mov", "alac"), ("mkv", "flac")):
                output, action = self.soundtrack_export(root, cover, recording, container, "--audio", treatment)
                self.assertEqual((action["audio"], action["bit_depth"]), (treatment, 24))
                self.assertTrue(any("Peaks above full scale clip" in warning for warning in action["warnings"]), action["warnings"])
                self.assertLessEqual(peak(output), 1.0)
            # A converted AAC track reports the rate it is encoded at.
            output, action = self.soundtrack_export(root, cover, recording, "mov", "--audio", "aac")
            self.assertEqual((action["audio"], action["codec"]), ("aac", "aac"))
            self.assertEqual(action["bit_rate"], 192000)

            # A lossy codec outside the measured copy set keeps its own format where the container carries it, at its rate.
            other = root / "recording.mp3"
            ffmpeg("-i", recording, "-c:a", "libmp3lame", "-b:a", "128k", other)
            output, action = self.soundtrack_export(root, cover, other, "mov")
            self.assertEqual((action["audio"], action["codec"], action["bit_rate"]), ("mp3", "mp3", 128000))
            self.assertIn("The MP3 source is written as MP3 at its own rate", action["reason"])
            self.assertEqual(probe(output, "-select_streams", "a:0", "-show_streams")["streams"][0]["codec_name"], "mp3")


    def test_copied_dolby_soundtrack_from_a_movie_keeps_its_audible_length(self):
        # The source's edit list hides the encoder padding of the final AC-3 or E-AC-3 frame. A copied soundtrack once
        # played that padding in MOV and MP4 (512 samples here); it now ends at the planned, last audible sample.
        def samples(path):
            return ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "s16le", "-")

        with tempfile.TemporaryDirectory(prefix="mpcut-still-dolby-soundtrack-") as directory:
            root = Path(directory)
            cover = root / "cover.png"
            ffmpeg("-f", "lavfi", "-i", "color=blue:size=64x36", "-frames:v", "1", cover)
            for codec in ("ac3", "eac3"):
                recording = root / f"{codec}.mp4"
                ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.4*sin(2*PI*440*t)|0.3*sin(2*PI*661*t):s=48000:d=2", "-c:a", codec, recording)
                source = samples(recording)
                self.assertEqual(len(source), 2 * 48000 * 2 * 2)
                for container in ("mov", "mp4"):
                    with self.subTest(codec=codec, container=container):
                        output, action = self.soundtrack_export(root, cover, recording, container)
                        self.assertEqual((action["audio"], action["codec"]), ("copy", codec))
                        self.assertEqual(sample_hashes(output, "a:0"), sample_hashes(recording, "a:0"))
                        self.assertEqual(samples(output), source)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cli")
    args = parser.parse_args()
    CLI = str(Path(args.cli).resolve())
    unittest.main(argv=[__file__], verbosity=2)
