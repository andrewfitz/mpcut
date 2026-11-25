#!/usr/bin/env python3
"""Generate local spoken media and timing oracles for transcript integration QA."""

import argparse
from array import array
from fractions import Fraction
from hashlib import sha256
import json
from pathlib import Path
import random
import re
import subprocess
import tempfile
import wave

from media_regression import ffmpeg, probe

RATE = 16000
DURATION = 18
SCRIPT = (
    ("question", "Host", "0.4", "Could you describe what the lantern does?", {"lav": 1, "wide": .65}),
    ("interrupt", "Guest", "1.8", "Just a second!", {"wide": .8, "close": 1, "lav": .07}),
    ("take1", "Guest", "3", "The lantern glows only when the moon rises.", {"wide": 1, "close": .8, "lav": .45}),
    ("take2", "Guest", "7", "The lantern glows when the moon rises.", {"wide": 1, "close": .8, "lav": .45}),
    ("take3", "Guest", "11", "The lantern glows only when the moon rises.", {"wide": 1, "close": .8, "lav": .45}),
    ("off-air", "Guest", "15", "The compass is upside down.", {"close": 1}),
)
VOICES = {"Host": "rms", "Guest": "slt"}
# Hand-aligned Flite 2.2 phoneme counts for the fixed script and voices.
WORD_PHONE_COUNTS = {
    "question": (3, 2, 7, 3, 2, 6, 3),
    "interrupt": (4, 1, 6),
    "take1": (2, 6, 4, 4, 3, 2, 3, 5),
    "take2": (2, 6, 4, 3, 2, 3, 5),
    "take3": (2, 6, 4, 4, 3, 2, 3, 5),
    "off-air": (2, 6, 2, 5, 3),
}
TRACKS = {
    "wide": {"stream": 1, "offset": "-1/2", "file": "wide.mov", "role": "mixed_audio"},
    "close": {"stream": 1, "offset": "1", "file": "close.mov", "role": "mixed_audio"},
    "lav": {"stream": 0, "offset": "0", "file": "lav.wav", "role": "isolated_mic", "speaker": "Host"},
}


def samples(seconds):
    return int(Fraction(seconds) * RATE)


def write_wav(path, values, rate=RATE):
    with wave.open(str(path), "wb") as out:
        out.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        out.writeframes(array("h", (max(-32768, min(32767, x)) for x in values)).tobytes())


def speak(tmp, flite, label, speaker, line, start):
    recording = tmp / "phrase.wav"
    synthesis = subprocess.run(
        [flite, "-voice", VOICES[speaker], "-psdur", "-t", line, "-o", recording],
        check=True, capture_output=True, text=True, timeout=30,
    )
    phones = re.findall(r"([a-z]+):([0-9.]+)", synthesis.stdout)
    counts = WORD_PHONE_COUNTS[label]
    if not phones or phones[0][0] != "pau" or phones[-1][0] != "pau" or len(phones) != 2 + sum(counts):
        raise ValueError(f"Unexpected phoneme annotation for {label}: {synthesis.stdout}")
    first = samples(phones[0][1])
    i = 0
    previous = start
    words = []
    for word, count in zip(line.split(), counts, strict=True):
        i += count
        end = start + samples(phones[i][1]) - first
        words.append({"text": word, "start": previous, "end": end})
        previous = end
    signal = array("h", ffmpeg("-i", recording, "-ar", str(RATE), "-ac", "1", "-f", "s16le", "-"))
    return signal[first:first + previous - start], words


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def timestamp(sample):
    milliseconds = sample * 1000 // RATE
    seconds, remainder = divmod(milliseconds, 1000)
    minutes, seconds = divmod(seconds, 60)
    return f"00:{minutes:02}:{seconds:02},{remainder:03}"


def write_cues(path, phrases, track):
    offset = samples(TRACKS[track]["offset"])
    audible = [phrase for phrase in phrases if track in phrase["tracks"]]
    path.write_text("".join(
        f"{index}\n{timestamp(phrase['start'] - offset)} --> {timestamp(phrase['end'] - offset)}\n"
        f"{phrase['text']}\n\n"
        for index, phrase in enumerate(audible, 1)
    ))


def camera(path, soundtrack, *, seconds, color, codec="pcm_s16le", delay="0", gap=False):
    audio_filter = ["-af", "aselect='not(between(t,4.8,5.8))'"] if gap else []
    ffmpeg("-y", "-f", "lavfi", "-i", f"testsrc2=s=192x108:r=25:d={seconds}",
           "-itsoffset", delay, "-i", soundtrack, "-map", "0:v:0", "-map", "1:a:0",
           "-vf", f"drawbox=x=0:y=0:w=iw:h=12:color={color}:t=fill",
           "-c:v", "libx264", "-preset", "ultrafast", "-g", "25", "-bf", "0",
           "-c:a", codec, *audio_filter, path)


def write_manifest(root, audio):
    """Emit helper inputs in source clocks, separately from the ASR baseline inputs."""
    work = root.resolve() / "helper-session"
    work.mkdir(exist_ok=True)
    track_samples = {
        "wide": [0] * samples("0.5") + audio["wide"] + [0] * samples("0.02"),
        "close": audio["close"][samples("1"):],
        "lav": audio["lav"],
    }
    entries = []
    for track, info in TRACKS.items():
        recording = work / f"{track}.wav"
        write_wav(recording, track_samples[track])
        checksum = sha256(recording.read_bytes()).hexdigest()
        offset = Fraction(info["offset"])
        entries.append({
            "track_id": track, "source_id": track, "stream_evidence": {"fixture_sha256": checksum},
            "binding": {"stream_index": info["stream"], "origin": {"numerator": 0, "denominator": 1},
                        "session_start": {"numerator": offset.numerator, "denominator": offset.denominator}},
            "name": track, "role": info["role"], "speaker": info.get("speaker"), "recognize": True,
            "start_frame": samples(offset), "audio": str(recording),
            "result": str(work / f"{track}.json"), "activity": str(work / f"{track}-activity.json"),
            "recognition_key": f"parakeet-v3-fixture-{checksum}",
        })
    save_json(work / "manifest.json", {
        "schema_version": 1, "job_id": "spoken-fixture", "fingerprint": sha256(
            json.dumps(entries, sort_keys=True).encode()
        ).hexdigest(), "engine": "parakeet-v3", "language": "en", "expected_speakers": 2,
        "output": str(work / "result.json"), "tracks": entries,
    })


def write_parity_fixture(root):
    rate = 48000
    write_wav(root / "parity.wav", [4000] * rate + [-4000] * rate + [8000] * (2 * rate), rate)
    save_json(root / "parity.cut", {"format": "mpcut", "schema_version": 9, "kind": "sequence",
                                   "clips": [{"id": "clip", "file": "parity.wav", "from": "0", "to": "4"}]})
    save_json(root / "parity-words.json", {
        "source": "parity.wav", "duration_seconds": 4,
        "sample_zero": {"numerator": 0, "denominator": 1}, "metadata": {},
        "segments": [{"start": 0.25, "end": 3.5, "words": [
            {"text": "Keep", "start": 0.25, "end": 0.5},
            {"text": "remove", "start": 1, "end": 2},
            {"text": "this", "start": 2.5, "end": 3.5},
        ]}],
    })
    save_json(root / "queue.cut", {
        "format": "mpcut", "schema_version": 9, "kind": "multicam", "reference_angle_id": "wide",
        "group_range": {"from": "0", "to": "4"},
        "angles": [{"id": "wide", "file": "wide.mov"}, {"id": "close", "file": "close.mov"}],
        "audio_sources": [{"id": "lav", "file": "lav.wav"}],
        "audio": {"mode": "fixed", "source_id": "lav", "audio_stream_index": 0},
        "switches": [{"group_time": "0", "angle_id": "wide"}, {"group_time": "2", "angle_id": "close"}],
    })
    save_json(root / "queue-words.json", {
        "source": "lav.wav", "duration_seconds": 18,
        "sample_zero": {"numerator": 0, "denominator": 1}, "metadata": {},
        "segments": [{"start": 1, "end": 3, "words": [
            {"text": "Queuing", "start": 1, "end": 1.9},
            {"text": "excerpts", "start": 2.1, "end": 3},
        ]}],
    })


def create(root, flite="flite"):
    root.mkdir(parents=True, exist_ok=True)
    audio = {track: [0] * samples(DURATION) for track in TRACKS}
    guest_lav = [0] * samples(DURATION)
    phrases = []
    with tempfile.TemporaryDirectory() as work:
        tmp = Path(work)
        for label, speaker, onset, text, gain in SCRIPT:
            start = samples(onset)
            signal, words = speak(tmp, flite, label, speaker, text, start)
            phrases.append({"id": label, "speaker": speaker, "text": text, "start": start,
                            "end": start + len(signal), "words": words, "tracks": gain})
            for track, volume in gain.items():
                for i, value in enumerate(signal, start):
                    audio[track][i] += round(value * volume)
            if label != "off-air":
                volume = .85 if speaker == "Guest" else .10
                for i, value in enumerate(signal, start):
                    guest_lav[i] += round(value * volume)

        # A deterministic non-speech burst coincides with the host's question.
        rng = random.Random(283)
        cough_start = samples("1.55")
        cough = [round(rng.uniform(-6000, 6000) * (1 - i / 3200) ** 2) for i in range(3200)]
        audio["close"][cough_start:cough_start + len(cough)] = cough

        for track, values in audio.items():
            write_wav(root / f"{track}-recognition.wav", values)
            write_cues(root / f"{track}.srt", phrases, track)
        write_wav(root / "lav.wav", audio["lav"])
        write_wav(root / "guest-lav-benchmark.wav", guest_lav)
        write_wav(tmp / "wide.wav", [0] * samples("0.5") + audio["wide"])
        write_wav(tmp / "close.wav", audio["close"][samples("1.5"):])
        camera(root / "wide.mov", tmp / "wide.wav", seconds="18.52", color="blue")
        camera(root / "close.mov", tmp / "close.wav", seconds="17", color="red", delay="0.5")
        # Matroska preserves the packet hole; a MOV PCM stream can close it during muxing.
        camera(root / "close-gap.mkv", tmp / "close.wav", seconds="17", color="red", delay="0.5", gap=True)

        click = [0] * samples(3)
        click[samples("1.25")] = 30000
        write_wav(tmp / "click.wav", click)
        camera(root / "priming-click.mov", tmp / "click.wav", seconds=4, color="white", codec="aac")
        camera(root / "delayed-click.mov", tmp / "click.wav", seconds=4, color="white", delay="0.5")
    project = {"format": "mpcut", "schema_version": 9, "kind": "multicam", "reference_angle_id": "wide",
               "group_range": {"from": "0", "to": "18"},
               "angles": [{"id": key, "file": TRACKS[key]["file"], "offset": TRACKS[key]["offset"],
                           "audio_stream_index": TRACKS[key]["stream"]} for key in ("wide", "close")],
               "audio_sources": [{"id": "lav", "file": "lav.wav", "offset": "0"}],
               "audio": {"mode": "fixed", "source_id": "lav", "audio_stream_index": 0},
               "switches": [{"group_time": "0", "angle_id": "wide"}, {"group_time": "2", "angle_id": "close"},
                            {"group_time": "12", "angle_id": "wide"}]}
    save_json(root / "interview.cut", project)
    save_json(root / "sequence.cut", {"format": "mpcut", "schema_version": 9, "kind": "sequence",
                                     "clips": [{"id": "lav", "file": "lav.wav", "from": "0", "to": "18"}]})
    save_json(root / "truth.json", {"sampleRate": RATE, "duration": samples(DURATION), "tracks": TRACKS,
                                   "wordBounds": "Flite phoneme boundaries, reported to 1 ms",
                                   "phrases": phrases, "nonSpeech": [{"track": "close", "start": cough_start,
                                                                     "end": cough_start + len(cough)}],
                                   "clicks": {"priming-click.mov": 20000, "delayed-click.mov": 28000}})
    write_manifest(root, audio)
    write_parity_fixture(root)


def check_click(path, source_sample):
    """Check an extracted continuous WAV against the known source click."""
    with wave.open(str(path), "rb") as recording:
        assert (recording.getframerate(), recording.getnchannels(), recording.getsampwidth()) == (RATE, 1, 2)
        data = array("h", recording.readframes(recording.getnframes()))
    peak = max(range(len(data)), key=lambda index: abs(data[index]))
    assert abs(data[peak]) > 1000, f"{path}: no click found"
    assert abs(peak - source_sample) <= 1, f"{path}: click at {peak}, expected {source_sample}"
    return peak


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--flite", default="flite", help="path to Flite 2.2")
    parser.add_argument("--check-extracted-clicks", type=Path, metavar="DIRECTORY",
                        help="check an MPCut extraction WAV named for each click MOV")
    args = parser.parse_args()
    create(args.output, args.flite)
    truth = json.loads((args.output / "truth.json").read_text())
    for name, click in truth["clicks"].items():
        starts = probe(args.output / name, "-show_streams", "-select_streams", "a:0")["streams"]
        print(f"{name}: stream starts {starts[0]['start_time']}, click sample {click}")
        if args.check_extracted_clicks:
            path = args.check_extracted_clicks / Path(name).with_suffix(".wav")
            print(f"{path}: peak sample {check_click(path, click)}")


if __name__ == "__main__":
    main()
