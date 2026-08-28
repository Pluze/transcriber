#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$ROOT_DIR/Sources/Transcriber.swift"
PLIST="$ROOT_DIR/Resources/Info.plist"
APP="$ROOT_DIR/Transcriber.app"
CONTENTS="$APP/Contents"

[[ -x "$ROOT_DIR/ThirdParty/ffmpeg/bin/ffmpeg" ]] || "$ROOT_DIR/scripts/build-ffmpeg.sh"
[[ -x "$ROOT_DIR/ThirdParty/whisper/bin/whisper-cli" ]] || "$ROOT_DIR/scripts/build-whisper.sh"

DEVELOPER_PATH="$(xcode-select -p)"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then DEVELOPER_PATH=/Applications/Xcode.app/Contents/Developer; fi
SWIFTC_BIN="$(DEVELOPER_DIR="$DEVELOPER_PATH" xcrun --find swiftc)"
SDK_PATH="$(DEVELOPER_DIR="$DEVELOPER_PATH" xcrun --sdk macosx --show-sdk-path)"
BUILD_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/transcriber-build.XXXXXX")"
cleanup() { rm -rf "$BUILD_TEMP"; }
trap cleanup EXIT INT TERM

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/runtime/bin" "$CONTENTS/Resources/licenses" "$CONTENTS/Resources/catalog" "$BUILD_TEMP/module-cache"
cp "$PLIST" "$CONTENTS/Info.plist"
cp -a "$ROOT_DIR/ThirdParty/whisper/bin/." "$CONTENTS/Resources/runtime/bin/"
cp "$ROOT_DIR/ThirdParty/ffmpeg/bin/ffmpeg" "$CONTENTS/Resources/runtime/bin/ffmpeg"
cp -a "$ROOT_DIR/ThirdParty/licenses/." "$CONTENTS/Resources/licenses/"
cp "$ROOT_DIR/LICENSE" "$CONTENTS/Resources/licenses/Transcriber-LICENSE"
cp "$ROOT_DIR/Resources/catalog/"*.json "$CONTENTS/Resources/catalog/"

"$SWIFTC_BIN" -parse-as-library -O -whole-module-optimization \
  -target arm64-apple-macos13.3 -sdk "$SDK_PATH" \
  -module-cache-path "$BUILD_TEMP/module-cache" \
  -framework SwiftUI -framework AppKit -framework CryptoKit \
  "$SOURCE" -o "$CONTENTS/MacOS/Transcriber"

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
plutil -lint "$CONTENTS/Info.plist" >/dev/null
echo "Built: $APP"
