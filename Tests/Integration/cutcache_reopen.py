#!/usr/bin/env python3
"""Reopen an edited transcript in the CLI, file worker and hidden desktop after deleting every cache.

Pass a packaged MPCut.app or the SwiftPM products directory containing mpcut, MPCutDesktop and mpcut-mcp.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import wave

from participant_gui import hidden_editor
from project_media_mcp import Client, file_job, timed_out
from transcript_lifecycle import eventually, operation


def run(products, folder):
    packaged = products.suffix == ".app"
    helpers = products / "Contents/Helpers" if packaged else products
    desktop = products if packaged else products / "MPCutDesktop"
    provider = folder / "provider"
    attempts = folder / "provider-calls"
    provider.write_text('#!/bin/sh\necho "$@" >> "$0-calls"\nexit 1\n')
    provider.chmod(0o700)
    settings = folder / "cache-settings"
    settings.mkdir()
    disk = folder / "removable-cache"
    disk.mkdir()
    marker = operation().upper()
    (disk / ".mpcut-cache-disk-id").write_text(marker)
    info = disk.stat()
    (settings / "config.json").write_text(json.dumps({"mode": "disk", "disk": {
        "path": str(disk), "volume": f"device-{info.st_dev}", "inode": info.st_ino, "diskMarker": marker}}))
    launch_env = {"MPCUT_TRANSCRIBERRR_HELPER": str(provider), "MPCUT_SIDECAR_HOME": str(settings),
                  "MPCUT_TRANSCRIPT_CLAIMS_HOME": str(folder / "claims")}
    env = dict(os.environ, **launch_env, MPCUT_MUTED="1", CFFIXED_USER_HOME=str(folder / "home"))

    def cli(*args, request=None, failure=None):
        cmd = [helpers / "mpcut", *args]
        if args[:3] != ("project", "document", "print"):
            cmd.append("--json")
        if request is not None:
            cmd.append("--stdin")
        result = subprocess.run(cmd, input=None if request is None else json.dumps(request),
                                cwd=folder, env=env, text=True, capture_output=True, timeout=60)
        assert result.stdout, (cmd, result.returncode, result.stderr)
        reply = json.loads(result.stdout)
        if failure:
            assert result.returncode and reply["error"]["code"] == failure, (cmd, reply)
        else:
            assert result.returncode == 0, (cmd, reply, result.stderr)
        return reply

    media = folder / "voice.wav"
    with wave.open(str(media), "wb") as sound:
        sound.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        sound.writeframes(bytes(16000 * 2))
    old = folder / "legacy.cutdb"
    with sqlite3.connect(old) as db:
        db.execute("CREATE TABLE retained_work (name TEXT)")
    before = old.read_bytes()
    project = folder / "first.cut"
    project.write_text(json.dumps({"format": "mpcut", "schema_version": 9, "kind": "sequence",
                                   "clips": [{"id": "clip", "file": media.name, "from": "0", "to": "1"}]}))
    source = folder / "native.json"
    zero = {"numerator": 0, "denominator": 1}
    word = {"id": "w1", "text": "Original", "start_sample": 4000, "end_sample": 8000,
            "precision": "word", "utterance_id": "u1"}
    observation = {"track_id": "mic", "word_id": "w1", "start_sample": 4000, "end_sample": 8000,
                   "evidence": "recognized"}
    source.write_text(json.dumps({"version": 1, "clock": "presentation", "sample_rate": 16000,
                                  "tracks": [{"id": "mic", "name": "Mic", "origin": zero, "session_start": zero,
                                              "coverage": "recognized", "role": "mixed_audio",
                                              "activity": [{"start_sample": 0, "end_sample": 320, "level": 0.625}],
                                              "words": [word]}], "speakers": [], "words": [dict(word, observations=[observation])]}))
    cli("transcript", "attachment", "import", "--project", project, "--transcript", source,
        "--audio-stream-index", "0", "--in-place")
    copy = folder / "second.cut"
    cli("transcript", "words", "correct", request={"project_path": str(project), "out_project": str(copy),
        "first_word_id": "w1", "change": {"replace_text": {"text": "Edited"}}})
    source.unlink()

    def word_in(page):
        row, = page["items"]
        assert row["range"] == {"from": "1/4", "to": "1/2"}, row
        return row["text"]

    helper = helpers / "mpcut-mcp"
    def open_live(display):
        live = Client(helper, env=dict(env, MPCUT_TEST_SOCKET_DIRECTORY=display["BACKSTAGE_SESSION"]))
        try:
            handle = live.call("project_open", operation_id=operation(), project_path=str(copy))["project_handle"]
            def state():
                return live.call("project_editor_state_read", project_handle=handle)
            eventually("indexed test recording", lambda: state()["total"] == 1 and state()["can_edit"])
            return live, handle, state
        except BaseException:
            live.close()
            raise

    with hidden_editor(desktop, copy, folder, launch_env, use_sidecars=True) as display:
        live, handle, state = open_live(display)
        try:
            live.call("silence_editor_threshold_set", project_handle=handle, operation_id=operation(),
                      expected_revision=state()["revision"], silence_threshold_db=-37.5)
            live.call("project_save", project_handle=handle, operation_id=operation(), expected_revision=state()["revision"])
        finally:
            live.close()
    index = cli("analysis", "sidecar", "build", "--only", "index", media)
    assert Path(index["write_location"]).is_relative_to(disk), index
    caches = list(folder.rglob("*.cutcache"))
    assert caches, "index build did not produce a cutcache"
    for cache in caches:
        cache.unlink()
    assert not list(folder.rglob("*.cutcache"))
    disk.rename(folder / "disconnected-cache")
    assert not cli("analysis", "sidecar", "inspect", media).get("write_location")
    for path, expected in [(project, "Original"), (copy, "Edited")]:
        assert word_in(cli("transcript", "words", "locate", "--project", path, "--space", "source",
                           "--word-id", "w1", "--no-sidecar", "--verbose")) == expected
        document = cli("project", "document", "print", path)
        if path == copy:
            threshold, = document["analysis_annotations"]["silence"]
            assert threshold["threshold_db"] == -37.5, threshold
        else:
            assert not document.get("analysis_annotations", {}).get("silence")
        attachment, = document["transcripts"]["attachments"]
        digest = attachment["asset"]["sha256"]
        assert list(document["embedded_assets"]["transcripts"]) == [digest]
        track, = document["embedded_assets"]["transcripts"][digest]["tracks"]
        assert track["provider_activity"] == [{"start": "0", "end": "1/50", "level": 0.625}], track
    client = Client(helper, "--files-only", env=env, poll_interval=0.05)
    try:
        page = file_job(client, "transcript_file_occurrences_locate",
                        request={"project_path": str(copy), "space": "source", "word_id": "w1", "verbose": True})
        assert word_in(page) == "Edited"
    finally:
        client.close()

    with hidden_editor(desktop, copy, folder, launch_env, use_sidecars=True) as display:
        live, handle, state = open_live(display)
        try:
            def located():
                return word_in(live.call("transcript_editor_occurrences_locate", project_handle=handle,
                                         space="source", word_id="w1", verbose=True))

            def threshold():
                return live.call("analysis_editor_state_read", project_handle=handle).get("manual_threshold_db")

            def history(action):
                live.call("history_" + action, project_handle=handle, expected_revision=state()["revision"],
                          operation_id=operation())

            assert located() == "Edited" and threshold() == -37.5
            history("undo")
            assert threshold() is None
            history("undo")
            assert located() == "Original"
            history("redo")
            assert located() == "Edited"
            history("redo")
            assert threshold() == -37.5
            try:
                live.call("project_open", operation_id=operation(), project_path=str(old))
            except ValueError as error:
                assert "unsupported_cutcache_version" in str(error), error
            else:
                raise AssertionError("The editor accepted a legacy database as a project")
        finally:
            live.close()
    assert not attempts.exists(), attempts.read_text()
    cli("transcript", "words", "locate", "--project", old, "--word-id", "w1",
        failure="unsupported_cutcache_version")
    assert old.read_bytes() == before


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("products", type=Path)
    args = parser.parse_args()
    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(240)
    with tempfile.TemporaryDirectory(prefix="mpcut-cutcache-reopen-") as temporary:
        run(args.products.resolve(strict=True), Path(temporary).resolve())
    print("Cutcache deletion, unavailable cache disk, CLI, file MCP, desktop reopen, undo and redo passed.")
