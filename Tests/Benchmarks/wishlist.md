# Wishlist core benchmarks

Run from the repository root with the development FFmpeg dependencies installed.

```sh
MPCUT_WISHLIST_BENCH=1 swift test -c release -Xswiftc -enable-testing \
  --filter WishlistBenchmarkTests
```

The three cases call the production camera lookup, timeline mapping, and
waveform matcher directly. Each case warms up once, prints median calling-thread
CPU time in milliseconds, and checks that each timed run produces identical
sorted-key JSON. To compare revisions, run the same harness and Swift toolchain
on both revisions and compare the `sha256` fields in the `WISHLIST_BENCH` lines.
Fixture generation, JSON encoding, and assertions run outside the measurement.

| Case | Work per sample | Before CPU p50 | After CPU p50 | SHA-256 prefix |
| --- | --- | ---: | ---: | --- |
| Camera lookup, 64 recordings per angle | 4,096 lookups across four angles | 4.833 ms | 0.600 ms | `64dc14f7fbc5` |
| Camera lookup, 512 recordings per angle | 4,096 lookups across four angles | 33.403 ms | 3.910 ms | `a4174e721a4f` |
| Timeline mapping, specific occurrence | 40 source queries over 30,000 clips | 85.111 ms | 5.364 ms | `8e409977ce43` |
| Timeline mapping, file filter | 40 source queries over 30,000 clips | 87.075 ms | 10.906 ms | `d4efd73391b3` |
| Waveform matching, dense | Two shifted seven-minute 50 Hz traces | 42.628 ms | 19.165 ms | `0bba2eaf61fc` |
| Waveform matching, missing samples | Same traces with regularly missing target bins | 45.233 ms | 22.955 ms | `0bba2eaf61fc` |

These observations came from optimized standalone runs of the same operation
bodies and fixtures on Apple silicon. Before and after output JSON matched
byte for byte for all six cases. Camera lookup covers reverse-ordered recordings,
coverage gaps, and endpoint selection. Mapping preserves repeated source uses,
and waveform matching returns the expected offset of 473/50 seconds.
