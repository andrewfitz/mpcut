# App-wide naming cutover

**Deliver one release with a single MPCut vocabulary.** The desktop app, CLI, MCP discovery and handlers, file jobs, preferences, native documents, reports and shipped integrations change together. The naming convention describes the public vocabulary. This plan covers implementation order, remaining contract decisions and release tests. [Feature map](NAMING-CONVENTION.md)

## Pre-cutover inventory

| Finding | Decision |
|---|---|
| All 96 MCP tools have a destination in the feature map. Their schemas contain 633 top-level property declarations using 173 distinct spellings. The project has 17 CLI help topics, including the multicam workflow guide, and 15 shared editor preferences. | Track fields and behaviors as well as entry points. A matched tool count alone cannot establish coverage. |
| Sixteen tools declare an enum named `action` or `operation`. Others select behavior through `kind`, `mode`, an output path, input type or dry-run flag. For example, `transcript_read` can seek and `file_silence` can write media. | Give reads, navigation, project edits, queue mutations and file writes explicit destinations. Retain a typed selector for closely related variants with the same effect. The families in the naming map are design groupings; publish only fully specified callable contracts. |
| The live editor, file bridge and CLI each interpret arguments. The Go helper discovers tools from the bundle. A schema-only rename can advertise a tool whose handler or bundled CLI still expects another spelling. | Change declaration, validator, dispatch, argument builder, result writer, consumer and fixtures in the same feature slice. Verify the packaged helper against the packaged app. |
| `mode`, `source`, `track`, `range` and `time` acquire different meanings across editing, monitoring and export. The visible track number, absolute stream index, and sequence track ordinal can refer to different things. | Use the owning object and explicit meaning. For example, use `export_mode`, `source_id`, `audio_stream_index`, `track_ordinal`, `group_time` or `assembly_time`. Keep scope in the parent where it is unambiguous. |
| MPCut already contains native compatibility paths: CLI shorthand, the old total-silence-padding flag and report field, a preference fallback, multiple native project layouts and sidecar fallbacks. | Remove these paths at cutover. Use a single current native document schema for both sequence and multicam, including still-bearing projects. Validate the current schema before interpreting fields. |
| Existing formats also contain externally owned names: MCP transport, codec metadata, host interchange formats and provider payloads. | Keep protocol-defined spellings at their boundaries. Apply the MPCut vocabulary in the adapter and the public MPCut contract. An operating-system file alias or a codec name is not an API compatibility shim. |

**Impact on existing work:** scripts using retired names must be edited. Old MPCut-native documents, drafts and reports with retired layouts will not open or replay in the new release. Renamed preferences start at their documented defaults. Rebuild incompatible analysis caches from the underlying media. A rejected input must leave its original file intact. Treat authored metadata separately from regenerable analysis; never discard it as part of an automatic cache rebuild.

## Implementation order

### 1. Close the contract inventory

Start from the checked-in MCP catalog, CLI parser and help, preference declarations, native schemas, app dispatch and output encoders. Record one row per operation, including every selector branch. Record input keys, required combinations, enum values, defaults, units, clock, identity type, output keys, errors, owner and side effects. Include nested JSON, stdout/stderr and progress events, job status/results, export manifests, menu commands, accessibility and undo labels.

Resolve each many-to-one or one-to-many mapping before publishing names. In particular, separate transcript text reads from seeking, camera takes from edits to existing switches, still placement insertion from picture replacement, editor state from file inspection, and export preflight from rendering. Use one representation for an action on a surface: either a callable tool or a tool plus a required selector. A conceptual fully qualified action name does not create a second callable alias.

**Done when** each existing behavior has one canonical destination or an explicit removal decision. Every proposed name has a distinct dispatch owner. Each result type identifies its producing action and consumers. Use the existing schema and CLI help sources for implementation; the inventory is a review artifact.

### 2. Establish native types, persistence and shared settings

Define canonical Swift names and explicit coding keys at serialization boundaries. Unify native project encoding and decoding, history snapshots, drafts, transcript attachments/results/sessions, reports, sidecar manifests and analysis sections. Keep a current format discriminator so unsupported data fails before mutation. Update schema files, example documents and fixtures alongside the reader and writer. Read only current preference keys. Cover saved window layout and transcript UI settings as well as the 15 shared editor preferences.

Preserve exact edit times, source identity, occurrence identity, undo steps and stream routing. Give manual and automatic thresholds explicit representations. Keep per-side padding in seconds throughout. Replay a report produced by the new writer using the same settings and edit boundaries that it recorded.

**Done when** each native writer round-trips through its current reader, invalid or retired formats return a specific error, and the app can start with fresh preferences. Check sequence, multicam, stills, offline media, repeated assembly ranges, named views and attached transcripts.

### 3. Change feature families end to end

| Work package | Include | Acceptance example |
|---|---|---|
| Projects, recovery, history, automation | Open/create/save/recover/close, window targeting, dirty state, revisions, history, preferences and local MCP settings | Edit one of two open windows, undo, save and reopen the intended revision. |
| Media, sequence and playback | Import, inspect, refresh/relink, source vs. occurrence, split/trim/delete/reorder, marks, snap, seek, scrub, shuttle, monitor and preview audio | Trim by source time and seek by sequence time. Changing preview gain must leave exported samples unchanged. |
| Workspace and review | Layout, panels, inspector, timeline zoom/scroll, monitor, frame review and accessibility | Reveal a time in the requested panel and verify the returned frame belongs to the requested clock. |
| Multicam | Setup, angles and sources, offsets, camera take, switch edits, microphone selection, program routing, group limits, assembly occurrences and preview | Edit one repeated occurrence in assembly time. Verify group-time routing and the other occurrence. |
| Still assets, gaps and placements | Create, insert, replace, reframe, resize, relink, remove and space clips | Replacing picture preserves sound and duration. Inserting a still extends the timeline. |
| Waveforms, scenes, silence and analysis caches | Signed envelope vs. peaks, scan/review, room tone, blips, per-side padding, protection, queue/shorten, scan jobs, refresh and sidecars | Run on a file and an open editor, compare spans, preview and render the resulting cut. Confirm scan and plan publish no media output. |
| Transcription | Provider jobs, file staging, track evidence, attachments, speakers, word occurrences, script alignment, correction, excerpt selection, plan/apply/queue and caption export | Search a repeated word, select its occurrence, review the exact plan, apply it and verify the authored edit. A text read must leave transport state unchanged. |
| Export, queues and interchange | File/editor inputs, dry runs, joined vs. separate outputs, export tiers, copy/smart/encode, audio replacement, JPEG frames, project conversion and Resolve import | Compare plan and render, inspect output media, and confirm queued snapshots use their captured revision. Test editable-project export separately from host import. |
| Background operations | File, analysis, native-editor, transcript and export jobs, receipt IDs, retry deduplication, cancellation and published outputs | Cancel the exact job, reject a different owner's handle and report any completed outputs. |

Implement each row through core → desktop UI → CLI → live/file MCP → consumers, as applicable. Distinguish a capability absent from a surface from a broken mapping. The naming cutover does not itself require adding new editing capabilities.

### 4. Remove superseded contracts and update distribution

Delete retired flags, aliases, selector spellings, old-key fallbacks, dual encoders, preference conversion and historical native-format dispatch. Audit these by tracing readers and writers, not solely by searching for the word “legacy”. Swift decoders that ignore unknown keys and generic dictionary handlers need specific rejection tests: an old argument must not quietly produce a default operation.

Update CLI help, JSON examples, MCP schemas and generated reference, agent guides, desktop plugins, bundled documentation, host adapters, helper discovery, scripts, integration fixtures, benchmark invocations and package checks. Distinguish current feature documentation from historical release notes. Publish one bundle containing matching desktop, CLI, helper and catalogs.

### 5. Verify and release

1. Compare the canonical inventory with CLI discovery, MCP discovery and dispatch in both directions. Flag missing, duplicate and advertised-but-unhandled entries. Exercise every typed selector and conditional mode. Validate required/optional combinations and unknown fields.
2. Run Swift tests, the Go helper tests, native-format and sidecar round trips, and the feature integration suites. Include negative tests for retired spellings, mixed old/new inputs and unsupported native layouts. Verify errors precede file publication or project mutation.
3. Regenerate the MCP reference and check it with `python3 scripts/mcp-reference.py --check`. Exercise the guide examples and plugin instructions with the bundled executables. Compare results across desktop, CLI and MCP on identical fixtures where their operations overlap.
4. Use `scripts/build-app.sh` to produce a staged bundle. Exercise `TestLiveBundle` over the real MCP socket, bundled CLI commands, generated reports, UI controls and host interchange outputs. Verify clean preferences and a directory containing older data separately.
5. Publish after the staged bundle passes. Include a breaking-change release note specifying the new native format, preference reset and script changes. The implementation is complete when the shipped surfaces accept and emit only their canonical MPCut contracts.

## Review evidence

The counts above describe the pre-cutover release and came from the 11 JSON catalogs in `Sources/MPCutApp/MCPResources`, the help entries in `Sources/MPCutCLI/CommandHelp.swift`, and the shared settings in `Sources/MPCutApp/EditorPreferences.swift`. Additional review covered CLI dispatch in `Arguments.swift`, file-tool forwarding in `MCPFileRequest.swift`, helper discovery in `mcp/main.go`, native project and history decoding in `MPCutCore`, the schemas in `docs/schema`, and the packaging and integration surfaces. These are planning findings. Runtime verification belongs to the implementation phases above.

## Cutover verification by consumer

The implemented 2.0 catalog has 176 tools across 11 feature catalogs. The CLI advertises 54 help topics. Native projects use schema version 3, MPCut-authored transcript documents use version 2, and sidecars use SQLite format 3. The MCP helper uses version 2 of the private app socket protocol. A client using the previous socket contract receives a version error before dispatch. Discovery and per-operation examples are available in the [MCP reference](MCP-REFERENCE.md) and the [CLI guide](CLI.md).

| Consumer | What can drift | Verification |
|---|---|---|
| Desktop settings and automation launchers | Persistent keys, command-line UserDefaults overrides and MCP preference selectors have independent readers. | Exercise fresh, retired and canonical stored keys, settings shared across two windows, isolated socket launch and preference read-back. |
| Native and file automation | Local socket dispatch, file-job routing, CLI argument construction, receipts and asynchronous result polling can disagree with discovery. | Send discovered tools through the helper and poll using the returned job ID. Compare the CLI result on the same fixture. Try a retired tool and mixed argument spellings before checking disk and editor state. |
| Authored projects and analysis | A cache rebuild could overwrite named views, speaker corrections or transcript attachments. | Round-trip sequence, still and multicam edits with history and attachments. Reject retired documents without touching their bytes. Run a cold-cache scan and repeat with the populated cache. |
| Human and agent documentation | CLI help, README, usage guide, bundled guides, plugin instructions and generated MCP reference ship separately. | Run documented examples against the staged CLI, run the guide inventory and review unmatched controls, regenerate the reference and check the packaged copies. |
| Deployment | SwiftPM products, the app bundle, Go helper, individually installed desktop plugins and client configuration can refer to different builds. | Run Swift and Go suites, Python packaging tests, build into an isolated destination, then test discovery and jobs through that bundle. Verify plugin manifests and entry points there before installing. |
| External interchange | Resolve, Premiere, FFmpeg and transcription providers own their wire formats. | Use export/import fixtures and the transcript provider fixture. Verify external field spellings and media timing across the adapter boundary. Record any host-dependent test that could not run. |

Run `swift test`, `(cd mcp && go test ./...)`, `python3 -m unittest discover -s Tests/Packaging`, `python3 scripts/guide-inventory.py` and `python3 scripts/mcp-reference.py --check`. Use a separate output directory for `scripts/build-app.sh` and the integration harnesses' documented environment variables to select that bundle. A skipped live test must be reported separately from a passing run.
