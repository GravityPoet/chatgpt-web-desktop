#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

BIN="${CLOAK_BROWSER_BIN:-$HOME/.cloakbrowser/current/Chromium.app/Contents/MacOS/Chromium}"
SHA_FILE="${CLOAK_BROWSER_SHA_FILE:-$ROOT/packaging/cloakbrowser-current.sha256}"
ACCOUNT_NAME="${CLOAK_VERIFY_ACCOUNT:-challenge-smoke-9i@icloud.com}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

require_executable() {
  [[ -x "$1" ]] || fail "not executable: $1"
}

require_file "$SHA_FILE"
require_executable "$BIN"

expected_hash="$(awk 'NR == 1 { print $1 }' "$SHA_FILE")"
current_hash="$(shasum -a 256 "$BIN" | awk '{ print $1 }')"
[[ "$current_hash" == "$expected_hash" ]] || fail "CloakBrowser hash changed: got $current_hash expected $expected_hash"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cloak-contract.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

export CLOAK_ACCOUNT_BASE="$tmpdir/accounts"
mkdir -p "$CLOAK_ACCOUNT_BASE"

cargo build -p cloak-cli >/dev/null

"$ROOT/target/debug/cloak" account create "$ACCOUNT_NAME" --json >/dev/null

LOCALE=1 "$ROOT/target/debug/cloak" launch "$ACCOUNT_NAME" --dry-run --json > "$tmpdir/rust-plan.json"
LOCALE=1 DRY_RUN=1 "$ROOT/packaging/launch-account.sh" "$ACCOUNT_NAME" > "$tmpdir/bash-dry-run.txt"

node - "$tmpdir/rust-plan.json" <<'NODE'
const fs = require("fs");
const plan = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const argv = plan.argv || [];
const joined = argv.join("\n");
function assert(condition, message) {
  if (!condition) {
    console.error(`FAIL: ${message}`);
    process.exit(1);
  }
}
assert(argv.some((arg) => arg.startsWith("--user-data-dir=")), "missing --user-data-dir");
assert(argv.some((arg) => arg.startsWith("--fingerprint=")), "missing --fingerprint");
assert(argv.includes("--fingerprint-platform=macos"), "missing --fingerprint-platform=macos");
assert(argv.some((arg) => arg.startsWith("--load-extension=")), "missing --load-extension");
assert(argv.some((arg) => arg.startsWith("--disable-extensions-except=")), "missing --disable-extensions-except");
assert(argv.some((arg) => arg.startsWith("--fingerprint-timezone=")), "missing --fingerprint-timezone");
assert(argv.some((arg) => arg.startsWith("--lang=")), "missing --lang");
assert(argv.some((arg) => arg.startsWith("--fingerprint-locale=")), "missing --fingerprint-locale");
assert(argv.some((arg) => arg.startsWith("--accept-lang=")), "missing --accept-lang");
assert(argv.some((arg) => arg.startsWith("--fingerprint-webrtc-ip=")), "missing --fingerprint-webrtc-ip");
assert(!joined.includes("沉浸式翻译"), "immersive translate must not be default-loaded");
assert((plan.selftest_extension_paths || []).every((path) => !path.includes("Chromium Web Store")), "headless selftest must exclude Chromium Web Store extension");
assert((plan.selftest_extension_paths || []).every((path) => !path.includes("沉浸式翻译")), "headless selftest must exclude immersive translate");
NODE

LC_ALL=C grep -aq -- "--disable-extensions-except=" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --disable-extensions-except"
LC_ALL=C grep -aq -- "--fingerprint-timezone=" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --fingerprint-timezone"
LC_ALL=C grep -aq -- "--fingerprint-webrtc-ip=" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --fingerprint-webrtc-ip"
if LC_ALL=C grep -aq "沉浸式翻译" "$tmpdir/bash-dry-run.txt"; then
  fail "Bash dry-run default-loaded immersive translate"
fi

node "$ROOT/selftest/run-selftest.mjs" --pair --headless --quiet --no-result-file

printf 'PASS: CloakBrowser challenge contract holds for %s\n' "$ACCOUNT_NAME"
