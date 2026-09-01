---
name: org2-release
description: Publish, repair, or verify coordinated Org2 releases across npm, the VS Code Marketplace, GitHub Releases, the macOS DMG, the Scarf-tracked downloads page, and GitHub release notes. Use when cutting an Org2 version, republishing a missing channel, attaching release artifacts, updating release download links, or auditing whether an Org2 release is complete.
---

# Org2 Release

Ship one coordinated Org2 version without touching the user's daily app. Keep GitHub Releases as the artifact host and route public direct downloads through the permanent Scarf Gateway template.

Read [references/release-contract.md](references/release-contract.md) before mutating a registry, tag, GitHub Release, Scarf configuration, or download surface.

## Canonical release command

Use `tools/release-openorg.mjs` for a normal coordinated release. Do not manually reconstruct the checklist below unless repairing one specific channel.

Prepare reviewer-facing Markdown notes, then inspect the read-only plan:

```sh
npm run release:openorg -- patch \
  --ios-build NEXT_BUILD \
  --notes /absolute/path/to/release-notes.md
```

The command is preview-only unless `--execute` is present. When the plan is correct:

```sh
npm run release:openorg -- patch \
  --ios-build NEXT_BUILD \
  --notes /absolute/path/to/release-notes.md \
  --what-to-test /absolute/path/to/what-to-test.md \
  --execute
```

The orchestrator:

- fails closed on a dirty or unsynchronized `main`;
- checkpoints every phase and each input-fingerprinted validation job under `/tmp/openorg-release-VERSION/state.json`;
- builds the shared runtime once, runs docs, Node, and VS Code validation concurrently, then runs Swift serially in an isolated scratch directory;
- builds the isolated arm64 DMG, isolated Intel DMG, and iOS archive concurrently;
- overlaps the GitHub tag workflow/DMG publication with TestFlight upload and processing;
- assigns the TestFlight build to both required groups and requests external beta review through App Store Connect;
- synchronizes GitHub, Scarf-backed downloads, and the generated site before parallel public verification;
- writes each long-running job to a separate log beside the checkpoint.

Use `--through PHASE` for an intentional checkpoint, `--restart` to discard phase and job state, `--skip-ios` for a tooling-only release, and `--skip-testflight-groups` only when explicitly accepting a manual App Store Connect handoff. Validation retries reuse successful jobs only while the tracked and untracked release inputs retain the same fingerprint. Never use the latter as the normal path.

## Resume and repair without duplicate work

1. Resume the existing versioned checkpoint before considering `--restart`. Inspect its completed phases, validation fingerprint, and per-job logs. Restart only when the recorded inputs are stale or the candidate itself changed.
2. A failed parallel packaging phase may still leave one fully valid Mac artifact. Preserve any artifact whose sidecar has the exact version and architecture, whose SHA-256 matches, and whose signing, notarization, stapling, and Gatekeeper checks passed. Repair only the failed architecture with `tools/package-openorg-macos.mjs`.
3. npm optional native dependencies follow the architecture of the Node process that installs them. For a single-architecture repair, run the locked install under the target-architecture Node binary and launch the package command with that same binary. Before returning to a host-architecture documentation or sync step, restore the lockfile install under the orchestrator's host Node. Do not rerun validation merely because dependencies were reinstalled from an unchanged lockfile.
4. Manually mark a failed fan-out phase complete only as a narrow recovery after every required output independently satisfies that phase's contract. Never advance a checkpoint to conceal a missing, unnotarized, mismatched, or unverified artifact.

## 1. Establish scope

1. Read `AGENTS.md` and inspect `git status`, the current branch, recent tags, and existing releases.
2. Require explicit authorization for commits, pushes, tags, registry publication, release edits, or Scarf mutations. Treat a direct request to cut/publish a release as authorization for those normal release effects.
3. Preserve unrelated work. Release from `main` unless the user explicitly selects another branch.
4. Derive the version from the user's request; use unprefixed SemVer tags such as `0.4.1`.

## 2. Validate the release candidate

1. Confirm npm and GitHub authentication without printing tokens: `npm whoami` and `gh auth status`.
2. Run the checks required by affected surfaces. For a coordinated release, the orchestrator performs one shared build, runs the built Node and documentation checks with the extension tests, and then runs the complete macOS Swift suite serially. The tag workflow runs one independent `npm test` gate and publishes the already-packed tarball without repeating npm lifecycle tests.
3. Resolve failures before versioning. Report pre-existing skips accurately.
4. Commit and push the complete feature tree to `main` before creating release metadata.

## 3. Stamp and package

1. Stamp root and VS Code manifests and lockfiles with `npm version VERSION --no-git-tag-version --allow-same-version` and the equivalent `npm --prefix editors/vscode-org2 version` command.
2. Add a concise VS Code changelog entry. Avoid npm serialization noise unrelated to the version.
3. Validate `npm pack --dry-run --json` and package the VSIX from `editors/vscode-org2`.
4. The orchestrator packages both architectures concurrently with `tools/package-openorg-macos.mjs`. Each package gets its own temporary app staging and Swift scratch directory. Supply the target-architecture Node binary, pinned native whisper.cpp executable, verified `ggml-base.en.bin` model, Developer ID identity, shared Google OAuth desktop client, and notarytool Keychain profile through the environment variables in the release contract. The command fails closed when a runtime or notarization credential is missing, signs nested code with hardened runtime, submits the DMG for notarization, staples it, runs Gatekeeper verification, and records a sidecar manifest and SHA-256. Never overwrite or relaunch the daily app at `~/Applications/OpenOrg.app` or its historical `~/Applications/Org2Workspace.app` path during release packaging.
5. Require `OpenOrg.dmg` for Apple Silicon and `OpenOrg-Intel.dmg` for Intel. Verify the app with `codesign --verify --deep --strict`, the image with `hdiutil verify`, and the stapled artifact with `xcrun stapler validate` and `spctl`.

## 4. Publish

1. Commit release metadata, push `main`, create an annotated version tag, and push the tag.
2. Watch `.github/workflows/release-packages.yml` to completion. It publishes npm through Trusted Publishing, publishes the VS Code extension, creates the GitHub Release, and attaches the npm and VSIX artifacts.
3. If the workflow fails, inspect its logs before using a local fallback. Never republish a version already visible in a registry.
4. Upload the verified OpenOrg DMGs with their canonical architecture names and replace generated notes with reviewer-facing highlights, installation requirements, notarization status, checksums, and the full changelog.
5. Unless iOS was explicitly skipped, upload the stamped archive to TestFlight, wait for processing, update `What to Test`, assign both the internal and external groups, and submit external beta review. The orchestrator performs these actions concurrently with GitHub publication.

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
2. Confirm the Marketplace serves the exact versioned VSIX, allowing for catalog propagation delay. If the tag workflow's Marketplace publish step succeeded and the exact VSIX is attached to the GitHub Release but the public catalog still shows the prior version, do not block or roll back the GitHub/npm/Mac release and do not republish the same version. Report Marketplace visibility as a pending follow-up and retry only that public check later; leave the final verification checkpoint incomplete until it converges.
3. Download GitHub Release assets back and inspect their embedded versions.
4. Request every Scarf URL without following redirects. Require a 3xx response whose `Location` is the matching GitHub Release asset.
5. Run `node tools/sync-release-downloads.mjs --check` and confirm the repository is clean and synchronized with `origin/main`.
6. Report release URLs, commits/tag, validation, signing/notarization status, and any separately distributed iOS build.
