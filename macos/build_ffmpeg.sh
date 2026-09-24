#!/usr/bin/env bash
# Builds a self-contained ffmpeg and ffprobe for the app bundle.
#
# Configured without any GPL parts, so the binaries are LGPL and can be shipped
# in the DMG. H.264 export uses Apple's VideoToolbox encoder instead of x264.
# Only macOS system libraries are linked (--disable-autodetect keeps Homebrew
# libraries out), so the binaries run on any Mac with macOS 13 or newer.
#
# Usage: macos/build_ffmpeg.sh <version> <output dir>
set -euo pipefail

VERSION=${1:?ffmpeg version}
OUT=${2:?output dir}
WORK="$(dirname "$OUT")/ffmpeg-src"

if [[ -x "$OUT/bin/ffmpeg" && -x "$OUT/bin/ffprobe" ]]; then
  echo "ffmpeg $VERSION already built in $OUT"
  exit 0
fi

mkdir -p "$WORK"
cd "$WORK"
if [[ ! -d "ffmpeg-$VERSION" ]]; then
  curl -fL --retry 3 -o "ffmpeg-$VERSION.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
  tar xf "ffmpeg-$VERSION.tar.xz"
fi
cd "ffmpeg-$VERSION"

./configure \
  --prefix="$OUT" \
  --enable-static --disable-shared \
  --disable-autodetect \
  --enable-videotoolbox --enable-audiotoolbox \
  --enable-zlib --enable-bzlib \
  --disable-ffplay --disable-doc --disable-debug \
  --extra-cflags="-mmacosx-version-min=13.0" \
  --extra-ldflags="-mmacosx-version-min=13.0"
make -j"$(sysctl -n hw.ncpu)"
make install

mkdir -p "$OUT/share/licenses"
cp COPYING.LGPLv2.1 "$OUT/share/licenses/FFmpeg-COPYING.LGPLv2.1"
echo "Built ffmpeg $VERSION (LGPL) into $OUT"
