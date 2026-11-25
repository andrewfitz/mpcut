#!/usr/bin/env python3
"""Check privacy and Flow layout when a participant appearance is unresolved."""

import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess

import participant_e2e as fixture
from participant_e2e_fixture import ffmpeg
from saved_project import read_project


def verify_rotated_vfr(harness):
    anamorphic = harness.folder / "anamorphic.mov"
    rotated = harness.folder / "rotated.mov"
    ffmpeg("-i", harness.gallery, "-vf", r"select=not(eq(n\,8)),setsar=4/3", "-fps_mode", "vfr",
           "-an", "-c:v", "prores_ks", "-pix_fmt", "yuv422p10le", anamorphic)
    ffmpeg("-display_rotation:v:0", "90", "-noautorotate", "-i", anamorphic, "-c", "copy", rotated)
    stream, = fixture.probe(rotated, "-select_streams", "v:0", "-show_streams")["streams"]
    harness.assertEqual((stream["width"], stream["height"], stream["sample_aspect_ratio"]), (320, 180, "4:3"))
    harness.assertEqual(stream["side_data_list"][0]["rotation"], 90)
    source_times = fixture.frame_times(rotated, stream)
    harness.assertEqual(source_times[7:9], [Fraction(7, 8), Fraction(9, 8)])

    end, switch = Fraction(31, 16), Fraction(9, 8)
    base = harness.base("rotated")
    project = read_project(base)
    project["angles"] = [{"id": "gallery", "file": str(rotated)}]
    project["audio"] = {"mode": "none"}
    project["group_range"] = fixture.interval(0, end)
    base.write_text(json.dumps(project))

    def appearance(participant, side, interval):
        # The right tile becomes the top tile in the displayed picture.
        y = 8 if side == "right" else 168
        return {"id": f"{participant}-{side}", "participant_id": participant, "range": interval,
                "role": "tile", "state": "video",
                "bounds": {"x": 30 / 180, "y": y / 320, "width": 120 / 180, "height": 144 / 320}}

    first, second = fixture.interval(0, switch), fixture.interval(switch, end)
    geometry = {"source_id": "gallery", "appearances": [appearance("guest", "right", first),
                appearance("host", "left", first), appearance("guest", "left", second),
                appearance("host", "right", second)],
                "coverage": [{"range": fixture.interval(0, end), "state": "verified"}]}
    approved = harness.approved(base, "rotated-approved", edited_geometry=geometry)
    render = fixture.plan("original", size=(180, 426), redactions=(
        {"participant_id": "guest", "treatment": "opaque", "color": fixture.color(fixture.COVER)},
    ))
    render["canvas"]["frame_rate"] = {"numerator": 24000, "denominator": 1001}
    output, report = harness.export(approved, "rotated-masked", render)
    harness.assertEqual(report["privacy_issues"], [])
    stream, frames = fixture.video(output)
    harness.assertEqual((stream["width"], stream["height"]), (180, 426))
    cadence = Fraction(1001, 24000)
    times = [i * cadence for i in range(len(frames))]
    harness.assertEqual(fixture.frame_times(output, stream), times)
    harness.assertLess(times[-1], end)
    harness.assertGreater(times[-1] + cadence, end)
    time_base = Fraction(stream["time_base"])
    harness.assertEqual(time_base * int(stream["duration_ts"]), end)
    packets = fixture.probe(output, "-select_streams", "v:0", "-show_packets")["packets"]
    harness.assertEqual(time_base * int(packets[-1]["duration"]), end - times[-1])
    for time, frame in zip(times, frames):
        guest_y, host_y = (107, 319) if time < switch else (319, 107)
        harness.assert_color(frame, 180, 90, guest_y, fixture.COVER, f"rotated guest at {time}")
        harness.assert_color(frame, 180, 90, host_y, fixture.HOST, f"rotated host at {time}")


def analysis_available(harness):
    """Whether this build links the detector, judged by scanning a recording with no rotation."""
    result = subprocess.run([str(fixture.CLI), "participants", "scan", "--file", str(harness.gallery),
                             "--backend", "cpu-only", "--sampling", "sparse", "--no-sidecar", "--json"],
                            capture_output=True, text=True, timeout=180)
    report = json.loads(result.stdout)
    if result.returncode == 0:
        return True
    harness.assertEqual(report["error"]["code"], "participant_analysis_unavailable", report)
    return False


def verify_bitstream_rotation_refuses_scanned_geometry(harness):
    source = harness.folder / "orientation-sei.mp4"
    ffmpeg("-i", harness.gallery, "-an", "-c:v", "libx264", "-g", "8", "-bf", "0",
           "-bsf:v", "h264_metadata=display_orientation=insert:rotate=90", source)
    stream, = fixture.probe(source, "-select_streams", "v:0", "-show_streams")["streams"]
    harness.assertFalse(stream.get("side_data_list"))
    first, = fixture.probe(source, "-read_intervals", "%+#1", "-select_streams", "v:0", "-show_frames")["frames"]
    harness.assertTrue(any(item.get("rotation") == 90 for item in first["side_data_list"]))
    base = harness.base("bitstream-rotation")
    project = read_project(base)
    project["angles"] = [{"id": "gallery", "file": str(source)}]
    project["audio"] = {"mode": "none"}
    base.write_text(json.dumps(project))

    geometry = fixture.geometry()
    geometry["analysis_identity"] = "scan-with-container-orientation"
    approved = harness.approved(base, "bitstream-approved", edited_geometry=geometry)
    render = fixture.plan("original", size=(180, 320), redactions=(
        {"participant_id": "guest", "treatment": "opaque", "color": fixture.color(fixture.COVER)},
    ))
    _, report = harness.export(approved, "bitstream-redaction", render, ok=False)
    harness.assertEqual(report["error"]["code"], "participant_display_transform_changed")
    report = harness.cli("participants", "scan", "--file", str(source), "--backend", "cpu-only",
                         "--sampling", "sparse", ok=False)
    # The detector library is optional. The scan finds the bitstream rotation only while decoding
    # for analysis, so a build without the library refuses every scan before reading a picture.
    # The output-side mismatch check above runs in either build.
    expected = "unsupported_display_transform" if analysis_available(harness) else "participant_analysis_unavailable"
    harness.assertEqual(report["error"]["code"], expected)

    geometry.pop("analysis_identity")
    for appearance in geometry["appearances"]:
        bounds = appearance["bounds"]
        appearance["bounds"] = {"x": bounds["y"], "y": max(0, 1 - bounds["x"] - bounds["width"]),
                                "width": bounds["height"], "height": bounds["width"]}
    manually_corrected = harness.approved(base, "bitstream-manual", edited_geometry=geometry)
    output, _ = harness.export(manually_corrected, "bitstream-manual-output", render)
    frame = harness.decode(output, size=(180, 320))[0]
    harness.assert_color(frame, 180, 45, 85, fixture.COVER, "rotated guest with manual bounds")
    harness.assert_color(frame, 180, 90, 235, fixture.HOST, "rotated host with manual bounds")


def verify_native_treatment_and_confirmation(harness):
    geometry = fixture.geometry()
    geometry["coverage"] = [{"range": fixture.interval(0, 5), "state": "inferred"}]
    project = harness.approved(harness.base("native-base"), "native-private", edited_geometry=geometry)
    treatment = ("tiles", "feeds", "treatment", "--source-id", "gallery",
                 "--feed-id", "guest", "--treatment", "cover", "--color", "#ff00ff", "--in-place")
    harness.cli(*treatment, "--project", str(project))
    harness.assertIsNone(read_project(project)["participants"].get("render"))
    movie = harness.folder / "native-program.mov"
    render = ("export", "project", "render", "--output", str(movie))

    refusal = harness.cli(*render, "--project", str(project), "--mode", "copy", ok=False)
    harness.assertEqual(refusal["error"]["code"], "participant_render_requires_encoding")
    refusal = harness.cli(*render, "--project", str(project), "--dry-run", ok=False)
    harness.assertEqual(refusal["error"]["code"], "unresolved_participant_privacy")
    harness.assertFalse(movie.exists())

    def review(label, time, *, expect_open=False):
        directory = harness.folder / label
        args = ("review", "frames", "export", "--project", str(project), "--clock", "assembly",
                "--at", str(time), "--preset", "full", "--output", str(directory))
        result = harness.cli(*args, ok=expect_open)
        if expect_open:
            frame, = result["frames"]
            image = ffmpeg("-i", directory / frame["file"], "-pix_fmt", "rgb24", "-f", "rawvideo", "-")
            width, height = frame["width"], frame["height"]
            harness.assert_color(image, width, width * 3 // 4, height // 2, (255, 0, 255), "reviewed guest cover")
        else:
            harness.assertEqual(result["error"]["code"], "unresolved_participant_privacy")
            harness.assertFalse(directory.exists())

    review("before-confirmation", 0)
    confirm = ("tiles", "feeds", "confirm", "--source-id", "gallery",
               "--feed-id", "guest", "--in-place")
    harness.cli(*confirm, "--project", str(project), "--from", "0", "--to", "1")
    review("within-confirmation", 0, expect_open=True)
    review("outside-confirmation", 2)

    guest = next(a for a in geometry["appearances"] if a["participant_id"] == "guest" and fixture.rational(a["range"]["from"]) == 0)
    bounds = guest["bounds"]
    corrected = ",".join(str(bounds[key] if key != "width" else bounds[key] - 0.01)
                         for key in ("x", "y", "width", "height"))
    harness.cli("tiles", "box", "set", "--project", str(project), "--source-id", "gallery",
                "--tile-id", guest["id"], "--from", "0", "--to", "1", "--bounds", corrected, "--in-place")
    review("after-box-edit", 0)
    harness.cli(*confirm, "--project", str(project))
    review("after-reconfirmation", 0, expect_open=True)
    review("inferred-absence", 3)
    refusal = harness.cli(*render, "--project", str(project), ok=False)
    harness.assertEqual(refusal["error"]["code"], "unresolved_participant_privacy")
    harness.assertFalse(movie.exists())

    # The source fixture has two verified offscreen intervals for the guest.
    coverage = [(0, 3, "inferred"), (3, Fraction(27, 8), "verified"),
                (Fraction(27, 8), Fraction(7, 2), "inferred"),
                (Fraction(7, 2), Fraction(15, 4), "verified"), (Fraction(15, 4), 5, "inferred")]
    geometry["coverage"] = [{"range": fixture.interval(start, end), "state": state}
                            for start, end, state in coverage]
    verified = harness.approved(harness.base("verified-absence-base"), "verified-absence", edited_geometry=geometry)
    harness.cli(*treatment, "--project", str(verified))
    harness.cli(*confirm, "--project", str(verified))
    report = harness.cli(*render, "--project", str(verified))
    harness.assertTrue(report["participant_render"]["publishable"])
    harness.assertTrue(movie.exists())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    fixture.CLI = parser.parse_args().mpcut.resolve(strict=True)

    harness = fixture.ParticipantE2E("runTest")
    harness.setUpClass()
    try:
        harness.setUp()
        base = harness.base()
        geometry = fixture.geometry()
        second = next(a for a in geometry["appearances"] if a["id"] == "guest-thumb-16")
        second.pop("participant_id")
        # A stage appearance is still resolved during this interval. It cannot
        # vouch for the identity of the simultaneous thumbnail.
        approved = harness.approved(base, edited_geometry=geometry)
        malformed = read_project(approved)["participants"]
        thumbnail = next(a for a in malformed["sources"][0]["appearances"] if a["id"] == second["id"])
        thumbnail["role"] = "presentation"
        invalid = harness.folder / "invalid.cut"
        report = harness.cli("participants", "project", "apply", ok=False, request={
            "project_path": str(base), "out_project": str(invalid), "participants": malformed,
        })
        harness.assertEqual(report["error"]["code"], "invalid_participant_project")
        harness.assertFalse(invalid.exists())
        render = fixture.plan("original", size=(fixture.WIDTH, fixture.HEIGHT), redactions=(
            {"participant_id": "guest", "treatment": "opaque", "color": fixture.color(fixture.COVER)},
        ))
        render["canvas"]["background"] = fixture.color(fixture.COVER)
        request = {"project_path": str(approved), "plan": render}
        report = harness.cli("participants", "render", "plan", request=request)
        harness.assertFalse(report["publishable"])
        harness.assertEqual(report["privacy_issues"], [
            {"source_id": "gallery", "source": second["range"], "output": second["range"]},
        ])
        _, refused = harness.export(approved, "must-stop", render, ok=False)
        harness.assertEqual(refused["error"]["code"], "unresolved_participant_privacy")

        render["unresolved_privacy"] = "cover"
        output, _ = harness.export(approved, "covered", render)
        width, height = fixture.WIDTH, fixture.HEIGHT
        frames = harness.decode(output, size=(width, height))
        for index, frame in enumerate(frames):
            time = Fraction(index, fixture.FPS)
            if Fraction(second["range"]["from"]) <= time < Fraction(second["range"]["to"]):
                harness.assertLessEqual(max(frame), 14, f"frame {index} leaked the unresolved appearance")
            else:
                host = next(tile for tile in fixture.tiles_at(index) if tile.participant == "host")
                x, y, w, h = host.rect
                harness.assert_color(frame, width, x + w // 2, y + h // 2, fixture.HOST, f"host frame {index}")

        second["role"] = second["state"] = "presentation"
        presentation = harness.approved(base, "presentation", edited_geometry=geometry)
        request["project_path"] = str(presentation)
        render["unresolved_privacy"] = "stop"
        report = harness.cli("participants", "render", "plan", request=request)
        harness.assertTrue(report["publishable"])
        harness.assertEqual(report["privacy_issues"], [])

        # Clearing a native screen-share assignment makes its pixels unreviewed again.
        native = harness.folder / "native-share.cut"
        harness.cli("tiles", "tile", "screen-share", str(approved), "--tile-id", second["id"], "--out-project", str(native))
        harness.cli("tiles", "feeds", "treatment", str(native), "--feed-id", "guest", "--treatment", "cover", "--in-place")
        harness.cli("tiles", "link", str(native), "--tile-id", second["id"], "--clear", "--in-place")
        at = second["range"]["from"]
        review = harness.cli("tiles", "inspect", str(native), "--at", at)
        harness.assertTrue(any(issue["kind"] == "unassigned_tile" and issue["tile_id"] == second["id"]
                               for issue in review["issues"]))
        frames_dir = harness.folder / "unassigned-share-frames"
        frame = harness.cli("review", "frames", "export", "--project", str(native), "--clock", "assembly",
                            "--at", at, "--output", str(frames_dir), ok=False)
        harness.assertEqual(frame["error"]["code"], "unresolved_participant_privacy")
        harness.assertFalse(list(frames_dir.glob("*.jpg")))
        iso = harness.cli("tiles", "angles", "plan", str(native), "--all", "--no-meeting-mix")
        harness.assertTrue(iso["requires_review"])
        harness.assertTrue(any(issue["code"] == "unassigned_tiles" for issue in iso["issues"]))
        old = harness.cli("participants", "render", "plan", request={"project_path": str(native), "plan": render}, ok=False)
        harness.assertEqual(old["error"]["code"], "unsupported_legacy_participant_edit")

        second["role"], second["state"] = "thumbnail", "video"
        geometry["appearances"] = [a for a in geometry["appearances"] if a["id"] != "guest-stage-16"]
        uncertain = harness.approved(base, "uncertain", edited_geometry=geometry)
        flow = fixture.plan("flow", fixture.slot("host"), fixture.slot("guest"), size=(320, 90))
        flow["shots"][0]["compact"] = True
        output, _ = harness.export(uncertain, "flow", flow)
        frame = harness.decode(output, size=(320, 90))[16]
        harness.assert_color(frame, 320, 80, 45, fixture.HOST, "preserved host seat")
        harness.assert_color(frame, 320, 240, 45, fixture.GAP, "held unresolved guest seat")
        verify_rotated_vfr(harness)
        verify_bitstream_rotation_refuses_scanned_geometry(harness)
        verify_native_treatment_and_confirmation(harness)
    finally:
        harness.doClassCleanups()


if __name__ == "__main__":
    main()
