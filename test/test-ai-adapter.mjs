#!/usr/bin/env node

import assert from "node:assert/strict";
import {
  MockAiAdapter,
  createAiAdapterRequest,
  normalizeAiAdapterResponse,
} from "../dist/aiAdapter.js";

const request = createAiAdapterRequest({
  jobId: "weekly-summary",
  task: {
    type: "summarize-meeting",
    template: "weekly-summary@v1",
    instructions: "Summarize decisions with citations.",
  },
  prompt: [
    { role: "system", content: "Use only the supplied Org2 context." },
    { role: "user", content: "Create a weekly summary." },
  ],
  context: [
    {
      id: "meeting-1",
      type: "org-headline",
      title: "Team Sync",
      text: "Decision: ship the adapter interface first.",
      sourceRefs: [{ file: "notes/team.org", id: "abc", line: 12, endLine: 16 }],
    },
    {
      id: "meeting-2",
      type: "raw-transcript",
      text: "Follow-up: add the mock adapter test.",
      sourceRefs: [{ file: "raw/transcripts/team.org", line: 3 }],
    },
  ],
  output: { contentType: "text+json", schemaHint: "weekly-summary@v1" },
  provenance: { requireSourceRefs: true, promptTemplateVersion: "weekly-summary@v1" },
});

const mock = new MockAiAdapter({ name: "local-test", model: "deterministic-v1" });
const response = await mock.generate(request);
assert.equal(response.schema, "org2:ai-adapter-response:v1");
assert.equal(response.metadata.adapterName, "local-test");
assert.equal(response.metadata.model, "deterministic-v1");
assert.equal(response.metadata.provider, "mock");
assert.match(response.text, /summarize-meeting/);
assert.deepEqual(response.json, { taskType: "summarize-meeting", contextCount: 2 });
assert.equal(response.citations.length, 2);

assert.equal(mock.requests.length, 1);
assert.equal(mock.requests[0].schema, "org2:ai-adapter-request:v1");
assert.equal(mock.requests[0].context[0].sourceRefs[0].file, "notes/team.org");

// Recorded requests are defensive copies, so tests can inspect them without mutating adapter state.
mock.requests[0].context[0].text = "mutated outside adapter";
assert.equal(mock.requests[0].context[0].text, "Decision: ship the adapter interface first.");

const custom = new MockAiAdapter({
  name: "custom-mock",
  model: "json-v1",
  responder: (input, callIndex) => ({
    schema: "org2:ai-adapter-response:v1",
    json: { callIndex, jobId: input.jobId, promptCount: input.prompt.length },
    metadata: { adapterName: "placeholder", model: "placeholder" },
  }),
});
const customResponse = await custom.generate(request);
assert.deepEqual(customResponse.json, { callIndex: 0, jobId: "weekly-summary", promptCount: 2 });
assert.equal(customResponse.metadata.adapterName, "custom-mock");
assert.equal(customResponse.metadata.model, "json-v1");

const normalized = normalizeAiAdapterResponse("future-provider", "model-profile", { text: "ok" });
assert.equal(normalized.schema, "org2:ai-adapter-response:v1");
assert.equal(normalized.metadata.adapterName, "future-provider");
assert.equal(normalized.metadata.model, "model-profile");
assert.equal(normalized.text, "ok");

console.log("AI adapter interface tests passed");
