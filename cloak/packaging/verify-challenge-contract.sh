#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

BIN="${CLOAK_BROWSER_BIN:-$HOME/.cloakbrowser/current/Chromium.app/Contents/MacOS/Chromium}"
RUNTIME_SHA_FILE="$HOME/.cloakbrowser/current.sha256"
DEFAULT_SHA_FILE="$ROOT/packaging/cloakbrowser-current.sha256"
SHA_FILE="${CLOAK_BROWSER_SHA_FILE:-}"
if [[ -z "$SHA_FILE" && -f "$RUNTIME_SHA_FILE" ]]; then
  SHA_FILE="$RUNTIME_SHA_FILE"
fi
if [[ -z "$SHA_FILE" ]]; then
  SHA_FILE="$DEFAULT_SHA_FILE"
fi
ACCOUNT_NAME="${CLOAK_VERIFY_ACCOUNT:-challenge-smoke-9i@example.test}"

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

require_executable "$BIN"

if [[ -n "${CLOAK_BROWSER_EXPECTED_SHA256:-}" ]]; then
  expected_hash="$(printf '%s' "$CLOAK_BROWSER_EXPECTED_SHA256" | tr '[:upper:]' '[:lower:]')"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || fail "CLOAK_BROWSER_EXPECTED_SHA256 must be a 64-character SHA256"
else
  require_file "$SHA_FILE"
  expected_hash="$(awk 'NR == 1 { print $1 }' "$SHA_FILE" | tr '[:upper:]' '[:lower:]')"
fi
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
assert(argv.some((arg) => arg.startsWith("--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")), "missing coherent macOS --user-agent");
assert(argv.some((arg) => arg.startsWith("--load-extension=")), "missing --load-extension");
assert(argv.some((arg) => arg.startsWith("--disable-extensions-except=")), "missing --disable-extensions-except");
assert(argv.includes("--ignore-gpu-blocklist"), "missing --ignore-gpu-blocklist");
assert(argv.includes("--disable-blink-features=AutomationControlled"), "missing AutomationControlled blink feature guard");
assert(argv.some((arg) => arg.startsWith("--fingerprint-timezone=")), "missing --fingerprint-timezone");
assert(argv.some((arg) => arg.startsWith("--lang=")), "missing --lang");
assert(argv.some((arg) => arg.startsWith("--fingerprint-locale=")), "missing --fingerprint-locale");
assert(argv.some((arg) => arg.startsWith("--accept-lang=")), "missing --accept-lang");
assert(argv.some((arg) => arg.startsWith("--fingerprint-webrtc-ip=")), "missing --fingerprint-webrtc-ip");
assert(argv.some((arg) => arg.startsWith("--fingerprint-brand-version=")), "missing --fingerprint-brand-version");
assert(argv.some((arg) => arg.startsWith("--fingerprint-platform-version=")), "missing --fingerprint-platform-version");
assert(argv.some((arg) => arg.startsWith("--fingerprint-gpu-vendor=")), "missing --fingerprint-gpu-vendor");
assert(argv.some((arg) => arg.startsWith("--fingerprint-gpu-renderer=")), "missing --fingerprint-gpu-renderer");
assert(plan.browser_identity?.userAgent?.includes("Mac OS X 10_15_7"), "browser identity missing coherent UA");
assert(plan.browser_identity?.uaData?.platform === "macOS", "browser identity missing low-entropy UA-CH platform");
assert(plan.browser_identity?.uaData?.platformVersion === "15.5.0", "browser identity missing platformVersion");
assert(plan.browser_identity?.uaData?.architecture === "arm", "browser identity missing architecture");
assert(plan.browser_identity?.uaData?.bitness === "64", "browser identity missing bitness");
assert(Array.isArray(plan.browser_identity?.uaData?.fullVersionList), "browser identity missing fullVersionList");
assert(typeof plan.browser_identity?.uaData?.uaFullVersion === "string", "browser identity missing uaFullVersion");
// Version consistency: UA major must match fullVersionList major
const uaMajor = plan.browser_identity?.userAgent?.match(/Chrome\/(\d+)/)?.[1];
const fvlMajor = plan.browser_identity?.uaData?.fullVersionList?.[0]?.version?.split(".")?.[0];
assert(uaMajor === fvlMajor, `UA major (${uaMajor}) != fullVersionList major (${fvlMajor})`);
assert(!joined.includes("沉浸式翻译"), "immersive translate must not be default-loaded");
assert((plan.selftest_extension_paths || []).every((path) => !path.includes("Chromium Web Store")), "headless selftest must exclude Chromium Web Store extension");
assert((plan.selftest_extension_paths || []).every((path) => !path.includes("沉浸式翻译")), "headless selftest must exclude immersive translate");
NODE

LC_ALL=C grep -aq -- "--disable-extensions-except=" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --disable-extensions-except"
LC_ALL=C grep -aq -- "--user-agent=Mozilla/5.0" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --user-agent"
LC_ALL=C grep -aq -- "10_15_7" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing coherent macOS UA version"
LC_ALL=C grep -aq -- "--ignore-gpu-blocklist" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --ignore-gpu-blocklist"
LC_ALL=C grep -aq -- "--disable-blink-features=AutomationControlled" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing AutomationControlled blink feature guard"
LC_ALL=C grep -aq -- "--fingerprint-timezone=" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --fingerprint-timezone"
LC_ALL=C grep -aq -- "--fingerprint-webrtc-ip=" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --fingerprint-webrtc-ip"
LC_ALL=C grep -aq -- "--fingerprint-brand-version=" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --fingerprint-brand-version"
LC_ALL=C grep -aq -- "--fingerprint-platform-version=" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --fingerprint-platform-version"
LC_ALL=C grep -aq -- "--fingerprint-gpu-vendor=" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --fingerprint-gpu-vendor"
LC_ALL=C grep -aq -- "--fingerprint-gpu-renderer=" "$tmpdir/bash-dry-run.txt" || fail "Bash dry-run missing --fingerprint-gpu-renderer"
if LC_ALL=C grep -aq "沉浸式翻译" "$tmpdir/bash-dry-run.txt"; then
  fail "Bash dry-run default-loaded immersive translate"
fi

node "$ROOT/selftest/run-selftest.mjs" --pair --headless --quiet --no-result-file

printf 'PASS: CloakBrowser challenge contract holds for %s\n' "$ACCOUNT_NAME"
