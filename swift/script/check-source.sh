#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

require_command() {
  command_name="$1"
  install_hint="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required checker: $command_name" >&2
    echo "install with: $install_hint" >&2
    exit 2
  fi
}

require_command actionlint "brew install actionlint"
require_command shellcheck "brew install shellcheck"

cd "$REPO_ROOT"
actionlint

while IFS= read -r script_path; do
  bash -n "$script_path"
  shellcheck "$script_path"
done < <(find "$ROOT/script" "$ROOT/packaging" -type f -name '*.sh' -print | LC_ALL=C sort)

/usr/bin/plutil -lint "$ROOT/packaging/Info.plist" >/dev/null

echo "Swift source checks passed."
