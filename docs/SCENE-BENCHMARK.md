# Scene detection benchmark

The scene scanner uses VideoToolbox where available and compares 64 × 36 samples from consecutive decoded pictures. An adaptive threshold and neighboring-frame checks suppress brief flashes and sustained motion. A separate comparison of pooled color and layout estimates which shots share a view. The scan produces timestamps and labels and writes no media output.

FFmpeg's `scdet` is the reference for hard cuts. PySceneDetect's adaptive detector is another lightweight option. OmniShotCut offers learned detection for a broader set of transitions and requires model weights. MPCut uses a small native detector for background hard-cut navigation without a model download. The comparison here measures MPCut and FFmpeg on the same files. [FFmpeg filters](https://ffmpeg.org/ffmpeg-filters.html#scdet) · [PySceneDetect detectors](https://www.scenedetect.com/docs/latest/api/detectors.html) · [OmniShotCut](https://github.com/UVA-Computer-Vision-Lab/OmniShotCut)

## Reproduce

Build the app on an Apple Silicon Mac and run the benchmark from the repository root. The fixture generator uses a separate FFmpeg with `libx264`, such as the Homebrew build.

```sh
python3 Tests/Benchmarks/scene_detection.py dist/MPCut.app/Contents/Helpers/mpcut \
  --ffmpeg dist/MPCut.app/Contents/Helpers/ffmpeg \
  --runs 3 --tears-of-steel /path/to/tears_of_steel_720p.mov
```

The two generated H.264 montages each have 13 shots, 12 cuts, and six known framings: four wide views and two crops. Both include an eight-frame insert. One adds two one-frame flashes. A cut counts only if the timestamp lands on the expected frame. For view grouping, the benchmark checks whether every pair of shots with the same label was grouped together and whether shots with different labels stayed separate.

The optional film benchmark uses the [Blender Foundation's original 720p *Tears of Steel* MOV](https://download.blender.org/demo/movies/ToS/). Two 24-second excerpts were labeled by checking adjacent frames. The 40–64 second excerpt guided tuning and excludes a gradual transition. The 70–94 second excerpt was labeled after tuning and used as a holdout. The rest of the 12:14 film is used for timing.

## Results

Apple M4 Max with 48 GB of memory on macOS 27.0.1. Times are median wall-clock times from three runs of the release CLI on local storage. The FFmpeg reference uses the bundled 9.0.2 build with VideoToolbox decode and scaling to 64 × 36, then `scdet` at its default threshold of 10. MPCut's times include file inspection and view grouping.

| Footage | MPCut exact cuts | MPCut extra markers | FFmpeg exact cuts | FFmpeg extra markers |
| --- | ---: | ---: | ---: | ---: |
| Generated multicam | 12/12 | 0 | 6/12 | 0 |
| Generated multicam with flashes | 12/12 | 0 | 6/12 | 2 |
| *Tears of Steel*, tuning excerpt | 7/7 | 0 | 7/7 | 0 |
| *Tears of Steel*, holdout excerpt | 5/5 | 0 | 5/5 | 0 |

| Scan | MPCut | FFmpeg |
| --- | ---: | ---: |
| Generated multicam, 21.37 s | 0.51 s | 0.57 s |
| Generated multicam with flashes, 21.37 s | 0.51 s | 0.58 s |
| *Tears of Steel*, full 12:14 | 17.44 s | 16.41 s |

MPCut recovered all six framing groups and all 78 pairwise shot relationships in both generated montages. The VP9 WebM and ProRes MOV versions of the clean montage also produced 12 cuts and six views. Lowering `scdet` to 6 recovered all the generated cuts and still flagged both flashes. The film excerpts measure hard-cut accuracy; they contain no ground truth for physical camera identities or the full film's cut count.

An earlier build of the scanner completed a single 2.5-hour, 3.1 GiB H.264 stress run in 4:45 with 146 MiB peak resident memory. That test used repeated continuous footage and measured throughput only.

In the end-to-end CLI check, all 13 detected ranges from the generated montage went directly into bulk Smart Trim. FFprobe decoded all 13 output clips with the expected frame counts, including the eight-frame insert.
