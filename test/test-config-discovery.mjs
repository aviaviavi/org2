import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { findConfigFile } from "../dist/config.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-config-discovery-"));

try {
  const rootConfig = path.join(tmp, "org2.json");
  fs.writeFileSync(rootConfig, "{}\n", "utf8");

  const segments = Array.from({ length: 12 }, (_, index) => `level-${index + 1}`);
  const deepDir = path.join(tmp, ...segments);
  fs.mkdirSync(deepDir, { recursive: true });

  assert.equal(
    findConfigFile(deepDir),
    rootConfig,
    "config discovery should reach the workspace root from deeply nested files",
  );

  const nestedConfig = path.join(tmp, ...segments.slice(0, 5), "org2.json");
  fs.writeFileSync(nestedConfig, "{}\n", "utf8");
  assert.equal(
    findConfigFile(deepDir),
    nestedConfig,
    "config discovery should still prefer the nearest config",
  );
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log("config discovery: ok");
