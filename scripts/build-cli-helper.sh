#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
PRODUCT_NAME="RecappiMiniSidecar"
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

DEST_DIR="$PROJECT_DIR/cli/recappi/helpers/darwin-$NPM_ARCH"
DEST="$DEST_DIR/$PRODUCT_NAME"
mkdir -p "$DEST_DIR"
cp "$BUILD_DIR/$PRODUCT_NAME" "$DEST"
chmod 755 "$DEST"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY")
    if [ "${CODESIGN_IDENTITY:-}" != "-" ]; then
        SIGN_ARGS+=(--options runtime)
        if [ "${RELEASE:-0}" = "1" ]; then
            SIGN_ARGS+=(--timestamp)
        fi
    fi
    codesign "${SIGN_ARGS[@]}" "$DEST"
    codesign --verify --strict --verbose=2 "$DEST"
fi

echo "Built $PRODUCT_NAME helper at $DEST"
