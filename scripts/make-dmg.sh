#!/usr/bin/env bash
# Packages dist/LLM Analytics.app into a drag-to-Applications DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d "dist/LLM Analytics.app" ] || ./scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' 'dist/LLM Analytics.app/Contents/Info.plist')"
STAGE="build/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "dist/LLM Analytics.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
OUT="dist/LLMAnalytics-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "LLM Analytics" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "✓ $OUT"
