#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${FFMPEG_VERSION:-9.0.1}"
BUILD_ROOT="$ROOT_DIR/.build/ffmpeg"
ARCHIVE="$BUILD_ROOT/ffmpeg-$VERSION.tar.xz"
SOURCE_DIR="$BUILD_ROOT/ffmpeg-$VERSION"
PREFIX="$BUILD_ROOT/install"
OUTPUT="$ROOT_DIR/ThirdParty/ffmpeg/bin/ffmpeg"

if [[ -x "$OUTPUT" && "${FORCE_REBUILD:-0}" != "1" ]]; then
  echo "FFmpeg already available: $OUTPUT"
  exit 0
fi

mkdir -p "$BUILD_ROOT" "$ROOT_DIR/ThirdParty/ffmpeg/bin"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" --output "$ARCHIVE"
fi
if [[ "${REUSE_SOURCE:-0}" != "1" ]]; then
  rm -rf "$SOURCE_DIR" "$PREFIX"
  tar -xf "$ARCHIVE" -C "$BUILD_ROOT"
fi
cd "$SOURCE_DIR"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.3}"
DEVELOPER_PATH="$(xcode-select -p)"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then DEVELOPER_PATH=/Applications/Xcode.app/Contents/Developer; fi
CLANG_BIN="$(DEVELOPER_DIR="$DEVELOPER_PATH" xcrun --find clang)"
SDK_PATH="$(DEVELOPER_DIR="$DEVELOPER_PATH" xcrun --sdk macosx --show-sdk-path)"
./configure \
  --prefix="$PREFIX" \
  --arch=arm64 \
  --target-os=darwin \
  --cc="$CLANG_BIN" \
  --host-cc="$CLANG_BIN" \
  --host-cflags="-isysroot $SDK_PATH" \
  --host-ld="$CLANG_BIN" \
  --host-ldflags="-isysroot $SDK_PATH" \
  --sysroot="$SDK_PATH" \
  --enable-static \
  --disable-shared \
  --disable-debug \
  --disable-doc \
  --disable-ffplay \
  --disable-ffprobe \
  --disable-avdevice \
  --disable-network \
  --disable-autodetect \
  --enable-zlib \
  --enable-bzlib \
  --disable-iconv \
  --disable-gpl \
  --disable-nonfree

BUILD_JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)"
make -j"$BUILD_JOBS"
make install
cp "$PREFIX/bin/ffmpeg" "$OUTPUT"
cp "$SOURCE_DIR/COPYING.LGPLv2.1" "$ROOT_DIR/ThirdParty/licenses/FFmpeg-COPYING.LGPLv2.1"
chmod 755 "$OUTPUT"
codesign --force --sign - "$OUTPUT" >/dev/null
echo "Built LGPL FFmpeg $VERSION: $OUTPUT"
