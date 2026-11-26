#!/usr/bin/env python3
"""Exercise desktop autosave, undo, named Save and file MCP on a project larger than 64 MiB."""
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import wave

from participant_gui import hidden_editor
from project_media_mcp import Client, file_job, timed_out
from transcript_lifecycle import operation


def run(products, folder):
    desktop = products if products.suffix == ".app" else products / "MPCutDesktop"
    helpers = products / "Contents/Helpers" if products.suffix == ".app" else products
    sound = folder / "voice.wav"
    with wave.open(str(sound), "wb") as audio:
        audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        audio.writeframes(bytes(32000))
    base = folder / "base.cut"
    base.write_text(json.dumps({"format": "mpcut", "schema_version": 9, "kind": "sequence",
                                "clips": [{"id": "clip", "file": str(sound), "from": "0", "to": "1"}]}))
    subtitle = folder / "voice.srt"
    subtitle.write_text("1\n00:00:00,100 --> 00:00:00,600\nSpoken\n")
    env = dict(os.environ, CFFIXED_USER_HOME=str(folder / "home"), MPCUT_MUTED="1")
    subprocess.run([helpers / "mpcut", "transcript", "attachment", "import", "--project", base,
                    "--transcript", subtitle, "--audio-stream-index", "0", "--in-place", "--json"],
                   stdout=subprocess.DEVNULL, env=env, check=True)
    document = json.loads(base.read_bytes())
    assets = document["embedded_assets"]["transcripts"]
    _, transcript = assets.popitem()
    word, = transcript["words"]
    # Retain a short queryable word alongside 64 MiB of actual stored subtitle text.
    for index in range(16384):
        transcript["words"].append(dict(word, i=f"stored-{index}", t="x" * 4096))
    canonical = json.dumps(transcript, sort_keys=True, separators=(",", ":")).encode()
    digest = hashlib.sha256(canonical).hexdigest()
    del canonical
    assets[digest] = transcript
    document["transcripts"]["attachments"][0]["asset"]["sha256"] = digest
    draft = (folder / "home/Library/Autosave Information/com.mpcut.desktop" / operation() / "Untitled.cut")
    draft.parent.mkdir(parents=True)
    with draft.open("w") as stream:
        json.dump(document, stream, separators=(",", ":"))
    del document, transcript, assets
    minimum = 64 * 1024 * 1024
    assert draft.stat().st_size > minimum
    print(f"Embedded fixture is {draft.stat().st_size:,} bytes", flush=True)

    def client(display):
        return Client(helpers / "mpcut-mcp", env=dict(env, MPCUT_TEST_SOCKET_DIRECTORY=display["BACKSTAGE_SESSION"]))

    def current_threshold(live, handle):
        return live.call("analysis_editor_state_read", project_handle=handle).get("manual_threshold_db")

    def assert_word(page):
        row, = page["items"]
        assert row["text"] == "Spoken" and row["range"] == {"from": "1/10", "to": "3/5"}, row

    def mutate(live, handle, tool, **arguments):
        revision = live.call("project_editor_state_read", project_handle=handle)["revision"]
        return live.call(tool, project_handle=handle, expected_revision=revision, operation_id=operation(), **arguments)

    saved = folder / "saved.cut"
    with hidden_editor(desktop, base, folder) as display, closing(client(display)) as live:
        drafts = live.call("project_drafts_list")["drafts"]
        assert str(draft) in [item["draft_path"] for item in drafts], drafts
        handle = live.call("project_draft_recover", draft_path=str(draft), operation_id=operation())["project_handle"]
        assert_word(live.call("transcript_editor_occurrences_locate", project_handle=handle,
                              space="source", word_id=word["i"], verbose=True))
        mutate(live, handle, "silence_editor_threshold_set", silence_threshold_db=-37.5)
        assert current_threshold(live, handle) == -37.5
        autosaved = json.loads(draft.read_bytes())
        assert list(autosaved["embedded_assets"]["transcripts"]) == [digest]
        assert autosaved["analysis_annotations"]["silence"][0]["threshold_db"] == -37.5
        assert draft.stat().st_size > minimum
        print(f"Desktop autosaved {draft.stat().st_size:,} bytes", flush=True)
        del autosaved
        mutate(live, handle, "history_undo")
        assert current_threshold(live, handle) is None
        mutate(live, handle, "project_save", project_path=str(saved))
        assert saved.stat().st_size > minimum

    with closing(Client(helpers / "mpcut-mcp", "--files-only", env=env)) as file_client:
        assert_word(file_job(file_client, "transcript_file_occurrences_locate",
                             request={"project_path": str(saved), "space": "source", "word_id": word["i"]}))

    with hidden_editor(desktop, base, folder) as display, closing(client(display)) as live:
        handle = live.call("project_open", project_path=str(saved), operation_id=operation())["project_handle"]
        assert current_threshold(live, handle) is None
        mutate(live, handle, "history_redo")
        assert current_threshold(live, handle) == -37.5
        assert_word(live.call("transcript_editor_occurrences_locate", project_handle=handle,
                              space="source", word_id=word["i"], verbose=True))
        mutate(live, handle, "project_save")
        assert saved.stat().st_size > minimum
        print(f"Reopened and saved {saved.stat().st_size:,} bytes, including restored history", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("products", type=Path)
    parser.add_argument("--scratch-directory", type=Path)
    args = parser.parse_args()
    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(600)
    with tempfile.TemporaryDirectory(prefix="mpcut-large-reopen-", dir=args.scratch_directory) as temp:
        run(args.products.resolve(strict=True), Path(temp).resolve())
