#!/bin/bash
# Builds "Frame Studio.app" next to this script.
#   ./build.sh            build only
#   ./build.sh --install  build, then install (or update) it in /Applications
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg (use --install)" >&2; exit 2 ;;
  esac
done

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

if [ "$INSTALL" = 1 ]; then
  DEST="/Applications/$APP"
  if pgrep -x FrameStudio >/dev/null; then
    echo "  Note: Frame Studio is running; quit and reopen it to use the new version."
  fi
  echo "→ Installing to $DEST…"
  # Replace rather than overwrite in place, so a running copy keeps working until it's reopened.
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # Make Finder, Spotlight and the Dock pick up the new version and its icon.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  touch "$DEST"
  echo "✓ Installed $DEST"
fi
