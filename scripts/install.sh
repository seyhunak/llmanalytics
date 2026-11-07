#!/usr/bin/env bash
# Build from source and install into /Applications (no Gatekeeper prompt, since it's built locally).
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHS="${ARCHS:---arch $(uname -m)}" ./scripts/build-app.sh
osascript -e 'quit app "LLM Analytics"' 2>/dev/null || true
rm -rf "/Applications/LLM Analytics.app"
cp -R "dist/LLM Analytics.app" /Applications/
open "/Applications/LLM Analytics.app"
echo "✓ Installed to /Applications/LLM Analytics.app"
