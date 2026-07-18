import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { corpusIdentityStatus, initializeCorpusIdentity } from "../dist/corpusIdentity.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-corpus-identity-"));
try {
  const preview = initializeCorpusIdentity(root, { id: "team-operations", name: "Team Operations", kind: "shared" });
  assert.equal(preview.applied, false);
  assert.equal(fs.existsSync(path.join(root, "org2.json")), false);

  const applied = initializeCorpusIdentity(root, { id: "team-operations", name: "Team Operations", kind: "shared" }, { apply: true });
  assert.equal(applied.status.valid, true);
  assert.equal(applied.status.identity?.kind, "shared");
  assert.equal(fs.existsSync(path.join(root, "workflows")), true);

  const config = JSON.parse(fs.readFileSync(path.join(root, "org2.json"), "utf8"));
  assert.deepEqual(config.corpus, {
    schema: "org2:corpus:v1",
    id: "team-operations",
    name: "Team Operations",
    kind: "shared",
  });
  assert.equal(corpusIdentityStatus(root).identity?.id, "team-operations");

  assert.throws(
    () => initializeCorpusIdentity(root, { id: "different-team", name: "Different Team", kind: "shared" }, { apply: true }),
    /already has identity team-operations/,
  );

  const shown = spawnSync(process.execPath, ["dist/cli.js", "corpus", "show", "--dir", root, "--json"], { encoding: "utf8" });
  assert.equal(shown.status, 0, shown.stderr);
  assert.equal(JSON.parse(shown.stdout).identity.id, "team-operations");

  const invalidRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-corpus-invalid-"));
  try {
    fs.writeFileSync(path.join(invalidRoot, "org2.json"), "{}\n");
    const invalid = spawnSync(process.execPath, ["dist/cli.js", "corpus", "validate", "--dir", invalidRoot, "--json"], { encoding: "utf8" });
    assert.equal(invalid.status, 1);
    assert.match(invalid.stdout, /corpus.*must be an object/s);
  } finally {
    fs.rmSync(invalidRoot, { recursive: true, force: true });
  }
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

console.log("✓ corpus identity");
