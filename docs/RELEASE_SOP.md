# ChatGPT Swift Release SOP

## Project

- Repository: `GravityPoet/chatgpt-web-desktop`
- GitHub remote: `git@github.com:GravityPoet/chatgpt-web-desktop.git`
- Release branch: `main`
- Package ecosystem: Swift Package Manager / macOS application

## Versioning

- Version source: `swift/packaging/Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`)
- Tag format: annotated `vMAJOR.MINOR.PATCH`
- Release type: stable GitHub Release unless the workflow input selects draft/prerelease
- Release notes: GitHub generated notes plus customer-facing bilingual verification when manually edited

## Preconditions

- Clean working tree except intentional release changes.
- `swift/packaging/check-release-readiness.sh --github-secrets GravityPoet/chatgpt-web-desktop` for GitHub/self-signed distribution.
- Local verification: `swift test --package-path swift --no-parallel -Xswiftc -strict-concurrency=complete`, source checks, universal app verification, DMG verification, and native smoke tests.
- GitHub Actions workflow: `.github/workflows/swift-macos-release.yml`, manually dispatched with the exact tag and `distribution=github` for local self-signing.
- Sparkle is disabled for local self-signed releases; Sparkle requires Developer ID distribution.

## Release commands

```bash
cd <repo-root>
git status --short --branch
swift/packaging/check-release-readiness.sh --github-secrets GravityPoet/chatgpt-web-desktop
git tag -a v<MAJOR.MINOR.PATCH> -m "ChatGPT Swift <MAJOR.MINOR.PATCH>"
git push origin main
git push origin v<MAJOR.MINOR.PATCH>
gh workflow run "Swift macOS Release" -f tag=v<MAJOR.MINOR.PATCH> -f distribution=github -f enable_sparkle=false -f draft=false -f prerelease=false
```

## Artifacts and verification

- CI artifact: `swift/dist/ChatGPT Swift.dmg`
- Local artifacts, when generated: `swift/dist/ChatGPT Swift.zip` and `swift/dist/ChatGPT Swift.dmg`
- Verify with `swift/packaging/verify-app-bundle.sh`, `hdiutil verify`, checksum generation, and `gh release view <tag>`.
- Verify `LSRequiresNativeExecution=true` and `LSArchitecturePriority=[arm64,x86_64]` so Apple silicon launches natively while Intel remains supported.
- Local self-signed `spctl` rejection is expected; codesign integrity and the local/GitHub entitlement allowlist remain required.

## Rollback and fuse conditions

- Before tag push: amend or revert the release commit and remove only the unpushed local tag.
- After tag push: do not rewrite the tag; create a corrective commit and a new patch tag. A published release is never overwritten.
- Stop if the target tag or release exists at a different commit, required credentials are unavailable, or any release gate fails.
- If a draft release exists at the exact commit, rerun the same tag only; do not replace a published release.

## Failure ledger

| Date | Version/Tag | Command | Error signature | Root cause | Fix | Prevention |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-25 | v0.1.2 | `git ls-remote origin` | `Could not resolve hostname ssh.github.com` | Current sandbox network/DNS could not reach the SSH remote | Rerun network-dependent GitHub operations with approved external execution and verify the remote SHA afterward | Treat sandbox DNS failure as an execution-environment issue; do not infer repository or tag state from the failed read |
| 2026-08-25 | v0.1.2 | `gh auth status` | `The token in default is invalid` | Local gh token is stale; SSH remote credentials may still be usable | Prefer authenticated repository remote or refresh gh auth before release API operations | Check both SSH push capability and gh API authentication before attempting a GitHub Release |
| 2026-08-25 | v0.1.2 | `swift test --no-parallel -Xswiftc -strict-concurrency=complete` | `error opening .../.cache/clang/ModuleCache ... Operation not permitted` | The restricted execution sandbox blocked Swift's user-level compiler cache | Rerun the same release gate with approved external execution and retain the successful output | Keep Swift build/test gates outside the restricted cache boundary when the environment denies user cache writes |
| 2026-08-25 | v0.1.2 | `git add docs/RELEASE_SOP.md` from `swift/` | `pathspec 'docs/RELEASE_SOP.md' did not match any files` | The checkout root is the parent of the Swift package directory | Use `git add ../docs/RELEASE_SOP.md` from `swift/`, or run Git commands from the repository root | Resolve `git rev-parse --show-toplevel` before composing release-relative paths |
| 2026-08-25 | v0.1.2 | `git push origin main` | `privacy check failed ... docs/RELEASE_SOP.md ... local user paths` | The SOP contained a machine-specific absolute checkout path | Replace it with the generic `<repo-root>` placeholder and amend before retrying | Never commit local filesystem paths, usernames, or runtime metadata in release documentation |
| 2026-08-25 | v0.1.2 | GitHub Actions Intel `swift build -c release --arch x86_64` | `compiler is unable to type-check this expression in reasonable time` at `BrowserWindowController.swift:294` | The large diagnostic tuple array relied on slow architecture-dependent type inference | Add an explicit `[(String, String)]` annotation, validate x86_64 locally, and publish the corrective patch as `v0.1.3` without moving `v0.1.2` | Require a real Intel release build before tagging; never retarget a pushed release tag |
| 2026-08-25 | v0.1.3 | GitHub Actions Intel Smoke after universal build | No output after `Build complete!`; job canceled at 21m10s while still in `make-app.sh` | CI local signing attempted to use the runner login Keychain and blocked after compilation | Use a runner-scoped temporary unlocked Keychain with a known partition-list password; clean it after Swift packaging; publish as `v0.1.4` without moving `v0.1.3` | Never depend on an interactive login Keychain for CI self-signing; probe the signing helper under `GITHUB_ACTIONS=true` before release |
| 2026-08-25 | v0.1.4 | CI Keychain probe shell wrapper | `zsh: read-only variable: status` | The zsh wrapper used the reserved `$status` variable name | Use `exit_code` for captured command status and rerun the probe | Avoid zsh special variable names in release diagnostics |
| 2026-08-25 | v0.1.4 | GitHub Actions Intel Smoke after universal build | No output after `Build complete!`; cancellation left an orphan `security` process | CI `security add-trusted-cert` can block on the runner even with a temporary keychain; system trust is not required for local CI codesigning | Skip trust-store mutation for CI keychains and publish as `v0.1.5` without moving `v0.1.4` | Keep CI self-signing limited to an isolated keychain/import/partition-list flow; never mutate interactive trust settings in headless runners |
| 2026-08-25 | v0.1.5 | CI self-signing helper probe | `failed to create local code signing identity` after skipping trust-store mutation | `security find-identity -p codesigning` requires a trusted certificate and is not a valid presence check for an intentionally self-signed CI certificate | Use `security find-certificate` for CI import verification, then prove the actual signed app with `verify-app-bundle.sh` and x86_64 Smoke | Separate certificate/key presence from Gatekeeper trust; require an artifact-level signing gate for self-signed CI releases |
| 2026-08-25 | v0.1.5 | Installed app launch review on macOS 27 ahead of macOS 28 | macOS reported that a bundled component may not open in the next major macOS | A universal app had no explicit native-execution launch policy, so Launch Services could select a translated Intel path on Apple silicon | Add `LSRequiresNativeExecution=true` with `LSArchitecturePriority=[arm64,x86_64]`, enforce both keys in the bundle verifier, and confirm the installed process is ARM64 | Treat native-launch metadata and a real installed-process architecture check as release gates for every universal build |
| 2026-08-25 | v0.1.6 | CI self-signing cleanup after local simulation | Later local signing failed with `ChatGPT Rust Local Code Signing: no identity found` because the previous CI keychain remained as the only search-list entry | Restore the saved user keychain search list before deleting the runner keychain in both success and failure cleanup paths | Restore the list atomically in `make-app.sh`, then rerun CI simulation and local installation as separate gates | Never leave a temporary CI keychain or a changed keychain search list behind after a packaging run |
| 2026-08-25 | v0.1.7 | GitHub Actions arm64 `Build signed DMG with Sparkle configuration` | `diskutil image create from`: `Unknown option '--volumeName'` on the Xcode 16.4 macOS 15 runner | `diskutil` exposes an incompatible option set across macOS releases even though its help command succeeds | Use the stable `hdiutil create -volname ... -srcfolder ... -format UDZO` path and verify/mount with `hdiutil` | Do not infer `diskutil` option compatibility from help availability; run a real DMG create/verify gate on the target runner |
| 2026-08-25 | v0.1.7 | GitHub Actions rerun after DMG fix | User reported no GitHub Actions quota; the in-progress run was canceled and did not publish an asset | Remote runner capacity was unavailable for this release window | Build, verify, checksum, and upload the DMG from the local macOS host using the same signed packaging scripts | Keep a documented local-release fallback that still requires DMG verification, checksum matching, and a downloaded-asset recheck |
| 2026-08-25 | v0.1.8 | `./script/check-source.sh` from the repository root | `zsh: no such file or directory: ./script/check-source.sh` | The source-check script is scoped to the `swift/` package, while the command was first run one directory above it | Reran from `swift/` and completed source and shell checks successfully | Resolve the package root before invoking platform-specific release scripts |
| 2026-08-25 | v0.1.8 | `./packaging/verify-app-bundle.sh "dist/ChatGPT Swift.app"` after `make-app.sh` | `error: incomplete app bundle: dist/ChatGPT Swift.app` | `make-app.sh` removes its transient `.app` after creating the ZIP unless `CHATGPT_SWIFT_KEEP_TRANSIENT_APP=1` is set | Used `make-dmg.sh`, which keeps the bundle through DMG verification, and verified the mounted DMG instead | Treat the `.app` lifecycle flag as part of the packaging command; verify the archive or mounted DMG when the default build cleans staging output |
| 2026-08-25 | v0.1.8 | `git add ...` in the restricted execution sandbox | `fatal: Unable to create .../.git/index.lock: Operation not permitted` | The sandbox denied writes to the Git index even though the working tree was writable | Reran the identical scoped staging/commit command with approved external execution; the privacy guard and commit completed | Run Git index/tag/push writes through an approved external execution path when the sandbox denies `.git` mutations |
| 2026-08-25 | v0.1.8 | `shasum -a 256 <absolute-path>/ChatGPT.Swift.dmg > ChatGPT.Swift.dmg.sha256` followed by public download verification | Downloaded checksum file referenced the build host's temporary absolute path | The checksum was generated from outside its upload directory, so `shasum -c` validated the local source path instead of the downloaded asset | Regenerated the checksum from the staging directory with a basename-only entry, replaced only the checksum asset, and verified it in a fresh download directory | Always generate release checksum files from the asset staging directory and run `shasum -c` against a freshly downloaded copy before declaring the release complete |
