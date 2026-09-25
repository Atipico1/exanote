#!/bin/bash
# Build a self-contained "Exanote.app" (Swift app + its own Python) and a DMG.
#   scripts/build_app.sh                      ad-hoc signature, for local testing
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build_app.sh
# AI models are not bundled; the app downloads them (~5.3 GB) on first use.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/build}"
PY_VERSION="3.12"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
cd "$ROOT"

echo "▸ Building the Swift app"
xcodegen generate >/dev/null
xcodebuild -project Exanote.xcodeproj -scheme Exanote -configuration Release -derivedDataPath "$OUT/derived" -quiet build
APP="$OUT/Exanote.app"
rm -rf "$APP"
ditto "$OUT/derived/Build/Products/Release/Exanote.app" "$APP"

echo "▸ Adding a relocatable CPython $PY_VERSION"
uv python install "$PY_VERSION" >/dev/null
# Take uv's standalone install directly; "uv python find" would return this repo's .venv.
PYTHON_HOME="$(ls -d "$(uv python dir)"/cpython-"$PY_VERSION".*-macos-aarch64-none | sort -V | tail -1)"
[ -x "$PYTHON_HOME/bin/python$PY_VERSION" ] || { echo "No standalone CPython $PY_VERSION found" >&2; exit 1; }
PY="$APP/Contents/Resources/python"
ditto "$PYTHON_HOME" "$PY"
rm -f "$PY"/lib/python3.*/EXTERNALLY-MANAGED

echo "▸ Installing Exanote and its runtime dependencies"
# --compile-bytecode: the app never writes .pyc files into its own (signed) bundle at runtime.
uv pip install --python "$PY/bin/python3" --overrides scripts/bundle-overrides.txt --compile-bytecode --quiet "$ROOT"

echo "▸ Removing what the app never loads"
STDLIB="$(echo "$PY"/lib/python3.*)"
rm -rf "$PY/include" "$PY/share" "$PY"/lib/tcl* "$PY"/lib/tk* "$PY"/lib/itcl* "$PY"/lib/thread* \
  "$STDLIB"/test "$STDLIB"/idlelib "$STDLIB"/tkinter "$STDLIB"/turtledemo "$STDLIB"/ensurepip "$STDLIB"/config-*
rm -rf "$STDLIB"/site-packages/pip "$STDLIB"/site-packages/pip-*
# transformers and mlx-vlm ship hundreds of model families; only a few are ever imported, and
# those compile in memory in milliseconds, so keep bytecode for everything except model folders.
find "$STDLIB"/site-packages/transformers/models "$STDLIB"/site-packages/mlx_vlm/models -type d -name __pycache__ -prune -exec rm -rf {} +
find "$PY/bin" -mindepth 1 ! -name 'python*' -delete

echo "▸ Signing ($SIGN_IDENTITY)"
SIGN=(codesign --force --sign "$SIGN_IDENTITY" --timestamp=none)
if [ "$SIGN_IDENTITY" != "-" ]; then
  SIGN=(codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime --entitlements scripts/python.entitlements)
fi
find "$PY" -type f \( -name '*.so' -o -name '*.dylib' \) -print0 | xargs -0 "${SIGN[@]}" 2>/dev/null
"${SIGN[@]}" "$PY/bin/python"
"${SIGN[@]}" "$APP"
codesign --verify --strict "$APP"

echo "▸ Making the DMG"
STAGE="$OUT/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Exanote.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -ov -volname "Exanote" -srcfolder "$STAGE" -format ULFO "$OUT/Exanote.dmg"
rm -rf "$STAGE"

echo "✓ $(du -sh "$APP" | cut -f1) app, $(du -h "$OUT/Exanote.dmg" | cut -f1) DMG → $OUT"
