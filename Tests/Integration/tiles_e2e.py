#!/usr/bin/env python3
"""Exercise the Tiles CLI with a synthetic gallery and independent media decoding.

Run with python3 Tests/Integration/tiles_e2e.py path/to/mpcut.
A TileTrail-enabled build also exercises frame-by-frame recording analysis.
Use the bundled CLI, or point MPCUT_FFMPEG_HELPER at the packaged FFmpeg helper.
"""

import argparse
import fcntl
from fractions import Fraction
from hashlib import sha256
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import threading
import unittest

import participant_e2e
from participant_e2e import ParticipantFixtureCase, bounds, geometry, interval, rational
from participant_e2e_fixture import (
    FPS, GAP, GUEST, HEIGHT, HOST, LOWER, PRORES, STAGE, STAGE_RECT, UPPER, WIDTH,
    ffmpeg, generate_camera, paint, probe, sound,
)
from saved_project import read_project

ISO_OPTIONS = ("--size", "160x90", "--frame-rate", str(FPS), "--fit", "fill",
               "--camera-off", "blank", "--gap-color", bytes(GAP).hex())


class TilesE2E(ParticipantFixtureCase):
    def tiles(self, *args, status=0, request=None):
        command = [str(participant_e2e.CLI), "tiles", *map(str, args), "--no-sidecar", "--json"]
        if request is not None:
            command.append("--stdin")
        result = subprocess.run(command, input=json.dumps(request) if request is not None else None,
                                text=True, capture_output=True, timeout=180)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertIsInstance(report, dict)
        return report

    def manifest(self, delivery):
        report = json.loads((delivery / "manifest.json").read_text())
        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(report["status"], "completed")
        for entry in report["files"]:
            artifact = delivery / entry["filename"]
            contents = artifact.read_bytes()
            self.assertEqual(entry["bytes"], len(contents), artifact.name)
            self.assertEqual(entry["sha256"], sha256(contents).hexdigest(), artifact.name)
        return report

    def test_manual_feed_creation_and_assignment_without_scanning(self):
        source = self.base()
        original = source.read_bytes()
        draft = self.folder / "drawn.cut"
        created = self.tiles("feeds", "add", source, "--name", "Slides", "--out-project", draft)
        self.assertEqual(source.read_bytes(), original)
        feed = created["feed_id"]
        self.assertEqual(created["operation_count"], 1)
        self.tiles("box", "add", draft, "--source-id", "gallery", "--tile-id", "screen",
                   "--from", "0", "--to", "1", "--bounds", "0,0,1,1", "--in-place")
        self.tiles("link", draft, "--tile-id", "screen", "--feed-id", feed, "--in-place")
        assigned, = self.tiles("feeds", "list", draft)["feeds"]
        self.assertEqual((assigned["feed_id"], assigned["name"]), (feed, "Slides"))
        tile, = self.tiles("inspect", draft, "--at", "0")["tiles"]
        self.assertEqual((tile["tile_id"], tile["feed_id"]), ("screen", feed))

    def test_raw_recording_stops_for_review_and_reuses_its_feed_ids(self):
        recording = generate_camera(self.folder / "private-recording-name.mov", HOST, 2)
        scan = self.folder / "scan.json"
        summary = self.tiles("scan", recording, "--output", scan, "--backend", "cpu-only",
                             "--sampling", "every-frame", "--feed-layout", "1x1")
        self.assertNotIn("analysis", summary)
        self.assertEqual(summary["counts"]["feed_count"], 1)
        analysis = json.loads(scan.read_text())["analysis"]
        # The even-grid fallback records one inferred layout. TileTrail inspects every frame.
        self.assertEqual(len(analysis["observations"]), 2 * FPS if analysis["diagnostics"] else 1)
        issues = self.tiles("inspect", scan, "--issues")
        self.assertEqual(summary["review_issue_count"], len(issues["issues"]))
        preview = self.folder / "preview.png"
        self.tiles("preview", scan, "--at", "0", "--output", preview)
        self.assertTrue(preview.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))

        delivery = self.folder / "delivery"
        blocked = self.tiles("export-isos", recording, "--output", delivery, "--expected-feeds", "2",
                             "--backend", "cpu-only", "--sampling", "every-frame", "--feed-layout", "1x1",
                             *ISO_OPTIONS, status=3)
        self.assertEqual(blocked["status"], "needs_review")
        mismatch, = [issue for issue in blocked["issues"] if issue["code"] == "feed_count_mismatch"]
        self.assertIsNone(mismatch.get("source_time"))
        self.assertFalse(list(delivery.glob("*.mov")))
        self.assertFalse((delivery / "manifest.json").exists())
        project = Path(blocked["review_project_path"])
        self.assertTrue(project.is_file())
        self.assertFalse(project.is_relative_to(delivery))
        original_feeds = self.tiles("feeds", "list", project)["feeds"]
        feed, = original_feeds
        feed_id = feed["feed_id"]
        original_geometry = self.tiles("inspect", project)
        revised_hints = self.tiles("accept", project, "--expected-feeds", "1", "--max-visible-tiles", "1", "--in-place")
        self.assertEqual(revised_hints["operation_count"], 1)
        reviewed_issues = self.tiles("inspect", project, "--issues")["issues"]
        self.assertEqual(revised_hints["review_issue_count"], len(reviewed_issues))
        self.assertFalse(any(issue["kind"] == "count_mismatch" for issue in reviewed_issues))
        updated_hints = self.tiles("accept", project, "--expected-feeds", "2", "--in-place")
        self.assertEqual(updated_hints["operation_count"], 1)
        updated_source, = read_project(project)["participants"]["sources"]
        self.assertEqual(updated_source["count_hints"], {"expected_feeds": 2, "max_visible_tiles": 1})
        cleared = self.tiles("accept", project, "--clear-count-hints", "--in-place")
        self.assertEqual(cleared["operation_count"], 1)
        relieved = read_project(project)["participants"]
        self.assertEqual(self.tiles("feeds", "list", project)["feeds"], original_feeds)
        cleared_source, = relieved["sources"]
        self.assertNotIn("count_hints", cleared_source)
        cleared_geometry = self.tiles("inspect", project)
        for key in ("source_id", "counts", "tiles", "coverage", "gaps", "layouts"):
            self.assertEqual(cleared_geometry[key], original_geometry[key], key)
        completed = self.tiles("export-isos", project, "--output", delivery, "--resume", *ISO_OPTIONS)
        self.assertEqual(completed["status"], "completed")
        self.assertTrue(self.tiles("angles", "verify", delivery)["valid"])
        published = self.manifest(delivery)
        public_source_id = published["source_id"]
        self.assertRegex(public_source_id, r"^[0-9a-f]{64}$")
        self.assertNotIn(recording.name, json.dumps(published))
        initial, = [entry["feed"]["feed_id"] for entry in published["files"] if "feed" in entry]
        self.assertEqual(initial, feed_id)
        # Resume an older delivery whose manifest exposed the private recording ID.
        published["source_id"] = original_geometry["source_id"]
        (delivery / "manifest.json").write_text(json.dumps(published))
        tile_ids = {tile["tile_id"] for tile in original_geometry["tiles"]}
        tile_id, = tile_ids
        corrected = self.tiles("box", "set", project, "--tile-id", tile_id, "--from", "0", "--to", "2",
                               "--bounds", "0.1,0.1,0.8,0.8", "--in-place")
        self.assertEqual(corrected["operation_count"], 1)
        tile, = self.tiles("inspect", project, "--at", "1")["tiles"]
        self.assertEqual(tile["bounds"], {"x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8})
        self.tiles("feeds", "rename", project, "--feed-id", feed_id, "--name", "Host", "--in-place")
        completed = self.tiles("export-isos", project, "--output", delivery, "--resume", *ISO_OPTIONS)
        self.assertEqual(completed["status"], "completed")
        self.assertTrue(self.tiles("angles", "verify", delivery)["valid"])
        manifest = self.manifest(delivery)
        self.assertEqual(manifest["source_id"], public_source_id)
        self.assertNotIn(recording.name, json.dumps(manifest))
        self.assertEqual(rational(manifest["duration"]), 2)
        movie, = [entry for entry in manifest["files"] if "feed" in entry]
        self.assertEqual((movie["feed"]["feed_id"], movie["feed"]["name"]), (feed_id, "Host"))
        for image in self.decode(delivery / movie["filename"], frame_count=2 * FPS):
            self.assert_color(image, 160, 80, 45, HOST, "reviewed raw recording")

    def test_saved_plan_render_tamper_resume_and_preserve_legacy_output(self):
        reviewed = self.approved(self.base())
        old_project = read_project(reviewed)
        legacy = self.cli("participants", "angles", "list", request={
            "project_path": str(reviewed), "source_id": "gallery", "participant_ids": ["guest", "host"],
            "range": interval(0, 5),
        })["angles"]
        self.assertEqual({angle["id"] for angle in legacy}, {"guest", "host"})

        plan_path = self.folder / "angles.json"
        plan = self.tiles("angles", "plan", reviewed, "--feed-id", "guest", "--feed-id", "host",
                          "--output", plan_path, *ISO_OPTIONS)
        saved = json.loads(plan_path.read_text())
        for key in ("schema_version", "project_revision", "source_id", "provenance"):
            self.assertEqual(saved[key], plan[key], key)
        self.assertFalse(plan["requires_review"], plan["issues"])
        self.assertEqual({feed["feed_id"]: feed["audio_tracks"] for feed in plan["feeds"]},
                         {"guest": 1, "host": 0})
        delivery = self.folder / "delivery"
        self.tiles("angles", "render", "--plan", plan_path, "--output", delivery)
        manifest = self.manifest(delivery)
        self.assertTrue(self.tiles("angles", "verify", delivery)["valid"])
        movies = {entry["feed"]["feed_id"]: delivery / entry["filename"]
                  for entry in manifest["files"] if "feed" in entry}
        guest_frames = self.decode(movies["guest"])
        for index in (0, FPS):
            self.assert_color(guest_frames[index], 160, 80, 45, GUEST, "guest before and after seat swap")
        self.assert_color(guest_frames[3 * FPS], 160, 80, 45, GAP, "offscreen guest")
        self.assertEqual(sound(movies["guest"]), self.iso_pcm())
        self.assertEqual(sound(delivery / "meeting-mix.mov"), sound(self.gallery))
        self.assertEqual(read_project(reviewed), old_project)

        guest = movies["guest"]
        host = movies["host"]
        host_inode = host.stat().st_ino
        with guest.open("ab") as artifact:
            artifact.write(b"damaged delivery")
        result = self.tiles("angles", "verify", delivery, status=1)
        self.assertFalse(result["valid"])
        self.assertIn(guest.name, {issue["filename"] for issue in result["issues"]})
        self.tiles("angles", "render", "--plan", plan_path, "--output", delivery, "--resume")
        self.assertTrue(self.tiles("angles", "verify", delivery)["valid"])
        self.assertEqual(host.stat().st_ino, host_inode)
        self.assertEqual(sound(guest), self.iso_pcm())
        for repaired, original in zip(self.decode(guest), guest_frames, strict=True):
            average_error = sum(abs(left - right) for left, right in zip(repaired, original, strict=True)) / len(original)
            self.assertLessEqual(average_error, 2, "Repair preserves the crop across a fresh H.264 encode")

        # An edited crop invalidates only its own movie while other feed data stays current.
        guest_inode = guest.stat().st_ino
        tile = next(tile for tile in self.tiles("inspect", reviewed, "--at", "0")["tiles"]
                    if tile.get("feed_id") == "host")
        self.tiles("box", "set", reviewed, "--tile-id", tile["tile_id"], "--from", "0", "--to", "1",
                   "--bounds", "0.05,0.05,0.2,0.4", "--in-place")
        self.tiles("export-isos", reviewed, "--output", delivery, "--resume", *ISO_OPTIONS)
        self.assertNotEqual(host.stat().st_ino, host_inode)
        self.assertEqual(guest.stat().st_ino, guest_inode)
        self.assertTrue(self.tiles("angles", "verify", delivery)["valid"])

        # A correction invalidates the old plan. A fresh delivery of the edited project
        # must neither retain the withheld movie nor expose its microphone or name.
        self.tiles("feeds", "treatment", reviewed, "--feed-id", "guest", "--treatment", "cover", "--in-place")
        error = self.tiles("angles", "render", "--plan", plan_path, "--output", delivery, "--resume", status=1)
        self.assertEqual(error["error"]["code"], "stale_iso_plan")
        self.tiles("export-isos", reviewed, "--output", delivery, "--resume", *ISO_OPTIONS)
        self.assertTrue(self.tiles("angles", "verify", delivery)["valid"])
        revised = self.manifest(delivery)
        self.assertEqual([feed["feed_id"] for feed in revised["withheld"]], ["guest"])
        self.assertEqual([entry["feed"]["feed_id"] for entry in revised["files"] if "feed" in entry], ["host"])
        self.assertIn("shared_mix", {issue["code"] for issue in revised["issues"]})
        self.assertFalse(guest.exists())

    def test_selected_feed_warns_about_withheld_voices_and_strips_bindings(self):
        reviewed = self.approved(self.base())
        delivery = self.folder / "delivery"
        flags = (*ISO_OPTIONS, "--feed-id", "guest", "--from", "1/2", "--to", "201/80")
        plan = self.tiles("angles", "plan", reviewed, *flags)
        self.assertIn("microphone", plan["feeds"][0])
        self.tiles("export-isos", reviewed, "--output", delivery, *flags)
        manifest = self.manifest(delivery)
        self.assertEqual(manifest["source_range"], interval("1/2", "201/80"))
        self.assertEqual(manifest["withheld"], [{"feed_id": "host", "reason": "excluded"}])
        warning, = [issue for issue in manifest["issues"] if issue["code"] == "shared_mix"]
        self.assertNotIn("Host", warning["message"])
        movie, = [entry for entry in manifest["files"] if "feed" in entry]
        self.assertNotIn("microphone", movie["feed"])
        self.assertEqual(movie["feed"]["voices"], [])
        self.assertEqual(movie["feed"]["audio_tracks"], 1)
        self.assertEqual(manifest["render_metrics"]["picture_passes"], 1)
        timing = probe(delivery / movie["filename"], "-select_streams", "v:0", "-show_streams", "-show_packets")
        scale = Fraction(timing["streams"][0]["time_base"])
        packets = timing["packets"]
        self.assertEqual([int(packet["pts"]) * scale for packet in packets], [Fraction(i, FPS) for i in range(2 * FPS + 1)])
        self.assertEqual(int(packets[-1]["duration"]) * scale, Fraction(1, 80))

        # The destination's lock serializes different processes, including verification.
        fd = os.open(delivery, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for command in [("angles", "verify", delivery), ("export-isos", reviewed, "--output", delivery, *flags)]:
                busy = self.tiles(*command, status=1)
                self.assertEqual(busy["error"]["code"], "iso_delivery_busy")
        finally:
            os.close(fd)

        # Editing a completed project and its recorded checksum cannot make the altered routing valid.
        project_path = delivery / "multicam.cut"
        edited = read_project(project_path)
        edited["audio"] = {"mode": "none"}
        changed = json.dumps(edited).encode()
        project_path.write_bytes(changed)
        project_record = next(entry for entry in manifest["files"] if entry["filename"] == project_path.name)
        project_record.update(sha256=sha256(changed).hexdigest(), bytes=len(changed))
        (delivery / "manifest.json").write_text(json.dumps(manifest))
        verification = self.tiles("angles", "verify", delivery, status=1)
        self.assertIn("multicam.cut", [issue["filename"] for issue in verification["issues"]])

        # A name-only edit reuses the movie and refreshes the delivery filename and project.
        before = (delivery / movie["filename"]).stat().st_ino
        self.tiles("feeds", "rename", reviewed, "--feed-id", "guest", "--name", "New Name", "--in-place")
        self.tiles("export-isos", reviewed, "--output", delivery, "--resume", *flags)
        revised = self.manifest(delivery)
        renamed, = [entry for entry in revised["files"] if "feed" in entry]
        self.assertEqual((delivery / renamed["filename"]).stat().st_ino, before)
        self.assertFalse((delivery / movie["filename"]).exists())
        self.assertEqual(revised["render_metrics"]["picture_passes"], 0)
        self.assertTrue(self.tiles("angles", "verify", delivery)["valid"])

        quiet = self.tiles("angles", "plan", reviewed, "--no-meeting-mix", "--no-isos", *flags)
        self.assertNotIn("microphone", quiet["feeds"][0])
        self.assertNotIn("shared_mix", [issue["code"] for issue in quiet["issues"]])

        # A valid checksum cannot make a microphone that ends early match its picture.
        target = delivery / renamed["filename"]
        shortened = self.folder / "short-mic.mov"
        ffmpeg("-i", target, "-t", "1", "-i", target, "-map", "0:v:0", "-map", "1:a:0",
               "-c", "copy", "-video_track_timescale", str(scale.denominator), shortened)
        shortened.replace(target)
        contents = target.read_bytes()
        renamed.update(sha256=sha256(contents).hexdigest(), bytes=len(contents))
        (delivery / "manifest.json").write_text(json.dumps(revised))
        verification = self.tiles("angles", "verify", delivery, status=1)
        self.assertTrue(any(issue["filename"] == target.name and "microphone duration" in issue["message"]
                            for issue in verification["issues"]), verification)

    def test_preferred_tile_disappearance_matches_iso_manifest_gaps(self):
        reviewed = self.approved(self.base())
        self.tiles("feeds", "prefer", reviewed, "--feed-id", "host", "--tile-id", "host-left-0",
                   "--from", "0", "--to", "2", "--in-place")
        delivery = self.folder / "delivery"
        self.tiles("export-isos", reviewed, "--output", delivery, "--feed-id", "host",
                   "--from", "0", "--to", "2", "--no-meeting-mix", *ISO_OPTIONS)
        host, = [entry for entry in self.manifest(delivery)["files"] if "feed" in entry]
        pictures = self.decode(delivery / host["filename"], frame_count=2 * FPS)
        self.assert_color(pictures[0], 160, 80, 45, HOST, "preferred host tile")
        self.assert_color(pictures[FPS], 160, 80, 45, GAP, "missing preferred tile after seat swap")
        self.assertEqual(host["feed"]["visible"], [interval(0, 1)])
        self.assertEqual(host["feed"]["gaps"], [interval(1, 2)])

    def test_video_only_gallery_does_not_deliver_a_withheld_microphone_as_the_mix(self):
        silent = self.folder / "gallery-picture.mov"
        ffmpeg("-i", self.gallery, "-map", "0:v:0", "-c", "copy", silent)
        base = self.base()
        project = read_project(base)
        project["angles"][0] = {"id": "gallery", "file": str(silent)}
        project["audio"] = {"mode": "fixed", "source_id": "recorder", "audio_stream_index": 1}
        base.write_text(json.dumps(project))
        reviewed = self.approved(base)
        delivery = self.folder / "delivery"
        self.tiles("export-isos", reviewed, "--output", delivery, "--feed-id", "host", *ISO_OPTIONS)
        manifest = self.manifest(delivery)
        self.assertEqual(manifest["withheld"], [{"feed_id": "guest", "reason": "excluded"}])
        self.assertFalse((delivery / "meeting-mix.mov").exists())
        host, = [entry for entry in manifest["files"] if "feed" in entry]
        self.assertEqual(probe(delivery / host["filename"], "-select_streams", "a", "-show_streams")["streams"], [])

    def test_sequence_hdr_isos_and_legacy_sdr_rendition(self):
        recording = self.folder / "pq.mov"
        ffmpeg("-f", "lavfi", "-i", "testsrc2=size=160x90:rate=8:duration=1",
               "-c:v", "prores_ks", "-pix_fmt", "yuv422p10le", "-color_primaries", "bt2020",
               "-color_trc", "smpte2084", "-colorspace", "bt2020nc", "-bsf:v",
               "prores_metadata=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc", recording)
        span = interval(0, 1)
        source = str(recording)
        project = self.folder / "edit.cut"
        payload = {"format": "mpcut", "schema_version": 4, "kind": "sequence",
                   "clips": [{"id": "clip", "file": source, **span}],
                   "participants": {"people": [{"id": "host", "name": "Host"}], "sources": [
                       {"source_id": source, "appearances": [{"id": "main", "participant_id": "host",
                        "range": span, "bounds": {"x": 0, "y": 0, "width": 1, "height": 1},
                        "role": "tile", "state": "video"}], "coverage": [{"range": span, "state": "verified"}]}
                   ]}}
        project.write_text(json.dumps(payload))
        def properties(movie):
            stream, = probe(movie, "-select_streams", "v:0", "-show_streams")["streams"]
            return stream["codec_name"], stream["color_primaries"], stream["color_transfer"]

        delivery = self.folder / "delivery"
        def deliver(*options):
            self.tiles("export-isos", project, "--output", delivery, "--no-meeting-mix", *ISO_OPTIONS, *options)
            manifest = self.manifest(delivery)
            movie, = [entry for entry in manifest["files"] if "feed" in entry]
            return properties(delivery / movie["filename"])

        self.assertEqual(deliver(), ("hevc", "bt2020", "smpte2084"))
        legacy, _ = self.export(project, "legacy", participant_e2e.plan("solo", participant_e2e.slot("host")))
        self.assertEqual(properties(legacy)[:2], ("h264", "bt709"))
        payload["program_color_policy"] = {
            "version": 1, "transfer": "bt709", "primaries": "bt709", "matrix": "bt709", "range": "tv",
            "viewing_conditions": "sdr", "diffuse_white_nits": 203, "rendition_policy_version": 1,
        }
        project.write_text(json.dumps(payload))
        self.assertEqual(deliver("--resume")[:2], ("h264", "bt709"))

    def test_saved_plan_rejects_replaced_microphone_media(self):
        audio = self.folder / "audio.mov"
        shutil.copy2(self.recorder, audio)
        base = self.base()
        project = read_project(base)
        project["audio_sources"][0]["file"] = str(audio)
        base.write_text(json.dumps(project))
        reviewed = self.approved(base)
        plan = self.folder / "angles.json"
        self.tiles("angles", "plan", reviewed, "--feed-id", "guest", "--output", plan, *ISO_OPTIONS)
        replacement = self.folder / "replacement.mov"
        shutil.copy2(audio, replacement)
        replacement.replace(audio)
        delivery = self.folder / "delivery"
        stale = self.tiles("angles", "render", "--plan", plan, "--output", delivery, status=1)
        self.assertEqual(stale["error"]["code"], "stale_iso_plan")
        self.assertFalse(delivery.exists())

    def test_blanking_an_uncertain_interval_converts_the_issue_to_a_warning(self):
        source = geometry()
        source["appearances"].append({"id": "unknown", "range": interval(1, 2),
            "bounds": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2}, "role": "tile", "state": "unknown"})
        reviewed = self.approved(self.base(), edited_geometry=source)
        stopped = self.tiles("angles", "plan", reviewed, *ISO_OPTIONS)
        self.assertTrue(stopped["requires_review"])
        blanked = self.tiles("angles", "plan", reviewed, "--on-uncertain", "blank", *ISO_OPTIONS)
        self.assertFalse(blanked["requires_review"])
        warning, = [issue for issue in blanked["issues"] if issue["code"] == "unassigned_tiles"]
        self.assertFalse(warning["blocking"])
        self.assertEqual(warning["range"], interval(1, 2))

    def test_saved_plan_rejects_replaced_recording_before_rerouting(self):
        recording = self.folder / "recording.mov"
        shutil.copy2(self.gallery, recording)
        base = self.base()
        project = read_project(base)
        project["angles"][0]["file"] = str(recording)
        base.write_text(json.dumps(project))
        reviewed = self.approved(base)
        plan = self.folder / "angles.json"
        self.tiles("angles", "plan", reviewed, "--output", plan, *ISO_OPTIONS)
        replacement = generate_camera(self.folder / "shorter.mov", HOST, 2)
        replacement.replace(recording)
        delivery = self.folder / "delivery"
        stale = self.tiles("angles", "render", "--plan", plan, "--output", delivery, status=1)
        self.assertEqual(stale["error"]["code"], "stale_iso_plan")
        self.assertFalse(delivery.exists())

    def test_interrupted_movie_restarts_without_a_completion_manifest(self):
        reviewed = self.approved(self.base())
        delivery = self.folder / "delivery"
        flags = ("--size", "1280x720", "--frame-rate", "30", "--no-meeting-mix", "--no-isos")
        command = [str(participant_e2e.CLI), "tiles", "export-isos", str(reviewed), "--output", str(delivery),
                   *flags, "--progress", "jsonl", "--no-sidecar", "--json"]
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as run:
            timeout = threading.Timer(60, run.kill)
            timeout.start()
            try:
                for line in run.stderr:
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if event.get("phase") == "rendering" and 0.1 < event.get("fraction", 0) < 0.5:
                        run.send_signal(signal.SIGINT)
                        break
                stdout, stderr = run.communicate(timeout=60)
                self.assertEqual(run.returncode, 130, stdout + stderr)
            finally:
                timeout.cancel()
                if run.poll() is None:
                    run.kill()
        self.assertFalse((delivery / "manifest.json").exists())
        self.assertFalse(list(delivery.glob("*.mov")))
        self.assertFalse(self.tiles("angles", "verify", delivery, status=1)["valid"])
        self.tiles("export-isos", reviewed, "--output", delivery, "--resume", *flags)
        self.assertTrue(self.tiles("angles", "verify", delivery)["valid"])

    def test_arranged_gallery_swaps_and_blanks_tiles_across_layout_change(self):
        colors = [HOST, GUEST, (62, 75, 204), (212, 158, 61), (137, 60, 194),
                  (215, 172, 172), (43, 152, 177), (122, 116, 48), (230, 235, 222)]
        recording = self.folder / "nine-tile.mov"
        appearances = []
        raw = bytearray()
        for start, (cols, rows) in enumerate(((3, 3), (2, 2))):
            width, height = WIDTH // cols, HEIGHT // rows
            frame = bytearray(3 * WIDTH * HEIGHT)
            for index, swatch in enumerate(colors[:cols * rows]):
                rect = (index % cols * width, index // cols * height, width, height)
                paint(frame, rect, swatch)
                tile_id = f"tile-{index}" if start == 0 else f"small-tile-{index}"
                appearances.append({"id": tile_id, "participant_id": f"feed-{index}",
                                    "slot_id": f"position-{index}", "range": interval(start, start + 1), "bounds": bounds(rect),
                                    "role": "tile", "state": "video"})
            raw.extend(frame * FPS)
        ffmpeg("-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{WIDTH}x{HEIGHT}",
               "-framerate", str(FPS), "-i", "-", *PRORES, recording, input=bytes(raw))
        base = self.folder / "sequence.cut"
        base.write_text(json.dumps({"format": "mpcut", "schema_version": 4, "kind": "sequence",
                                   "clips": [{"id": "gallery", "file": str(recording), **interval(0, 2)}]}))
        project = self.folder / "reviewed.cut"
        self.cli("participants", "project", "apply", request={
            "project_path": str(base), "out_project": str(project),
            "participants": {
                "people": [{"id": f"feed-{index}", "name": f"Feed {index}"} for index in range(9)],
                "sources": [{"source_id": str(recording), "appearances": appearances,
                             "coverage": [{"range": interval(0, 2), "state": "verified"}]}],
            },
        })
        slots = [
            {"id": "feed-1", "target": "participant", "destination_tile_id": "tile-0"},
            {"id": "feed-0", "target": "participant", "destination_tile_id": "tile-1"},
            {"id": "empty", "target": "empty", "destination_tile_id": "tile-2",
             "background": int.from_bytes(bytes(GAP), "big")},
        ]
        before = project.read_bytes()
        failed = self.tiles("layout", "set", status=1, request={
            "project_path": str(project), "clip_id": "gallery", "layout": "arranged",
            "from": "0", "to": "2", "in_place": True,
            "slot": [{"id": "feed-1", "target": "participant", "destination_tile_id": "tile-8"}],
        })
        self.assertEqual(failed["error"]["code"], "unmappable_tile_layout")
        self.assertIn("tile-8", failed["error"]["message"])
        self.assertIn("at 1.", failed["error"]["message"])
        self.assertEqual(project.read_bytes(), before)
        receipt = self.tiles("layout", "set", request={
            "project_path": str(project), "clip_id": "gallery", "layout": "arranged",
            "from": "0", "to": "2", "slot": slots, "in_place": True,
        })
        self.assertEqual(receipt["operation_count"], 1)
        listing, = self.tiles("layout", "list", project, "--clip-id", "gallery")["layouts"]
        self.assertEqual(listing["clock"], "source")
        self.assertEqual([layout["range"] for layout in listing["layouts"]],
                         [interval(0, 1), interval(1, 2)])
        self.assertEqual({layout["layout"] for layout in listing["layouts"]}, {"arranged"})
        dest = self.folder / "review"
        result = self.cli("review", "frames", "export", "--project", str(project), "--clock", "sequence",
                          "--at", "0", "--at", "1", "--preset", "full", "--output", str(dest))
        self.assertEqual(len(result["frames"]), 2)
        self.assertEqual([Fraction(frame["frame_time"]["numerator"], frame["frame_time"]["denominator"])
                          for frame in result["frames"]], [0, 1])
        for shot, (cols, rows) in zip(result["frames"], ((3, 3), (2, 2))):
            width, height = shot["width"], shot["height"]
            frame = ffmpeg("-i", dest / shot["file"], "-pix_fmt", "rgb24", "-f", "rawvideo", "-")
            for position, swatch in enumerate((GUEST, HOST, GAP, colors[3])):
                x = (position % cols + 0.5) * width / cols
                y = (position // cols + 0.5) * height / rows
                self.assert_color(frame, width, int(x), int(y), swatch, f"{cols}x{rows} position {position}")

    def test_one_way_arrangement_consumes_stage_and_thumbnail(self):
        project = self.approved(self.base())
        self.tiles("layout", "set", request={
            "project_path": str(project), "group": True, "layout": "arranged",
            "from": "2", "to": "3", "in_place": True,
            "slot": [{"id": "guest", "target": "participant", "framing": "fill",
                      "destination_tile_id": f"host-upper-{2 * FPS}"}],
        })

        dest = self.folder / "one-way"
        result = self.cli("review", "frames", "export", "--project", str(project), "--clock", "assembly",
                          "--at", "2", "--preset", "full", "--output", str(dest))
        shot, = result["frames"]
        self.assertEqual((shot["width"], shot["height"]), (WIDTH, HEIGHT))
        frame = ffmpeg("-i", dest / shot["file"], "-pix_fmt", "rgb24", "-f", "rawvideo", "-")
        for rect, color, description in [(UPPER, STAGE, "preferred stage in destination"),
                                          (STAGE_RECT, (0, 0, 0), "consumed stage"),
                                          (LOWER, (0, 0, 0), "consumed thumbnail")]:
            x, y, width, height = rect
            self.assert_color(frame, WIDTH, x + width // 2, y + height // 2, color, description)

    def test_audio_only_keeps_program_mix_and_warns_about_treated_feeds(self):
        project = self.approved(self.base())
        self.tiles("feeds", "treatment", project, "--feed-id", "guest", "--treatment", "cover", "--in-place")
        output = self.folder / "audio-only.wav"
        result = self.cli("export", "project", "render", "--project", str(project), "--output", str(output),
                          "--tracks", "audio", "--mode", "encode", "--audio", "pcm")
        self.assertEqual(rational(result["encoded_video_duration"]), 0)
        self.assertEqual(result["participant_render"]["frame_count"], 0)
        self.assertIn("speech", result["participant_render"]["audio_privacy_notice"])
        self.assertEqual(sound(output), sound(self.gallery))

        copied = self.folder / "audio-copy.mov"
        result = self.cli("export", "project", "render", "--project", str(project), "--output", str(copied),
                          "--tracks", "audio", "--mode", "copy")
        action, = result["participant_render"]["audio_actions"]
        self.assertEqual(action["audio"], "copy")
        self.assertEqual(sound(copied), sound(self.gallery))

    def test_rendered_isos_support_transcript_switches_and_undo(self):
        reviewed = self.approved(self.base())
        delivery = self.folder / "delivery"
        self.tiles("export-isos", reviewed, "--output", delivery, *ISO_OPTIONS)
        self.assertTrue(self.tiles("angles", "verify", delivery)["valid"])
        project = delivery / "multicam.cut"
        delivered = read_project(project)
        angles = {angle["name"]: angle for angle in delivered["angles"]}
        self.assertEqual(set(angles), {"Host", "Guest"})
        for angle in angles.values():
            self.assertNotIn("feed_angle", angle)
            self.assertTrue((delivery / angle["file"]).is_file())
        mix, = delivered["audio_sources"]
        self.assertEqual(mix["file"], "meeting-mix.mov")
        self.assertEqual(sound(delivery / mix["file"]), sound(self.gallery))

        transcript = self.folder / "dialogue.vtt"
        transcript.write_text(
            "WEBVTT\n\n00:00.000 --> 00:00.875\n<v Host>Welcome.\n\n"
            "00:01.000 --> 00:01.875\n<v Guest>Glad to be here.\n"
        )
        attachment = self.cli("transcript", "attachment", "import", "--project", str(project),
                              "--transcript", str(transcript), "--source-id", mix["id"],
                              "--audio-stream-index", str(mix["audio_stream_index"]),
                              "--origin", "0", "--in-place")["attachment"]
        before_cuts = read_project(project)
        result = self.tiles("switches", "propose", project, "--attachment-id", attachment["id"],
                            "--minimum-hold", "1/2")
        proposals = result["proposals"]
        expected = [(0, angles["Host"]["id"]), (1, angles["Guest"]["id"])]
        self.assertEqual([(rational(cut["at"]), cut["angle_id"]) for cut in proposals], expected[1:])
        self.assertEqual({link["angle_id"] for link in result["links"]}, {angle for _, angle in expected})
        switched = delivery / "switched.cut"
        self.cli("project", "edit", request={
            "project_path": str(project), "out_project": str(switched),
            "operations": [{"action": "switch_set", "at": str(rational(cut["at"])),
                            "angle_id": cut["angle_id"], "project_revision": cut["project_revision"]}
                           for cut in proposals],
        })
        edited = read_project(switched)
        self.assertEqual([(rational(cut["group_time"]), cut["angle_id"]) for cut in edited["switches"]], expected)
        for (at, angle), end in zip(expected, (1, 5), strict=True):
            coverage = self.cli("multicam", "switch", "coverage", request={
                "project_path": str(switched), "angle_id": angle, "group_time": str(at),
            })
            self.assertEqual(coverage["group"], interval(at, end))
            for lane in ("picture", "audio"):
                self.assertEqual(coverage[lane], {"status": "covered", "missing": []}, coverage)
            self.assertEqual(coverage["audio_route"],
                             {"source_id": mix["id"], "audio_stream_index": mix["audio_stream_index"]})
        self.assertEqual(edited["audio"], before_cuts["audio"])
        # The persisted undo step keeps the first marker and drops the proposed cut.
        undo = edited["history"]["undo"][-1]
        self.assertEqual(undo["switches"], [[0, 1]])
        self.assertEqual(edited["switches"][:1], before_cuts["switches"])

    def test_feed_angles_take_cuts_without_rendering_intermediate_media(self):
        reviewed = self.approved(self.base())
        converted = self.folder / "angles.cut"
        existing_movies = set(self.folder.rglob("*.mov"))
        self.tiles("angles", "use", reviewed, "--all", "--out-project", converted)
        self.assertEqual(set(self.folder.rglob("*.mov")), existing_movies)
        authored = read_project(converted)
        angles = {angle.get("name"): angle["id"] for angle in authored["angles"]}
        self.assertTrue({"Host", "Guest"}.issubset(angles), authored["angles"])

        transcript = self.folder / "dialogue.vtt"
        transcript.write_text(
            "WEBVTT\n\n00:00.000 --> 00:00.875\n<v Host>Welcome.\n\n"
            "00:01.000 --> 00:01.875\n<v Guest>Glad to be here.\n"
        )
        attachment = self.cli("transcript", "attachment", "import", "--project", str(converted),
                              "--transcript", str(transcript), "--source-id", "gallery",
                              "--audio-stream-index", "1", "--origin", "0", "--in-place")["attachment"]
        result = self.tiles("switches", "propose", converted, "--attachment-id", attachment["id"],
                            "--minimum-hold", "1/2")
        proposals = result["proposals"]
        self.assertEqual([(rational(proposal["at"]), proposal["angle_id"]) for proposal in proposals],
                         [(0, angles["Host"]), (1, angles["Guest"])])
        self.assertTrue(all(proposal["project_revision"] == result["project_revision"] for proposal in proposals))
        cuts = [{"action": "switch_set", "at": str(rational(cut["at"])), "angle_id": cut["angle_id"]}
                for cut in proposals]
        cuts[0]["project_revision"] = result["project_revision"]
        switched = self.folder / "switched.cut"
        self.cli("project", "edit", request={
            "project_path": str(converted), "out_project": str(switched),
            "operations": cuts,
        })
        self.assertEqual(set(self.folder.rglob("*.mov")), existing_movies)
        output = self.folder / "edit.mov"
        render = ("export", "project", "render", "--project", str(switched), "--output", str(output))
        self.cli(*render, "--mode", "copy", ok=False)
        self.assertFalse(output.exists())
        self.cli(*render)
        frames = ffmpeg("-i", output, "-an", "-vf", "select=eq(t\\,0)+eq(t\\,1),scale=320:180",
                        "-fps_mode", "passthrough", "-pix_fmt", "rgb24", "-f", "rawvideo", "-")
        frame_bytes = 3 * WIDTH * HEIGHT
        self.assertEqual(len(frames), 2 * frame_bytes)
        self.assert_color(frames[:frame_bytes], WIDTH, WIDTH // 2, HEIGHT // 2, HOST, "opening host crop")
        self.assert_color(frames[frame_bytes:], WIDTH, WIDTH // 2, HEIGHT // 2, GUEST, "guest after seat swap")
        self.assertEqual(sound(output), sound(self.gallery))

        self.tiles("feeds", "treatment", switched, "--feed-id", "guest", "--treatment", "cover", "--in-place")
        captions = self.folder / "captions.srt"
        receipt = self.cli("transcript", "export", "--project", str(switched), "--captions",
                           "--output", str(captions))
        self.assertIn("Glad to be here.", captions.read_text())
        self.assertTrue(any("speech" in warning for warning in receipt["warnings"]), receipt)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    options, tests = parser.parse_known_args()
    participant_e2e.CLI = options.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
