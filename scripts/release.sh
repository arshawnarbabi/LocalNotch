#!/usr/bin/env bash
# LocalNotch release script
# Usage: ./scripts/release.sh [version]
# Example: ./scripts/release.sh 0.1.0-beta
# Produces: LocalNotch.zip in the repo root, ready to upload to GitHub Releases.

set -euo pipefail

VERSION="${1:-0.1.0-beta}"
APP_NAME="LocalNotch"
BUNDLE_ID="com.localnotch"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/release"
STAGING="$REPO_ROOT/.build/staging"
APP_BUNDLE="$STAGING/$APP_NAME.app"

echo "==> Building $APP_NAME v$VERSION"

cd "$REPO_ROOT"

# Build release binary (Apple Silicon only)
swift build -c release --arch arm64

BINARY="$BUILD_DIR/$APP_NAME"
if [ ! -f "$BINARY" ]; then
  echo "ERROR: Binary not found at $BINARY"
  exit 1
fi

# Assemble .app bundle
echo "==> Assembling $APP_NAME.app"
rm -rf "$STAGING"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$REPO_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Write Info.plist with current version
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>LocalNotch captures a screenshot to send to your local AI model for analysis. Nothing leaves your machine.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign (no Apple Developer account required)
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"

# Zip
echo "==> Creating LocalNotch.zip"
cd "$STAGING"
zip -r "$REPO_ROOT/LocalNotch.zip" "$APP_NAME.app"

echo ""
echo "Done: $REPO_ROOT/LocalNotch.zip"
echo "Upload this file to GitHub Releases and mark as Pre-release."
echo "Users must right-click → Open the first time to bypass Gatekeeper."
