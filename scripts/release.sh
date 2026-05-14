#!/usr/bin/env bash
# LocalNotch release script
# Usage: ./scripts/release.sh [version]
# Example: ./scripts/release.sh 0.1.1-beta
# Produces: LocalNotch.zip in the repo root, ready to upload to GitHub Releases.

set -euo pipefail

VERSION="${1:-0.2.0-beta}"
APP_NAME="LocalNotch"
BUNDLE_ID="com.localnotch"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/release"
STAGING="$REPO_ROOT/.build/staging"
APP_BUNDLE="$STAGING/$APP_NAME.app"
ZIP_PATH="$REPO_ROOT/LocalNotch.zip"

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

# Ad-hoc sign with a STABLE designated requirement based on the bundle identifier.
# Without this override, ad-hoc signing falls back to a cdhash-based designated
# requirement, which changes on every rebuild. macOS TCC keys permissions to the
# designated requirement, so a cdhash-based one means Screen Recording / Screen
# Capture permission has to be re-granted after every rebuild. Pinning the DR to
# the bundle identifier keeps it stable across rebuilds — grant once, works forever.
echo "==> Signing (ad-hoc, stable identifier-based designated requirement)"
codesign --force --deep --sign - \
    --identifier "$BUNDLE_ID" \
    -r="designated => identifier \"$BUNDLE_ID\"" \
    "$APP_BUNDLE"

# Verify the app identity is stable before packaging. Screen Recording permission
# is keyed to this identity, so a cdhash-based ad-hoc requirement will break TCC
# persistence across rebuilds/reinstalls.
SIGNING_INFO=$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)
IDENTIFIER=$(printf '%s\n' "$SIGNING_INFO" | sed -n 's/^Identifier=//p' | head -n 1)
DR=$(codesign -d -r- "$APP_BUNDLE" 2>&1 | grep "designated =>" || true)
echo "    $DR"
if [ "$IDENTIFIER" != "$BUNDLE_ID" ]; then
    echo "ERROR: codesign identifier is '$IDENTIFIER', expected '$BUNDLE_ID'."
    exit 1
fi
if echo "$DR" | grep -q "cdhash"; then
    echo "ERROR: designated requirement is cdhash-based — TCC permissions will not persist across rebuilds."
    exit 1
fi
if ! echo "$DR" | grep -q "identifier \"$BUNDLE_ID\""; then
    echo "ERROR: designated requirement does not contain identifier '$BUNDLE_ID'."
    exit 1
fi
if echo "$SIGNING_INFO" | grep -q "Info.plist=not bound"; then
    echo "ERROR: Info.plist is not sealed into the code signature."
    exit 1
fi

# Zip
echo "==> Creating LocalNotch.zip"
rm -f "$ZIP_PATH"
cd "$STAGING"
zip -r "$ZIP_PATH" "$APP_NAME.app"

echo ""
echo "Done: $ZIP_PATH"
echo "Upload this file to GitHub Releases and mark as Pre-release."
echo "Users must right-click → Open the first time to bypass Gatekeeper."
