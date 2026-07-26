#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
APP_NAME="ChatGPT Swift"
BINARY_NAME="ChatGPTSwiftWeb"
APP_DIR="$ROOT/dist/$APP_NAME.app"
ARCHIVE="$ROOT/dist/$APP_NAME.zip"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
ICON_SOURCE="$ROOT/../tauri/src-tauri/icons/icon.icns"
SIGN_IDENTITY="${CHATGPT_SWIFT_CODESIGN_IDENTITY:-}"
SIGN_TIMESTAMP="${CHATGPT_SWIFT_CODESIGN_TIMESTAMP:-0}"
SIGN_ENTITLEMENTS="${CHATGPT_SWIFT_CODESIGN_ENTITLEMENTS:-}"
LOCAL_ENTITLEMENTS="$ROOT/packaging/local-debug.entitlements"
SPARKLE_FEED_URL="${CHATGPT_SWIFT_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${CHATGPT_SWIFT_SPARKLE_PUBLIC_ED_KEY:-}"
SHORT_VERSION_OVERRIDE="${CHATGPT_SWIFT_SHORT_VERSION:-}"
BUILD_NUMBER_OVERRIDE="${CHATGPT_SWIFT_BUILD_NUMBER:-}"
KEEP_TRANSIENT_APP="${CHATGPT_SWIFT_KEEP_TRANSIENT_APP:-0}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
VERIFY_ROOT=""

unregister_app_bundle() {
  app_bundle="$1"
  if [[ -d "$app_bundle/Contents" ]]; then
    while IFS= read -r -d '' nested_app; do
      "$LSREGISTER" -u "$nested_app" >/dev/null 2>&1 || true
    done < <(find "$app_bundle/Contents" -type d -name '*.app' -prune -print0 2>/dev/null)
  fi
  "$LSREGISTER" -u "$app_bundle" >/dev/null 2>&1 || true
}

cleanup_failed_build() {
  status=$?
  trap - EXIT INT TERM
  if [[ -n "$VERIFY_ROOT" ]]; then
    rm -rf "$VERIFY_ROOT"
  fi
  if [[ "$status" -ne 0 ]]; then
    unregister_app_bundle "$APP_DIR"
    rm -rf "$APP_DIR"
    rm -f "$ROOT/dist/.metadata_never_index"
  fi
  exit "$status"
}
trap cleanup_failed_build EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "$SHORT_VERSION_OVERRIDE" && ! "$SHORT_VERSION_OVERRIDE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: CHATGPT_SWIFT_SHORT_VERSION must use numeric major.minor.patch format." >&2
  exit 2
fi
if [[ -n "$BUILD_NUMBER_OVERRIDE" && ! "$BUILD_NUMBER_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CHATGPT_SWIFT_BUILD_NUMBER must be a positive integer." >&2
  exit 2
fi

cd "$ROOT"

mkdir -p .build dist
: > .build/.metadata_never_index
: > dist/.metadata_never_index
if [[ -d .build ]]; then
  while IFS= read -r -d '' nested_app; do
    "$LSREGISTER" -u "$nested_app" >/dev/null 2>&1 || true
  done < <(find .build -type d -name '*.app' -prune -print0 2>/dev/null)
fi
unregister_app_bundle "$APP_DIR"
rm -rf "$APP_DIR"

swift build -c release

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$("$REPO_ROOT/tauri/packaging/ensure-local-codesign-cert.sh")"
fi
case "$SIGN_IDENTITY" in
  "Developer ID Application:"*) ;;
  *)
    if [[ -z "$SIGN_ENTITLEMENTS" ]]; then
      SIGN_ENTITLEMENTS="$LOCAL_ENTITLEMENTS"
    fi
    ;;
esac

mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

cp ".build/release/$BINARY_NAME" "$MACOS/$BINARY_NAME"
cp "$ROOT/packaging/Info.plist" "$CONTENTS/Info.plist"

if [[ -n "$SHORT_VERSION_OVERRIDE" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION_OVERRIDE" "$CONTENTS/Info.plist"
fi
if [[ -n "$BUILD_NUMBER_OVERRIDE" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER_OVERRIDE" "$CONTENTS/Info.plist"
fi
/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null

if [[ -n "$SPARKLE_FEED_URL" || -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  if [[ -z "$SPARKLE_FEED_URL" || -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "error: CHATGPT_SWIFT_SPARKLE_FEED_URL and CHATGPT_SWIFT_SPARKLE_PUBLIC_ED_KEY must be set together." >&2
    exit 2
  fi
  case "$SPARKLE_FEED_URL" in
    https://*) ;;
    *)
      echo "error: CHATGPT_SWIFT_SPARKLE_FEED_URL must be an https:// URL." >&2
      exit 2
      ;;
  esac
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$CONTENTS/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED_URL" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$CONTENTS/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$CONTENTS/Info.plist"
fi

SPARKLE_FRAMEWORK_SOURCE=""
for candidate in \
  "$ROOT/.build/release/Sparkle.framework" \
  "$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
do
  if [[ -d "$candidate" ]]; then
    SPARKLE_FRAMEWORK_SOURCE="$candidate"
    break
  fi
done

if [[ -z "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  echo "error: Sparkle.framework not found after swift build." >&2
  exit 2
fi
/usr/bin/ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS/Sparkle.framework"

if ! /usr/bin/otool -l "$MACOS/$BINARY_NAME" | /usr/bin/grep -q '@executable_path/../Frameworks'; then
  /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/$BINARY_NAME"
fi

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES/AppIcon.icns"
else
  echo "warning: icon not found at $ICON_SOURCE" >&2
fi

chmod +x "$MACOS/$BINARY_NAME"

codesign_args=(--force --deep --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_TIMESTAMP" == "1" ]]; then
  codesign_args+=(--timestamp)
fi
if [[ -n "$SIGN_ENTITLEMENTS" ]]; then
  if [[ ! -f "$SIGN_ENTITLEMENTS" ]]; then
    echo "error: CHATGPT_SWIFT_CODESIGN_ENTITLEMENTS does not exist: $SIGN_ENTITLEMENTS" >&2
    exit 2
  fi
  codesign_args+=(--entitlements "$SIGN_ENTITLEMENTS")
fi

framework_codesign_args=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_TIMESTAMP" == "1" ]]; then
  framework_codesign_args+=(--timestamp)
fi
/usr/bin/codesign "${framework_codesign_args[@]}" "$FRAMEWORKS/Sparkle.framework"
/usr/bin/codesign "${codesign_args[@]}" "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/lipo "$MACOS/$BINARY_NAME" -verify_arch "$(uname -m)"

if [[ "$KEEP_TRANSIENT_APP" == "1" ]]; then
  trap - EXIT INT TERM
  echo "$APP_DIR"
  exit 0
fi

rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
/usr/bin/unzip -tq "$ARCHIVE" >/dev/null
VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-swift-archive-verify.XXXXXX")"
: > "$VERIFY_ROOT/.metadata_never_index"
/usr/bin/ditto -x -k "$ARCHIVE" "$VERIFY_ROOT"
VERIFY_APP="$VERIFY_ROOT/$APP_NAME.app"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$VERIFY_APP/Contents/Info.plist" 2>/dev/null || true)" == "local.chatgpt-web.swift" ]]
/usr/bin/codesign --verify --deep --strict "$VERIFY_APP"
/usr/bin/lipo "$VERIFY_APP/Contents/MacOS/$BINARY_NAME" -verify_arch "$(uname -m)"
rm -rf "$VERIFY_ROOT"
VERIFY_ROOT=""
unregister_app_bundle "$APP_DIR"
rm -rf "$APP_DIR"
rm -f "$ROOT/dist/.metadata_never_index"
trap - EXIT INT TERM
echo "$ARCHIVE"
