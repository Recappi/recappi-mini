#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="RecappiMini"
BUILD_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/debug"
APP_BUNDLE="$PROJECT_DIR/build/$APP_NAME.app"

echo "Building..."
cd "$PROJECT_DIR"
swift build

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
cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
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
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>RecappiMini</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Recappi Mini needs microphone access to record meetings</string>
    <!-- Allow HTTP for internal LMHub / Ollama / LM Studio / localhost
         endpoints. OpenAI and Gemini still enforce HTTPS naturally. -->
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

# Codesign with persistent self-signed certificate so TCC permissions survive rebuilds
codesign --force --deep --sign "RecappiMini Dev" --identifier "com.recappi.mini" "$APP_BUNDLE"

echo "App bundle created at: $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
