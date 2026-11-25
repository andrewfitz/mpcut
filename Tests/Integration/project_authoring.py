"""Exercise the project authoring CLI directly with a generated audio source."""

import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys
import tempfile
import wave
from saved_project import read_project


def exercise(cli, folder):
    media = folder / "take.wav"
    with wave.open(str(media), "wb") as audio:
        audio.setparams((1, 2, 8000, 0, "NONE", ""))
        audio.writeframes(bytes(16000))

    def author(command, request, *, replacement=None):
        body = json.dumps(request)
        if replacement:
            body = body.replace(*replacement)
        process = subprocess.run([str(cli), "project", command, "--stdin", "--json"],
                                 input=body, text=True, capture_output=True)
        payload = json.loads(process.stdout)
        assert (process.returncode == 0) == payload["ok"], (process.stderr, payload)
        return payload

    def clip(identifier):
        return {"action": "append", "id": identifier, "file": str(media)}

    failed = folder / "failed.cut"
    create = {"kind": "sequence", "out_project": str(failed), "operations": [clip("a"), clip("a")]}
    assert author("create", create)["error"]["code"] == "invalid_cut_project"
    assert not failed.exists()

    create["operations"] = [clip("a"), clip("b"), {"action": "move", "id": "a", "index": 1}]
    invalid = author("create", create, replacement=('"index": 1', '"index": 0.99999999999999999'))
    assert invalid["error"]["code"] == "invalid_json"
    assert not failed.exists()

    dangling = folder / "dangling.cut"
    target = folder / "missing" / "absent.cut"
    dangling.symlink_to(target)
    create["out_project"] = str(dangling)
    assert author("create", create)["error"]["code"] == "output_exists"
    assert dangling.is_symlink()
    assert not target.exists()

    raced = folder / "raced.cut"
    create["out_project"] = str(raced)
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(lambda _: author("create", create), range(2)))
    assert sum(result["ok"] for result in results) == 1
    assert next(result for result in results if not result["ok"])["error"]["code"] == "output_exists"
    assert len(read_project(raced)["clips"]) == 2

    source = folder / "original.cut"
    create["out_project"] = str(source)
    assert author("create", create)["operation_count"] == 3
    assert [clip["id"] for clip in read_project(source)["clips"]] == ["b", "a"]

    subdirectory = folder / "copies"
    subdirectory.mkdir()
    copy = subdirectory / "revised.cut"
    assert author("edit", {"project_path": str(source), "out_project": str(copy),
                           "operations": [{"action": "remove", "id": "b"}]})["ok"]
    archive = read_project(copy)
    assert archive["clips"][0]["file"] == "../take.wav"
    assert len(archive["history"]["undo"]) == 1

    camera = Path(__file__).resolve().parents[1] / "MPCutAppTests/Fixtures/ProRes-2997.mov"
    multicam = folder / "multicam.cut"
    assert author("create", {"kind": "multicam", "out_project": str(multicam),
                             "angles": [{"id": "A", "file": str(camera)}],
                             "group_end": "1001/10000", "operations": []})["ok"]
    unchanged = folder / "multicam-copy.cut"
    assert author("edit", {"project_path": str(multicam), "out_project": str(unchanged),
                           "operations": [{"action": "move", "index": 0, "to_index": 0}]})["ok"]
    assert read_project(unchanged) == read_project(multicam)

    with_sound = camera.with_name("Multicam-Delayed-PCM.mov")
    mix = folder / "mix.cut"
    assert author("create", {"kind": "multicam", "out_project": str(mix),
                             "angles": [{"id": "A", "file": str(with_sound), "audio_stream_index": 1}],
                             "group_end": "1/5", "operations": [
                                 {"action": "audio_set", "mode": "fixed", "source_id": "A", "audio_stream_index": 1},
                                 {"action": "audio_replacement_set", "id": "donor",
                                  "original": {"source_id": "A", "audio_stream_index": 1},
                                  "path": str(media), "replacement_source_id": "lav", "replacement_stream_index": 0,
                                  "relative_offset": "1/8000", "uncovered": "keep_original"},
                                 {"action": "audio_set", "mode": "mix"}
                             ]})["ok"]
    authored = read_project(mix)
    assert authored["audio"] == {"mode": "mix"}
    assert authored["fixed_audio"] == {"source_id": "A", "audio_stream_index": 1}
    assert authored["mix_lanes"][0]["target"] == {"kind": "camera", "angle_id": "A"}
    assert authored["audio_replacements"][0]["relative_offset"] == "1/8000"

    configured = folder / "configured.cut"
    assert author("create", {"kind": "multicam", "out_project": str(configured),
                             "angles": [{"id": "A", "file": str(with_sound)},
                                        {"id": "B", "file": str(camera)}],
                             "group_end": "1/5", "operations": [
                                 {"action": "camera_rename", "source_id": "A", "name": "Wide"},
                                 {"action": "camera_offset_set", "source_id": "B", "offset": "-1/10"},
                                 {"action": "camera_move", "angle_id": "B", "to_index": 0},
                                 {"action": "camera_microphone_set", "source_id": "A", "audio_stream_index": 1},
                                 {"action": "group_end_set", "to": "3/10"},
                                 {"action": "switch_audio_set", "at": "0", "source_id": "A", "audio_stream_index": 1},
                             ]})["ok"]
    setup = read_project(configured)
    b, a = setup["angles"]
    assert (b["id"], b["offset"], a["id"], a["name"], a["audio_stream_index"]) == ("B", "-1/10", "A", "Wide", 1)
    assert setup["group_range"]["to"] == "3/10"
    assert setup["switches"][0]["audio"] == {"source_id": "A", "audio_stream_index": 1}

    cleared_setup = folder / "cleared-setup.cut"
    assert author("edit", {"project_path": str(configured), "out_project": str(cleared_setup), "operations": [
        {"action": "camera_rename", "source_id": "A", "name": ""},
        {"action": "camera_microphone_set", "source_id": "A"},
        {"action": "switch_audio_clear", "at": "0"},
    ]})["ok"]
    cleared = read_project(cleared_setup)
    assert "name" not in cleared["angles"][1] and "audio_stream_index" not in cleared["angles"][1]
    assert "audio" not in cleared["switches"][0]

    silence_plan = subprocess.run([
        str(cli), "silence", "plan", "--project", str(mix), "--output", str(folder / "short.mov"),
        "--mode", "copy", "--audio", "pcm", "--audio-output", "downmix_mono", "--json"
    ], text=True, capture_output=True)
    assert silence_plan.returncode == 0, (silence_plan.stdout, silence_plan.stderr)
    preflight = json.loads(silence_plan.stdout)["preflight"]
    assert preflight["mode"] == "copy"
    assert preflight["audio_output"] == "downmix_mono"
    assert preflight["audio_lanes"][0]["action"] == "pcm"

    restored = folder / "restored.cut"
    assert author("edit", {"project_path": str(mix), "out_project": str(restored), "operations": [
        {"action": "audio_set", "mode": "fixed"}, {"action": "audio_replacement_remove", "id": "donor"}
    ]})["ok"]
    after = read_project(restored)
    assert after["audio"] == {"mode": "fixed", "source_id": "A", "audio_stream_index": 1}
    assert after["mix_lanes"] == authored["mix_lanes"]
    assert not after.get("audio_replacements")

    program = folder / "program-replacement.cut"
    assert author("create", {"kind": "multicam", "out_project": str(program),
                             "angles": [{"id": "A", "file": str(camera), "offset": "1/20"}],
                             "group_end": "1/5", "operations": [
                                 {"action": "audio_set", "mode": "replace", "path": str(media),
                                  "replacement_source_id": "sound", "replacement_stream_index": 0,
                                  "reference_source_id": "A", "relative_offset": "-1/10"}
                             ]})["ok"]
    program_audio = read_project(program)
    assert program_audio["audio"] == {"mode": "fixed", "source_id": "sound", "audio_stream_index": 0}
    assert program_audio["audio_sources"][0]["offset"] == "-1/20"
    suggest = subprocess.run([
        str(cli), "multicam", "sync", "suggest", "--project", str(program), "--reference-source-id", "A",
        "--replacement", str(media), "--replacement-stream", "0", "--program", "--metadata-only", "--json",
    ], text=True, capture_output=True)
    assert suggest.returncode == 0, (suggest.stdout, suggest.stderr)
    assert json.loads(suggest.stdout)["report"]["reference_source_id"] == "A"


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as root:
        exercise(Path(sys.argv[1]).resolve(), Path(root))
