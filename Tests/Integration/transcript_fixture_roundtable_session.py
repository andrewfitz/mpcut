#!/usr/bin/env python3
"""Prepare, recognize, import and score the roundtable conversation with real binaries.

    python3 Tests/Integration/transcript_fixture_roundtable_session.py --fixture FIXTURE \\
        --cli /path/to/mpcut --helper /path/to/transcriberrr --engine qwen3 --out DIR [--no-roles]

FIXTURE comes from transcript_fixture_roundtable.py. The score counts substituted,
missing and inserted words per utterance, words given to the wrong speaker after the
best one-to-one mapping of speakers, and the error of each utterance's first onset
and last offset. Use an empty output directory.
"""
import argparse
from collections import Counter, defaultdict
import json
import os
import re
import resource
import shutil
import subprocess
import time
from pathlib import Path

ROLES = {"host-lav": {"role": "isolated_mic", "speaker": "Host"},
         "guest-lav": {"role": "isolated_mic", "speaker": "Guest"},
         "wide": {"role": "mixed_audio"}, "close": {"role": "mixed_audio"}}


def norm(text):
    return re.sub(r"[^a-z0-9']", "", text.lower().replace("’", "'"))


def cli(binary, env, verb, *args, request=None, check=True):
    cmd = [binary, "transcript", *verb.split(), "--json", *map(str, args)]
    if request is not None:
        cmd.append("--stdin")
    proc = subprocess.run(cmd, text=True, capture_output=True, env=env, timeout=240,
                          input=json.dumps(request) if request is not None else None)
    try:
        result = json.loads(proc.stdout)
    except Exception:
        raise SystemExit(f"non-JSON from {cmd}: rc={proc.returncode}\n{proc.stdout[:500]}\n{proc.stderr[:500]}")
    if check and proc.returncode:
        raise SystemExit(f"{cmd} failed: {json.dumps(result)[:800]}")
    return result


def align(ref, hyp):
    """Levenshtein alignment. Returns list of (ref_index|None, hyp_index|None)."""
    n, m = len(ref), len(hyp)
    cost = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        cost[i][0] = i
    for j in range(m + 1):
        cost[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost[i][j] = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1,
                             cost[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]))
    pairs, i, j = [], n, m
    while i or j:
        if i and j and cost[i][j] == cost[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            pairs.append((i - 1, j - 1)); i -= 1; j -= 1
        elif i and cost[i][j] == cost[i - 1][j] + 1:
            pairs.append((i - 1, None)); i -= 1
        else:
            pairs.append((None, j - 1)); j -= 1
    return pairs[::-1]


def speaker_mapping(votes):
    """Maximize correct words over one-to-one mappings of known labels."""
    names = sorted({name for counts in votes.values() for name in counts})
    best = {0: (0, {})}
    for label, counts in votes.items():
        updated = best.copy()
        for mask, (total, mapping) in best.items():
            for index, name in enumerate(names):
                bit = 1 << index
                if mask & bit or not counts[name]:
                    continue
                score = total + counts[name]
                if score > updated.get(mask | bit, (0, {}))[0]:
                    updated[mask | bit] = (score, mapping | {label: name})
        best = updated
    return max(best.values(), key=lambda result: result[0])[1]


def score(result, truth):
    rate = result["sample_rate"]
    speakers = {s["id"]: s.get("name") or s["id"] for s in result["speakers"]}
    words = [w for w in result["words"] if norm(w["text"])]
    utterances = truth["utterances"]
    # Assign each emitted word to the utterance whose window holds its midpoint; prefer same-text utterance on overlap.
    buckets = {u["id"]: [] for u in utterances}
    outside = []
    for w in words:
        mid = (w["start_sample"] + w["end_sample"]) / 2 / rate
        hits = [u for u in utterances if u["start"] - 0.4 <= mid <= u["end"] + 0.4]
        if not hits:
            outside.append(w); continue
        if len(hits) > 1:
            name = speakers.get(w.get("speaker_id"))
            token = norm(w["text"])
            hits.sort(key=lambda u: (token not in [norm(x) for x in u["text"].split()], u["speaker"] != name))
        buckets[hits[0]["id"]].append(w)
    total = sub = dele = ins = spk_err = matched = 0
    onset_err, offset_err, detail = [], [], []
    # Best one-to-one speaker mapping by votes.
    votes = defaultdict(Counter)
    rows = []
    for u in utterances:
        ref = [norm(x) for x in u["text"].split() if norm(x)]
        hyp = buckets[u["id"]]
        pairs = align(ref, [norm(w["text"]) for w in hyp])
        rows.append((u, ref, hyp, pairs))
        for r, h in pairs:
            if r is not None and h is not None and ref[r] == norm(hyp[h]["text"]):
                label = hyp[h].get("speaker_id")
                if label is not None:
                    votes[label][u["speaker"]] += 1
    mapping = speaker_mapping(votes)
    for u, ref, hyp, pairs in rows:
        total += len(ref)
        s = d = i = 0
        wrong = []
        for r, h in pairs:
            if r is None:
                i += 1
            elif h is None:
                d += 1
            elif ref[r] != norm(hyp[h]["text"]):
                s += 1
            else:
                matched += 1
                if mapping.get(hyp[h].get("speaker_id")) != u["speaker"]:
                    spk_err += 1; wrong.append(hyp[h]["text"])
        sub += s; dele += d; ins += i
        if hyp and not u["overlaps"]:
            onset_err.append(abs(hyp[0]["start_sample"] / rate - u["start"]))
            offset_err.append(abs(hyp[-1]["end_sample"] / rate - u["end"]))
        detail.append({"id": u["id"], "ref": len(ref), "sub": s, "del": d, "ins": i, "speakerWrong": wrong,
                       "hyp": " ".join(w["text"] for w in hyp)})
    ins += len(outside)
    obs = {}
    for w in result["words"]:
        for o in w["observations"]:
            obs.setdefault(o["track_id"], {}).setdefault(o["evidence"], 0)
            obs[o["track_id"]][o["evidence"]] += 1
    names = {t["id"]: t["source_id"] for t in result["tracks"]}
    return {"refWords": total, "hypWords": len(words), "matched": matched, "sub": sub, "del": dele, "ins": ins,
            "wer": round((sub + dele + ins) / total, 4), "speakerErrors": spk_err,
            "speakerMap": mapping, "speakers": speakers, "outsideWords": [w["text"] for w in outside],
            "meanOnsetErrMs": round(1000 * sum(onset_err) / max(1, len(onset_err)), 1),
            "maxOnsetErrMs": round(1000 * max(onset_err, default=0), 1),
            "meanOffsetErrMs": round(1000 * sum(offset_err) / max(1, len(offset_err)), 1),
            "maxOffsetErrMs": round(1000 * max(offset_err, default=0), 1),
            "trackWords": {t["source_id"]: len(t.get("words", [])) for t in result["tracks"]},
            "observations": {names.get(k, k): v for k, v in obs.items()}, "detail": detail}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--cli", required=True)
    p.add_argument("--helper", required=True)
    p.add_argument("--engine", default="qwen3")
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--no-roles", action="store_true")
    p.add_argument("--fixture", type=Path, required=True)
    p.add_argument("--project", default=None)
    p.add_argument("--no-score", action="store_true")
    args = p.parse_args()
    out = args.out
    if out.exists() and any(out.iterdir()):
        raise SystemExit(f"{out} is not empty. Choose a new directory for this run.")
    out.mkdir(parents=True, exist_ok=True)
    for f in args.fixture.iterdir():
        if f.is_file():
            shutil.copy2(f, out / f.name)
    project = out / args.project if args.project else next(out.glob("*.cut"))
    env = os.environ | {"MPCUT_TRANSCRIBERRR_HELPER": args.helper}
    timing = {}
    inventory = cli(args.cli, env, "tracks list", "--project", project)
    tracks = inventory["sessions"][0]["tracks"]
    options = {"engine": args.engine}
    if not args.no_roles:
        options["track_options"] = {t["id"]: ROLES[t["source_id"]] for t in tracks if t["source_id"] in ROLES}
    t0 = time.monotonic(); c0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    job = cli(args.cli, env, "job prepare",
              request={"project_path": str(project), "job_directory": str(out / "jobs"), "options": options})
    c1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    timing["prepareWall"] = round(time.monotonic() - t0, 3)
    timing["prepareCPU"] = round(c1.ru_utime + c1.ru_stime - c0.ru_utime - c0.ru_stime, 3)
    (out / "prepared.json").write_text(json.dumps(job, indent=1))
    t0 = time.monotonic(); c0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    for session in job["sessions"]:
        with open(out / "events.jsonl", "ab") as events, open(out / "helper.stderr", "ab") as err:
            subprocess.run([args.helper, *session["command"][1:]], stdout=events, stderr=err,
                           env=env, check=True, timeout=240)
    c1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    timing["sessionWall"] = round(time.monotonic() - t0, 3)
    timing["sessionCPU"] = round(c1.ru_utime + c1.ru_stime - c0.ru_utime - c0.ru_stime, 3)
    timing["sessionExit"] = 0
    # The import removes the session output once the result is attached.
    result = json.loads(Path(job["sessions"][0]["output"]).read_text())
    t0 = time.monotonic()
    attached = cli(args.cli, env, "attachment import", "--project", project, "--job-id", job["id"],
                   "--job-directory", out / "jobs", "--out-project", out / "attached.cut")
    timing["importWall"] = round(time.monotonic() - t0, 3)
    (out / "attached.json").write_text(json.dumps(attached, indent=1))
    (out / "result.json").write_text(json.dumps(result))
    if args.no_score:
        print(json.dumps(timing)); return
    truth = json.loads((args.fixture / "truth.json").read_text())
    report = score(result, truth) | {"timing": timing, "engine": args.engine, "roles": not args.no_roles}
    (out / "score.json").write_text(json.dumps(report, indent=1))
    brief = {k: v for k, v in report.items() if k != "detail"}
    print(json.dumps(brief, indent=1))
    for row in report["detail"]:
        if row["sub"] or row["del"] or row["ins"] or row["speakerWrong"]:
            print("  !", json.dumps(row))


if __name__ == "__main__":
    main()
