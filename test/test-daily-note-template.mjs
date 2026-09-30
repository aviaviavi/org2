import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  dailyNoteDateFromIso,
  dailyNoteTemplateProblem,
  inferDailyNoteTemplates,
  renderDailyNoteTemplate,
  resolveDailyNotePath,
} from "../dist/dailyNoteTemplate.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(fs.readFileSync(path.join(here, "fixtures/daily-note-templates.json"), "utf8"));
const cli = path.join(here, "../dist/cli.js");

for (const { template, date, path: expected } of fixture.render) {
  assert.equal(dailyNoteTemplateProblem(template), null, template);
  assert.equal(renderDailyNoteTemplate(template, dailyNoteDateFromIso(date)), expected, template);
}
for (const template of fixture.invalid) {
  assert.notEqual(dailyNoteTemplateProblem(template), null, `expected ${JSON.stringify(template)} to be rejected`);
}
const reference = dailyNoteDateFromIso(fixture.inferReference);
for (const { path: example, template, date } of fixture.infer) {
  const [best] = inferDailyNoteTemplates(example, reference);
  if (template === null) {
    assert.equal(best, undefined, example);
    continue;
  }
  assert.equal(best?.template, template, example);
  assert.equal(best.date, date, example);
  assert.equal(renderDailyNoteTemplate(best.template, dailyNoteDateFromIso(best.date)), example);
}
// Ambiguous numeric orders offer both readings.
const ambiguous = inferDailyNoteTemplates("logs/09-10-2026.md", reference).map((candidate) => candidate.template);
assert.ok(ambiguous.includes("logs/{DD}-{MM}-{YYYY}.md") && ambiguous.includes("logs/{MM}-{DD}-{YYYY}.md"), ambiguous.join(", "));
assert.throws(() => inferDailyNoteTemplates("../outside/2026-09-29.md", reference), /inside the corpus/);

// Resolution: template wins; invalid templates and absent config keep dailiesDir.
const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-daily-template-"));
const date = dailyNoteDateFromIso("2026-09-29");
assert.equal(resolveDailyNotePath({ roam: { dailiesDir: "daily" } }, root, date), path.join(root, "daily/2026-09-29.org"));
fs.mkdirSync(path.join(root, "daily"));
fs.writeFileSync(path.join(root, "daily/2026-09-29.org2"), "");
assert.equal(resolveDailyNotePath({ roam: { dailiesDir: "daily" } }, root, date), path.join(root, "daily/2026-09-29.org2"));
assert.equal(resolveDailyNotePath({ roam: { dailiesDir: "daily", dailyFileTemplate: "ops/{MM}{DD}.md" } }, root, date), path.join(root, "ops/0929.md"));
assert.equal(resolveDailyNotePath({ roam: { dailiesDir: "daily", dailyFileTemplate: "../{MM}{DD}.md" } }, root, date), path.join(root, "daily/2026-09-29.org2"));

// CLI: infer, guarded preview/apply, clear, and unrelated config preservation.
const run = (...args) => {
  const result = spawnSync(process.execPath, [cli, "daily-config", ...args, "--dir", root], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout);
  return JSON.parse(result.stdout);
};
const runFailure = (...args) => spawnSync(process.execPath, [cli, "daily-config", ...args, "--dir", root], { encoding: "utf8" });
fs.writeFileSync(path.join(root, "org2.json"), `${JSON.stringify({ roam: { dailiesDir: "daily" }, todo: { sequences: ["TODO | DONE"] } }, null, 2)}\n`);
fs.mkdirSync(path.join(root, "journal/2026/09"), { recursive: true });
fs.writeFileSync(path.join(root, "journal/2026/09/2026-09-29-wind-down.md"), "# wind down\n");

const inferred = run("infer", "--file", path.join(root, "journal/2026/09/2026-09-29-wind-down.md"), "--date", "2026-09-30");
assert.equal(inferred.candidates[0].template, "journal/{YYYY}/{MM}/{YYYY}-{MM}-{DD}-wind-down.md");
assert.equal(inferred.exampleExists, true);
assert.ok(inferred.candidates[0].paths.today.relativePath.startsWith("journal/"));
assert.notEqual(runFailure("infer", "--file", os.tmpdir()).status, 0);

const shown = run("show");
assert.equal(shown.template, null);
assert.equal(shown.effective, "dailiesDir");
const preview = run("set", "--template", inferred.candidates[0].template);
assert.equal(preview.changed, true);
assert.equal(preview.applied, false);
assert.equal(JSON.parse(fs.readFileSync(path.join(root, "org2.json"), "utf8")).roam.dailyFileTemplate, undefined);
const stale = runFailure("set", "--template", inferred.candidates[0].template, "--if-revision", "sha256:stale", "--apply");
assert.notEqual(stale.status, 0);
assert.match(stale.stderr, /changed since they were loaded/);
const applied = run("set", "--template", inferred.candidates[0].template, "--if-revision", shown.revision, "--apply");
assert.equal(applied.applied, true);
const written = JSON.parse(fs.readFileSync(path.join(root, "org2.json"), "utf8"));
assert.deepEqual(written, { roam: { dailiesDir: "daily", dailyFileTemplate: "journal/{YYYY}/{MM}/{YYYY}-{MM}-{DD}-wind-down.md" }, todo: { sequences: ["TODO | DONE"] } });
const onDate = run("show", "--date", "2026-09-29");
assert.equal(onDate.paths.date.relativePath, "journal/2026/09/2026-09-29-wind-down.md");
assert.equal(onDate.paths.date.exists, true);
const invalid = runFailure("set", "--template", "journal/{YYYY}.md");
assert.notEqual(invalid.status, 0);
assert.match(invalid.stderr, /day token/);
run("set", "--clear", "--apply");
assert.deepEqual(JSON.parse(fs.readFileSync(path.join(root, "org2.json"), "utf8")), { roam: { dailiesDir: "daily" }, todo: { sequences: ["TODO | DONE"] } });

fs.rmSync(root, { recursive: true, force: true });
console.log("daily note template tests passed");
