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
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Recappi Mini needs microphone access to record meetings</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Recappi Mini uses speech recognition to transcribe meeting recordings</string>
</dict>
</plist>
EOF

# Codesign with persistent self-signed certificate so TCC permissions survive rebuilds
codesign --force --deep --sign "RecappiMini Dev" --identifier "com.recappi.mini" "$APP_BUNDLE"

echo "App bundle created at: $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
