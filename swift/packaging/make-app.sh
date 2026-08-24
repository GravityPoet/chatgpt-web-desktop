#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
APP_NAME="ChatGPT Swift"
BINARY_NAME="ChatGPTSwiftWeb"
APP_DIR="$ROOT/dist/$APP_NAME.app"
ARCHIVE="$ROOT/dist/$APP_NAME.zip"
ARCHIVE_TMP="$ARCHIVE.tmp.$$"
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
EXPECTED_SPARKLE_VERSION="2.9.6"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
VERIFY_ROOT=""
CI_LOCAL_KEYCHAIN=""
CI_KEYCHAIN_LIST_BACKUP=""
if [[ "${GITHUB_ACTIONS:-}" == "true" && -z "${CHATGPT_RUST_CODESIGN_KEYCHAIN:-}" ]]; then
  CI_LOCAL_KEYCHAIN="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/chatgpt-rust-local-signing.keychain-db"
  CI_KEYCHAIN_LIST_BACKUP="$(mktemp "${TMPDIR:-/tmp}/chatgpt-swift-keychains.XXXXXX")"
  /usr/bin/security list-keychains -d user >"$CI_KEYCHAIN_LIST_BACKUP" 2>/dev/null || true
fi

unregister_app_bundle() {
  app_bundle="$1"
  if [[ -d "$app_bundle/Contents" ]]; then
    while IFS= read -r -d '' nested_app; do
      "$LSREGISTER" -u "$nested_app" >/dev/null 2>&1 || true
    done < <(find "$app_bundle/Contents" -type d -name '*.app' -prune -print0 2>/dev/null)
  fi
  "$LSREGISTER" -u "$app_bundle" >/dev/null 2>&1 || true
}

cleanup_ci_keychain() {
  if [[ -n "$CI_KEYCHAIN_LIST_BACKUP" && -f "$CI_KEYCHAIN_LIST_BACKUP" ]]; then
    restored_keychains=()
    while IFS= read -r keychain; do
      [[ -n "$keychain" ]] && restored_keychains+=("$keychain")
    done < <(/usr/bin/sed -nE 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/p' "$CI_KEYCHAIN_LIST_BACKUP")
    if [[ "${#restored_keychains[@]}" -gt 0 ]]; then
      /usr/bin/security list-keychains -d user -s "${restored_keychains[@]}" >/dev/null 2>&1 || true
    fi
    rm -f "$CI_KEYCHAIN_LIST_BACKUP"
    CI_KEYCHAIN_LIST_BACKUP=""
  fi
  if [[ -n "$CI_LOCAL_KEYCHAIN" ]]; then
    /usr/bin/security delete-keychain "$CI_LOCAL_KEYCHAIN" >/dev/null 2>&1 || true
  fi
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
    rm -f "$ARCHIVE_TMP"
    rm -f "$ROOT/dist/.metadata_never_index"
  fi
  cleanup_ci_keychain
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
rm -f "$ARCHIVE_TMP"
: > .build/.metadata_never_index
: > dist/.metadata_never_index
if [[ -d .build ]]; then
  while IFS= read -r -d '' nested_app; do
    "$LSREGISTER" -u "$nested_app" >/dev/null 2>&1 || true
  done < <(find .build -type d -name '*.app' -prune -print0 2>/dev/null)
fi
unregister_app_bundle "$APP_DIR"
rm -rf "$APP_DIR"

swift build -c release --arch arm64 --arch x86_64
UNIVERSAL_RELEASE_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$("$REPO_ROOT/tauri/packaging/ensure-local-codesign-cert.sh")"
fi
SIGNING_DISTRIBUTION="github"
case "$SIGN_IDENTITY" in
  "Developer ID Application:"*)
    SIGNING_DISTRIBUTION="developer-id"
    ;;
  *)
    if [[ -z "$SIGN_ENTITLEMENTS" ]]; then
      SIGN_ENTITLEMENTS="$LOCAL_ENTITLEMENTS"
    fi
    ;;
esac

mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

cp "$UNIVERSAL_RELEASE_DIR/$BINARY_NAME" "$MACOS/$BINARY_NAME"
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
  if [[ ! "$SPARKLE_FEED_URL" =~ ^https://[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*(:[0-9]+)?([/?#][^[:cntrl:][:space:]]*)?$ ]]; then
    echo "error: CHATGPT_SWIFT_SPARKLE_FEED_URL must contain a non-empty host and no credentials or control characters." >&2
    exit 2
  fi
  if [[ "$SPARKLE_FEED_URL" =~ ^https://[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*:([0-9]+)([/\?#].*)?$ ]]; then
    sparkle_port="${BASH_REMATCH[4]}"
    if (( sparkle_port < 1 || sparkle_port > 65535 )); then
      echo "error: CHATGPT_SWIFT_SPARKLE_FEED_URL port must be between 1 and 65535." >&2
      exit 2
    fi
  fi
 /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$CONTENTS/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED_URL" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$CONTENTS/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$CONTENTS/Info.plist"
fi

SPARKLE_FRAMEWORK_SOURCE=""
for candidate in \
  "$UNIVERSAL_RELEASE_DIR/Sparkle.framework" \
  "$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
do
  candidate_info="$candidate/Versions/Current/Resources/Info.plist"
  [[ -f "$candidate_info" ]] || candidate_info="$candidate/Versions/B/Resources/Info.plist"
  if [[ -d "$candidate" && -f "$candidate_info" ]] \
      && [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$candidate_info" 2>/dev/null || true)" == "$EXPECTED_SPARKLE_VERSION" ]]; then
    SPARKLE_FRAMEWORK_SOURCE="$candidate"
    break
  fi
done

if [[ -z "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  echo "error: Sparkle.framework $EXPECTED_SPARKLE_VERSION not found after swift build." >&2
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
"$ROOT/packaging/verify-app-bundle.sh" "$APP_DIR" "$SIGNING_DISTRIBUTION" >/dev/null

if [[ "$KEEP_TRANSIENT_APP" == "1" ]]; then
  cleanup_ci_keychain
  trap - EXIT INT TERM
  echo "$APP_DIR"
  exit 0
fi

rm -f "$ARCHIVE_TMP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_TMP"
/usr/bin/unzip -tq "$ARCHIVE_TMP" >/dev/null
VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-swift-archive-verify.XXXXXX")"
: > "$VERIFY_ROOT/.metadata_never_index"
/usr/bin/ditto -x -k "$ARCHIVE_TMP" "$VERIFY_ROOT"
VERIFY_APP="$VERIFY_ROOT/$APP_NAME.app"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$VERIFY_APP/Contents/Info.plist" 2>/dev/null || true)" == "local.chatgpt-web.swift" ]]
"$ROOT/packaging/verify-app-bundle.sh" "$VERIFY_APP" "$SIGNING_DISTRIBUTION" >/dev/null
rm -rf "$VERIFY_ROOT"
VERIFY_ROOT=""
mv -f "$ARCHIVE_TMP" "$ARCHIVE"
unregister_app_bundle "$APP_DIR"
rm -rf "$APP_DIR"
rm -f "$ROOT/dist/.metadata_never_index"
cleanup_ci_keychain
trap - EXIT INT TERM
echo "$ARCHIVE"
