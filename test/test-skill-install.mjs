import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-skill-install-"));
try {
  const cli = path.resolve("dist/cli.js");
  const run = (...args) => spawnSync(process.execPath, [cli, "skill", "install", "--dir", root, "--format", "json", ...args], { encoding: "utf8" });
  const destination = path.join(root, ".agents", "skills", "org2", "SKILL.md");

  const preview = run();
  assert.equal(preview.status, 0, preview.stderr);
  assert.equal(JSON.parse(preview.stdout).status, "would-create");
  assert.equal(fs.existsSync(destination), false);

  const applied = run("--apply");
  assert.equal(applied.status, 0, applied.stderr);
  assert.equal(JSON.parse(applied.stdout).status, "created");
  assert.match(fs.readFileSync(destination, "utf8"), /\nname: org2\n/);

  const repeated = run("--apply");
  assert.equal(repeated.status, 0, repeated.stderr);
  assert.equal(JSON.parse(repeated.stdout).status, "unchanged");

  fs.writeFileSync(destination, "user-managed\n", "utf8");
  const conflict = run("--apply");
  assert.equal(conflict.status, 2);
  assert.equal(JSON.parse(conflict.stdout).status, "conflict");
  assert.equal(fs.readFileSync(destination, "utf8"), "user-managed\n");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

console.log("skill installer: ok");
