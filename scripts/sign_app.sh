#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Path to Exanote.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
PY="$APP/Contents/Resources/python"
echo "▸ Signing ($SIGN_IDENTITY)"
SIGN=(codesign --force --sign "$SIGN_IDENTITY" --timestamp=none)
if [ "$SIGN_IDENTITY" != "-" ]; then
  SIGN=(codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime --entitlements "$ROOT/scripts/python.entitlements")
fi
find "$PY" -type f \( -name '*.so' -o -name '*.dylib' \) -print0 | xargs -0 "${SIGN[@]}" 2>/dev/null
"${SIGN[@]}" "$PY/bin/python"
# Sign Sparkle's nested helpers inside-out with the same Developer ID as the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  HELPER_SIGN=(codesign --force --sign "$SIGN_IDENTITY" --timestamp=none)
  if [ "$SIGN_IDENTITY" != "-" ]; then
    HELPER_SIGN=(codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime)
  fi
  "${HELPER_SIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  "${HELPER_SIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  "${HELPER_SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
  "${HELPER_SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
  "${HELPER_SIGN[@]}" "$SPARKLE"
fi
"${SIGN[@]}" "$APP"
codesign --verify --strict "$APP"

