#!/usr/bin/env python3
"""A recording whose edit ends on its last stored sample scans to completion.

Some exports store one more sample than they present: the edit list ends on that sample's
timestamp, the demuxer marks it for discard and the decoder never shows it. The scan reads
every presented picture, so it completes, and the sample's width is unknown coverage.

usage: tiles_edit_tail.py /path/to/mpcut [--ffmpeg ffmpeg]
"""

import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def recording(ffmpeg, folder):
    full = folder / "full.mp4"
    subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=6",
                    "-c:v", "libx264", "-bf", "0", "-g", "25", "-pix_fmt", "yuv420p", str(full)], check=True)
    data = bytearray(full.read_bytes())
    at = data.find(b"elst")
    assert at > 0 and data[at + 4] == 0 and struct.unpack(">I", data[at + 8:at + 12])[0] == 1, "one version 0 edit"
    duration = struct.unpack(">I", data[at + 12:at + 16])[0]
    assert duration == 6000, duration  # movie timescale 1000
    # End the edit one 40 ms frame early: the last sample is stored and never presented.
    data[at + 12:at + 16] = struct.pack(">I", duration - 40)
    trimmed = folder / "trailing.mp4"
    trimmed.write_bytes(data)
    return trimmed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mpcut-edit-tail.") as temporary:
        folder = Path(temporary)
        media = recording(args.ffmpeg, folder)
        for sampling in ("adaptive", "every-frame", "sparse"):
            output = folder / f"{sampling}.json"
            result = subprocess.run([str(args.mpcut), "tiles", "scan", str(media), "--no-sidecar", "--feed-layout", "2x2",
                                     "--sampling", sampling, "--output", str(output), "--json"],
                                    capture_output=True, text=True, timeout=120)
            assert result.returncode == 0, (sampling, result.stdout, result.stderr)
            summary = json.loads(result.stdout)
            assert summary["state"] == "completed", (sampling, summary)
            tail = summary["coverage"][-1]
            assert tail == {"range": {"from": "149/25", "to": "6"}, "state": "unknown"}, (sampling, tail)
            assert all(part["state"] != "unknown" for part in summary["coverage"][:-1]), (sampling, summary["coverage"])
            report = json.loads(output.read_text())
            last = report["analysis"]["observations"][-1]["timestamp"]
            assert last["numerator"] * 25 <= 148 * last["denominator"], (sampling, last)
        project = folder / "base.cut"
        created = subprocess.run([str(args.mpcut), "project", "create", "--stdin", "--json"], input=json.dumps({
            "kind": "sequence", "out_project": str(project),
            "operations": [{"action": "append", "id": "call", "file": str(media), "from": "0", "to": "5"}],
        }), capture_output=True, text=True, timeout=60)
        assert created.returncode == 0, (created.stdout, created.stderr)
        accepted = subprocess.run([str(args.mpcut), "tiles", "accept", "--project", str(project), "--scan",
                                   str(folder / "adaptive.json"), "--out-project", str(folder / "reviewed.cut"), "--json"],
                                  capture_output=True, text=True, timeout=60)
        assert accepted.returncode == 0 and json.loads(accepted.stdout).get("ok"), (accepted.stdout, accepted.stderr)
    print("tiles_edit_tail: ok")


if __name__ == "__main__":
    main()
