#!/bin/bash
set -euo pipefail

# Launch one multi-account ChatGPT identity in the FULL CloakBrowser.
#
# Each identity is one "different M4 Pro Mac": same honest-Mac platform/GPU/UA
# (faking Windows-on-Mac creates detectable contradictions), but a DISTINCT,
# STABLE per-account fingerprint seed so canvas/WebGL/audio hashes differ. The
# accounts therefore do not look like the same device, yet each looks like a
# perfectly ordinary Mac.
#
# Isolation model (sequential use, one VPN switched per region):
#   - identity         := stable --fingerprint=<seed> derived from the name
#   - storage/login    := own --user-data-dir under Accounts/<name> (NEVER the
#                         daily PWA's main profile)
#   - timezone         := cloak-companion auto-matches the current VPN IP zone
#   - IP/DNS/WebRTC    := the VPN (switch region BEFORE launching this account)
#
# The binary is resolved through ~/.cloakbrowser/current so the auto-updater can
# repoint one symlink without touching this script or any launcher shortcut.
#
# Usage:   launch-account.sh <account-name>
#   DRY_RUN=1 launch-account.sh <name>   # print the argv, do not launch
#
# Reminder: switch the VPN to that account's region first; the companion then
# pins the browser timezone to the new exit IP automatically.

name="${1:-}"
[[ -n "$name" ]] || { printf 'usage: %s <account-name>\n' "$(basename "$0")" >&2; exit 1; }
[[ "$name" == "main" ]] && { printf "refuse: 'main' is reserved for the daily PWA profile\n" >&2; exit 1; }
case "$name" in */*|*..*|.*) printf 'bad account name: %s\n' "$name" >&2; exit 1;; esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$ROOT/extension/cloak-companion"
[[ -d "$EXT" ]] || { printf 'error: companion extension not found: %s\n' "$EXT" >&2; exit 1; }

# Resolve the stealth Chromium: prefer the auto-update symlink, else newest pin.
CB="$HOME/.cloakbrowser"
BIN="$CB/current/Chromium.app/Contents/MacOS/Chromium"
if [[ ! -x "$BIN" ]]; then
  BIN="$(/bin/ls -d "$CB"/chromium-*/Chromium.app/Contents/MacOS/Chromium 2>/dev/null | sort -V | tail -1 || true)"
fi
[[ -n "$BIN" && -x "$BIN" ]] || { printf 'error: CloakBrowser binary not found under %s\n' "$CB" >&2; exit 1; }

# Deterministic per-account seed in the wrapper's 10000-99999 range, so the same
# name always rebuilds the same device fingerprint across launches and machines.
hex="$(printf '%s' "$name" | /usr/bin/shasum -a 256 | cut -c1-8)"
seed=$(( 16#$hex % 90000 + 10000 ))

UDD="$HOME/Library/Application Support/ChatGPT Cloak/Accounts/$name"
mkdir -p "$UDD"

# Robust timezone: derive the zone from the current (VPN) exit IP and pass it via
# the TZ env var so ICU reports it in EVERY JS context — main thread AND web
# workers. The JS companion cannot reach worker scopes, so a detector (CreepJS)
# reads the real OS zone inside a worker and flags the mismatch; TZ fixes it at
# the engine level. Best-effort: on failure the browser keeps the OS zone and the
# companion still covers the main page.
tz_zone="$(/usr/bin/curl -s --max-time 5 https://ipapi.co/timezone/ 2>/dev/null || true)"
if [[ "$tz_zone" =~ ^[A-Za-z]+/[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)?$ ]]; then
  export TZ="$tz_zone"
else
  tz_zone="(unchanged OS zone: $(/bin/date +%Z))"
fi

args=(
  "--user-data-dir=$UDD"
  "--fingerprint=$seed"
  "--fingerprint-platform=macos"
  "--load-extension=$EXT"
  "--no-first-run"
  "--no-default-browser-check"
  "--new-window"
  "https://chatgpt.com/"
)

printf 'account : %s\n' "$name"
printf 'seed    : %s\n' "$seed"
printf 'timezone: %s  (page + workers)\n' "${TZ:-$tz_zone}"
printf 'profile : %s\n' "$UDD"
printf 'binary  : %s\n' "$BIN"
printf 'reminder: switch VPN to this account region BEFORE launch\n'

if [[ -n "${DRY_RUN:-}" ]]; then
  printf 'argv    : '; printf '%q ' "$BIN" "${args[@]}"; printf '\n'
  exit 0
fi

exec "$BIN" "${args[@]}"
