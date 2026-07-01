#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="RecordAudio"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

ARCH="$(uname -m)"
echo "Building $APP_NAME for ${ARCH} (min macOS 13.0)…"

swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macos13.0" \
  -framework SwiftUI -framework AppKit \
  -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia \
  Sources/*.swift \
  -o "$MACOS_DIR/$APP_NAME"

cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$RES_DIR/AppIcon.icns"
else
  echo "⚠️  Resources/AppIcon.icns missing — run ./Icon/build_icon.sh first."
fi

# Ad-hoc code signature. This stabilizes the identity macOS ties the Screen
# Recording permission to, so the grant survives rebuilds.
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "✅ Built $APP_DIR"
echo "   Run it with:  open \"$APP_DIR\""
