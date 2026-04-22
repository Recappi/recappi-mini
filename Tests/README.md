# Recappi Mini Automation

This repo now has a sidecar Apple-native automation setup that validates the
real packaged app while keeping the test harness separate from runtime source
organization.

## What is included

- `RecappiMiniAutomation.xcodeproj`
  A sidecar Xcode project for `XCTest` / `XCUITest`.
- `Tests/RecappiMiniCoreTests`
  Core automation harness checks for scripts, fixtures, and local assumptions.
- `Tests/RecappiMiniUITests`
  UI smoke coverage plus cloud-flow E2E that launch the packaged app bundle.
- `Tests/AutomationHost`
  A tiny host app target used only to keep the UI-test target valid inside
  Xcode.
- `Tests/Fixtures/Audio`
  Generated audio fixtures for upload/export automation.
- `scripts/generate-test-audio-fixtures.sh`
  Creates deterministic spoken fixtures with built-in macOS tools.
- `scripts/run-core-tests.sh`
  Runs the sidecar core test target.
- `scripts/run-ui-smoke-tests.sh`
  Runs the launch-only UI smoke target.
- `scripts/run-automation-tests.sh`
  Builds fixtures, builds the app bundle, then runs the full automation scheme.

## Runtime hooks used by automation

The app now exposes deterministic UI-test hooks so XCUITest can exercise the
real cloud processing flow without depending on live microphone capture:

1. `RECAPPI_UI_TEST=1`
   Enables UI-test mode inside the app.
2. `RECAPPI_TEST_AUTH_TOKEN=<value>`
   Seeds the Recappi Cloud bearer token and lets the app bootstrap directly
   into a signed-in state.
3. `RECAPPI_TEST_BACKEND_URL=<url>`
   Overrides the backend base URL when needed.
4. `RECAPPI_TEST_AUDIO_FIXTURE=<path>`
   Replaces live recording capture with a bundled `recording.m4a` fixture.
5. `RECAPPI_TEST_ALLOW_INTERACTIVE_OAUTH=1`
   Opts the UI suite into a real browser-based Google/GitHub sign-in. This is
   disabled by default because unattended runs should seed
   `RECAPPI_TEST_AUTH_TOKEN` instead.

The runtime also exposes stable accessibility identifiers for the Settings
auth flow, recording controls, processing labels, retry button, and result
actions. UI automation now seeds bearer-token auth directly.

## Typical local commands

```bash
./scripts/generate-test-audio-fixtures.sh
./scripts/run-core-tests.sh
./scripts/run-ui-smoke-tests.sh
./scripts/run-automation-tests.sh
```

For unattended end-to-end runs, prefer a seeded bearer token:

```bash
RECAPPI_TEST_AUTH_TOKEN=... ./scripts/run-automation-tests.sh
```

If you intentionally want to exercise the real browser login flow, opt in
explicitly:

```bash
RECAPPI_TEST_ALLOW_INTERACTIVE_OAUTH=1 ./scripts/run-automation-tests.sh \
  -only-testing:RecappiMiniUITests/RecappiMiniEndToEndSkeletonUITests/testPersistedSessionTranscriptionFlow
```

## Expected environment variables

- `RECAPPI_TEST_AUTH_TOKEN`
  Bearer token used by live backend UI tests.
- `RECAPPI_TEST_BACKEND_URL`
  Optional backend override for cloud-flow UI tests.
- `RECAPPI_TEST_APP`
  Optional override for the built app bundle path. Defaults to
  `build/RecappiMini.app`.
- `RECAPPI_TEST_ALLOW_INTERACTIVE_OAUTH`
  Optional opt-in for manual interactive OAuth smoke. Leave this unset for
  unattended runs.

## Known caveat

If XCUITest fails before assertions with an error like `Timed out while enabling
automation mode`, that is a system-level UI automation / TCC runner problem on
the current machine rather than an app assertion failure. The shell probes and
package-level tests can still pass while this macOS automation mode remains
blocked.
