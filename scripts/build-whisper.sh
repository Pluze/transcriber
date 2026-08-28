#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${WHISPER_VERSION:-1.9.1}"
BUILD_ROOT="$ROOT_DIR/.build/whisper"
ARCHIVE="$BUILD_ROOT/whisper.cpp-v$VERSION.tar.gz"
SOURCE_DIR="$BUILD_ROOT/whisper.cpp-$VERSION"
BUILD_DIR="$SOURCE_DIR/build-transcriber"
PREFIX="$BUILD_ROOT/install"
OUTPUT="$ROOT_DIR/ThirdParty/whisper/bin/whisper-cli"

if [[ -x "$OUTPUT" && "${FORCE_REBUILD:-0}" != "1" ]]; then
  echo "whisper.cpp already available: $OUTPUT"
  exit 0
fi

mkdir -p "$BUILD_ROOT"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$VERSION.tar.gz" --output "$ARCHIVE"
fi
rm -rf "$SOURCE_DIR" "$PREFIX" "$ROOT_DIR/ThirdParty/whisper/bin"
tar -xzf "$ARCHIVE" -C "$BUILD_ROOT"

DEVELOPER_PATH="$(xcode-select -p)"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then DEVELOPER_PATH=/Applications/Xcode.app/Contents/Developer; fi
export DEVELOPER_DIR="$DEVELOPER_PATH"
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
  -DBUILD_SHARED_LIBS=ON \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=ON \
  -DGGML_BLAS=ON \
  -DGGML_BLAS_VENDOR=Apple \
  -DGGML_NATIVE=OFF \
  -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16

BUILD_JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)"
cmake --build "$BUILD_DIR" --config Release -j "$BUILD_JOBS"
cmake --install "$BUILD_DIR" --config Release
mkdir -p "$ROOT_DIR/ThirdParty/whisper/bin"
cp "$PREFIX/bin/whisper-cli" "$ROOT_DIR/ThirdParty/whisper/bin/"
cp -a "$PREFIX/lib/"libwhisper*.dylib "$PREFIX/lib/"libggml*.dylib "$ROOT_DIR/ThirdParty/whisper/bin/"
cp "$SOURCE_DIR/LICENSE" "$ROOT_DIR/ThirdParty/licenses/whisper.cpp-LICENSE"
codesign --force --sign - "$ROOT_DIR/ThirdParty/whisper/bin/whisper-cli" >/dev/null
echo "Built whisper.cpp v$VERSION: $OUTPUT"
