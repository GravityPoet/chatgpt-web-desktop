#!/bin/bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Read-only guard: no backup needed. This script only scans Git content.
LOCAL_HOME_RAW="${PRIVACY_LOCAL_HOME:-$HOME}"
LOCAL_HOME="$(printf '%s' "$LOCAL_HOME_RAW" | sed 's/[][\\.^$*+?{}|()]/\\&/g')"
SOCKET_KEY='"socket''Path"[[:space:]]*:'
PATTERN="(@gmail\\.com|@icloud\\.com|${LOCAL_HOME}|\\.codegraph/daemon\\.(pid|sock)|${SOCKET_KEY})"
ZERO_SHA="0000000000000000000000000000000000000000"

run_git_grep() {
  local rev="$1"
  if [[ -n "$rev" ]]; then
    git grep -I -n -E "$PATTERN" "$rev" -- \
      . \
      ':(exclude)cloak/target' \
      ':(exclude)cloak/cloak-picker/node_modules' \
      ':(exclude)tauri/node_modules' \
      ':(exclude)swift/.build' \
      ':(exclude).git' || true
  else
    git grep -I -n -E "$PATTERN" -- \
      . \
      ':(exclude)cloak/target' \
      ':(exclude)cloak/cloak-picker/node_modules' \
      ':(exclude)tauri/node_modules' \
      ':(exclude)swift/.build' \
      ':(exclude).git' || true
  fi
}

fail_with_matches() {
  local scope="$1"
  local matches="$2"
  if [[ -n "$matches" ]]; then
    printf 'privacy check failed in %s:\n%s\n' "$scope" "$matches" >&2
    printf '%s\n' 'Refusing to continue. Remove or replace private emails, local user paths, or runtime metadata before committing/pushing.' >&2
    exit 1
  fi
}

scan_worktree() {
  local matches
  matches="$(run_git_grep "")"
  fail_with_matches "worktree" "$matches"
}

scan_commit() {
  local commit="$1"
  local matches
  matches="$(run_git_grep "$commit")"
  fail_with_matches "commit $commit" "$matches"
}

scan_range() {
  local remote_sha="$1"
  local local_sha="$2"
  local commit

  if [[ "$local_sha" == "$ZERO_SHA" ]]; then
    return 0
  fi

  if [[ "$remote_sha" == "$ZERO_SHA" ]]; then
    scan_commit "$local_sha"
    return 0
  fi

  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    scan_commit "$commit"
  done < <(git rev-list "$remote_sha..$local_sha")
}

scan_pre_push() {
  local local_ref local_sha remote_ref remote_sha
  while read -r local_ref local_sha remote_ref remote_sha; do
    scan_range "$remote_sha" "$local_sha"
  done
}

case "${1:-}" in
  --pre-push)
    scan_pre_push
    ;;
  *)
    scan_worktree
    ;;
esac

printf '%s\n' "privacy check: ok"
