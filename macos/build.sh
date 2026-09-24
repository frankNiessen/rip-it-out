#!/usr/bin/env bash
# Builds "Rip It Out.app" and a DMG into dist/ (Apple Silicon, macOS 13+).
#
#   macos/build.sh            build app and DMG
#   macos/build.sh --no-dmg   build the app only (faster while testing)
#
# Needs: Xcode command line tools, uv and Node.js (brew install uv node).
# Downloads and builds are cached in build/, so a second run takes a few minutes.
#
# Signing (optional). Without these the app is signed ad hoc: it runs on the Mac
# that built it, and elsewhere only after removing the quarantine flag.
#   CODESIGN_IDENTITY  "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE     a notarytool keychain profile, created once with
#                      xcrun notarytool store-credentials <profile> ...
set -euo pipefail

PY_VERSION=3.12
FFMPEG_VERSION=9.0.2
DENO_VERSION=2.9.7

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
STAGE="$BUILD/stage"
APP_NAME="Rip It Out"
MAKE_DMG=1
[[ "${1:-}" == "--no-dmg" ]] && MAKE_DMG=0

VERSION=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT/stemtool/__init__.py")
[[ "$(uname -m)" == "arm64" ]] || { echo "Build on an Apple Silicon Mac."; exit 1; }
command -v node >/dev/null || { echo "Node.js is needed (brew install node)."; exit 1; }
echo "==> Building $APP_NAME $VERSION"
mkdir -p "$BUILD" "$DIST"

# --- 1. ffmpeg (LGPL, from source) -------------------------------------------
"$ROOT/macos/build_ffmpeg.sh" "$FFMPEG_VERSION" "$BUILD/ffmpeg-$FFMPEG_VERSION"

# --- 2. Deno (yt-dlp needs a JavaScript runtime for YouTube) --------------------
DENO="$BUILD/deno-$DENO_VERSION/deno"
if [[ ! -x "$DENO" ]]; then
  echo "==> Downloading Deno $DENO_VERSION"
  mkdir -p "$(dirname "$DENO")"
  curl -fsSL --retry 3 -o "$BUILD/deno.zip" \
    "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-aarch64-apple-darwin.zip"
  unzip -oq "$BUILD/deno.zip" -d "$(dirname "$DENO")"
  rm "$BUILD/deno.zip"
fi

# --- 3. Portable Python (python-build-standalone via uv) ------------------------
echo "==> Portable Python $PY_VERSION"
UV_PYTHON_INSTALL_BIN=0 UV_PYTHON_INSTALL_DIR="$BUILD/python" uv python install "$PY_VERSION" >/dev/null
PY_SRC=$(find "$BUILD/python" -maxdepth 1 -type d -name "cpython-$PY_VERSION.*-macos-aarch64-none" | sort -V | tail -1)
[[ -n "$PY_SRC" ]] || { echo "Python $PY_VERSION not found in $BUILD/python"; exit 1; }

# --- 4. Stage the engine: Python with all packages, ffmpeg, Deno, licenses --------
echo "==> Staging the engine"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/licenses"
ditto "$PY_SRC" "$STAGE/python"
PY="$STAGE/python/bin/python3"
SITE=$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
uv pip install --quiet --python "$PY" --break-system-packages -r "$ROOT/requirements.txt"
ditto "$ROOT/stemtool" "$SITE/stemtool"
find "$SITE/stemtool" -name "__pycache__" -type d -prune -exec rm -rf {} +

echo "==> Trimming"
rm -rf "$STAGE/python/include" "$STAGE/python/share" \
  "$STAGE/python/lib/"tcl* "$STAGE/python/lib/"tk* "$STAGE/python/lib/"itcl* "$STAGE/python/lib/"thread* \
  "$STAGE/python/lib/libtcl"* "$STAGE/python/lib/python$PY_VERSION/"{idlelib,tkinter,turtledemo,test} \
  "$STAGE/python/lib/python$PY_VERSION/lib-dynload/_tkinter"* \
  "$SITE/torch/include" "$SITE/torch/share"
find "$SITE" -type d -name tests -path "*/scipy/*" -prune -exec rm -rf {} +
find "$SITE" -type d -name tests -path "*/numpy/*" -prune -exec rm -rf {} +
"$PY" -m compileall -q -j 0 "$SITE/stemtool" >/dev/null || true
if ls "$SITE" | grep -qi "^mutagen"; then echo "mutagen (GPL) must not be bundled"; exit 1; fi

# Electron's packager copies symlinks as absolute links into build/, which breaks
# the bundle. The few there are (python3 -> python3.12 and such) become copies.
find "$STAGE" -type l -print0 | while IFS= read -r -d '' link; do
  target=$(cd "$(dirname "$link")" && realpath "$(readlink "$link")")
  rm "$link" && cp -p "$target" "$link"
done

cp "$BUILD/ffmpeg-$FFMPEG_VERSION/bin/ffmpeg" "$BUILD/ffmpeg-$FFMPEG_VERSION/bin/ffprobe" "$DENO" "$STAGE/bin/"
cp "$BUILD/ffmpeg-$FFMPEG_VERSION/share/licenses/"* "$STAGE/licenses/"
cp "$ROOT/macos/THIRD_PARTY_NOTICES.md" "$ROOT/LICENSE" "$STAGE/licenses/"

# --- 5. Icon -------------------------------------------------------------------------
echo "==> Icon"
ICONS="$BUILD/icons"
uv run --quiet --no-project --with pillow python "$ROOT/macos/make_icon.py" "$ICONS" >/dev/null
rm -rf "$ICONS/AppIcon.iconset" && mkdir "$ICONS/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONS/icon-1024.png" --out "$ICONS/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ICONS/icon-1024.png" --out "$ICONS/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONS/AppIcon.iconset" -o "$ICONS/AppIcon.icns"

# --- 6. Electron app ----------------------------------------------------------------------
echo "==> Packaging the Electron app"
(cd "$ROOT/desktop" && npm ci --no-audit --no-fund --silent)
rm -rf "$BUILD/electron"
OUT_DIR=$(cd "$ROOT/desktop" && STAGE="$STAGE" ICON="$ICONS/AppIcon.icns" OUT="$BUILD/electron" VERSION="$VERSION" \
  node package.mjs | tail -1)
APP="$DIST/$APP_NAME.app"
rm -rf "$APP"
ditto "$OUT_DIR/$APP_NAME.app" "$APP"
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  echo "==> Signing ad hoc (no CODESIGN_IDENTITY set)"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "==> App: $APP ($(du -sh "$APP" | cut -f1))"

# --- 7. DMG (and notarization) ---------------------------------------------------------
if [[ $MAKE_DMG == 1 ]]; then
  DMG="$DIST/RipItOut-$VERSION.dmg"
  DMG_STAGE="$BUILD/dmg"
  rm -rf "$DMG_STAGE" "$DMG" && mkdir -p "$DMG_STAGE"
  ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
  ln -s /Applications "$DMG_STAGE/Applications"
  echo "==> Creating $DMG"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -fs HFS+ -format ULMO "$DMG"
  rm -rf "$DMG_STAGE"
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
      echo "==> Notarizing (takes a few minutes)"
      xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$DMG"
    fi
  fi
  echo "==> DMG: $DMG ($(du -sh "$DMG" | cut -f1))"
fi
