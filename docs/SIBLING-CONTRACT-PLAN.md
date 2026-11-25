# MPCut cutover to the shared contract

Proposed · 25 November 2026

MPCut, ColorGrade and MonitorKit are separate products that share one command grammar, one JSON spelling, one set of exit statuses and the data they pass to each other. The [shared contract](../../../ultracam/docs/shared/SIBLING_CONTRACT.md) states that target with one form for every rule. ColorGrade and MonitorKit are built to it from the start. This page lists what MPCut changes to reach it. [Naming convention](NAMING-CONVENTION.md) · [ColorGrade plan](../../../ultracam/docs/COLORGRADEKIT_PLAN.md) · [MonitorKit CLI plan](../../../ultracam/docs/monitorkit/HEADLESS_CLI_PLAN.md)

MPCut's design was the starting point for the contract, and most of it carries over unchanged. Where MPCut had two names for one thing, or a shape that did not suit three products, the contract picks the better form and MPCut moves to it. The [naming convention](NAMING-CONVENTION.md#adoption-across-the-app) already sets the method: ship one current contract across the app, CLI, MCP helper, plugins and saved formats, and remove retired names and fallback readers in the same release. So this is one release, MPCut 3.0, with no aliases and no period where both forms work.

Nothing here has been implemented. No MPCut source, descriptor or guide was edited. Each statement about current behavior was checked against the working tree on 25 November 2026, by reading source or by running the built CLI.

## What carries over unchanged

| Convention | Where it is defined |
| --- | --- |
| snake_case machine fields, kebab-case flags, feature → object → action command paths, `feature_target_object_verb` MCP tools | [Naming convention](NAMING-CONVENTION.md) |
| `--json`, `--input`, `--stdin`, `--project`, `--output`, `--out-project`, `--in-place`, `--at`, `--dry-run`, `--plan-token`, `--no-sidecar` | [Argument parsing](../Sources/MPCutCLI/Arguments.swift) |
| `{"ok": false, "error": {"code": …, "message": …}}` on failure, with `nearest` and `alternatives` where they help | [CLI entry point](../Sources/MPCutCLI/main.swift) |
| Exit statuses 0, 1, 2, 3 and 130 | [CLI guide](CLI.md#script-mpcut) |
| Time strings in requests and in the timeline of a `.cut`: `N/D`, an integer or a decimal. Half-open ranges. Zero-based absolute stream indices | [Project format](CUT-FORMAT.md) · [Time parsing](../Sources/MPCutCore/RationalTime.swift) |
| Frame lookup by the frame whose interval contains the time, with `no_frame` and `ambiguous_frame` | [Frame export](../Sources/MPCutCore/JPEGExport.swift) |
| `operation_id`, `job_id`, job states, receipts, result paging, `plan_token`, history origin, `expected_revision` on live tools | [Headless guide](HEADLESS.md) · [Agent guide](MCP-AGENT-GUIDE.md) |
| The `media`, `project`, `history`, `review`, `export` and `analysis` command paths, and `--video`, `--quality`, `--audio` on a render | [Command paths](../Sources/MPCutCLI/CommandPath.swift) |

## Changes to existing behavior

Each row replaces the left column with the right column in MPCut 3.0.

| Area | MPCut 2 | MPCut 3 | Why |
| --- | --- | --- | --- |
| Times in CLI results | `{"numerator": 37, "denominator": 25}` objects. Live MCP tools already write `"37/25"`. | The string, everywhere a time is written. | The string is the only form every MPCut input accepts, including flags and `project edit`. A result can then be passed straight back in, to MPCut or to a sibling. |
| Times inside a `.cut` | The timeline stores strings. `media_snapshot` and `transcripts` store objects. | Strings throughout, as project schema 10. | One time format in the saved document. |
| Older projects | MPCut opens only schema 9. An earlier document reports an unsupported version, and nothing converts it. | MPCut opens only schema 10. `mpcut project migrate` converts a schema 9 project into a new schema 10 file and leaves the original untouched. | People keep their saved work across the cutover. ColorGrade has the same command. |
| Result header | Command results carry `ok`. `--version` and `help` do not. Nothing names the product or command. | Every JSON result MPCut prints, and every manifest or report saved from one, begins with `ok`, `product: "mpcut"` and `command`. A command reading a request ignores those three members, so a replayed report still works as input. Projects, schemas and requests have no header. | A saved result tells the next product what it is. |
| Written files | A render returns `output` as a path string. A still render adds `output_bytes`. | `output` is a file descriptor: `{path, media_type, byte_length, sha256}`. A batch returns `outputs` as a list of them. `output_bytes` is retired. | Every product reports a written file the same way, with a digest that binds later work to the exact bytes. |
| Frames manifest | Three version 2 shapes: single source, program and multicam angles. Rows name the written image `file`. | One version 3 shape with a `clock`. Every row has `id`, `request_number`, `requested_time` and `availability`. A row with a picture has `output`, `frame_time`, `width`, `height`, `stage` and `signal`. Multicam `group_time` becomes `requested_time` on the `group` clock. `generated_gap` becomes an availability. [Shared schema](../../../ultracam/docs/shared/frames_manifest.schema.json) · [Multicam example](../../../ultracam/docs/shared/examples/mpcut.frames_manifest.json) | One reader in MonitorKit and ColorGrade handles every manifest. `file` keeps one meaning, the source media. |
| Exit statuses | 1 for every failed operation. | 4 for a failed check such as `tiles angles verify`. 5 for a capability this Mac lacks. 6 for `missing_source` and `source_changed`. 7 for `stale_render_plan`, `stale_tile_review`, `stale_tile_switch`, `project_save_conflict` and `output_exists`. 0, 1, 2, 3 and 130 keep their meaning. | A script can tell a missing file from a conflict from a failed check without parsing text. |
| Missing source file | `media inspect` on a missing file returns `invalid_input`. | `missing_source`, exit 6. `invalid_input` stays for a file that is present and unusable. | One code for one condition across the three products. |
| Reused operation ID | File jobs return `operation_id_conflict`. Live tools return `operation_conflict`. | `operation_id_conflict` for both. | One name. |
| Saved-file guard | Live tools take `expected_revision`. Saved-file `project edit` takes `project_revision`, a SHA-256 of the project model, for a reviewed tile-switch batch. | `project inspect` returns `revision` for a saved file, binding a counter to the SHA-256 of the saved bytes. Every saved-file mutation takes it as `expected_revision`. `project_revision` is retired. | One guard name on a window and on a file, and every saved-file edit can be guarded. |
| Clock selector | `timeline range map` and transcript commands use `--space`. Review commands use `--clock`. | `--clock`, and `clock` in JSON. | One name. |
| Output directory | `scenes export` uses `--export-to`. | `--output`. | One name. |
| Enum flag values | Some are kebab-case and some snake_case: `every-frame`, `keep-offline`, `source-timecode`, `non-silent`, `cpu-only`, `422-hq` beside `separate_tracks` and `current_cut`. | snake_case, identical to the JSON value. | A value copies between a flag and a request unchanged. |
| One-based fields | `error.segment` and `failed_range` count from one without saying so. | `error.segment_number` and `failed_range_number`. | `_number` is one-based and `_index` is zero-based, everywhere. |
| `media inspect` detail | The CLI uses `--frames`, `--keyframes` and `--audio-packets`. The MCP tool uses `detail`. | `--detail metadata\|frames\|keyframes\|audio_packets` on the CLI as well. | A command and its tool take the same options. |
| `media inspect` streams | `sample_rate`. Times as objects. No shared description of color. | `sample_rate_hz`. Time strings. A shared `signal` on each video stream and on `image`, beside the existing `color_*` strings. [Shared schema](../../../ultracam/docs/shared/media_inspect.schema.json) | Values carry their unit, and all three products return the same members. |
| `project media relink` | `--from` and `--to` take paths. | `--source OLD --with NEW`, as `project media replace` already does. | `--from` and `--to` always take times. |

## Additions

| Addition | Detail |
| --- | --- |
| `capabilities` | `mpcut capabilities --json` and `cli_capabilities_read`. Readable and writable formats, encoders and the `detector_capabilities` now in `--version`, with a reason for each unavailable feature. |
| `help schema NAME` | Print one published JSON Schema, starting with the project schemas in `docs/schema`, the frames manifest and the media inspection result. |
| `--version` members | `shared_contract_version: 1` beside `version`, `build_id` and `project_schema_versions`. |
| `job` command paths | `job list`, `job status`, `job result`, `job cancel` and `job release` on the CLI, and `file_job_list` in the helper, over the existing receipts. |
| `error.pointer` | The RFC 6901 JSON Pointer to the request field at fault. |
| `--frame-match` | `containing` stays the default. Add `exact`, `at_or_before`, `at_or_after` and `nearest` to `review frames export` and the frame-read tools. |
| `--progress` everywhere | On `export project render` and every other command that can run long. It is on scans, refresh, transcript, participants and tiles commands today. |
| `--project-handle` | Let the CLI address an open window through the local control socket, as the live MCP tools do. |
| PNG and TIFF for rendered Tiles frames | These are JPEG only today, which rules them out for measurement. |

## What the cutover touches inside MPCut

- **Integration tests.** Forty-five files under `Tests/Integration` read `numerator` and `denominator` from results. Tests that assert exit status 1, `output` as a string, or the version 2 manifest fields change with them.
- **Saved projects.** `project migrate` from schema 9 to 10 for `media_snapshot` and `transcripts` times, with golden files and a prompt in the app when it meets a schema 9 document. Replayable silence and scene reports written by MPCut 2 need a stated answer: rescan, or a one-time converter.
- **Descriptors and generated reference.** The JSON in `Sources/MPCutApp/MCPResources`, [MCP reference](MCP-REFERENCE.md), `help --json` and the three offline guides.
- **Guides.** [CLI guide](CLI.md), [Headless guide](HEADLESS.md), [Agent guide](MCP-AGENT-GUIDE.md), [Project format](CUT-FORMAT.md) and [Usage](USAGE.md).
- **Plugins and the walkthrough.** The skill instructions under `plugins/mpcut` and `docs/mcp_walkthrough.py` name tools, fields and error codes.
- **Go helper.** Error messages and the `app_unavailable` text in [the bridge](../mcp/bridge.go).

## Corrections that need no cutover

- **Settings paths.** [Naming convention](NAMING-CONVENTION.md), [Agent guide](MCP-AGENT-GUIDE.md), [Usage](USAGE.md), [MCP plan](MCP-PLAN.md) and the bridge's `app_unavailable` message place Enable local MCP control under Settings → General → Automation. The Settings window has an Automation page, and the control is there. Save and reuse analysis is on the Storage page.
- **`project merge` exit status.** [CLI guide](CLI.md#convert-and-hand-off-projects) says it exits 1 for a conflict. The code path for `merge_conflict` appears to exit 2. Run a conflicting merge to confirm, and correct whichever is wrong. As a Git merge driver it stays outside the shared exit table.

## Shared code

The [ColorGrade parity specification](../../../ultracam/docs/colorgradekit/MPCUT_PARITY.md#how-to-share-the-implementation) proposes extracting the Go MCP transport, the exact-byte save guard, history retention and the cache cleaner into packages that MPCut and ColorGrade both build. MonitorKit's files-only helper would use the same Go transport package. The result header, file descriptor, time string and error object belong in that shared Swift package too, so three products encode them with one implementation. Extract each piece together with its tests when its second consumer exists.

## Order of work

1. Correct the settings paths and settle the `project merge` status. These ship in any release.
2. Build the shared Swift types: time string, result header, file descriptor, error object and signal.
3. Make the cutover on a branch: times, header, file descriptors, the unified frames manifest, renamed flags, values, fields and codes, exit statuses, and project schema 10.
4. Add `capabilities`, `help schema`, `job` paths, `--frame-match`, `--progress` and `--project-handle`.
5. Update descriptors, guides, plugins, the walkthrough and the integration tests in the same branch.
6. Run the shared checks against the built bundle, then the handoffs in the shared contract once ColorGrade and MonitorKit exist. [Discovery check](../../../ultracam/docs/colorgradekit/check_mpcut_parity.py) · [Contract check](../../../ultracam/docs/shared/check_shared_contract.py)
7. Release as MPCut 3.0 with a migration note that lists every row of the changes table.
