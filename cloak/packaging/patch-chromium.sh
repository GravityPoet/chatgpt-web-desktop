#!/bin/bash
set -euo pipefail

# Patch the CloakBrowser Chromium so ChatGPT voice/camera does not crash macOS TCC.
#
# CloakBrowser ships an ad-hoc Chromium whose Info.plist has no NSMicrophoneUsageDescription.
# On macOS, the instant a process touches the microphone (ChatGPT getUserMedia) without that
# usage-description key, TCC terminates the process:
#   namespace=TCC ... "must contain an NSMicrophoneUsageDescription key"
# That termination is the "Chromium 意外退出" crash when granting the mic permission.
#
# Fix: inject NSMicrophoneUsageDescription + NSCameraUsageDescription into the main app and its
# helper bundles, then ad-hoc re-sign so the bundle seals stay consistent. Idempotent and
# re-runnable. CloakBrowser upgrades replace Chromium and drop the keys again, so re-run after
# every CloakBrowser upgrade.
#
# Note: Chromium is intentionally NOT rebranded. The green ChatGPT identity belongs to the
# ChatGPT Cloak launcher; the Chromium it drives stays a plain browser so the two are distinct.

PLISTBUDDY=/usr/libexec/PlistBuddy
MIC_DESC="ChatGPT voice input uses the microphone."
CAM_DESC="ChatGPT video and vision features use the camera."

CLOAK_DIR="${CLOAKBROWSER_DIR:-$HOME/.cloakbrowser}"

shopt -s nullglob
APPS=("$CLOAK_DIR"/chromium-*/Chromium.app)
if [[ ${#APPS[@]} -eq 0 ]]; then
  printf 'error: no CloakBrowser Chromium found under %s\n' "$CLOAK_DIR" >&2
  exit 1
fi

set_key() {
  local plist="$1" key="$2" val="$3"
  if "$PLISTBUDDY" -c "Print :$key" "$plist" >/dev/null 2>&1; then
    "$PLISTBUDDY" -c "Set :$key $val" "$plist"
  else
    "$PLISTBUDDY" -c "Add :$key string $val" "$plist"
  fi
}

for APP in "${APPS[@]}"; do
  PLISTS=("$APP/Contents/Info.plist")
  HELPERS_DIR="$APP/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Helpers"
  for HELPER in "$HELPERS_DIR"/*.app; do
    PLISTS+=("$HELPER/Contents/Info.plist")
  done

  for PLIST in "${PLISTS[@]}"; do
    [[ -f "$PLIST" ]] || continue
    set_key "$PLIST" NSMicrophoneUsageDescription "$MIC_DESC"
    set_key "$PLIST" NSCameraUsageDescription "$CAM_DESC"
  done

  # Re-sign bottom-up so the modified Info.plist hashes and nested seals match again.
  # The build is already ad-hoc (no Team ID, no notarization), so ad-hoc re-sign is equivalent.
  /usr/bin/codesign --force --deep --sign - "$APP"
  /usr/bin/codesign --verify --deep --strict "$APP"

  printf 'patched + resigned: %s\n' "$APP"
done

printf '\ndone. Quit any running Cloak Chromium and relaunch ChatGPT Cloak for the change to take effect.\n'
