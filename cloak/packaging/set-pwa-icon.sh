#!/bin/bash
set -euo pipefail

# Force the ChatGPT Cloak PWA Dock/Finder icon to the full-bleed green ChatGPT icon,
# overriding Chrome's white-inset PWA shim icon.
#
# Chrome renders the web app icon shrunk onto a white macOS squircle and writes that to
# Contents/Resources/app.icns (the file the Dock reads for the running app). Two layers,
# both applied here:
#   1) Overwrite app.icns with the full-bleed green icns — what the running app's Dock
#      tile uses. Verified to survive a normal quit/relaunch; Chrome only rewrites it
#      when it *rebuilds the shim* (Chromium upgrade, or the web app's icon/title/
#      start_url changes).
#   2) Set a Finder *custom icon* (kHasCustomIcon + bundle-root "Icon\r") via
#      NSWorkspace setIcon:forFile: — covers Finder / Launchpad / Get-Info.
# Re-run after a Chromium upgrade or if the shim is ever rebuilt.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON="${ICON:-$ROOT/packaging/icon-green.icns}"
PWA_APP="${PWA_APP:-$HOME/Applications/Chromium Apps.localized/ChatGPT Cloak.app}"

[[ -f "$ICON" ]] || { printf 'error: icon not found: %s\n' "$ICON" >&2; exit 1; }
[[ -d "$PWA_APP" ]] || { printf 'error: PWA bundle not found: %s\n' "$PWA_APP" >&2; exit 1; }

# Quit the shim so it can't rewrite app.icns mid-edit, AND so the Dock re-reads the
# icon on next launch. The AppleScript quit only lands if the shim is registered
# under its display name; a Chrome shim *rebuild* (install-as-app, Chromium upgrade,
# or a web-app icon/title/start_url change) respawns the loader and rewrites app.icns
# back to the teal shim icon. So also kill the loader by its exact path — surgical,
# this never matches the main browser or any other PWA.
/usr/bin/osascript -e 'tell application "ChatGPT Cloak" to quit' >/dev/null 2>&1 || true
/usr/bin/pkill -f "$PWA_APP/Contents/MacOS/app_mode_loader" >/dev/null 2>&1 || true

# 1) Overwrite the Dock-read shim icon with the full-bleed green icns, then verify it
# stuck. If a shim rebuild raced us and rewrote it teal, re-kill the loader and retry —
# without this check the script prints "done" even when Chrome silently won the race.
copied=""
for _try in 1 2 3 4 5; do
  /bin/cp "$ICON" "$PWA_APP/Contents/Resources/app.icns"
  if /usr/bin/cmp -s "$ICON" "$PWA_APP/Contents/Resources/app.icns"; then copied=1; break; fi
  /usr/bin/pkill -f "$PWA_APP/Contents/MacOS/app_mode_loader" >/dev/null 2>&1 || true
done
[[ -n "$copied" ]] || { printf 'error: app.icns keeps reverting to the teal shim icon — fully quit the ChatGPT Cloak PWA, then re-run\n' >&2; exit 1; }
printf 'app.icns -> %s (verified green)\n' "$ICON"

# 2) Set the Finder custom icon (Finder / Launchpad / Get-Info).
ok=$(/usr/bin/osascript <<OSA
use framework "AppKit"
use scripting additions
set img to current application's NSImage's alloc()'s initWithContentsOfFile:"$ICON"
if img is missing value then return "no-image"
set okFlag to current application's NSWorkspace's sharedWorkspace()'s setIcon:img forFile:"$PWA_APP" options:0
return okFlag as text
OSA
)
printf 'setIcon -> %s\n' "$ok"
[[ "$ok" == "true" ]] || { printf 'error: setIcon failed (%s)\n' "$ok" >&2; exit 1; }

# Confirm the custom-icon resource landed, then refresh Dock icon presentation.
if [[ -f "$PWA_APP/Icon"$'\r' ]]; then printf 'custom icon resource: present\n'; else printf 'warning: Icon resource missing\n' >&2; fi
/usr/bin/touch "$PWA_APP"
/usr/bin/killall Dock >/dev/null 2>&1 || true

printf 'done: %s now uses %s\n' "$PWA_APP" "$ICON"
