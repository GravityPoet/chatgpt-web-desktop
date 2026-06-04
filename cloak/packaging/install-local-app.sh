#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ChatGPT Cloak"
APP_DIR="$ROOT/dist/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
INSTALL_TMP="/Applications/.$APP_NAME.app.tmp.$$"

printf '%s\n' "backup: skipped; /Applications app bundle is generated and reinstallable from cloak/packaging/make-app.sh."

"$ROOT/packaging/make-app.sh" >/dev/null

# Give the CloakBrowser Chromium mic/camera usage strings, otherwise ChatGPT voice input
# crashes Chromium via macOS TCC. Non-fatal: a missing CloakBrowser only warns.
"$ROOT/packaging/patch-chromium.sh" >/dev/null || \
  printf '%s\n' "warning: chromium patch skipped (CloakBrowser Chromium not found)" >&2

/usr/bin/osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
/bin/sleep 1

rm -rf "$INSTALL_TMP"
/usr/bin/ditto "$APP_DIR" "$INSTALL_TMP"
/usr/bin/codesign --verify --deep --strict "$INSTALL_TMP"

rm -rf "$INSTALL_APP"
mv "$INSTALL_TMP" "$INSTALL_APP"

/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
/usr/bin/open "$INSTALL_APP"

printf '%s\n' "$INSTALL_APP"
