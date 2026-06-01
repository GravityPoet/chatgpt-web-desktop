#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
APP_NAME="ChatGPT Swift"
BINARY_NAME="ChatGPTSwiftWeb"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON_SOURCE="$ROOT/../tauri/src-tauri/icons/icon.icns"
SIGN_IDENTITY="${CHATGPT_SWIFT_CODESIGN_IDENTITY:-}"

cd "$ROOT"

swift build -c release

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$("$REPO_ROOT/tauri/packaging/ensure-local-codesign-cert.sh")"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp ".build/release/$BINARY_NAME" "$MACOS/$BINARY_NAME"
cp "$ROOT/packaging/Info.plist" "$CONTENTS/Info.plist"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES/AppIcon.icns"
else
  echo "warning: icon not found at $ICON_SOURCE" >&2
fi

chmod +x "$MACOS/$BINARY_NAME"

/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
