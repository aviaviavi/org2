import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  createAgentRun, renderAgentRunOrg, listAgentRuns, listAgentRunSnapshots,
} from "../dist/agentRun.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-large-run-list-"));
try {
  assert.deepEqual(listAgentRuns(root), []);
  const dir = path.join(root, ".org2", "runs");
  fs.mkdirSync(dir, { recursive: true });
  for (let index = 0; index < 4; index++) {
    const run = createAgentRun({ goal: `Large history ${index}`, now: "2026-09-10T00:00:00.000Z" });
    run.comments.push({ id: `comment-${index}`, author: "test", body: "History detail. ".repeat(100000), createdAt: run.createdAt });
    fs.writeFileSync(path.join(dir, `${run.id}.org2`), renderAgentRunOrg(run));
    if (index === 0) {
      fs.writeFileSync(path.join(dir, `${run.id}.sync-conflict.org2`), renderAgentRunOrg(run));
    }
  }
  const snapshots = listAgentRunSnapshots(root);
  const runs = listAgentRuns(root);
  assert.equal(runs.length, 4);
  assert.deepEqual(runs, snapshots.map(snapshot => snapshot.run));
  assert.ok(snapshots.every(snapshot => snapshot.raw.length > 1000000));
  assert.ok(snapshots.every(snapshot => snapshot.revision && snapshot.sourceIssues.length === 0));
  // Invalid canonical input must still fail closed, rather than silently
  // disappearing from a workspace list after the streaming refactor.
  fs.writeFileSync(path.join(dir, "invalid.org2"), "invalid run");
  assert.throws(() => listAgentRuns(root), /machine-state JSON/);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
console.log("large run list tests passed");
