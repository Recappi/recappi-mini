#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/xcode/DerivedData"
RESULT_BUNDLE="$ROOT_DIR/.build/xcode/RecappiMiniUISmokeTests.xcresult"
AUTH_TOKEN_OVERRIDE_FILE="$ROOT_DIR/.build/xcode/recappi_test_auth_token.txt"
BACKEND_OVERRIDE_FILE="$ROOT_DIR/.build/xcode/recappi_test_backend_url.txt"
RECORDINGS_ROOT_OVERRIDE_FILE="$ROOT_DIR/.build/xcode/recappi_test_recordings_root.txt"

"$ROOT_DIR/scripts/generate-test-audio-fixtures.sh"
"$ROOT_DIR/scripts/build-app.sh"

export RECAPPI_TEST_APP="${RECAPPI_TEST_APP:-$ROOT_DIR/build/RecappiMini.app}"
export RECAPPI_TEST_AUDIO_FIXTURE="${RECAPPI_TEST_AUDIO_FIXTURE:-$ROOT_DIR/Tests/Fixtures/Audio/automation-recording.m4a}"
export RECAPPI_TEST_UPLOAD_FIXTURE="${RECAPPI_TEST_UPLOAD_FIXTURE:-$ROOT_DIR/Tests/Fixtures/Audio/automation-upload.wav}"

mkdir -p "$ROOT_DIR/.build/xcode"
if [[ -n "${RECAPPI_TEST_AUTH_TOKEN:-}" ]]; then
  printf '%s' "$RECAPPI_TEST_AUTH_TOKEN" > "$AUTH_TOKEN_OVERRIDE_FILE"
else
  rm -f "$AUTH_TOKEN_OVERRIDE_FILE"
fi

if [[ -n "${RECAPPI_TEST_BACKEND_URL:-}" ]]; then
  printf '%s' "$RECAPPI_TEST_BACKEND_URL" > "$BACKEND_OVERRIDE_FILE"
else
  rm -f "$BACKEND_OVERRIDE_FILE"
fi

printf '%s' "${RECAPPI_TEST_RECORDINGS_ROOT:-$HOME/Documents/Recappi Mini}" > "$RECORDINGS_ROOT_OVERRIDE_FILE"

rm -rf "$RESULT_BUNDLE"
pkill -f "$ROOT_DIR/build/RecappiMini.app/Contents/MacOS/RecappiMini" >/dev/null 2>&1 || true
pkill -f "RecappiMiniUITests-Runner.app/Contents/MacOS/RecappiMiniUITests-Runner" >/dev/null 2>&1 || true

xcodebuild \
  -project "$ROOT_DIR/RecappiMiniAutomation.xcodeproj" \
  -scheme RecappiMiniUITests \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:RecappiMiniUITests/AAARecappiMiniLaunchSmokeUITests \
  test \
  "$@"
