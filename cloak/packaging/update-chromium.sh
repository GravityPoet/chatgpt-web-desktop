#!/bin/bash
set -euo pipefail

# Hands-off auto-update for the stealth Chromium binary.
#
# CloakBrowser pins macOS to a specific darwin-arm64 build; only releases that
# actually ship a `cloakbrowser-darwin-arm64.tar.gz` asset are valid macOS
# targets (newer linux/windows-only releases must be ignored). This script:
#   1. asks the CloakHQ GitHub releases API for the newest release carrying the
#      darwin-arm64 asset  → the authoritative "latest macOS version",
#   2. compares it to the installed version (the ~/.cloakbrowser/current target),
#   3. if newer AND no Cloak Chromium is running: downloads from cloakbrowser.dev,
#      SHA256-verifies against the release SHA256SUMS, extracts, strips quarantine,
#   4. stages the new build as a candidate, re-applies the macOS post-steps —
#      TCC mic/cam patch + re-sign (patch-chromium.sh), then verifies the
#      candidate while `current` still points at the stable build,
#   5. only repoints `current` after the local contract and live challenge gate
#      pass; otherwise the stable build stays active and the candidate is kept
#      for inspection,
#   6. LaunchServices re-registers the approved build and refreshes the PWA icon,
#   7. keeps the previous version on disk for rollback; prunes older ones.
#
# Safe to run on a timer (launchd). No-op when already current or when a browser
# is open (deferred to the next run). DRY_RUN=1 reports the decision only.
# Optional GITHUB_TOKEN raises the API rate limit. All output also appended to
# ~/.cloakbrowser/update.log.

# launchd runs with a minimal PATH; make Homebrew tools (jq) and system tools resolve.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CB="${CLOAKBROWSER_DIR:-$HOME/.cloakbrowser}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # cloak/
LOG="$CB/update.log"
RUNTIME_SHA_FILE="$CB/current.sha256"
REPO="CloakHQ/cloakbrowser"
ASSET="cloakbrowser-darwin-arm64.tar.gz"
DEV_BASE="https://cloakbrowser.dev"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

mkdir -p "$CB"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG" >&2; }
die() { log "ERROR: $*"; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq not found (brew install jq)"

marker_hash() {
  if [[ -f "$1" ]]; then
    awk 'NR == 1 { print $1 }' "$1"
  fi
  return 0
}

write_hash_file() {
  local file="$1" hash="$2" path="$3"
  mkdir -p "$(dirname "$file")"
  printf '%s  %s\n' "$hash" "$path" > "$file.tmp"
  mv -f "$file.tmp" "$file"
}

# 1) installed version (current symlink target, else newest chromium-* dir)
installed=""
if [[ -L "$CB/current" ]]; then
  installed="$(basename "$(readlink "$CB/current")")"; installed="${installed#chromium-}"
fi
if [[ -z "$installed" ]]; then
  d="$(ls -d "$CB"/chromium-* 2>/dev/null | sort -V | tail -1 || true)"
  installed="${d##*/chromium-}"
fi
[[ -n "$installed" ]] || die "no installed Chromium found under $CB"

# 2) latest macOS version = newest release whose assets include the darwin tarball
api="https://api.github.com/repos/$REPO/releases?per_page=50"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  json="$(curl -fsSL --max-time 30 -H "Authorization: Bearer $GITHUB_TOKEN" "$api" 2>>"$LOG" || true)"
else
  json="$(curl -fsSL --max-time 30 "$api" 2>>"$LOG" || true)"
fi
[[ -n "$json" ]] || { log "GitHub API unreachable; skip this run"; exit 0; }
latest_tag="$(printf '%s' "$json" | jq -r --arg a "$ASSET" \
  'map(select([.assets[].name] | index($a))) | sort_by(.tag_name) | reverse | .[0].tag_name // ""')"
[[ -n "$latest_tag" ]] || { log "no macOS (darwin-arm64) release found; skip"; exit 0; }
latest="${latest_tag#chromium-v}"

log "installed=$installed latest=$latest"

# 2b) Picker freshness. The installed Cloak Picker statically links cloak-core, which
# this binary updater never rebuilds; a source edit can silently leave it on an old
# launch plan. Check every tick (incl. no-op). Warn-only here — rebuild is interactive
# (check-picker-fresh.sh --rebuild) or opt-in via CLOAK_PICKER_AUTO_REBUILD=1. DRY_RUN
# must never trigger a rebuild.
if [[ -n "${DRY_RUN:-}" ]]; then
  CLOAK_PICKER_AUTO_REBUILD="" "$ROOT/packaging/check-picker-fresh.sh" >>"$LOG" 2>&1 || true
else
  "$ROOT/packaging/check-picker-fresh.sh" >>"$LOG" 2>&1 || log "warn: picker freshness check failed"
fi

# 3) decide
if [[ "$installed" == "$latest" ]]; then log "up to date; no-op"; exit 0; fi
newer="$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | tail -1)"
[[ "$newer" == "$latest" && "$newer" != "$installed" ]] || { log "installed >= latest; no-op"; exit 0; }

if [[ -n "${DRY_RUN:-}" ]]; then log "DRY-RUN: would update $installed -> $latest"; exit 0; fi

# 4) never swap under a running browser
if pgrep -f "user-data-dir=.*NoTrace Browser" >/dev/null 2>&1 || \
   pgrep -f "$CB/.*/Chromium.app/Contents/MacOS/Chromium" >/dev/null 2>&1; then
  log "Cloak Chromium running; defer update to next run"; exit 0
fi

# 5) download + verify + stage candidate
tagdir="chromium-v$latest"
dest="$CB/chromium-$latest"
app="$dest/Chromium.app"
candidate_bin="$app/Contents/MacOS/Chromium"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

if [[ -x "$candidate_bin" ]]; then
  log "candidate already staged -> $dest"
else
  url="$DEV_BASE/$tagdir/$ASSET"
  log "downloading $url"
  curl -fSL --max-time 900 "$url" -o "$tmp/$ASSET" 2>>"$LOG" || die "download failed"
  sums="$(curl -fsSL --max-time 60 "$DEV_BASE/$tagdir/SHA256SUMS" 2>>"$LOG" || true)"
  want="$(printf '%s' "$sums" | awk -v a="$ASSET" '$2==a{print $1}')"
  [[ -n "$want" ]] || die "no SHA256 entry for $ASSET"
  got="$(shasum -a 256 "$tmp/$ASSET" | awk '{print $1}')"
  [[ "$got" == "$want" ]] || die "SHA256 mismatch want=$want got=$got"
  log "download sha256 ok"

  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tmp/$ASSET" -C "$dest" || die "extract failed"
  found_app="$(find "$dest" -maxdepth 3 -name 'Chromium.app' -type d | head -1)"
  [[ -n "$found_app" ]] || { rm -rf "$dest"; die "Chromium.app missing after extract"; }
  if [[ "$(dirname "$found_app")" != "$dest" ]]; then
    mv "$found_app" "$dest/"
  fi
  /usr/bin/xattr -cr "$dest" 2>>"$LOG" || true
  log "extracted candidate -> $dest"
fi

[[ -d "$app" ]] || die "candidate Chromium.app missing: $app"
[[ -x "$candidate_bin" ]] || die "candidate Chromium binary missing: $candidate_bin"

# 6) macOS post-steps are scoped to the staged candidate. Do not mutate current.
log "patching staged candidate"
CLOAKBROWSER_DIR="$CB" CLOAK_BROWSER_APP="$app" "$ROOT/packaging/patch-chromium.sh" >>"$LOG" 2>&1 \
  || die "patch-chromium failed for staged candidate"
candidate_sha="$(shasum -a 256 "$candidate_bin" | awk '{print $1}')"
[[ -n "$candidate_sha" ]] || die "could not hash staged candidate"
log "candidate sha256=$candidate_sha"

# 7) local contract gate. This verifies the candidate binary without switching
# current, including Rust/Bash dry-run parity and the local stealth self-test.
command -v node >/dev/null 2>&1 || die "candidate gate cannot run: node not found"
gate_dir="$CB/update-gates/chromium-$latest"
local_pass_file="$gate_dir/local-contract.sha256"
live_pass_file="$gate_dir/live-challenge.sha256"
if [[ "$(marker_hash "$local_pass_file")" == "$candidate_sha" ]]; then
  log "local contract gate already passed for $latest"
else
  log "running local contract gate for candidate $latest"
  CLOAK_BROWSER_BIN="$candidate_bin" \
  CLOAK_BROWSER_EXPECTED_SHA256="$candidate_sha" \
    "$ROOT/packaging/verify-challenge-contract.sh" >>"$LOG" 2>&1 \
    || die "candidate $latest failed local challenge contract; current unchanged (candidate kept at $dest)"
  write_hash_file "$local_pass_file" "$candidate_sha" "$candidate_bin"
  log "local contract gate PASS for $latest"
fi

# 8) live challenge gate. Timer runs stage candidates but does not silently
# switch them. A human-triggered run with CLOAK_UPDATE_LIVE_GATE=1 opens a
# headed temporary browser, audits the detection sites, and only then promotes.
if [[ "$(marker_hash "$live_pass_file")" == "$candidate_sha" ]]; then
  log "live challenge gate already passed for $latest"
elif [[ "${CLOAK_UPDATE_LIVE_GATE:-}" == "1" ]]; then
  live_report_dir="$CB/update-gates/chromium-$latest/live-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$live_report_dir"
  log "running live challenge gate for candidate $latest -> $live_report_dir"
  CLOAK_BROWSER_BIN="$candidate_bin" \
  CLOAK_BROWSER_EXPECTED_SHA256="$candidate_sha" \
    node "$ROOT/selftest/run-live-challenge-audit.mjs" \
      --headed \
      --site browserscan \
      --site sannysoft \
      --site browserleaks-webrtc \
      --site creepjs \
      --site fingerprint-pro \
      --timeout-ms 120000 \
      --no-screenshots \
      --account-name "update-candidate-$(date '+%s')" \
      --result-dir "$live_report_dir" >>"$LOG" 2>&1 \
    || die "candidate $latest failed live challenge gate; current unchanged (report: $live_report_dir/report.json)"
  write_hash_file "$live_pass_file" "$candidate_sha" "$candidate_bin"
  log "live challenge gate PASS for $latest"
else
  log "candidate $latest passed local contract but live challenge gate was not run; current unchanged"
  log "to verify and promote: CLOAK_UPDATE_LIVE_GATE=1 $ROOT/packaging/update-chromium.sh"
  exit 0
fi

# 9) promote only after all gates pass.
ln -sfn "$dest" "$CB/current"; log "current -> $dest"
write_hash_file "$RUNTIME_SHA_FILE" "$candidate_sha" "$CB/current/Chromium.app/Contents/MacOS/Chromium"
[[ -x "$LSREG" ]] && { "$LSREG" -f "$app" >>"$LOG" 2>&1 || log "warn: lsregister failed"; }
"$ROOT/packaging/set-pwa-icon.sh" >>"$LOG" 2>&1 || log "warn: set-pwa-icon failed"

# 10) keep new + previous (rollback); prune older
for d in "$CB"/chromium-*; do
  [[ -d "$d" ]] || continue
  case "$d" in "$dest"|"$CB/chromium-$installed") continue;; esac
  rm -rf "$d" && log "pruned old $d"
done

log "updated $installed -> $latest OK (previous kept for rollback)"
