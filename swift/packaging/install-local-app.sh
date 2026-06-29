#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
APP_NAME="ChatGPT Swift"
APP_DIR="$ROOT/dist/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
SIGN_IDENTITY="${CHATGPT_SWIFT_CODESIGN_IDENTITY:-}"
SIGN_TIMESTAMP="${CHATGPT_SWIFT_CODESIGN_TIMESTAMP:-0}"
SIGN_ENTITLEMENTS="${CHATGPT_SWIFT_CODESIGN_ENTITLEMENTS:-}"
LOCAL_ENTITLEMENTS="$ROOT/packaging/local-debug.entitlements"

"$ROOT/packaging/make-app.sh" >/dev/null

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$("$REPO_ROOT/tauri/packaging/ensure-local-codesign-cert.sh")"
fi
case "$SIGN_IDENTITY" in
  "Developer ID Application:"*) ;;
  *)
    if [[ -z "$SIGN_ENTITLEMENTS" ]]; then
      SIGN_ENTITLEMENTS="$LOCAL_ENTITLEMENTS"
    fi
    ;;
esac

/usr/bin/osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
/bin/sleep 1
/usr/bin/ditto "$APP_DIR" "$INSTALL_APP"
codesign_args=(--force --deep --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_TIMESTAMP" == "1" ]]; then
  codesign_args+=(--timestamp)
fi
if [[ -n "$SIGN_ENTITLEMENTS" ]]; then
  if [[ ! -f "$SIGN_ENTITLEMENTS" ]]; then
    echo "error: CHATGPT_SWIFT_CODESIGN_ENTITLEMENTS does not exist: $SIGN_ENTITLEMENTS" >&2
    exit 2
  fi
  codesign_args+=(--entitlements "$SIGN_ENTITLEMENTS")
fi
/usr/bin/codesign "${codesign_args[@]}" "$INSTALL_APP"
/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
/usr/bin/open -a "$APP_NAME"

printf '%s\n' "$INSTALL_APP"
