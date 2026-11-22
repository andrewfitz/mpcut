# Local MCP control audit

November 21, 2026 · MPCut 1.2.0 · Apple Silicon

The audit followed requests from the bundled stdio helper through the local socket to the open editor, its undo history, and the media written to disk. The scenarios below capture the failures that are most difficult to detect through tool discovery alone.

| Scenario | Behavior covered by the regression |
| --- | --- |
| A client loses the reply after closing a project | Retrying the identical operation returns its original successful close receipt. A different request cannot act on the closed handle. |
| A user changes the timeline during an agent edit | Deferred edits recheck their target and revision before committing. A cancelled import leaves history consistent. Undo restores the selection and range state that preceded an explicit clip deletion. |
| A group interval occurs twice in a multicam assembly | Splitting one occurrence preserves the other. A camera switch in group time is visible in both. Frame review identifies the source camera and source time. |
| Analysis inputs change while a worker runs | Analysis checks the relevant source, track, settings, or routing before publishing results. Pause protection and queued takes retain their native editing semantics. |
| A human quits while an agent has work running | Declining the quit prompt lets the work continue. Confirming quit waits for worker cleanup, including when all project windows have already closed. |
| A helper receives an incomplete or oversized reply | An ambiguous response reports `outcome_unknown`. A result too large for the SDK transport reports `response_too_large`. Clients can inspect project state and use the retry rules in the agent guide. |
| A Resolve archive conversion is cancelled | The production Lua bridge was exercised on Blackmagic’s interpreter with a simulated project manager. It restored the original project and page, removed its temporary project and staged files, and preserved a competing destination. A live Resolve session was outside this cancellation test. |
| An app is moved, or two builds bootstrap Go at the same time | The relocated helper discovers the bundled catalog and reads both offline guides. Concurrent builds share the pinned toolchain and include dependency notices. |

## Reproducing the checks

Run `swift test` for editor, history, job, and core media regressions. Run `go test -race ./...` and `go vet ./...` in `mcp/` with the pinned Go toolchain. Run `python3 scripts/mcp-reference.py --check` to compare the tool reference with the live schemas.

Build with `scripts/build-app.sh dist/MPCut-MCP`. On a logged-in macOS desktop, run the following from the repository root with the pinned Go toolchain on PATH. The live tests need the local control socket to be free and use disposable projects and media.

```sh
go test -C mcp ./integration -v -count=1 \
  -args -bundle="$PWD/dist/MPCut-MCP/MPCut.app"
```

The silence-to-export fixture checks the samples in both queued WAV files and restores the original edit through native history. The Settings fixture exercises disabling, enabling, and relaunching the GUI with a connected helper. See the [coverage matrix](MCP-COVERAGE.md) for workflow coverage and external host dependencies.
