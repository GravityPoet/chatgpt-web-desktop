#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${CHATGPT_SWIFT_GITHUB_REPO:-}"
CERTIFICATE_P12_PATH="${CHATGPT_SWIFT_CERTIFICATE_P12_PATH:-}"
CERTIFICATE_P12_BASE64="${CHATGPT_SWIFT_CERTIFICATE_P12_BASE64:-}"
CERTIFICATE_PASSWORD="${CHATGPT_SWIFT_CERTIFICATE_PASSWORD:-}"
SPARKLE_PUBLIC_ED_KEY="${CHATGPT_SWIFT_SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_ED_PRIVATE_KEY="${CHATGPT_SWIFT_SPARKLE_ED_PRIVATE_KEY:-}"
APPLE_ID_VALUE="${APPLE_ID:-}"
APPLE_TEAM_ID_VALUE="${APPLE_TEAM_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD_VALUE="${APPLE_APP_SPECIFIC_PASSWORD:-}"
DRY_RUN=0

usage() {
  cat >&2 <<EOF
usage: $0 --repo <owner/repo> --certificate-p12 <file.p12> [options]

Options may be provided as flags or environment variables:
  --repo <owner/repo>                         CHATGPT_SWIFT_GITHUB_REPO
  --certificate-p12 <file.p12>                CHATGPT_SWIFT_CERTIFICATE_P12_PATH
  --certificate-password <password>           CHATGPT_SWIFT_CERTIFICATE_PASSWORD
  --sparkle-public-ed-key <public-key>        CHATGPT_SWIFT_SPARKLE_PUBLIC_ED_KEY
  --sparkle-private-ed-key <private-key>      CHATGPT_SWIFT_SPARKLE_ED_PRIVATE_KEY
  --apple-id <apple-id>                       APPLE_ID
  --apple-team-id <team-id>                   APPLE_TEAM_ID
  --apple-app-specific-password <password>    APPLE_APP_SPECIFIC_PASSWORD
  --dry-run                                   Validate inputs without writing GitHub secrets.

The script stores these GitHub Actions secrets without printing secret values:
  CHATGPT_SWIFT_CERTIFICATE_P12_BASE64
  CHATGPT_SWIFT_CERTIFICATE_PASSWORD
  CHATGPT_SWIFT_SPARKLE_PUBLIC_ED_KEY
  CHATGPT_SWIFT_SPARKLE_ED_PRIVATE_KEY
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_SPECIFIC_PASSWORD
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --certificate-p12)
      CERTIFICATE_P12_PATH="${2:-}"
      shift 2
      ;;
    --certificate-password)
      CERTIFICATE_PASSWORD="${2:-}"
      shift 2
      ;;
    --sparkle-public-ed-key)
      SPARKLE_PUBLIC_ED_KEY="${2:-}"
      shift 2
      ;;
    --sparkle-private-ed-key)
      SPARKLE_ED_PRIVATE_KEY="${2:-}"
      shift 2
      ;;
    --apple-id)
      APPLE_ID_VALUE="${2:-}"
      shift 2
      ;;
    --apple-team-id)
      APPLE_TEAM_ID_VALUE="${2:-}"
      shift 2
      ;;
    --apple-app-specific-password)
      APPLE_APP_SPECIFIC_PASSWORD_VALUE="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

error_count=0

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "error: missing required value: $name" >&2
    error_count=1
  fi
}

require_value "--repo / CHATGPT_SWIFT_GITHUB_REPO" "$REPO"
require_value "--certificate-password / CHATGPT_SWIFT_CERTIFICATE_PASSWORD" "$CERTIFICATE_PASSWORD"
require_value "--sparkle-public-ed-key / CHATGPT_SWIFT_SPARKLE_PUBLIC_ED_KEY" "$SPARKLE_PUBLIC_ED_KEY"
require_value "--sparkle-private-ed-key / CHATGPT_SWIFT_SPARKLE_ED_PRIVATE_KEY" "$SPARKLE_ED_PRIVATE_KEY"
require_value "--apple-id / APPLE_ID" "$APPLE_ID_VALUE"
require_value "--apple-team-id / APPLE_TEAM_ID" "$APPLE_TEAM_ID_VALUE"
require_value "--apple-app-specific-password / APPLE_APP_SPECIFIC_PASSWORD" "$APPLE_APP_SPECIFIC_PASSWORD_VALUE"

if [[ -z "$CERTIFICATE_P12_BASE64" ]]; then
  if [[ -z "$CERTIFICATE_P12_PATH" ]]; then
    echo "error: missing required value: --certificate-p12 / CHATGPT_SWIFT_CERTIFICATE_P12_PATH" >&2
    error_count=1
  elif [[ ! -f "$CERTIFICATE_P12_PATH" ]]; then
    echo "error: certificate file does not exist: $CERTIFICATE_P12_PATH" >&2
    error_count=1
  else
    CERTIFICATE_P12_BASE64="$(/usr/bin/base64 <"$CERTIFICATE_P12_PATH" | /usr/bin/tr -d '\n')"
  fi
fi

if [[ "$error_count" != "0" ]]; then
  exit 2
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "release credential inputs look ready for $REPO"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI is required to write GitHub secrets." >&2
  exit 2
fi

set_secret() {
  local name="$1"
  local value="$2"
  gh secret set "$name" --repo "$REPO" --body "$value" >/dev/null
  echo "stored GitHub secret: $name"
}

set_secret CHATGPT_SWIFT_CERTIFICATE_P12_BASE64 "$CERTIFICATE_P12_BASE64"
set_secret CHATGPT_SWIFT_CERTIFICATE_PASSWORD "$CERTIFICATE_PASSWORD"
set_secret CHATGPT_SWIFT_SPARKLE_PUBLIC_ED_KEY "$SPARKLE_PUBLIC_ED_KEY"
set_secret CHATGPT_SWIFT_SPARKLE_ED_PRIVATE_KEY "$SPARKLE_ED_PRIVATE_KEY"
set_secret APPLE_ID "$APPLE_ID_VALUE"
set_secret APPLE_TEAM_ID "$APPLE_TEAM_ID_VALUE"
set_secret APPLE_APP_SPECIFIC_PASSWORD "$APPLE_APP_SPECIFIC_PASSWORD_VALUE"

"$ROOT/packaging/check-release-readiness.sh" --github-secrets "$REPO"
