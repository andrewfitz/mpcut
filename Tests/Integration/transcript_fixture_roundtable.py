#!/usr/bin/env python3
"""Generate a three-speaker, four-source multicam conversation with macOS voices.

    python3 Tests/Integration/transcript_fixture_roundtable.py OUTPUT_DIR [WIDE_OFFSET]

Host and Guest wear lavs. A producer speaks from behind the cameras and is heard
only on the two camera mixes, at spill level on both lavs, and interrupts the
Guest once. The sources use different sample rates, codecs and signed offsets.
truth.json gives each utterance's speaker, text and bounds on the group clock in
seconds. Pass a WIDE_OFFSET such as -12/25 to start the group on a picture frame
of the reference camera. Needs FFmpeg with libx264 and the macOS `say` voices
Samantha, Daniel and Karen.
"""
import json
import subprocess
import sys
import wave
from array import array
from pathlib import Path

RATE = 48000
VOICES = {"Host": "Samantha", "Guest": "Daniel", "Producer": "Karen"}
# (id, speaker, text, placement). Placement None = after previous + gap; ("during", id, seconds) = overlap.
LINES = [
    ("welcome", "Host", "Welcome back to the workshop. Today we are talking about restoring old film cameras.", None),
    ("thanks", "Guest", "Thanks for having me. I brought a rangefinder that was stuck for decades.", None),
    ("ask-first", "Host", "So what was the first thing you checked?", None),
    ("shutter", "Guest", "Um, the first thing I check is always the shutter, you know, because that is where the dust collects.", None),
    ("interject", "Producer", "Sorry, one moment please.", ("during", "shutter", 2.2)),
    ("take1", "Guest", "The shutter curtain was torn, so I replaced it with silk from Japan.", None),
    ("slower", "Host", "Could you say that again a little slower?", None),
    ("take2", "Guest", "The shutter curtain was torn, so I replaced it with new silk from Kyoto.", None),
    ("verdict", "Producer", "That was a great take. Let us keep the second one.", None),
    ("how-long", "Host", "Wonderful. And how long did the whole repair take?", None),
    ("weekends", "Guest", "About three weekends, mostly waiting for the glue to dry.", None),
    ("goodbye", "Host", "Thank you so much for joining us.", None),
]
GAP = 0.7
WIDE_OFFSET = sys.argv[2] if len(sys.argv) > 2 else "-1/2"
# Linear gain of each speaker on each track; offset is the .cut sync offset (source = group - offset).
TRACKS = {
    "host-lav": {"file": "host-lav.wav", "offset": "0", "gains": {"Host": 1.0, "Guest": 0.07, "Producer": 0.03},
                 "role": "isolated_mic", "speaker": "Host"},
    "guest-lav": {"file": "guest-lav.wav", "offset": "1/4", "gains": {"Guest": 1.0, "Host": 0.08, "Producer": 0.04},
                  "role": "isolated_mic", "speaker": "Guest"},
    "wide": {"file": "wide.mov", "offset": WIDE_OFFSET, "gains": {"Host": 0.55, "Guest": 0.55, "Producer": 0.9},
             "role": "mixed_audio"},
    "close": {"file": "close.mp4", "offset": "6/5", "gains": {"Guest": 0.8, "Host": 0.3, "Producer": 0.5},
              "role": "mixed_audio"},
}


def run(*args):
    subprocess.run([str(a) for a in args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def bounds(path):
    with wave.open(str(path)) as wav:
        samples = array("h", wav.readframes(wav.getnframes()))
    loud = [i for i, s in enumerate(samples) if abs(s) > 300]
    return loud[0] / RATE, (loud[-1] + 1) / RATE, len(samples) / RATE


def frac(text):
    from fractions import Fraction
    return Fraction(text)


def main(out):
    out.mkdir(parents=True, exist_ok=True)
    tmp = out / "stems"
    tmp.mkdir(exist_ok=True)
    placed = {}
    cursor = 1.0
    truth = []
    for ident, speaker, text, where in LINES:
        clip = tmp / f"{ident}.wav"
        run("say", "-v", VOICES[speaker], "-o", clip, f"--data-format=LEI16@{RATE}", text)
        lead, tail, length = bounds(clip)
        if where:
            start = placed[where[1]] + where[2]
        else:
            start = cursor
            cursor = start + length + GAP
        placed[ident] = start
        truth.append({"id": ident, "speaker": speaker, "text": text, "start": round(start + lead, 4),
                      "end": round(start + tail, 4), "clipStart": round(start, 4), "overlaps": bool(where)})
    duration = round(cursor + 1.0, 3)
    stems = {}
    for speaker in VOICES:
        mine = [(i, placed[i]) for i, s, _, _ in LINES if s == speaker]
        cmd = ["ffmpeg", "-y"]
        for ident, _ in mine:
            cmd += ["-i", tmp / f"{ident}.wav"]
        graph = ";".join(f"[{n}:a]adelay={round(start * 1000)}:all=1[d{n}]" for n, (_, start) in enumerate(mine))
        graph += ";" + "".join(f"[d{n}]" for n in range(len(mine)))
        graph += f"amix=inputs={len(mine)}:normalize=0,apad,atrim=end={duration}[out]"
        stem = tmp / f"stem-{speaker}.wav"
        run(*cmd, "-filter_complex", graph, "-map", "[out]", "-ar", RATE, "-ac", 1, stem)
        stems[speaker] = stem
    speakers = list(VOICES)
    for name, track in TRACKS.items():
        offset = float(frac(track["offset"]))
        mix = ";".join(f"[{n}:a]volume={track['gains'][s]}[g{n}]" for n, s in enumerate(speakers))
        mix += ";" + "".join(f"[g{n}]" for n in range(len(speakers)))
        mix += f"[{len(speakers)}:a]amix=inputs={len(speakers) + 1}:normalize=0"
        # source = group - offset: a negative offset starts before group zero.
        mix += f",adelay={round(-offset * 1000)}:all=1" if offset < 0 else f",atrim=start={offset},asetpts=PTS-STARTPTS"
        mix += "[a]"
        inputs = ["ffmpeg", "-y"]
        for s in speakers:
            inputs += ["-i", stems[s]]
        inputs += ["-f", "lavfi", "-t", duration + 1, "-i", f"anoisesrc=color=pink:amplitude=0.004:sample_rate={RATE}:seed={len(name)}"]
        length = duration - offset
        target = out / track["file"]
        if name == "host-lav":
            run(*inputs, "-filter_complex", mix, "-map", "[a]", "-t", length, "-ar", 48000, "-ac", 1,
                "-c:a", "pcm_s24le", target)
        elif name == "guest-lav":
            run(*inputs, "-filter_complex", mix, "-map", "[a]", "-t", length, "-ar", 44100, "-ac", 1,
                "-c:a", "pcm_s16le", target)
        elif name == "wide":
            run(*inputs, "-f", "lavfi", "-t", length, "-i", "testsrc2=size=640x360:rate=25",
                "-filter_complex", mix, "-map", f"{len(speakers) + 1}:v", "-map", "[a]", "-t", length,
                "-c:v", "libx264", "-g", 25, "-bf", 2, "-pix_fmt", "yuv420p", "-preset", "veryfast",
                "-c:a", "aac", "-b:a", "128k", "-ar", 48000, "-ac", 2, target)
        else:
            run(*inputs, "-f", "lavfi", "-t", length, "-i", "smptebars=size=640x360:rate=25",
                "-filter_complex", mix, "-map", f"{len(speakers) + 1}:v", "-map", "[a]", "-t", length,
                "-c:v", "libx264", "-g", 25, "-bf", 0, "-pix_fmt", "yuv420p", "-preset", "veryfast",
                "-c:a", "aac", "-b:a", "96k", "-ar", 44100, "-ac", 1, target)
    project = {
        "format": "mpcut", "schema_version": 9, "kind": "multicam", "reference_angle_id": "wide",
        "group_range": {"from": "0", "to": str(int(duration))},
        "angles": [{"id": "wide", "file": "wide.mov", "offset": TRACKS["wide"]["offset"]},
                   {"id": "close", "file": "close.mp4", "offset": TRACKS["close"]["offset"]}],
        "audio_sources": [{"id": "host-lav", "file": "host-lav.wav", "offset": "0"},
                         {"id": "guest-lav", "file": "guest-lav.wav", "offset": "1/4"}],
        "audio": {"mode": "fixed", "source_id": "host-lav", "audio_stream_index": 0},
        "switches": [{"group_time": "0", "angle_id": "wide"}, {"group_time": "8", "angle_id": "close"}, {"group_time": "16", "angle_id": "wide"},
                     {"group_time": "30", "angle_id": "close"}, {"group_time": "42", "angle_id": "wide"}],
    }
    (out / "roundtable.cut").write_text(json.dumps(project, indent=2))
    (out / "truth.json").write_text(json.dumps(
        {"duration": duration, "tracks": {k: {x: v[x] for x in v if x != "gains"} | {"gains": v["gains"]}
                                          for k, v in TRACKS.items()}, "utterances": truth}, indent=2))
    print(json.dumps({"duration": duration, "utterances": len(truth)}))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
