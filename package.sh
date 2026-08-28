#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${VERSION:-1.0.0}"
APP="$ROOT_DIR/Transcriber.app"
DIST="$ROOT_DIR/dist"

"$ROOT_DIR/build.sh"
mkdir -p "$DIST"
ARCHIVE="$DIST/Transcriber-$VERSION-macOS-arm64.zip"
rm -f "$ARCHIVE"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ZIP="$(mktemp "${TMPDIR:-/tmp}/transcriber-notary.XXXXXX.zip")"
  ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$NOTARY_ZIP"
fi

# The end-user archive contains exactly one item: Transcriber.app.
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$ARCHIVE"
echo "Release: $ARCHIVE"
