#!/bin/bash
# Regenerates the committed icon artwork from Tools/render-icon.swift:
# Resources/AppIcon.icns (macOS 14/15) and the foreground layer of Resources/AppIcon.icon (macOS 26+).
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swift Tools/render-icon.swift "$TMP"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
mkdir -p Resources/AppIcon.icon/Assets
cp "$TMP/layers/foreground.png" Resources/AppIcon.icon/Assets/foreground.png
echo "Updated Resources/AppIcon.icns and Resources/AppIcon.icon/Assets/foreground.png"
