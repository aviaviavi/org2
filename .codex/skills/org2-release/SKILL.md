---
name: org2-release
description: Publish, repair, or verify coordinated Org2 releases across npm, the VS Code Marketplace, GitHub Releases, the macOS DMG, the Scarf-tracked downloads page, and GitHub release notes. Use when cutting an Org2 version, republishing a missing channel, attaching release artifacts, updating release download links, or auditing whether an Org2 release is complete.
---

# Org2 Release

Ship one coordinated Org2 version without touching the user's daily app. Keep GitHub Releases as the artifact host and route public direct downloads through the permanent Scarf Gateway template.

Read [references/release-contract.md](references/release-contract.md) before mutating a registry, tag, GitHub Release, Scarf configuration, or download surface.

## 1. Establish scope

1. Read `AGENTS.md` and inspect `git status`, the current branch, recent tags, and existing releases.
2. Require explicit authorization for commits, pushes, tags, registry publication, release edits, or Scarf mutations. Treat a direct request to cut/publish a release as authorization for those normal release effects.
3. Preserve unrelated work. Release from `main` unless the user explicitly selects another branch.
4. Derive the version from the user's request; use unprefixed SemVer tags such as `0.4.1`.

## 2. Validate the release candidate

1. Confirm npm and GitHub authentication without printing tokens: `npm whoami` and `gh auth status`.
2. Run the checks required by affected surfaces. For a coordinated release, include `npm test`, `npm run docs:check`, extension tests, and the complete macOS Swift suite.
3. Resolve failures before versioning. Report pre-existing skips accurately.
4. Commit and push the complete feature tree to `main` before creating release metadata.

## 3. Stamp and package

1. Stamp root and VS Code manifests and lockfiles with `npm version VERSION --no-git-tag-version --allow-same-version` and the equivalent `npm --prefix editors/vscode-org2 version` command.
2. Add a concise VS Code changelog entry. Avoid npm serialization noise unrelated to the version.
3. Validate `npm pack --dry-run --json` and package the VSIX from `editors/vscode-org2`.
4. Build the macOS app into a temporary staging directory with `ORG2_WORKSPACE_SWIFT_CONFIGURATION=release` and `ORG2_WORKSPACE_APP_PATH`. Supply the target-architecture Node binary through `ORG2_WORKSPACE_NODE_PATH`, the pinned native whisper.cpp executable through `ORG2_WORKSPACE_WHISPER_CPP_PATH`, and the verified `ggml-base.en.bin` model through `ORG2_WORKSPACE_WHISPER_MODEL_PATH`; release packaging fails closed when any self-contained runtime is missing. Never overwrite or relaunch `/Users/avi/Applications/Org2Workspace.app` during release packaging.
5. Create an Apple Silicon DMG containing the app and an `Applications` symlink. Verify the app with `codesign --verify --deep --strict` and the image with `hdiutil verify`. Record its SHA-256.

## 4. Publish

1. Commit release metadata, push `main`, create an annotated version tag, and push the tag.
2. Watch `.github/workflows/release-packages.yml` to completion. It publishes npm through Trusted Publishing, publishes the VS Code extension, creates the GitHub Release, and attaches the npm and VSIX artifacts.
3. If the workflow fails, inspect its logs before using a local fallback. Never republish a version already visible in a registry.
4. Upload the verified DMG as `Org2Workspace.dmg` and replace generated notes with reviewer-facing highlights, install constraints, the DMG checksum, and the full changelog.

## 5. Synchronize tracked downloads

Run a safe preview after every artifact is attached:

```sh
node tools/sync-release-downloads.mjs
```

Then apply both durable surfaces:

```sh
node tools/sync-release-downloads.mjs --apply-page --apply-release-notes
npm run org2 -- publish docs-site --config org2.json
```

The sync tool regenerates `docs/site/downloads.org` from GitHub Release assets and inserts an idempotent managed Scarf block into each release body. Commit and push the resulting page and generated site output. Do not hand-author a second set of artifact URLs.

## 6. Verify publicly

1. Confirm npm's `latest` dist-tag equals the version.
2. Confirm the Marketplace serves the exact versioned VSIX; allow for catalog propagation delay.
3. Download GitHub Release assets back and inspect their embedded versions.
4. Request every Scarf URL without following redirects. Require a 3xx response whose `Location` is the matching GitHub Release asset.
5. Run `node tools/sync-release-downloads.mjs --check` and confirm the repository is clean and synchronized with `origin/main`.
6. Report release URLs, commits/tag, validation, signing/notarization status, and any separately distributed iOS build.
