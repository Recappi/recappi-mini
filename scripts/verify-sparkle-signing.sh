#!/bin/bash
set -euo pipefail

APP_PATH="${1:-${APP_PATH:-$(cd "$(dirname "$0")/.." && pwd)/build/Recappi Mini.app}}"
APP_IDENTIFIER="com.recappi.mini"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"

if [ ! -d "$APP_PATH" ]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 1
fi

if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "Sparkle.framework not found in app bundle: $SPARKLE_FRAMEWORK" >&2
    exit 1
fi

codesign_field() {
    local field="$1"
    local path="$2"
    local output
    output="$(codesign -dv --verbose=2 "$path" 2>&1)"
    awk -F= -v key="$field" '$1 == key { print $2; exit }' <<<"$output"
}

assert_identifier() {
    local label="$1"
    local path="$2"
    local expected="$3"
    local actual
    actual="$(codesign_field Identifier "$path")"

    if [ "$actual" != "$expected" ]; then
        echo "$label has unexpected code identifier: $actual (expected $expected)" >&2
        exit 1
    fi
}

assert_identifier_not_host() {
    local label="$1"
    local path="$2"
    local actual
    actual="$(codesign_field Identifier "$path")"

    if [ -z "$actual" ]; then
        echo "$label is missing a code identifier" >&2
        exit 1
    fi
    if [ "$actual" = "$APP_IDENTIFIER" ]; then
        echo "$label was signed with the host app identifier ($APP_IDENTIFIER)" >&2
        exit 1
    fi
}

assert_team_matches_host() {
    local label="$1"
    local path="$2"
    local host_team="$3"
    local actual_team

    if [ "$host_team" = "not set" ] || [ -z "$host_team" ]; then
        return
    fi

    actual_team="$(codesign_field TeamIdentifier "$path")"
    if [ "$actual_team" != "$host_team" ]; then
        echo "$label has TeamIdentifier $actual_team (expected $host_team)" >&2
        exit 1
    fi
}

APP_TEAM="$(codesign_field TeamIdentifier "$APP_PATH")"

assert_identifier "app" "$APP_PATH" "$APP_IDENTIFIER"
assert_identifier "Sparkle.framework" "$SPARKLE_FRAMEWORK" "org.sparkle-project.Sparkle"
assert_identifier "Sparkle Updater.app" "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" "org.sparkle-project.Sparkle.Updater"
assert_identifier "Sparkle Installer.xpc" "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc" "org.sparkle-project.InstallerLauncher"
assert_identifier "Sparkle Downloader.xpc" "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" "org.sparkle-project.DownloaderService"
assert_identifier_not_host "Sparkle Autoupdate" "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"

for path in \
    "$SPARKLE_FRAMEWORK" \
    "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" \
    "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" \
    "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
do
    assert_team_matches_host "$path" "$path" "$APP_TEAM"
done

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Sparkle signing verified for $APP_PATH"
