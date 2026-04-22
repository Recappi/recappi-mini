#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="RecappiMini"
APP_BUNDLE="$PROJECT_DIR/build/$APP_NAME.app"
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
RELEASE_MODE="${RELEASE:-0}"
APP_VERSION="${APP_VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1.0}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-RecappiMini Dev}"
ENTITLEMENTS_PATH="$PROJECT_DIR/RecappiMini/RecappiMini.entitlements"

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
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy Logo.png directly into Contents/Resources so `Image("Logo")` and
# `MenuBarExtra(image: "Logo")` both resolve via Bundle.main without a
# module-bundle hop. (SPM also generates a *_*.bundle next to the binary,
# but Bundle.module lookup is flaky for executableTarget on macOS.)
cp "$PROJECT_DIR/RecappiMini/Resources/Logo.png" "$APP_BUNDLE/Contents/Resources/Logo.png"
cp "$PROJECT_DIR/RecappiMini/Resources/LogoTemplate.png" "$APP_BUNDLE/Contents/Resources/LogoTemplate.png"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Recappi Mini</string>
    <key>CFBundleDisplayName</key>
    <string>Recappi Mini</string>
    <key>CFBundleIdentifier</key>
    <string>com.recappi.mini</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>RecappiMini</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Recappi Mini needs microphone access to record meetings</string>
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

# Generate AppIcon.icns from Resources/Logo.png
echo "Generating AppIcon.icns..."
LOGO_SRC="$PROJECT_DIR/RecappiMini/Resources/Logo.png"
ICONSET="$PROJECT_DIR/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
# macOS .icns requires these exact size/@2x pairs.
sips -z 16 16     "$LOGO_SRC" --out "$ICONSET/icon_16x16.png"     >/dev/null
sips -z 32 32     "$LOGO_SRC" --out "$ICONSET/icon_16x16@2x.png"  >/dev/null
sips -z 32 32     "$LOGO_SRC" --out "$ICONSET/icon_32x32.png"     >/dev/null
sips -z 64 64     "$LOGO_SRC" --out "$ICONSET/icon_32x32@2x.png"  >/dev/null
sips -z 128 128   "$LOGO_SRC" --out "$ICONSET/icon_128x128.png"   >/dev/null
sips -z 256 256   "$LOGO_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$LOGO_SRC" --out "$ICONSET/icon_256x256.png"   >/dev/null
sips -z 512 512   "$LOGO_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$LOGO_SRC" --out "$ICONSET/icon_512x512.png"   >/dev/null
cp "$LOGO_SRC" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

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
    codesign --force --deep --sign "$CODESIGN_IDENTITY" --identifier "com.recappi.mini" "$APP_BUNDLE"
fi

echo "App bundle created at: $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
