# Org2 release contract

## Public channels

- Repository: `aviaviavi/org2`
- npm: `@aviaviavi/org2`
- VS Code Marketplace: `AviPress.org2-vscode`
- Git tag: unprefixed SemVer, for example `0.4.1`
- GitHub Release assets:
  - `aviaviavi-org2-{version}.tgz`
  - `org2-vscode-{version}.vsix`
  - OpenOrg `0.5.0+`: `OpenOrg.dmg` and `OpenOrg-Intel.dmg`
  - Historical Org2 Workspace releases: `Org2Workspace.dmg` and `Org2Workspace-Intel.dmg`

The iOS client is distributed separately through TestFlight. Its marketing version is coordinated with the desktop/CLI release, while its monotonically increasing build number remains separate.

## TestFlight

- App Store Connect app ID: `6797133238`
- Internal group: `Org2 Internal` (`f7462891-5b0e-4ccf-a3bc-2c2ea2f2540d`)
- External group: `OpenOrg Alpha` (`566e8d38-3c80-442c-8b9a-4f7916181149`)
- Public beta link: `https://testflight.apple.com/join/Yp3hfBng`

`tools/release-openorg.mjs` archives and uploads the iOS client, waits for App Store Connect processing, updates the English `What to Test` text, adds the build to both groups, and submits it for external beta review. Configure these non-committed environment variables once:

- `OPENORG_ASC_ISSUER_ID`
- `OPENORG_ASC_KEY_ID`
- `OPENORG_ASC_PRIVATE_KEY_PATH`

The private key stays outside the repository. Do not log it, copy it into release state, or add it to a corpus. The orchestrator stores only the resulting non-secret build ID and group IDs in its temporary checkpoint directory.

## Scarf Gateway

- Scarf owner: `org2`
- File Package: `org2-direct-download-artifacts`
- Package ID: `8f4f86e1-5e31-4c52-a6c7-ceae5b64913f`
- Default domain: `org2.gateway.scarf.sh`
- Route ID: `X3Eyp83Kad`
- Incoming path: `/downloads/{version}/{artifact}`
- Outgoing URL: `https://github.com/aviaviavi/org2/releases/download/{version}/{artifact}`
- Public template: `https://org2.gateway.scarf.sh/downloads/{version}/{artifact}`

Scarf Gateway is a redirect and measurement layer only. GitHub Releases remains the underlying file host. Do not upload release binaries to Scarf or create a new Scarf package per version.

Use `SCARF_API_TOKEN` only for authenticated API reads or an explicitly authorized configuration repair. Never log, persist, or place the token in release files, docs, fixtures, or skill resources. The normal release workflow does not need the token because the route is already templated.

## Signing and hosting constraints

- Build `OpenOrg.dmg` for Apple Silicon and `OpenOrg-Intel.dmg` for Intel (`x86_64`) with `tools/package-openorg-macos.mjs`.
- Bundle a native whisper.cpp executable and the verified English `base.en` model so dictation does not require Homebrew, a model download, or runtime environment variables. Keep macOS Speech only as a fallback.
- Require Developer ID signing, hardened runtime, Apple notarization, ticket stapling, and Gatekeeper verification for every OpenOrg DMG. The package command fails closed without a configured notarytool Keychain profile.
- Historical Org2 Workspace DMGs remain developer-signed but not notarized; say so plainly on their download page.
- Never build into or replace the daily app at `/Users/avi/Applications/Org2Workspace.app` as part of release packaging.
- Build each macOS architecture with a distinct `ORG2_WORKSPACE_SWIFT_SCRATCH_PATH`; parallel release builds must never share SwiftPM's mutable build directory.
- Attach all distributable files to the matching GitHub Release before synchronizing downloads.

## Download synchronization

`tools/sync-release-downloads.mjs` reads published GitHub Releases and their assets. It manages:

1. `docs/site/downloads.org`, including the current release and historical artifact table.
2. A marker-delimited `Direct downloads` block in GitHub release bodies.

Default execution is preview-only. Use `--apply-page` for the repository source, `--apply-release-notes` for GitHub mutations, `--release VERSION` to restrict release-note updates, and `--check` for a no-drift gate.

The tag workflow applies the release-note block after npm and VSIX assets are attached. Run the tool again after uploading the DMG so the final block includes every artifact.

## Authoritative documentation

- Scarf File Packages and URL templates: https://docs.scarf.sh/packages/
- Scarf Gateway variables and redirect behavior: https://docs.scarf.sh/gateway/
- GitHub Release assets: https://docs.github.com/en/rest/releases/assets
- App Store Connect builds: https://developer.apple.com/documentation/appstoreconnectapi/builds
- Add builds to beta groups: https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betagroups-_id_-relationships-builds
- Submit beta app review: https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betaappreviewsubmissions
