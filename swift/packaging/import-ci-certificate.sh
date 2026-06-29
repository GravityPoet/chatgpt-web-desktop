#!/bin/bash
set -euo pipefail

CERTIFICATE_P12_BASE64="${CHATGPT_SWIFT_CERTIFICATE_P12_BASE64:-}"
CERTIFICATE_PASSWORD="${CHATGPT_SWIFT_CERTIFICATE_PASSWORD:-}"
TMP_DIR="${RUNNER_TEMP:-/tmp}"
KEYCHAIN_PATH="${CHATGPT_SWIFT_CI_KEYCHAIN_PATH:-"$TMP_DIR/chatgpt-swift-signing.keychain-db"}"
KEYCHAIN_PASSWORD="${CHATGPT_SWIFT_CI_KEYCHAIN_PASSWORD:-$(/usr/bin/uuidgen)}"
CERTIFICATE_TEXT="$TMP_DIR/chatgpt-swift-certificate.p12.base64"
CERTIFICATE_P12="$TMP_DIR/chatgpt-swift-certificate.p12"

if [[ -z "$CERTIFICATE_P12_BASE64" || -z "$CERTIFICATE_PASSWORD" ]]; then
  echo "error: CHATGPT_SWIFT_CERTIFICATE_P12_BASE64 and CHATGPT_SWIFT_CERTIFICATE_PASSWORD are required." >&2
  exit 2
fi

cleanup() {
  rm -f "$CERTIFICATE_TEXT" "$CERTIFICATE_P12"
}
trap cleanup EXIT

printf '%s' "$CERTIFICATE_P12_BASE64" >"$CERTIFICATE_TEXT"
if ! /usr/bin/base64 -D <"$CERTIFICATE_TEXT" >"$CERTIFICATE_P12" 2>/dev/null; then
  /usr/bin/base64 --decode <"$CERTIFICATE_TEXT" >"$CERTIFICATE_P12"
fi

/usr/bin/security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
/usr/bin/security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
/usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
/usr/bin/security import "$CERTIFICATE_P12" \
  -k "$KEYCHAIN_PATH" \
  -P "$CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null
/usr/bin/security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH" >/dev/null
/usr/bin/security list-keychains -d user -s "$KEYCHAIN_PATH"
/usr/bin/security default-keychain -d user -s "$KEYCHAIN_PATH"

identity="$(
  /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
    | /usr/bin/awk -F '"' '/Developer ID Application:/ { print $2; exit }'
)"

if [[ -z "$identity" ]]; then
  echo "error: no Developer ID Application identity found in imported certificate." >&2
  /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN_PATH" >&2 || true
  exit 2
fi

printf '%s\n' "$identity"
