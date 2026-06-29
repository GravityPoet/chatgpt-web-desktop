#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ChatGPT Swift"
DMG_PATH="${1:-"$ROOT/dist/$APP_NAME.dmg"}"
NOTARY_PROFILE="${CHATGPT_SWIFT_NOTARY_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found. Install Xcode command line tools first." >&2
  exit 2
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found, building it first: $DMG_PATH" >&2
  CHATGPT_SWIFT_CODESIGN_TIMESTAMP="${CHATGPT_SWIFT_CODESIGN_TIMESTAMP:-1}" "$ROOT/packaging/make-dmg.sh" >/dev/null
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "error: DMG still not found: $DMG_PATH" >&2
  exit 2
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
else
  if [[ -z "$APPLE_ID" || -z "$APPLE_TEAM_ID" || -z "$APPLE_APP_SPECIFIC_PASSWORD" ]]; then
    cat >&2 <<EOF
error: missing notarization credentials.

Use either:
  CHATGPT_SWIFT_NOTARY_PROFILE=<keychain-profile> $0

Or:
  APPLE_ID=<apple-id> APPLE_TEAM_ID=<team-id> APPLE_APP_SPECIFIC_PASSWORD=<app-password> $0

For Developer ID distribution, also build with:
  CHATGPT_SWIFT_CODESIGN_IDENTITY="Developer ID Application: ..." CHATGPT_SWIFT_CODESIGN_TIMESTAMP=1
EOF
    exit 2
  fi

  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
fi

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
/usr/sbin/spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"

printf '%s\n' "$DMG_PATH"
