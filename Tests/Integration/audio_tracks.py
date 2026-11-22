#!/usr/bin/env python3
"""Exercise the normal editing commands on sound files and selected movie tracks."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import wave


def time(value):
    return Fraction(value["numerator"], value["denominator"])


def ffmpeg(*args):
    return subprocess.check_output(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", *args],
                                   timeout=120)


def probe(source, *options):
    return json.loads(subprocess.check_output(["ffprobe", "-v", "error", *options, "-of", "json", source],
                                              timeout=120))


def hashes(source, selector):
    data = probe(source, "-select_streams", selector, "-show_packets", "-show_data_hash", "sha256",
                 "-show_entries", "packet=data_hash")
    return [packet["data_hash"] for packet in data["packets"]]


def pcm(source, selector="0:a:0"):
    return ffmpeg("-i", source, "-map", selector, "-c:a", "pcm_s16le", "-f", "s16le", "-")


class TrackEditing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temp.cleanup)
        root = Path(temp.name)
        cls.sound = root / "Recording.wav"
        cls.movie = root / "Multitrack.mov"
        cls.processed = root / "Processed.wav"
        tone = "0.35*sin(2*PI*(230*t+12*t*t))*if(between(n,48000,143999),0,1)"
        ffmpeg("-f", "lavfi", "-i", f"aevalsrc={tone.replace(',', chr(92)+',')}:s=48000:d=4",
               "-c:a", "pcm_s16le", cls.sound)
        ffmpeg("-f", "lavfi", "-i", "testsrc2=size=192x96:rate=25:duration=4", "-i", cls.sound,
               "-f", "lavfi", "-i", "sine=f=880:r=48000:d=4",
               "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264", "-g", "25",
               "-c:a:0", "aac", "-c:a:1", "pcm_s16le", cls.movie)
        ffmpeg("-i", cls.sound, "-af", "volume=0.5", "-c:a", "pcm_s16le", cls.processed)

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def cli(self, *args, request=None, ok=True):
        result = subprocess.run([CLI, *args, "--json"], capture_output=True, text=True, timeout=30,
                                input=json.dumps(request) if request is not None else None)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["ok"], ok, report)
        return report

    def test_wav_json_edit_reorders_exact_samples(self):
        output = self.root / "Edit.wav"
        bounds = [(41, 5951), (81325, 92241)]
        def rational(n):
            return {"numerator": n, "denominator": 48000}
        request = {"file": str(self.sound), "clips": [{"from": rational(a), "to": rational(b)} for a,b in bounds],
                   "order": [2, 1, 2], "output": str(output)}
        dry = self.cli("export", "--stdin", "--dry-run", request=request)
        self.assertFalse(output.exists())
        result = self.cli("export", "--stdin", request=request)
        self.assertEqual(dry["segments"], result["segments"])
        self.assertEqual(result["mode"], "copy")
        self.assertEqual(time(result["encodedDuration"]), 0)
        with wave.open(str(self.sound)) as original, wave.open(str(output)) as assembled:
            audio = original.readframes(original.getnframes())
            self.assertEqual(assembled.getsampwidth(), 2)
            self.assertEqual(assembled.readframes(assembled.getnframes()),
                             b"".join(audio[a*2:b*2] for a,b in [bounds[1], bounds[0], bounds[1]]))

    def test_movie_end_does_not_extend_an_audio_only_packet_cut(self):
        source = self.root / "Longer audio.mov"
        output = self.root / "Selection.ac3"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=size=128x64:rate=25:duration=2",
               "-f", "lavfi", "-i", "sine=f=650:r=48000:d=3.2",
               "-c:v", "libx264", "-c:a", "ac3", source)
        args = ["export", "--audio-only", "--clip", source, "--from", "358/375", "--output", output]
        report = self.cli(*args, "--to", "2", ok=False)
        self.assertEqual(report["error"]["code"], "unsafe_boundary")
        self.assertEqual(report["error"]["boundary"], "to")
        self.assertFalse(output.exists())

        report = self.cli(*args, "--to", "742/375")
        self.assertEqual(time(report["duration"]), Fraction(128, 125))
        packets = hashes(source, "a:0")
        self.assertEqual(hashes(output, "a:0"), packets[30:62])

    def test_copy_excludes_an_audio_track_with_repeated_timestamps(self):
        source = self.root / "Damaged first track.mka"
        ffmpeg("-f", "lavfi", "-i", "sine=d=2:f=440:r=48000",
               "-f", "lavfi", "-i", "sine=d=2:f=660:r=48000",
               "-filter:a:0", "asetpts=0", "-map", "0:a", "-map", "1:a",
               "-c:a:0", "aac", "-c:a:1", "pcm_s16le", source)
        flags = ("export", "--clip", source, "--tracks", "audio", "--mode", "copy")
        rejected = self.cli(*flags, "--output", self.root / "Both.mka", ok=False)
        self.assertEqual(rejected["error"]["code"], "unsupported_tracks")
        self.assertIn("non-increasing presentation timestamps", rejected["error"]["message"])
        selected = self.cli(*flags, "--audio-stream", "0", "--output", self.root / "First.mka", ok=False)
        # The refusal is the same. Each request lists its own working alternatives beside it.
        self.assertEqual({key: value for key, value in selected["error"].items() if key != "alternatives"},
                         {key: value for key, value in rejected["error"].items() if key != "alternatives"})
        expected = ffmpeg("-i", source, "-map", "0:1", "-c", "copy", "-f", "s16le", "-")
        for label in ("Fresh", "Cached"):
            with self.subTest(index=label):
                if label == "Cached":
                    self.assertTrue(self.cli("sidecar", "--only", "index", source)["inventory"]["hasIndex"])
                output = self.root / f"{label} second track.wav"
                self.cli(*flags, "--audio-stream", "1", "--output", output)
                with wave.open(str(output)) as written:
                    self.assertEqual(written.readframes(written.getnframes()), expected)

    def test_aac_empty_edit_is_matched_to_the_output_track_across_sources(self):
        source = self.root / "Delayed.mov"
        joined = self.root / "Repeated.mov"
        audio = self.root / "Next.m4a"
        output = self.root / "Joined.m4a"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=size=128x64:rate=25:duration=2",
               "-f", "lavfi", "-i", "sine=f=500:r=48000:d=2", "-itsoffset", "1.75",
               "-f", "lavfi", "-i", "sine=f=750:r=48000:d=0.25",
               "-map", "0:v", "-map", "1:a", "-map", "2:a",
               "-c:v", "libx264", "-g", "25", "-c:a", "aac", source)
        self.cli("export", "--clip", source, "--clip", source, "--output", joined)
        ffmpeg("-f", "lavfi", "-i", "sine=f=500:r=48000:d=1",
               "-f", "lavfi", "-i", "sine=f=750:r=48000:d=1",
               "-map", "0:a", "-map", "1:a", "-c:a", "aac", audio)
        # The second AAC track is stream 2 in the movie and stream 1 in
        # the audio file. Its first edit is empty, but the next is audible.
        result = self.cli("export", "--audio-only", "--clip", joined, "--from", "2.1", "--to", "2.5",
                          "--clip", audio, "--from", "0.2", "--to", "0.6", "--output", output)
        self.assertEqual(time(result["duration"]), Fraction(4, 5))
        self.assertEqual(len(probe(output, "-show_streams")["streams"]), 2)

    def test_rearrange_and_bulk_use_audio_copy_and_infer_wav(self):
        output = self.root / "Rearranged.wav"
        self.cli("rearrange", self.sound, "--output", output, "2.3-2.6,0.1-0.2")
        original = pcm(self.sound)
        self.assertEqual(pcm(output), original[110400*2:124800*2] + original[4800*2:9600*2])
        report = self.cli("bulk", "--stdin", request={"file":str(self.sound), "outputDirectory":str(self.root),
                          "ranges":[{"from": "0.1","to":"0.2"},{"from":"3.1","to":"3.3"}]})
        self.assertEqual(len(report["outputs"]), 2)
        for index,item in enumerate(report["outputs"]):
            first,last = [(4800,9600),(148800,158400)][index]
            self.assertEqual(Path(item["output"]).suffix, ".wav")
            self.assertEqual(pcm(item["output"]), original[first*2:last*2])

    def test_caf_reorders_stereo_float_pcm_without_changing_samples(self):
        source = self.root / "Float.caf"
        output = self.root / "Edited.caf"
        ffmpeg("-i", self.sound, "-af", "pan=stereo|c0=c0|c1=0.5*c0", "-c:a", "pcm_f32le", source)
        ranges = [(12123, 14231), (121, 231)]
        args = [arg for start, end in ranges for arg in
                ("--clip", source, "--from", f"{start}/48000", "--to", f"{end}/48000")]
        report = self.cli("export", "--output", output, *args)
        self.assertEqual(report["mode"], "copy")
        self.assertEqual(time(report["duration"]), Fraction(2218, 48000))
        original = ffmpeg("-i", source, "-c:a", "pcm_f32le", "-f", "f32le", "-")
        edited = ffmpeg("-i", output, "-c:a", "pcm_f32le", "-f", "f32le", "-")
        self.assertEqual(edited, b"".join(original[8 * start:8 * end] for start, end in ranges))

    def test_bulk_falls_back_to_mov_for_sample_accurate_linked_pcm(self):
        source = self.root / "PCM.mp4"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=s=96x64:r=25:d=3", "-i", self.sound, "-t", "3",
               "-c:v", "libx264", "-g", "25", "-keyint_min", "25", "-sc_threshold", "0",
               "-c:a", "pcm_s16le", source)
        refused = self.cli("export", "--clip", source, "--from", "0", "--to", "1", "--mode", "copy",
                           "--output", self.root / "Explicit.mp4", "--dry-run", ok=False)["error"]
        self.assertEqual((refused["code"], refused["segment"], refused["track"]), ("unsupported_tracks", 1, 1), refused)
        report = self.cli("bulk", "--stdin", "--mode", "copy",
                          request={"file": str(source), "outputDirectory": str(self.root),
                                   "ranges": [{"from": "0", "to": "1"}]})
        output = Path(report["outputs"][0]["output"])
        self.assertEqual(output.suffix, ".mov")
        self.assertEqual(pcm(output), pcm(source)[:48000 * 2])
        self.assertEqual(hashes(output, "v:0"), hashes(source, "v:0")[:25])

    def test_silence_strip_join_and_replay_on_sound_file(self):
        report = self.cli("silence", "--leave","0.25","--waveform","8",self.sound)
        self.assertEqual(time(report["pauses"][0]["from"]),1)
        self.assertEqual(time(report["pauses"][0]["to"]),3)
        output = self.root / "Joined.wav"
        self.cli("silence","--stdin","--output",output,request=report)
        audio = pcm(self.sound)
        self.assertEqual(pcm(output), audio[:54000*2] + audio[138000*2:])

    def test_silence_replays_on_the_common_linked_audio_sample_grid(self):
        source = self.root / "Two sample rates.mov"
        ffmpeg("-i", self.sound, "-f", "lavfi", "-i", "sine=f=880:r=44100:d=4",
               "-map", "0:a", "-map", "1:a", "-c:a", "pcm_s16le", source)
        report = self.cli("silence", "--leave", "0.407", source)
        start, end = (time(report["removals"][0][key]) for key in ("from", "to"))
        self.assertEqual((start, end), (Fraction(362, 300), Fraction(838, 300)))

        output = self.root / "Joined.mov"
        dry = self.cli("silence", "--stdin", "--output", output, "--dry-run", request=report)
        self.assertFalse(output.exists())
        written = self.cli("silence", "--stdin", "--output", output, request=report)
        self.assertEqual(dry["segments"], written["segments"])
        self.assertEqual(time(written["duration"]), 4 - (end - start))
        for index, rate in enumerate((48000, 44100)):
            selector = f"0:a:{index}"
            original = pcm(source, selector)
            self.assertEqual(pcm(output, selector),
                             original[:2 * int(start * rate)] + original[2 * int(end * rate):])

    def test_silence_summary_counts_only_silence_removed_from_selected_audio(self):
        source = self.root / "Longer soundtrack.mov"
        ffmpeg("-f", "lavfi", "-i", "color=s=160x96:r=25:d=4",
               "-f", "lavfi", "-i", "sine=f=440:r=48000:d=5",
               "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-c:a", "pcm_s16le", source)
        output = self.root / "Uncut track.wav"
        written = self.cli("silence", "--tracks", "audio", "--output", output, source)
        self.assertEqual(time(written["duration"]), 5)
        self.assertEqual(written["silence"]["detectedPauses"], 0)
        self.assertEqual(time(written["silence"]["removedDuration"]), 0)
        self.assertEqual(pcm(output), pcm(source))

        source_with_pause = self.root / "Longer soundtrack with pause.mov"
        signal = r"if(lt(t\,1)+gte(t\,3)\,0.25*sin(2*PI*(400+100*gte(t\,4))*t)\,0)"
        ffmpeg("-i", source, "-f", "lavfi", "-i", f"aevalsrc={signal}:s=48000:d=5",
               "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "pcm_s16le", source_with_pause)
        report = self.cli("silence", "--tracks", "audio", source_with_pause)
        self.assertEqual(time(report["duration"]), 5)
        self.assertEqual(time(report["removedDuration"]), Fraction(8, 5))
        output = self.root / "Soundtrack without pause.wav"
        written = self.cli("silence", "--stdin", "--output", output, request=report)
        self.assertEqual(time(written["duration"]), Fraction(17, 5))
        self.assertEqual(time(written["silence"]["removedDuration"]), Fraction(8, 5))
        original = pcm(source_with_pause)
        self.assertEqual(pcm(output), original[:2 * 57600] + original[2 * 134400:])

    def test_sidecar_build_reuse_and_no_video_queries(self):
        source = self.root / "Speech.wav"
        source.write_bytes(self.sound.read_bytes())
        base = self.cli("inspect", source)
        self.assertFalse(base["media"]["hasVideo"])
        self.assertEqual(base["media"]["frames"], [])
        self.assertIn("wav",base["copy"]["containers"])
        saved = self.cli("sidecar",source)
        self.assertTrue(saved["inventory"]["hasIndex"])
        self.assertFalse(saved["inventory"]["hasScenes"])
        self.assertEqual(saved["inventory"]["waveformStreams"],[0])
        self.assertEqual(saved["inventory"]["envelopeStreams"],[0])
        self.assertEqual(self.cli("inspect",source),base)
        for command in [["frames","--output",self.root/"Images"],["scenes"],["inspect","--keyframes"]]:
            self.assertEqual(self.cli(*command,source,ok=False)["error"]["code"],"no_video")
        self.assertFalse((self.root / "Images").exists())

    def test_extract_each_track_preserves_video_aac_and_pcm(self):
        video = self.root / "Picture.mov"
        aac = self.root / "Sound.m4a"
        wav = self.root / "Effect input.wav"
        self.cli("export","--video-only","--clip",self.movie,"--output",video)
        self.assertEqual([s["codec_type"] for s in probe(video,"-show_streams")["streams"]],["video"])
        self.assertEqual(hashes(video,"v:0"), hashes(self.movie,"v:0"))
        for index,output in [(1,aac),(2,wav)]:
            options = self.cli("inspect","--tracks","audio","--audio-stream",str(index),self.movie)
            self.assertIn(output.suffix[1:],options["copy"]["containers"])
            result = self.cli("export","--stdin",request={"tracks":"audio","audioStream":index,
                              "clips":[{"file":str(self.movie)}],"output":str(output)})
            self.assertEqual(result["segments"][0]["trackActions"],
                             [{"action": "copy", "index": index, "kind": "audio"}])
            self.assertEqual(len(probe(output,"-show_streams")["streams"]),1)
        self.assertEqual(hashes(aac,"a:0"),hashes(self.movie,"a:0"))
        self.assertEqual(pcm(wav),pcm(self.movie,"0:a:1"))

    def test_replacement_keeps_original_video_and_other_soundtracks(self):
        output = self.root / "Replaced.mov"
        args = ["export","--clip",self.movie,"--replace-audio",self.processed,
                "--replace-track","2","--replacement-stream","0","--output",output]
        dry = self.cli(*args,"--dry-run")
        self.assertFalse(output.exists())
        result = self.cli("export","--stdin",request={"replaceAudio":str(self.processed),"replaceTrack":2,
                          "replacementStream":0,"file":str(self.movie),"clips":[{}],"output":str(output)})
        self.assertEqual(result["replacement"],dry["replacement"])
        self.assertEqual(time(result["encodedDuration"]),0)
        self.assertEqual(hashes(output,"v:0"),hashes(self.movie,"v:0"))
        self.assertEqual(hashes(output,"a:0"),hashes(self.movie,"a:0"))
        self.assertEqual(pcm(output,"0:a:1"),pcm(self.processed))
        self.assertNotEqual(pcm(output,"0:a:1"),pcm(self.movie,"0:a:1"))

    def test_lossless_and_compressed_audio_use_the_same_commands(self):
        for codec, extension in [("flac","flac"), ("libmp3lame","mp3"), ("aac","m4a"), ("libopus","opus")]:
            with self.subTest(codec=codec):
                source = self.root / f"Input.{extension}"
                output = self.root / f"Full.{extension}"
                ffmpeg("-i", self.sound, "-c:a", codec, source)
                info = self.cli("inspect",source)
                self.assertFalse(info["media"]["hasVideo"])
                self.assertTrue(info["copy"]["eligible"], info)
                self.cli("export","--clip",source,"--output",output)
                self.assertEqual(hashes(output,"a:0"), hashes(source,"a:0"))
                self.assertEqual(len(pcm(output)), len(pcm(source)))

    def test_bulk_edited_flac_picks_a_timestamped_audio_container(self):
        source = self.root/"Interview.flac"
        ffmpeg("-i",self.sound,"-c:a","flac",source)
        bounds = self.cli("inspect","--audio-packets","--stream","0","--from","1","--to","2",source)["media"]["audioPackets"]
        self.assertGreater(len(bounds), 2)
        self.assertTrue(all(1 <= time(row["time"]) < 2 and row["stream"] == 0 for row in bounds))
        report = self.cli("bulk","--stdin",request={"file":str(source), "outputDirectory":str(self.root),
                          "ranges":[{"from":bounds[0]["time"],"to":bounds[-1]["time"]}]})
        item = report["outputs"][0]
        self.assertEqual(item["container"],"mka")
        self.assertEqual(time(item["encodedDuration"]),0)
        selected = hashes(item["output"],"a:0")
        originals = hashes(source,"a:0")
        start = originals.index(selected[0])
        self.assertEqual(selected, originals[start:start+len(selected)])

    def test_rejects_impossible_selection_and_replacement_requests(self):
        output = self.root/"Bad.wav"
        for code, args in [
            ("no_video", ["--tracks","video","--clip",self.sound]),
            # An audio selection converts in encode mode. Video settings and a video selection do not apply.
            ("invalid_arguments", ["--tracks","audio","--mode","encode","--video","h264","--clip",self.sound]),
            ("invalid_arguments", ["--tracks","video","--mode","encode","--clip",self.movie]),
            ("no_audio", ["--tracks","audio","--audio-stream","999","--clip",self.movie]),
            ("unsupported_container", ["--replace-audio",self.processed,"--clip",self.movie,"--from","1"]),
            ("invalid_arguments", ["--replace-track","1","--clip",self.movie]),
        ]:
            with self.subTest(args=args[:4]):
                report = self.cli("export",*args,"--output",output,ok=False)
                self.assertEqual(report["error"]["code"], code, report)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    options, rest = parser.parse_known_args()
    CLI = options.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *rest])
