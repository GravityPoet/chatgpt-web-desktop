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
