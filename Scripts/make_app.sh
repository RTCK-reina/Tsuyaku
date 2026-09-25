#!/bin/bash
# Build Tsuyaku.app from the SwiftPM release binary.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Tsuyaku"
BUNDLE="dist/${APP_NAME}.app"

echo "== building (release) =="
swift build -c release --product "$APP_NAME"

BIN=".build/release/$APP_NAME"
echo "== bundling $BUNDLE =="
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/" 2>/dev/null || true

# Ad-hoc sign so TCC (mic permission) works with a stable bundle identity.
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true

echo "== done =="
echo "Run:  open $BUNDLE"
echo "Binary: $BUNDLE/Contents/MacOS/$APP_NAME"
