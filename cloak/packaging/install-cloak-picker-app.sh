#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Cloak Picker"
BUILT_APP="$ROOT/target/release/bundle/macos/$APP_NAME.app"
INSTALL_APP="${CLOAK_PICKER_INSTALL_APP:-/Applications/$APP_NAME.app}"
INSTALL_PARENT="$(dirname "$INSTALL_APP")"
INSTALL_TMP="$INSTALL_PARENT/.$APP_NAME.app.tmp.$$"
EXPECTED_BUNDLE_ID="local.cloak.picker"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

printf '%s\n' "backup: skipped; Cloak Picker.app is a generated Tauri bundle and is reinstallable from this script."

cd "$ROOT"
npm --prefix "$ROOT/cloak-picker" run tauri -- build

if [[ ! -d "$BUILT_APP" ]]; then
  printf 'error: built app not found: %s\n' "$BUILT_APP" >&2
  exit 1
fi

if [[ -e "$INSTALL_APP/Contents/Info.plist" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_id" != "$EXPECTED_BUNDLE_ID" ]]; then
    printf 'error: refusing to replace %s; bundle id is %s, expected %s\n' \
      "$INSTALL_APP" "${existing_id:-unknown}" "$EXPECTED_BUNDLE_ID" >&2
    exit 1
  fi
fi

/usr/bin/osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
/bin/sleep 1

if /usr/bin/pgrep -f "$INSTALL_APP/Contents/MacOS/cloak-picker" >/dev/null 2>&1; then
  printf 'error: %s is still running; quit it and retry\n' "$INSTALL_APP" >&2
  exit 1
fi

/usr/bin/codesign --force --deep --sign - "$BUILT_APP"
/usr/bin/codesign --verify --deep --strict "$BUILT_APP"

/bin/rm -rf "$INSTALL_TMP"
/usr/bin/ditto "$BUILT_APP" "$INSTALL_TMP"
/usr/bin/codesign --verify --deep --strict "$INSTALL_TMP"

/bin/rm -rf "$INSTALL_APP"
/bin/mv "$INSTALL_TMP" "$INSTALL_APP"
/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
/usr/bin/touch "$INSTALL_APP"
if [[ -x "$LSREG" ]]; then
  "$LSREG" -f "$INSTALL_APP" >/dev/null 2>&1 || true
fi

# Record which cloak-core source this build embeds so check-picker-fresh.sh can later
# detect when a code edit has outdated the installed Picker.
"$ROOT/packaging/check-picker-fresh.sh" --stamp >/dev/null 2>&1 || true

printf '%s\n' "$INSTALL_APP"
