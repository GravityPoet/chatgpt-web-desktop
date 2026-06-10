#!/bin/bash
set -euo pipefail

# Detect whether the installed Cloak Picker is stale relative to the cloak-core
# source it embeds, and either rebuild it or warn.
#
# Why this exists: Cloak Picker statically links cloak-core (Cargo path dep), so a
# change to crates/cloak-core (e.g. a fingerprint fix) does NOT reach the installed
# /Applications/Cloak Picker.app until the app is rebuilt. update-chromium.sh updates
# the CloakBrowser *binary* but never the Picker, so a code edit can silently ship an
# old launch plan. This script closes that gap.
#
# Mechanism: hash the Rust source the Picker embeds (content-only, path/mtime
# independent), stamp it at install time, and compare on demand.
#
# Modes:
#   (default)   check: app missing or hash != stamp => stale. Stale handling:
#                 - Picker running                       -> defer (log), exit 0
#                 - --rebuild / CLOAK_PICKER_AUTO_REBUILD=1 -> rebuild via installer
#                 - otherwise                            -> warn (log + notification)
#   --stamp     write the current source hash as the freshness stamp (called by the
#               installer after a successful install; also usable to "bless" the
#               current build without rebuilding).
#   --print     print the current source hash and the stored stamp, then exit.
#
# Exit status: 0 = fresh / rebuilt / deferred / warned; non-zero only on hard error.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CB="${CLOAKBROWSER_DIR:-$HOME/.cloakbrowser}"
STAMP="$CB/picker-source.sha256"
INSTALL_APP="${CLOAK_PICKER_INSTALL_APP:-/Applications/Cloak Picker.app}"
PICKER_BIN="$INSTALL_APP/Contents/MacOS/cloak-picker"

log() { printf '%s picker-fresh: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Content hash of every source input compiled into the Picker. Per-file digests
# (value only, no path) over a path-sorted file list, so the result depends on file
# contents and relative layout but not on absolute location or mtimes.
compute_hash() {
  (
    cd "$ROOT"
    {
      find crates/cloak-core/src cloak-picker/src-tauri/src -type f -name '*.rs' 2>/dev/null \
        | sort \
        | while IFS= read -r f; do /usr/bin/shasum -a 256 "$f" | awk '{print $1}'; done
      for extra in crates/cloak-core/Cargo.toml cloak-picker/src-tauri/Cargo.toml Cargo.lock; do
        [ -f "$extra" ] && /usr/bin/shasum -a 256 "$extra" | awk '{print $1}'
      done
    } | /usr/bin/shasum -a 256 | awk '{print $1}'
  )
}

read_stamp() { [ -f "$STAMP" ] && awk 'NR==1{print $1}' "$STAMP" || true; }

write_stamp() {
  local hash="$1"
  mkdir -p "$CB"
  printf '%s  cloak-core+picker source\n' "$hash" > "$STAMP.tmp"
  mv -f "$STAMP.tmp" "$STAMP"
}

picker_running() {
  /usr/bin/pgrep -f "$PICKER_BIN" >/dev/null 2>&1
}

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"ChatGPT Cloak\"" >/dev/null 2>&1 || true
}

rebuild() {
  log "rebuilding Cloak Picker from current cloak-core source"
  bash "$ROOT/packaging/install-cloak-picker-app.sh"
  # The installer calls this script with --stamp on success, so the stamp is fresh.
}

mode="${1:-check}"
case "$mode" in
  --stamp)
    h="$(compute_hash)"
    write_stamp "$h"
    log "stamped source hash ${h:0:12} -> $STAMP"
    ;;
  --print)
    printf 'source  %s\nstamp   %s\napp     %s\n' \
      "$(compute_hash)" "$(read_stamp || echo '(none)')" \
      "$([ -x "$PICKER_BIN" ] && echo present || echo MISSING)"
    ;;
  check|--check|--rebuild)
    want_rebuild=0
    [ "$mode" = "--rebuild" ] && want_rebuild=1
    case "${CLOAK_PICKER_AUTO_REBUILD:-}" in 1|on|true|yes) want_rebuild=1 ;; esac

    now="$(compute_hash)"
    have="$(read_stamp || true)"

    if [ -x "$PICKER_BIN" ] && [ -n "$have" ] && [ "$now" = "$have" ]; then
      log "fresh (source ${now:0:12} matches installed Picker)"
      exit 0
    fi

    if [ ! -x "$PICKER_BIN" ]; then
      reason="Cloak Picker not installed"
    elif [ -z "$have" ]; then
      reason="no freshness stamp (Picker build provenance unknown)"
    else
      reason="cloak-core source changed since the installed Picker was built"
    fi
    log "STALE: $reason"

    if picker_running; then
      log "Cloak Picker is running; deferring rebuild. Quit it and re-run, or rebuild manually."
      notify "Cloak Picker 已过期，退出后将自动重建（或手动重建）"
      exit 0
    fi

    if [ "$want_rebuild" = "1" ]; then
      rebuild
      exit 0
    fi

    log "to apply the latest cloak-core into the Picker, run:"
    log "    bash $ROOT/packaging/check-picker-fresh.sh --rebuild"
    notify "Cloak Picker 已过期，需重建以应用最新指纹/启动逻辑修复"
    exit 0
    ;;
  *)
    printf 'usage: %s [check|--rebuild|--stamp|--print]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
