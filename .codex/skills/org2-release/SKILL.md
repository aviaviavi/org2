---
name: org2-release
description: Publish, repair, or verify coordinated Org2 releases across npm, the VS Code Marketplace, GitHub Releases, notarized macOS DMGs, TestFlight, Scarf-tracked downloads, and release notes. Use when cutting an Org2 version, repairing a missing channel, attaching release artifacts, updating release links, or auditing release completeness.
---

# Org2 Release

Ship one coordinated Org2 version without touching the user's daily app. Treat the notarized Mac artifacts and GitHub Release as the primary release path: TestFlight distribution and Marketplace visibility must not delay them or cause them to be rolled back. Keep GitHub Releases as the artifact host and route public direct downloads through the permanent Scarf Gateway template.

Read [references/release-contract.md](references/release-contract.md) before mutating a registry, tag, GitHub Release, Scarf configuration, or download surface.

## Canonical release command

Use `tools/release-openorg.mjs` for a normal coordinated release. Do not manually reconstruct the checklist below unless repairing one specific channel.

Prepare reviewer-facing Markdown notes, then inspect the read-only plan:

```sh
npm run release:openorg -- patch \
  --ios-build NEXT_BUILD \
  --notes /absolute/path/to/release-notes.md \
  --skip-testflight-groups
```

The command is preview-only unless `--execute` is present. When the plan is correct:

```sh
npm run release:openorg -- patch \
  --ios-build NEXT_BUILD \
  --notes /absolute/path/to/release-notes.md \
  --what-to-test /absolute/path/to/what-to-test.md \
  --skip-testflight-groups \
  --execute
```

The orchestrator:

- fails closed on a dirty or unsynchronized `main`;
- checkpoints every phase and each input-fingerprinted validation and packaging job under `/tmp/openorg-release-VERSION/state.json`;
- builds the shared runtime once, runs docs, Node, and VS Code validation concurrently, then runs Swift serially in an isolated scratch directory;
- builds the isolated arm64 DMG, isolated Intel DMG, and iOS archive concurrently, reusing the validated TypeScript output and installing each architecture's production dependencies in separate staging;
- overlaps the GitHub tag workflow/DMG publication with the TestFlight binary upload;
- leaves TestFlight metadata, group assignment, and external beta review for the signed-in App Store Connect browser flow described below;
- synchronizes GitHub, Scarf-backed downloads, and the generated site before parallel public verification;
- writes each long-running job to a separate log beside the checkpoint.

Use `--through PHASE` for an intentional checkpoint, `--restart` to discard phase and job state, and `--skip-ios` for a tooling-only release. For an iOS release, `--skip-testflight-groups` is the normal browser-first path: it skips only API-driven distribution, not the required browser completion below. Validation retries reuse successful jobs only while the tracked and untracked release inputs retain the same fingerprint. Never use `--restart` merely to retry one failed lane.

## Resume and repair without duplicate work

1. Resume the existing versioned checkpoint before considering `--restart`. Inspect its completed phases, validation fingerprint, and per-job logs. Restart only when the recorded inputs are stale or the candidate itself changed.
2. Do not repeat the complete Swift suite solely to chase a timing-only failure. If the full run has no functional failure, rerun each failed timing test once in isolation. Accept the full run plus focused passing retry as the release evidence; repeat the full suite only when a functional test failed or an isolated timing retry still fails.
3. Resume a failed packaging phase normally. Its completed jobs are retained only while the source fingerprint and outputs match: Mac sidecars must have the exact version and architecture, notarization success, and matching SHA-256; iOS archives must have the exact version/build and valid code signatures. Missing or damaged outputs rerun only their own job. Use `tools/package-openorg-macos.mjs` for an explicitly scoped architecture repair.
4. npm optional native dependencies follow the architecture of the Node process that installs them. The Mac packager now installs locked production dependencies under each target Node in its own temporary directory and loads the native DuckDB binding before compiling Swift. Do not replace the shared checkout's dependencies between parallel packaging jobs. Preserve `/usr/bin:/bin:/usr/sbin:/sbin` in `PATH` so notarization verification can invoke `/usr/sbin/spctl`.
5. If the tag workflow times out only while publishing VS Code, do not rerun the release or republish npm. Confirm the version is absent from the Marketplace, then use the workflow's `publish_only=true` dispatch for the same version. It checks out the version tag, skips the full test and npm publication gates, retries Marketplace submission, and reattaches the small release assets. The tag workflow is intentionally allowed to continue to GitHub asset publication when Marketplace submission fails.
6. Manually mark a failed fan-out phase complete only as a narrow recovery after every required output independently satisfies that phase's contract. Never advance a checkpoint to conceal a missing, unnotarized, mismatched, or unverified artifact.

## 1. Establish scope

1. Read `AGENTS.md` and inspect `git status`, the current branch, recent tags, and existing releases.
2. Require explicit authorization for commits, pushes, tags, registry publication, release edits, or Scarf mutations. Treat a direct request to cut/publish a release as authorization for those normal release effects.
3. Preserve unrelated work. Release from `main` unless the user explicitly selects another branch.
4. Derive the version from the user's request; use unprefixed SemVer tags such as `0.4.1`.

## 2. Validate the release candidate

1. Confirm GitHub authentication with `gh auth status` and npm registry reachability with `npm ping`, without printing tokens. npm publication uses the tag workflow's Trusted Publishing/OIDC identity; a local npm credential is required only for an explicitly chosen local fallback.
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
2. Watch `.github/workflows/release-packages.yml` through npm publication and GitHub asset attachment. It attempts the VS Code extension too, but that optional channel cannot block creation of the GitHub Release.
3. If a publication lane fails, inspect its logs before using a fallback. Never republish a version already visible in a registry. For a Marketplace-only retry, dispatch:

   ```sh
   gh workflow run release-packages.yml --ref main \
     -f dry_run=false \
     -f release_version=VERSION \
     -f publish_only=true
   ```

4. Upload the verified OpenOrg DMGs with their canonical architecture names and replace generated notes with reviewer-facing highlights, installation requirements, notarization status, checksums, and the full changelog.
5. Unless iOS was explicitly skipped, let the orchestrator upload the stamped archive concurrently with GitHub publication. Complete TestFlight distribution through the browser after the binary reaches a valid processed state.

## TestFlight browser completion

Use an existing signed-in App Store Connect browser session for every release. Do not use the App Store Connect API to update review details, attach the external group, or submit beta review; API-key roles may allow upload and reads while forbidding those distribution actions.

1. Open the exact OpenOrg version and build under TestFlight and wait for processing to complete.
2. Set the English `What to Test` text from the prepared release file.
3. Ensure the build belongs to `Org2 Internal` and select `OpenOrg Alpha` as the external group.
4. Review whether `Automatically notify testers` matches the release intent.
5. Immediately before clicking `Submit for Review`, obtain the browser action-time confirmation required for granting the external group access, submitting Apple beta review, and notifying testers.
6. After submission, verify the build page shows both groups and the external review/testing status. Browser completion is part of an iOS release even though it runs outside the orchestrator checkpoint.

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
2. Check the Marketplace once. If its publish step succeeded and the exact VSIX is attached to the GitHub Release but the catalog still shows the prior version, do not wait, block, roll back, or republish. Report catalog visibility as a non-blocking propagation follow-up.
3. Download GitHub Release assets back and inspect their embedded versions.
4. Request every Scarf URL without following redirects. Require a 3xx response whose `Location` is the matching GitHub Release asset.
5. Run `node tools/sync-release-downloads.mjs --check` and confirm the repository is clean and synchronized with `origin/main`.
6. Report release URLs, commits/tag, validation, signing/notarization status, and any separately distributed iOS build.
