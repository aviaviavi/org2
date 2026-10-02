import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "org2-repair-cli-"));
try {
  const worker = path.join(temporary, "native-worker");
  fs.writeFileSync(worker, `#!${process.execPath}\nconsole.log(JSON.stringify(process.argv.slice(2)));\n`, { mode: 0o700 });
  const cli = path.resolve("dist/cli.js");
  const run = (...args) => spawnSync(process.execPath, [cli, "thread", "repair", "--dir", temporary,
    "--executable", worker, ...args], { encoding: "utf8" });
  const preview = run("--json");
  assert.equal(preview.status, 0, preview.stderr);
  assert.deepEqual(JSON.parse(preview.stdout), ["--repair-transcript", temporary]);
  const applied = run("--apply", "--if-revision", "a".repeat(64));
  assert.equal(applied.status, 0, applied.stderr);
  assert.deepEqual(JSON.parse(applied.stdout), ["--repair-transcript", temporary, "--apply", "--if-revision", "a".repeat(64)]);
  const watch = run("--apply", "--watch", "--interval", "900");
  assert.equal(watch.status, 0, watch.stderr);
  assert.deepEqual(JSON.parse(watch.stdout), ["--repair-transcript", temporary, "--apply", "--interval", "900"]);
  assert.equal(run("--watch").status, 0);
  for (const interval of ["NaN", "0", "-1", "9", "86401", "Infinity"]) {
    const result = run("--watch", "--interval", interval);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /interval/);
  }
  assert.notEqual(run("--interval", "120").status, 0);
  assert.notEqual(run("--watch", "--if-revision", "a".repeat(64)).status, 0);
  const missing = spawnSync(process.execPath, [cli, "thread", "repair", "--executable", path.join(temporary, "absent")], { encoding: "utf8" });
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /Native chat repair worker unavailable/);
  console.log("OK: native chat repair CLI preview, apply, watch, interval validation, and worker discovery");
} finally { fs.rmSync(temporary, { recursive: true, force: true }); }
