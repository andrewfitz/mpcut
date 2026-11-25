#!/usr/bin/env python3
"""Compare whole and time-range LZFSE blocks over actual peak samples and tile observations."""

import argparse
import bisect
import ctypes
from fractions import Fraction
import json
from pathlib import Path
import plistlib
import sqlite3
import statistics
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Integration"))
from sidecar_payload import section_bytes


def lzfse_function(name):
    function = getattr(ctypes.CDLL("/usr/lib/libcompression.dylib"), name)
    function.argtypes = (ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
                         ctypes.c_void_p, ctypes.c_int)
    function.restype = ctypes.c_size_t
    return function


encode = lzfse_function("compression_encode_buffer")
decode = lzfse_function("compression_decode_buffer")


def pack(raw):
    output = ctypes.create_string_buffer(len(raw))
    written = encode(output, len(raw), raw, len(raw), None, 0x801)
    return (len(raw), output.raw[:written]) if 0 < written < len(raw) else (0, raw)


def unpack(size, data):
    if not size:
        return data
    output = ctypes.create_string_buffer(size)
    if decode(output, size, data, len(data), None, 0x801) != size:
        raise ValueError("LZFSE did not reproduce the expected block length")
    return output.raw


def compare(rows, ticks, window, block, directory, runs):
    if not rows or len(rows) != len(ticks) or ticks != sorted(ticks):
        raise ValueError("Expected nonempty source-time ordered samples")
    # A block starts on a row. The paired row offsets model a time index that the
    # consumer has already loaded; timings include the payload lookup and decode.
    starts = [0]
    for i, tick in enumerate(ticks):
        if tick >= ticks[starts[-1]] + block:
            starts.append(i)
    midpoint = (ticks[0] + ticks[-1]) / 2
    left = bisect.bisect_left(ticks, midpoint)
    right = max(left + 1, bisect.bisect_left(ticks, midpoint + window))
    byte_offsets = [0]
    for row in rows:
        byte_offsets.append(byte_offsets[-1] + len(row))
    results = {}
    for mode, indices in (("whole", [0]), ("ranged", starts)):
        path = directory / (mode + ".sqlite")
        with sqlite3.connect(path) as db:
            started = time.perf_counter()
            db.execute("CREATE TABLE blocks(first_row INTEGER PRIMARY KEY, size INTEGER, payload BLOB)")
            for first, end in zip(indices, indices[1:] + [len(rows)]):
                size, packed = pack(b"".join(rows[first:end]))
                db.execute("INSERT INTO blocks VALUES(?,?,?)", (first, size, packed))
            db.commit()
            write_time = time.perf_counter() - started
            records = db.execute("SELECT size,payload FROM blocks ORDER BY first_row")
            if b"".join(unpack(n, p) for n, p in records) != b"".join(rows):
                raise ValueError("Full scan does not reproduce source bytes")
            timings = []
            first_row = indices[bisect.bisect_right(indices, left) - 1]
            expected = b"".join(rows[left:right])
            decoded_size = 0
            for _ in range(runs + 1):
                started = time.perf_counter()
                records = db.execute("SELECT size,payload FROM blocks "
                                     "WHERE first_row >= ? AND first_row < ? ORDER BY first_row", (first_row, right))
                data = b"".join(unpack(n, p) for n, p in records)
                view = data[byte_offsets[left] - byte_offsets[first_row]:byte_offsets[right] - byte_offsets[first_row]]
                timings.append(time.perf_counter() - started)
                if view != expected:
                    raise ValueError("Time range does not reproduce source bytes")
                decoded_size = len(data)
            results[mode] = {"blocks": len(indices), "databaseBytes": path.stat().st_size,
                             "buildSeconds": round(write_time, 6), "rangeDecodedBytes": decoded_size,
                             "medianRangeMilliseconds": round(1000 * statistics.median(timings[1:]), 4)}
    return {"rows": len(rows), "logicalBytes": byte_offsets[-1], "selectedRows": right - left, **results}


def fraction(value):
    if isinstance(value, dict):
        return Fraction(value["numerator"], value["denominator"])
    return Fraction(value)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--waveform-cache", type=Path, help="database containing waveform_peaks.v1.STREAM")
    source.add_argument("--tile-scan", type=Path, help="completed Tiles scan JSON")
    parser.add_argument("--stream", type=int, default=0)
    parser.add_argument("--window", type=Fraction, default=Fraction(1, 10))
    parser.add_argument("--block", type=Fraction, default=Fraction(4))
    parser.add_argument("--runs", type=int, default=9)
    args = parser.parse_args()
    if args.window <= 0 or args.block <= 0 or args.runs < 1:
        parser.error("--window, --block and --runs must be positive")
    if args.waveform_cache:
        with sqlite3.connect(args.waveform_cache.resolve().as_uri() + "?mode=ro", uri=True) as db:
            info = plistlib.loads(section_bytes(db, f"waveform_peaks.v1.{args.stream}"))
        peak_data = info["value"]
        if len(peak_data) % 4:
            raise ValueError("Expected Float32 peaks")
        rows = [peak_data[i:i+4] for i in range(0, len(peak_data), 4)]
        # Waveform peaks use a 20 ms bin, including a possible short final bin.
        ticks = [Fraction(i, 50) for i in range(len(rows))]
    else:
        observations = json.loads(args.tile_scan.read_bytes())["analysis"]["observations"]
        ticks = [fraction(row["timestamp"]) for row in observations]
        rows = [(json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n").encode() for row in observations]
    with tempfile.TemporaryDirectory(prefix="mpcut-range-benchmark-") as scratch:
        result = compare(rows, ticks, args.window, args.block, Path(scratch), args.runs)
    print(json.dumps(result, indent=2))
