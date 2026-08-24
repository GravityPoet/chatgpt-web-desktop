#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ChatGPT Swift"
UPDATE_ARTIFACT="${CHATGPT_SWIFT_SPARKLE_UPDATE_ARTIFACT:-"$ROOT/dist/$APP_NAME.dmg"}"
APPCAST_DIR="${CHATGPT_SWIFT_SPARKLE_APPCAST_DIR:-"$ROOT/dist/sparkle-appcast"}"
APPCAST_NAME="${CHATGPT_SWIFT_SPARKLE_APPCAST_NAME:-appcast.xml}"
DOWNLOAD_URL_PREFIX="${CHATGPT_SWIFT_SPARKLE_DOWNLOAD_URL_PREFIX:-}"
RELEASE_NOTES_URL_PREFIX="${CHATGPT_SWIFT_SPARKLE_RELEASE_NOTES_URL_PREFIX:-}"
PRIVATE_ED_KEY_FILE="${CHATGPT_SWIFT_SPARKLE_ED_KEY_FILE:-}"
PRIVATE_ED_KEY="${CHATGPT_SWIFT_SPARKLE_ED_PRIVATE_KEY:-}"
ACCOUNT="${CHATGPT_SWIFT_SPARKLE_KEY_ACCOUNT:-chatgpt-swift}"
VERIFY_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-swift-appcast-verify.XXXXXX")"
MOUNTED=0
APPCAST_TMP_DIR=""
APPCAST_PATH=""
APPCAST_TMP=""
ARTIFACT_DESTINATION=""
ARTIFACT_TMP=""
APPCAST_BACKUP=""
ARTIFACT_BACKUP=""
APPCAST_REPLACED=0
ARTIFACT_REPLACED=0

restore_file() {
  local target="$1"
  local backup="$2"
  local rollback_tmp="${target}.rollback.$$"
  if [[ -n "$backup" && -f "$backup" ]]; then
    /bin/cp -p "$backup" "$rollback_tmp" && /bin/mv -f "$rollback_tmp" "$target"
  else
    /bin/unlink "$target" 2>/dev/null || true
  fi
}

cleanup_verify_mount() {
  status=$?
  trap - EXIT INT TERM
  if [[ "$MOUNTED" -eq 1 ]]; then
    hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || true
  fi
  if [[ "$status" -ne 0 ]]; then
    rollback_failed=0
    if [[ "$APPCAST_REPLACED" -eq 1 ]] && ! restore_file "$APPCAST_PATH" "$APPCAST_BACKUP"; then
      echo "error: failed to roll back appcast: $APPCAST_PATH" >&2
      rollback_failed=1
    fi
    if [[ "$ARTIFACT_REPLACED" -eq 1 ]] && ! restore_file "$ARTIFACT_DESTINATION" "$ARTIFACT_BACKUP"; then
      echo "error: failed to roll back appcast artifact: $ARTIFACT_DESTINATION" >&2
      rollback_failed=1
    fi
    if [[ "$rollback_failed" -eq 1 ]]; then
      status=1
    fi
  fi
  [[ -n "$ARTIFACT_TMP" ]] && /bin/unlink "$ARTIFACT_TMP" 2>/dev/null || true
  [[ -n "$APPCAST_BACKUP" ]] && /bin/unlink "$APPCAST_BACKUP" 2>/dev/null || true
  [[ -n "$ARTIFACT_BACKUP" ]] && /bin/unlink "$ARTIFACT_BACKUP" 2>/dev/null || true
  [[ -n "$APPCAST_TMP_DIR" ]] && rm -rf "$APPCAST_TMP_DIR"
  rm -rf "$VERIFY_MOUNT"
  exit "$status"
}
trap cleanup_verify_mount EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

find_generate_appcast() {
  local candidate
  for candidate in \
    "${CHATGPT_SWIFT_SPARKLE_TOOLS_DIR:-}/generate_appcast" \
    "$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    "$ROOT/.build/checkouts/Sparkle/generate_appcast"
  do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

validate_public_url_prefix() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^https://[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*(:[0-9]+)?/[^?#[:cntrl:][:space:]]*$ ]]; then
    echo "error: $name must be a valid HTTPS URL without credentials or control characters." >&2
    return 1
  fi
  if [[ "$value" =~ ^https://[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*:([0-9]+)([/\?#].*)?$ ]]; then
    local port="${BASH_REMATCH[4]}"
    if (( port < 1 || port > 65535 )); then
      echo "error: $name port must be between 1 and 65535." >&2
      return 1
    fi
  fi
  if [[ "$value" != */ ]]; then
    echo "error: $name must end with / because Sparkle resolves asset paths relative to the prefix." >&2
    return 1
  fi
}

if [[ -z "$DOWNLOAD_URL_PREFIX" ]]; then
  echo "error: CHATGPT_SWIFT_SPARKLE_DOWNLOAD_URL_PREFIX is required for a publishable appcast." >&2
  exit 2
fi
validate_public_url_prefix "CHATGPT_SWIFT_SPARKLE_DOWNLOAD_URL_PREFIX" "$DOWNLOAD_URL_PREFIX"
if [[ -n "$RELEASE_NOTES_URL_PREFIX" ]]; then
  validate_public_url_prefix "CHATGPT_SWIFT_SPARKLE_RELEASE_NOTES_URL_PREFIX" "$RELEASE_NOTES_URL_PREFIX"
fi
case "$APPCAST_NAME" in
  ""|.|..|*/*)
    echo "error: CHATGPT_SWIFT_SPARKLE_APPCAST_NAME must be a simple file name." >&2
    exit 2
    ;;
esac
if [[ -n "$PRIVATE_ED_KEY_FILE" && -n "$PRIVATE_ED_KEY" ]]; then
  echo "error: set only one of CHATGPT_SWIFT_SPARKLE_ED_KEY_FILE or CHATGPT_SWIFT_SPARKLE_ED_PRIVATE_KEY." >&2
  exit 2
fi
if [[ -n "$PRIVATE_ED_KEY_FILE" && ! -f "$PRIVATE_ED_KEY_FILE" ]]; then
  echo "error: Sparkle EdDSA private key file not found: $PRIVATE_ED_KEY_FILE" >&2
  exit 2
fi
if [[ -z "$PRIVATE_ED_KEY_FILE" && -z "$PRIVATE_ED_KEY" ]]; then
  echo "error: a Sparkle EdDSA private key is required to generate a publishable appcast." >&2
  exit 2
fi

cd "$ROOT"

GENERATE_APPCAST="$(find_generate_appcast || true)"
if [[ -z "$GENERATE_APPCAST" ]]; then
  swift build -c release >/dev/null
  GENERATE_APPCAST="$(find_generate_appcast || true)"
fi

if [[ -z "$GENERATE_APPCAST" ]]; then
  echo "error: Sparkle generate_appcast tool not found. Run swift build first or set CHATGPT_SWIFT_SPARKLE_TOOLS_DIR." >&2
  exit 2
fi

if [[ ! -f "$UPDATE_ARTIFACT" ]]; then
  "$ROOT/packaging/make-dmg.sh" >/dev/null
fi

if ! hdiutil verify "$UPDATE_ARTIFACT" >/dev/null; then
  echo "error: update artifact failed DMG verification: $UPDATE_ARTIFACT" >&2
  exit 2
fi
hdiutil attach -readonly -nobrowse -mountpoint "$VERIFY_MOUNT" "$UPDATE_ARTIFACT" >/dev/null
MOUNTED=1
UPDATE_APP="$VERIFY_MOUNT/ChatGPT Swift.app"
if [[ ! -d "$UPDATE_APP" ]]; then
  echo "error: update artifact does not contain ChatGPT Swift.app" >&2
  exit 2
fi
"$ROOT/packaging/verify-app-bundle.sh" "$UPDATE_APP" auto >/dev/null
hdiutil detach "$VERIFY_MOUNT" >/dev/null
MOUNTED=0
rm -rf "$VERIFY_MOUNT"
VERIFY_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-swift-appcast-verify.XXXXXX")"

if [[ ! -f "$UPDATE_ARTIFACT" ]]; then
  echo "error: update artifact not found: $UPDATE_ARTIFACT" >&2
  exit 2
fi

mkdir -p "$APPCAST_DIR"
APPCAST_PATH="$APPCAST_DIR/$APPCAST_NAME"
APPCAST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-swift-appcast-output.XXXXXX")"
APPCAST_TMP="$APPCAST_TMP_DIR/$APPCAST_NAME"
artifact_destination="$APPCAST_DIR/$(basename "$UPDATE_ARTIFACT")"
ARTIFACT_DESTINATION="$artifact_destination"
if [[ "$UPDATE_ARTIFACT" != "$artifact_destination" ]]; then
  ARTIFACT_TMP="$artifact_destination.tmp.$$"
  if [[ -e "$artifact_destination" ]]; then
    ARTIFACT_BACKUP="$artifact_destination.backup.$$"
    /bin/cp -p "$artifact_destination" "$ARTIFACT_BACKUP"
  fi
  /bin/cp -p "$UPDATE_ARTIFACT" "$ARTIFACT_TMP"
  /bin/mv -f "$ARTIFACT_TMP" "$artifact_destination"
  ARTIFACT_REPLACED=1
fi
if [[ -f "$APPCAST_PATH" ]]; then
  APPCAST_BACKUP="$APPCAST_PATH.backup.$$"
  /bin/cp -p "$APPCAST_PATH" "$APPCAST_BACKUP"
fi

args=(--account "$ACCOUNT")
args+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
if [[ -n "$RELEASE_NOTES_URL_PREFIX" ]]; then
  args+=(--release-notes-url-prefix "$RELEASE_NOTES_URL_PREFIX")
fi
if [[ -n "$PRIVATE_ED_KEY_FILE" ]]; then
  args+=(--ed-key-file "$PRIVATE_ED_KEY_FILE")
elif [[ -n "$PRIVATE_ED_KEY" ]]; then
  args+=(--ed-key-file -)
fi
args+=(-o "$APPCAST_TMP" "$APPCAST_DIR")

if [[ -n "$PRIVATE_ED_KEY" ]]; then
  printf '%s' "$PRIVATE_ED_KEY" | "$GENERATE_APPCAST" "${args[@]}"
else
  "$GENERATE_APPCAST" "${args[@]}"
fi

if [[ ! -f "$APPCAST_TMP" ]]; then
  echo "error: appcast was not generated: $APPCAST_TMP" >&2
  exit 2
fi

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$APPCAST_TMP"
fi
if ! /usr/bin/grep -Eq 'sparkle:edSignature="[^"]+"' "$APPCAST_TMP"; then
  echo "error: generated appcast has no EdDSA signature: $APPCAST_TMP" >&2
  exit 2
fi
/bin/mv -f "$APPCAST_TMP" "$APPCAST_PATH"
APPCAST_REPLACED=1
[[ -n "$APPCAST_BACKUP" ]] && /bin/unlink "$APPCAST_BACKUP"
APPCAST_BACKUP=""
[[ -n "$ARTIFACT_BACKUP" ]] && /bin/unlink "$ARTIFACT_BACKUP"
ARTIFACT_BACKUP=""

printf '%s\n' "$APPCAST_PATH"
