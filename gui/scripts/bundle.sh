#!/bin/bash
# Builds a release binary and wraps it into gui/build/Transcrio.app.
# A bare SwiftPM executable has no proper activation or Dock icon; the bundle does.
set -euo pipefail

GUI="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$GUI/build/Transcrio.app"
VERSION="${TRANSCRIBE_APP_VERSION:-0.1.0}"

cd "$GUI"
swift build -c release --product TranscribeApp
BIN="$(swift build -c release --show-bin-path)/TranscribeApp"

rm -rf "$APP" "$GUI/build/Transcribe.app"  # also the bundle from before the rename
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Transcrio"
# SwiftPM resource bundles (the app icon SVGs); AppIconResources looks in Contents/Resources.
for bundle in "$(dirname "$BIN")"/*_*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

ICON_KEY=""
if [ -x "$GUI/scripts/make-icon.sh" ]; then
    "$GUI/scripts/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns" && ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Transcrio</string>
    <key>CFBundleDisplayName</key><string>Transcrio</string>
    <key>CFBundleIdentifier</key><string>io.github.gitkeniwo.transcribe</string>
    <key>CFBundleExecutable</key><string>Transcrio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    $ICON_KEY
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper and TCC treat the bundle consistently on this Mac.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
