#!/bin/bash
set -euo pipefail

REQUIRED_SECRET_NAMES=(
  CHATGPT_SWIFT_CERTIFICATE_P12_BASE64
  CHATGPT_SWIFT_CERTIFICATE_PASSWORD
  CHATGPT_SWIFT_SPARKLE_PUBLIC_ED_KEY
  CHATGPT_SWIFT_SPARKLE_ED_PRIVATE_KEY
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_SPECIFIC_PASSWORD
)

usage() {
  cat >&2 <<EOF
usage:
  $0 --env
  $0 --github-secrets <owner/repo>

Modes:
  --env                 Validate release environment variables without printing values.
  --github-secrets      Validate that required GitHub Actions secret names exist.
EOF
}

validate_feed_url() {
  local feed_url="${CHATGPT_SWIFT_SPARKLE_FEED_URL:-}"
  if [[ -z "$feed_url" ]]; then
    echo "error: missing required environment variable: CHATGPT_SWIFT_SPARKLE_FEED_URL" >&2
    return 1
  fi
  case "$feed_url" in
    https://*) ;;
    *)
      echo "error: CHATGPT_SWIFT_SPARKLE_FEED_URL must be an https:// URL." >&2
      return 1
      ;;
  esac
}

validate_env() {
  local missing=0
  local name

  for name in "${REQUIRED_SECRET_NAMES[@]}"; do
    if [[ -z "${!name:-}" ]]; then
      echo "error: missing required environment variable: $name" >&2
      missing=1
    fi
  done

  if ! validate_feed_url; then
    missing=1
  fi

  if [[ "$missing" != "0" ]]; then
    return 2
  fi

  echo "release environment looks ready"
}

validate_github_secrets() {
  local repo="$1"
  local missing=0
  local name
  local secret_list

  if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh CLI is required for --github-secrets." >&2
    return 2
  fi

  secret_list="$(gh secret list --repo "$repo" --json name --jq '.[].name')"
  for name in "${REQUIRED_SECRET_NAMES[@]}"; do
    if ! printf '%s\n' "$secret_list" | /usr/bin/grep -qx "$name"; then
      echo "missing GitHub secret: $name" >&2
      missing=1
    fi
  done

  if [[ "$missing" != "0" ]]; then
    return 2
  fi

  echo "GitHub release secrets look ready for $repo"
}

case "${1:-}" in
  --env)
    validate_env
    ;;
  --github-secrets)
    if [[ -z "${2:-}" ]]; then
      usage
      exit 2
    fi
    validate_github_secrets "$2"
    ;;
  *)
    usage
    exit 2
    ;;
esac
