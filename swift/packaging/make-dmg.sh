#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ChatGPT Swift"
APP_DIR="$ROOT/dist/$APP_NAME.app"
DMG_PATH="$ROOT/dist/$APP_NAME.dmg"
STAGING="$ROOT/dist/dmg-staging"

"$ROOT/packaging/make-app.sh" >/dev/null

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

if /usr/sbin/diskutil image create from --help >/dev/null 2>&1; then
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
echo "$DMG_PATH"
