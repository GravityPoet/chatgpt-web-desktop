#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is only supported on macOS." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ChatGPT Swift"
BUNDLE_ID="local.chatgpt-web.swift"
BINARY_NAME="ChatGPTSwiftWeb"
APP_DIR="$ROOT/dist/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
PROCESS_PATTERN='^/Applications/ChatGPT Swift\.app/Contents/MacOS/ChatGPTSwiftWeb( |$)'
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/Library/Application Support/Codex/Backups/ChatGPTSwift/$STAMP"
BACKUP_ZIP="$BACKUP_DIR/$APP_NAME.app.zip"
STAGE_APP="/Applications/.ChatGPT-Swift-stage-$$"
DISPLACED_APP="/Applications/.ChatGPT-Swift-displaced-$$"
VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-swift-install-verify.XXXXXX")"
SPARKLE_GENERATE_APPCAST_CACHE="$HOME/Library/Caches/Sparkle_generate_appcast"
HAD_PREVIOUS=0
DISPLACED_READY=0
INSTALL_REPLACED=0

unregister_app_bundle() {
  app_bundle="$1"
  if [[ -d "$app_bundle/Contents" ]]; then
    while IFS= read -r -d '' nested_app; do
      "$LSREGISTER" -u "$nested_app" >/dev/null 2>&1 || true
    done < <(find "$app_bundle/Contents" -type d -name '*.app' -prune -print0 2>/dev/null)
  fi
  "$LSREGISTER" -u "$app_bundle" >/dev/null 2>&1 || true
}

remove_cached_product_apps() {
  [[ -d "$SPARKLE_GENERATE_APPCAST_CACHE" ]] || return 0
  while IFS= read -r -d '' cached_app; do
    cached_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$cached_app/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$cached_id" == "$BUNDLE_ID" ]] || continue
    running_copy="$(
      ps ax -o command= | while IFS= read -r command; do
        expected_command="$cached_app/Contents/MacOS/$BINARY_NAME"
        if [[ "$command" == "$expected_command" || "${command#"$expected_command "}" != "$command" ]]; then
          printf '%s\n' "$command"
        fi
      done
    )"
    if [[ -n "$running_copy" ]]; then
      echo "Refusing to remove a running cached product app: $cached_app" >&2
      exit 1
    fi
    unregister_app_bundle "$cached_app"
    rm -rf "$cached_app"
  done < <(find "$SPARKLE_GENERATE_APPCAST_CACHE" -type d -name "$APP_NAME.app" -prune -print0 2>/dev/null)
}

stop_canonical_process() {
  /usr/bin/osascript -e 'tell application id "local.chatgpt-web.swift" to quit' >/dev/null 2>&1 || true
  for _ in {1..5}; do
    if ! /usr/bin/pgrep -f "$PROCESS_PATTERN" >/dev/null; then
      return 0
    fi
    /bin/sleep 1
  done
  /usr/bin/pkill -TERM -f "$PROCESS_PATTERN" >/dev/null 2>&1 || true
  /bin/sleep 1
  /usr/bin/pkill -KILL -f "$PROCESS_PATTERN" >/dev/null 2>&1 || true
}

cleanup_or_rollback() {
  status=$?
  trap - EXIT INT TERM
  unregister_app_bundle "$APP_DIR"
  rm -rf "$APP_DIR" "$STAGE_APP" "$VERIFY_ROOT"
  rm -f "$ROOT/dist/.metadata_never_index"
  if [[ "$status" -ne 0 ]]; then
    if [[ "$INSTALL_REPLACED" -eq 1 ]]; then
      stop_canonical_process
      unregister_app_bundle "$INSTALL_APP"
      rm -rf "$INSTALL_APP"
    fi
    if [[ "$DISPLACED_READY" -eq 1 && -d "$DISPLACED_APP" && ! -e "$INSTALL_APP" ]]; then
      mv "$DISPLACED_APP" "$INSTALL_APP"
      "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
      /usr/bin/open "$INSTALL_APP" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup_or_rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

: > "$VERIFY_ROOT/.metadata_never_index"
remove_cached_product_apps
CHATGPT_SWIFT_KEEP_TRANSIENT_APP=1 "$ROOT/packaging/make-app.sh" >/dev/null
"$ROOT/packaging/verify-app-bundle.sh" "$APP_DIR" >/dev/null

rm -rf "$STAGE_APP" "$DISPLACED_APP"
/usr/bin/ditto --noextattr --noqtn "$APP_DIR" "$STAGE_APP"
/usr/bin/xattr -cr "$STAGE_APP"
"$ROOT/packaging/verify-app-bundle.sh" "$STAGE_APP" >/dev/null

if [[ -d "$INSTALL_APP" ]]; then
  HAD_PREVIOUS=1
  mkdir -p "$BACKUP_DIR"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$INSTALL_APP" "$BACKUP_ZIP"
  /usr/bin/unzip -tq "$BACKUP_ZIP" >/dev/null
  /usr/bin/ditto -x -k "$BACKUP_ZIP" "$VERIFY_ROOT"
  BACKUP_APP="$VERIFY_ROOT/$APP_NAME.app"
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$BACKUP_APP/Contents/Info.plist" 2>/dev/null || true)" == "$BUNDLE_ID" ]]
  /usr/bin/codesign --verify --deep --strict "$BACKUP_APP"
fi

/usr/bin/osascript -e 'tell application id "local.chatgpt-web.swift" to quit' >/dev/null 2>&1 || true
for _ in {1..5}; do
  if ! /usr/bin/pgrep -f "$PROCESS_PATTERN" >/dev/null; then
    break
  fi
  /bin/sleep 1
done
if /usr/bin/pgrep -f "$PROCESS_PATTERN" >/dev/null; then
  /usr/bin/pkill -TERM -f "$PROCESS_PATTERN"
  /bin/sleep 1
fi
if /usr/bin/pgrep -f "$PROCESS_PATTERN" >/dev/null; then
  echo "ChatGPT Swift did not stop cleanly." >&2
  exit 1
fi

if [[ "$HAD_PREVIOUS" -eq 1 ]]; then
  "$LSREGISTER" -u "$INSTALL_APP" >/dev/null 2>&1 || true
  mv "$INSTALL_APP" "$DISPLACED_APP"
  DISPLACED_READY=1
fi
mv "$STAGE_APP" "$INSTALL_APP"
INSTALL_REPLACED=1
"$ROOT/packaging/verify-app-bundle.sh" "$INSTALL_APP" >/dev/null
"$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
/usr/bin/mdimport "$INSTALL_APP" >/dev/null 2>&1 || true

/usr/bin/open "$INSTALL_APP"
for _ in {1..15}; do
  if /usr/bin/pgrep -f "$PROCESS_PATTERN" >/dev/null; then
    break
  fi
  /bin/sleep 1
done
if ! /usr/bin/pgrep -f "$PROCESS_PATTERN" >/dev/null; then
  echo "ChatGPT Swift did not launch from /Applications." >&2
  exit 1
fi

unregister_app_bundle "$APP_DIR"
rm -rf "$APP_DIR" "$VERIFY_ROOT"
rm -f "$ROOT/dist/.metadata_never_index"

physical_paths="$(
  for root in \
    /Applications \
    "$ROOT" \
    /private/tmp \
    "$SPARKLE_GENERATE_APPCAST_CACHE" \
    "$HOME/Library/Application Support/Codex/Backups/ChatGPTSwift"
  do
    [[ -d "$root" ]] || continue
    find "$root" -type d -name '*.app' -prune -print0 2>/dev/null
  done | while IFS= read -r -d '' app; do
    plist="$app/Contents/Info.plist"
    [[ -f "$plist" ]] || continue
    if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null || true)" == "$BUNDLE_ID" ]]; then
      printf '%s\n' "$app"
    fi
  done | sort -u
)"
if [[ "$physical_paths" != "$INSTALL_APP" ]]; then
  echo "ChatGPT Swift filesystem installation is not unique:" >&2
  printf '%s\n' "${physical_paths:-<none>}" >&2
  exit 1
fi

for _ in {1..20}; do
  spotlight_paths="$(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "local.chatgpt-web.swift"c' | sort -u)"
  [[ "$spotlight_paths" == "$INSTALL_APP" ]] && break
  /bin/sleep 1
done
if [[ "${spotlight_paths:-}" != "$INSTALL_APP" ]]; then
  echo "ChatGPT Swift Spotlight registration is not unique:" >&2
  printf '%s\n' "${spotlight_paths:-<none>}" >&2
  exit 1
fi

launchservices_paths="$(
  # Swift reads the bundle ID from the environment.
  # shellcheck disable=SC2016
  FINAL_APP_BUNDLE_ID="$BUNDLE_ID" /usr/bin/swift -e '
    import Foundation
    import CoreServices
    let identifier = ProcessInfo.processInfo.environment["FINAL_APP_BUNDLE_ID"]! as CFString
    let urls = (LSCopyApplicationURLsForBundleIdentifier(identifier, nil)?.takeRetainedValue() as? [URL]) ?? []
    for url in urls.sorted(by: { $0.path < $1.path }) { print(url.path) }
  '
)"
if [[ "$launchservices_paths" != "$INSTALL_APP" ]]; then
  echo "ChatGPT Swift LaunchServices registration is not unique:" >&2
  printf '%s\n' "${launchservices_paths:-<none>}" >&2
  exit 1
fi

dock_paths="$(
  # Swift reads the bundle ID from the environment.
  # shellcheck disable=SC2016
  FINAL_APP_BUNDLE_ID="$BUNDLE_ID" /usr/bin/swift -e '
    import Foundation
    let bundleID = ProcessInfo.processInfo.environment["FINAL_APP_BUNDLE_ID"]!
    let plistURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dictionary = root as? [String: Any],
          let apps = dictionary["persistent-apps"] as? [[String: Any]] else { exit(0) }
    for app in apps {
      guard let tile = app["tile-data"] as? [String: Any],
            tile["bundle-identifier"] as? String == bundleID,
            let file = tile["file-data"] as? [String: Any],
            let raw = file["_CFURLString"] as? String else { continue }
      if let url = URL(string: raw), url.isFileURL { print(url.path) } else { print(raw) }
    }
  ' | sort -u
)"
if [[ -n "$dock_paths" && "$dock_paths" != "$INSTALL_APP" ]]; then
  /usr/bin/killall Dock >/dev/null 2>&1 || true
  /bin/sleep 2
  dock_paths="$(
    # Swift reads the bundle ID from the environment.
    # shellcheck disable=SC2016
    FINAL_APP_BUNDLE_ID="$BUNDLE_ID" /usr/bin/swift -e '
      import Foundation
      let bundleID = ProcessInfo.processInfo.environment["FINAL_APP_BUNDLE_ID"]!
      let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
      guard let data = try? Data(contentsOf: plistURL),
            let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = root as? [String: Any],
            let apps = dictionary["persistent-apps"] as? [[String: Any]] else { exit(0) }
      for app in apps {
        guard let tile = app["tile-data"] as? [String: Any],
              tile["bundle-identifier"] as? String == bundleID,
              let file = tile["file-data"] as? [String: Any],
              let raw = file["_CFURLString"] as? String else { continue }
        if let url = URL(string: raw), url.isFileURL { print(url.path) } else { print(raw) }
      }
    ' | sort -u
  )"
fi
if [[ -n "$dock_paths" && "$dock_paths" != "$INSTALL_APP" ]]; then
  echo "ChatGPT Swift Dock entry points to a non-canonical path:" >&2
  printf '%s\n' "$dock_paths" >&2
  exit 1
fi

rm -rf "$DISPLACED_APP"
DISPLACED_READY=0
INSTALL_REPLACED=0
trap - EXIT INT TERM
printf 'INSTALLED_APP=%s\n' "$INSTALL_APP"
if [[ -f "$BACKUP_ZIP" ]]; then
  printf 'BACKUP_ZIP=%s\n' "$BACKUP_ZIP"
fi
