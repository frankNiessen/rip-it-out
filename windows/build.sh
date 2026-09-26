#!/usr/bin/env bash
# Builds Rip It Out for 64-bit Windows: the app in build/app and a per-user
# installer in dist/. Runs in Git Bash on Windows (GitHub's windows-latest runner).
#
#   windows/build.sh                  build app and installer
#   windows/build.sh --no-installer   build the app only
#
# Needs: uv, Node.js, the GitHub CLI with GH_TOKEN set (for ffmpeg), 7-Zip and
# Inno Setup 6. The installer is not signed, so SmartScreen warns before it runs.
#
# The app bundles the CPU build of PyTorch, so it runs on every PC. On a PC with an
# NVIDIA graphics card the installer offers to download the CUDA build of the same
# PyTorch version (gpu_wheels.py finds it, installer.iss downloads it).
set -euo pipefail

PY_VERSION=3.12
DENO_VERSION=2.9.7
TORCH_VERSION=2.14.0  # pinned: the CPU build ships, the installer downloads the matching CUDA build
TORCH_CPU_INDEX=https://download.pytorch.org/whl/cpu
# Longest path allowed inside the app folder. The install folder
# (C:\Users\<name>\AppData\Local\Programs\Rip It Out\) takes up to about 80 of
# Windows' 260 characters.
MAX_REL_PATH=175

# Windows-style paths with forward slashes work for bash and the native tools alike.
winpath() { cygpath -m "$1"; }
ROOT=$(winpath "$(cd "$(dirname "$0")/.." && pwd)")
BUILD="$ROOT/build"
DIST="$ROOT/dist"
STAGE="$BUILD/stage"
APP="$BUILD/app"
APP_NAME="Rip It Out"
MAKE_INSTALLER=1
[[ "${1:-}" == "--no-installer" ]] && MAKE_INSTALLER=0
ISCC=${ISCC:-"C:/Program Files (x86)/Inno Setup 6/ISCC.exe"}

VERSION=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT/stemtool/__init__.py")
echo "==> Building $APP_NAME $VERSION for Windows"
mkdir -p "$BUILD" "$DIST"

# --- 1. ffmpeg (LGPL build, checked) ---------------------------------------------
"$ROOT/windows/fetch_ffmpeg.sh" "$BUILD/ffmpeg"

# --- 2. Deno (yt-dlp needs a JavaScript runtime for YouTube) ----------------------
DENO="$BUILD/deno-$DENO_VERSION/deno.exe"
if [[ ! -f "$DENO" ]]; then
  echo "==> Downloading Deno $DENO_VERSION"
  mkdir -p "$(dirname "$DENO")"
  curl -fsSL --retry 3 -o "$BUILD/deno.zip" \
    "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-x86_64-pc-windows-msvc.zip"
  7z x -y -o"$(dirname "$DENO")" "$BUILD/deno.zip" >/dev/null
  rm "$BUILD/deno.zip"
fi

# --- 3. Portable Python (python-build-standalone via uv) ------------------------------
echo "==> Portable Python $PY_VERSION"
UV_PYTHON_INSTALL_BIN=0 UV_PYTHON_INSTALL_DIR="$BUILD/python" uv python install "$PY_VERSION" >/dev/null
PY_SRC=$(find "$BUILD/python" -maxdepth 1 -type d -name "cpython-$PY_VERSION.*-windows-x86_64-none" | sort -V | tail -1)
[[ -n "$PY_SRC" ]] || { echo "Python $PY_VERSION not found in $BUILD/python"; exit 1; }

# --- 4. Stage the engine: Python with all packages, ffmpeg, Deno, licenses ------------
echo "==> Staging the engine"
rm -rf "$STAGE" "$APP"
mkdir -p "$STAGE/bin" "$STAGE/licenses"
cp -r "$PY_SRC" "$STAGE/python"
PY="$STAGE/python/python.exe"
SITE=$(winpath "$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' | tr -d '\r')")
# PyTorch first, the CPU build (the PyPI one would do too, but this index says so);
# the rest keeps it. Compiled here, as the
# app folder is replaced whole on every install.
uv pip install --quiet --python "$PY" --break-system-packages --compile-bytecode \
  --index-url "$TORCH_CPU_INDEX" "torch==$TORCH_VERSION" torchaudio
uv pip install --quiet --python "$PY" --break-system-packages --compile-bytecode \
  -r "$ROOT/requirements.txt"
cp -r "$ROOT/stemtool" "$SITE/stemtool"
find "$SITE/stemtool" -name "__pycache__" -type d -prune -exec rm -rf {} +
"$PY" -m compileall -q "$SITE/stemtool" >/dev/null

echo "==> Trimming"
rm -rf "$STAGE/python/include" "$STAGE/python/libs" "$STAGE/python/tcl" \
  "$STAGE/python/Lib/"{idlelib,tkinter,turtledemo,test} "$STAGE/python/DLLs/"{_tkinter.pyd,tcl86t.dll,tk86t.dll} \
  "$SITE/torch/include" "$SITE/torch/share"
rm -f "$SITE/torch/lib/"*.lib  # link libraries, only for building extensions (dnnl.lib alone is hundreds of MB)
find "$SITE" -type d -name tests -path "*/scipy/*" -prune -exec rm -rf {} +
find "$SITE" -type d -name tests -path "*/numpy/*" -prune -exec rm -rf {} +
find "$STAGE" -name "*.pdb" -delete

echo "==> License check"
# Inventory of every bundled Python package; stops the build if one is GPL.
"$PY" -I "$ROOT/macos/license_report.py" "$STAGE/licenses/PYTHON_PACKAGES.md"
"$PY" -c "import torch; print('PyTorch', torch.__version__)"
"$PY" -m pip --version  # the installer installs the GPU download with it

echo "==> GPU download"
# What the installer downloads on PCs with an NVIDIA GPU. The app reads the folder name
# from python/gpu.json (desktop/main.js).
"$PY" -I "$ROOT/windows/gpu_wheels.py" "$BUILD/gpu.json" "$BUILD/gpu.iss"
cp "$BUILD/gpu.json" "$STAGE/python/gpu.json"

cp "$BUILD/ffmpeg/bin/ffmpeg.exe" "$BUILD/ffmpeg/bin/ffprobe.exe" "$DENO" "$STAGE/bin/"
cp "$BUILD/ffmpeg/licenses/"* "$ROOT/windows/THIRD_PARTY_NOTICES.md" "$ROOT/LICENSE" "$STAGE/licenses/"

echo "==> Path lengths"
LONGEST=$(cd "$STAGE" && find . -type f | awk '{ print length($0) - 2 + 10, substr($0, 3) }' | sort -n | tail -1)
echo "Longest path inside the app folder: resources/${LONGEST#* } (${LONGEST%% *} characters)"
if (( ${LONGEST%% *} > MAX_REL_PATH )); then
  echo "Paths longer than $MAX_REL_PATH characters may not work in Windows' default path limit"; exit 1
fi

# --- 5. Icon -------------------------------------------------------------------------
echo "==> Icon"
ICONS="$BUILD/icons"
uv run --quiet --no-project --with pillow python "$ROOT/macos/make_icon.py" "$ICONS" >/dev/null

# --- 6. Electron app ----------------------------------------------------------------------
echo "==> Packaging the Electron app"
(cd "$ROOT/desktop" && npm ci --no-audit --no-fund --silent)
rm -rf "$BUILD/electron"
OUT_DIR=$(cd "$ROOT/desktop" && STAGE="$STAGE" ICON="$ICONS/icon.ico" OUT="$BUILD/electron" VERSION="$VERSION" \
  node package.mjs | tail -1 | tr -d '\r')
mv "$OUT_DIR" "$APP"
rm -rf "$STAGE" "$BUILD/electron"  # the app has its own copy; disk space on CI runners is limited
echo "==> App: $APP ($(du -sh "$APP" | cut -f1))"

# --- 7. Installer ----------------------------------------------------------------------------
if [[ $MAKE_INSTALLER == 1 ]]; then
  echo "==> Installer (takes a while)"
  rm -f "$DIST"/RipItOut-Setup-*
  # MSYS would read /D... as a path and rewrite it.
  MSYS2_ARG_CONV_EXCL="*" "$ISCC" /Q "/DAppVersion=$VERSION" "/DSourceDir=$APP" "/DOutputDir=$DIST" \
    "/DIconFile=$ICONS/icon.ico" "/DGpuInclude=$BUILD/gpu.iss" \
    "$ROOT/windows/installer.iss"
  ls -l "$DIST"/RipItOut-Setup-*
fi
