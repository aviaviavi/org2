#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = (relativePath) => readFileSync(join(repoRoot, relativePath), "utf8");

const packageJSON = JSON.parse(read("package.json"));
assert.equal(packageJSON.name, "@aviaviavi/org2", "the npm package remains the Org2 substrate");
assert.equal(packageJSON.bin?.org2, "dist/cli.js", "the org2 CLI name remains stable");
assert.equal(packageJSON.bin?.["org2-lsp"], "dist/lsp.js", "the org2-lsp CLI name remains stable");

const macBuild = read("tools/build-macos-app.mjs");
assert.match(macBuild, /ORG2_WORKSPACE_BUNDLE_ID \?\? "org\.org2\.workspace"/, "preserve the macOS bundle identifier");
assert.match(macBuild, /const executableName = "Org2Workspace"/, "preserve the macOS executable name for 0.5");
assert.match(macBuild, /ORG2_WORKSPACE_APP_NAME \?\? "OpenOrg"/, "present the renamed macOS product");
assert.match(macBuild, /OpenOrgAppIcon\.png/, "package the OpenOrg review icon");

const macPackage = read("apps/macos/Org2Workspace/Package.swift");
assert.match(macPackage, /name: "Org2Workspace"/, "preserve the Swift package and target name for 0.5");

const iosProject = read("apps/ios/Org2Mobile/Org2Mobile.xcodeproj/project.pbxproj");
assert.match(iosProject, /PRODUCT_BUNDLE_IDENTIFIER = org\.org2\.mobile;/, "preserve the iOS bundle identifier");

const keychainContracts = [
  ["apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/AIChatDestinationCredentials.swift", "Org2Workspace.AIChatDestinations"],
  ["apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/DataSourceCredentials.swift", "Org2Workspace.DataSources"],
  ["apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/OpenClawGatewayClient.swift", "Org2Workspace.OpenClawGateway"],
  ["apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/OrgCrypt.swift", "Org2Workspace.OrgCrypt"],
  ["apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/SourceCredentials.swift", "org.org2.workspace.external-sources"],
];
for (const [relativePath, service] of keychainContracts) {
  assert.ok(read(relativePath).includes(`"${service}"`), `preserve Keychain service ${service}`);
}

const workspaceStore = read("apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/WorkspaceStore.swift");
for (const preferenceKey of [
  "Org2Workspace.corpusRoot",
  "Org2Workspace.corpusMounts.v1",
  "Org2Workspace.aiChat.destinations.v1",
  "Org2Workspace.meetingTranscription.provider.v1",
  "Org2Workspace.appearance.mode.v1",
]) {
  assert.ok(workspaceStore.includes(`"${preferenceKey}"`), `preserve preference key ${preferenceKey}`);
}

const productIdentity = read("apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/WorkspaceProductIdentity.swift");
assert.match(productIdentity, /displayName = "OpenOrg"/, "keep the user-facing product name centralized");
assert.match(productIdentity, /substrateName = "Org2"/, "keep Org2 named as the open substrate");

console.log("OK: OpenOrg/Org2 launch compatibility identifiers are unchanged");
