#!/bin/bash
set -euo pipefail

DEVELOPER_ID_SECRET_NAMES=(
  CHATGPT_SWIFT_CERTIFICATE_P12_BASE64
  CHATGPT_SWIFT_CERTIFICATE_PASSWORD
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_SPECIFIC_PASSWORD
)
SPARKLE_SECRET_NAMES=(
  CHATGPT_SWIFT_SPARKLE_PUBLIC_ED_KEY
  CHATGPT_SWIFT_SPARKLE_ED_PRIVATE_KEY
)

usage() {
  cat >&2 <<EOF
usage:
  $0 --env [--distribution github|developer-id] [--sparkle on|off]
  $0 --github-secrets <owner/repo> [--distribution github|developer-id] [--sparkle on|off]

Modes:
  --env                 Validate release environment variables without printing values.
  --github-secrets      Validate that required GitHub Actions secret names exist.

Defaults:
  --distribution github  GitHub-only DMG distribution with local self-signing.
  --sparkle off          Manual GitHub Release updates; no Sparkle appcast required.
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

  if [[ "$DISTRIBUTION" == "developer-id" ]]; then
    for name in "${DEVELOPER_ID_SECRET_NAMES[@]}"; do
      if [[ -z "${!name:-}" ]]; then
        echo "error: missing required environment variable: $name" >&2
        missing=1
      fi
    done
  fi

  if [[ "$SPARKLE" == "on" ]]; then
    for name in "${SPARKLE_SECRET_NAMES[@]}"; do
      if [[ -z "${!name:-}" ]]; then
        echo "error: missing required environment variable: $name" >&2
        missing=1
      fi
    done
    if ! validate_feed_url; then
      missing=1
    fi
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
  local required_names=()

  if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh CLI is required for --github-secrets." >&2
    return 2
  fi

  secret_list="$(gh secret list --repo "$repo" --json name --jq '.[].name')"
  if [[ "$DISTRIBUTION" == "developer-id" ]]; then
    required_names+=("${DEVELOPER_ID_SECRET_NAMES[@]}")
  fi
  if [[ "$SPARKLE" == "on" ]]; then
    required_names+=("${SPARKLE_SECRET_NAMES[@]}")
  fi

  if [[ "${#required_names[@]}" == "0" ]]; then
    echo "GitHub release secrets look ready for $repo"
    return 0
  fi

  for name in "${required_names[@]}"; do
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

DISTRIBUTION="github"
SPARKLE="off"
MODE=""
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      MODE="env"
      shift
      ;;
    --github-secrets)
      MODE="github-secrets"
      REPO="${2:-}"
      shift 2
      ;;
    --distribution)
      DISTRIBUTION="${2:-}"
      shift 2
      ;;
    --sparkle)
      SPARKLE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$DISTRIBUTION" in
  github|developer-id) ;;
  *)
    echo "error: --distribution must be github or developer-id." >&2
    exit 2
    ;;
esac

case "$SPARKLE" in
  on|off) ;;
  *)
    echo "error: --sparkle must be on or off." >&2
    exit 2
    ;;
esac

case "$MODE" in
  env)
    validate_env
    ;;
  github-secrets)
    if [[ -z "$REPO" ]]; then
      usage
      exit 2
    fi
    validate_github_secrets "$REPO"
    ;;
  *)
    usage
    exit 2
    ;;
esac
