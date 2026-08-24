#!/bin/bash
set -euo pipefail

APP_PATH="${1:-}"
DISTRIBUTION="${2:-auto}"
APP_NAME="ChatGPT Swift"
BUNDLE_ID="local.chatgpt-web.swift"
BINARY_NAME="ChatGPTSwiftWeb"
MINIMUM_SYSTEM_VERSION="12.0"
EXPECTED_SPARKLE_VERSION="2.9.6"
REQUIRED_ARCHITECTURES=(arm64 x86_64)

if [[ -z "$APP_PATH" || $# -gt 2 ]]; then
  echo "usage: $0 </path/to/$APP_NAME.app> [github|developer-id|auto]" >&2
  exit 2
fi
case "$DISTRIBUTION" in
  auto|github|developer-id) ;;
  *)
    echo "error: distribution must be github, developer-id, or auto" >&2
    exit 2
    ;;
esac

INFO_PLIST="$APP_PATH/Contents/Info.plist"
MAIN_BINARY="$APP_PATH/Contents/MacOS/$BINARY_NAME"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

if [[ ! -d "$APP_PATH" || ! -f "$INFO_PLIST" || ! -x "$MAIN_BINARY" ]]; then
  echo "error: incomplete app bundle: $APP_PATH" >&2
  exit 2
fi

verify_universal_binary() {
  local binary="$1"
  if ! /usr/bin/lipo "$binary" -verify_arch "${REQUIRED_ARCHITECTURES[@]}" >/dev/null; then
    echo "error: binary is not arm64+x86_64 universal: $binary" >&2
    return 1
  fi
}

minimum_version_for_architecture() {
  local binary="$1"
  local architecture="$2"
  /usr/bin/otool -arch "$architecture" -l "$binary" | /usr/bin/awk '
    $1 == "cmd" && ($2 == "LC_BUILD_VERSION" || $2 == "LC_VERSION_MIN_MACOSX") {
      in_version_command = 1
      next
    }
    in_version_command && ($1 == "minos" || $1 == "version") {
      print $2
      exit
    }
  '
}

actual_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$actual_bundle_id" != "$BUNDLE_ID" ]]; then
  echo "error: unexpected bundle identifier: ${actual_bundle_id:-<missing>}" >&2
  exit 1
fi

plist_minimum="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$plist_minimum" != "$MINIMUM_SYSTEM_VERSION" ]]; then
  echo "error: LSMinimumSystemVersion must be $MINIMUM_SYSTEM_VERSION, got ${plist_minimum:-<missing>}" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "$APP_PATH"
signing_details="$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
if [[ "$DISTRIBUTION" == "auto" ]]; then
  if printf '%s' "$signing_details" | /usr/bin/grep -q 'Authority=Developer ID Application:'; then
    DISTRIBUTION="developer-id"
  else
    DISTRIBUTION="github"
  fi
fi
if [[ "$DISTRIBUTION" == "developer-id" ]] && ! printf '%s' "$signing_details" | /usr/bin/grep -q 'Authority=Developer ID Application:'; then
  echo "error: developer-id verification requires a Developer ID Application signing identity" >&2
  exit 1
fi
if ! entitlements="$(/usr/bin/codesign -d --entitlements - "$APP_PATH" 2>/dev/null)"; then
  echo "error: unable to inspect app entitlements" >&2
  exit 1
fi
for forbidden_entitlement in \
  com.apple.security.get-task-allow \
  com.apple.security.cs.allow-dyld-environment-variables
do
  if printf '%s' "$entitlements" | /usr/bin/grep -q "$forbidden_entitlement"; then
    echo "error: app carries forbidden debug entitlement: $forbidden_entitlement" >&2
    exit 1
  fi
done
if [[ "$DISTRIBUTION" == "developer-id" ]] && printf '%s' "$entitlements" | /usr/bin/grep -q 'com.apple.security.cs.disable-library-validation'; then
  echo "error: Developer ID app carries the local-only library-validation exception" >&2
  exit 1
fi
if [[ "$DISTRIBUTION" == "github" ]]; then
  while IFS= read -r entitlement_key; do
    case "$entitlement_key" in
      com.apple.security.cs.disable-library-validation) ;;
      *)
        echo "error: local/GitHub app carries an unapproved security entitlement: $entitlement_key" >&2
        exit 1
        ;;
    esac
  done < <(
    printf '%s' "$entitlements" | /usr/bin/sed -nE \
      -e 's/.*<key>(com\.apple\.security\.[^<]+)<\/key>.*/\1/p' \
      -e 's/.*\[Key\] (com\.apple\.security\.[^[:space:]]+).*/\1/p'
  )
fi
verify_universal_binary "$MAIN_BINARY"

for architecture in "${REQUIRED_ARCHITECTURES[@]}"; do
  binary_minimum="$(minimum_version_for_architecture "$MAIN_BINARY" "$architecture")"
  if [[ "$binary_minimum" != "$MINIMUM_SYSTEM_VERSION" ]]; then
    echo "error: $BINARY_NAME $architecture minimum macOS must be $MINIMUM_SYSTEM_VERSION, got ${binary_minimum:-<missing>}" >&2
    exit 1
  fi
done

if [[ ! -d "$FRAMEWORKS_DIR" ]]; then
  echo "error: embedded Frameworks directory is missing" >&2
  exit 1
fi

SPARKLE_FRAMEWORK="$FRAMEWORKS_DIR/Sparkle.framework"
SPARKLE_BINARY="$SPARKLE_FRAMEWORK/Versions/Current/Sparkle"
if [[ ! -x "$SPARKLE_BINARY" ]]; then
  SPARKLE_BINARY="$SPARKLE_FRAMEWORK/Sparkle"
fi
if [[ ! -d "$SPARKLE_FRAMEWORK" || ! -x "$SPARKLE_BINARY" ]]; then
  echo "error: embedded Sparkle.framework executable is missing" >&2
  exit 1
fi
SPARKLE_INFO_PLIST="$SPARKLE_FRAMEWORK/Versions/Current/Resources/Info.plist"
[[ -f "$SPARKLE_INFO_PLIST" ]] || SPARKLE_INFO_PLIST="$SPARKLE_FRAMEWORK/Versions/B/Resources/Info.plist"
actual_sparkle_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$SPARKLE_INFO_PLIST" 2>/dev/null || true)"
if [[ "$actual_sparkle_version" != "$EXPECTED_SPARKLE_VERSION" ]]; then
  echo "error: embedded Sparkle version must be $EXPECTED_SPARKLE_VERSION, got ${actual_sparkle_version:-<missing>}" >&2
  exit 1
fi
verify_universal_binary "$SPARKLE_BINARY"
if ! /usr/bin/otool -L "$MAIN_BINARY" | /usr/bin/grep -Eq '@rpath/Sparkle\.framework/Versions/[^/[:space:]]+/Sparkle'; then
  echo "error: main executable does not link the embedded Sparkle.framework" >&2
  exit 1
fi

verified_embedded_binaries=0
while IFS= read -r -d '' candidate; do
  if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    verify_universal_binary "$candidate"
    verified_embedded_binaries=$((verified_embedded_binaries + 1))
  fi
done < <(/usr/bin/find "$FRAMEWORKS_DIR" -type f -perm -111 -print0)

if [[ "$verified_embedded_binaries" -eq 0 ]]; then
  echo "error: no embedded framework binaries were found" >&2
  exit 1
fi

if [[ "$DISTRIBUTION" == "developer-id" ]]; then
  while IFS= read -r -d '' candidate; do
    if ! /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
      continue
    fi
    candidate_details="$(/usr/bin/codesign -dv --verbose=4 "$candidate" 2>&1 || true)"
    if ! printf '%s' "$candidate_details" | /usr/bin/grep -q 'Authority=Developer ID Application:'; then
      echo "error: embedded Mach-O is not signed with Developer ID: $candidate" >&2
      exit 1
    fi
    if ! candidate_entitlements="$(/usr/bin/codesign -d --entitlements - "$candidate" 2>/dev/null)"; then
      echo "error: unable to inspect embedded Mach-O entitlements: $candidate" >&2
      exit 1
    fi
    for forbidden_entitlement in \
      com.apple.security.cs.disable-library-validation \
      com.apple.security.get-task-allow \
      com.apple.security.cs.allow-dyld-environment-variables
    do
      if printf '%s' "$candidate_entitlements" | /usr/bin/grep -q "$forbidden_entitlement"; then
        echo "error: embedded Mach-O carries forbidden entitlement $forbidden_entitlement: $candidate" >&2
        exit 1
      fi
    done
  done < <(/usr/bin/find "$APP_PATH/Contents" -type f -print0)
fi

printf 'APP_BUNDLE_VERIFIED=%s\n' "$APP_PATH"
printf 'APP_ARCHITECTURES=arm64 x86_64\n'
printf 'APP_MINIMUM_MACOS=%s\n' "$MINIMUM_SYSTEM_VERSION"
printf 'EMBEDDED_UNIVERSAL_BINARIES=%s\n' "$verified_embedded_binaries"
printf 'APP_DISTRIBUTION=%s\n' "$DISTRIBUTION"
