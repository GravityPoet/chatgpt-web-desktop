#!/bin/bash
set -uo pipefail

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
#   4. re-applies the macOS post-steps — TCC mic/cam patch + re-sign
#      (patch-chromium.sh), repoint `current`, LaunchServices re-register so the
#      green PWA resolves the new binary, refresh the PWA icon (set-pwa-icon.sh),
#   5. keeps the previous version on disk for rollback; prunes older ones.
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
REPO="CloakHQ/cloakbrowser"
ASSET="cloakbrowser-darwin-arm64.tar.gz"
DEV_BASE="https://cloakbrowser.dev"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

mkdir -p "$CB"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG" >&2; }
die() { log "ERROR: $*"; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq not found (brew install jq)"

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

# 3) decide
if [[ "$installed" == "$latest" ]]; then log "up to date; no-op"; exit 0; fi
newer="$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | tail -1)"
[[ "$newer" == "$latest" && "$newer" != "$installed" ]] || { log "installed >= latest; no-op"; exit 0; }

if [[ -n "${DRY_RUN:-}" ]]; then log "DRY-RUN: would update $installed -> $latest"; exit 0; fi

# 4) never swap under a running browser
if pgrep -f "user-data-dir=.*ChatGPT Cloak" >/dev/null 2>&1 || \
   pgrep -f "$CB/.*/Chromium.app/Contents/MacOS/Chromium" >/dev/null 2>&1; then
  log "Cloak Chromium running; defer update to next run"; exit 0
fi

# 5) download + verify + extract
tagdir="chromium-v$latest"
dest="$CB/chromium-$latest"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
url="$DEV_BASE/$tagdir/$ASSET"
log "downloading $url"
curl -fSL --max-time 900 "$url" -o "$tmp/$ASSET" 2>>"$LOG" || die "download failed"
sums="$(curl -fsSL --max-time 60 "$DEV_BASE/$tagdir/SHA256SUMS" 2>>"$LOG" || true)"
want="$(printf '%s' "$sums" | awk -v a="$ASSET" '$2==a{print $1}')"
[[ -n "$want" ]] || die "no SHA256 entry for $ASSET"
got="$(shasum -a 256 "$tmp/$ASSET" | awk '{print $1}')"
[[ "$got" == "$want" ]] || die "SHA256 mismatch want=$want got=$got"
log "sha256 ok"

rm -rf "$dest"; mkdir -p "$dest"
tar -xzf "$tmp/$ASSET" -C "$dest" || die "extract failed"
app="$(find "$dest" -maxdepth 3 -name 'Chromium.app' -type d | head -1)"
[[ -n "$app" ]] || { rm -rf "$dest"; die "Chromium.app missing after extract"; }
if [[ "$(dirname "$app")" != "$dest" ]]; then mv "$app" "$dest/"; app="$dest/Chromium.app"; fi
/usr/bin/xattr -cr "$dest" 2>>"$LOG" || true
log "extracted -> $dest"

# 6) macOS post-steps (re-applied because an upgrade replaces the app and drops them)
CLOAKBROWSER_DIR="$CB" "$ROOT/packaging/patch-chromium.sh" >>"$LOG" 2>&1 || log "warn: patch-chromium failed"
ln -sfn "$dest" "$CB/current"; log "current -> $dest"
[[ -x "$LSREG" ]] && { "$LSREG" -f "$app" >>"$LOG" 2>&1 || log "warn: lsregister failed"; }
"$ROOT/packaging/set-pwa-icon.sh" >>"$LOG" 2>&1 || log "warn: set-pwa-icon failed"

# 6.5) regression gate: verify stealth on the new binary; roll back on any hard
# fail. This is intentionally mandatory because the binary carries the actual
# privacy/isolation behavior.
command -v node >/dev/null 2>&1 || {
  log "self-test cannot run: node not found; rolling back current -> $installed"
  ln -sfn "$CB/chromium-$installed" "$CB/current"
  [[ -x "$LSREG" ]] && "$LSREG" -f "$CB/chromium-$installed/Chromium.app" >>"$LOG" 2>&1
  "$ROOT/packaging/set-pwa-icon.sh" >>"$LOG" 2>&1 || true
  die "update $latest blocked because mandatory self-test could not run"
}
if node "$ROOT/selftest/run-selftest.mjs" --pair --headless --quiet --no-result-file >>"$LOG" 2>&1; then
  log "self-test PASS on $latest"
else
  log "self-test FAIL on $latest; rolling back current -> $installed"
  ln -sfn "$CB/chromium-$installed" "$CB/current"
  [[ -x "$LSREG" ]] && "$LSREG" -f "$CB/chromium-$installed/Chromium.app" >>"$LOG" 2>&1
  "$ROOT/packaging/set-pwa-icon.sh" >>"$LOG" 2>&1 || true
  die "update $latest failed mandatory self-test; rolled back to $installed (new build kept at $dest for inspection)"
fi

# 7) keep new + previous (rollback); prune older
for d in "$CB"/chromium-*; do
  [[ -d "$d" ]] || continue
  case "$d" in "$dest"|"$CB/chromium-$installed") continue;; esac
  rm -rf "$d" && log "pruned old $d"
done

log "updated $installed -> $latest OK (previous kept for rollback)"
