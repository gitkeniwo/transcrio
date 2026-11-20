#!/bin/bash
# Renders the app icon SVG and packs it into an .icns. Usage: make-icon.sh <out.icns> [icon.svg]
set -euo pipefail
GUI="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$GUI/build/AppIcon.icns}"
SVG="${2:-$GUI/icons/a3b-lcd-clay.svg}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swift "$GUI/scripts/make-icon.swift" "$TMP/AppIcon.iconset" "$SVG"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$OUT"
