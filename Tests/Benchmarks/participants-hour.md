# One-hour participant scan and project reopen

The November 23, 2026 runs used an Apple M4 Max, macOS 27.0.1, FFmpeg 9.0.2 and TileTrail-enabled MPCut debug executables. The source is a generated 384×256 gallery with 16 solid-color tiles. Repeating the static clip exercises one hour of decode, sampling, report import and project storage.

The 30 fps source contained 108,000 frames. MPCut's sparse mode decoded the full stream and sent one frame to TileTrail every 0.2 seconds. The 1 fps variant resampled the source before looping it, so it tests one observation per second without the original stream's decode load. The CLI has a fixed sparse cadence and exposes no sampling interval override. Both runs selected the CPU detector, disabled the sidecar, produced complete reports and recorded inferred coverage for the half-open interval `[0, 3600)`. Neither report included a resume point.

| Measurement | 30 fps input, 5 observations/s | 1 fps input, 1 observation/s |
| --- | ---: | ---: |
| Decoded frames | 108,000 | 3,600 |
| Saved observations | 18,000 | 3,600 |
| Last observation | 3599.8 s | 3599 s |
| Tracks and distinct appearances | 16 each | 16 each |
| Scan elapsed time | 682.68 s | 76.67 s |
| Scan user + system CPU time | 87.19 s | 10.79 s |
| Scan peak RSS | 741,212,160 bytes | 203,063,296 bytes |
| Saved scan size | 76,023,435 bytes | 17,042,089 bytes |
| Project accept elapsed time | 18.33 s | 17.92 s |
| Project accept peak RSS | 390,889,472 bytes | 125,665,280 bytes |
| Accepted geometry spans | 1,454 | 16 |
| Accepted project size | 403,969 bytes | 6,699 bytes |
| Relocated project inspect elapsed time | 0.24 s | 0.11 s |

The 30 fps scan and 1 fps scan used different build snapshots. The 30 fps scan began during concurrent builds and accelerated as the host load fell. A first successful 1 fps scan with that older executable took 308.29 seconds at 180,895,744 bytes peak RSS. Treat the wall times as individual measurements under varying host load. The `.cut` stores the accepted geometry, with adjacent identical spans merged. The 30 fps scan JSON exceeded 64 MiB and the CLI imported it successfully. The project JSON stayed below 1 MiB for this fixture.

Each saved v4 project held 16 people and the full inferred coverage interval. I reopened the project in a separate directory containing the `.cut` and its relatively addressed media. The probe resolved the media in that directory. The reopened participant object and the object embedded in the `.cut` matched after sorting JSON keys. The relocation reused the media inode on the same volume and used no sidecar. A cross-volume media copy was outside this check.

## Frozen final build repeat

MPCut linked against TileTrail `f1cdfb6` repeated the 30 fps workload with the same checked input and no sidecar. The completed report recorded 18,000 observations with 16 regions each, 16 participant tracks, an inferred `[0, 3600)` interval and no resume point. The source SHA-256 embedded in the report matched the original recording. The CLI successfully accepted and reopened the report using the same frozen executable.

| Measurement | Final 30 fps run |
| --- | ---: |
| Scan elapsed time | 105.56 s |
| Scan user + system CPU time | 39.22 s |
| Scan peak RSS | 1,314,422,784 bytes |
| Saved scan size | 85,537,861 bytes |
| Project accept elapsed time | 5.10 s |
| Project accept peak RSS | 499,761,152 bytes |
| Accepted geometry spans | 1,458 |
| Accepted project size | 385,347 bytes |
| Relocated project inspect elapsed time | 0.15 s |
| Relocated project inspect peak RSS | 22,724,608 bytes |

The repeat ran with much less concurrent build load. The measurements show the elapsed time and peak process RSS for these particular debug runs. The final report contained 735 distinct appearance IDs despite the stable region and participant counts. All 719 events were uncertain transitions for participant 14. The tracker reported re-entry at each ten-second loop boundary after the first and a leave 0.4 seconds into each repetition. Decoded frame checksums vary within the nominally static H.264 seed, so this fixture also exposes sensitivity to subtle encoded-picture changes. The accepted project retained 16 people and reproduced the complete geometry object on reopen.

### Streaming report encoder

The final Swift relink used the same immutable TileTrail library and repeated the exact 30 fps input with `--no-sidecar`. Peak process RSS fell **39.6%**. The scan report and its stdout copy matched the previous 85,537,861-byte report byte for byte. The input inode and change time were unchanged between runs. Elapsed time and CPU time are observations from two individual debug runs under different host load.

| Measurement | Before streaming | After streaming |
| --- | ---: | ---: |
| Scan elapsed time | 105.56 s | 86.95 s |
| Scan user + system CPU time | 39.22 s | 33.95 s |
| Scan peak RSS | 1,314,422,784 bytes | 794,542,080 bytes |

The streaming CLI accepted the full report in 5.17 seconds at 499,875,840 bytes peak RSS. Its 385,347-byte project reopened from the relocated directory in 0.12 seconds at 22,790,144 bytes peak RSS. The reopened participant object again matched the saved project, including all 1,458 appearance spans and inferred coverage through 3,600 seconds.

## Saved-report compatibility

An earlier schema v1 report omitted the `identity_uncertain` key that the newer CLI originally required. It failed with `invalid_json` at the first region. The updated decoder accepts that preserved report and normalizes legacy regions before sending them to the marker ABI. The patched CLI accepted both the unmodified 1 fps and 30 fps legacy reports, and the respective saved geometry survived relocation. The newer 1 fps report passed a same-binary scan and accept.

A preliminary test created a media hard link after scanning began, which advanced the source's filesystem change time. The live scan rejected the changed snapshot with `source_changed` even though the source bytes were unchanged. Prepare any links before launching a scan, or wait for it to exit before creating them. The measured runs kept the source stable.

## Fixture and executable checksums

| Artifact | SHA-256 |
| --- | --- |
| 10-second 30 fps seed | `4425868c572f3464aba2106b64435fbabb5dbeb6a0bb79e489f6f4f9e322c4f7` |
| One-hour 30 fps source | `182452e81e9d5f1f1a2a034c9d356e3deb2aa5177ddd27a30bbb192e42ef51c8` |
| One-hour 1 fps source | `d2d593c8b1bc14eb3489f1df95f61b23612d81298145ded426a0c1e213074730` |
| 30 fps scan executable | `a251d37626d0002fa3c340c37dfa976653cd0d534586b13ed6488caae7abc55c` |
| 1 fps scan and accept executable | `411e454d6d4dc9daf79478112a51ee9ab3ddb7eff580fdfa8abdaa3e912486c6` |
| Legacy-compatible accept executable | `e8e195f352d3ed1fc165250e42f086e723fbf3693f2d1962f3a1ae2ddfa01a3b` |
| Frozen scan and accept executable before streaming | `e8d811e8af5830ba349f579f32afedc79b9cd39724ba8b1e5468a5c03ffa4a78` |
| Final streaming scan and accept executable | `a0449be90fcea211275cd7a2e2b87b8ff2396328b2968de33a2176dfce34c351` |
| Saved 30 fps report | `87926d698f8464f1ff6f707bb9cbf280e576025d4001b8e80ec4419fd4b8e4ad` |
| Saved frozen 30 fps report before and after streaming | `b65b88e833e39ba74e8ce1dcd39dd5d3ce9b8e1540887c3fcccc3dbe800fb1e8` |
| Saved current 1 fps report | `8937c1302433616d67497109fca65663545d74adf31da2762fa2a485866c87d9` |
| Saved legacy 1 fps report | `536c9cba59bd2f4238197895a9820f9c95640234ba2b585f74072e4352eae67a` |

## Reproduce

Run from the repository root with a native TileTrail-enabled `mpcut`, FFmpeg and `jq` installed. Set `mpcut` to the absolute path of the build under test. Save the binary checksum before starting because a rebuild can replace the executable while a scan is running. A clean rerun of the generation commands reproduced all three fixture checksums on this host.

```bash
mpcut="$PWD/.build/tiletrail-native/out/Products/Debug/mpcut"
scratch=$(mktemp -d /tmp/mpcut-participant-hour.XXXXXX)
cd "$scratch"
shasum -a 256 "$mpcut"
python3 - <<'PY'
import subprocess

colors = [
    'ff5f57', '28c840', '0067cc', 'ffbd2e',
    '8848b3', 'f58a52', '41b8e6', 'a2624b',
    '7b8d42', 'f20c1e', 'f947aa', '37a8a2',
    'a3d5d6', 'e7e3cf', '7136a8', '879bd3',
]
filters = ','.join(
    f'drawbox=x={index % 4 * 96 + 3}:y={index // 4 * 64 + 3}'
    f':w=90:h=58:color=0x{color}:t=fill'
    for index, color in enumerate(colors)
)
subprocess.run([
    'ffmpeg', '-nostdin', '-v', 'error', '-f', 'lavfi',
    '-i', 'color=black:s=384x256:r=30:d=10', '-vf', filters,
    '-c:v', 'libx264', '-preset', 'ultrafast', '-threads', '4',
    '-g', '300', 'sample.mov',
], check=True)
PY
ffmpeg -nostdin -v error -stream_loop 359 -i sample.mov -c copy hour-loop.mov
ffmpeg -v error -n -i sample.mov -vf fps=1 -an -c:v libx264 \
  -threads 2 -preset ultrafast one-fps-seed.mov
ffmpeg -v error -n -stream_loop 359 -i one-fps-seed.mov -c copy hour-one-fps.mov
for source in hour-loop.mov hour-one-fps.mov; do
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,avg_frame_rate,duration,nb_frames \
    -of json "$source"
done

# Use hour-one-fps.mov instead to reproduce the second workload.
mkdir initial relocated
ln hour-loop.mov initial/gallery.mov
ln hour-loop.mov relocated/gallery.mov
/usr/bin/time -l "$mpcut" participants scan --file initial/gallery.mov \
  --backend cpu-only --sampling sparse --no-sidecar --progress stderr \
  --output scan.json --json > scan-stdout.json 2> scan-time.txt
cmp scan.json scan-stdout.json
jq '{state, duration: .source.duration, observations: (.analysis.observations | length),
     coverage: .analysis.coverage, resume_at: .analysis.resume_at}' scan.json

jq -n --arg media "$PWD/initial/gallery.mov" --arg out "$PWD/initial/base.cut" \
  '{kind:"sequence",out_project:$out,operations:[{action:"append",id:"gallery",
    file:$media,from:"0",to:"3600"}]}' | "$mpcut" project create --stdin --json
jq '.clips[0].file = "gallery.mov"' initial/base.cut > initial/relative.cut
/usr/bin/time -l "$mpcut" participants project accept --project initial/relative.cut \
  --source-id gallery.mov --analysis-file scan.json --out-project initial/accepted.cut \
  --json > accept.json 2> accept-time.txt
cp initial/accepted.cut relocated/accepted.cut
/usr/bin/time -l "$mpcut" participants project inspect --project relocated/accepted.cut \
  --json > inspect.json 2> inspect-time.txt
"$mpcut" project inspect --project relocated/accepted.cut --json > project.json
diff -u <(jq -S .participants initial/accepted.cut) <(jq -S . inspect.json)
jq '.sources' project.json
```
