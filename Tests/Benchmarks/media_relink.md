# Project Media performance

Run the benchmark against a built CLI on macOS.

```sh
python3 Tests/Benchmarks/media_relink.py .build/debug/mpcut --size session --runs 3
python3 Tests/Benchmarks/media_relink.py .build/debug/mpcut --size production --runs 3
```

The runner creates PCM WAV files and a v5 project in a temporary directory. It includes online recordings, moved recordings, shorter same-name candidates, and recordings reachable only through undo or redo. It runs one warmup per command and reports wall time for the remaining samples, including CLI startup and JSON output. The runner checks inventory status and use counts, confirms Locate selections, and verifies every rewritten clip and saved history state. Pass `--schema-version 4` to measure legacy input.

## Session results

Three measured samples on an Apple M4 Max running macOS 27.0.1, using debug builds from before and after the batch rewrite and native clock capture. The fixture has 600 clips, 24 current recordings, eight undo steps, and four redo steps. The prefix relink moves 30 recordings, including 12 referenced only in history.

| Workload | Earlier median | Later median |
| --- | ---: | ---: |
| List media with history | 108.4 ms | 87.1 ms |
| Locate moved recordings with history | 435.0 ms | 196.4 ms |
| Relink and save the archive | 7,346.3 ms | 608.6 ms |
| List media after relink | 141.9 ms | 118.3 ms |

The later build rewrites the timeline and history once for independent destinations and captures the source clock from the existing probe. The measurements compare whole debug builds, which also contain audit fixes.

## Production stress run

The later debug build processed a project with 8,000 clips, 240 current recordings, 32 undo steps, and 16 redo steps. The prefix relink moved 228 recordings. The runner verified all 48 history states after reopening the written archive.

| Workload | Median of three samples |
| --- | ---: |
| List media with history | 1.22 s |
| Locate moved recordings with history | 8.50 s |
| Relink and save the archive | 17.87 s |
| List media after relink | 5.99 s |

A separate three-sample run of the last workload compared the batch rewrite build with a later build that deduplicates retained uses before checking Revert eligibility. The median dropped from 8.82 s to 3.34 s. Both runs confirmed Revert availability for all 228 relocated recordings. Other builds were running on the same machine, and wall times varied across samples.
