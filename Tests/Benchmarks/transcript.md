# Transcript backend benchmark

Run from the repository root with the CLI inside an MPCut release bundle and a
local FFmpeg with AAC and libx264 encoding.

```sh
mkdir -p .build/transcript-checks
TMPDIR="$PWD/.build/transcript-checks" \
  python3 Tests/Benchmarks/transcript.py /path/to/MPCut.app/Contents/Helpers/mpcut \
  > .build/transcript-checks/benchmark.json
```

The default fixture is a three-hour multicam recording with two 25 fps picture
angles, two dedicated audio sources, two speakers, word-level evidence from
three or four tracks per word, camera switches, three routed sound sources,
and a reordered assembly. It uses generated tones and static pictures. Scripted transcript results enter
through the normal JSON import command, so the benchmark covers data handling
after recognition.

A full pass warms the binary, local file cache, and media analysis sidecars
created automatically by MPCut. Each of the five measured passes begins from
the same project bytes and runs every request in a fresh CLI process.
Plain and attached project inspection alternate order. The two use the same
source files and validate the same timeline and media coverage. The JSON
records fields that differ elsewhere in the inspection responses.
Project inspection is a broad CLI backend comparison that includes media
inspection and tier planning. It does not launch MPCut or measure window
presentation or preview readiness.

Transcript inspection loads the attachment. Reads exercise the first and
middle 50-word pages. Search exercises a recurring two-word phrase and a
later match page. The fixture checks IDs, routed sources, and exact output
timestamps in those pages. The warm-up also checks the distinct source-space
word count and order of the isolated guest track. Correction modifies the
same selection on every pass.
The history measurement reopens the corrected project through project
inspection and checks the undo delta on disk. A fresh search confirms that
the replacement persisted and points to the original word ID.

Reported wall time includes launching the CLI, running the operation, and
capturing JSON output. The child process CPU time and peak resident memory
come from macOS `/usr/bin/time -l`. Python decoding and result verification happen outside
the measurement. Fixture generation and import also happen outside the
measurement. The JSON records individual samples, medians, peak resident
memory, fixture dimensions, and SHA-256 digests of the inputs and release
binary.

Use `--seconds 80 --runs 1` for a quick check. Add `--progress` to see
measured timings as they finish on stderr. Keep fixture duration, run count,
machine, and FFmpeg version fixed when comparing release builds.

To measure the saved-project loader the editor uses, link the headless helper
against the Release objects left by `scripts/build-app.sh` and pass it to the
same benchmark. Build the helper immediately after packaging so it uses the
same MPCutCore revision as the CLI. For a release built in a different
checkout, pass that checkout as the helper build command's second argument.

```sh
bash Tests/Benchmarks/transcript_editor.sh .build/transcript-checks/transcript-editor
TMPDIR="$PWD/.build/transcript-checks" \
  python3 Tests/Benchmarks/transcript.py /path/to/MPCut.app/Contents/Helpers/mpcut \
    --editor-loader .build/transcript-checks/transcript-editor \
  > .build/transcript-checks/benchmark.json
```

The helper measures archive decoding, revision hashing, history
materialization, and collection of saved media references. Its timer excludes
process launch and reporting. It verifies that the history archive restores
the previous authoring state when loaded by the editor. Media indexing and
editor model initialization remain outside this measurement.
