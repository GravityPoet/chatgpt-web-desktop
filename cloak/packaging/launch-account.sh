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

# A rename pins the original seed in .cloak-seed so the device fingerprint survives
# the new name (the seed is otherwise name-derived). Advanced users can hand-pin too.
if [[ -f "$UDD/.cloak-seed" ]]; then
  pinned="$(head -1 "$UDD/.cloak-seed" 2>/dev/null || true)"
  [[ "$pinned" =~ ^[0-9]{4,5}$ ]] && seed="$pinned"
fi

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

# Optional per-account locale: make navigator.languages and the Accept-Language
# header follow the VPN region so language is coherent with the IP and timezone.
# Engine-level via --accept-lang (the intl.accept_languages pref) so it also holds
# inside Web Workers — a page-world spoof could not. Off by default: plain en-US is
# the least-surprising signal and ChatGPT keys its UI off your account, not this.
# Enable per account from the picker (writes a .cloak-locale marker) or ad hoc with
# LOCALE=1. Best-effort: if the region/language lookup fails the flag is omitted and
# the browser default holds (no header-vs-navigator mismatch).
locale_on=0
if [[ -n "${LOCALE:-}" ]]; then
  case "$LOCALE" in 1|on|true|yes) locale_on=1;; esac
elif [[ -f "$UDD/.cloak-locale" ]]; then
  locale_on=1
fi
accept_lang=""
if [[ "$locale_on" == "1" ]]; then
  country="$(/usr/bin/curl -s --max-time 5 https://ipapi.co/country_code/ 2>/dev/null || true)"
  langs="$(/usr/bin/curl -s --max-time 5 https://ipapi.co/languages/ 2>/dev/null || true)"
  primary="${langs%%,*}"                          # first language token (e.g. ja, en-US)
  if [[ "$primary" =~ ^[A-Za-z]{2,3}(-[A-Za-z0-9]+)?$ ]]; then
    if [[ "$primary" != *-* && "$country" =~ ^[A-Za-z]{2}$ ]]; then
      primary="$primary-$country"                 # ja -> ja-JP
    fi
    base="${primary%%-*}"
    if [[ "$base" == "en" ]]; then
      accept_lang="$primary,en;q=0.9"
    else
      accept_lang="$primary,$base;q=0.9,en-US;q=0.8,en;q=0.7"
    fi
  fi
fi

# Optional per-account upstream proxy (.cloak-proxy holds one URL, chmod 600).
# Chromium cannot authenticate to a SOCKS5 proxy, so an AUTHENTICATED upstream
# (scheme://user:pass@host:port) is bridged through a local no-auth SOCKS5 relay
# (proxy-relay.py) started just before launch and killed on exit; a no-auth upstream
# is handed to --proxy-server directly. Remote DNS is preserved on both paths.
proxy_url=""
[[ -f "$UDD/.cloak-proxy" ]] && proxy_url="$(head -1 "$UDD/.cloak-proxy" 2>/dev/null || true)"
proxy_mode="none"; proxy_display="off (system VPN / direct)"
if [[ -n "$proxy_url" ]]; then
  case "$proxy_url" in
    socks5://*|http://*|https://*) ;;
    *) printf 'error: .cloak-proxy must start socks5:// or http:// (got %q)\n' "$proxy_url" >&2; exit 1;;
  esac
  proxy_scheme="${proxy_url%%://*}"
  proxy_rest="${proxy_url#*://}"
  proxy_hostport="${proxy_rest#*@}"           # strip user:pass@ for display
  if [[ "$proxy_rest" == *@* ]]; then
    proxy_mode="relay";  proxy_display="$proxy_scheme://$proxy_hostport  (auth via local relay)"
  else
    proxy_mode="direct"; proxy_display="$proxy_scheme://$proxy_hostport"
  fi
fi

args=(
  "--user-data-dir=$UDD"
  "--fingerprint=$seed"
  "--fingerprint-platform=macos"
  "--load-extension=$EXT"
  "--no-first-run"
  "--no-default-browser-check"
)
[[ -n "$accept_lang" ]] && args+=("--accept-lang=$accept_lang")
args+=(
  "--new-window"
  "https://chatgpt.com/"
)

printf 'account : %s\n' "$name"
printf 'seed    : %s\n' "$seed"
printf 'timezone: %s  (page + workers)\n' "${TZ:-$tz_zone}"
printf 'locale  : %s\n' "${accept_lang:-off (navigator.languages = browser default)}"
printf 'proxy   : %s\n' "$proxy_display"
printf 'profile : %s\n' "$UDD"
printf 'binary  : %s\n' "$BIN"
printf 'reminder: switch VPN to this account region BEFORE launch\n'

if [[ -n "${DRY_RUN:-}" ]]; then
  printf 'argv    : '; printf '%q ' "$BIN" "${args[@]}"
  case "$proxy_mode" in
    relay)  printf '%q ' "--proxy-server=socks5://127.0.0.1:<relay-port>";;
    direct) printf '%q ' "--proxy-server=$proxy_url";;
  esac
  printf '\n'
  exit 0
fi

mkdir -p "$UDD"   # create the profile dir only on a real launch (dry run leaves no trace)

# No proxy, or a no-auth proxy: hand the flag straight to Chromium and exec.
if [[ "$proxy_mode" == "direct" ]]; then
  args+=("--proxy-server=$proxy_url")
fi
if [[ "$proxy_mode" != "relay" ]]; then
  exec "$BIN" "${args[@]}"
fi

# Authenticated proxy: bring up the local relay, point Chromium at it, supervise
# (no exec, so the EXIT trap can tear the relay down when the browser quits).
command -v python3 >/dev/null 2>&1 || { printf 'error: authenticated proxy needs python3 for the local relay\n' >&2; exit 1; }
RELAY="$ROOT/packaging/proxy-relay.py"
[[ -x "$RELAY" ]] || { printf 'error: relay missing or not executable: %s\n' "$RELAY" >&2; exit 1; }
lport="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || true)"
[[ "$lport" =~ ^[0-9]+$ ]] || { printf 'error: could not allocate a local relay port\n' >&2; exit 1; }
python3 "$RELAY" --listen "127.0.0.1:$lport" --upstream "$proxy_url" &
relay_pid=$!
trap 'kill "$relay_pid" 2>/dev/null; wait "$relay_pid" 2>/dev/null' EXIT INT TERM
ready=0
for _ in $(seq 1 50); do
  if /usr/bin/nc -z 127.0.0.1 "$lport" 2>/dev/null; then ready=1; break; fi
  kill -0 "$relay_pid" 2>/dev/null || break          # relay died early
  /bin/sleep 0.1
done
[[ "$ready" == "1" ]] || { printf 'error: proxy relay failed to come up on 127.0.0.1:%s\n' "$lport" >&2; exit 1; }
args+=("--proxy-server=socks5://127.0.0.1:$lport")
"$BIN" "${args[@]}" || true                          # block until the browser quits; trap kills the relay
