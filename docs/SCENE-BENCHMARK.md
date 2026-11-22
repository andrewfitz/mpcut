# Scene detection benchmark

MPCut compares a 64 × 36 color grid from every decoded picture. An adaptive threshold and neighboring frames distinguish hard cuts from flashes and sustained motion. Pooled tile colors identify recurring views. The desktop and `mpcut scenes --json` use the same detector.

The original full-file scanner benchmarked below uses a pipelined AVAssetReader for eligible progressive H.264 and HEVC MOV/MP4 tracks with shared pixel buffers. The scanner checks the presentation timestamp, dimensions and pixel format on every frame, and checks the final frame count. When the track duration is not an integral number of ticks per frame, the reader verifies display times against a sorted table of video packet timestamps. The table uses eight bytes per frame and is capped at 64 MiB. Interlaced pictures, alpha, complex edits and incompatible timing use FFmpeg, with VideoToolbox decoding where available. ProRes 4:2:2 surfaces can be mapped directly for sampling. For software FFV1, the scanner checks the first packet and uses up to eight workers when the frame contains enough independent slices.

The resumable scanner used by Find Scenes, the CLI, and MCP reads through FFmpeg with VideoToolbox where available. It saves detector state and a verified seek point. On a synthetic two-hour H.264 file at 24 fps (172,800 frames), a first scan of seconds 7,000–7,010 decoded 289 frames including preroll. Repeating the same selection took 40–85 ms in local debug runs, with zero decoded frames and zero media bytes read by FFmpeg. In a separate test, killing the scanner at a saved checkpoint and starting another process continued the same attempt. These measurements cover scene detection only.

An M4 Max experiment compared CPU sampling with a Metal kernel on eight 4K NV12 surfaces. For the identical 64 × 36 result, the CPU took 3.49 µs per frame and a Metal dispatch with per-frame synchronization took 235.92 µs. The figures are medians of five 512-frame runs and cover sampling alone. MPCut uses the media engine for supported decoding and the CPU for this small comparison.

FFmpeg's `scdet` is the reference for hard cuts. PySceneDetect's adaptive detector is another lightweight option. OmniShotCut offers learned detection for a broader set of transitions and requires model weights. MPCut uses a small native detector for background hard-cut navigation without a model download. The comparison here measures MPCut and FFmpeg on the same files. [FFmpeg filters](https://ffmpeg.org/ffmpeg-filters.html#scdet) · [PySceneDetect detectors](https://www.scenedetect.com/docs/latest/api/detectors.html) · [OmniShotCut](https://github.com/UVA-Computer-Vision-Lab/OmniShotCut)

## Reproduce

Build the app on an Apple Silicon Mac and run the benchmark from the repository root. The fixture generator uses a separate FFmpeg with `libx264`, such as the Homebrew build.

```sh
python3 Tests/Benchmarks/scene_detection.py dist/MPCut.app/Contents/Helpers/mpcut \
  --ffmpeg dist/MPCut.app/Contents/Helpers/ffmpeg \
  --baseline /path/to/previous/MPCut.app/Contents/Helpers/mpcut \
  --codec-matrix --runs 3 --tears-of-steel /path/to/tears_of_steel_720p.mov
```

The generated H.264 montages each have 13 shots, 12 cuts, four wide views and two crops. Both include an eight-frame insert. One adds two one-frame flashes. A hit must land on the expected frame. The benchmark also checks all 78 pairs of shots for correct grouping. The codec matrix transcodes the clean edit to 4K HEVC Main10, 4K ProRes 422 and 1080p FFV1. The two HEVC files contain identical compressed video with different sample-entry tags. Use `--require-identical` to fail on a baseline JSON difference, or omit `--baseline` to run the candidate and FFmpeg alone.

The benchmark disables analysis sidecars on CLI versions that support `--no-sidecar`, including for existing files supplied through `--extra` or `--tears-of-steel`. To measure the effect of reusing saved analysis, run `python3 Tests/Benchmarks/analysis_sidecar.py dist/MPCut.app/Contents/Helpers/mpcut /path/to/recording.mov`. It builds a sidecar next to a temporary copy, checks that fresh and cached reports agree, and prints median wall times and sidecar size.

The optional film benchmark uses the [Blender Foundation's original 720p *Tears of Steel* MOV](https://download.blender.org/demo/movies/ToS/). Two 24-second excerpts were labeled by checking adjacent frames. The 40–64 second excerpt guided tuning and excludes a gradual transition. The 70–94 second excerpt was labeled after tuning and used as a holdout. The rest of the 12:14 film is used for timing.

## Results

The test machine was an Apple M4 Max Mac Studio with 48 GB of memory on macOS 27.0.1. The benchmark compares the signed CLI from immediately before these changes with the optimized signed CLI on the same local files. Each binary gets one warm-up and three measured runs with alternating execution order. Wall time includes startup, source inspection, decoding, view grouping and writing JSON. Peak RSS is the median of the per-run CLI process peaks. Decoder service memory and media-engine allocations outside that process are excluded.

The independent reference is the bundled FFmpeg 9.0.2 `scdet` at its default threshold of 10. It uses VideoToolbox decoding and scaling on the H.264, HEVC and ProRes fixtures. It uses software decoding and point scaling on FFV1 and arbitrary `--extra` inputs.

| Footage | MPCut exact cuts | MPCut extra markers | FFmpeg exact cuts | FFmpeg extra markers |
| --- | ---: | ---: | ---: | ---: |
| Generated multicam | 12/12 | 0 | 6/12 | 0 |
| Generated multicam with flashes | 12/12 | 0 | 6/12 | 2 |
| *Tears of Steel*, tuning excerpt | 7/7 | 0 | 7/7 | 0 |
| *Tears of Steel*, holdout excerpt | 5/5 | 0 | 5/5 | 0 |

| Scan | Previous | Optimized | Previous peak RSS | Optimized peak RSS | FFmpeg `scdet` |
| --- | ---: | ---: | ---: | ---: | ---: |
| *Tears of Steel*, 12:14 H.264 | 15.547 s | 2.748 s | 44.1 MiB | 80.3 MiB | 14.393 s |
| H.264 multicam, 21.37 s | 0.443 s | 0.149 s | 25.0 MiB | 26.3 MiB | 0.467 s |
| H.264 multicam with flashes | 0.406 s | 0.150 s | 24.3 MiB | 26.5 MiB | 0.435 s |
| 4K HEVC Main10, `hvc1` | 1.686 s | 0.962 s | 107.1 MiB | 31.2 MiB | 2.782 s |
| 4K HEVC Main10, `hev1` | 1.267 s | 1.275 s | 107.2 MiB | 105.7 MiB | 2.527 s |
| 4K ProRes 422 | 4.716 s | 3.624 s | 153.9 MiB | 71.1 MiB | 3.343 s |
| 1080p multi-slice FFV1 | 1.117 s | 0.667 s | 24.7 MiB | 20.2 MiB | 0.214 s |
| Single-slice FFV1, all-intra | 0.515 s | 0.525 s | 14.7 MiB | 14.6 MiB | 0.124 s |
| Untiled 4:4:4 VP9 | 0.131 s | 0.093 s | 24.4 MiB | 29.1 MiB | 0.091 s |

The full-film scan accelerated 5.7× and used 36.2 MiB more peak CLI memory. The release reports agreed on all 138 cuts, their exact timestamps and 109 recurring-view groups. A separate decoder comparison checked all 17,620 presentation timestamps and hashes of the sampled YUV grids. This verifies agreement across the full film. Hard-cut accuracy was scored on the two labeled excerpts.

The 4K ProRes scan used 54% less peak CLI memory. Multi-slice FFV1 traded CPU work for elapsed time, using 2.584 CPU seconds compared with 2.055. Single-slice FFV1 keeps frame threading. Non-4:2:0 VP9 can use two extra frame workers on small enough pictures, which accounted for higher peak memory in that fixture.

Apple's reader accepted the `hvc1` file and declined the same HEVC pictures tagged `hev1`. MPCut sends `hev1` directly to the FFmpeg/VideoToolbox decoder. That row was remeasured after this change using the same montage and benchmark settings. The two additional software-decoder fixtures were measured with `--extra`. All nine old and new scene reports matched in full. [Machine-readable results, including CPU time](SCENE-BENCHMARK.json)

MPCut recovered all 12 exact cuts, six framing groups and 78 pairwise shot relationships in both H.264 montages and across the codec matrix. In a separate 25 fps regression fixture, the previous scanner missed a two-frame insert immediately after a flash. The optimized scanner marked both the switch to the insert and the return to the original view while suppressing both flashes. A variable-frame-rate fixture also forces a decoder restart partway through the scan and checks that the editor receives each final marker exactly once.

An earlier build of the scanner completed a single 2.5-hour, 3.1 GiB H.264 stress run in 4:45 with 146 MiB peak resident memory. That test used repeated continuous footage and measured throughput only. With packet-verified variable frame timing, the signed CLI scanned the 223,809-frame stress file in 40.88 s with sidecar reads disabled. Its scene JSON matched the prior workspace build byte for byte. A separate uncached scan of a 2 h 26 min, 1080p HEVC Main10 recording took 102.07 s and reported 738 scenes. These are individual runs on the M4 Max.

In the end-to-end CLI check, all 13 detected ranges from the generated montage went directly into bulk Smart Trim. FFprobe decoded all 13 output clips with the expected frame counts, including the eight-frame insert.
