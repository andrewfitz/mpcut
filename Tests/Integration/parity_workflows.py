#!/usr/bin/env python3
"""Exercise saved-project MCP workflows against a built helper and matching CLI.

Run with python3 Tests/Integration/parity_workflows.py path/to/mpcut-mcp path/to/mpcut.
The gallery fixture and independent decoder use ffmpeg and ffprobe on PATH.
"""

import argparse
import base64
from contextlib import contextmanager
from fractions import Fraction
import os
from pathlib import Path
import signal
import time
import unittest
import uuid

from headless import Client, timed_out
import participant_e2e
from participant_e2e import ParticipantFixtureCase, interval
from participant_e2e_fixture import COVER, GUEST, HOST, HEIGHT, WIDTH, ffmpeg, probe
from saved_project import read_project


HELPER = None


class ParityWorkflows(ParticipantFixtureCase):
    @contextmanager
    def connect(self):
        client = Client(HELPER, "--files-only", poll_interval=0.05, env=dict(
            os.environ, MPCUT_MUTED="1", MPCUT_FILE_RECEIPT_DIRECTORY=str(self.folder / "receipts")))
        try:
            yield client
        finally:
            client.close()
        self.assertEqual(client.process.returncode, 0)

    def submit(self, client, tool, *, operation_id=None, **arguments):
        return client.call(tool, operation_id=operation_id or str(uuid.uuid4()), **arguments)

    def wait_for_job(self, client, receipt, *, error=None):
        deadline = time.monotonic() + 30
        state = receipt
        while state["state"] in ("running", "cancelling") and time.monotonic() < deadline:
            client.wait_for_poll()
            state = client.call("file_job_status_read", job_id=receipt["job_id"])
        self.assertEqual(state["state"], "failed" if error else "succeeded", state)
        return state

    def finish(self, client, receipt, *, error=None):
        state = self.wait_for_job(client, receipt, error=error)
        result = client.job_result(state)
        if error:
            self.assertEqual(result["error"]["code"], error, result)
        return result

    def job(self, client, tool, *, error=None, **arguments):
        return self.finish(client, self.submit(client, tool, **arguments), error=error)

    def test_retry_in_place_gap_after_reconnect(self):
        project = self.folder / "retry.cut"
        insert = dict(project_path=str(project), in_place=True, clock="sequence", at="0", frames=10,
                      rate="30", operation_id=str(uuid.uuid4()))
        with self.connect() as client:
            self.job(client, "still_file_project_create", out_project=str(project), gap=True, frames=10,
                     rate="30", codec="h264", container="mp4", width=320, height=180)
            receipt = self.submit(client, "timeline_file_gap_insert", **insert)
            original_result = self.finish(client, receipt)
            placements = self.job(client, "still_file_placements_list", project_path=str(project))["placements"]
            self.assertEqual(len(placements), 2, placements)
        saved = project.read_bytes()

        with self.connect() as client:
            recovered = client.call("file_job_status_read", job_id=insert["operation_id"])
            self.assertEqual(recovered["job_id"], receipt["job_id"])
            self.assertEqual(self.finish(client, recovered), original_result)
            replay = self.submit(client, "timeline_file_gap_insert", **insert)
            self.assertEqual(replay["job_id"], receipt["job_id"])
            self.assertEqual(self.finish(client, replay), original_result)
            with self.assertRaisesRegex(ValueError, r"operation_id_conflict"):
                self.submit(client, "timeline_file_gap_insert", **{**insert, "frames": 11})
            placements = self.job(client, "still_file_placements_list", project_path=str(project))["placements"]
            self.assertEqual(len(placements), 2, placements)
        self.assertEqual(project.read_bytes(), saved)

    def test_ordinary_render_requires_reviewed_project_when_token_is_supplied(self):
        project = self.folder / "reviewed.cut"
        output = self.folder / "reviewed.mov"
        stale_output = self.folder / "stale.mov"
        replacement = self.folder / "replacement.cut"
        options = dict(project_path=str(project), output=str(output), mode="copy",
                       tracks="video", no_sidecar=True)

        def append(clip_id):
            return dict(action="append", id=clip_id, file=str(self.gallery))

        with self.connect() as client:
            version = self.job(client, "cli_version_read")
            self.assertEqual(version, self.cli("--version"))
            self.assertEqual(str(uuid.UUID(version["build_id"])), version["build_id"])
            self.assertTrue(version["detector_capabilities"]["standalone_fixed_grid"])
            self.job(client, "project_file_create", request=dict(
                kind="sequence", out_project=str(project), operations=[append("first")]))
            self.assertIn(read_project(project)["schema_version"], version["project_schema_versions"])
            approved = self.job(client, "export_file_project_render", dry_run=True, **options)["plan_token"]
            stale_options = {**options, "output": str(stale_output)}
            stale = self.job(client, "export_file_project_render", dry_run=True,
                             **stale_options)["plan_token"]
            self.assertTrue(approved and stale)
            self.assertFalse(output.exists() or stale_output.exists())

        with self.connect() as client:
            self.job(client, "export_file_project_render", plan_token=approved, **options)
            duration = probe(output, "-show_entries", "format=duration")["format"]["duration"]
            self.assertEqual(Fraction(duration), 5)
            self.job(client, "project_file_edit", request=dict(
                project_path=str(project), out_project=str(replacement), operations=[append("second")]))
        replacement.replace(project)

        with self.connect() as client:
            self.job(client, "export_file_project_render", error="stale_render_plan", plan_token=stale,
                     **stale_options)
            self.assertFalse(stale_output.exists())
            new_token = self.job(client, "export_file_project_render", dry_run=True,
                                 **stale_options)["plan_token"]
            self.job(client, "export_file_project_render", plan_token=new_token, **stale_options)
        duration = probe(stale_output, "-show_entries", "format=duration")["format"]["duration"]
        self.assertEqual(Fraction(duration), 10)

    def read_pixels(self, client, project):
        receipt = self.submit(client, "review_file_frame_read", project_path=str(project), clock="assembly", at="1/2")
        self.wait_for_job(client, receipt)
        response = client.request("tools/call", name="review_file_frame_result_read",
                                  arguments={"job_id": receipt["job_id"]})
        self.assertFalse(response.get("isError"), response)
        metadata = response["structuredContent"]
        self.assertEqual(metadata["job_id"], receipt["job_id"])
        self.assertTrue(all(0 < metadata[axis] <= 640 for axis in ("width", "height")), metadata)
        images = [block for block in response["content"] if block["type"] == "image"]
        self.assertEqual(len(images), 1)
        image, = images
        self.assertEqual(image["mimeType"], "image/jpeg")
        jpeg = base64.b64decode(image["data"], validate=True)
        self.assertTrue(jpeg.startswith(b"\xff\xd8"))
        self.assertLessEqual(len(jpeg), 1024 * 1024)
        pixels = ffmpeg("-f", "mjpeg", "-i", "-", "-vf", f"scale={WIDTH}:{HEIGHT}",
                        "-pix_fmt", "rgb24", "-frames:v", "1", "-f", "rawvideo", "-", input=jpeg)
        self.assertEqual(len(pixels), WIDTH * HEIGHT * 3)
        return pixels

    def test_cover_geometry_comparison_matches_rendered_pixels(self):
        project = self.approved(self.base())
        before = self.folder / "covered-before.cut"
        with self.connect() as client:
            catalog = {tool["name"] for tool in client.pages("tools/list", "tools")}
            self.assertTrue({"review_file_frame_read", "review_file_frame_result_read",
                             "history_file_compare", "tiles_file_box_set"} <= catalog)
            self.assertNotIn("project_windows_list", catalog)
            self.job(client, "tiles_file_feeds_treatment", project_path=str(project), source_id="gallery",
                     feed_id="host", treatment="cover", in_place=True)
            tiles = self.job(client, "tiles_file_inspect", project_path=str(project), source_id="gallery", at="1/2")
            tile, = [tile for tile in tiles["tiles"] if tile.get("feed_id") == "host"]
            old_pixels = self.read_pixels(client, project)
            before.write_bytes(project.read_bytes())
            self.job(client, "tiles_file_box_set", project_path=str(project), source_id="gallery",
                     tile_id=tile["tile_id"], **interval(0, 1),
                     bounds=dict(x=0.5, y=0, width=0.5, height=1), in_place=True)

        with self.connect() as client:
            comparison = self.job(client, "history_file_compare", before_project_path=str(before),
                                  project_path=str(project))
            self.assertIn("privacy_geometry", comparison["project_fields"])
            self.assertNotIn("feed_treatments", comparison["project_fields"])
            self.assertTrue(any(
                change["category"] == "privacy_geometry" and change["kind"] == "modified"
                and change["source_id"] == "gallery" and change.get("tile_id") == tile["tile_id"]
                and change.get("before_range") == interval(0, 1) and change.get("after_range") == interval(0, 1)
                and "bounds" in change["fields"]
                for change in comparison["participant_changes"]
            ), comparison)
            new_pixels = self.read_pixels(client, project)
        self.assert_color(old_pixels, WIDTH, WIDTH // 4, HEIGHT // 2, COVER, "original left cover")
        self.assert_color(old_pixels, WIDTH, WIDTH * 3 // 4, HEIGHT // 2, GUEST, "original right feed")
        self.assert_color(new_pixels, WIDTH, WIDTH // 4, HEIGHT // 2, HOST, "revealed left feed")
        self.assert_color(new_pixels, WIDTH, WIDTH * 3 // 4, HEIGHT // 2, COVER, "moved right cover")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path)
    parser.add_argument("cli", type=Path)
    args, unittest_args = parser.parse_known_args()
    HELPER = args.helper.resolve()
    participant_e2e.CLI = args.cli.resolve()
    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(180)
    unittest.main(argv=[__file__, *unittest_args])
