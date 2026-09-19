import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const fixtureURL = new URL("./fixtures/openorg-context-token-budgets-v1.json", import.meta.url);
const fixture = JSON.parse(await readFile(fixtureURL, "utf8"));

assert.equal(fixture.schema, "org2:openorg-context-token-benchmark:v1");
const representative = fixture.representativeTokens;
const budgets = fixture.budgets;
const scenario = fixture.scenario;
const fullTurn = representative.static + representative.project + representative.transcript;
const before = fullTurn * fixture.turns;
const recovery = representative.static
  + representative.project
  + Math.min(representative.transcript, budgets.recoveryTranscript);
const after = (recovery * scenario.recoveryTurns)
  + (scenario.projectDeltaTokens * scenario.projectDeltaTurns);
const reductionPercent = 100 - (after * 100 / before);

assert.ok(budgets.statelessHistory > 0 && budgets.statelessHistory <= 12_000);
assert.ok(budgets.sharedRoomSummary + budgets.sharedRoomUnseen <= 4_000);
assert.ok(scenario.recoveryTurns >= 2, "benchmark must model initial and post-compaction recovery");
assert.ok(scenario.projectDeltaTurns > 0, "benchmark must model changed workspace context");
assert.ok(
  scenario.recoveryTurns + scenario.projectDeltaTurns <= fixture.turns,
  "benchmark scenario exceeds its turn count"
);
assert.ok(
  reductionPercent >= budgets.minimumPersistentReductionPercent,
  `persistent context reduction ${reductionPercent.toFixed(1)}% is below ${budgets.minimumPersistentReductionPercent}%`
);

console.log(JSON.stringify({
  beforeTokens: before,
  afterTokens: after,
  reductionPercent: Number(reductionPercent.toFixed(1)),
  scenario,
  budgets
}, null, 2));
