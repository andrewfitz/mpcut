# MPCut

## Running macOS tests

Run GUI checks on Backstage’s hidden display. This includes MPCutAppTests, whose XCTest host can create windows even when launched by `swift test`. Build the tests with `swift build --build-tests`, then use Backstage to launch the actual test host. For the default debug build:

```sh
test_products=$(swift build --show-bin-path)
backstage launch "$(xcrun --find xctest)" --env MPCUT_MUTED=1 -- "$test_products/MPCutAppTests.xctest"
```

Launch MPCut muted for testing: pass `MPCUT_MUTED=1` in the environment of the app or test process (`backstage launch … --env MPCUT_MUTED=1`, or `config.environment` for Launch Services). A muted MPCut plays no preview, scrub or reverse audio, skips its own alert sound and drops AppKit's beep for a key event nothing handles, while preview players keep decoding and advancing. Other AppKit beeps (for example a text field rejecting input) can still sound, so keep test input valid. MPCutAppTests also sets it in process as the bundle loads (`Tests/MPCutTestSupport`), so `swift test` and filtered `xctest` runs are muted too; an explicit `MPCUT_MUTED=0` keeps them audible. The integration launchers pass it to the app. Offline (manual rendering) audio engines in tests keep their full output, so audio assertions still read real samples.

Use the same launch command with `MPCutCoreTests.xctest` when running the core suite. Pass the same SwiftPM scratch path and configuration to both build commands when using a custom build. Check the test summary in the Backstage log. For desktop integration tests, launch the app under test through Backstage itself. A script that opens a new app through Launch Services creates a separate process. The participant GUI fixture launches its editor on Backstage automatically. Use a session-specific Backstage quit for cleanup.
