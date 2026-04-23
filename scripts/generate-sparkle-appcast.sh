#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.8.1}"
SPARKLE_CACHE_DIR="${SPARKLE_CACHE_DIR:-$ROOT_DIR/.build/vendor}"
SPARKLE_DIST_DIR="$SPARKLE_CACHE_DIR/Sparkle-$SPARKLE_VERSION"
SPARKLE_ARCHIVE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

ARCHIVES_DIR="${1:-}"
if [ -z "$ARCHIVES_DIR" ]; then
    echo "Usage: $0 <archives-dir>" >&2
    exit 1
fi

DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:?DOWNLOAD_URL_PREFIX is required}"
SPARKLE_PRIVATE_ED_KEY="${SPARKLE_PRIVATE_ED_KEY:?SPARKLE_PRIVATE_ED_KEY is required}"
PRODUCT_LINK_URL="${PRODUCT_LINK_URL:-https://github.com/Recappi/recappi-mini/releases}"
FULL_RELEASE_NOTES_URL="${FULL_RELEASE_NOTES_URL:-$PRODUCT_LINK_URL}"
APPCAST_FILENAME="${APPCAST_FILENAME:-appcast.xml}"
APPCAST_OUTPUT_PATH="${APPCAST_OUTPUT_PATH:-$ARCHIVES_DIR/$APPCAST_FILENAME}"

mkdir -p "$SPARKLE_CACHE_DIR"

if [ ! -x "$SPARKLE_DIST_DIR/bin/generate_appcast" ]; then
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    curl -L "$SPARKLE_ARCHIVE_URL" -o "$TMP_DIR/Sparkle.tar.xz"
    tar -xf "$TMP_DIR/Sparkle.tar.xz" -C "$TMP_DIR"

    rm -rf "$SPARKLE_DIST_DIR"
    mv "$TMP_DIR" "$SPARKLE_DIST_DIR"
    trap - EXIT
fi

echo "$SPARKLE_PRIVATE_ED_KEY" | "$SPARKLE_DIST_DIR/bin/generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --release-notes-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --embed-release-notes \
    --full-release-notes-url "$FULL_RELEASE_NOTES_URL" \
    --link "$PRODUCT_LINK_URL" \
    -o "$APPCAST_OUTPUT_PATH" \
    "$ARCHIVES_DIR"
