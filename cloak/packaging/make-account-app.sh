#!/bin/bash
set -euo pipefail

# Build a double-clickable per-account launcher app (one green tile per account).
#
# Each app runs launch-account.sh <name> directly, so a double-click opens that
# account in the FULL CloakBrowser WITH its isolation intact: stable
# --fingerprint=<seed>, own --user-data-dir, the cloak-companion extension,
# timezone-from-exit-IP and any per-account proxy. Click a tile = switch account.
#
# Why this instead of Chromium "Install as app":
#   chatgpt.com's installed-app always hashes to ONE app-id, so every "Install
#   as app" writes the SAME bundle and overwrites the previous one (and the main
#   daily PWA) — you cannot have two chatgpt PWA tiles coexist. A PWA shim also
#   drops the --fingerprint flag, so the account loses its device isolation.
#   These applets each carry a UNIQUE bundle id, so any number of account tiles
#   coexist, and they launch THROUGH launch-account.sh so the seed survives.
#
# The green icon is baked in two layers (applet.icns + a Finder custom icon),
# and nothing ever rebuilds this bundle, so the icon stays green for good.
#
# Usage:   make-account-app.sh <account-name> [display-label]
#   make-account-app.sh moonlitpoet88
#   make-account-app.sh moonlitpoet88 "Cloak 工作号"
#   DEST_DIR=~/Applications make-account-app.sh moonlitpoet88   # elsewhere
#   ICON=/path/to/other.icns make-account-app.sh work           # custom icon

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$ROOT/packaging/launch-account.sh"
ICON="${ICON:-$ROOT/packaging/icon-green.icns}"
DEST_DIR="${DEST_DIR:-$HOME/Desktop}"

name="${1:-}"
[[ -n "$name" ]] || { printf 'usage: %s <account-name> [display-label]\n' "$(basename "$0")" >&2; exit 1; }
[[ "$name" == "main" ]] && { printf "refuse: 'main' is the daily PWA profile, not a picker account\n" >&2; exit 1; }
# Same charset the picker enforces, so the name is safe to embed in AppleScript.
case "$name" in
  */*|*..*|.*|*[!A-Za-z0-9_-]*)
    printf 'bad account name: %s (letters, digits, - or _ only)\n' "$name" >&2; exit 1;;
esac
[[ -x "$LAUNCH" ]] || { printf 'error: launcher not found: %s\n' "$LAUNCH" >&2; exit 1; }
[[ -f "$ICON" ]]   || { printf 'error: icon not found: %s\n' "$ICON" >&2; exit 1; }

label="${2:-Cloak - $name}"
case "$label" in */*) printf 'error: label must not contain "/"\n' >&2; exit 1;; esac
APP="$DEST_DIR/$label.app"

mkdir -p "$DEST_DIR"
TMP="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$TMP"' EXIT

# AppleScript: launch the account detached (background + stdio to /dev/null) so
# the applet quits at once and leaves no Terminal window; launch-account.sh
# execs the browser itself. A broad PATH is exported so the auth-proxy relay's
# python3 (often under Homebrew) resolves even from the GUI launch context.
cat >"$TMP/app.applescript" <<OSA
on run
	do shell script "export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin; " & quoted form of "$LAUNCH" & " " & quoted form of "$name" & " > /dev/null 2>&1 &"
end run
OSA

rm -rf "$APP"
/usr/bin/osacompile -o "$APP" "$TMP/app.applescript"

# Unique bundle id per account → no LaunchServices dedup, no app-id collision.
/usr/bin/defaults write "$APP/Contents/Info" CFBundleIdentifier "local.cloak.account.$name"
/usr/bin/defaults write "$APP/Contents/Info" CFBundleName "$label"
# Agent app: the launcher itself shows no Dock icon; the browser's own icon does.
/usr/bin/defaults write "$APP/Contents/Info" LSUIElement 1

# Green icon layer 1: the bundle's own icns (what most surfaces read).
/bin/cp "$ICON" "$APP/Contents/Resources/applet.icns"

# The bundle's own icns is what Finder / Dock / Launchpad read (via the applet's
# CFBundleIconFile=applet), so swapping applet.icns above is all the green icon
# needs. A Finder custom icon (kHasCustomIcon + Icon^M resource fork) is NOT used
# on purpose: its resource fork / FinderInfo would trip `codesign --verify
# --strict` ("detritus not allowed") and leave the app unlaunchable on arm64.
#
# Re-sign ad-hoc LAST: editing the bundle invalidated osacompile's signature, and
# Apple Silicon refuses to launch a bundle whose signature does not match.
/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  printf 'warning: ad-hoc re-sign failed (app may still run)\n' >&2

/usr/bin/touch "$APP"                       # nudge LaunchServices to re-read the icon
/usr/bin/killall Dock >/dev/null 2>&1 || true

# Compute the seed this tile will launch with, for the receipt.
hex="$(printf '%s' "$name" | /usr/bin/shasum -a 256 | cut -c1-8)"
seed=$(( 16#$hex % 90000 + 10000 ))
[[ -f "$HOME/Library/Application Support/ChatGPT Cloak/Accounts/$name/.cloak-seed" ]] && \
  seed="$(head -1 "$HOME/Library/Application Support/ChatGPT Cloak/Accounts/$name/.cloak-seed" 2>/dev/null || printf '%s' "$seed")"

printf 'created : %s\n' "$APP"
printf 'account : %s  (seed %s, isolated via launch-account.sh)\n' "$name" "$seed"
printf 'icon    : %s  (baked into applet.icns)\n' "$ICON"
printf 'tip     : double-click the tile; switch VPN to this account region first if it has no own proxy\n'
