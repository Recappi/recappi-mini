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
2. `RECAPPI_TEST_COOKIE=<value>`
   Seeds the Better Auth session cookie and pre-fills the Settings field.
3. `RECAPPI_TEST_BACKEND_URL=<url>`
   Overrides the backend base URL when needed.
4. `RECAPPI_TEST_AUDIO_FIXTURE=<path>`
   Replaces live recording capture with a bundled `recording.m4a` fixture.
5. `RECAPPI_TEST_DISABLE_SUMMARY=1`
   Forces transcript-only E2E.
6. `RECAPPI_TEST_SUMMARY_STUB=1`
   Exercises the summary/action-items UI path using a deterministic stub after
   transcript fetch, so automation does not depend on external LLM credentials.

The runtime also exposes stable accessibility identifiers for the Settings
cookie flow, recording controls, processing labels, retry button, and result
actions.

## Typical local commands

```bash
./scripts/generate-test-audio-fixtures.sh
./scripts/run-core-tests.sh
./scripts/run-ui-smoke-tests.sh
./scripts/run-automation-tests.sh
```

## Expected environment variables

- `RECAPPI_TEST_COOKIE`
  Better Auth session cookie value used by live backend UI tests.
- `RECAPPI_TEST_BACKEND_URL`
  Optional backend override for cloud-flow UI tests.
- `RECAPPI_TEST_APP`
  Optional override for the built app bundle path. Defaults to
  `build/RecappiMini.app`.
- `RECAPPI_TEST_DISABLE_SUMMARY`
  Optional switch to keep automation on transcript-only coverage.
- `RECAPPI_TEST_SUMMARY_STUB`
  Optional switch to generate deterministic summary files during UI automation.

## Known caveat

If XCUITest fails before assertions with an error like `Timed out while enabling
automation mode`, that is a system-level UI automation / TCC runner problem on
the current machine rather than an app assertion failure. The shell probes and
package-level tests can still pass while this macOS automation mode remains
blocked.
