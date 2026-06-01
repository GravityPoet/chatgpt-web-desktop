#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ChatGPT Rust"
BUILT_APP="$ROOT/src-tauri/target/release/bundle/macos/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
SIGN_IDENTITY="${CHATGPT_RUST_CODESIGN_IDENTITY:-}"

cd "$ROOT"
npm run build:app

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$("$ROOT/packaging/ensure-local-codesign-cert.sh")"
fi

/usr/bin/osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
/bin/sleep 1
/usr/bin/ditto "$BUILT_APP" "$INSTALL_APP"
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$INSTALL_APP"
/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
/usr/bin/open -a "$APP_NAME"

printf '%s\n' "$INSTALL_APP"
