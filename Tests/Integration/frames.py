#!/usr/bin/env python3
"""Verify frame manifests against decoded JPEG pixels, ranges and source clocks."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


def run(args):
    return subprocess.run(args, check=True, capture_output=True, timeout=120).stdout


def ratio(value):
    return Fraction(value["numerator"], value["denominator"])


def rgb(path, xfrac=0.5, yfrac=0.5):
    data = run(["ffmpeg", "-loglevel", "error", "-i", path, "-vf",
                f"format=rgb24,crop=1:1:iw*{xfrac}:ih*{yfrac}", "-frames:v", "1",
                "-c:v", "rawvideo", "-f", "rawvideo", "-"])
    return tuple(data)


class Frames(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.source = cls.root / "five.mov"
        graphs = [f"color={color}:s=720x240:r=25:d=1[v{i}]" for i, color in enumerate(
            ["red", "blue", "red", "blue", "yellow"])]
        graphs += ["[v0][v1][v2][v3][v4]concat=n=5:v=1:a=0[v]",
                   "aevalsrc='if(between(t,1,2)+between(t,3,4),sin(440*2*PI*t)*0.35,0)':s=48000:d=5[a]"]
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", ";".join(graphs) + ";[v]null[out0];[a]anull[out1]",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "25", "-c:a", "pcm_s16le", cls.source])

    def export(self, name, *flags, count, source=None, signature=b"\xff\xd8"):
        dest = self.root / name
        stdout = run([CLI, "review", "frames", "export", "--json", "--output", dest, *flags, source or self.source])
        report = json.loads(stdout)
        self.assertEqual(json.loads((dest / "manifest.json").read_bytes()), report)
        # Every caller states how many pictures it expects, so the per-frame
        # checks below and in the tests cannot pass on a short or empty list.
        self.assertEqual(len(report["frames"]), count, report)
        for frame in report["frames"]:
            file = dest / frame["file"]
            self.assertEqual(file.read_bytes()[:len(signature)], signature)
            dims = run(["ffprobe", "-loglevel", "error", "-show_entries", "stream=width,height",
                        "-of", "csv=p=0:s=x", file]).decode().strip()
            self.assertEqual(dims, f"{frame['width']}x{frame['height']}")
        return dest, report

    def test_scene_samples_and_budget(self):
        dest, report = self.export("budget", "--limit", "2", count=2)
        self.assertEqual(report["range_count"], 5)
        self.assertEqual([f["scene_number"] for f in report["frames"]], [1, 5])
        self.assertEqual([ratio(f["frame_time"]) for f in report["frames"]], [Fraction(12,25), Fraction(112,25)])
        self.assertEqual([(f["width"], f["height"]) for f in report["frames"]], [(640,213)]*2)
        r, g, b = rgb(dest / report["frames"][1]["file"])
        self.assertTrue(r > 180 and g > 180 and b < 50)
        _, single = self.export("middle", "--limit", "1", "--sample", "first", "--preset", "full", count=1)
        first = single["frames"][0]
        self.assertEqual((first["scene_number"], ratio(first["frame_time"]), first["width"]), (3,2,720))

    def test_requested_order_duplicates_and_refusal(self):
        dest, report = self.export("times", "--at", "17/5", "--at", "0.4", "--at", "3.41", count=3)
        frames = report["frames"]
        self.assertEqual([ratio(f["frame_time"]) for f in frames], [Fraction(17,5), Fraction(2,5), Fraction(17,5)])
        self.assertEqual((dest / frames[0]["file"]).read_bytes(), (dest / frames[2]["file"]).read_bytes())
        self.assertGreater(rgb(dest / frames[0]["file"])[2], 200)
        self.assertGreater(rgb(dest / frames[1]["file"])[0], 200)
        kept = sorted(path.name for path in dest.iterdir())
        for output, flags, status, code in [
                (dest, [], 1, "output_exists"),
                (self.root / "badtime", ["--at","5"], 1, "invalid_range"),
                (self.root / "badlimit", ["--at","0","--limit","1"], 2, "invalid_arguments")]:
            with self.subTest(code=code, flags=flags):
                result = subprocess.run([CLI, "review", "frames", "export", "--json", "--output", output, *flags, self.source],
                                        capture_output=True, timeout=120)
                self.assertEqual(result.returncode, status, result.stdout)
                report = json.loads(result.stdout)
                self.assertIs(report["ok"], False)
                self.assertEqual(report["error"]["code"], code, report)
                if output != dest:
                    self.assertFalse(output.exists())
        self.assertEqual(sorted(path.name for path in dest.iterdir()), kept)

    def test_non_silent_ranges_and_empty_manifest(self):
        _, report = self.export("audible", "--select", "non-silent", "--min-pause-seconds", "0.35",
                                "--threshold-db", "-45", "--sample", "first", count=2)
        self.assertEqual(report["detection_audio_stream_index"], 1)
        self.assertEqual(report["range_count"], 2)
        for f, expected in zip(report["frames"], [1,3], strict=True):
            self.assertAlmostEqual(float(ratio(f["from"])), expected, delta=.021)
            self.assertAlmostEqual(float(ratio(f["to"])), expected + 1, delta=.021)
            self.assertLessEqual(ratio(f["clip_from"]), ratio(f["from"]))
            self.assertGreaterEqual(ratio(f["clip_to"]), ratio(f["to"]))
        dest, empty = self.export("empty", "--select", "non-silent", "--threshold-db", "0", "--min-pause-seconds", "0.1", count=0)
        self.assertEqual(empty["frames"], [])
        self.assertEqual(list(dest.iterdir()), [dest / "manifest.json"])

    def test_vfr_held_frame_and_nonzero_origin(self):
        source = self.root / "offset.mkv"
        run(["ffmpeg", "-loglevel", "error", "-i", self.source, "-an", "-vf", "setpts='(N+if(gte(N,25),9,0))/(25*TB)'",
             "-fps_mode", "vfr", "-c:v", "ffv1", "-output_ts_offset", "2", source])
        dest, report = self.export("vfr", "--at", "1.15", "--at", "1.38", count=2, source=source)
        self.assertEqual(ratio(report["origin"]), 2)
        for f, time, channel in zip(report["frames"], [Fraction(24,25), Fraction(34,25)], [0,2], strict=True):
            self.assertEqual(ratio(f["frame_time"]), time)
            self.assertEqual(f["frame_pts"] * ratio(report["time_base"]), 2 + time)
            self.assertGreater(rgb(dest / f["file"])[channel], 200)

    def test_duplicate_presentation_timestamp_cannot_select_a_picture(self):
        source = self.root / "duplicate-pts.mkv"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "color=red:s=320x180:r=1:d=1[r];color=blue:s=320x180:r=1:d=1[b];"
             "color=lime:s=320x180:r=1:d=1[g];"
             "[r][b][g]concat=n=3:v=1:a=0,setpts='if(lt(N,2),0,1/TB)'",
             "-fps_mode", "passthrough", "-c:v", "ffv1", source])
        dest = self.root / "duplicate-pictures"
        result = subprocess.run([CLI, "review", "frames", "export", "--json", "--at", "0", "--output", dest, source],
                                capture_output=True, timeout=120)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "ambiguous_frame")
        self.assertFalse(dest.exists())
        self.assertFalse(list(self.root.glob(".mpcut-frames-*")))
        dest, report = self.export("unique-picture", "--at", "1", count=1, source=source)
        frame = report["frames"][0]
        self.assertEqual(ratio(frame["frame_time"]), 1)
        self.assertGreater(rgb(dest / frame["file"])[1], 200)

    def test_portrait_rotation_changes_pixels_and_dimensions(self):
        base = self.root / "split.mp4"
        source = self.root / "portrait.mov"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "color=red:s=320x160:d=1,drawbox=x=160:y=0:w=160:h=160:c=blue:t=fill", "-c:v", "libx264", base])
        run(["ffmpeg", "-loglevel", "error", "-display_rotation", "90", "-i", base, "-c", "copy", source])
        dest, result = self.export("portrait", "--at", "0", "--preset", "full", count=1, source=source)
        f = result["frames"][0]
        self.assertEqual((f["width"], f["height"]), (160,320))
        self.assertGreater(rgb(dest / f["file"], yfrac=.2)[2], 200)
        self.assertGreater(rgb(dest / f["file"], yfrac=.8)[0], 200)

    def test_review_keeps_rows_of_horizontally_squeezed_software_picture(self):
        source = self.root / "squeezed.mkv"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "nullsrc=s=1280x400:r=1:d=1,format=gray,geq=lum='255*mod(Y,2)',setsar=1/4",
             "-c:v", "ffv1", source])
        dest, report = self.export("squeezed-review", "--at", "0", count=1, source=source)
        frame = report["frames"][0]
        self.assertEqual((frame["width"], frame["height"]), (320, 400))
        image = dest / frame["file"]
        adjacent_rows = sorted(rgb(image, yfrac=(y + 0.1) / 400)[0] for y in (198, 199))
        self.assertLess(adjacent_rows[0], 40)
        self.assertGreater(adjacent_rows[1], 215)

    def test_untagged_yuv_has_same_colors_across_decoders(self):
        hardware = self.root / "untagged.mp4"
        software = self.root / "untagged.mkv"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "color=red:s=320x240:r=1:d=1[r];color=lime:s=320x240:r=1:d=1[g];"
             "[r][g]concat=n=2:v=1:a=0", "-c:v", "libx264", hardware])
        # FFV1 stores the H.264 software decoder's exact YUV samples.
        run(["ffmpeg", "-loglevel", "error", "-i", hardware, "-c:v", "ffv1", software])
        rgb_by_decoder = []
        for source in (hardware, software):
            dest, report = self.export(f"untagged-{source.suffix[1:]}", "--at", "0", "--at", "1",
                                       "--preset", "full", count=2, source=source)
            rgb_by_decoder.append([rgb(dest / frame["file"]) for frame in report["frames"]])
        for hardware_pixel, software_pixel in zip(*rgb_by_decoder, strict=True):
            for hardware_channel, software_channel in zip(hardware_pixel, software_pixel, strict=True):
                self.assertAlmostEqual(hardware_channel, software_channel, delta=4)

    def test_untagged_matrix_follows_picture_size_on_both_decoders(self):
        # 75% red and green, stored with the BT.709 matrix at 1280x720 and with BT.601 at 640x360,
        # then stripped of every color tag. VideoToolbox tags untagged pictures larger than 704x576
        # as BT.709 and smaller ones as BT.601, which is what the native preview shows. Read with
        # the other matrix, the red patch moves by 16 to 42 levels and the green by 32. VideoToolbox
        # also gives both the BT.709 transfer (75% becomes 197 in sRGB) and the smaller one SMPTE C
        # primaries, which the native preview converts to sRGB; these are its measured values.
        for size, matrix, patches in (("1280x720", "bt709", ((197, 0, 0), (0, 197, 0))),
                                      ("640x360", "bt601", ((193, 26, 0), (47, 195, 0)))):
            hardware = self.root / f"untagged-{matrix}.mp4"
            software = self.root / f"untagged-{matrix}.mkv"
            run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                 f"color=c=0xBF0000:s={size}:r=1:d=1[r];color=c=0x00BF00:s={size}:r=1:d=1[g];"
                 f"[r][g]concat=n=2:v=1:a=0,format=gbrp,scale=out_color_matrix={matrix}:out_range=tv,format=yuv420p",
                 "-c:v", "libx264", "-bsf:v",
                 "h264_metadata=colour_primaries=2:transfer_characteristics=2:matrix_coefficients=2", hardware])
            run(["ffmpeg", "-loglevel", "error", "-i", hardware, "-c:v", "ffv1", software])
            for source in (hardware, software):
                tags = run(["ffprobe", "-loglevel", "error", "-select_streams", "v:0", "-show_entries",
                            "stream=color_space,color_primaries,color_transfer", "-of", "csv=p=0", source]).decode().strip()
                self.assertEqual(tags, "unknown,unknown,unknown")
                with self.subTest(size=size, decoder=source.suffix[1:]):
                    dest, report = self.export(f"untagged-{matrix}-{source.suffix[1:]}", "--at", "0", "--at", "1",
                                               "--preset", "full", count=2, source=source)
                    for frame, expected in zip(report["frames"], patches, strict=True):
                        for channel, wanted in zip(rgb(dest / frame["file"]), expected, strict=True):
                            self.assertAlmostEqual(channel, wanted, delta=6)

    def test_matrix_only_tag_sets_the_primaries_the_native_preview_shows(self):
        # Only the matrix is recorded, against the size rule: BT.709 at 640x360 and BT.601 at 1280x720.
        # VideoToolbox then takes the primaries from the matrix (BT.709, or SMPTE C for BT.601) and the
        # BT.709 transfer, whatever the size; these are the native preview's measured values.
        for size, matrix, code, patches in (("640x360", "bt709", 1, ((197, 0, 0), (0, 197, 0))),
                                            ("1280x720", "bt601", 6, ((193, 26, 0), (47, 195, 0)))):
            hardware = self.root / f"matrix-only-{matrix}.mp4"
            software = self.root / f"matrix-only-{matrix}.mkv"
            run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                 f"color=c=0xBF0000:s={size}:r=1:d=1[r];color=c=0x00BF00:s={size}:r=1:d=1[g];"
                 f"[r][g]concat=n=2:v=1:a=0,format=gbrp,scale=out_color_matrix={matrix}:out_range=tv,format=yuv420p",
                 "-c:v", "libx264", "-bsf:v",
                 f"h264_metadata=colour_primaries=2:transfer_characteristics=2:matrix_coefficients={code}", hardware])
            run(["ffmpeg", "-loglevel", "error", "-i", hardware, "-c:v", "ffv1", software])
            for source in (hardware, software):
                with self.subTest(size=size, decoder=source.suffix[1:]):
                    dest, report = self.export(f"matrix-only-{matrix}-{source.suffix[1:]}", "--at", "0", "--at", "1",
                                               "--preset", "full", count=2, source=source)
                    for frame, expected in zip(report["frames"], patches, strict=True):
                        for channel, wanted in zip(rgb(dest / frame["file"]), expected, strict=True):
                            self.assertAlmostEqual(channel, wanted, delta=6)

    def test_srgb_tagged_picture_without_matrix_is_read_as_bt601(self):
        # BT.709 primaries and the sRGB transfer but no matrix, as screen recordings often carry.
        # VideoToolbox then leaves the matrix unset and Core Animation decodes BT.601, whatever the
        # size. The old size rule read this 1280x720 picture as BT.709: red 207,19,0 and green 1,161,1.
        hardware = self.root / "srgb-no-matrix.mp4"
        software = self.root / "srgb-no-matrix.mkv"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "color=c=0xBF0000:s=1280x720:r=1:d=1[r];color=c=0x00BF00:s=1280x720:r=1:d=1[g];"
             "[r][g]concat=n=2:v=1:a=0,format=gbrp,scale=out_color_matrix=bt601:out_range=tv,format=yuv420p",
             "-c:v", "libx264", "-bsf:v",
             "h264_metadata=colour_primaries=1:transfer_characteristics=13:matrix_coefficients=2", hardware])
        run(["ffmpeg", "-loglevel", "error", "-i", hardware, "-c:v", "ffv1", software])
        for source in (hardware, software):
            with self.subTest(decoder=source.suffix[1:]):
                dest, report = self.export(f"srgb-no-matrix-{source.suffix[1:]}", "--at", "0", "--at", "1",
                                           "--preset", "full", count=2, source=source)
                for frame, expected in zip(report["frames"], ((191, 0, 0), (0, 191, 0)), strict=True):
                    for channel, wanted in zip(rgb(dest / frame["file"]), expected, strict=True):
                        self.assertAlmostEqual(channel, wanted, delta=6)

    def assert_two_patches(self, name, colors, matrix, metadata, expected, delta=6, depth=8, sources=None):
        """Exports a 1280x720 picture of each color, stored with `matrix` and the given color fields,
        from H.264 (VideoToolbox) and FFV1 (software), and compares it with the native preview."""
        fmt = "yuv420p10le" if depth == 10 else "yuv420p"
        hardware = self.root / f"{name}.mp4"
        software = self.root / f"{name}.mkv"
        first, second = colors
        graph = (f"color=c={first}:s=1280x720:r=1:d=1[a];color=c={second}:s=1280x720:r=1:d=1[b];"
                 f"[a][b]concat=n=2:v=1:a=0,format=gbrp,scale=out_color_matrix={matrix}:out_range=tv,format={fmt}")
        if sources is None:
            run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", graph, "-c:v", "libx264",
                 "-bsf:v", f"h264_metadata={metadata}", hardware])
            run(["ffmpeg", "-loglevel", "error", "-i", hardware, "-c:v", "ffv1", software])
            sources = (hardware, software)
        else:
            sources = sources(graph, hardware, software)
        for source in sources:
            with self.subTest(case=name, decoder=source.suffix[1:]):
                dest, report = self.export(f"{name}-{source.suffix[1:]}", "--at", "0", "--at", "1",
                                           "--preset", "full", count=2, source=source)
                for frame, wanted in zip(report["frames"], expected, strict=True):
                    pixel = rgb(dest / frame["file"])
                    for channel, value in zip(pixel, wanted, strict=True):
                        self.assertAlmostEqual(channel, value, delta=delta, msg=(pixel, wanted))

    def test_out_of_gamut_signal_is_limited_like_the_native_preview(self):
        # 75% red and blue stored with the BT.709 matrix but recording only the BT.709 transfer, so
        # the native preview reads them with BT.601 and SMPTE C primaries. That leaves the green
        # signal below zero, which Core Animation limits to zero before converting color; Core Image
        # carried it on, and VideoToolbox pictures came out 11 and 6 levels lower in green.
        self.assert_two_patches("bt709-read-as-bt601", ("0xBF0000", "0x0000BF"), "bt709",
                                "colour_primaries=2:transfer_characteristics=1:matrix_coefficients=2",
                                ((179, 23, 0), (17, 23, 192)), delta=4)

    def test_primaries_without_transfer_take_the_native_preview_transfer(self):
        # Only the primaries are recorded. Core Animation shows EBU Tech 3213 primaries with the
        # BT.709 transfer, P3 D65 with sRGB and BT.2020 as the ITU-R BT.2020 color space, each with
        # the BT.601 matrix; these are its measured values. Read as sRGB, as Core Image does without
        # a transfer, both patches were 190, and BT.2020 was also read with its own matrix.
        for code, name, expected in ((5, "ebu", ((202, 0, 1), (0, 198, 19))),
                                     (12, "p3", ((209, 0, 0), (0, 194, 0))),
                                     (9, "bt2020", ((235, 0, 0), (0, 198, 0)))):
            self.assert_two_patches(f"primaries-only-{name}", ("0xBF0000", "0x00BF00"), "bt601",
                                    f"colour_primaries={code}:transfer_characteristics=2:matrix_coefficients=2",
                                    expected)

    def test_sdr_bt2020_picture_without_matrix_is_read_as_bt601(self):
        # BT.2020 primaries and an SDR transfer without a matrix. Core Animation decodes the missing
        # matrix as BT.601 here; only a PQ or HLG picture takes BT.2020 from its primaries. Read
        # with BT.2020, the green patch was 22 levels darker than the native preview.
        self.assert_two_patches("sdr-bt2020-no-matrix", ("0xBF0000", "0x00BF00"), "bt601",
                                "colour_primaries=9:transfer_characteristics=1:matrix_coefficients=2",
                                ((249, 0, 0), (0, 209, 0)))

    def test_hdr_picture_without_matrix_takes_the_sdr_preview_matrix(self):
        # PQ with BT.709 primaries and no matrix, stored with the BT.709 matrix. Core Animation decodes
        # the missing matrix as BT.709, as does Core Image, which maps the SDR preview of an HDR
        # picture; these are that preview's measured values. Read with BT.601 they were 141,0,1 and
        # 10,173,4.
        tags = ["-color_primaries", "bt709", "-color_trc", "smpte2084"]

        def sources(graph, hardware, software):
            graph += ",setparams=color_primaries=bt709:color_trc=smpte2084:colorspace=unknown:range=tv"
            run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", graph, "-c:v", "ffv1", *tags, software])
            encoders = run(["ffmpeg", "-hide_banner", "-encoders"]).decode()
            # HEVC Main 10 takes the VideoToolbox decoder.
            if " libx265 " in encoders:
                codec = ["-c:v", "libx265", "-x265-params", "log-level=error"]
            elif " hevc_videotoolbox " in encoders:
                codec = ["-c:v", "hevc_videotoolbox", "-profile:v", "main10"]
            else:
                return (software,)
            run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", graph, *codec, "-tag:v", "hvc1", *tags, hardware])
            return (hardware, software)

        self.assert_two_patches("pq-bt709-no-matrix", ("0x860000", "0x008600"), "bt709", None,
                                ((152, 0, 0), (0, 152, 0)), depth=10, sources=sources)

    def test_untagged_mid_grey_takes_the_native_preview_transfer(self):
        # Limited-range grey at codes 16, 126 and 235 without any color tag. The native preview shows
        # it with VideoToolbox's BT.709 transfer, so mid grey is 139 in sRGB, not the 128 of reading
        # the values as sRGB. PNG keeps the decoded values and names the profile they are in.
        for size, profile in (("1280x720", "HDTV"), ("640x360", "Composite NTSC")):
            hardware = self.root / f"untagged-grey-{size}.mp4"
            software = self.root / f"untagged-grey-{size}.mkv"
            run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                 f"nullsrc=s={size}:r=1:d=1,format=yuv420p,"
                 "geq=lum='if(lt(X,W/3),16,if(lt(X,2*W/3),126,235))':cb=128:cr=128",
                 "-c:v", "libx264", "-bsf:v",
                 "h264_metadata=colour_primaries=2:transfer_characteristics=2:matrix_coefficients=2", hardware])
            run(["ffmpeg", "-loglevel", "error", "-i", hardware, "-c:v", "ffv1", software])
            for source in (hardware, software):
                with self.subTest(size=size, decoder=source.suffix[1:]):
                    dest, report = self.export(f"untagged-grey-{size}-{source.suffix[1:]}", "--at", "0",
                                               "--preset", "full", count=1, source=source)
                    image = dest / report["frames"][0]["file"]
                    for xfrac, expected in ((1 / 6, 0), (1 / 2, 139), (5 / 6, 255)):
                        for channel in rgb(image, xfrac=xfrac):
                            self.assertAlmostEqual(channel, expected, delta=2, msg=(xfrac, image))
                    dest, report = self.export(f"untagged-grey-{size}-{source.suffix[1:]}-png", "--at", "0",
                                               "--preset", "full", "--format", "png", count=1, source=source,
                                               signature=b"\x89PNG")
                    image = dest / report["frames"][0]["file"]
                    self.assertEqual(self.image_facts(image)[1], profile)
                    for channel in rgb(image, xfrac=1 / 2):
                        self.assertAlmostEqual(channel, 128, delta=1)

    @staticmethod
    def markers(jpeg):
        """The marker codes of a JPEG up to its scan."""
        found, i = [], 2
        while i + 4 <= len(jpeg) and jpeg[i] == 0xFF:
            found.append(jpeg[i + 1])
            if jpeg[i + 1] == 0xDA:
                break
            i += 2 + int.from_bytes(jpeg[i + 2:i + 4], "big")
        return found

    def test_full_jpeg_of_stored_jpeg_pictures_is_the_stored_picture(self):
        # Photo JPEG and AVI MJPEG pictures are complete JPEGs already. A Full JPEG of one is that
        # picture's bytes rather than a second lossy encoding of its decoded pixels.
        stored = self.root / "stored-pictures"
        stored.mkdir()
        photo = self.root / "photo.mov"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=1",
             "-vf", "format=yuvj420p", "-c:v", "mjpeg", "-q:v", "3", photo])
        run(["ffmpeg", "-loglevel", "error", "-i", photo, "-c:v", "copy", "-f", "image2", stored / "photo-%03d.jpg"])
        dest, report = self.export("stored-photo", "--at", "0", "--at", "0.2", "--preset", "full", count=2, source=photo)
        for frame, index in zip(report["frames"], (1, 6), strict=True):
            self.assertEqual((frame["width"], frame["height"]), (640, 360))
            self.assertEqual((dest / frame["file"]).read_bytes(), (stored / f"photo-{index:03d}.jpg").read_bytes())

        # An AVI picture without Huffman tables gains the standard ones and decodes to the same pixels.
        standard = self.root / "standard-tables.avi"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=0.2",
             "-vf", "format=yuvj420p", "-c:v", "mjpeg", "-huffman", "default", "-q:v", "3", standard])
        run(["ffmpeg", "-loglevel", "error", "-i", standard, "-c:v", "copy", "-f", "image2", stored / "avi-%03d.jpg"])
        stripped = bytearray()
        for picture in sorted(stored.glob("avi-*.jpg")):
            data, i = picture.read_bytes(), 2
            stripped += data[:2]
            while data[i + 1] != 0xDA:
                length = int.from_bytes(data[i + 2:i + 4], "big")
                if data[i + 1] != 0xC4:
                    stripped += data[i:i + 2 + length]
                i += 2 + length
            stripped += data[i:]
        (self.root / "no-tables.mjpeg").write_bytes(stripped)
        no_tables = self.root / "no-tables.avi"
        run(["ffmpeg", "-loglevel", "error", "-f", "mjpeg", "-framerate", "25", "-i", self.root / "no-tables.mjpeg",
             "-c:v", "copy", no_tables])
        dest, report = self.export("stored-avi", "--at", "0", "--preset", "full", count=1, source=no_tables)
        image = (dest / report["frames"][0]["file"]).read_bytes()
        self.assertNotIn(0xC4, self.markers(stripped))
        self.assertIn(0xC4, self.markers(image))
        decoded = self.raw(dest / report["frames"][0]["file"], "rgb24")
        self.assertEqual(decoded, self.raw(stored / "avi-001.jpg", "rgb24"))

        # Pictures that need a conversion are still decoded and encoded: a review image, PNG,
        # a BT.709 matrix (as MPCut's own Photo JPEG stills are tagged) and a display rotation.
        tagged = self.root / "photo-709.mov"
        run(["ffmpeg", "-loglevel", "error", "-i", photo, "-c", "copy", "-colorspace", "bt709",
             "-color_primaries", "bt709", "-color_trc", "bt709", "-movflags", "+write_colr", tagged])
        rotated = self.root / "photo-rotated.mov"
        run(["ffmpeg", "-loglevel", "error", "-display_rotation", "90", "-i", photo, "-c", "copy", rotated])
        for name, source, flags in (("review", photo, ["--preset", "review"]),
                                    ("png", photo, ["--preset", "full", "--format", "png"]),
                                    ("tagged", tagged, ["--preset", "full"]),
                                    ("rotated", rotated, ["--preset", "full"])):
            with self.subTest(case=name):
                signature = b"\x89PNG" if "png" in flags else b"\xff\xd8"
                dest, report = self.export(f"stored-{name}", "--at", "0", *flags, count=1, source=source,
                                           signature=signature)
                self.assertNotEqual((dest / report["frames"][0]["file"]).read_bytes(),
                                    (stored / "photo-001.jpg").read_bytes())
        self.assertEqual((report["frames"][0]["width"], report["frames"][0]["height"]), (360, 640))

    def test_hlg_ramp_is_tone_mapped_and_sdr_ramp_is_not(self):
        # A neutral ramp from black to peak signal. Converted to sRGB without
        # tone mapping, the upper half of an HLG ramp is one flat white.
        def ramp(name, depth, tags, codec):
            source = self.root / name
            low, span, mid, fmt = (64, 876, 512, "yuv420p10le") if depth == 10 else (16, 219, 128, "yuv420p")
            primaries, transfer, matrix = tags
            run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                 f"nullsrc=s=640x360:r=1:d=1,format={fmt},geq=lum='{low}+{span}*X/(W-1)':cb={mid}:cr={mid},"
                 f"setparams=color_primaries={primaries}:color_trc={transfer}:colorspace={matrix}:range=tv",
                 *codec, "-color_primaries", primaries, "-color_trc", transfer, "-colorspace", matrix,
                 "-color_range", "tv", source])
            dest, report = self.export(name + "-picture", "--at", "0", "--preset", "full", count=1, source=source)
            image = dest / report["frames"][0]["file"]
            return [rgb(image, xfrac=x)[1] for x in (0.6, 0.9)]

        hlg = ("bt2020", "arib-std-b67", "bt2020nc")
        encoders = run(["ffmpeg", "-hide_banner", "-encoders"]).decode()
        sources = [("hlg-software.mkv", ["-c:v", "ffv1"])]
        # HEVC Main 10 takes the VideoToolbox decoder.
        if " libx265 " in encoders:
            sources.append(("hlg-hardware.mov", ["-c:v", "libx265", "-x265-params", "log-level=error", "-tag:v", "hvc1"]))
        elif " hevc_videotoolbox " in encoders:
            sources.append(("hlg-hardware.mov", ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-tag:v", "hvc1"]))
        for name, codec in sources:
            with self.subTest(source=name):
                upper_middle, near_peak = ramp(name, 10, hlg, codec)
                self.assertLess(upper_middle, 160)
                self.assertGreater(near_peak, 180)
                self.assertGreater(near_peak - upper_middle, 60)
        # The same ramp as BT.709 SDR keeps its plain conversion.
        upper_middle, near_peak = ramp("sdr-ramp.mkv", 8, ("bt709", "bt709", "bt709"), ["-c:v", "ffv1"])
        self.assertAlmostEqual(upper_middle, 163, delta=6)
        self.assertAlmostEqual(near_peak, 233, delta=6)

    def test_limited_range_levels_survive_every_software_conversion(self):
        # Black, mid grey and white patches at limited-range codes 16, 126 and 235.
        # The sRGB transfer tag keeps colour management from moving the mid level,
        # so the expected picture values are exactly 0, 128 and 255. The scaled,
        # odd-height, wide-sample and off-block-width conversions each lost two
        # levels (white 253), and unscaled 8-bit gray kept 16 and 235.
        cases = [("review", "yuv420p", "1280x720", "review"),
                 ("off-block", "yuv420p", "648x360", "full"),
                 ("off-block-422", "yuv422p", "648x360", "full"),
                 ("odd-height", "yuv420p", "640x361", "full"),
                 ("ten-bit", "yuv420p10le", "640x360", "full"),
                 ("ten-bit-422", "yuv422p10le", "640x360", "full"),
                 ("gray", "gray", "640x360", "full"),
                 ("gray-review", "gray", "1280x720", "review"),
                 ("block", "yuv420p", "640x360", "full")]
        for name, fmt, size, preset in cases:
            with self.subTest(case=name):
                scale = 4 if "10" in fmt else 1
                chroma = "" if fmt == "gray" else f":cb={128 * scale}:cr={128 * scale}"
                source = self.root / f"levels-{name}.mkv"
                run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                     f"nullsrc=s={size}:r=1:d=1,format={fmt},"
                     f"geq=lum='{scale}*if(lt(X,W/3),16,if(lt(X,2*W/3),126,235))'{chroma},"
                     "setparams=color_primaries=bt709:color_trc=iec61966-2-1:colorspace=bt709:range=tv",
                     "-c:v", "ffv1", "-color_primaries", "bt709", "-color_trc", "iec61966-2-1",
                     "-colorspace", "bt709", "-color_range", "tv", source])
                dest, report = self.export(f"levels-{name}", "--at", "0", "--preset", preset, count=1, source=source)
                image = dest / report["frames"][0]["file"]
                for xfrac, expected in ((1 / 6, 0), (1 / 2, 128), (5 / 6, 255)):
                    for channel in rgb(image, xfrac=xfrac):
                        self.assertAlmostEqual(channel, expected, delta=1, msg=(name, xfrac))

    def raw(self, path, pixel_format):
        return run(["ffmpeg", "-loglevel", "error", "-i", path, "-frames:v", "1", "-pix_fmt", pixel_format,
                    "-f", "rawvideo", "-"])

    def image_facts(self, path):
        pixel_format = run(["ffprobe", "-loglevel", "error", "-show_entries", "stream=pix_fmt",
                            "-of", "csv=p=0", path]).decode().strip()
        described = run(["sips", "-g", "profile", "-g", "hasAlpha", path]).decode()
        facts = dict(line.strip().split(": ", 1) for line in described.splitlines()[1:])
        return pixel_format, facts["profile"], facts["hasAlpha"]

    def test_png_and_tiff_keep_rgb_samples_exactly(self):
        # FFV1 holds these R'G'B' samples losslessly, so the exported file must return every one.
        for depth, source_format, raw_format, stored in ((8, "gbrp", "rgb24", "rgb24"), (16, "gbrp16le", "rgb48le", "rgb48")):
            source = self.root / f"rgb{depth}.mkv"
            run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", f"testsrc2=s=326x182:r=5:d=1,format={source_format}",
                 "-c:v", "ffv1", source])
            expected = self.raw(source, raw_format)
            for name, signature in (("png", b"\x89PNG\r\n\x1a\n"), ("tiff", b"")):
                with self.subTest(depth=depth, format=name):
                    dest, report = self.export(f"rgb{depth}-{name}", "--at", "0", "--preset", "full", "--format", name,
                                               count=1, source=source, signature=signature)
                    self.assertEqual(report["format"], name)
                    frame = report["frames"][0]
                    self.assertEqual(frame["file"], "frame-000001." + name)
                    if name == "tiff":
                        self.assertIn((dest / frame["file"]).read_bytes()[:4], (b"II*\x00", b"MM\x00*"))
                    pixel_format, profile, alpha = self.image_facts(dest / frame["file"])
                    self.assertTrue(pixel_format.startswith(stored), pixel_format)
                    self.assertEqual((profile, alpha), ("sRGB IEC61966-2.1", "no"))
                    self.assertEqual(self.raw(dest / frame["file"], raw_format), expected)
        # JPEG stays the default and its manifest does not gain a key.
        _, report = self.export("rgb-default", "--at", "0", count=1, source=source)
        self.assertNotIn("format", report)
        self.assertEqual(report["frames"][0]["file"], "frame-000001.jpg")
        result = subprocess.run([CLI, "review", "frames", "export", "--json", "--format", "bmp", "--at", "0",
                                 "--output", self.root / "rgb-bmp", source], capture_output=True, timeout=120)
        self.assertEqual((result.returncode, json.loads(result.stdout)["error"]["code"]), (2, "invalid_arguments"))
        self.assertFalse((self.root / "rgb-bmp").exists())

    def test_png_keeps_depth_gamut_and_hdr_signal(self):
        # Limited-range patches at 10-bit codes 64, 504 and 940: black, (126 - 16) / 219 and white.
        def patches(name, primaries, transfer, matrix):
            source = self.root / name
            run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                 "nullsrc=s=640x360:r=1:d=1,format=yuv420p10le,"
                 "geq=lum='4*if(lt(X,W/3),16,if(lt(X,2*W/3),126,235))':cb=512:cr=512,"
                 f"setparams=color_primaries={primaries}:color_trc={transfer}:colorspace={matrix}:range=tv",
                 "-c:v", "ffv1", "-color_primaries", primaries, "-color_trc", transfer, "-colorspace", matrix,
                 "-color_range", "tv", source])
            dest, report = self.export(name + "-png", "--at", "0", "--preset", "full", "--format", "png",
                                       count=1, source=source, signature=b"\x89PNG")
            image = dest / report["frames"][0]["file"]
            pixel_format, profile, _ = self.image_facts(image)
            self.assertEqual(pixel_format, "rgb48be")
            samples = self.raw(image, "rgb48le")
            row = 180 * 640 * 6
            levels = [int.from_bytes(samples[row + x * 6:row + x * 6 + 2], "little") for x in (106, 320, 533)]
            return profile, levels

        expected = [0, round(110 / 219 * 65535), 65535]
        for name, tags, profile in (
                ("deep-709.mkv", ("bt709", "bt709", "bt709"), "HDTV"),
                ("deep-p3.mkv", ("smpte432", "iec61966-2-1", "bt709"), "Display P3"),
                # PQ and HLG keep their signal: no tone mapping moves the mid level.
                ("deep-hlg.mkv", ("bt2020", "arib-std-b67", "bt2020nc"), "Rec. ITU-R BT.2100 HLG"),
                ("deep-pq.mkv", ("bt2020", "smpte2084", "bt2020nc"), "Rec. ITU-R BT.2100 PQ")):
            with self.subTest(source=name):
                found, levels = patches(name, *tags)
                self.assertEqual(found, profile)
                for level, wanted in zip(levels, expected, strict=True):
                    self.assertAlmostEqual(level, wanted, delta=16)

    def test_png_keeps_full_range_deep_levels(self):
        # A flat full-range picture at half scale and at peak. swscale delivers the code shifted up
        # to 16 bits, which is exact only for a 16-bit source: 10-bit peak 1023 arrives as 65472.
        for name, fmt, bits in (("gray16", "gray16le", 16), ("yuv444p10", "yuv444p10le", 10)):
            peak = (1 << bits) - 1
            for code in (1 << (bits - 1), peak):
                with self.subTest(source=name, code=code):
                    source = self.root / f"full-{name}-{code}.mkv"
                    chroma = "" if fmt.startswith("gray") else f":cb={1 << (bits - 1)}:cr={1 << (bits - 1)}"
                    run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                         f"nullsrc=s=320x180:r=1:d=1,format={fmt},geq=lum={code}{chroma},"
                         "setparams=color_primaries=bt709:color_trc=iec61966-2-1:colorspace=bt709:range=pc",
                         "-c:v", "ffv1", "-color_primaries", "bt709", "-color_trc", "iec61966-2-1",
                         "-colorspace", "bt709", "-color_range", "pc", source])
                    dest, report = self.export(f"full-{name}-{code}", "--at", "0", "--preset", "full", "--format", "png",
                                               count=1, source=source, signature=b"\x89PNG")
                    samples = self.raw(dest / report["frames"][0]["file"], "rgb48le")
                    level = int.from_bytes(samples[(90 * 320 + 160) * 6:(90 * 320 + 160) * 6 + 2], "little")
                    self.assertAlmostEqual(level, round(code / peak * 65535), delta=2)

    def test_anamorphic_bitstream_rotation_survives_first_seek(self):
        # The H.264 display orientation SEI occurs on the first decoded picture.
        # The MOV container has no display matrix. Seek past several closed GOPs.
        source = self.root / "bitstream.mp4"
        run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
             "color=red:s=240x160:r=12:d=6,drawbox=x=120:y=0:w=120:h=160:c=blue:t=fill,setsar=4/3",
             "-c:v", "libx264", "-g", "12", "-bsf:v", "h264_metadata=display_orientation=insert:rotate=90", source])
        dest, result = self.export("bitstream", "--at", "5.5", "--preset", "full", count=1, source=source)
        f = result["frames"][0]
        self.assertEqual((f["width"], f["height"]), (160, 320))
        self.assertGreater(rgb(dest / f["file"], yfrac=.2)[2], 200)
        self.assertGreater(rgb(dest / f["file"], yfrac=.8)[0], 200)

    def test_full_preset_follows_midstream_resolution_change(self):
        source = self.root / "switch.ts"
        with source.open("xb") as stream:
            for second, (size, color) in enumerate([("320x192", "red"), ("640x288", "blue")]):
                stream.write(run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                                  f"color={color}:s={size}:r=12:d=1", "-c:v", "libx264",
                                  "-bf", "0", "-g", "12", "-muxdelay", "0", "-output_ts_offset",
                                  str(second), "-f", "mpegts", "-"]))
        dest, result = self.export("switch-pictures", "--at", "0.5", "--at", "1.5",
                                   "--preset", "full", count=2, source=source)
        self.assertEqual([(f["width"], f["height"]) for f in result["frames"]], [(320, 192), (640, 288)])
        for frame, channel in zip(result["frames"], [0, 2], strict=True):
            self.assertGreater(rgb(dest / frame["file"])[channel], 200)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
