#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="RecappiMini"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Recappi Mini}"
APP_BUNDLE="${APP_BUNDLE:-$PROJECT_DIR/build/$APP_DISPLAY_NAME.app}"
LEGACY_APP_BUNDLE="$PROJECT_DIR/build/$APP_NAME.app"
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
RELEASE_MODE="${RELEASE:-0}"
APP_VERSION="${APP_VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-RecappiMini Dev}"
ENTITLEMENTS_PATH="$PROJECT_DIR/RecappiMini/RecappiMini.entitlements"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/Recappi/recappi-mini/sparkle-appcast/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-/1OzWfoXSQ2w+rIi6pKRn8X8egyv+T/dQGOyG7QJj0M=}"

if [ "$CODESIGN_IDENTITY" = "-" ] && [ "${CI:-}" != "true" ] && [ "${ALLOW_ADHOC_CODESIGN:-0}" != "1" ]; then
    cat >&2 <<'EOF'
error: local RecappiMini builds must use the stable "RecappiMini Dev" signing identity.

Do not run `CODESIGN_IDENTITY=- ./scripts/build-app.sh` for local UI verification:
ad-hoc signing changes the code identity on every build and repeatedly resets
macOS Screen Recording/TCC permissions.

Use `./scripts/build-app.sh` instead. If you are in an isolated environment that
really requires ad-hoc signing, set ALLOW_ADHOC_CODESIGN=1 explicitly.
EOF
    exit 1
fi

if [ "$RELEASE_MODE" = "1" ] && [ "$BUILD_CONFIG" = "debug" ]; then
    BUILD_CONFIG="release"
fi

BUILD_ARGS=()
if [ "$BUILD_CONFIG" = "release" ]; then
    BUILD_ARGS+=("-c" "release")
fi

echo "Building..."
cd "$PROJECT_DIR"
swift build "${BUILD_ARGS[@]}"
BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE" "$LEGACY_APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    ditto "$BUILD_DIR/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

# Copy Logo.png directly into Contents/Resources so `Image("Logo")` and
# `MenuBarExtra(image: "Logo")` both resolve via Bundle.main without a
# module-bundle hop. (SPM also generates a *_*.bundle next to the binary,
# but Bundle.module lookup is flaky for executableTarget on macOS.)
cp "$PROJECT_DIR/RecappiMini/Resources/Logo.png" "$APP_BUNDLE/Contents/Resources/Logo.png"
cp "$PROJECT_DIR/RecappiMini/Resources/LogoTemplate.png" "$APP_BUNDLE/Contents/Resources/LogoTemplate.png"
cp "$PROJECT_DIR/RecappiMini/Resources/GoogleG.png" "$APP_BUNDLE/Contents/Resources/GoogleG.png"
cp "$PROJECT_DIR/RecappiMini/Resources/GitHubMark.png" "$APP_BUNDLE/Contents/Resources/GitHubMark.png"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.recappi.mini</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUFeedURL</key>
    <string>$SPARKLE_FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_ED_KEY</string>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>RecappiMini</string>
    <key>CFBundleIconFile</key>
    <string>Recappi</string>
    <key>CFBundleIconName</key>
    <string>Recappi</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.recappi.mini.auth</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>recappi</string>
            </array>
        </dict>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Recappi Mini needs microphone access to record meetings</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Recappi Mini uses speech recognition to show live captions while recording meetings.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Recappi Mini uses your active browser tab URL and title to detect meeting pages in Safari and Chrome.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Recappi Mini needs system audio recording access to capture meeting audio from your Mac</string>
    <!-- Allow HTTP for local backend development / localhost overrides. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

# Compile the Icon Composer bundle (RecappiMini/Resources/Recappi.icon) via
# actool. The .icon file is passed directly as actool's document argument
# (no .xcassets wrapper) — that's the only mode that emits Assets.car +
# fallback Recappi.icns for the new Liquid Glass icon format.
echo "Compiling Recappi.icon via actool..."
PARTIAL_PLIST="$PROJECT_DIR/build/RecappiIconPartial.plist"
xcrun actool "$PROJECT_DIR/RecappiMini/Resources/Recappi.icon" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    --output-format human-readable-text \
    --notices --warnings \
    --output-partial-info-plist "$PARTIAL_PLIST" \
    --app-icon Recappi \
    --include-all-app-icons \
    --enable-on-demand-resources NO \
    --development-region en \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --platform macosx \
    > /dev/null

# Merge CFBundleIconName / CFBundleIconFile written by actool into Info.plist.
/usr/libexec/PlistBuddy -c "Merge $PARTIAL_PLIST" "$APP_BUNDLE/Contents/Info.plist"
rm -f "$PARTIAL_PLIST"

if [ "$RELEASE_MODE" = "1" ] && [ "$CODESIGN_IDENTITY" != "-" ]; then
    codesign \
        --force \
        --deep \
        --sign "$CODESIGN_IDENTITY" \
        --identifier "com.recappi.mini" \
        --options runtime \
        --entitlements "$ENTITLEMENTS_PATH" \
        --timestamp \
        "$APP_BUNDLE"
else
    # Preserve the existing local-dev behavior unless callers opt into
    # release signing or explicitly request ad-hoc signing with `-`.
    codesign --force --deep --sign "$CODESIGN_IDENTITY" --identifier "com.recappi.mini" --entitlements "$ENTITLEMENTS_PATH" "$APP_BUNDLE"
fi

if [ "$APP_BUNDLE" != "$LEGACY_APP_BUNDLE" ]; then
    ln -s "$(basename "$APP_BUNDLE")" "$LEGACY_APP_BUNDLE"
fi

echo "App bundle created at: $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
