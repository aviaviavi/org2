# Org2 release contract

## Public channels

- Repository: `aviaviavi/org2`
- npm: `@aviaviavi/org2`
- VS Code Marketplace: `AviPress.org2-vscode`
- Git tag: unprefixed SemVer, for example `0.4.1`
- GitHub Release assets:
  - `aviaviavi-org2-{version}.tgz`
  - `org2-vscode-{version}.vsix`
  - `Org2Workspace.dmg`

The iOS client is distributed separately through TestFlight and does not share the desktop/CLI build number automatically.

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

- Build the macOS release for Apple Silicon.
- Current public DMGs are Apple developer-signed and not notarized; say so plainly.
- Never build into or replace the daily app at `/Users/avi/Applications/Org2Workspace.app` as part of release packaging.
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
