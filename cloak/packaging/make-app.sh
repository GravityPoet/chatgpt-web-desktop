#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
APP_NAME="ChatGPT Cloak"
BINARY_NAME="ChatGPTCloakLauncher"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_NAME="$APP_NAME.app/Contents"
ICON_SOURCE="$REPO_ROOT/tauri/src-tauri/icons/icon.icns"
SIGN_IDENTITY="${CHATGPT_CLOAK_CODESIGN_IDENTITY:-}"

cd "$ROOT"

printf '%s\n' "backup: skipped; dist app bundle is generated and fully rebuildable from this script."

swift build -c release

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(CHATGPT_RUST_CODESIGN_IDENTITY="ChatGPT Cloak Local Code Signing" "$REPO_ROOT/tauri/packaging/ensure-local-codesign-cert.sh")"
fi

mkdir -p "$DIST_DIR"
STAGING_DIR="$(/usr/bin/mktemp -d "$DIST_DIR/.chatgpt-cloak-app.XXXXXX")"
cleanup() {
  /bin/rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

CONTENTS="$STAGING_DIR/$CONTENTS_NAME"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$MACOS" "$RESOURCES"
cp ".build/release/$BINARY_NAME" "$MACOS/$BINARY_NAME"

cat >"$CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleDisplayName</key>
	<string>ChatGPT Cloak</string>
	<key>CFBundleExecutable</key>
	<string>ChatGPTCloakLauncher</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>local.chatgpt-cloak</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>ChatGPT Cloak</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>LSMultipleInstancesProhibited</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>ChatGPT voice input uses the microphone.</string>
	<key>NSCameraUsageDescription</key>
	<string>ChatGPT video and vision features use the camera.</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
EOF

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES/AppIcon.icns"
else
  printf '%s\n' "warning: icon not found at $ICON_SOURCE" >&2
fi

chmod +x "$MACOS/$BINARY_NAME"

/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$STAGING_DIR/$APP_NAME.app"
/usr/bin/codesign --verify --deep --strict "$STAGING_DIR/$APP_NAME.app"

rm -rf "$APP_DIR"
mv "$STAGING_DIR/$APP_NAME.app" "$APP_DIR"

printf '%s\n' "$APP_DIR"
