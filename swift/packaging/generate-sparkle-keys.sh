#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT="${CHATGPT_SWIFT_SPARKLE_KEY_ACCOUNT:-chatgpt-swift}"
MODE="${1:-print-public-key}"

find_generate_keys() {
  local candidate
  for candidate in \
    "${CHATGPT_SWIFT_SPARKLE_TOOLS_DIR:-}/generate_keys" \
    "$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys" \
    "$ROOT/.build/checkouts/Sparkle/generate_keys"
  do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

cd "$ROOT"

GENERATE_KEYS="$(find_generate_keys || true)"
if [[ -z "$GENERATE_KEYS" ]]; then
  swift build -c release >/dev/null
  GENERATE_KEYS="$(find_generate_keys || true)"
fi

if [[ -z "$GENERATE_KEYS" ]]; then
  echo "error: Sparkle generate_keys tool not found. Run swift build first or set CHATGPT_SWIFT_SPARKLE_TOOLS_DIR." >&2
  exit 2
fi

case "$MODE" in
  create|print-public-key)
    "$GENERATE_KEYS" --account "$ACCOUNT"
    ;;
  public-key-only)
    "$GENERATE_KEYS" --account "$ACCOUNT" -p
    ;;
  *)
    cat >&2 <<EOF
usage: $0 [create|print-public-key|public-key-only]

Environment:
  CHATGPT_SWIFT_SPARKLE_KEY_ACCOUNT   Keychain account name. Default: chatgpt-swift
  CHATGPT_SWIFT_SPARKLE_TOOLS_DIR     Directory containing Sparkle generate_keys.

This script prints the public EdDSA key for Info.plist. The private key remains
in your macOS Keychain unless you explicitly export it with Sparkle tooling.
EOF
    exit 2
    ;;
esac
