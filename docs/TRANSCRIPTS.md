# Work with transcripts in MPCut

Use a transcript to find dialogue, compare takes, review word-based cuts, queue excerpts, or deliver subtitles. MPCut can import transcripts without a recognition provider. To create a transcript from audio, use the Transcriberrr helper in the desktop app or use `transcript job run` for a prepared CLI job.

## Import and bind a transcript

Open **View → Toggle Transcript** (⌥⌘T), click **Transcript** in the sequence toolbar, or open the multicam inspector’s **Transcript** tab. Choose **Import Transcript…** and select Transcriberrr JSON, SubRip (.srt), or WebVTT (.vtt). Review each track’s binding to a recording or multicam source, absolute audio stream index, and optional channel. Channel indexes start at zero. For a sequence, confirm the recording used to make the transcript. For multicam, confirm which source contributed each track.

Drag the divider to set the panel width. Use the vertical-arrow button in the panel header to extend it beside the timeline. Click it again to tuck the panel above the timeline and restore the timeline’s full width.

Word-timed JSON supports word-level selections. A segment-only JSON entry or subtitle cue has the timing of the whole entry. A cue with an unknown presentation-clock origin is approximate. Set a known origin in the binding review if the clock needs adjustment. Where merged JSON has several possible sources for a line, inspect the candidate tracks before relying on its source time.

MPCut exports transcript JSON with `schema_version` equal to `2`. Track, word, and binding fields use snake_case, including `session_start`, `speaker_id`, and `audio_stream_index`. Transcriberrr sample-timed output uses its own provider schema with `version` equal to `1` and a `sample_rate`. MPCut can import that output and preserve its track timing and observations. [MPCut transcript JSON schema](schema/transcript-document-v2.schema.json)

The copy a project keeps in its `.transcripts` directory uses a compact, compressed form of the same document with `schema_version` equal to `3`. It is not meant for reading or editing by hand. Export the transcript to get the version 2 JSON. MPCut reads both versions wherever it accepts transcript JSON. [Stored transcript schema](schema/transcript-document-v3.schema.json)

Copying a project, saving an excerpt or writing a recovery draft shares a stored transcript’s storage on APFS in place of copying it. When you save over an existing project that is the only `.cut` file in its folder, MPCut removes files in its `.transcripts` directory that nothing has referred to for a day. Recognition jobs give up their session output once the result is attached. An attached job whose result the project has entirely replaced is removed after 30 days without changes, and can be staged and recognized again from the media.

A transcript does not carry audio levels. MPCut measures them into each recording’s analysis sidecar, and the selection waveform is drawn from the recording. A project made by an earlier build keeps the levels inside its stored transcript, which can make that file hundreds of megabytes for a long recording. To rewrite it in the compact form, import the stored file over its own attachment: `mpcut transcript attachment import --project FILE.cut --attachment-id ID --transcript FILE.cut.transcripts/SHA.json --in-place`. The bindings stay as they are, and saving removes the earlier file from the `.transcripts` directory. A build from before this change cannot open the compact form, so copy the project and its `.transcripts` directory first if an older build still needs them.

The transcript options menu includes **Inspect Attachment…**, **Rebind Transcript…**, **Recover Transcript Store…** for an unavailable attachment, and **Detach Transcript**. Inspect the binding if a file moved, went offline, or changed. Keep the saved `Interview.cut` and its companion `Interview.cut.transcripts` directory together, along with the media the project references. The companion directory holds the imported transcript assets, so deleting the original subtitle or JSON does not break a saved attachment. An exported transcript is a separate deliverable. Keep the project and companion store to retain bindings and authored work.

## Generate a transcript

Choose **Transcribe Audio…** in the transcript pane. MPCut opens the installed Transcriberrr app in the background if needed and reads the project’s audio streams while it loads the available engines. Select the recordings to include and choose an engine. Open **Stream settings** to set a recording’s role, channel, or speaker hint. **Recognition options** contains model and language overrides, **Identify speakers in mixed audio** with an optional number of **Expected speakers** where the engine supports it, and **Download missing models**. A blank channel mixes that stream’s channels to mono. The default multicam session includes off-air camera audio as well as the program microphone. Picture-only sources can contribute camera coverage.

When you open transcription setup for a Zoom video or mixed audio file, MPCut asks Transcriberrr to find participant recordings from the same recording segment. Choose **Skip search** to continue without them. When it finds separate recordings for multiple speakers, MPCut selects **Use Zoom participant audio** automatically. For a single speaker, you can select it manually. Open **Edit speaker names** to see each microphone’s filename and change its transcript label. Clear the option to transcribe everyone audible in the mix, including participants without separate recordings. The words seek and edit against the loaded recording. If a participant file goes offline, Transcription Jobs shows which microphone needs attention. Restore the file and retry to complete its transcript.

The helper must report `session_schema_version: 1` in its capabilities. To point MPCut at a development helper, set `MPCUT_TRANSCRIBERRR_HELPER` to the absolute path of its executable before launching MPCut. The installed helper determines which engines, models, language settings, and speaker limits are available.

Open **Transcription Jobs…** to check progress, coverage, and warnings by track. Cancel a running desktop job in MPCut. For a partial, failed, or interrupted attempt, review the warning and retry after resolving the issue. Valid per-track recognition can be reused when the media, stream, channel, engine, model revision, and recognition settings still match. After a multicam sync change, use **Reconcile Transcript** on the affected generated attachment to update alignment. Review any corrections or track matches flagged as missing or ambiguous after a new result.

## Find and verify dialogue

| View | What the time refers to | Typical use |
| --- | --- | --- |
| **Source** | The recording’s presentation clock | Find outtakes, pre-roll, or dialogue on an off-air microphone. |
| **Group** | The synchronized multicam clock | Compare the same moment across sources. |
| **Current Cut** | The output timeline in playback order | Find retained or repeated dialogue, check routed program audio, and export timed subtitles. |

Scroll through the full transcript in one pane. Timestamps and speaker names appear inline at the start of each turn. Enter a phrase in **Find dialogue** and press Return. The match arrows jump to each occurrence in context. Filter by speaker, source, track, multicam audio lane, or occurrence where available, and turn on **Include Inferred Track Matches** when inspecting possible matches. Click a word or cue to seek. Drag or Shift-click an endpoint to extend a selection. **Follow Playback** keeps the dialogue view in step with playback. Use **Play Context** to hear surrounding audio. In Source, it opens a Source Context window on the bound recording and stream, including dialogue before the synchronized group starts.

In a multicam Mix, Current Cut includes words from every on-air lane. When the same word is heard on several lanes, MPCut shows a single occurrence and lists the other lanes in its evidence. Lane names and colour chips appear in passages, track filters, job setup, and coverage. Deleting time affects every lane. Review the other speech listed in the edit plan before applying it. Tightening a pause requires transcript evidence and no speech on every on-air lane.

Use **Inspect Word Evidence** to review recognized observations and inferred or candidate tracks. Recognized speech supplies wording for a track. In **Review → Coverage Gaps**, Source and Group show input track status and known gaps. Current Cut shows gaps in the routed program. Click a timed Group or Current Cut gap to seek there. Review offline, unbound, skipped, or failed tracks and ambiguous matches before treating a missing line as evidence of silence.

## Review an edit or build a quote

- **Selection** can mark the phrase or the gap between two words. Expand to nearby words, a sentence, a speaker turn, or a preceding question. Review a split, start or end trim, deletion, or tightened pause. Use **Protect Pause…** to save a pause you intend to keep.
- **Correct Text…** changes wording. Speaker tools rename, assign, split, or merge speakers. Word evidence can record an accepted or rejected track match. **Named Selects and Corrections…** shows saved changes and their anchor status.
- **Review → Compare Takes…** finds alternate readings with context. **Align Script…** accepts pasted or imported script text and suggests readings per beat. Check qualifiers and surrounding speech. **Review Restarts and Fillers…** offers candidates to accept or dismiss before reviewing deletions.
- **Save Named Select…** keeps a source passage available for later use. **Add to Ordered Selects** collects passages across attachments. Open **Selects** to reorder them and review assembly, insertion at the playhead, replacement of a selected range, or a single queued excerpt.
- In multicam, **Switch Angle at Dialogue…** proposes a picture switch. You can remember a preferred angle for a speaker. Review the program soundtrack and selected angle at the boundary.
- **Copy Quote with References** copies wording and locations. **Queue Excerpt…** captures an editable range with its media, camera switches, and audio routing. Render it through the export queue when ready.

Before committing a cut, check the requested speech time, proposed media boundary, changed duration, affected speech, and export tier. The review can offer exact timing, nearest media-frame timing, or a copy-safe boundary. Exact word timestamps can fall between media frames or away from packet-copy boundaries. Read the plan again after changing the edit or rebinding the transcript.

Nearest media-frame timing can move a boundary by up to half a frame. When a deleted word touches the next word, that leaves up to half a frame of it in the program. Current Cut does not list a remainder that short, and search does not find it. Use exact timing or a frame nudge to move the boundary.

Choose **Export Transcript…** in the attachment’s options to write native JSON, readable text, SubRip, or WebVTT. Choose **Current Cut** for captions timed to the edited output and **Source** for the recording’s own timing. Transcript export creates a separate text or data file. Use media export to render an excerpt or movie.

## Use the command line

Run `mpcut help transcript words search --json` for the request fields. Each action accepts flags, or one snake_case JSON object with fields such as `project_path` and `audio_stream_index` via `--input REQUEST.json` or `--stdin`. Add `--json` for structured output. With flag input, `--transcript -` reads the transcript itself from stdin.

### Attach and search

Given `Interview.wav` and `Interview.json`, inspect the stream first and substitute its absolute index for `0` if needed.

```sh
mpcut transcript tracks list --file Interview.wav --json
mpcut transcript attachment import --file Interview.wav --audio-stream-index 0 --transcript Interview.json \
    --out-project Interview-text.cut --json
mpcut transcript words search --project Interview-text.cut --space current_cut \
    --query "expected benefit" --limit 5 --json
mpcut transcript export --project Interview-text.cut --space current_cut --output Interview.srt
```

For an existing project, use `--project FILE.cut` on import and supply `--out-project FILE.cut` or `--in-place`. Inspect a raw transcript with `transcript attachment inspect --transcript FILE` or existing attachments with `transcript attachment inspect --project FILE.cut`. Add `--track-id ID` to page through the activity frames of a track in a transcript that still carries them. Use `transcript attachment bind` to update association or origin and `transcript attachment detach` to remove an attachment. To normalize a bare import to JSON, use `transcript attachment import --file MEDIA --transcript FILE --output FILE.json`.

`transcript words read`, `transcript words search`, `transcript words locate`, `transcript words compare`, `transcript script align`, `transcript words suggest`, and `transcript export` can operate across a project's attachments. Use `--attachment-id ID` for one attachment. Filter by the selected view and, where applicable, speaker, file, source, track, audio lane (`--lane-id ID`), clip ID, assembly index, and inferred evidence. Lane-aware CLI and MCP readouts use the IDs from the multicam project and report `lane_id`, `lane_order`, `lane_label`, and `lane_color_slot`. A speaker on several lanes has a `lanes` list, and words heard on additional lanes have `heard_on_lane_ids`. Use `lane_id` in MCP and JSON CLI requests. Exported transcript JSON stays on schema version 2. Pass `next_offset` as the next request’s `offset`. `transcript words locate --word-id ID` lists projected occurrences. Word IDs are scoped to the attachment, and a repeated word can have multiple occurrence IDs on the same output timeline.

Search matches a phrase word for word and ignores case, accents and punctuation. A number matches however it is written: `200 hours` finds “two hundred hours”, `fifteen hundred` finds “1,500”, `1999` finds “nineteen ninety nine”, `three thirty` finds “3:30”, `fifty percent` finds “50%” and `30 second clip` finds “thirty second clip”. An ordinal matches only an ordinal, so `first` finds “1st” and `second` does not find “two”. This works in each language the system's number rules cover, with that language's own words, ordinal forms and names for signs such as “$” and “%”. The language is the one the transcript declares, or else the one its words are written in. `transcript words compare` and `transcript script align` match words as written. When nothing matches, a compound is tried closed and open, so `rangefinder` finds “range finder”.

### Stage recognition and import the result

```sh
mpcut transcript provider capabilities --json
mpcut transcript tracks list --project Interview.cut --json
mpcut transcript job prepare --project Interview.cut --job-directory ./jobs --json > prepared.json
```

For an interview recorded with a guest lavalier and a room microphone, use the track IDs from `transcript tracks list` to label the inputs before staging. In place of the last command above, save the following as `microphones.json`, substitute the two actual IDs, then run `mpcut transcript job prepare --input microphones.json --json > prepared.json`. A channel index selects one channel within a stream. Omit it to mix that stream to mono.

```json
{
  "project": "Interview.cut",
  "job_directory": "./jobs",
  "options": {
    "track_options": {
      "GUEST_TRACK_ID": {"role": "isolated_mic", "speaker": "Guest", "channel": 0},
      "ROOM_TRACK_ID": {"role": "mixed_audio"}
    }
  }
}
```

Review the receipt’s `id` and each entry in `sessions`. It contains `manifest`, `output`, and the command to run. Run the supplied command for each manifest, for example `transcriberrr session --manifest /path/to/session.json --offline --jsonl`. A synchronized group produces one manifest. In an ordinary sequence, unrelated recordings can produce several. Once the external recognizer writes the result files, import them using the same job directory.

```sh
job=$(jq -er '.id' prepared.json)
mpcut transcript attachment import --project Interview.cut --job-id "$job" --job-directory ./jobs \
    --out-project Interview-text.cut --json
mpcut transcript job status --job-id "$job" --job-directory ./jobs --json
```

`transcript job prepare` stages 16 kHz audio and writes manifests. Use `transcript job run --job-id UUID` with the same job directory for managed recognition. Alternatively, invoke the reported provider command manually. When launched manually, the recognition process belongs to the shell that launches it. Interrupt that process there to stop it. The CLI `transcript job cancel` action updates the job record. Use `transcript job retry` to stage work again and run the returned provider commands. Job import checks the result against the prepared inputs and restores their bindings. Once a result is attached, MPCut removes the staged audio of every track that finished. It also removes the session output when the job kept a result for each recognized track, as a job run by MPCut does. Importing such a job a second time reports `transcript_output_removed`; run `transcript job retry` first. Independently generated results can also be imported with `--transcript FILE`.

### Plan, apply, correct, and queue

Use `transcript words select` to resolve bounds, `transcript edit plan` to inspect a proposed edit, and `transcript edit apply` to commit the reviewed plan. This example deletes the first word of a unique search match. It uses `jq` to extract the word and occurrence IDs. For repeated matches, review the search results and choose the intended occurrence. Use the same `space` as the response that supplied it.

```sh
mpcut transcript words search --project Interview-text.cut --space current_cut \
    --query "expected benefit" --limit 1 --json > match.json
word=$(jq -er 'select(.total == 1) | .items[0].words[0].word_id' match.json)
occurrence=$(jq -er 'select(.total == 1) | .items[0].words[0].id' match.json)
mpcut transcript edit plan --project Interview-text.cut --space current_cut --action delete \
    --first-word-id "$word" --first-occurrence-id "$occurrence" --output review.json --json
```

Read `review.json` and check the occurrence, affected speech and resolved media boundaries. To apply that plan to a new copy of the project, run the following command.

```sh
mpcut transcript edit apply --project Interview-text.cut --plan-file review.json \
    --out-project Interview-reviewed.cut --json
```

If the project has multiple attachments, add `--attachment-id ID` for this single-attachment example. For compound edits use JSON with a `request` containing `action` and ordered `selections`. Give each cross-attachment selection its `attachment_id` and use occurrence IDs wherever words repeat. The edit request accepts `split`, `trim_start`, `trim_end`, `delete`, `tighten`, `assemble`, `insert`, `replace`, `switch_angle`, and `queue`. A stale reviewed plan is rejected. Refresh the read and review a fresh plan.

Use `transcript words correct` with a typed `change`, such as `{"rename_speaker":{"speaker_id":"speaker-0","name":"Guest"}}`. For span changes such as `replace_text`, add a selection. Other changes include assigning, splitting, and merging speakers, recording a track-match override, saving a named select, and protecting a pause. Use `transcript excerpt queue` to save an editable excerpt snapshot beside the source project or supply `--out-project` to name it. Render the snapshot with `mpcut export project render --project`.

## Use MCP

Enable local control in the MPCut app for live workflows and connect the packaged `mpcut-mcp` helper. Start with the `project_handle` from `project_windows_list` or `project_open`. Use the corresponding `transcript_file_*` tool for saved-file workflows. [MCP setup and agent guide](MCP-AGENT-GUIDE.md)

| Tool | Actions and receipts |
| --- | --- |
| `transcript_file_words_search`, `transcript_file_attachment_import` and other saved-file operations | Submit the CLI JSON payload under `request` with a fresh UUID `operation_id`. Poll `file_job_status_read` by `job_id` and page large results with `file_job_result_read`. |
| `transcript_editor_attachment_import`, `transcript_editor_attachment_bind`, `transcript_editor_attachment_detach`, `transcript_editor_attachment_export` | Supply the revision and result pins required by each tool. Export returns an output job. |
| `transcript_provider_capabilities_read`, `transcript_tracks_list`, `transcript_editor_job_start`, `transcript_editor_job_status_read` | Choose inputs, start recognition and poll the durable job ID. |
| `transcript_editor_words_search`, `transcript_editor_occurrences_locate`, `transcript_editor_coverage_read`, `transcript_editor_occurrence_seek` | Find dialogue, verify coverage and navigate to an exact occurrence. |
| `transcript_editor_edit_plan`, `transcript_editor_edit_apply`, `transcript_editor_excerpt_queue` | Review boundaries, then commit the edit or capture the excerpt. |

### Review one live quote

1. Get `revision` from `project_editor_state_read` and `transcript_revision` from `transcript_editor_attachments_list`. For one attachment, retain its `attachment_id` and `result_id`. For a project-wide search, omit both. Pass the search result’s `attachment_results` map as `expected_attachment_results` when requesting another page.
2. Call `transcript_editor_words_search`, `space: "current_cut"`, and the quote as `query`. Pass the prior `next_offset` when paging. For a specific repeated match, use the `word_id` and `id` from each endpoint in the chosen result as the word and occurrence IDs in the selection.
3. Call `transcript_editor_edit_plan`, the revision pins and result identity, and `edit: {"action":"queue","selections":[…],"name":"Transcript quote"}`. Review the returned boundaries, affected speech, duration, and tier. Use the returned `plan_id` with `transcript_editor_excerpt_queue` and a fresh operation ID. For a timeline edit, call `transcript_editor_edit_apply` with its reviewed plan. Reread and replan if a revision or result changed.
4. Use `export_queue_plan` to preflight the queued item or `export_queue_render` to write it. Poll `export_editor_job_status_read`. Use the walkthrough to exercise import, occurrence selection, plan review, queueing, export, and file inspection.

Reuse an operation ID only for a retry with identical arguments. Timeline and transcript revisions are separate. See the reference for required fields and supported clocks on each action. [Transcript MCP schemas](MCP-REFERENCE.md#transcripts) · [Runnable MCP walkthrough](mcp_walkthrough.py)

## Verify the workflow

The CLI tests generate disposable media and check staging and job import with a stub provider, binding and clock behavior for JSON/SRT/WebVTT, repeated occurrences, stale-plan rejection, and multi-attachment edits. The verification guide shows how to run the spoken fixtures, native-window and live MCP checks, and compare exported media. [Transcript verification](TRANSCRIPT-VERIFICATION.md)
