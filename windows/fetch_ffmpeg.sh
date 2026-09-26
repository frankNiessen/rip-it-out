#!/usr/bin/env bash
# Downloads an LGPL build of ffmpeg and ffprobe for 64-bit Windows into <dest>/bin,
# from BtbN/FFmpeg-Builds (the newest release branch), and checks the binary that
# ships: no GPL or nonfree parts, no x264, and Windows' own H.264 encoder included.
#
#   windows/fetch_ffmpeg.sh <dest>
#
# Needs the GitHub CLI (gh) with GH_TOKEN set, and 7-Zip; both are on GitHub's
# Windows runners.
set -euo pipefail

# Windows-style paths with forward slashes work for bash and the native tools alike.
winpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
DEST=$(winpath "$1")
REPO=BtbN/FFmpeg-Builds

if [[ ! -x "$DEST/bin/ffmpeg.exe" ]]; then
  ASSET=$(gh release view latest -R "$REPO" --json assets --jq '.assets[].name' \
    | grep -E '^ffmpeg-n[0-9.]+-latest-win64-lgpl-[0-9.]+\.zip$' | sort -V | tail -1)
  [[ -n "$ASSET" ]] || { echo "No LGPL win64 build found in $REPO"; exit 1; }
  echo "==> Downloading $ASSET"
  TMP=$(winpath "$(mktemp -d)")
  gh release download latest -R "$REPO" -p "$ASSET" -D "$TMP"
  7z x -y -o"$TMP" "$TMP/$ASSET" >/dev/null
  SRC=$(dirname "$(dirname "$(find "$TMP" -name ffmpeg.exe | head -1)")")
  mkdir -p "$DEST/bin" "$DEST/licenses"
  cp "$SRC/bin/ffmpeg.exe" "$SRC/bin/ffprobe.exe" "$DEST/bin/"
  cp "$SRC"/LICENSE* "$DEST/licenses/FFmpeg-LICENSE.txt"
  rm -rf "$TMP"
fi

FF="$DEST/bin/ffmpeg.exe"
# Outputs are read whole first: grep -q closing the pipe early would fail the check.
VERSION=$("$FF" -hide_banner -version)
LICENSE=$("$FF" -hide_banner -L)
BUILDCONF=$("$FF" -hide_banner -buildconf)
echo "${VERSION%%$'\n'*}"
if ! grep -q "Lesser General Public" <<<"$LICENSE" || grep -qE -- "--enable-(gpl|nonfree)" <<<"$BUILDCONF"; then
  echo "This ffmpeg is not an LGPL build"; exit 1
fi
ENCODERS=$("$FF" -hide_banner -encoders)
grep -q " h264_mf " <<<"$ENCODERS" || { echo "This ffmpeg has no h264_mf encoder"; exit 1; }
if grep -qE " libx26[45] " <<<"$ENCODERS"; then echo "This ffmpeg includes x264 or x265 (GPL)"; exit 1; fi
echo "ffmpeg is an LGPL build with h264_mf"
