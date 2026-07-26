#!/bin/bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ChatGPTSwiftWeb"
BUNDLE_ID="local.chatgpt-web.swift"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/ChatGPT Swift.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SMOKE_REPORT=""

cd "$ROOT_DIR"

stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

unregister_app_bundle() {
  app_bundle="$1"
  if [[ -d "$app_bundle/Contents" ]]; then
    while IFS= read -r -d '' nested_app; do
      "$LSREGISTER" -u "$nested_app" >/dev/null 2>&1 || true
    done < <(find "$app_bundle/Contents" -type d -name '*.app' -prune -print0 2>/dev/null)
  fi
  "$LSREGISTER" -u "$app_bundle" >/dev/null 2>&1 || true
}

build_app() {
  CHATGPT_SWIFT_KEEP_TRANSIENT_APP=1 ./packaging/make-app.sh
}

cleanup_transient_app() {
  status=$?
  trap - EXIT INT TERM
  stop_app
  unregister_app_bundle "$APP_BUNDLE"
  rm -rf "$APP_BUNDLE"
  rm -f "$ROOT_DIR/dist/.metadata_never_index"
  if [[ -n "$SMOKE_REPORT" ]]; then
    rm -f "$SMOKE_REPORT"
  fi
  exit "$status"
}

prepare_transient_app() {
  build_app
  trap cleanup_transient_app EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    stop_app
    ./packaging/install-local-app.sh
    ;;
  --debug|debug)
    stop_app
    prepare_transient_app
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    stop_app
    prepare_transient_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stop_app
    prepare_transient_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    prepare_transient_app
    report_file="$(mktemp "${TMPDIR:-/tmp}/chatgpt-swift-smoke.XXXXXX")"
    rm -f "$report_file"
    SMOKE_REPORT="$report_file"
    smoke_timeout="${CHATGPT_SWIFT_SMOKE_TIMEOUT_SECONDS:-25}"
    if ! [[ "$smoke_timeout" =~ ^[0-9]+$ ]]; then
      echo "invalid CHATGPT_SWIFT_SMOKE_TIMEOUT_SECONDS: $smoke_timeout" >&2
      exit 2
    fi
    if [[ "$smoke_timeout" -lt 5 ]]; then
      smoke_timeout=5
    elif [[ "$smoke_timeout" -gt 120 ]]; then
      smoke_timeout=120
    fi
    CHATGPT_SWIFT_SMOKE_REPORT_PATH="$report_file" \
      CHATGPT_SWIFT_SMOKE_TIMEOUT_SECONDS="$smoke_timeout" \
      "$APP_BINARY" &
    app_pid="$!"
    deadline=$((smoke_timeout + 10))
    elapsed=0
    while [[ "$elapsed" -lt "$deadline" ]]; do
      if [[ -f "$report_file" ]]; then
        break
      fi
      if ! kill -0 "$app_pid" >/dev/null 2>&1; then
        break
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    if [[ ! -f "$report_file" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
      kill "$app_pid" >/dev/null 2>&1 || true
    fi
    shutdown_wait=0
    while kill -0 "$app_pid" >/dev/null 2>&1 && [[ "$shutdown_wait" -lt 5 ]]; do
      sleep 1
      shutdown_wait=$((shutdown_wait + 1))
    done
    if kill -0 "$app_pid" >/dev/null 2>&1; then
      kill -KILL "$app_pid" >/dev/null 2>&1 || true
    fi
    wait "$app_pid" >/dev/null 2>&1 || true
    if [[ ! -f "$report_file" ]]; then
      echo "smoke test failed: app exited without writing report" >&2
      exit 1
    fi
    cat "$report_file"
    if ! /usr/bin/grep -qx "SMOKE_STATUS=pass" "$report_file"; then
      echo "smoke test failed" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
