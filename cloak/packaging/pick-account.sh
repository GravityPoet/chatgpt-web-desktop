#!/bin/bash
set -euo pipefail

# Clickable account picker for the multi-account ChatGPT identities.
#
# Native macOS account picker: prefers the Rust/Tauri day-mode picker, then
# falls back to the AppKit UI target ChatGPTCloakAccountPicker, then this
# zero-dependency osascript list if Swift is unavailable. It shows each existing identity with its stable
# fingerprint seed, region label, locale state and proxy, then launches the
# chosen one THROUGH launch-account.sh so seed / timezone / proxy / VPN rules all
# stay in one place. It also manages identities without touching a terminal:
#   ➕ new · 🌐 set/clear per-account proxy · 🏷 region label · ⚙︎ locale toggle
#   ✎ rename (keeps the fingerprint) · 🗑 delete (erases that login, confirmed)
#
# All on-screen text is Simplified Chinese; the technical tokens (socks5://,
# http://, "main", seed numbers, example URLs) are left verbatim on purpose.
#
# Region is whatever the account's proxy / the VPN exit is at launch time; the
# 🏷 label is just a human note. Switch the VPN (for accounts without their own
# proxy) to the right region BEFORE launching.
#
# Why this and not just switching profiles inside one browser window:
#   --fingerprint is a PROCESS flag, not a per-profile setting. One Chromium
#   process holding N profiles shares ONE fingerprint, IP and timezone, so
#   switching the active profile isolates cookies ONLY — every account still
#   hashes to the same canvas/WebGL/audio device and ChatGPT can link them.
#   This picker instead launches a SEPARATE process per account, each with its
#   own stable --fingerprint=<seed>, --user-data-dir, timezone, optional locale
#   and optional proxy, so every account looks like a different ordinary Mac and
#   the daily `main` PWA profile is never touched.
#
# Usage:  pick-account.sh        # opens the picker
#         CLOAK_PICKER_TAURI=0 pick-account.sh    # force legacy Swift/osascript
#   Tip: /Applications/Cloak Picker.app is the preferred installed picker.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$ROOT/packaging/launch-account.sh"
ACCT_BASE="$HOME/Library/Application Support/NoTrace Browser/Accounts"
[[ -x "$LAUNCH" ]] || { printf 'error: launcher not found: %s\n' "$LAUNCH" >&2; exit 1; }
mkdir -p "$ACCT_BASE"
chmod 700 "$ACCT_BASE" 2>/dev/null || true

if [[ "${CLOAK_PICKER_LEGACY:-0}" != "1" ]]; then
  export CLOAK_REPO_ROOT="$ROOT"
  export CLOAK_LAUNCH_SCRIPT="$LAUNCH"
  export CLOAK_ACCOUNT_BASE="$ACCT_BASE"

  if [[ "${CLOAK_PICKER_TAURI:-1}" != "0" ]]; then
    TAURI_APP="${CLOAK_PICKER_APP:-}"
    if [[ -z "$TAURI_APP" ]]; then
      for CANDIDATE in \
        "/Applications/Cloak Picker.app" \
        "$ROOT/target/release/bundle/macos/Cloak Picker.app"
      do
        if [[ -x "$CANDIDATE/Contents/MacOS/cloak-picker" ]]; then
          TAURI_APP="$CANDIDATE"
          break
        fi
      done
    fi
    if [[ -n "$TAURI_APP" && -x "$TAURI_APP/Contents/MacOS/cloak-picker" ]]; then
      exec "$TAURI_APP/Contents/MacOS/cloak-picker"
    fi

    # Raw cargo binaries can open a blank WebView when the frontend assets were
    # not embedded by `tauri build`; keep them as an explicit developer fallback.
    if [[ "${CLOAK_PICKER_RAW:-0}" == "1" ]]; then
      if [[ -x "$ROOT/target/release/cloak-picker" ]]; then
        exec "$ROOT/target/release/cloak-picker"
      fi
      if [[ -x "$ROOT/target/debug/cloak-picker" ]]; then
        exec "$ROOT/target/debug/cloak-picker"
      fi
    fi
    printf '%s\n' "warning: no Tauri picker app bundle was found; falling back." >&2
  fi

  if [[ -x "$ROOT/.build/release/ChatGPTCloakAccountPicker" ]]; then
    exec "$ROOT/.build/release/ChatGPTCloakAccountPicker"
  fi

  if command -v swift >/dev/null 2>&1; then
    cd "$ROOT"
    exec swift run -c release ChatGPTCloakAccountPicker
  fi
fi

NEW="➕  新建账号…"
PRX="🌐  设置 / 清除代理…"
REG="🏷  设置区域标签…"
TOG="⚙︎  切换语言…"
REN="✎  重命名账号…"
DEL="🗑  删除账号…"

# Same deterministic seed formula as launch-account.sh (must stay in sync).
seed_of() {
  local hex; hex="$(printf '%s' "$1" | /usr/bin/shasum -a 256 | cut -c1-8)"
  printf '%s' "$(( 16#$hex % 90000 + 10000 ))"
}

# scheme://user:pass@host:port -> scheme://host:port  (never show credentials).
mask_proxy() {
  local u="$1" scheme rest
  scheme="${u%%://*}"; rest="${u#*://}"
  printf '%s://%s' "$scheme" "${rest#*@}"
}

# Escape a value for an AppleScript double-quoted string literal.
osa_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# osascript "choose from list". $1=prompt, rest=items. Echoes the chosen item,
# empty on cancel. Items are escaped for the AppleScript string literal.
choose() {
  local prompt="$1"; shift
  local items="" it
  for it in "$@"; do
    it="${it//\\/\\\\}"; it="${it//\"/\\\"}"
    items+="\"$it\","
  done
  items="${items%,}"
  osascript <<OSA 2>/dev/null || true
set theList to {$items}
set theChoice to choose from list theList with prompt "$prompt" with title "Cloak Picker" OK button name "选择" cancel button name "取消"
if theChoice is false then
  return ""
else
  return item 1 of theChoice
end if
OSA
}

# osascript text prompt. $1=prompt. Echoes entered text, empty on cancel/blank.
ask() {
  osascript <<OSA 2>/dev/null || true
set r to display dialog "$(osa_esc "$1")" default answer "" with title "Cloak Picker" buttons {"取消", "确定"} default button "确定"
if button returned of r is "确定" then
  return text returned of r
end if
return ""
OSA
}

# Like ask but distinguishes Cancel from an empty submit (needed so "blank = clear"
# works). Sets globals ask2_state (OK|CANCEL) and ask2_val. $1=prompt $2=default.
ask2_state=""; ask2_val=""
ask2() {
  local out tab; tab="$(printf '\t')"
  out="$(osascript <<OSA 2>/dev/null || printf 'CANCEL'
set r to display dialog "$(osa_esc "$1")" default answer "$(osa_esc "$2")" with title "Cloak Picker" buttons {"取消", "确定"} default button "确定"
if button returned of r is "确定" then
  return "OK" & tab & (text returned of r)
end if
return "CANCEL"
OSA
)"
  if [[ "$out" == "OK$tab"* ]]; then ask2_state="OK"; ask2_val="${out#OK$tab}"
  else ask2_state="CANCEL"; ask2_val=""; fi
}

# Destructive yes/no with a caution icon. Echoes "yes" only on the Delete button.
confirm() {
  osascript <<OSA 2>/dev/null || printf 'no'
set r to display dialog "$(osa_esc "$1")" with title "Cloak Picker" buttons {"取消", "删除"} default button "取消" with icon caution
if button returned of r is "删除" then
  return "yes"
end if
return "no"
OSA
}

random_seed() {
  local n
  n="$(/usr/bin/od -An -N4 -tu4 /dev/urandom | /usr/bin/tr -d ' ')"
  printf '%s' "$(( n % 90000 + 10000 ))"
}

valid_account_name() {
  case "${1:-}" in
    ""|main|*/*|*\\*|*..*|.*|*.|*[!A-Za-z0-9._@+-]*) return 1;;
    *) return 0;;
  esac
}

invalid_name_message="名字无效：可用字母、数字、.、@、+、-、_；不能叫「main」，不能以 . 开头，不能含 /、\\ 或连续 ..。"

secure_account_dir() {
  local d="$1"
  mkdir -p "$d"
  chmod 700 "$d" 2>/dev/null || true
  [[ -f "$d/.cloak-seed" ]] && chmod 600 "$d/.cloak-seed" 2>/dev/null || true
  [[ -f "$d/.cloak-proxy" ]] && chmod 600 "$d/.cloak-proxy" 2>/dev/null || true
  [[ -f "$d/.cloak-locale" ]] && chmod 600 "$d/.cloak-locale" 2>/dev/null || true
  [[ -f "$d/.cloak-region" ]] && chmod 600 "$d/.cloak-region" 2>/dev/null || true
}

create_account() {
  local n="$1" d="$ACCT_BASE/$1" s
  [[ -e "$d" ]] && { choose "「$n」已存在。" "好" >/dev/null; return 1; }
  secure_account_dir "$d"
  s="$(random_seed)"
  ( umask 077; printf '%s\n' "$s" > "$d/.cloak-seed" )
  chmod 600 "$d/.cloak-seed" 2>/dev/null || true
  return 0
}

names=(); labels=()
build_labels() {
  names=(); labels=()
  local d n s pin loc reg prx
  for d in "$ACCT_BASE"/*/; do
    [[ -d "$d" ]] || continue
    secure_account_dir "${d%/}"
    n="$(basename "$d")"
    [[ "$n" == "main" ]] && continue
    s="$(seed_of "$n")"
    if [[ -f "${d%/}/.cloak-seed" ]]; then
      pin="$(head -1 "${d%/}/.cloak-seed" 2>/dev/null || true)"
      [[ "$pin" =~ ^[0-9]{4,5}$ ]] && s="$pin"
    fi
    loc="关"; [[ -f "${d%/}/.cloak-locale" ]] && loc="开"
    reg=""; [[ -f "${d%/}/.cloak-region" ]] && reg="      $(head -1 "${d%/}/.cloak-region" 2>/dev/null || true)"
    prx="关"; [[ -f "${d%/}/.cloak-proxy" ]] && prx="$(mask_proxy "$(head -1 "${d%/}/.cloak-proxy" 2>/dev/null || true)")"
    names+=("$n")
    labels+=("$n      指纹 $s$reg      语言 $loc      代理 $prx")
  done
}

launch_named() { exec "$LAUNCH" "$1"; }

# Show the account list and echo the chosen NAME (empty on cancel / no accounts).
pick_account() {
  build_labels
  (( ${#names[@]} )) || { choose "还没有账号 —— 先用「➕ 新建账号…」创建。" "好" >/dev/null; return 0; }
  local choice i
  choice="$(choose "$1" ${labels[@]+"${labels[@]}"})"
  [[ -z "$choice" ]] && return 0
  for i in "${!labels[@]}"; do
    [[ "${labels[$i]}" == "$choice" ]] && { printf '%s' "${names[$i]}"; return 0; }
  done
  return 0
}

toggle_menu() {
  local n d
  n="$(pick_account "切换语言（Accept-Language 跟随 VPN 出口区域）。选哪个账号：")"
  [[ -z "$n" ]] && return 0
  d="$ACCT_BASE/$n"
  if [[ -f "$d/.cloak-locale" ]]; then rm -f "$d/.cloak-locale"
  else secure_account_dir "$d"; : > "$d/.cloak-locale"; chmod 600 "$d/.cloak-locale" 2>/dev/null || true; fi
  return 0
}

do_proxy() {
  local n d cur
  n="$(pick_account "给哪个账号设置 / 清除代理：")"
  [[ -z "$n" ]] && return 0
  d="$ACCT_BASE/$n"
  cur=""; [[ -f "$d/.cloak-proxy" ]] && cur="$(head -1 "$d/.cloak-proxy" 2>/dev/null || true)"
  ask2 "「$n」的代理 URL（留空 = 清除）。例：socks5://user:pass@host:1080 或 http://host:8080" "$cur"
  [[ "$ask2_state" == "OK" ]] || return 0
  if [[ -z "$ask2_val" ]]; then
    rm -f "$d/.cloak-proxy"
  else
    case "$ask2_val" in
      socks5://*|http://*|https://*) ;;
      *) choose "代理须以 socks5:// 或 http:// 开头。" "好" >/dev/null; return 0;;
    esac
    secure_account_dir "$d"
    ( umask 177; printf '%s\n' "$ask2_val" > "$d/.cloak-proxy" )   # creds: owner-only
    chmod 600 "$d/.cloak-proxy" 2>/dev/null || true
  fi
  return 0
}

do_region() {
  local n d cur
  n="$(pick_account "给哪个账号设置 / 清除区域标签：")"
  [[ -z "$n" ]] && return 0
  d="$ACCT_BASE/$n"
  cur=""; [[ -f "$d/.cloak-region" ]] && cur="$(head -1 "$d/.cloak-region" 2>/dev/null || true)"
  ask2 "「$n」的区域标签（留空 = 清除）。例：JP-Tokyo 或 东京" "$cur"
  [[ "$ask2_state" == "OK" ]] || return 0
  if [[ -z "$ask2_val" ]]; then secure_account_dir "$d"; rm -f "$d/.cloak-region"
  else secure_account_dir "$d"; printf '%s\n' "$ask2_val" > "$d/.cloak-region"; chmod 600 "$d/.cloak-region" 2>/dev/null || true; fi
  return 0
}

do_rename() {
  local n new d s
  n="$(pick_account "重命名哪个账号：")"
  [[ -z "$n" ]] && return 0
  new="$(ask "「$n」的新名字（可用邮箱格式，如 poet-quench-9i@example.test）：")"
  [[ -z "$new" ]] && return 0
  valid_account_name "$new" || { choose "$invalid_name_message" "好" >/dev/null; return 0; }
  d="$ACCT_BASE/$n"
  [[ -e "$ACCT_BASE/$new" ]] && { choose "「$new」已存在。" "好" >/dev/null; return 0; }
  # Pin the ORIGINAL seed so the device fingerprint survives the new name.
  s="$(seed_of "$n")"
  if [[ -f "$d/.cloak-seed" ]]; then
    local p; p="$(head -1 "$d/.cloak-seed" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]{4,5}$ ]] && s="$p"
  fi
  secure_account_dir "$d"; printf '%s\n' "$s" > "$d/.cloak-seed"; chmod 600 "$d/.cloak-seed" 2>/dev/null || true
  mv "$d" "$ACCT_BASE/$new"
  secure_account_dir "$ACCT_BASE/$new"
  return 0
}

do_delete() {
  local n
  n="$(pick_account "删除哪个账号（会清除它的登录）：")"
  [[ -z "$n" ]] && return 0
  [[ "$(confirm "删除「$n」？将永久清除它的 cookie / 登录，无法撤销。")" == "yes" ]] || return 0
  rm -rf "$ACCT_BASE/$n"
  return 0
}

main_menu() {
  build_labels
  local choice i n
  choice="$(choose "选择要启动的账号：提醒，不要用 Chromium 原生 Profile 切换账号；隔离入口是这里。" ${labels[@]+"${labels[@]}"} "$NEW" "$PRX" "$REG" "$TOG" "$REN" "$DEL")"
  [[ -z "$choice" ]] && exit 0
  case "$choice" in
    "$NEW")
      n="$(ask "新账号名字（可用邮箱格式，如 poet-quench-9i@example.test）：")"
      [[ -z "$n" ]] && exit 0
      valid_account_name "$n" || { choose "$invalid_name_message" "好" >/dev/null; main_menu; return; }
      create_account "$n" || { main_menu; return; }
      launch_named "$n" ;;
    "$PRX") do_proxy;   main_menu ;;
    "$REG") do_region;  main_menu ;;
    "$TOG") toggle_menu; main_menu ;;
    "$REN") do_rename;  main_menu ;;
    "$DEL") do_delete;  main_menu ;;
    *)
      for i in "${!labels[@]}"; do
        [[ "${labels[$i]}" == "$choice" ]] && launch_named "${names[$i]}"
      done
      exit 0 ;;
  esac
}

main_menu
