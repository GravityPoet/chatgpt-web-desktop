#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ChatGPT Swift"
DMG_PATH="${1:-"$ROOT/dist/$APP_NAME.dmg"}"
NOTARY_PROFILE="${CHATGPT_SWIFT_NOTARY_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
VERIFY_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-swift-notary-verify.XXXXXX")"
MOUNTED=0
DMG_BACKUP_DIR=""
DMG_BACKUP=""
ROLLBACK_ON_FAILURE=0

restore_dmg() {
  local rollback_tmp="${DMG_PATH}.rollback.$$"
  [[ -n "$DMG_BACKUP" && -f "$DMG_BACKUP" ]] || return 1
  /bin/cp -p "$DMG_BACKUP" "$rollback_tmp" && /bin/mv -f "$rollback_tmp" "$DMG_PATH"
}

cleanup_verify_mount() {
  status=$?
  trap - EXIT INT TERM
  if [[ "$MOUNTED" -eq 1 ]]; then
    hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || true
  fi
  if [[ "$status" -ne 0 && "$ROLLBACK_ON_FAILURE" -eq 1 ]] && ! restore_dmg; then
    echo "error: failed to roll back DMG after notarization failure: $DMG_PATH" >&2
    status=1
  fi
  [[ -n "$DMG_BACKUP_DIR" ]] && rm -rf "$DMG_BACKUP_DIR"
  rm -rf "$VERIFY_MOUNT"
  exit "$status"
}
trap cleanup_verify_mount EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found. Install Xcode command line tools first." >&2
  exit 2
fi

if [[ ! -f "$DMG_PATH" ]]; then
  if [[ "${CHATGPT_SWIFT_CODESIGN_IDENTITY:-}" != "Developer ID Application:"* ]]; then
    echo "error: refusing to build a local self-signed DMG for notarization; set CHATGPT_SWIFT_CODESIGN_IDENTITY to a Developer ID Application identity first." >&2
    exit 2
  fi
  echo "DMG not found, building it first: $DMG_PATH" >&2
  CHATGPT_SWIFT_CODESIGN_TIMESTAMP="${CHATGPT_SWIFT_CODESIGN_TIMESTAMP:-1}" "$ROOT/packaging/make-dmg.sh" >/dev/null
fi

if ! hdiutil verify "$DMG_PATH" >/dev/null; then
  echo "error: DMG integrity verification failed: $DMG_PATH" >&2
  exit 2
fi
hdiutil attach -readonly -nobrowse -mountpoint "$VERIFY_MOUNT" "$DMG_PATH" >/dev/null
MOUNTED=1
VERIFY_APP="$VERIFY_MOUNT/$APP_NAME.app"
if [[ ! -d "$VERIFY_APP" ]]; then
  echo "error: notarization DMG does not contain $APP_NAME.app" >&2
  exit 2
fi
"$ROOT/packaging/verify-app-bundle.sh" "$VERIFY_APP" developer-id >/dev/null
hdiutil detach "$VERIFY_MOUNT" >/dev/null
MOUNTED=0
rm -rf "$VERIFY_MOUNT"
VERIFY_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-swift-notary-verify.XXXXXX")"

DMG_BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-swift-notary-backup.XXXXXX")"
DMG_BACKUP="$DMG_BACKUP_DIR/$APP_NAME.dmg"
/bin/cp -p "$DMG_PATH" "$DMG_BACKUP"
ROLLBACK_ON_FAILURE=1

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
