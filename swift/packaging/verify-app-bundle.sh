#!/bin/bash
set -euo pipefail

APP_PATH="${1:-}"
APP_NAME="ChatGPT Swift"
BUNDLE_ID="local.chatgpt-web.swift"
BINARY_NAME="ChatGPTSwiftWeb"
MINIMUM_SYSTEM_VERSION="12.0"
REQUIRED_ARCHITECTURES=(arm64 x86_64)

if [[ -z "$APP_PATH" || $# -ne 1 ]]; then
  echo "usage: $0 </path/to/$APP_NAME.app>" >&2
  exit 2
fi

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

printf 'APP_BUNDLE_VERIFIED=%s\n' "$APP_PATH"
printf 'APP_ARCHITECTURES=arm64 x86_64\n'
printf 'APP_MINIMUM_MACOS=%s\n' "$MINIMUM_SYSTEM_VERSION"
printf 'EMBEDDED_UNIVERSAL_BINARIES=%s\n' "$verified_embedded_binaries"
