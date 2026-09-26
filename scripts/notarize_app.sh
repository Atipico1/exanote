#!/bin/bash
# Notarize a Developer ID-signed Exanote app and its downloadable DMG.
# Run after scripts/build_app.sh with NOTARY_PROFILE set to a notarytool Keychain profile.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/build}"
PROFILE="${NOTARY_PROFILE:-exanote}"
APP="$OUT/Exanote.app"
DMG="$OUT/Exanote.dmg"
ZIP="$OUT/Exanote-notary.zip"

[ -d "$APP" ] || { echo "Missing $APP; run scripts/build_app.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
signature_details="$(codesign -dvv "$APP" 2>&1)"
if ! grep -q '^Authority=Developer ID Application:' <<< "$signature_details"; then
  echo "Exanote.app needs a Developer ID Application signature" >&2
  echo "$signature_details" >&2
  exit 1
fi

submit() {
  local artifact="$1" result status submission_id
  result="$(mktemp)"
  if ! xcrun notarytool submit "$artifact" --keychain-profile "$PROFILE" --wait --output-format json >"$result"; then
    cat "$result" >&2
    rm -f "$result"
    return 1
  fi
  status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$result")"
  submission_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$result")"
  rm -f "$result"
  if [ "$status" != Accepted ]; then
    echo "Notarization of $artifact: $status (submission $submission_id)" >&2
    if [ -n "$submission_id" ]; then
      xcrun notarytool log "$submission_id" --keychain-profile "$PROFILE" >&2 || true
    fi
    return 1
  fi
  echo "Accepted: $artifact ($submission_id)"
}

echo "▸ Notarizing the app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
submit "$ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"

echo "▸ Rebuilding the DMG with the stapled app"
STAGE="$OUT/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Exanote.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -ov -volname "Exanote" -srcfolder "$STAGE" -format ULFO "$DMG"
rm -rf "$STAGE"

echo "▸ Notarizing the DMG"
submit "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type execute --verbose "$APP"
echo "✓ Notarized distribution: $DMG"
