#!/usr/bin/env python3
"""Verify the shared export command's copy-only audio replacement."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from media_regression import ffmpeg, packets, probe, run


class Replacement(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        self.movie = self.folder / "source.mov"
        self.extracted = self.folder / "isolated.wav"
        self.processed = self.folder / "processed.wav"
        self.output = self.folder / "replaced.mov"
        # The second audio track starts after the picture and ends before it.
        ffmpeg("-f", "lavfi", "-i", "testsrc2=d=3:s=160x96:r=25",
               "-f", "lavfi", "-i", "sine=d=3:f=440:r=48000",
               "-itsoffset", "0.375", "-f", "lavfi", "-i", "sine=d=2:f=660:r=48000",
               "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264", "-threads", "1",
               "-c:a:0", "aac", "-c:a:1", "pcm_s16le", "-disposition:a:0", "default",
               "-disposition:a:1", "0", "-metadata:s:a:0", "language=jpn", "-metadata:s:a:1", "language=fra", self.movie)
        ffmpeg("-i", self.movie, "-map", "0:2", "-c", "copy", self.extracted)
        ffmpeg("-i", self.extracted, "-af", "volume=0.25", "-c:a", "pcm_s24le", self.processed)

    def replace(self, *, replacement=None, destination=None, target=2, extra=(), missing=False):
        args = [CLI, "export", "soundtrack", "replace", "--json", "--mode", "copy", "--clip", self.movie,
                "--replace-audio", replacement or self.processed, "--replace-track", str(target),
                "--output", destination or self.output, *extra]
        result = subprocess.run(args, capture_output=True, timeout=30)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode == 0, not missing, report)
        return report

    @staticmethod
    def pcm(file, track):
        return ffmpeg("-i", file, "-map", track, "-f", "s24le", "-c:a", "pcm_s24le", "-")

    def test_replaces_offset_pcm_track_and_preserves_picture_and_other_aac_packets(self):
        planned = self.replace(extra=("--dry-run",))
        self.assertFalse(self.output.exists())
        rendered = self.replace()
        bounds = {"from": "0", "to": "3"}
        self.assertEqual(planned["cut_map"]["occurrences"], [{
            "occurrence_number": 1, "input_number": 1, "file": str(self.movie),
            "input_clock": "source", "input": bounds, "output": bounds,
        }])
        self.assertEqual(rendered["cut_map"], planned["cut_map"])
        for stream in ("v:0", "a:0"):
            original = packets(self.movie, stream)
            actual = packets(self.output, stream)
            self.assertEqual(actual, original)
        self.assertEqual(self.pcm(self.output, "0:2"), self.pcm(self.processed, "0:0"))
        self.assertNotEqual(self.pcm(self.output, "0:2"), self.pcm(self.movie, "0:2"))
        streams = probe(self.output, "-show_streams")["streams"]
        self.assertEqual(streams[2]["codec_name"], "pcm_s24le")
        self.assertEqual(streams[1]["tags"]["language"], "jpn")
        self.assertEqual(streams[2]["tags"]["language"], "fra")
        self.assertEqual(streams[2]["disposition"]["default"], 0)
        self.assertEqual((float(streams[2]["start_time"]), float(streams[2]["duration"])), (0.375, 2.0))
        # PCM packet sizes depend on the muxer's interleaving, so compare concatenated payload bytes.
        self.assertEqual(run(["ffmpeg", "-v", "error", "-i", self.processed, "-map", "0:0", "-c", "copy", "-f", "s24le", "-"]),
                         run(["ffmpeg", "-v", "error", "-i", self.output, "-map", "0:2", "-c", "copy", "-f", "s24le", "-"]))

    def test_audio_only_replacement_preserves_six_channel_order_and_other_track(self):
        self.movie = self.folder / "two-tracks.mov"
        ffmpeg("-i", self.extracted, "-i", self.processed, "-map", "0:a", "-map", "1:a",
               "-c", "copy", self.movie)
        surround = self.folder / "surround.wav"
        tones = "|".join(f"0.1*sin(2*PI*{hz}*t)" for hz in (220, 330, 440, 110, 550, 660))
        ffmpeg("-f", "lavfi", "-i", f"aevalsrc={tones}:c=5.1:s=48000:d=2", "-c:a", "pcm_s24le", surround)
        self.replace(replacement=surround, target=1)
        streams = probe(self.output, "-show_streams")["streams"]
        self.assertEqual([s["channels"] for s in streams], [1, 6])
        self.assertEqual(streams[1]["channel_layout"], "5.1")
        self.assertEqual(self.pcm(self.output, "0:1"), self.pcm(surround, "0:0"))
        self.assertEqual(self.pcm(self.output, "0:0"), self.pcm(self.movie, "0:0"))

    def test_matroska_cannot_copy_named_pcm_surround_layout(self):
        self.movie = self.extracted
        surround = self.folder / "surround.wav"
        ffmpeg("-f", "lavfi", "-i", "anullsrc=r=48000:cl=5.1(side):d=2", "-c:a", "pcm_s24le", surround)
        for extension in ("mka", "mkv"):
            output = self.folder / f"replaced.{extension}"
            for extra in (("--dry-run",), ()):
                with self.subTest(extension=extension, extra=extra):
                    report = self.replace(replacement=surround, destination=output, target=0, extra=extra, missing=True)
                    self.assertEqual(report["error"]["code"], "unsupported_container")
                    self.assertIn("speaker layout", report["error"]["message"])
                    self.assertFalse(output.exists())
        self.replace(replacement=surround, target=0)
        self.assertEqual(probe(self.output, "-show_streams")["streams"][0]["channel_layout"], "5.1(side)")
        self.assertEqual(self.pcm(self.output, "0:a"), self.pcm(surround, "0:a"))

    def test_audio_only_replacement_can_write_m4a_wav_and_mka(self):
        self.movie = self.extracted
        incoming = self.folder / "processed.m4a"
        ffmpeg("-i", self.processed, "-c:a", "aac", incoming)
        for extension, replacement in (("wav", self.processed), ("mka", self.processed), ("m4a", incoming)):
            with self.subTest(extension=extension):
                output = self.folder / f"replaced.{extension}"
                report = self.replace(replacement=replacement, destination=output, target=0, extra=("--dry-run",))
                self.assertEqual(report["container"], extension)
                self.assertFalse(output.exists())
                self.replace(replacement=replacement, destination=output, target=0)
                self.assertEqual(self.pcm(output, "0:a"), self.pcm(replacement, "0:a"))

    def test_compressed_replacement_from_a_chosen_external_stream(self):
        alternate = self.folder / "alternate.mov"
        ffmpeg("-i", self.processed, "-f", "lavfi", "-i", "sine=d=2:f=850:r=48000",
               "-map", "1:a", "-map", "0:a", "-c:a", "aac", alternate)
        # Replace the primary AAC track in a zero-offset 2s movie.
        base = self.folder / "two-seconds.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=d=2:s=160x96:r=25", "-i", self.processed,
               "-c:v", "libx264", "-threads", "1", "-c:a", "aac", base)
        self.movie = base
        self.replace(replacement=alternate, target=1, extra=("--replacement-stream", "1"))
        self.assertEqual(packets(self.output, "v:0"), packets(base, "v:0"))
        incoming = packets(alternate, "a:1")
        actual = packets(self.output, "a:0")
        self.assertEqual([(p["pts"], p["data_hash"]) for p in incoming],
                         [(p["pts"], p["data_hash"]) for p in actual])

    def test_matroska_opus_slot_uses_the_rounded_container_clock(self):
        self.movie = self.folder / "two-opus-tracks.mkv"
        self.output = self.folder / "replaced.mkv"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=d=3:s=160x96:r=25",
               "-f", "lavfi", "-i", "sine=d=3:f=440:r=48000",
               "-f", "lavfi", "-i", "sine=d=2:f=660:r=48000",
               "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264",
               "-threads", "1", "-c:a", "libopus", self.movie)
        self.replace(extra=("--dry-run",))
        self.replace()
        for stream in ("v:0", "a:0"):
            self.assertEqual(packets(self.output, stream), packets(self.movie, stream))
        self.assertEqual(self.pcm(self.output, "0:2"), self.pcm(self.processed, "0:0"))
        target = probe(self.output, "-show_streams")["streams"][2]
        self.assertEqual(target["start_time"], "0.000000")

    def test_preserves_a_second_picture_track_and_selected_audio_slot(self):
        self.movie = self.folder / "alternate-picture.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=d=3:s=160x96:r=25",
               "-itsoffset", "0.2", "-f", "lavfi", "-i", "testsrc2=d=2:s=96x64:r=25",
               "-f", "lavfi", "-i", "sine=d=3:f=440:r=48000",
               "-i", self.extracted,
               "-map", "0:v", "-map", "1:v", "-map", "2:a", "-map", "3:a",
               "-c:v", "libx264", "-threads", "1", "-c:a:0", "aac", "-c:a:1", "copy", self.movie)
        self.replace(target=3)
        for stream in ("v:0", "v:1", "a:0"):
            self.assertEqual(packets(self.output, stream), packets(self.movie, stream))
        self.assertEqual(self.pcm(self.output, "0:3"), self.pcm(self.processed, "0:0"))

    def test_preserves_linked_mov_chapters_and_untouched_streams(self):
        metadata = self.folder / "chapters.txt"
        metadata.write_text(
            ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=First\n"
            "[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=3000\ntitle=Second\n"
        )
        chaptered = self.folder / "chaptered.mov"
        ffmpeg("-i", self.movie, "-i", metadata, "-map", "0", "-map_chapters", "1", "-c", "copy", chaptered)
        self.movie = chaptered
        self.assertEqual(probe(self.movie, "-show_streams")["streams"][-1]["codec_tag_string"], "text")
        self.replace(extra=("--dry-run",))
        self.replace()
        self.assertEqual(
            [stream["codec_tag_string"] for stream in probe(self.output, "-show_streams")["streams"]].count("text"), 1
        )
        for stream in ("v:0", "a:0"):
            self.assertEqual(packets(self.output, stream), packets(self.movie, stream))
        self.assertEqual(self.pcm(self.output, "0:2"), self.pcm(self.processed, "0:0"))
        expected = [("0.000000", "1.000000", "First"), ("1.000000", "3.000000", "Second")]
        for file in (self.movie, self.output):
            chapters = probe(file, "-show_chapters")["chapters"]
            self.assertEqual([(c["start_time"], c["end_time"], c["tags"]["title"]) for c in chapters], expected)

    def native_decoder(self):
        decoder = self.folder / "decodeaudio"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", Path(__file__).with_name("DecodeAudio.swift"),
                        "-o", decoder], check=True, capture_output=True, timeout=45)
        return decoder

    def test_multi_edit_aac_can_be_kept_or_transplanted(self):
        original = self.folder / "multitrack.mov"
        edited = self.folder / "joined.mov"
        ffmpeg("-f", "lavfi", "-i", "color=s=320x96:r=25:d=3",
               "-f", "lavfi", "-i", "aevalsrc=0.1*sin(2*PI*(600*t+50*t*t)):s=48000:d=3",
               "-f", "lavfi", "-i", "sine=r=48000:d=3:f=200", "-map", "0:v", "-map", "1:a", "-map", "2:a",
               "-c:v", "libx264", "-g", "1", "-c:a:0", "aac", "-c:a:1", "pcm_s16le", original)
        run([CLI, "export", "clips", "join", "--json", "--mode", "copy", "--clip", original, "--from", "2", "--to", "3",
             "--clip", original, "--from", "0", "--to", "1", "--output", edited], allow_diagnostics=True)
        decoder = self.native_decoder()
        reference = run([decoder, edited, "0"])
        self.assertEqual(len(reference), 96_000 * 2)
        # Place the edited AAC in the delayed target slot, including its original join.
        self.replace(replacement=edited, extra=("--replacement-stream", "1"))
        self.assertEqual(run([decoder, self.output, "1"]), bytes(18_000 * 2) + reference)
        self.assertEqual([p["data_hash"] for p in packets(edited, "a:0", ("-ignore_editlist", "1"))],
                         [p["data_hash"] for p in packets(self.output, "a:1", ("-ignore_editlist", "1"))])
        # Substitute the PCM track; the edited AAC beside it must survive byte-for-byte.
        self.movie = edited
        kept = self.folder / "kept-edits.mov"
        self.replace(destination=kept)
        self.assertEqual(run([decoder, kept, "0"]), reference)

    def test_offset_aac_replacement_preserves_priming_and_presentation(self):
        incoming = self.folder / "processed.m4a"
        ffmpeg("-i", self.processed, "-c:a", "aac", incoming)
        self.replace(replacement=incoming)
        self.assertEqual([p["data_hash"] for p in packets(incoming, "a:0")],
                         [p["data_hash"] for p in packets(self.output, "a:1")])
        decoder = self.native_decoder()
        original = run([decoder, incoming])
        presented = run([decoder, self.output, "1"])
        self.assertEqual(len(original), 96_000 * 2)
        self.assertEqual(presented, bytes(18_000 * 2) + original)

    def test_delay_that_cannot_be_preserved_fails_preflight(self):
        incoming = self.folder / "processed.mp3"
        ffmpeg("-i", self.processed, "-c:a", "libmp3lame", incoming)
        report = self.replace(replacement=incoming, extra=("--dry-run",), missing=True)
        self.assertEqual(report["error"]["code"], "unsupported_tracks")
        self.assertIn("encoder delay", report["error"]["message"])
        self.assertFalse(self.output.exists())

    def test_split_source_keeps_donor_in_both_pieces(self):
        base = self.folder / "intra.mov"
        donor = self.folder / "donor.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=d=2:s=160x96:r=25",
               "-f", "lavfi", "-i", "sine=d=2:f=440:r=48000", "-c:v", "libx264",
               "-g", "1", "-threads", "1", "-c:a", "pcm_s16le", base)
        ffmpeg("-i", base, "-f", "lavfi", "-i", "sine=d=2:f=880:r=48000",
               "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "pcm_s16le", donor)
        alias = self.folder / "alias.mov"
        alias.symlink_to(base)
        request = {"file": str(base), "output": str(self.output), "clips": [
            {"to": "1", "replace_audio": str(donor)}, {"file": str(alias), "from": "1"}]}
        result = subprocess.run([CLI, "export", "soundtrack", "replace", "--json", "--stdin"], text=True,
                                input=json.dumps(request), capture_output=True, timeout=30)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0, report)
        # The two pieces meet in one recording, so they are written as the one range they make, named by its first clip.
        self.assertEqual([segment["file"] for segment in report["segments"]], [str(base)])
        # Pieces that do not meet stay two, each reported by the path it was asked for.
        apart = {"file": str(base), "output": str(self.folder / "apart.mov"), "clips": [
            {"to": "1", "replace_audio": str(donor)}, {"file": str(alias), "from": "27/25"}]}
        planned = subprocess.run([CLI, "export", "soundtrack", "replace", "--json", "--stdin", "--dry-run"], text=True,
                                 input=json.dumps(apart), capture_output=True, timeout=30)
        self.assertEqual(planned.returncode, 0, planned.stdout)
        self.assertEqual([segment["file"] for segment in json.loads(planned.stdout)["segments"]], [str(base), str(alias)])
        self.assertEqual(self.pcm(self.output, "0:a:0"), self.pcm(donor, "0:a:0"))
        self.assertEqual([p["data_hash"] for p in packets(self.output, "v:0")],
                         [p["data_hash"] for p in packets(base, "v:0")])

    def test_reordered_sources_bind_different_soundtracks(self):
        first, second = [self.folder / (name + ".mov") for name in ("first", "second")]
        for path, frequency in [(first, 440), (second, 660)]:
            ffmpeg("-f", "lavfi", "-i", "testsrc2=d=1:s=128x96:r=25", "-f", "lavfi", "-i",
                   f"sine=d=1:f={frequency}:r=48000", "-c:v", "libx264", "-g", "1",
                   "-threads", "1", "-c:a", "pcm_s16le", path)
        request = {"output": str(self.output), "order": [2, 1, 2], "clips": [
            {"file": str(first), "replace_audio": str(second)},
            {"file": str(second), "replace_audio": str(first)}]}
        result = subprocess.run([CLI, "export", "soundtrack", "replace", "--json", "--stdin"], text=True,
                                input=json.dumps(request), capture_output=True, timeout=30)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0, report)
        self.assertEqual([s["file"] for s in report["segments"]], [str(second), str(first), str(second)])
        self.assertEqual(self.pcm(self.output, "0:a:0"),
                         self.pcm(first, "0:a:0") + self.pcm(second, "0:a:0") + self.pcm(first, "0:a:0"))

    def test_ranged_replacement_checks_destination_before_staging(self):
        self.output.write_bytes(b"existing output")
        report = self.replace(replacement=self.folder / "missing.wav", extra=("--to", "1"), missing=True)
        self.assertEqual(report["error"]["code"], "output_exists", report)
        self.assertEqual(self.output.read_bytes(), b"existing output")

    def test_ranged_replacement_failure_names_the_original_source(self):
        arguments = [CLI, "export", "soundtrack", "replace", "--mode", "copy", "--clip", self.movie, "--to", "0.125",
                     "--replace-audio", self.processed, "--replace-track", "2", "--output", self.output]
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"Clip 1 · {self.movie.name}", result.stderr)
        self.assertFalse(self.output.exists())

    def test_ranged_replacement_dry_run_lists_replayable_original_clip(self):
        self.movie = self.folder / "long-gop.mov"
        donor = self.folder / "donor.wav"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=d=3:s=160x96:r=25",
               "-f", "lavfi", "-i", "sine=d=3:f=440:r=48000", "-c:v", "libx264", "-g", "25",
               "-c:a", "pcm_s16le", self.movie)
        ffmpeg("-f", "lavfi", "-i", "sine=d=3:f=660:r=48000", "-c:a", "pcm_s16le", donor)
        span = ("--from", "0.8", "--to", "2.12")
        report = self.replace(replacement=donor, target=1, extra=(*span, "--snap", "nearest", "--dry-run"))
        raises = report["tier"]["raise"]
        self.assertEqual([offer["tier"] for offer in raises], ["true_lossless"])
        self.assertEqual(raises[0]["clips"], [{"file": str(self.movie), "from": "1", "to": "2"}])
        self.replace(replacement=donor, target=1, extra=("--from", "1", "--to", "2"))
        self.assertEqual([p["data_hash"] for p in packets(self.output, "v:0")],
                         [p["data_hash"] for p in packets(self.movie, "v:0")[25:50]])

    def test_ranged_replacement_resolves_the_final_container_after_staging(self):
        self.movie = self.folder / "intra.mov"
        self.output = self.folder / "trimmed.m4v"
        donor = self.folder / "donor.m4a"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=d=2:s=160x96:r=25",
               "-f", "lavfi", "-i", "sine=d=2:f=440:r=48000", "-c:v", "libx264",
               "-g", "1", "-threads", "1", "-c:a", "aac", self.movie)
        ffmpeg("-f", "lavfi", "-i", "sine=d=2:f=880:r=48000", "-c:a", "aac", donor)
        trim = ("--from", "0.64", "--to", "1.28")
        report = self.replace(replacement=donor, target=1, extra=(*trim, "--dry-run"))
        self.assertEqual(report["container"], "m4v")
        self.assertFalse(self.output.exists())
        self.replace(replacement=donor, target=1, extra=trim)
        self.assertEqual([p["data_hash"] for p in packets(self.output, "v:0")],
                         [p["data_hash"] for p in packets(self.movie, "v:0")[16:32]])
        self.assertLessEqual({p["data_hash"] for p in packets(self.output, "a:0")},
                             {p["data_hash"] for p in packets(donor, "a:0")})

    def test_rejects_smart_mode_for_replacement(self):
        settings = {"output": str(self.output), "clips": [{"file": str(self.movie)}],
                    "replace_audio": str(self.processed), "replace_track": 2}
        for mode in ("smart", "copy"):
            request = dict(settings, mode=mode)
            result = subprocess.run([CLI, "export", "soundtrack", "replace", "--json", "--stdin", "--dry-run"],
                                    input=json.dumps(request), capture_output=True, text=True, timeout=30)
            report = json.loads(result.stdout)
            if mode == "smart":
                self.assertEqual(result.returncode, 2, report)
                self.assertEqual(report["error"]["code"], "invalid_arguments", report)
            else:
                self.assertEqual(result.returncode, 0, report)
                self.assertTrue(report["dry_run"])
            self.assertFalse(self.output.exists())

    def test_mismatch_invalid_stream_and_existing_destination(self):
        original = self.movie.read_bytes()
        expected = set(self.folder.iterdir()) | {Path(str(path) + ".cutdb") for path in (self.movie, self.processed)}
        for error, kwargs in [
            ("duration_mismatch", {"target": 1}),
            ("no_audio", {"target": 0}),
            ("no_audio", {"extra": ("--replacement-stream", "40")}),
            ("output_exists", {"destination": self.movie}),
            ("unsupported_container", {"destination": self.folder / "video.wav"}),
        ]:
            with self.subTest(code=error):
                report = self.replace(missing=True, **kwargs)
                self.assertEqual(report["error"]["code"], error, report)
                destination = kwargs.get("destination", self.output)
                if destination == self.movie:
                    # The occupied destination is the source movie itself.
                    self.assertEqual(self.movie.read_bytes(), original)
                else:
                    self.assertFalse(destination.exists())
                # Neither the requested file nor a staging neighbour remains.
                self.assertEqual(set(self.folder.iterdir()), expected)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
