# MPCut performance pass

Work directly in the current checkout. Pick one slow user action, measure it, change the code, and repeat the same action on the same input. Use the same release build settings and cache state on both sides. Three runs per side and the median are a starting point. If the difference is smaller than the run-to-run variation, repeat before claiming a win. If another edit touches the path mid-comparison, remeasure that case.

## Where to start

| Order | User action | What to investigate and measure |
| --- | --- | --- |
| 1 | Open or refresh a long recording | Time first edit, first correct preview, first thumbnail and full index separately. A prior two-hour import showed 73 ms, 749 ms and 4.52 s for first clip, first tile and complete index respectively. Count repeated probes and full index reads. Try one cold import and one reopen with a saved sidecar. |
| 2 | Trim, scroll and scrub while indexing | On the existing 50k-clip fixture, hold visible clip count fixed. Profile full timeline geometry rebuilds during trim, filmstrip queue rebuilds and decoder reopens during fast scrubs. Record p95 input latency and time from pointer release to the correct frame. Check dropped frames and undo. |
| 3 | Export a batch of review frames | Compare one frame with 20 frames through CLI and MCP. ProgramFrames and MCPReviewFrame can reopen decoders per frame. Try reusing JPEGExport’s chronological batch path. Check first-result latency, total seconds, memory, frame identity and original request order. |

## Rest of the pass

| Area | Workload and success measure |
| --- | --- |
| Project lifecycle | Launch, open several regular and multicam projects, switch, edit, save, undo, recover, close and quit. Measure visible stalls, save time and memory after close. Reopen and verify edits, history and project targeting. |
| Indexing and storage | Compare fresh and warm reads, short frame queries on long media, thumbnail writes, and refresh after source replacement. Measure bytes read or written and time saved. Verify cached results match fresh results. |
| GPU and preview | Start with forced HDR-to-SDR preview, where the presentation path can wait for rendering. Compare native HDR and forced SDR during playback and scrubbing. Then profile still-image packing, mixed-canvas scaling and software fallbacks. Count conversion and transfer costs and check frame timing, color and memory. |
| Analysis and algorithms | Profile scene detection, silence, waveforms, multicam sync and timeline mapping on short and long inputs. Test algorithm or GPU changes where time accumulates. Score exact cuts, false positives, pause boundaries and known sync offsets against labeled fixtures. |
| Export and processing | Time preflight and writing separately for copy, Smart Trim, reencode, stills and multitrack audio. Look for repeated packet scans, decoder starts and temporary PCM copies. Verify copied packets, frame timestamps, channel order and decoded samples as appropriate. |
| AI, GUI, CLI and MCP | Follow one quote from transcription through search, frame review, edit, export and reopen. Time each step. Distinguish worker execution from client polling. Check real speech accuracy on labeled audio and use a deterministic provider to compare workflow overhead. Include cancellation, retries and playback during a job. |
| Interchange, memory and size | Time host export and reopen where the NLE is available. Check timeline and audio routing. Repeat multi-project open/close and measure settled memory after decoder caches expire. Compare release bundle and compressed sizes when changing packaging. |

## Record the result

Use one row per change. Reuse the existing tools in this directory and the GUI performance tests. Add a timer only where an existing test misses the user-visible wait. After combining changes, rerun the affected workflows together once to catch interactions.

| Action and input | Before | After | Time or memory saved | Correctness check |
| --- | ---: | ---: | ---: | --- |
| Example: 20 review frames, same project and sidecar state | | | | Frame IDs, timestamps and request order |
