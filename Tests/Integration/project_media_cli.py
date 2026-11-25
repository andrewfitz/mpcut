"""Exercise project media commands with generated clips and a still fixture."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import wave
from saved_project import read_project


def exercise(cli, folder):
    def run(*arguments, request=None, succeeds=True):
        result = subprocess.run(
            [str(cli), *map(str, arguments), "--json"], cwd=folder,
            input=json.dumps(request) if request is not None else None,
            capture_output=True, text=True, timeout=60,
        )
        assert result.stdout, (arguments, result.returncode, result.stderr)
        payload = json.loads(result.stdout)
        assert (result.returncode == 0) == succeeds, (arguments, payload, result.stderr)
        if arguments[:2] != ("history", "compare") and arguments[:3] != ("project", "document", "print"):
            assert payload["ok"] == succeeds, payload
        return payload

    def write_wave(path, frames):
        with wave.open(str(path), "wb") as audio:
            audio.setparams((1, 2, 8000, 0, "NONE", ""))
            audio.writeframes(bytes(frames * 2))

    old_root = folder / "shoot"
    old_root.mkdir()
    write_wave(old_root / "take.wav", 16000)
    write_wave(old_root / "unused.wav", 8000)
    run("project", "create", "--stdin", request={
        "kind": "sequence",
        "out_project": "original.cut",
        "operations": [
            {"action": "append", "id": "take", "file": "shoot/take.wav", "from": "0", "to": "1"},
            {"action": "append", "id": "unused", "file": "shoot/unused.wav", "from": "0", "to": "1"},
        ],
    })
    run("project", "edit", "--stdin", request={
        "project_path": "original.cut", "out_project": "edit.cut",
        "operations": [{"action": "remove", "id": "unused"}],
    })
    edit = folder / "edit.cut"
    original_bytes = edit.read_bytes()
    original = read_project(edit)
    assert len(original["history"]["undo"]) == 1, original
    assert {Path(entry["path"]).name for entry in original["media_snapshot"]["entries"]} == {"take.wav", "unused.wav"}, original

    moved_root = folder / "archive"
    old_root.rename(moved_root)
    current_only = run("project", "media", "list", "edit.cut")
    assert [Path(row["path"]).name for row in current_only["sources"]] == ["take.wav"], current_only
    initial = run("project", "media", "list", "edit.cut", "--include-history")
    by_name = {Path(row["path"]).name: row for row in initial["sources"]}
    assert set(by_name) == {"take.wav", "unused.wav"}, initial
    assert {row["status"] for row in by_name.values()} == {"offline"}, initial

    compared = run("history", "compare", "--project", "edit.cut", "--history-index", "0")
    assert [(change["kind"], change["before"]["id"]) for change in compared["changes"]] == [
        ("removed", "unused"),
    ], compared
    out_of_range = run("history", "restore-copy", "--project", "edit.cut", "--history-index", "2",
                       "--out-project", "invalid.cut", succeeds=False)
    assert out_of_range["error"]["code"] == "revision_unavailable" and not (folder / "invalid.cut").exists()
    run("history", "restore-copy", "--project", "edit.cut", "--history-index", "0", "--out-project", "old.cut")
    restored = run("project", "document", "print", "old.cut")
    assert [clip["id"] for clip in restored["clips"]] == ["take", "unused"], restored
    assert not restored["history"].get("undo") and len(restored["history"]["redo"]) == 1, restored
    compared_redo = run("history", "compare", "--project", "old.cut", "--history-index", "1")
    assert [(change["kind"], change["after"]["id"]) for change in compared_redo["changes"]] == [
        ("added", "unused"),
    ], compared_redo
    already_exists = run("history", "restore-copy", "--project", "edit.cut", "--history-index", "0",
                         "--out-project", "original.cut", succeeds=False)
    assert already_exists["error"]["code"] == "destination_exists", already_exists
    run("history", "restore-copy", "--project", "old.cut", "--history-index", "1", "--out-project", "new.cut")
    current = read_project(folder / "new.cut")
    assert [clip["id"] for clip in current["clips"]] == ["take"] and len(current["history"]["undo"]) == 1, current
    assert edit.read_bytes() == original_bytes

    run("project", "media", "leave-offline", "edit.cut", "--source", by_name["take.wav"]["path"],
        "--out-project", "ignored.cut")
    ignored = run("project", "media", "list", "ignored.cut")["sources"]
    assert [row["status"] for row in ignored] == ["ignored"], ignored
    ignored_locate = run("project", "media", "locate", "ignored.cut", "--folder", "archive")["sources"]
    assert not ignored_locate, ignored_locate

    refresh = run("project", "media", "refresh", "--project", "edit.cut", "--no-sidecar")
    assert {Path(row["path"]).name: row["status"] for row in refresh["media"]} == {
        "take.wav": "offline",
    }, refresh

    # A lexical simplification would find the WAV next to the project even
    # though its recorded parent traversal cannot reach that file.
    write_wave(folder / "traversal.wav", 8000)
    traversal = folder / "traversal.cut"
    traversal.write_text(json.dumps({
        "format": "mpcut", "schema_version": 9, "kind": "sequence",
        "clips": [{"id": "unresolved", "file": "absent/../traversal.wav", "from": "0", "to": "1"}],
    }))
    inspected = run("project", "inspect", "--project", traversal, "--no-sidecar")
    assert inspected["duration"] == {"numerator": 1, "denominator": 1}, inspected
    assert inspected["sources"]["unresolved"].endswith("/absent/../traversal.wav"), inspected
    assert inspected["tier"]["id"] == "unavailable", inspected
    run("project", "media", "leave-offline", "traversal.cut", "--source", "absent/../traversal.wav", "--in-place")
    traversal_rows = run("project", "media", "list", "traversal.cut")["sources"]
    assert [row["status"] for row in traversal_rows] == ["ignored"], traversal_rows

    locate = run("project", "media", "locate", "edit.cut", "--folder", "archive", "--include-history")
    assert {Path(row["path"]).name for row in locate["sources"]} == {"take.wav", "unused.wav"}, locate
    assert all(row["outcome"] in {"verified", "match"} for row in locate["sources"]), locate
    assert edit.read_bytes() == original_bytes

    located = run("project", "media", "locate", "edit.cut", "--folder", "archive",
                  "--include-history", "--apply-matches", "--out-project", "located.cut")
    assert located["applied_count"] == 2 and Path(located["out_project"]).resolve() == folder / "located.cut", located
    run("project", "media", "revert", "located.cut", "--source", moved_root / "take.wav", "--out-project", "reverted.cut")
    reverted = run("project", "media", "list", "reverted.cut", "--include-history")["sources"]
    assert {Path(row["path"]).name: row["status"] for row in reverted} == {"take.wav": "offline", "unused.wav": "online"}, reverted
    undone = run("history", "compare", "--project", "reverted.cut", "--history-index", "0")
    assert [change["kind"] for change in undone["changes"]] == ["removed"], undone

    subdirectory = folder / "project copies"
    subdirectory.mkdir()
    prefix = run("project", "media", "relink", "edit.cut", "--map-prefix", f"{old_root}={moved_root}",
                 "--out-project", "project copies/prefix.cut")
    assert prefix["applied_count"] == 2, prefix
    copied = read_project((subdirectory / "prefix.cut"))
    assert copied["clips"][0]["file"] == "../archive/take.wav", copied
    assert len(copied["history"]["undo"]) == 1, copied
    assert {entry["path"] for entry in copied["media_snapshot"]["entries"]} == {
        "../archive/take.wav", "../archive/unused.wav",
    }, copied

    direct = run("project", "media", "relink", "edit.cut", "--from", by_name["take.wav"]["path"],
                 "--to", "archive/take.wav", "--from", by_name["unused.wav"]["path"],
                 "--to", "archive/missing.wav", "--in-place")
    assert direct["applied_count"] == 1 and len(direct["sources"]) == 2, direct
    current = run("project", "media", "list", "edit.cut", "--include-history")
    assert {Path(row["path"]).name: row["status"] for row in current["sources"]} == {
        "take.wav": "online", "unused.wav": "offline",
    }, current
    assert len(read_project(edit)["history"]["undo"]) == 1

    short = folder / "alternate.wav"
    write_wave(short, 4000)
    preview_input = edit.read_bytes()
    preview = run("project", "media", "replace", "edit.cut", "--source", str(moved_root / "take.wav"),
                  "--with", "alternate.wav", "--conform", "trim")
    assert preview["report"]["trimmed_use_ids"] == ["take"], preview
    assert "out_project" not in preview and edit.read_bytes() == preview_input
    replacement = run("project", "media", "replace", "edit.cut", "--source", str(moved_root / "take.wav"),
                      "--with", "alternate.wav", "--conform", "trim", "--allow-loss", "--out-project", "replaced.cut")
    assert Path(replacement["out_project"]).resolve() == folder / "replaced.cut", replacement
    replaced = read_project((folder / "replaced.cut"))
    assert Path(replaced["clips"][0]["file"]).name == "alternate.wav", replaced
    assert len(replaced["history"]["undo"]) == 2, replaced
    assert edit.read_bytes() == preview_input

    run("project", "edit", "--stdin", request={
        "project_path": "edit.cut", "out_project": "loss.cut",
        "operations": [{"action": "append", "id": "tail", "file": "archive/take.wav", "from": "1", "to": "2"}],
    })
    loss = run("project", "media", "replace", "loss.cut", "--source", "archive/take.wav",
               "--with", "alternate.wav")
    assert loss["report"]["lost_use_ids"] == ["tail"] and not loss["report"]["can_apply"], loss
    refusal = run("project", "media", "replace", "loss.cut", "--source", "archive/take.wav",
                  "--with", "alternate.wav", "--out-project", "refused.cut", succeeds=False)
    assert refusal["error"]["code"] == "media_replace_blocked" and not (folder / "refused.cut").exists(), refusal
    selected = run("project", "media", "replace", "loss.cut", "--source", "archive/take.wav",
                   "--with", "alternate.wav", "--use-id", "take")
    assert selected["report"]["affected_use_ids"] == ["take"] and selected["report"]["can_apply"], selected
    removed = run("project", "media", "replace", "loss.cut", "--source", "archive/take.wav",
                  "--with", "alternate.wav", "--loss", "remove", "--out-project", "removed.cut")
    assert removed["report"]["lost_use_ids"] == ["tail"], removed
    assert [clip["id"] for clip in read_project((folder / "removed.cut"))["clips"]] == ["take"]

    fixture = Path(__file__).resolve().parent / "fixtures" / "stills" / "patch.png"
    old_still = folder / "still.png"
    shutil.copyfile(fixture, old_still)
    still = run("still", "project", "create", "--image", "still.png", "--out-project", "still.cut",
                "--width", "1920", "--height", "1080", "--rate", "30", "--codec", "h264",
                "--container", "mov", "--duration", "1")
    old_still.rename(moved_root / "still.png")
    alias = run("still", "asset", "relink", "--project", "still.cut", "--asset", still["asset_id"],
                "--image", "archive/still.png", "--in-place")
    assert alias["asset_id"] == still["asset_id"], alias
    still_rows = run("project", "media", "list", "still.cut")["sources"]
    assert any(Path(row["url"]).resolve() == moved_root / "still.png" and row["status"] == "online" for row in still_rows), still_rows
    rejected = run("still", "asset", "relink", "--project", "still.cut", "--asset", still["asset_id"],
                   "--image", fixture.with_suffix(".jpeg"), "--out-project", "different.cut", succeeds=False)
    assert rejected["error"]["code"] == "media_relink_different" and not (folder / "different.cut").exists(), rejected


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as root:
        exercise(Path(sys.argv[1]).resolve(), Path(root).resolve())
