#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-Recappi Mini}"
APP_PATH="${APP_PATH:-$ROOT_DIR/build/$APP_NAME.app}"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/build/$APP_NAME.dmg}"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

if [ ! -d "$APP_PATH" ]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 1
fi

DMG_DIR="$(dirname "$DMG_PATH")"
STAGING_DIR="$(mktemp -d "$DMG_DIR/dmg-staging.XXXXXX")"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$DMG_DIR"

ditto "$APP_PATH" "$STAGING_DIR/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
fi
