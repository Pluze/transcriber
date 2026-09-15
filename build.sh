#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$ROOT_DIR/Resources/Info.plist"
APP="$ROOT_DIR/Transcriber.app"
CONTENTS="$APP/Contents"

[[ -x "$ROOT_DIR/ThirdParty/ffmpeg/bin/ffmpeg" ]] || "$ROOT_DIR/scripts/build-ffmpeg.sh"
[[ -x "$ROOT_DIR/ThirdParty/whisper/bin/whisper-cli" ]] || "$ROOT_DIR/scripts/build-whisper.sh"
[[ -d "$ROOT_DIR/ThirdParty/FluidAudioModels/speaker-diarization/Segmentation.mlmodelc" ]] || {
  echo "Bundled speaker diarization models are missing." >&2
  exit 1
}

DEVELOPER_PATH="$(xcode-select -p)"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then DEVELOPER_PATH=/Applications/Xcode.app/Contents/Developer; fi
SWIFT_BIN="$(DEVELOPER_DIR="$DEVELOPER_PATH" xcrun --find swift)"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/runtime/bin" "$CONTENTS/Resources/licenses" "$CONTENTS/Resources/catalog" "$CONTENTS/Resources/models"
cp "$PLIST" "$CONTENTS/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp -a "$ROOT_DIR/ThirdParty/whisper/bin/." "$CONTENTS/Resources/runtime/bin/"
cp "$ROOT_DIR/ThirdParty/ffmpeg/bin/ffmpeg" "$CONTENTS/Resources/runtime/bin/ffmpeg"
cp -a "$ROOT_DIR/ThirdParty/licenses/." "$CONTENTS/Resources/licenses/"
cp "$ROOT_DIR/LICENSE" "$CONTENTS/Resources/licenses/Transcriber-LICENSE"
cp "$ROOT_DIR/Resources/catalog/"*.json "$CONTENTS/Resources/catalog/"
cp -a "$ROOT_DIR/ThirdParty/FluidAudioModels/speaker-diarization" "$CONTENTS/Resources/models/"

APP_SCRATCH="$ROOT_DIR/.build/app"
mkdir -p "$APP_SCRATCH/module-cache"
DEVELOPER_DIR="$DEVELOPER_PATH" FLUID_AUDIO_PATH="${FLUID_AUDIO_PATH:-}" \
  SWIFTPM_MODULECACHE_OVERRIDE="$APP_SCRATCH/module-cache" \
  CLANG_MODULE_CACHE_PATH="$APP_SCRATCH/module-cache" \
  "$SWIFT_BIN" build --disable-sandbox --package-path "$ROOT_DIR" --scratch-path "$APP_SCRATCH" \
  --configuration release --arch arm64 -debug-info-format none --product Transcriber
APP_BIN_DIR="$(DEVELOPER_DIR="$DEVELOPER_PATH" FLUID_AUDIO_PATH="${FLUID_AUDIO_PATH:-}" \
  SWIFTPM_MODULECACHE_OVERRIDE="$APP_SCRATCH/module-cache" \
  CLANG_MODULE_CACHE_PATH="$APP_SCRATCH/module-cache" \
  "$SWIFT_BIN" build --disable-sandbox --package-path "$ROOT_DIR" --scratch-path "$APP_SCRATCH" \
  --configuration release --arch arm64 -debug-info-format none --show-bin-path)"
cp "$APP_BIN_DIR/Transcriber" "$CONTENTS/MacOS/Transcriber"
if [[ -d "$APP_BIN_DIR/FluidAudio_FluidAudio.bundle" ]]; then
  cp -a "$APP_BIN_DIR/FluidAudio_FluidAudio.bundle" "$CONTENTS/Resources/"
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
plutil -lint "$CONTENTS/Info.plist" >/dev/null
echo "Built: $APP"
