import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { draftContinuationPrompt, durableRunMarker, Org2Lifecycle } from "../lib/lifecycle.js";

test("resumes an approved external draft in its correlated OpenClaw session", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-draft-resume-"));
  const stateFile = join(dir, "state.json");
  const run = {
    id: "draft-run-1",
    status: "running",
    approvals: [{ status: "approved" }],
  };
  const lifecycle = new Org2Lifecycle({ stateFile, exec: async (args) => {
    if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
    if (args[0] === "run" && args[1] === "show") return JSON.stringify(run);
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = {
    kind: "external-draft",
    org2RunId: run.id,
    sessionKey: "agent:slack:cron:revenue-scout",
    createdAt: "2026-07-30T16:56:25.154Z",
  };

  const resumed = await lifecycle.resumeDraftRun(run.id, { expectedCorpusId: "personal" });

  assert.equal(resumed.sessionKey, "agent:slack:cron:revenue-scout");
  assert.equal(durableRunMarker(resumed.prompt), run.id);
  assert.match(draftContinuationPrompt(run.id), /exact provider draft/);
  assert.match(resumed.prompt, /approval-resolve --decision-key/);
});
