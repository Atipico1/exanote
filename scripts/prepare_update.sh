#!/bin/bash
# Run only after exporting the notarized app. Sparkle tools come from its official release.
# SPARKLE_BIN=.build/sparkle-2.10.0/bin scripts/prepare_update.sh build/release-0.1.1 v0.1.1
set -euo pipefail
OUT="${1:?Output directory containing notarized Exanote.app}"
TAG="${2:?GitHub release tag}"
SPARKLE_BIN="${SPARKLE_BIN:?Path to Sparkle release bin directory}"
APP="$OUT/Exanote.app"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute "$APP"
mkdir -p "$OUT/updates"
ditto -c -k --keepParent "$APP" "$OUT/updates/Exanote.zip"
KEY_ARGS=(--account exanote)
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE"); fi
"$SPARKLE_BIN/generate_appcast" "${KEY_ARGS[@]}" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/Atipico1/exanote/releases/download/$TAG/" "$OUT/updates"
(cd "$OUT/updates" && shasum -a 256 Exanote.zip > SHA256SUMS)
echo "Upload Exanote.zip to the release, then publish updates/appcast.xml to GitHub Pages."
