#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ChatGPT Swift"
APP_DIR="$ROOT/dist/$APP_NAME.app"
DMG_PATH="$ROOT/dist/$APP_NAME.dmg"
DMG_TMP="$DMG_PATH.tmp.$$.dmg"
STAGING="$ROOT/dist/dmg-staging"
BUNDLE_ID="local.chatgpt-web.swift"
VERIFY_MOUNT="$ROOT/dist/.dmg-verify-$$"
MOUNTED=0
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
  hdiutil detach "$VERIFY_MOUNT"
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
  rm -f "$DMG_TMP"
  rm -f "$ROOT/dist/.metadata_never_index"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CHATGPT_SWIFT_KEEP_TRANSIENT_APP=1 "$ROOT/packaging/make-app.sh" >/dev/null

rm -rf "$STAGING" "$DMG_TMP"
mkdir -p "$STAGING"
: > "$STAGING/.metadata_never_index"
/usr/bin/ditto "$APP_DIR" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

# `diskutil image create from` is present on newer runners but its option set
# differs across macOS releases (notably, `--volumeName` is rejected on the
# Xcode 16.4 macOS 15 runner). `hdiutil` remains the stable scripting
# interface for this source-folder-to-UDZO operation.
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_TMP"

hdiutil verify "$DMG_TMP"
rm -rf "$VERIFY_MOUNT"
mkdir -p "$VERIFY_MOUNT"
hdiutil attach -readonly -nobrowse -mountpoint "$VERIFY_MOUNT" "$DMG_TMP" >/dev/null
MOUNTED=1
VERIFY_APP="$VERIFY_MOUNT/$APP_NAME.app"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$VERIFY_APP/Contents/Info.plist" 2>/dev/null || true)" == "$BUNDLE_ID" ]]
"$ROOT/packaging/verify-app-bundle.sh" "$VERIFY_APP" >/dev/null
unregister_app_bundle "$VERIFY_APP"
detach_verify_image >/dev/null
MOUNTED=0
rm -rf "$VERIFY_MOUNT"
mv -f "$DMG_TMP" "$DMG_PATH"
echo "$DMG_PATH"
