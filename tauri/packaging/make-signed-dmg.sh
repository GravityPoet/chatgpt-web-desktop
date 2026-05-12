#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ChatGPT Rust"
VERSION="0.1.0"
ARCH="$(uname -m)"
TAURI_APP="$ROOT/src-tauri/target/release/bundle/macos/$APP_NAME.app"
DIST_DIR="$ROOT/dist"
DIST_APP="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/ChatGPT-Rust-$VERSION-$ARCH.dmg"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-tauri-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

cd "$ROOT"
npm run build >/dev/null

mkdir -p "$DIST_DIR"
rm -rf "$DIST_APP" "$DMG_PATH"

/usr/bin/ditto --norsrc "$TAURI_APP" "$DIST_APP"
/usr/bin/xattr -cr "$DIST_APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$DIST_APP" >/dev/null
/usr/bin/codesign --verify --deep --strict "$DIST_APP"

/usr/bin/ditto --norsrc "$DIST_APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null

echo "$DMG_PATH"
