# Decoded gallery accuracy fixture

Run the fixture with a TileTrail-enabled MPCut and FFmpeg built with `libx264rgb`.

```sh
python3 Tests/Integration/tiles_gallery.py /path/to/mpcut --ffmpeg /path/to/ffmpeg
```

Pass `--artifacts DIRECTORY` to retain the generated MP4s, raw scan reports and accepted projects. The runner prints machine-readable scores and exits with status 1 when a threshold or diagnostic check fails.
Pass `--tiletrail /path/to/tiletrail` to check import and acceptance of an independently produced scan.

The main recording uses the source-local textures and four layouts from TileTrail's Rust gallery test. Each layout lasts three seconds at 12 fps. The recording always shows 25 tiles. It rotates the original seats at 3 seconds, replaces 15 feeds at 6 seconds and returns those 15 feeds at 9 seconds. Lossless H.264 RGB preserves the synthetic textures across the encode and decode. One-second closed GOPs provide stable intervals for adaptive scanning. The acceptance run measures hint-guided tracking of lossless synthetic video.

The scorer compares displayed rectangles at all 144 presentation timestamps, using the observation's effective span through the next observation or the appearance end. It uses one-to-one geometry matching at IoU ≥ 0.75 and an optimal one-to-one mapping between detected tracks and true feeds. It counts misses per true tile, false tiles per prediction and wrong identities per matched tile. The nine transition frames include the frame at each boundary and its two neighbors. The runner checks that the accepted project lists exactly 40 feed IDs. It requires an actual inferred span in adaptive mode and an observation at every presentation frame with observed coverage in every-frame mode.

The camera-off fixture replaces the first feed after a one-second camera-off interval. It requires the resulting ambiguous identity to have a dated issue at 2 seconds in both raw scan review and the accepted project. The fixed-grid fixture verifies all 64 cell rectangles on every presentation frame, expects a maximum-of-63 diagnostic spanning the recording, and checks that the CLI rejects a 72-cell request before scanning.

## Results on 2026-11-23

The native MPCut debug CLI linked against TileTrail on an Apple M4 Max running macOS 27.0.1. Homebrew FFmpeg 9.0.2 encoded the fixture. Both scans used the CPU backend and the 5 × 5 gallery hint.

| Sampling | Tile observations | Matched instances | Misses | False tiles | Wrong IDs | ID switches | Unresolved | Accepted feeds |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Adaptive | 56 | 3,600 / 3,600 | 0 | 0 | 0 | 0 | 0 | 40 |
| Every frame | 144 | 3,600 / 3,600 | 0 | 0 | 0 | 0 | 0 | 40 |

Both modes scored 225 of 225 tile instances in the transition windows and 3,375 of 3,375 elsewhere. Both dated the 25 initial moves at 3 seconds and 10 moves, 15 departures and 15 arrivals at each of 6 and 9 seconds. Adaptive inspection reported four inferred ranges. The separate replacement-feed case reported an ambiguous match and an unassigned tile spanning [2, 3) seconds. Both issues began at 2 seconds in the accepted project too. The fixed-grid case retained 64 cells throughout all 12 frames, reported the conflicting maximum over [0, 1) seconds and rejected the 72-cell request with an argument error naming the limit.

A separate encoding of the same textures to H.264 YUV 4:2:0 at CRF 12 recovered all 3,600 rectangles in each sampling mode. It had 73 unresolved matched instances per mode. All had dated issues. The scanner reported 40 tracks, and accepted review listed 38 linked feeds. This control quantifies the effect of chroma subsampling on the synthetic textures and falls short of the 40-reviewed-feed target.

The automatic detector marks all 12 pictures in a separate 72-cell recording as over its capacity. It reports no boxes and marks coverage unknown over [0, 1) seconds. MPCut inspection shows one dated 64-tile-limit issue over the full second. The issue retained its range after an unmodified standalone scan was accepted, saved, and reopened.
