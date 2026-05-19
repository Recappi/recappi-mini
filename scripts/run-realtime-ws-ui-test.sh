#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
BACKEND_PID=""

cleanup() {
  if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" 2>/dev/null; then
    kill "$BACKEND_PID" 2>/dev/null || true
  fi
  rm -f /tmp/recappi-mini-fake-realtime-backend-url
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"

/usr/bin/python3 Tests/Fixtures/Realtime/fake_realtime_backend.py \
  >"$TMP_DIR/backend.out" \
  2>"$TMP_DIR/backend.err" &
BACKEND_PID="$!"

for _ in {1..100}; do
  if [[ -s "$TMP_DIR/backend.out" ]]; then
    break
  fi
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    cat "$TMP_DIR/backend.err" >&2 || true
    exit 1
  fi
  sleep 0.05
done

PORT_LINE="$(head -n 1 "$TMP_DIR/backend.out" || true)"
if [[ "$PORT_LINE" != PORT=* ]]; then
  echo "Fake realtime backend did not print a PORT line." >&2
  cat "$TMP_DIR/backend.err" >&2 || true
  exit 1
fi

BACKEND_URL="http://127.0.0.1:${PORT_LINE#PORT=}"
echo "Using fake realtime backend at $BACKEND_URL"
echo "$BACKEND_URL" >/tmp/recappi-mini-fake-realtime-backend-url

/usr/bin/swift "$ROOT_DIR/scripts/select-abc-input-source.swift" || \
  echo "warning: failed to switch UI tests to ABC keyboard input source" >&2

RECAPPI_TEST_FAKE_REALTIME_BACKEND_URL="$BACKEND_URL" \
  xcodebuild test \
    -project RecappiMiniAutomation.xcodeproj \
    -scheme RecappiMiniUITests \
    -destination "platform=macOS" \
    -only-testing:RecappiMiniUITests/AAARecappiMiniLaunchSmokeUITests/testRealtimeWebSocketDisconnectReconnectsAndPreservesCaptions
