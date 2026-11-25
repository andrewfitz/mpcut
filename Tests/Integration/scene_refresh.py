#!/usr/bin/env python3
"""Exercise resumable scene scans and selective project refresh through the CLI."""
import argparse
from fractions import Fraction
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


def timestamp(value):
    return Fraction(value["numerator"], value["denominator"])


def ffmpeg(*arguments):
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", *arguments], check=True, timeout=120)


class SceneRefresh(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(scratch.cleanup)
        cls.picture = Path(scratch.name) / "picture.mp4"
        # A recurring view, a single-frame flash and B-frames between
        # three-second keyframes exercise detector state and decoder preroll.
        graph = (
            "color=red:s=1280x720:r=25:d=18,drawbox=c=white:t=fill:enable='eq(n,211)'[a];"
            "color=blue:s=1280x720:r=25:d=18[b];"
            "color=red:s=1280x720:r=25:d=18[c];"
            "[a][b][c]concat=n=3:v=1:a=0"
        )
        ffmpeg("-f", "lavfi", "-i", graph, "-c:v", "libx264", "-preset", "ultrafast",
               "-g", "75", "-bf", "2", "-sc_threshold", "0", cls.picture)

    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.folder = Path(scratch.name).resolve()
        self.source = self.folder / "editor.mp4"
        self.sidecar = self.folder / "editor.mp4.cutdb"
        self.project = self.folder / "editor.cut"

    def cli(self, *arguments):
        result = subprocess.run([CLI, "--json", *arguments], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout), result.stderr

    def scenes(self, *arguments):
        return self.cli("scenes", "scan", *arguments, self.source)[0]

    def status(self):
        return self.cli("analysis", "sidecar", "inspect", self.source)[0]

    def write_project(self, start="0", end="50", repeat_file=None):
        document = {
            "format": "mpcut", "schema_version": 3, "kind": "sequence",
            "clips": [
                {"id": "trim", "file": self.source.name, "from": start, "to": end},
                {"id": "repeat", "file": repeat_file or self.source.name, "from": "1", "to": "2"},
            ],
        }
        original = json.dumps(document).encode()
        self.project.write_bytes(original)
        return original

    def pause(self, *arguments):
        with subprocess.Popen(
            [CLI, "--json", "scenes", "scan", "--progress", "jsonl", *arguments, self.source],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ) as process:
            # Wait for progress within the first shot, before any cut has occurred.
            with selectors.DefaultSelector() as selector:
                selector.register(process.stderr, selectors.EVENT_READ)
                try:
                    deadline = time.monotonic() + 30
                    pending = b""
                    progress = {}
                    while not progress:
                        self.assertTrue(selector.select(timeout=max(0, deadline - time.monotonic())),
                                        "no scene scan progress")
                        chunk = os.read(process.stderr.fileno(), 65536)
                        self.assertTrue(chunk, "scene scan exited before reporting decoded progress")
                        pending += chunk
                        while b"\n" in pending:
                            event, pending = pending.split(b"\n", 1)
                            update = json.loads(event)["progress"]
                            if update.get("decoded") and timestamp(update["decoded"]) > 0:
                                progress = update
                                break
                    self.assertLess(timestamp(progress["decoded"]), 18)
                    process.send_signal(signal.SIGINT)
                    out, err = process.communicate(timeout=30)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
        self.assertEqual(process.returncode, 130, (event + out + err).decode(errors="replace"))
        result = json.loads(out)
        self.assertEqual(result["error"]["code"], "cancelled")
        return result

    def test_cold_trim_and_cached_full_report_keep_only_source_cuts(self):
        shutil.copyfile(self.picture, self.source)
        alias = self.folder / "linked-recording.mp4"
        os.link(self.source, alias)
        project_bytes = self.write_project(start="35", end="42", repeat_file=alias.name)
        selected, _ = self.cli("scenes", "scan", "--project", self.project, "--clip-id", "trim")
        self.assertEqual(len(selected["sources"]), 1)
        scope = selected["sources"][0]["outcome"]
        self.assertEqual(scope["state"], "completed")
        local = scope["report"]
        self.assertFalse(self.status()["inventory"]["has_scenes"])
        self.assertEqual(self.scenes("--from", "35", "--to", "42"), local)
        self.assertEqual(
            [(timestamp(scene["start"]), timestamp(scene["end"])) for scene in local["scenes"]],
            [(35, 36), (36, 42)],
        )

        full = self.scenes()
        self.assertEqual([timestamp(scene["start"]) for scene in full["scenes"]], [0, 18, 36])
        self.assertEqual([scene["view_label"] for scene in full["scenes"]], ["A", "B", "A"])
        self.assertEqual(timestamp(full["scenes"][-1]["end"]), 54)
        # A second interval lies inside an existing scene. A warm slice
        # preserves its identity while clipping the report to the requested interval.
        warm = self.scenes("--from", "37", "--to", "42")
        self.assertEqual(len(warm["scenes"]), 1)
        scene = warm["scenes"][0]
        self.assertEqual((timestamp(scene["start"]), timestamp(scene["end"])), (37, 42))
        self.assertEqual((scene["number"], scene["view"]), (full["scenes"][-1]["number"], full["scenes"][-1]["view"]))
        edge = self.scenes("--from", "35", "--to", "36")
        self.assertEqual([scene["view_label"] for scene in edge["scenes"]], ["B"])
        self.assertEqual(timestamp(edge["scenes"][0]["end"]), 36)
        operation = ("--from", "37", "--to", "42", "--policy", "restart", "--operation-id", "range-restart")
        restarted = self.scenes(*operation)
        self.assertEqual(
            [(timestamp(scene["start"]), timestamp(scene["end"])) for scene in restarted["scenes"]],
            [(37, 42)],
        )
        self.assertEqual(self.scenes(*operation), restarted)
        self.assertEqual(self.scenes(), full)
        all_sources, events = self.cli("scenes", "scan", "--project", self.project, "--all-sources", "--progress", "jsonl")
        self.assertEqual(len(all_sources["sources"]), 1)
        self.assertEqual(all_sources["sources"][0]["outcome"]["state"], "up_to_date")
        self.assertTrue(all(json.loads(line)["fraction"] == 1 for line in events.splitlines()))
        self.assertEqual(self.project.read_bytes(), project_bytes)

    def test_sigint_checkpoints_and_idempotent_restart_preserve_report(self):
        shutil.copyfile(self.picture, self.source)
        fresh = self.scenes("--no-sidecar")
        self.assertFalse(self.sidecar.exists())

        paused = self.pause()
        self.assertTrue(self.sidecar.exists(), paused)
        self.assertEqual(paused["state"], "paused")
        self.assertGreater(timestamp(paused["progress"]["durable"]), 0)
        self.assertLess(timestamp(paused["progress"]["durable"]), 54)
        attempts = self.status()["inventory"]["scene_attempts"]
        self.assertEqual(len(attempts), 1)
        saved = attempts[0]
        self.assertTrue(saved["current"])
        self.assertEqual(saved["state"], "paused")
        self.assertAlmostEqual(saved["covered_through"], float(timestamp(paused["progress"]["durable"])))
        self.assertEqual(self.scenes("--policy", "resume"), fresh)
        attempts = self.status()["inventory"]["scene_attempts"]
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]["id"], saved["id"])
        self.assertEqual(attempts[0]["state"], "completed")
        self.assertEqual(attempts[0]["covered_through"], 54)
        committed = self.sidecar.stat().st_mtime_ns
        self.assertEqual(self.scenes(), fresh)
        self.assertEqual(self.sidecar.stat().st_mtime_ns, committed)

        operation = ("--policy", "restart", "--operation-id", "scene-refresh-restart")
        self.assertEqual(self.scenes(*operation), fresh)
        restarted = self.sidecar.stat().st_mtime_ns
        self.assertGreater(restarted, committed)
        attempts = self.status()["inventory"]["scene_attempts"]
        self.assertEqual(len(attempts), 2)
        self.assertNotEqual(attempts[0]["id"], saved["id"])
        self.assertTrue(attempts[0]["current"])
        self.assertEqual(self.scenes(*operation), fresh)
        self.assertEqual(self.status()["inventory"]["scene_attempts"], attempts)
        self.assertEqual(self.sidecar.stat().st_mtime_ns, restarted)

    def test_refresh_keeps_only_verified_analyses_and_preserves_project(self):
        picture = self.folder / "original-picture.mp4"
        ffmpeg("-i", self.picture, "-t", "3", "-map", "0:v", "-c", "copy", picture)
        ffmpeg("-i", picture, "-f", "lavfi", "-i", "sine=frequency=300:duration=3",
               "-f", "lavfi", "-i", "sine=frequency=700:duration=3,volume=0:enable='between(t,0.75,2.25)'",
               "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "copy", "-c:a", "pcm_s16le", self.source)
        project_bytes = self.write_project(end="2")
        self.scenes()

        def pauses(stream):
            report, _ = self.cli("silence", "scan", "--stream", stream, "--threshold-db", "-35",
                                 "--min-pause-seconds", "0.5", self.source)
            return report["pauses"]

        self.assertEqual(pauses("1"), [])
        quiet_section = pauses("2")
        self.assertEqual(len(quiet_section), 1)

        def check_analyses(scenes, silence):
            status = self.status()
            self.assertEqual(status["status"], "current")
            self.assertEqual(status["inventory"]["has_scenes"], scenes)
            self.assertEqual([item["audio_stream_index"] for item in status["inventory"]["silence"]], silence)
            self.assertTrue(status["inventory"]["has_index"])
            attempts = status["inventory"]["scene_attempts"]
            self.assertEqual(sum(attempt["current"] for attempt in attempts), int(scenes))

        def refresh(scenes, audio, *flags):
            report, _ = self.cli("project", "media", "refresh", "--project", self.project, *flags)
            self.assertEqual(len(report["sources"]), 1)
            result = report["sources"][0]
            self.assertEqual(result["state"], "refreshed")
            self.assertEqual(result["scenes_preserved"], scenes)
            self.assertEqual(result["preserved_audio_streams"], audio)
            self.assertNotIn("persistence_error", result)
            return result

        check_analyses(True, [1, 2])
        unchanged, _ = self.cli("project", "media", "refresh", "--project", self.project)
        self.assertEqual([source["state"] for source in unchanged["sources"]], ["unchanged"])
        replacement = self.folder / "replacement.mp4"
        ffmpeg("-i", self.source, "-f", "lavfi", "-i", "sine=frequency=500:duration=3",
               "-map", "0:v", "-map", "1:a", "-map", "0:a:1",
               "-c", "copy", "-c:a:0", "pcm_s16le", replacement)
        replacement.replace(self.source)
        stale = self.status()
        self.assertEqual(stale["status"], "stale")
        self.assertTrue(stale["stale_reason"])
        self.assertFalse(any(attempt["current"] for attempt in stale["inventory"]["scene_attempts"]))
        refresh(True, [2])
        check_analyses(True, [2])

        self.assertEqual(pauses("1"), [])
        check_analyses(True, [1, 2])
        ffmpeg("-i", self.source, "-f", "lavfi", "-i", "sine=frequency=900:duration=3",
               "-map", "0:v", "-map", "1:a", "-map", "0:a:1",
               "-c", "copy", "-c:a:0", "pcm_s16le", "-movflags", "+faststart", replacement)
        stamp = self.source.stat()
        self.assertEqual(replacement.stat().st_size, stamp.st_size)
        replacement_bytes = replacement.read_bytes()
        self.assertNotEqual(replacement_bytes, self.source.read_bytes())
        self.source.write_bytes(replacement_bytes)
        replacement.unlink()
        os.utime(self.source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        self.assertEqual(self.source.stat().st_ino, stamp.st_ino)
        apparent = self.status()
        self.assertEqual(apparent["status"], "current")
        refresh(True, [2], "--deep")
        check_analyses(True, [2])
        generations = self.status()["generations"]
        self.assertGreater(generations[0]["id"], apparent["generations"][0]["id"])
        self.assertEqual(generations[0]["reason"], "content_changed")
        self.assertEqual([item["id"] for item in generations if item["current"]], [generations[0]["id"]])

        ffmpeg("-i", self.source, "-map", "0", "-c", "copy", replacement)
        self.assertNotEqual(replacement.read_bytes(), self.source.read_bytes())
        replacement.replace(self.source)
        refresh(True, [1, 2])
        check_analyses(True, [2])

        ffmpeg("-i", self.source, "-map", "0", "-c:a", "copy",
               "-vf", "drawbox=c=white:t=fill", "-c:v", "libx264", replacement)
        replacement.replace(self.source)
        refresh(False, [1, 2])
        check_analyses(False, [2])

        self.assertEqual(pauses("1"), [])
        self.assertEqual(pauses("2"), quiet_section)
        ffmpeg("-i", self.source, "-map", "0:v", "-map", "0:a:1", "-map", "0:a:0", "-c", "copy", replacement)
        replacement.replace(self.source)
        reordered = refresh(True, [])
        self.assertEqual(reordered["review_streams"], [1, 2])
        check_analyses(False, [])
        self.assertEqual(pauses("1"), quiet_section)
        self.assertEqual(pauses("2"), [])

        ffmpeg("-i", self.source, "-t", "1", "-map", "0", "-c:v", "libx264", "-c:a", "copy", replacement)
        replacement.replace(self.source)
        shortened = refresh(False, [])
        self.assertIn({"id": "trim", "reason": "range_outside_media"}, shortened["reference_issues"])
        check_analyses(False, [])
        self.assertEqual(self.project.read_bytes(), project_bytes)

    def test_refresh_flags_picture_track_reordered_past_audio(self):
        ffmpeg("-f", "lavfi", "-i", "color=red:s=160x90:r=25:d=3",
               "-f", "lavfi", "-i", "color=blue:s=160x90:r=25:d=3",
               "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
               "-map", "0:v", "-map", "1:v", "-map", "2:a",
               "-c:v", "libx264", "-c:a", "aac", self.source)
        self.write_project(end="2")
        baseline = self.cli("project", "media", "refresh", "--project", self.project)[0]["sources"][0]
        self.assertEqual(baseline["state"], "refreshed")
        self.assertNotIn("persistence_error", baseline)
        self.scenes()
        replacement = self.folder / "replacement.mp4"
        ffmpeg("-i", self.source, "-map", "0:a", "-map", "0:v:1", "-map", "0:v:0",
               "-disposition:v:0", "default", "-disposition:v:1", "0", "-c", "copy", replacement)
        replacement.replace(self.source)
        result = self.cli("project", "media", "refresh", "--project", self.project)[0]["sources"][0]
        self.assertEqual(result["state"], "refreshed")
        self.assertFalse(result["scenes_preserved"])
        self.assertTrue(result["display_changed"])
        self.assertIn(1, result["review_streams"])
        self.assertTrue(result["picture_needs_review"])

    def test_refresh_distinguishes_display_rotation_from_presentation_offset(self):
        ffmpeg("-f", "lavfi", "-i", "color=red:s=160x90:r=25:d=3",
               "-f", "lavfi", "-i", "sine=frequency=440:duration=5",
               "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-c:a", "aac", self.source)
        self.write_project(end="2")
        baseline = self.cli("project", "media", "refresh", "--project", self.project)[0]["sources"][0]
        self.assertNotIn("persistence_error", baseline)
        original_scenes = self.scenes()["scenes"]
        replacement = self.folder / "replacement.mp4"

        def packet_payloads():
            # Stream hash version 2 appends ", S=" and a hash of a stream's side data, which holds
            # the display matrix the first replacement changes on purpose (FFmpeg 9.1 writes it).
            # Compare the codec configuration and packet payloads without it.
            output = subprocess.check_output(["ffmpeg", "-nostdin", "-v", "error", "-i", self.source,
                                              "-map", "0", "-c", "copy", "-f", "streamhash", "-"], timeout=15)
            return [line.split(", S=")[0] for line in output.decode().splitlines()]

        original_payloads = packet_payloads()
        ffmpeg("-display_rotation:v:0", "90", "-i", self.source, "-map", "0", "-c", "copy", replacement)
        replacement.replace(self.source)
        self.assertEqual(packet_payloads(), original_payloads)
        rotation = self.cli("project", "media", "refresh", "--project", self.project)[0]["sources"][0]
        self.assertTrue(rotation["scenes_preserved"])
        self.assertTrue(rotation["display_changed"])
        self.assertEqual(rotation["preserved_audio_streams"], [1])
        self.assertTrue(self.status()["inventory"]["has_scenes"])
        self.assertEqual(self.scenes()["scenes"], original_scenes)

        ffmpeg("-itsoffset", "0.4", "-i", self.source, "-i", self.source,
               "-map", "0:v", "-map", "1:a", "-c", "copy", replacement)
        replacement.replace(self.source)
        self.assertEqual(packet_payloads(), original_payloads)
        timing = self.cli("project", "media", "refresh", "--project", self.project)[0]["sources"][0]
        self.assertFalse(timing["scenes_preserved"])
        self.assertTrue(timing["display_changed"])
        self.assertEqual(timing["preserved_audio_streams"], [])
        self.assertFalse(self.status()["inventory"]["has_scenes"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    args, tests = parser.parse_known_args()
    CLI = args.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
