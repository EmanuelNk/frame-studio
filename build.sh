#!/bin/bash
# Builds "Frame Studio.app" next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="Frame Studio.app"
echo "→ Compiling (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/FrameStudio"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "→ Generating app icon…"
  TMP="$(mktemp -d)"
  "$BIN" --cli icon --out "$TMP/icon_1024.png"
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

echo "→ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FrameStudio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc signing skipped)"

echo "✓ Built $(pwd)/$APP"
