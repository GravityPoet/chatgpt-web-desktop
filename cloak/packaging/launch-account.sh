#!/bin/bash
set -euo pipefail

# Launch one multi-account ChatGPT identity in the FULL CloakBrowser.
#
# Isolation model:
#   - identity      := stable per-account --fingerprint=<seed>
#   - storage/login := own --user-data-dir under Accounts/<name>
#   - network       := per-account proxy when configured, else current system VPN
#   - timezone/lang := resolved from the SAME exit path the browser will use
#   - privacy check := throwaway-profile browser probe runs in the background
#
# Usage:
#   launch-account.sh <account-name>
#   DRY_RUN=1 launch-account.sh <name>              # print argv, do not launch
#   CLOAK_ALLOW_PRIVACY_FAIL=1 launch-account.sh x  # explicit override gate failures
#   CLOAK_PREFLIGHT=strict launch-account.sh x      # block launch until browser probe passes
#   CLOAK_PREFLIGHT=0 launch-account.sh x           # skip browser probe only

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

name="${1:-}"
[[ -n "$name" ]] || { printf 'usage: %s <account-name>\n' "$(basename "$0")" >&2; exit 1; }
[[ "$name" == "main" ]] && { printf "refuse: 'main' is reserved for the daily PWA profile\n" >&2; exit 1; }
case "$name" in */*|*..*|.*) printf 'bad account name: %s\n' "$name" >&2; exit 1;; esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_SRC="$ROOT/extension/cloak-companion"
[[ -d "$EXT_SRC" ]] || { printf 'error: companion extension not found: %s\n' "$EXT_SRC" >&2; exit 1; }

# Resolve the stealth Chromium: prefer the auto-update symlink, else newest pin.
CB="$HOME/.cloakbrowser"
BIN="$CB/current/Chromium.app/Contents/MacOS/Chromium"
if [[ ! -x "$BIN" ]]; then
  BIN="$(/bin/ls -d "$CB"/chromium-*/Chromium.app/Contents/MacOS/Chromium 2>/dev/null | sort -V | tail -1 || true)"
fi
[[ -n "$BIN" && -x "$BIN" ]] || { printf 'error: CloakBrowser binary not found under %s\n' "$CB" >&2; exit 1; }

UDD="$HOME/Library/Application Support/ChatGPT Cloak/Accounts/$name"
if [[ -z "${DRY_RUN:-}" ]]; then
  mkdir -p "$UDD"
  chmod 700 "$UDD" 2>/dev/null || true
fi

strip() {
  printf '%s' "${1:-}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

truthy() {
  case "${1:-}" in 1|on|true|yes|YES|TRUE|ON) return 0;; *) return 1;; esac
}

osa_esc() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

url_decode() {
  local s="${1:-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$s" <<'PY' 2>/dev/null || printf '%s' "$s"
import sys
from urllib.parse import unquote
print(unquote(sys.argv[1]), end="")
PY
  else
    printf '%s' "$s"
  fi
}

privacy_failures=()
add_privacy_failure() {
  privacy_failures[${#privacy_failures[@]}]="$1"
}

confirm_privacy_override() {
  local body="$1"
  if truthy "${CLOAK_ALLOW_PRIVACY_FAIL:-}"; then
    printf 'privacy gate override: CLOAK_ALLOW_PRIVACY_FAIL=1\n' >&2
    return 0
  fi

  printf '\n隐私门禁失败，默认不启动：\n%s\n\n' "$body" >&2

  if command -v osascript >/dev/null 2>&1; then
    local escaped reply
    escaped="$(osa_esc "隐私门禁失败，默认不启动：\n\n$body\n\n确认仍然启动？")"
    reply="$(osascript <<OSA 2>/dev/null || true
set r to display dialog "$escaped" with title "ChatGPT Cloak 隐私门禁" buttons {"取消", "仍然启动"} default button "取消" with icon caution
return button returned of r
OSA
)"
    [[ "$reply" == "仍然启动" ]] && return 0
  fi

  if [[ -t 0 ]]; then
    local ans
    printf '如果确认仍然启动，请输入 YES: ' >&2
    read -r ans
    [[ "$ans" == "YES" ]] && return 0
  fi
  return 1
}

abort_on_privacy_failures() {
  (( ${#privacy_failures[@]} == 0 )) && return 0

  local body="" i
  for i in "${!privacy_failures[@]}"; do
    body+="$((i + 1)). ${privacy_failures[$i]}"$'\n'
  done
  if confirm_privacy_override "$body"; then
    return 0
  fi
  printf 'aborted: privacy gate failed\n' >&2
  exit 20
}

notify_privacy_failure() {
  local body="$1" report="${2:-}"
  printf '\n后台隐私检测失败：\n%s\n' "$body" >&2
  [[ -n "$report" ]] && printf '报告：%s\n' "$report" >&2

  if command -v osascript >/dev/null 2>&1; then
    local msg escaped
    msg="后台隐私检测失败：\n\n$body"
    [[ -n "$report" ]] && msg+="\n\n报告：$report"
    msg+="\n\n浏览器已启动；请暂停使用该账号，直到修复此项失败。"
    escaped="$(osa_esc "$msg")"
    osascript <<OSA >/dev/null 2>&1 &
display dialog "$escaped" with title "ChatGPT Cloak 隐私检测失败" buttons {"知道了"} default button "知道了" with icon caution
OSA
  fi
}

# Deterministic fallback seed; picker-created accounts pin a random seed in
# .cloak-seed so two display names never accidentally rebuild the same device.
hex="$(printf '%s' "$name" | /usr/bin/shasum -a 256 | cut -c1-8)"
seed=$(( 16#$hex % 90000 + 10000 ))
if [[ -f "$UDD/.cloak-seed" ]]; then
  pinned="$(head -1 "$UDD/.cloak-seed" 2>/dev/null || true)"
  [[ "$pinned" =~ ^[0-9]{4,5}$ ]] && seed="$pinned"
  chmod 600 "$UDD/.cloak-seed" 2>/dev/null || true
fi

EXT_RUNTIME="$UDD/.cloak-companion"
prepare_account_extension() {
  rm -rf "$EXT_RUNTIME"
  /usr/bin/ditto "$EXT_SRC" "$EXT_RUNTIME"
  chmod -R go-rwx "$EXT_RUNTIME" 2>/dev/null || true
  printf 'window.__cloakAccountSeed = "%s";\n' "$seed" > "$EXT_RUNTIME/account-seed-main.js"
  chmod 600 "$EXT_RUNTIME/account-seed-main.js" 2>/dev/null || true
}
if [[ -z "${DRY_RUN:-}" ]]; then
  prepare_account_extension
fi

DEFAULT_EXTRA_EXT_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs/电脑文件/Google插件/Cloak 浏览器插件"
EXTRA_EXT_RUNTIME="$UDD/.cloak-extra-extensions"
extra_ext_root="${CLOAK_EXTRA_EXTENSIONS_DIR:-$DEFAULT_EXTRA_EXT_ROOT}"
load_extension_dirs=("$EXT_RUNTIME")
extra_extension_dirs=()
selftest_extension_dirs=()

slug_for_path() {
  basename "$1" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_*//;s/_*$//'
}

unpack_crx_extension() {
  local crx="$1" dest="$2"
  command -v python3 >/dev/null 2>&1 || { printf 'warn: skip CRX extension, python3 unavailable: %s\n' "$crx" >&2; return 1; }
  rm -rf "$dest"
  mkdir -p "$dest"
  python3 - "$crx" "$dest" <<'PY'
from pathlib import Path
import io
import shutil
import struct
import sys
import zipfile

crx = Path(sys.argv[1])
dest = Path(sys.argv[2])
data = crx.read_bytes()
if data[:4] != b"Cr24":
    raise SystemExit("not a CRX file")
version = struct.unpack("<I", data[4:8])[0]
if version == 2:
    pub_len, sig_len = struct.unpack("<II", data[8:16])
    start = 16 + pub_len + sig_len
elif version == 3:
    header_len = struct.unpack("<I", data[8:12])[0]
    start = 12 + header_len
else:
    raise SystemExit(f"unsupported CRX version: {version}")

with zipfile.ZipFile(io.BytesIO(data[start:])) as zf:
    for info in zf.infolist():
        target = dest / info.filename
        resolved = target.resolve()
        if dest.resolve() not in resolved.parents and resolved != dest.resolve():
            raise SystemExit(f"unsafe path in CRX: {info.filename}")
    zf.extractall(dest)

if not (dest / "manifest.json").is_file():
    shutil.rmtree(dest, ignore_errors=True)
    raise SystemExit("manifest.json missing after CRX unpack")
PY
}

discover_extra_extensions() {
  case "${CLOAK_EXTRA_EXTENSIONS:-1}" in 0|off|false|no|NO|FALSE|OFF) return 0;; esac
  [[ -d "$extra_ext_root" ]] || return 0

  local manifest dir base
  while IFS= read -r manifest; do
    dir="${manifest%/manifest.json}"
    base="${dir##*/}"
    [[ "$base" == "cloak-companion" ]] && continue
    if [[ "$dir" == *","* ]]; then
      printf 'warn: skip extension path containing comma: %s\n' "$dir" >&2
      continue
    fi
    extra_extension_dirs[${#extra_extension_dirs[@]}]="$dir"
    case "$base" in
      "Chromium Web Store 插件") ;;
      *) selftest_extension_dirs[${#selftest_extension_dirs[@]}]="$dir" ;;
    esac
    load_extension_dirs[${#load_extension_dirs[@]}]="$dir"
  done < <(find "$extra_ext_root" -mindepth 2 -maxdepth 2 -name manifest.json -print | sort)

  local crx slug dest
  while IFS= read -r crx; do
    if [[ "$crx" == *","* ]]; then
      printf 'warn: skip CRX extension path containing comma: %s\n' "$crx" >&2
      continue
    fi
    case "$crx" in
      *沉浸式翻译*) continue ;;
    esac
    slug="$(slug_for_path "$crx")"
    [[ -n "$slug" ]] || continue
    dest="$EXTRA_EXT_RUNTIME/$slug"
    if [[ -z "${DRY_RUN:-}" ]]; then
      if ! unpack_crx_extension "$crx" "$dest"; then
        printf 'warn: failed to unpack CRX extension: %s\n' "$crx" >&2
        continue
      fi
      chmod -R go-rwx "$dest" 2>/dev/null || true
    fi
    extra_extension_dirs[${#extra_extension_dirs[@]}]="$dest"
    load_extension_dirs[${#load_extension_dirs[@]}]="$dest"
    selftest_extension_dirs[${#selftest_extension_dirs[@]}]="$dest"
  done < <(find "$extra_ext_root" -maxdepth 1 -type f -name '*.crx' -print | sort)
}

join_load_extensions() {
  local IFS=,
  printf '%s' "${load_extension_dirs[*]}"
}

discover_extra_extensions
load_extensions="$(join_load_extensions)"

region_label=""
[[ -f "$UDD/.cloak-region" ]] && region_label="$(head -1 "$UDD/.cloak-region" 2>/dev/null || true)"

# Optional per-account upstream proxy. Any SOCKS5 proxy, and any authenticated
# proxy, is routed through the local relay so Chromium sees a no-auth local
# SOCKS5 endpoint while DNS resolution stays at the upstream.
proxy_url=""
[[ -f "$UDD/.cloak-proxy" ]] && proxy_url="$(head -1 "$UDD/.cloak-proxy" 2>/dev/null || true)"
[[ -f "$UDD/.cloak-proxy" ]] && chmod 600 "$UDD/.cloak-proxy" 2>/dev/null || true

proxy_mode="none"
proxy_display="off (system VPN / direct)"
proxy_scheme=""
proxy_rest=""
proxy_hostport=""
proxy_userinfo=""
proxy_userinfo_decoded=""
proxy_curl_scheme=""

if [[ -n "$proxy_url" ]]; then
  case "$proxy_url" in
    socks5://*|http://*|https://*) ;;
    *) printf 'error: .cloak-proxy must start socks5://, http:// or https:// (got %q)\n' "$proxy_url" >&2; exit 1;;
  esac
  proxy_scheme="${proxy_url%%://*}"
  proxy_rest="${proxy_url#*://}"
  proxy_hostport="$proxy_rest"
  if [[ "$proxy_rest" == *@* ]]; then
    proxy_userinfo="${proxy_rest%@*}"
    proxy_hostport="${proxy_rest#*@}"
    proxy_userinfo_decoded="$(url_decode "$proxy_userinfo")"
  fi

  case "$proxy_scheme" in
    socks5) proxy_curl_scheme="socks5h"; proxy_mode="relay" ;;
    http|https)
      proxy_curl_scheme="$proxy_scheme"
      if [[ -n "$proxy_userinfo" ]]; then proxy_mode="relay"; else proxy_mode="direct"; fi
      ;;
  esac

  if [[ "$proxy_mode" == "relay" ]]; then
    proxy_display="$proxy_scheme://$proxy_hostport  (via local SOCKS5 relay)"
  else
    proxy_display="$proxy_scheme://$proxy_hostport"
  fi
fi

proxy_curl() {
  local url="$1"
  local args
  args=(--silent --show-error --fail --location --max-time "${CLOAK_GEO_TIMEOUT:-12}")
  if [[ -n "$proxy_url" ]]; then
    args+=(--proxy "$proxy_curl_scheme://$proxy_hostport")
    [[ -n "$proxy_userinfo_decoded" ]] && args+=(--proxy-user "$proxy_userinfo_decoded")
  fi
  /usr/bin/curl "${args[@]}" "$url" 2>/dev/null || true
}

parse_geo_json() {
  local source="$1"
  local json_body
  json_body="$(cat)"
  JSON_BODY="$json_body" python3 - "$source" <<'PY' 2>/dev/null || true
import json
import os
import sys

source = sys.argv[1]
try:
    data = json.loads(os.environ.get("JSON_BODY", ""))
except Exception:
    sys.exit(1)

ip = country = timezone = ""
if source == "ipwho":
    if data.get("success") is not True:
        sys.exit(1)
    ip = str(data.get("ip") or "")
    country = str(data.get("country_code") or "")
    tz = data.get("timezone") or {}
    timezone = str(tz.get("id") or "") if isinstance(tz, dict) else ""
elif source == "ipinfo":
    if data.get("error"):
        sys.exit(1)
    ip = str(data.get("ip") or "")
    country = str(data.get("country") or "")
    timezone = str(data.get("timezone") or "")
elif source == "ip-api":
    if data.get("status") != "success":
        sys.exit(1)
    ip = str(data.get("query") or "")
    country = str(data.get("countryCode") or "")
    timezone = str(data.get("timezone") or "")
else:
    sys.exit(1)

if not ip or not timezone:
    sys.exit(1)
print(f"{ip}\t{country}\t{timezone}")
PY
}

lookup_geo() {
  local body parsed
  body="$(proxy_curl "https://ipwho.is/")"
  parsed="$(printf '%s' "$body" | parse_geo_json ipwho)"
  [[ -n "$parsed" ]] && { printf '%s' "$parsed"; return 0; }

  body="$(proxy_curl "https://ipinfo.io/json")"
  parsed="$(printf '%s' "$body" | parse_geo_json ipinfo)"
  [[ -n "$parsed" ]] && { printf '%s' "$parsed"; return 0; }

  body="$(proxy_curl "http://ip-api.com/json/?fields=status,message,countryCode,timezone,query")"
  parsed="$(printf '%s' "$body" | parse_geo_json ip-api)"
  [[ -n "$parsed" ]] && { printf '%s' "$parsed"; return 0; }
  return 1
}

language_for_country() {
  case "$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')" in
    JP) printf 'ja-JP' ;;
    CN) printf 'zh-CN' ;;
    TW) printf 'zh-TW' ;;
    HK) printf 'zh-HK' ;;
    KR) printf 'ko-KR' ;;
    FR) printf 'fr-FR' ;;
    DE) printf 'de-DE' ;;
    NL) printf 'nl-NL' ;;
    GB|UK) printf 'en-GB' ;;
    US) printf 'en-US' ;;
    CA) printf 'en-CA' ;;
    AU) printf 'en-AU' ;;
    SG) printf 'en-SG' ;;
    TH) printf 'th-TH' ;;
    VN) printf 'vi-VN' ;;
    ID) printf 'id-ID' ;;
    MY) printf 'ms-MY' ;;
    PH) printf 'en-PH' ;;
    IN) printf 'en-IN' ;;
    BR) printf 'pt-BR' ;;
    ES) printf 'es-ES' ;;
    IT) printf 'it-IT' ;;
    TR) printf 'tr-TR' ;;
    RU) printf 'ru-RU' ;;
    *) printf 'en-US' ;;
  esac
}

valid_tz() {
  [[ "${1:-}" =~ ^[A-Za-z]+/[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)?$ ]]
}

region_matches() {
  local label="${1:-}" country="${2:-}" tz="${3:-}"
  [[ -z "$label" ]] && return 0

  local hay tok checked=0
  hay="$(printf '%s %s' "$country" "$tz" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ')"
  for tok in $(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' '); do
    [[ ${#tok} -lt 2 ]] && continue
    checked=1
    case " $hay " in
      *" $tok "*|*"${tok}"*) ;;
      *) return 1 ;;
    esac
  done
  [[ "$checked" == "0" ]] && return 0
  return 0
}

geo_line="$(lookup_geo || true)"
exit_ip=""
country=""
tz_zone=""
if [[ -n "$geo_line" ]]; then
  IFS=$'\t' read -r exit_ip country tz_zone <<<"$geo_line"
fi
if [[ -z "$exit_ip" ]]; then
  exit_ip="$(strip "$(proxy_curl https://api.ipify.org)")"
fi

if [[ -z "$exit_ip" ]]; then
  add_privacy_failure "无法通过账号出口获取公网 IP（proxy=${proxy_display}）。"
fi
if valid_tz "$tz_zone"; then
  export TZ="$tz_zone"
else
  add_privacy_failure "无法通过账号出口解析有效 timezone（got=${tz_zone:-empty}）。"
  tz_zone="(unchanged OS zone: $(/bin/date +%Z))"
fi
if [[ -n "$region_label" ]] && ! region_matches "$region_label" "$country" "$tz_zone"; then
  add_privacy_failure "区域标签「$region_label」与出口 country/timezone 不一致（country=${country:-unknown}, timezone=$tz_zone）。"
fi

# Optional per-account locale. If enabled, derive language from the same exit as
# the browser path; otherwise omit the flag rather than inventing a mismatch.
locale_on=0
if [[ -n "${LOCALE:-}" ]]; then
  case "$LOCALE" in 1|on|true|yes) locale_on=1;; esac
elif [[ -f "$UDD/.cloak-locale" ]]; then
  locale_on=1
fi
accept_lang=""
if [[ "$locale_on" == "1" ]]; then
  primary="$(language_for_country "$country")"
  if [[ "$primary" =~ ^[A-Za-z]{2,3}(-[A-Za-z0-9]+)?$ ]]; then
    base="${primary%%-*}"
    if [[ "$base" == "en" ]]; then
      accept_lang="$primary,en;q=0.9"
    else
      accept_lang="$primary,$base;q=0.9,en-US;q=0.8,en;q=0.7"
    fi
  else
    add_privacy_failure "语言跟随已开启，但无法由账号出口国家码解析 Accept-Language（country=${country:-unknown}）。"
  fi
fi

args=(
  "--user-data-dir=$UDD"
  "--fingerprint=$seed"
  "--fingerprint-platform=macos"
  "--load-extension=$load_extensions"
  "--no-first-run"
  "--no-default-browser-check"
)
[[ -n "$accept_lang" ]] && args+=("--accept-lang=$accept_lang")

proxy_server_arg=""
if [[ "$proxy_mode" == "direct" ]]; then
  proxy_server_arg="$proxy_url"
elif [[ "$proxy_mode" == "relay" ]]; then
  proxy_server_arg="socks5://127.0.0.1:<relay-port>"
fi

args+=(
  "--new-window"
  "https://chatgpt.com/"
)

printf 'account : %s\n' "$name"
printf 'seed    : %s\n' "$seed"
printf 'exit ip : %s\n' "${exit_ip:-unknown}"
printf 'timezone: %s  (page + workers)\n' "${TZ:-$tz_zone}"
printf 'locale  : %s\n' "${accept_lang:-off (navigator.languages = browser default)}"
printf 'proxy   : %s\n' "$proxy_display"
if (( ${#extra_extension_dirs[@]} > 0 )); then
  printf 'plugins : %s\n' "${extra_extension_dirs[*]}"
else
  printf 'plugins : none\n'
fi
printf 'profile : %s\n' "$UDD"
printf 'binary  : %s\n' "$BIN"
printf '提醒    : 不要用 Chromium 原生 Profile 切换账号；隔离入口是这个账号选择器 / launch-account.sh。\n'

if [[ -n "${DRY_RUN:-}" ]]; then
  printf 'argv    : '; printf '%q ' "$BIN" "${args[@]}"
  case "$proxy_mode" in
    relay)  printf '%q ' "--proxy-server=socks5://127.0.0.1:<relay-port>";;
    direct) printf '%q ' "--proxy-server=$proxy_url";;
  esac
  printf '\n'
  exit 0
fi

relay_pid=""
cleanup_relay() {
  if [[ -n "$relay_pid" ]]; then
    kill "$relay_pid" 2>/dev/null || true
    wait "$relay_pid" 2>/dev/null || true
  fi
}

start_relay() {
  command -v python3 >/dev/null 2>&1 || { printf 'error: proxy relay needs python3\n' >&2; exit 1; }
  local relay="$ROOT/packaging/proxy-relay.py"
  [[ -f "$relay" ]] || { printf 'error: relay missing: %s\n' "$relay" >&2; exit 1; }
  local lport
  lport="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || true)"
  [[ "$lport" =~ ^[0-9]+$ ]] || { printf 'error: could not allocate a local relay port\n' >&2; exit 1; }
  python3 "$relay" --listen "127.0.0.1:$lport" --upstream "$proxy_url" &
  relay_pid=$!
  trap cleanup_relay EXIT INT TERM

  local ready=0
  for _ in $(seq 1 50); do
    if /usr/bin/nc -z 127.0.0.1 "$lport" 2>/dev/null; then ready=1; break; fi
    kill -0 "$relay_pid" 2>/dev/null || break
    /bin/sleep 0.1
  done
  [[ "$ready" == "1" ]] || { printf 'error: proxy relay failed on 127.0.0.1:%s\n' "$lport" >&2; exit 1; }
  proxy_server_arg="socks5://127.0.0.1:$lport"
}

if [[ "$proxy_mode" == "relay" ]]; then
  start_relay
fi
if [[ -n "$proxy_server_arg" ]]; then
  browser_args=()
  for ((i = 0; i < ${#args[@]} - 2; i++)); do
    browser_args+=("${args[$i]}")
  done
  browser_args+=("--proxy-server=$proxy_server_arg")
  browser_args+=("${args[$((${#args[@]} - 2))]}" "${args[$((${#args[@]} - 1))]}")
  args=("${browser_args[@]}")
fi

run_browser_selftest() {
  local mode="${CLOAK_PREFLIGHT:-async}"
  [[ "$mode" == "0" ]] && return 0

  if ! command -v node >/dev/null 2>&1; then
    if [[ "$mode" == "strict" ]]; then
      add_privacy_failure "node 不可用，无法执行启动前浏览器隐私自测。"
    else
      notify_privacy_failure "node 不可用，无法执行后台浏览器隐私自测。" ""
    fi
    return 0
  fi
  valid_tz "${TZ:-}" || return 0

  local report_file="$UDD/.cloak-selftest-last.json"
  local selftest_output
  local -a selftest_args
  selftest_args=(--seed "$seed" --tz "$TZ" --expect-timezone "$TZ" --pair --headless --quiet --result-file "$report_file")
  [[ -n "$exit_ip" ]] && selftest_args+=(--expect-ip "$exit_ip")
  [[ -n "$proxy_server_arg" ]] && selftest_args+=(--proxy-server "$proxy_server_arg")
  [[ -n "$accept_lang" ]] && selftest_args+=(--accept-lang "$accept_lang")
  for ext_dir in "${selftest_extension_dirs[@]}"; do
    selftest_args+=(--extra-extension "$ext_dir")
  done

  if [[ "$mode" == "strict" ]]; then
    if ! selftest_output="$(node "$ROOT/selftest/run-selftest.mjs" "${selftest_args[@]}" 2>&1)"; then
      add_privacy_failure "启动前浏览器隐私自测失败：$selftest_output"
    fi
    return 0
  fi

  (
    local out rc
    out="$(node "$ROOT/selftest/run-selftest.mjs" "${selftest_args[@]}" 2>&1)" || rc=$?
    rc="${rc:-0}"
    if [[ "$rc" != "0" ]]; then
      notify_privacy_failure "后台浏览器隐私自测失败：$out" "$report_file"
    fi
  ) &
}

if [[ "${CLOAK_PREFLIGHT:-async}" == "strict" ]]; then
  run_browser_selftest
fi

abort_on_privacy_failures

"$BIN" "${args[@]}" &
browser_pid=$!

if [[ "${CLOAK_PREFLIGHT:-async}" != "strict" ]]; then
  run_browser_selftest
fi

wait "$browser_pid"
