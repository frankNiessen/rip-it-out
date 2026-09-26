#!/usr/bin/env bash
# Downloads a pinned LGPL build of ffmpeg and ffprobe for 64-bit Windows into
# <dest>/bin, from BtbN/FFmpeg-Builds, and checks the binary that ships: no GPL or
# nonfree parts, no x264, and Windows' own H.264 encoder included.
#
# Pinned to a month-end build: BtbN deletes its daily builds after two weeks but keeps
# the last one of each month for two years. To update, pick a newer month-end
# autobuild-* release and set the three values below (the build's file name is in the
# release; with a wrong SHA-256 this script prints the right one and stops).
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
FFMPEG_TAG=autobuild-2026-08-31-13-27
FFMPEG_ASSET=ffmpeg-n9.0.1-11-ge47273f4d9-win64-lgpl-9.0.zip  # the 9.0 release branch, not master
FFMPEG_SHA256=2484854ad6988d34560f4e6ea7a6ecb9dde0af7c229d2591815d056b04ec4f56

if [[ ! -x "$DEST/bin/ffmpeg.exe" ]]; then
  ASSET=$FFMPEG_ASSET
  echo "==> Downloading $ASSET ($FFMPEG_TAG)"
  TMP=$(winpath "$(mktemp -d)")
  gh release download "$FFMPEG_TAG" -R "$REPO" -p "$ASSET" -D "$TMP"
  GOT=$(sha256sum "$TMP/$ASSET" | cut -d' ' -f1)
  if [[ "$GOT" != "$FFMPEG_SHA256" ]]; then
    echo "SHA-256 of $ASSET is $GOT, expected $FFMPEG_SHA256"; exit 1
  fi
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
