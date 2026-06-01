#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
APP_NAME="ChatGPT Swift"
APP_DIR="$ROOT/dist/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
SIGN_IDENTITY="${CHATGPT_SWIFT_CODESIGN_IDENTITY:-}"

"$ROOT/packaging/make-app.sh" >/dev/null

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$("$REPO_ROOT/tauri/packaging/ensure-local-codesign-cert.sh")"
fi

/usr/bin/osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
/bin/sleep 1
/usr/bin/ditto "$APP_DIR" "$INSTALL_APP"
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$INSTALL_APP"
/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
/usr/bin/open -a "$APP_NAME"

printf '%s\n' "$INSTALL_APP"
