#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) release "LLM Analytics.app" into ./dist
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="dist/LLM Analytics.app"

ARCHS="${ARCHS:---arch arm64 --arch x86_64}"
echo "▸ Compiling ($ARCHS)"
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/LLMAnalytics"

echo "▸ Rendering icon"
rm -rf build/AppIcon.iconset && mkdir -p build
swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

echo "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LLMAnalytics"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

echo "▸ Signing (${SIGN_IDENTITY:-ad-hoc})"
codesign --force --deep --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP"
echo "✓ $APP (v$VERSION)"
