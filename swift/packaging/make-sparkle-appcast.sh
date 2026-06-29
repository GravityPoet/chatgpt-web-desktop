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

if [[ ! -f "$UPDATE_ARTIFACT" ]]; then
  echo "error: update artifact not found: $UPDATE_ARTIFACT" >&2
  exit 2
fi

if [[ -n "$PRIVATE_ED_KEY_FILE" && -n "$PRIVATE_ED_KEY" ]]; then
  echo "error: set only one of CHATGPT_SWIFT_SPARKLE_ED_KEY_FILE or CHATGPT_SWIFT_SPARKLE_ED_PRIVATE_KEY." >&2
  exit 2
fi

mkdir -p "$APPCAST_DIR"
artifact_destination="$APPCAST_DIR/$(basename "$UPDATE_ARTIFACT")"
if [[ "$UPDATE_ARTIFACT" != "$artifact_destination" ]]; then
  /bin/cp -p "$UPDATE_ARTIFACT" "$artifact_destination"
fi

args=(--account "$ACCOUNT")
if [[ -n "$DOWNLOAD_URL_PREFIX" ]]; then
  args+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
else
  echo "warning: CHATGPT_SWIFT_SPARKLE_DOWNLOAD_URL_PREFIX is empty; generated feed will not contain a public download prefix." >&2
fi
if [[ -n "$RELEASE_NOTES_URL_PREFIX" ]]; then
  args+=(--release-notes-url-prefix "$RELEASE_NOTES_URL_PREFIX")
fi
if [[ -n "$PRIVATE_ED_KEY_FILE" ]]; then
  args+=(--ed-key-file "$PRIVATE_ED_KEY_FILE")
elif [[ -n "$PRIVATE_ED_KEY" ]]; then
  args+=(--ed-key-file -)
fi
args+=(-o "$APPCAST_DIR/$APPCAST_NAME" "$APPCAST_DIR")

if [[ -n "$PRIVATE_ED_KEY" ]]; then
  printf '%s' "$PRIVATE_ED_KEY" | "$GENERATE_APPCAST" "${args[@]}"
else
  "$GENERATE_APPCAST" "${args[@]}"
fi

if [[ ! -f "$APPCAST_DIR/$APPCAST_NAME" ]]; then
  echo "error: appcast was not generated: $APPCAST_DIR/$APPCAST_NAME" >&2
  exit 2
fi

printf '%s\n' "$APPCAST_DIR/$APPCAST_NAME"
