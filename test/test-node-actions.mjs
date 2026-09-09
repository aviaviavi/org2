import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { compileCorpus } from "../dist/corpusCompile.js";
import { queryNodeActions } from "../dist/nodeActions.js";

const root = mkdtempSync(path.join(tmpdir(), "org2-node-actions-"));
const write = (relative, text) => {
  const absolute = path.join(root, relative);
  writeFileSync(absolute, text, "utf8");
  return absolute;
};

const gabbyID = "11111111-1111-4111-8111-111111111111";
const acmeID = "22222222-2222-4222-8222-222222222222";
const launchID = "33333333-3333-4333-8333-333333333333";
const files = [
  write("gabby.org2", `#+title: Gabby
#+ORG2_ENTITY_TYPE: person
:PROPERTIES:
:ID: ${gabbyID}
:END:
`),
  write("2026-08-18-gabby-sync.org2", `#+title: Meeting: Gabby sync
#+ORG2_KIND: meeting
[[id:${gabbyID}][Gabby]]

* TODO Gate OSS popularity leaderboard
* DONE Send meeting recap
CLOSED: [2026-08-18 Tue]
* DONE Old completed item
CLOSED: [2026-05-01 Fri]
* CANCELED Abandoned item
`),
  write("direct-actions.org2", `#+title: Direct actions

* IN_PROGRESS Confirm speaker plan with [[id:${gabbyID}][Gabby]]
DEADLINE: <2026-08-20 Thu>
* TODO Send contract details
:PROPERTIES:
:ASSIGNEE: Gabby
:END:
* DONE Directly completed with [[id:${gabbyID}][Gabby]]
CLOSED: [2026-08-10 Mon]
`),
  write("unrelated.org2", `#+title: Meeting: Other sync
#+ORG2_KIND: meeting

* TODO One task for [[id:${gabbyID}][Gabby]]
* TODO Unrelated task
`),
  write("mixed-meetings.org2", `#+title: Meeting notes

* Meeting: Gabby planning
[[id:${gabbyID}][Gabby]]
** TODO Scoped meeting action
* Meeting: Other planning
** TODO Must not leak from sibling meeting
`),
  write("acme.org2", `#+title: Acme
:PROPERTIES:
:ID: ${acmeID}
:ORG2_ENTITY_TYPE: company
:END:
`),
  write("launch.org2", `#+title: Launch
:PROPERTIES:
:ID: ${launchID}
:ORG2_ENTITY_TYPE: project
:END:
`),
  write("entity-actions.org2", `#+title: Entity actions

* TODO Renew Acme contract
:PROPERTIES:
:COMPANY: Acme
:END:
* TODO Prepare launch checklist
:PROPERTIES:
:PROJECT: [[id:${launchID}][Launch]]
:END:
* TODO Different customer action
:PROPERTIES:
:COMPANY: Other Co
:END:
`),
  write("2026-08-19-acme-sync.org2", `#+title: Meeting: Acme sync
#+ORG2_KIND: meeting
[[id:${acmeID}][Acme]]

* TODO Send Acme rollout dates
`),
];

const corpus = compileCorpus(files, { rootDir: root });
const payload = queryNodeActions(corpus, {
  object: `id:${gabbyID}`,
  today: "2026-08-19",
  recentDays: 30,
  openLimit: 8,
  completedLimit: 4,
});

assert.equal(payload.$schema, "org2:node-actions:v1");
assert.equal(payload.target.title, "Gabby");
assert.deepEqual(payload.counts, { open: 5, recentlyCompleted: 2 });
assert.deepEqual(payload.open.map((item) => item.title), [
  `Confirm speaker plan with [[id:${gabbyID}][Gabby]]`,
  "Send contract details",
  `One task for [[id:${gabbyID}][Gabby]]`,
  "Gate OSS popularity leaderboard",
  "Scoped meeting action",
]);
assert.equal(payload.open[0].relationship, "direct");
assert.equal(payload.open[0].date, "2026-08-20");
assert.equal(payload.open[3].relationship, "meeting");
assert.equal(payload.open[3].meeting?.title, "Gabby sync");
assert.deepEqual(payload.recentlyCompleted.map((item) => item.title), [
  "Send meeting recap",
  `Directly completed with [[id:${gabbyID}][Gabby]]`,
]);
assert.ok(!payload.open.some((item) => item.title === "Unrelated task"));
assert.ok(!payload.open.some((item) => item.title === "Must not leak from sibling meeting"));
assert.ok(!payload.recentlyCompleted.some((item) => item.title === "Old completed item"));
assert.ok(!payload.recentlyCompleted.some((item) => item.title === "Abandoned item"));

const companyPayload = queryNodeActions(corpus, {
  object: `id:${acmeID}`,
  today: "2026-08-19",
  recentDays: 30,
  openLimit: 8,
  completedLimit: 4,
});
assert.equal(companyPayload.target.entityType, "company");
assert.deepEqual(companyPayload.open.map((item) => item.title), [
  "Renew Acme contract",
  "Send Acme rollout dates",
]);
assert.equal(companyPayload.open[0].relationship, "direct");
assert.equal(companyPayload.open[1].relationship, "meeting");
assert.ok(!companyPayload.open.some((item) => item.title === "Different customer action"));

const projectPayload = queryNodeActions(corpus, {
  object: `id:${launchID}`,
  today: "2026-08-19",
  recentDays: 30,
  openLimit: 8,
  completedLimit: 4,
});
assert.equal(projectPayload.target.entityType, "project");
assert.deepEqual(projectPayload.open.map((item) => item.title), [
  "Prepare launch checklist",
]);
assert.equal(projectPayload.open[0].relationship, "direct");

const cli = spawnSync(process.execPath, [
  path.resolve("dist/cli.js"),
  "query",
  "actions",
  "--object",
  `id:${gabbyID}`,
  "--dir",
  root,
  "--recursive",
  "--open-limit",
  "1",
  "--completed-limit",
  "1",
  "--format",
  "json",
], {
  cwd: path.resolve("."),
  encoding: "utf8",
  env: { ...process.env, ORG2_TODAY: "2026-08-19" },
});
assert.equal(cli.status, 0, cli.stderr);
const cliPayload = JSON.parse(cli.stdout);
assert.deepEqual(cliPayload.counts, { open: 5, recentlyCompleted: 2 });
assert.equal(cliPayload.open.length, 1);
assert.equal(cliPayload.recentlyCompleted.length, 1);

console.log("node action query tests passed");

const customWorkflow = write("custom-workflow.org", `#+TODO: TODO missed | DONE SHIPPED
* missed Follow up with [[id:${gabbyID}][Gabby]]
* SHIPPED Delivered for [[id:${gabbyID}][Gabby]]
CLOSED: [2026-08-19 Wed]
* CANCELED Abandoned for [[id:${gabbyID}][Gabby]]
CLOSED: [2026-08-19 Wed]
`);
const customActions = queryNodeActions(compileCorpus([files[0], customWorkflow], { rootDir: root }), {
  object: `id:${gabbyID}`, today: "2026-08-19", recentDays: 30, openLimit: 8, completedLimit: 4,
});
assert.deepEqual(customActions.open.map(item => item.todo), ["missed"]);
assert.deepEqual(customActions.recentlyCompleted.map(item => item.todo), ["SHIPPED"]);
