#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/xcode/DerivedData"
RESULT_BUNDLE="$ROOT_DIR/.build/xcode/RecappiMiniCoreTests.xcresult"

"$ROOT_DIR/scripts/generate-test-audio-fixtures.sh"

rm -rf "$RESULT_BUNDLE"

xcodebuild \
  -project "$ROOT_DIR/RecappiMiniAutomation.xcodeproj" \
  -scheme RecappiMiniCoreTests \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -resultBundlePath "$RESULT_BUNDLE" \
  test \
  "$@"
