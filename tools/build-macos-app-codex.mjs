#!/usr/bin/env node

import { homedir } from "node:os";
import { join } from "node:path";

process.env.ORG2_WORKSPACE_APP_PATH ??= join(homedir(), "Applications", "Org2Workspace Codex.app");
process.env.ORG2_WORKSPACE_BUNDLE_ID ??= "org.org2.workspace.codex";
process.env.ORG2_WORKSPACE_APP_NAME ??= "Org2Workspace Codex";
process.env.ORG2_WORKSPACE_SWIFT_CONFIGURATION ??= "debug";

await import("./build-macos-app.mjs");
