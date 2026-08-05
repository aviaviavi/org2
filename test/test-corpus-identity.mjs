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

  const personalRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-corpus-personal-"));
  try {
    initializeCorpusIdentity(personalRoot, { id: "avi-notes", name: "Avi Notes", kind: "personal" }, { apply: true });
    fs.writeFileSync(path.join(root, "notes", "team.org2"), "* TODO Team planning\nSCHEDULED: <2026-07-20 Mon>\nShared roadmap phrase.\n");
    fs.writeFileSync(path.join(personalRoot, "notes", "personal.org2"), "* TODO Personal planning\nSCHEDULED: <2026-07-20 Mon>\nPersonal roadmap phrase.\n");

    const agenda = spawnSync(process.execPath, [
      "dist/cli.js", "workspace", "agenda",
      "--mount", personalRoot, "--mount", root,
      "--from", "2026-07-20", "--to", "2026-07-20", "--json",
    ], { encoding: "utf8" });
    assert.equal(agenda.status, 0, agenda.stderr);
    const agendaPayload = JSON.parse(agenda.stdout);
    assert.equal(agendaPayload.$schema, "org2:workspace-agenda:v1");
    assert.deepEqual(agendaPayload.corpora.map((corpus) => corpus.id), ["avi-notes", "team-operations"]);
    assert.deepEqual(agendaPayload.days[0].items.map((item) => item.corpus.id), ["avi-notes", "team-operations"]);

    const search = spawnSync(process.execPath, [
      "dist/cli.js", "workspace", "search", "roadmap phrase",
      "--mount", personalRoot, "--mount", root, "--recursive", "--limit", "10", "--json",
    ], { encoding: "utf8" });
    assert.equal(search.status, 0, search.stderr);
    const searchPayload = JSON.parse(search.stdout);
    assert.equal(searchPayload.$schema, "org2:workspace-search:v1");
    assert.equal(searchPayload.issues.length, 0, JSON.stringify(searchPayload, null, 2));
    assert.deepEqual(searchPayload.results.map((item) => item.corpus.id), ["avi-notes", "team-operations"]);

    const duplicateRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-corpus-duplicate-"));
    const invalidMount = fs.mkdtempSync(path.join(os.tmpdir(), "org2-corpus-invalid-mount-"));
    try {
      fs.writeFileSync(path.join(duplicateRoot, "org2.json"), fs.readFileSync(path.join(root, "org2.json"), "utf8"));
      const problematicMounts = spawnSync(process.execPath, [
        "dist/cli.js", "workspace", "search", "roadmap phrase",
        "--mount", root, "--mount", duplicateRoot, "--mount", invalidMount, "--recursive", "--json",
      ], { encoding: "utf8" });
      assert.equal(problematicMounts.status, 0, problematicMounts.stderr);
      const problematicPayload = JSON.parse(problematicMounts.stdout);
      assert.deepEqual(problematicPayload.corpora.map((corpus) => corpus.id), ["team-operations"]);
      assert.equal(problematicPayload.issues.length, 2, JSON.stringify(problematicPayload, null, 2));
      assert.ok(problematicPayload.issues.some((issue) => issue.root === path.resolve(duplicateRoot) && /duplicates corpus id team-operations/.test(issue.message)));
      assert.ok(problematicPayload.issues.some((issue) => issue.root === path.resolve(invalidMount) && /org2\.json: is required/.test(issue.message)));
      assert.deepEqual(
        problematicPayload.issues,
        [...problematicPayload.issues].sort((left, right) => left.root.localeCompare(right.root) || left.message.localeCompare(right.message)),
      );
    } finally {
      fs.rmSync(duplicateRoot, { recursive: true, force: true });
      fs.rmSync(invalidMount, { recursive: true, force: true });
    }
  } finally {
    fs.rmSync(personalRoot, { recursive: true, force: true });
  }

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
