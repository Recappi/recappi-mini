#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
PRODUCT_NAME="RecappiMiniSidecar"
APP_BUNDLE_NAME="Recappi Recorder.app"
ENTITLEMENTS_PATH="$PROJECT_DIR/RecappiMiniSidecar/RecappiMiniSidecar.entitlements"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    arm64) NPM_ARCH="arm64" ;;
    x86_64) NPM_ARCH="x64" ;;
    *)
        echo "Unsupported macOS helper build architecture: $HOST_ARCH" >&2
        exit 1
        ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
    echo "RecappiMiniSidecar can only be built on macOS." >&2
    exit 1
fi

BUILD_ARGS=(--product "$PRODUCT_NAME")
if [ "$BUILD_CONFIG" = "release" ]; then
    BUILD_ARGS=(-c release "${BUILD_ARGS[@]}")
fi

cd "$PROJECT_DIR"
swift build "${BUILD_ARGS[@]}"
BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

DEST_DIR="$PROJECT_DIR/cli/helpers/darwin-$NPM_ARCH"
APP_BUNDLE="$DEST_DIR/$APP_BUNDLE_NAME"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
DEST="$MACOS_DIR/$PRODUCT_NAME"
mkdir -p "$DEST_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
cp "$BUILD_DIR/$PRODUCT_NAME" "$DEST"
cp "$PROJECT_DIR/RecappiMiniSidecar/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod 755 "$DEST"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY" --entitlements "$ENTITLEMENTS_PATH")
    if [ "${CODESIGN_IDENTITY:-}" != "-" ]; then
        SIGN_ARGS+=(--options runtime)
        if [ "${RELEASE:-0}" = "1" ]; then
            SIGN_ARGS+=(--timestamp)
        fi
    fi
    codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
    codesign --verify --strict --verbose=2 "$APP_BUNDLE"
fi

echo "Built $PRODUCT_NAME helper app at $APP_BUNDLE"
