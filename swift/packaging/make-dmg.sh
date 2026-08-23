#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ChatGPT Swift"
APP_DIR="$ROOT/dist/$APP_NAME.app"
DMG_PATH="$ROOT/dist/$APP_NAME.dmg"
STAGING="$ROOT/dist/dmg-staging"
BUNDLE_ID="local.chatgpt-web.swift"
VERIFY_MOUNT="$ROOT/dist/.dmg-verify-$$"
MOUNTED=0
USE_DISKUTIL_IMAGE=0
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

unregister_app_bundle() {
  app_bundle="$1"
  if [[ -d "$app_bundle/Contents" ]]; then
    while IFS= read -r -d '' nested_app; do
      "$LSREGISTER" -u "$nested_app" >/dev/null 2>&1 || true
    done < <(find "$app_bundle/Contents" -type d -name '*.app' -prune -print0 2>/dev/null)
  fi
  "$LSREGISTER" -u "$app_bundle" >/dev/null 2>&1 || true
}

detach_verify_image() {
  if [[ "$USE_DISKUTIL_IMAGE" -eq 1 ]]; then
    /usr/sbin/diskutil eject "$VERIFY_MOUNT"
  else
    hdiutil detach "$VERIFY_MOUNT"
  fi
}

cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [[ -d "$VERIFY_MOUNT/$APP_NAME.app" ]]; then
    unregister_app_bundle "$VERIFY_MOUNT/$APP_NAME.app"
  fi
  if [[ "$MOUNTED" -eq 1 ]]; then
    detach_verify_image >/dev/null 2>&1 || true
  fi
  # The copied bundle is only DMG input. LaunchServices can index it while the
  # image is being assembled, so unregister it before removing the staging tree
  # or the same bundle ID can remain associated with a dead path.
  if [[ -d "$STAGING/$APP_NAME.app/Contents" ]]; then
    unregister_app_bundle "$STAGING/$APP_NAME.app"
  fi
  unregister_app_bundle "$APP_DIR"
  rm -rf "$APP_DIR" "$STAGING" "$VERIFY_MOUNT"
  rm -f "$ROOT/dist/.metadata_never_index"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CHATGPT_SWIFT_KEEP_TRANSIENT_APP=1 "$ROOT/packaging/make-app.sh" >/dev/null

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
: > "$STAGING/.metadata_never_index"
/usr/bin/ditto "$APP_DIR" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

if /usr/sbin/diskutil image create from --help >/dev/null 2>&1; then
  USE_DISKUTIL_IMAGE=1
  /usr/sbin/diskutil image create from \
    --format UDZO \
    --volumeName "$APP_NAME" \
    "$STAGING" \
    "$DMG_PATH"
else
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
fi

hdiutil verify "$DMG_PATH"
rm -rf "$VERIFY_MOUNT"
mkdir -p "$VERIFY_MOUNT"
if [[ "$USE_DISKUTIL_IMAGE" -eq 1 ]]; then
  /usr/sbin/diskutil image attach \
    --readOnly \
    --mountOptions nobrowse \
    --mountPoint "$VERIFY_MOUNT" \
    "$DMG_PATH" >/dev/null
else
  hdiutil attach -readonly -nobrowse -mountpoint "$VERIFY_MOUNT" "$DMG_PATH" >/dev/null
fi
MOUNTED=1
VERIFY_APP="$VERIFY_MOUNT/$APP_NAME.app"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$VERIFY_APP/Contents/Info.plist" 2>/dev/null || true)" == "$BUNDLE_ID" ]]
"$ROOT/packaging/verify-app-bundle.sh" "$VERIFY_APP" >/dev/null
unregister_app_bundle "$VERIFY_APP"
detach_verify_image >/dev/null
MOUNTED=0
rm -rf "$VERIFY_MOUNT"
echo "$DMG_PATH"
