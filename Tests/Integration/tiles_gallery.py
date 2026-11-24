#!/usr/bin/env python3
"""Score decoded Tiles CLI results against a deterministic 40-feed gallery."""

import argparse
from bisect import bisect_right
from collections import Counter, defaultdict
from fractions import Fraction
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

FPS = 12
CELL_WIDTH, CELL_HEIGHT, GUTTER = 64, 40, 6
BOX_KEYS = ("x", "y", "width", "height")
PHASES = [
    ("initial", list(range(25))),
    ("seat swaps", [(source + 7) % 25 for source in range(25)]),
    ("departures and entries", list(range(15, 40))),
    ("returns and departures", list(range(25))),
]
PHASE_FRAMES = 36
BOUNDARY_EVENTS = {
    PHASE_FRAMES: {"move": 25},
    2 * PHASE_FRAMES: {"move": 10, "leave": 15, "enter": 15},
    3 * PHASE_FRAMES: {"move": 10, "leave": 15, "enter": 15},
}


def box(cell, columns):
    return (cell % columns * CELL_WIDTH + GUTTER, cell // columns * CELL_HEIGHT + GUTTER,
            CELL_WIDTH - GUTTER, CELL_HEIGHT - GUTTER)


def pixels(columns, rows, feeds):
    """Port the source-local texture from TileTrail's tests/gallery.rs."""
    width, height = columns * CELL_WIDTH + GUTTER, rows * CELL_HEIGHT + GUTTER
    image = bytearray([18]) * (width * height * 3)
    for cell, feed in enumerate(feeds):
        x0, y0, w, h = box(cell, columns)
        if feed is None:
            # A camera-off card stays visibly distinct from the gutter.
            for y in range(h):
                offset = ((y0 + y) * width + x0) * 3
                image[offset:offset + w * 3] = bytes([47, 47, 47]) * w
            continue
        for y in range(h):
            for x in range(w):
                block = y * 4 // h * 4 + x * 4 // w
                shift = block * 7 % 32
                seed = (feed + 3) * 0x9e3779b9 & 0xffffffff
                seed = ((seed << shift) | (seed >> (32 - shift))) & 0xffffffff
                seed ^= block * 0x85ebca6b & 0xffffffff
                offset = ((y0 + y) * width + x0 + x) * 3
                image[offset:offset + 3] = bytes(52 + (seed >> (8 * channel) & 0x9f) for channel in range(3))
    return image


def record(ffmpeg, path, columns, rows, phases, phase_frames):
    width, height = columns * CELL_WIDTH + GUTTER, rows * CELL_HEIGHT + GUTTER
    # Preserve the RGB regression texture through decode. Fixed one-second closed
    # GOPs make stable ranges eligible for adaptive sampling.
    raw = b"".join(pixels(columns, rows, feeds) * phase_frames for _, feeds in phases)
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo",
                    "-pixel_format", "rgb24", "-video_size", f"{width}x{height}",
                    "-framerate", str(FPS), "-i", "-", "-c:v", "libx264rgb", "-crf", "0",
                    "-pix_fmt", "rgb24", "-threads", "1", "-g", str(FPS),
                    "-keyint_min", str(FPS), "-sc_threshold", "0", "-bf", "0", str(path)],
                   input=raw, check=True, timeout=120)
    return width, height


def tiles(cli, *args, status=0):
    completed = subprocess.run([str(cli), "tiles", *map(str, args), "--json"],
                               capture_output=True, text=True, timeout=180)
    if completed.returncode != status:
        raise AssertionError((args, completed.returncode, completed.stdout, completed.stderr))
    return json.loads(completed.stdout)


def scan(cli, recording, output, sampling, layout, size, expected=None):
    options = ["--expected-feeds", expected] if expected is not None else []
    return tiles(cli, "scan", recording, "--backend", "cpu-only", "--sampling", sampling,
                 layout, size, "--no-sidecar", "--output", output, *options)


def accept(cli, recording, output, duration):
    base = output.with_name(f"{output.stem}-sequence.cut")
    base.write_text(json.dumps({"format": "mpcut", "schema_version": 4, "kind": "sequence",
                                "clips": [{"id": "gallery", "file": str(recording),
                                           "from": "0", "to": str(duration)}]}))
    reviewed = output.with_suffix(".cut")
    tiles(cli, "accept", base, "--scan", output, "--out-project", reviewed)
    return reviewed


def tick(stamp):
    if not isinstance(stamp, dict):
        return Fraction(stamp) * FPS
    if "time_base" in stamp:
        base = stamp["time_base"]
        return Fraction(stamp["pts"] * FPS * base["numerator"], base["denominator"])
    return Fraction(stamp["numerator"] * FPS, stamp["denominator"])


def iou(a, b):
    x, y, w, h = a
    u, v, s, t = b
    overlap = max(0, min(x + w, u + s) - max(x, u)) * max(0, min(y + h, v + t) - max(y, v))
    return overlap / (w * h + s * t - overlap)


def identity_assignment(weights, predicted, actual):
    """Maximum-weight assignment using the Hungarian algorithm and zero-weight padding."""
    rows, cols = sorted(predicted), sorted(actual)
    size = max(len(rows), len(cols))
    rows += [None] * (size - len(rows))
    cols += [None] * (size - len(cols))
    row_potential, col_potential = [0] * (size + 1), [0] * (size + 1)
    owner, predecessor = [0] * (size + 1), [0] * (size + 1)
    for row in range(1, size + 1):
        owner[0] = row
        col = 0
        slack = [float("inf")] * (size + 1)
        visited = set()
        while True:
            visited.add(col)
            current = owner[col]
            for target in range(1, size + 1):
                if target in visited:
                    continue
                cost = -weights[rows[current - 1], cols[target - 1]]
                cost -= row_potential[current] + col_potential[target]
                if cost < slack[target]:
                    slack[target], predecessor[target] = cost, col
            closest = min((target for target in range(1, size + 1) if target not in visited),
                          key=slack.__getitem__)
            shift = slack[closest]
            for target in range(size + 1):
                if target in visited:
                    row_potential[owner[target]] += shift
                    col_potential[target] -= shift
                else:
                    slack[target] -= shift
            col = closest
            if owner[col] == 0:
                break
        while col:
            previous = predecessor[col]
            owner[col] = owner[previous]
            col = previous
    return {rows[owner[col] - 1]: cols[col - 1] for col in range(1, size + 1)
            if rows[owner[col] - 1] is not None}


def issue_covers(issue, appearance, frame):
    span = issue.get("range")
    return (issue["kind"] in {"ambiguous_match", "unassigned_tile"}
            and issue.get("tile_id") == str(appearance)
            and issue.get("source_time") is not None and tick(issue["source_time"]) <= frame
            and (tick(span["from"]) <= frame < tick(span["to"]) if span
                 else tick(issue["source_time"]) == frame))


def score(analysis, issues, width, height, columns, phases, phase_frames):
    observations = analysis["observations"]
    timestamps = [tick(observation["timestamp"]) for observation in observations]
    total_frames = len(phases) * phase_frames
    if (timestamps != sorted(set(timestamps))
            or any(frame.denominator != 1 or not 0 <= frame < total_frames for frame in timestamps)):
        raise AssertionError(f"Unexpected presentation timestamps: {timestamps}")
    end = tick(analysis["end"])
    ends = {appearance["id"]: tick(appearance["end"]) for appearance in analysis["appearances"]}
    weights, phases_counts, comparisons = Counter(), defaultdict(Counter), []
    seen, previous = set(), set()
    unresolved_starts, unreported = {}, []
    scale = (width, height, width, height)
    for frame in range(total_frames):
        phase, feeds = phases[frame // phase_frames]
        # Report each layout boundary and its two adjacent frames separately.
        transition = any(abs(frame - boundary) <= 1 for boundary in range(phase_frames, total_frames, phase_frames))
        counts = phases_counts["transition" if transition else "steady"]
        counts["truth"] += len(feeds)
        targets = [tuple(value / extent for value, extent in zip(box(cell, columns), scale))
                   for cell in range(len(feeds))]
        observed = bisect_right(timestamps, frame) - 1
        regions = observations[observed]["regions"] if observed >= 0 else []
        matched, unresolved = set(), set()
        for region in regions:
            appearance = region["appearance_id"]
            if frame >= min(ends.get(appearance, total_frames), end):
                continue
            counts["predicted"] += 1
            rect = tuple(region["rect"][key] for key in BOX_KEYS)
            # Disjoint truth boxes and an IoU threshold above 0.5 allow at most
            # one eligible truth box per prediction. Each truth box counts once.
            target = next((index for index, expected in enumerate(targets) if iou(rect, expected) >= 0.75), None)
            if target is None or target in matched:
                counts["false"] += 1
                continue
            matched.add(target)
            counts["matched"] += 1
            identity, feed = region.get("participant_id"), feeds[target]
            uncertain = region["identity_uncertain"] or any(
                candidate["participant_id"] != identity for candidate in region["possible_matches"])
            if uncertain or identity is None:
                counts["unresolved"] += 1
                unresolved.add(appearance)
                if appearance not in unresolved_starts and not any(issue_covers(issue, appearance, frame) for issue in issues):
                    unreported.append({"frame": frame, "phase": phase, "tile_id": appearance, "source": feed})
                unresolved_starts.setdefault(appearance, frame)
            else:
                weights[identity, feed] += 1
                comparisons.append((counts, identity, feed))
        counts["missed"] += len(feeds) - len(matched)
        unresolved_starts = {appearance: unresolved_starts[appearance] for appearance in unresolved}
        if frame:
            current = set(feeds)
            counts["departures"] += len(previous - current)
            counts["returns"] += len((current - previous) & seen)
        seen.update(feeds)
        previous = set(feeds)
    mapping = identity_assignment(weights, {identity for identity, _ in weights}, seen)
    last_identity = {}
    for counts, identity, feed in comparisons:
        counts["wrong_identity"] += mapping[identity] != feed
        counts["identity_switches"] += feed in last_identity and last_identity[feed] != identity
        last_identity[feed] = identity
    totals = sum(phases_counts.values(), Counter())
    result = {key: totals[key] for key in ("truth", "predicted", "matched", "missed", "false",
                                           "unresolved", "wrong_identity", "identity_switches",
                                           "departures", "returns")}
    result.update(observations=len(observations), tracks=len(analysis["tracks"]),
                  coverage=sorted({item["status"] for item in analysis["coverage"]}),
                  unreported_unresolved=unreported, windows=dict(phases_counts))
    return result


def ambiguous_return(cli, ffmpeg, folder):
    phases = [("original feed", list(range(25))),
              ("camera off", [None, *range(1, 25)]),
              ("different feed at the same seat", [39, *range(1, 25)])]
    recording, output = folder / "ambiguous.mp4", folder / "ambiguous.json"
    width, height = record(ffmpeg, recording, 5, 5, phases, FPS)
    scan(cli, recording, output, "every-frame", "--gallery-grid", "5x5")
    issues = tiles(cli, "inspect", output, "--issues")["issues"]
    analysis = json.loads(output.read_text())["analysis"]
    target = tuple(value / extent for value, extent in zip(box(0, 5), (width, height, width, height)))
    timeline = {tick(frame["timestamp"]): frame["regions"] for frame in analysis["observations"]}

    def first_cell(frame):
        return next(region for region in timeline[frame]
                    if iou(tuple(region["rect"][key] for key in BOX_KEYS), target) >= 0.75)

    off = first_cell(FPS)
    returned = first_cell(2 * FPS)
    reviewed = accept(cli, recording, output, len(phases))
    saved_issues = tiles(cli, "inspect", reviewed, "--issues")["issues"]
    # Every feed decision for the returning tile is one group, and one link of
    # the whole tile settles all of it.
    suffix = f"-appearance-{returned['appearance_id']}"
    decisions = [issue for issue in saved_issues if issue["kind"] in {"ambiguous_match", "unassigned_tile"}
                 and (issue.get("tile_id") or "").endswith(suffix)]
    groups = {issue.get("group_id") for issue in decisions}
    tile_id = decisions[0]["tile_id"] if decisions else None
    feed = next((issue.get("feed_id") or (issue.get("candidate_feed_ids") or [None])[0]
                 for issue in decisions if issue.get("feed_id") or issue.get("candidate_feed_ids")), None)
    own = next((issue.get("feed_id") for issue in decisions if issue.get("feed_id")), None)
    rival = next((candidate for issue in decisions for candidate in issue.get("candidate_feed_ids") or []
                  if candidate != own), None)
    left = same_left = None

    def remaining(project):
        # Feed decisions left on the tile, or a feed left without its tiles.
        return [issue for issue in tiles(cli, "inspect", project, "--issues")["issues"]
                if issue["kind"] in {"ambiguous_match", "unassigned_tile"}
                and (issue.get("tile_id") == tile_id or issue.get("feed_id") in {own, rival} and not issue.get("tile_id"))]

    if tile_id and feed:
        # Different Feed: keep the scan's own feed for the whole tile.
        settled = reviewed.with_name("ambiguous-settled.cut")
        tiles(cli, "link", "--project", reviewed, "--tile-id", tile_id, "--feed-id", feed, "--out-project", settled)
        left = remaining(settled)
    if tile_id and own and rival:
        # Same Feed: fold the own feed into the earlier one, then link the whole tile.
        same = reviewed.with_name("ambiguous-same.cut")
        tiles(cli, "feeds", "merge", "--project", reviewed, "--feed-id", own, "--into-feed-id", rival,
              "--out-project", same)
        tiles(cli, "link", "--project", same, "--tile-id", tile_id, "--feed-id", rival, "--in-place")
        same_left = remaining(same)
    return {
        "decision_issues": len(decisions),
        "decision_groups": sorted(map(str, groups)),
        "group_counts_match": all(issue.get("group_count") == len(decisions) for issue in decisions),
        "issues_left_after_one_link": left,
        "feed_issues_left_after_same_feed": same_left,
        "camera_off_classified": off["kind"] == "camera_off",
        "return_uncertain": returned["identity_uncertain"],
        "dated_return_issues": [issue for issue in issues
                                if issue_covers(issue, returned["appearance_id"], 2 * FPS)
                                and tick(issue["source_time"]) == 2 * FPS],
        "saved_issue_kinds_at_return": sorted({
            issue["kind"] for issue in saved_issues
            if (issue.get("tile_id") or "").endswith(f"-appearance-{returned['appearance_id']}")
            and issue.get("source_time") is not None and tick(issue["source_time"]) == 2 * FPS
        }),
    }


def capacity_report(cli, recording, output):
    analysis = json.loads(output.read_text())["analysis"]
    raw = tiles(cli, "inspect", output, "--issues")["issues"]
    reviewed = accept(cli, recording, output, 1)
    saved = tiles(cli, "inspect", reviewed, "--issues")["issues"]
    return {
        "observations": len(analysis["observations"]),
        "overflow_observations": sum(bool(frame.get("layout_capacity_exceeded"))
                                     for frame in analysis["observations"]),
        "visible_boxes": sum(len(frame["regions"]) for frame in analysis["observations"]),
        "coverage": [span["status"] for span in analysis["coverage"]],
        "raw_issues": [item for item in raw if item["id"] == "layout-capacity-0"],
        "accepted_issues": [item for item in saved if item["id"] == "layout-capacity-0"],
    }


def capacity_verified(report):
    raw = report["raw_issues"]
    return (report["observations"] == report["overflow_observations"] == FPS
            and report["visible_boxes"] == 0 and report["coverage"] == ["unknown"]
            and len(raw) == 1 and raw == report["accepted_issues"]
            and raw[0]["kind"] == "count_mismatch" and "64" in raw[0]["message"]
            and tick(raw[0]["source_time"]) == 0 and tick(raw[0]["range"]["to"]) == FPS)


def run(cli, ffmpeg, folder, tiletrail=None):
    recording = folder / "gallery.mp4"
    width, height = record(ffmpeg, recording, 5, 5, PHASES, PHASE_FRAMES)
    report, failures = {}, []
    for sampling in ("adaptive", "every-frame"):
        output = folder / f"{sampling}.json"
        summary = scan(cli, recording, output, sampling, "--gallery-grid", "5x5", 40)
        inspection = tiles(cli, "inspect", output, "--issues")
        issues = inspection["issues"]
        analysis = json.loads(output.read_text())["analysis"]
        result = score(analysis, issues, width, height, 5, PHASES, PHASE_FRAMES)
        reviewed = accept(cli, recording, output, len(PHASES) * PHASE_FRAMES // FPS)
        review = tiles(cli, "feeds", "list", reviewed)
        result["review_counts"] = review["counts"]
        result["reviewed_feed_ids"] = len({feed["feed_id"] for feed in review["feeds"]})
        result["issue_counts"] = Counter(issue["kind"] for issue in issues)
        boundary_events = {
            frame: Counter(event["kind"] for event in analysis["events"]
                           if tick(event["timestamp"]) == frame and not event["uncertain"])
            for frame in BOUNDARY_EVENTS
        }
        result["boundary_events"] = boundary_events
        if boundary_events != BOUNDARY_EVENTS:
            failures.append(f"{sampling}: missing or incorrect dated layout events")
        if "issues" in summary:
            result["scan_issue_counts"] = Counter(issue.get("kind", issue.get("code")) for issue in summary["issues"])
        report[sampling] = result
        limits = {"missed": (result["truth"], 0.01), "false": (result["predicted"], 0.01),
                  "wrong_identity": (result["matched"], 0.005)}
        for key, (denominator, threshold) in limits.items():
            if result[key] > denominator * threshold:
                failures.append(f"{sampling}: {key} {result[key]}/{denominator} exceeds {threshold:.1%}")
        if (result["review_counts"] != {"feed_count": 40, "max_visible_tiles": 25}
                or result["reviewed_feed_ids"] != 40):
            failures.append(f"{sampling}: unexpected review counts")
        if result["unreported_unresolved"]:
            failures.append(f"{sampling}: unresolved identity without a dated issue")
        if sampling == "adaptive" and "inferred" not in result["coverage"]:
            failures.append("adaptive: fixture did not exercise inferred coverage")
        if sampling == "every-frame" and (result["observations"] != len(PHASES) * PHASE_FRAMES
                                         or result["coverage"] != ["observed"]):
            failures.append("every-frame: fixture did not verify every presentation frame")

    fixed_phases = [("fixed limit", list(range(64)))]
    fixed_recording = folder / "fixed.mp4"
    record(ffmpeg, fixed_recording, 8, 8, fixed_phases, FPS)
    fixed_output = folder / "fixed.json"
    summary = tiles(cli, "scan", fixed_recording, "--backend", "cpu-only", "--sampling", "every-frame",
                    "--feed-layout", "8x8", "--max-visible-tiles", "63", "--no-sidecar", "--output", fixed_output)
    analysis = json.loads(fixed_output.read_text())["analysis"]
    # Fixed-switcher cells own the full rectangle, including the rendered gutters.
    report["fixed-limit"] = {
        "tracks": len(analysis["tracks"]),
        "tiles_per_frame": sorted({len(frame["regions"]) for frame in analysis["observations"]}),
        "count_issues": [issue for issue in summary.get("issues", []) if issue.get("kind") == "count_mismatch"],
    }
    fixed = report["fixed-limit"]
    expected_cells = {(col / 8, row / 8, 1 / 8, 1 / 8) for row in range(8) for col in range(8)}
    if (fixed["tracks"] != 64 or fixed["tiles_per_frame"] != [64]
            or [tick(frame["timestamp"]) for frame in analysis["observations"]] != list(range(FPS))
            or any({tuple(region["rect"][key] for key in BOX_KEYS) for region in frame["regions"]} != expected_cells
                   for frame in analysis["observations"])):
        failures.append("fixed limit: failed to retain all 64 distinct cells")
    if not any(issue.get("source_time") is not None and tick(issue["source_time"]) == 0
               and issue.get("range") and tick(issue["range"]["to"]) == FPS for issue in fixed["count_issues"]):
        failures.append("fixed limit: missing dated maximum-tile diagnostic")
    report["over-limit"] = tiles(cli, "scan", fixed_recording, "--feed-layout", "9x8",
                                 "--no-sidecar", status=2)["error"]
    if "64" not in report["over-limit"]["message"]:
        failures.append("over-limit: expected the diagnostic to name the cell limit")
    overflow_recording = folder / "overflow.mp4"
    record(ffmpeg, overflow_recording, 9, 8, [("above capacity", list(range(72)))], FPS)
    overflow_output = folder / "automatic-overflow.json"
    scan(cli, overflow_recording, overflow_output, "every-frame", "--feed-layout", "auto")
    report["automatic-overflow"] = capacity_report(cli, overflow_recording, overflow_output)
    if not capacity_verified(report["automatic-overflow"]):
        failures.append("automatic overflow: expected a dated limit issue without verified geometry")
    if tiletrail is not None:
        standalone = folder / "standalone-overflow.json"
        subprocess.run([tiletrail, "scan", overflow_recording, "--feed-layout", "auto",
                        "--output", standalone], check=True, timeout=180)
        report["standalone-overflow"] = capacity_report(cli, overflow_recording, standalone)
        if not capacity_verified(report["standalone-overflow"]):
            failures.append("standalone overflow: imported project lost detector uncertainty")
    report["ambiguous-return"] = ambiguous_return(cli, ffmpeg, folder)
    ambiguity = report["ambiguous-return"]
    if (not ambiguity["camera_off_classified"] or not ambiguity["return_uncertain"]
            or not any(issue["kind"] == "ambiguous_match" for issue in ambiguity["dated_return_issues"])
            or "ambiguous_match" not in ambiguity["saved_issue_kinds_at_return"]):
        failures.append("ambiguous return: expected a dated match issue at the replacement frame")
    if (len(ambiguity["decision_groups"]) != 1 or "None" in ambiguity["decision_groups"]
            or not ambiguity["group_counts_match"] or ambiguity["issues_left_after_one_link"] != []):
        failures.append("ambiguous return: expected one feed-decision group that one whole-tile link settles")
    if ambiguity["feed_issues_left_after_same_feed"] != []:
        failures.append("ambiguous return: expected a merge and one whole-tile link to settle the group as the same feed")
    return report, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", type=Path)
    parser.add_argument("--ffmpeg", type=Path, default=shutil.which("ffmpeg"),
                        help="FFmpeg with the libx264rgb encoder (default: search PATH)")
    parser.add_argument("--artifacts", type=Path, help="Keep recordings and scan JSON in this directory")
    parser.add_argument("--tiletrail", type=Path, help="Also import an independent TileTrail scan")
    args = parser.parse_args()
    if args.ffmpeg is None:
        parser.error("FFmpeg with libx264rgb is required")
    if args.artifacts:
        args.artifacts.mkdir(parents=True, exist_ok=True)
        directory = Path(tempfile.mkdtemp(prefix="mpcut-gallery-", dir=args.artifacts.resolve()))
        report, failures = run(args.cli.resolve(), args.ffmpeg.resolve(), directory, args.tiletrail)
        report["artifacts"] = str(directory)
    else:
        with tempfile.TemporaryDirectory(prefix="mpcut-gallery-") as directory:
            report, failures = run(args.cli.resolve(), args.ffmpeg.resolve(), Path(directory), args.tiletrail)
    print(json.dumps(dict(report, failures=failures), indent=2))
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
