#!/bin/bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ChatGPTSwiftWeb"
BUNDLE_ID="local.chatgpt-web.swift"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/ChatGPT Swift.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cd "$ROOT_DIR"

stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
  ./packaging/make-app.sh
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    stop_app
    build_app
    open_app
    ;;
  --debug|debug)
    stop_app
    build_app
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    stop_app
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stop_app
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    stop_app
    build_app
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
