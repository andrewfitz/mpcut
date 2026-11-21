#!/usr/bin/env python3
"""Regressions for audited packet-writer fixes against a built mpcut executable."""
import argparse
import array
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
AFINFO = Path("/usr/bin/afinfo")
CLI = None


def run(command, timeout=60):
    result = subprocess.run([str(part) for part in command], capture_output=True, timeout=timeout)
    if result.returncode:
        raise AssertionError(f"{command} exited {result.returncode}: {result.stderr.decode()}")
    return result.stdout


def ffmpeg(*args):
    return run([FFMPEG, "-hide_banner", "-v", "error", "-nostdin", "-y", *args])


def probe(path, *args):
    return json.loads(run([FFPROBE, "-v", "error", "-of", "json", *args, path]))


def pcm(path):
    return array.array("h", ffmpeg("-i", path, "-map", "0:a:0", "-vn", "-ac", "1", "-f", "s16le", "-"))


def ratio(value):
    return Fraction(value["numerator"], value["denominator"])


class WriterAuditFixes(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mpcut-audit-writer-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def export(self, source, destination, *extra):
        process = subprocess.run([str(CLI), "export", "--json", "--output", str(destination),
                                  "--clip", str(source), *extra], capture_output=True, text=True, timeout=60)
        self.assertEqual(process.returncode, 0, process.stderr + process.stdout)
        report = json.loads(process.stdout)
        self.assertIs(report["ok"], True, report)
        return report

    def test_whole_mov_copy_keeps_audio_that_leads_matroska_video(self):
        # Matroska declares no track start. The MPEG-4 Part 2 source is analysed by
        # the probe, the others are not: both paths must keep the audio lead.
        rate = 48_000
        for video, sound, extension in [("mpeg4", "ac3", "mov"), ("libx264", "ac3", "mp4"),
                                        ("libx264", "pcm_s16le", "mov")]:
            with self.subTest(video=video, sound=sound, extension=extension):
                source = self.root / f"{video}-{sound}.mkv"
                output = self.root / f"{video}-{sound}.{extension}"
                ffmpeg("-itsoffset", "0.5", "-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=2",
                       "-f", "lavfi", "-i", f"aevalsrc=0.4*sin(2*PI*(227*t+201*t*t)):s={rate}:d=2.5",
                       "-c:v", video, "-pix_fmt", "yuv420p", "-c:a", sound, source)
                starts = {s["codec_type"]: Fraction(s["start_time"]) for s in probe(source, "-show_streams")["streams"]}
                lead = starts["video"] - starts["audio"]
                self.assertGreaterEqual(lead, Fraction(1, 2))

                plan = self.export(source, output, "--dry-run")
                segment = plan["segments"][0]
                self.assertLess(abs(ratio(segment["outputStart"]) - lead), Fraction(1, 500), segment)
                for track in segment["tracks"]:
                    self.assertGreaterEqual(ratio(track["outputStart"]), 0, track)
                self.assertFalse(output.exists())

                self.export(source, output)
                written = {s["codec_type"]: Fraction(s["start_time"]) for s in probe(output, "-show_streams")["streams"]}
                self.assertEqual(written["audio"], 0)
                self.assertLess(abs(written["video"] - lead), Fraction(1, 500), written)

                expected, actual = pcm(source), pcm(output)
                self.assertLess(abs(len(actual) - len(expected)), 64)
                self.assertGreater(len(actual), int(2.49 * rate))
                # The leading half second is audible and stays aligned to within a millisecond.
                window = range(1_000, rate // 2)
                aligned = [lag for lag in range(-48, 49)
                           if all(expected[i + lag] == actual[i] for i in window)]
                self.assertTrue(aligned, "the audio before the first video frame was not preserved")

    def test_whole_copy_of_vbr_mp3_without_encoder_tag_keeps_its_duration(self):
        tagged = self.root / "tagged.mp3"
        ffmpeg("-f", "lavfi", "-i", "aevalsrc=0.4*sin(2*PI*(227*t+201*t*t)):s=44100:d=20.04",
               "-c:a", "libmp3lame", "-q:a", "6", tagged)
        data = bytearray(tagged.read_bytes())
        tag = data.find(b"Xing", 0, 4096)
        self.assertGreater(tag, 0)
        self.assertIn(bytes(data[tag + 120:tag + 124]), [b"Lavc", b"Lavf", b"LAME"])
        data[tag + 120:tag + 129] = bytes(9)  # A plain Xing header: no encoder ID, so no gapless delay.
        plain = self.root / "plain.mp3"
        plain.write_bytes(data)
        wrapped = self.root / "wrapped.mka"
        ffmpeg("-i", plain, "-c", "copy", wrapped)

        for source in [plain, wrapped]:
            with self.subTest(source=source.name):
                output = self.root / f"{source.stem}-copy.mp3"
                report = self.export(source, output)
                decoded = pcm(source)
                self.assertEqual(pcm(output), decoded)
                seconds = Fraction(len(decoded), 44_100)
                self.assertGreater(seconds, 20)
                self.assertLess(abs(ratio(report["duration"]) - seconds), Fraction(1, 100))
                packets = [probe(path, "-select_streams", "a:0", "-show_packets", "-show_entries",
                                 "packet=data_hash", "-show_data_hash", "sha256")["packets"]
                           for path in (source, output)]
                self.assertEqual(packets[1], packets[0])

                written = output.read_bytes()
                header = written.find(b"Xing", 0, 4096)
                self.assertGreater(header, 0, "the copy has no Xing header")
                # No encoder ID, delay or padding that a reader would subtract.
                self.assertEqual(written[header + 120:header + 156], bytes(36))
                info = probe(output, "-show_format", "-show_streams")
                self.assertLess(abs(Fraction(info["format"]["duration"]) - seconds), Fraction(1, 100))
                self.assertEqual(Fraction(info["streams"][0]["start_time"]), 0)
                if AFINFO.exists():
                    text = run([AFINFO, output]).decode()
                    line = next(line for line in text.splitlines() if "estimated duration" in line)
                    self.assertLess(abs(float(line.split(":")[1].split()[0]) - float(seconds)), 0.05, line)

    def test_whole_copy_of_headerless_cbr_mp3_keeps_every_sample(self):
        for name, options in [("stereo", ["-b:a", "128k"]),
                              ("mono", ["-ac", "1", "-ar", "22050", "-b:a", "32k"])]:
            with self.subTest(name=name):
                source = self.root / f"{name}.mp3"
                output = self.root / f"{name}-copy.mp3"
                ffmpeg("-f", "lavfi", "-i", "sine=d=3:r=44100", "-c:a", "libmp3lame", *options,
                       "-write_xing", "0", source)
                self.export(source, output)
                self.assertEqual(pcm(output), pcm(source))
                written = output.read_bytes()
                header = written.find(b"Info", 0, 4096)
                if header > 0:
                    self.assertEqual(written[header + 120:header + 156], bytes(36))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
