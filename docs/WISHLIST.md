# MPCut editing wish list

Item numbers match the original wishlist. The implementation column describes what is available in this source tree. Use the installed build’s CLI help and MCP discovery to confirm its public contracts. [Desktop guide](USAGE.md) · [CLI guide](CLI.md) · [Agent guide](MCP-AGENT-GUIDE.md)

## Dialogue and takes

| # | Wishlist item | Implementation |
|---|---|---|
| 1 | Import and search timed dialogue | Import Transcriberrr JSON, SRT and WebVTT. Search by phrase, speaker or track, and inspect the evidence for dialogue or camera coverage. |
| 2 | Read dialogue in cut order | Current Cut projects retained words onto output occurrences, including repeats, partial words and routed audio. |
| 3 | Keep named selects | Save a named source interval independently of its timeline use, including visual-only media. Reuse the select in an ordered edit. |
| 4 | Find takes separated by pauses | Review detected pauses and retained takes. Add missed take boundaries or remove manual splits before queueing. |

**Transcribe Multicam** submits audio-bearing camera and recorder streams, including off-air audio. After a sync change, **Reconcile Transcript** updates alignment and reuses recognition where the inputs still match. [Transcript guide](TRANSCRIPTS.md) · [Take candidates](USAGE.md#find-and-shorten-pauses)

## Cutting and pacing

| # | Wishlist item | Implementation |
|---|---|---|
| 5 | Choose copy-safe cuts | The tier badge and export preflight report eligibility. A nearest-cut prompt shows the requested and resolved positions and movement. |
| 6 | Set one pause’s retained duration | Set a total duration for a detected pause and read back the aligned duration. Multicam settings can target one assembly occurrence. |
| 7 | Review and nudge a hard cut | Audition an existing sequence join, multicam switch or assembly join and replay it. Use the existing trim or switch controls to adjust it. |
| 8 | Apply an ordered range plan | Insert an ordered list of raw ranges and named selects, or replace a sequence interval, in one history step. Repeated source ranges remain separate uses. |

[Sequence editing](USAGE.md#edit-a-sequence) · [Pause controls](USAGE.md#find-and-shorten-pauses) · [Export quality](USAGE.md#check-export-quality)

## Multicam

| # | Wishlist item | Implementation |
|---|---|---|
| 9 | Suggest sync offsets | Review comparable timestamp offsets and waveform matches. Available samples across the recording provide drift evidence before you choose an offset. |
| 10 | Put several files on one angle | Add recordings with their own locations and coverage on the group clock. The angle retains the real gaps between files. |
| 11 | See camera and mic coverage | Review the proposed camera and routed sound through the next switch, with group intervals for missing coverage. |
| 12 | Change the angle on one replay | Override picture on a chosen assembly occurrence. Restore the group switches for that occurrence when needed. |

[Desktop multicam editing](USAGE.md#edit-a-multicam-project) · [Saved multicam operations](CLI.md#work-with-multicam-projects)

## Revisions and delivery

| # | Wishlist item | Implementation |
|---|---|---|
| 13 | Map source and output ranges | Map half-open intervals between source and sequence or group and assembly clocks. Each intersecting occurrence appears separately. Select a retained history state for older review notes. |
| 14 | Explain changes since a revision | Compare the current state with a retained history entry, or compare two saved projects. Read changed project fields and the affected occurrence ranges. |
| 15 | Name, inspect and revise queue entries | Inspect captured files and trims, rename an entry or recapture the current edit from replacement or enclosing marks. |
| 16 | Export a cut map | Export JSON reports individual timeline occurrences, including adjacent uses in the same render segment. Desktop project and selection export can save the result beside the media. |

[Project History](USAGE.md#edit-a-sequence) · [Export queue](USAGE.md#export-several-ranges-from-the-timeline) · [Export modes and results](EXPORT-MODES.md)

[Core benchmarks for camera lookup, timeline mapping, and waveform matching](../Tests/Benchmarks/wishlist.md)

## Verify the wishlist workflows

Run the Swift suite with `swift test`. To exercise the desktop menus and live MCP tools against the same signed app, generate the [spoken fixture](../Tests/Integration/transcript_fixture.md), then run the following from the repository root with Go on your path. If the app build downloaded Go, use the binary under `.build/go*/go/bin/`.

```sh
app="$PWD/dist/MPCut.app"
python3 Tests/Integration/mcp_bundle.py "$app"
(cd mcp && go test -v ./integration -run '^TestLiveBundle$' -count=1 -args -bundle="$app" -transcript-fixture=/tmp/mpcut-spoken)
```

### Previously recorded fixture checks

- Scanning the bundled quiet-pause movie with a 0.3-second minimum and 0.1-second retained pause returned one pause, one removal, and two retained clips. This exercises the existing take-candidate workflow.
- A temporary ProRes sequence with three three-frame occurrences, including a reused passage, exported nine copied frames and zero encoded frames. The second and third occurrences were contiguous in source time, so the CLI reported two resolved export segments. This is why an occurrence-level cut map needs timeline information as well as the render result.
