#!/usr/bin/env node

import assert from 'node:assert/strict';
import {
  GmailFixtureConnector,
  SlackFixtureConnector,
  connectorRecordsToRawCaptureInputs,
  previewConnectorIngest,
  renderIngestReviewArtifact,
  validateConnectorManifest,
} from './dist/agentIngestConnectors.js';

const slack = new SlackFixtureConnector();
const slackRecords = slack.ingest({ messages: [
  { id: 's1', workspace: 'scarf', channel: 'proj-alpha', thread_ts: '1712167200.000000', user: 'U1', text: 'Decision: ship scoped ingestion first.', permalink: 'https://slack.example/1' },
  { id: 's2', workspace: 'scarf', channel: 'random', thread_ts: '1712167300.000000', user: 'U2', text: 'Out of scope.', permalink: 'https://slack.example/2' },
] }, { since: '2024-04-01T00:00:00Z', until: '2024-05-01T00:00:00Z', allowlist: ['proj-alpha'], limit: 10 });
assert.equal(slackRecords.length, 1);
assert.equal(slackRecords[0].source.kind, 'slack');
assert.equal(slackRecords[0].source.channel, 'proj-alpha');
assert.equal(slackRecords[0].text, 'Decision: ship scoped ingestion first.');
validateConnectorManifest(slack.manifest);
assert.equal(slack.manifest.auth.mode, 'external');
assert.equal(slack.manifest.capabilities.incrementalSync, true);

const slackPreview = previewConnectorIngest(slack, { messages: [
  { id: 's1', workspace: 'scarf', channel: 'proj-alpha', thread_ts: '1712167200.000000', user: 'U1', text: 'Decision: ship scoped ingestion first.', permalink: 'https://slack.example/1' },
  { id: 's3', workspace: 'scarf', channel: 'proj-alpha', thread_ts: '1712167400.000000', user: 'U3', text: 'Decision: ship scoped ingestion first.', permalink: 'https://slack.example/3' },
] }, { seenSourceIds: ['slack:s1'] });
assert.equal(slackPreview.records.length, 1);
assert.equal(slackPreview.records[0].id, 's3');
assert.equal(slackPreview.skipped[0].reason, 'duplicate-source-id');


const gmail = new GmailFixtureConnector();
const gmailRecords = gmail.ingest([
  { id: 'g1', subject: 'Important project thread', date: '2024-04-03T12:00:00Z', from: 'avi@example.com', to: ['team@example.com'], labels: ['important'], text: 'Follow up: review packet needs redaction.', sensitivity: 'sensitive' },
  { id: 'g2', subject: 'Old mail', date: '2023-01-01T12:00:00Z', from: 'old@example.com', to: ['team@example.com'], labels: ['important'], text: 'Too old.' },
], { since: '2024-04-01T00:00:00Z', allowlist: ['important'] });
assert.equal(gmailRecords.length, 1);
assert.equal(gmailRecords[0].source.kind, 'gmail');
assert.equal(gmailRecords[0].source.label, 'important');
assert.equal(gmailRecords[0].source.sensitivity, 'sensitive');
validateConnectorManifest(gmail.manifest);

const privacyPreview = previewConnectorIngest(gmail, [
  { id: 'g3', subject: 'Private mail', date: '2024-04-05T12:00:00Z', from: 'avi@example.com', to: ['team@example.com'], labels: ['important'], text: 'Private import candidate.', sensitivity: 'private' },
], { privacyPolicy: 'skip-private' });
assert.equal(privacyPreview.records.length, 0);
assert.equal(privacyPreview.skipped[0].reason, 'privacy-policy');

const rawInputs = connectorRecordsToRawCaptureInputs([...slackRecords, ...gmailRecords], '2024-04-04T00:00:00Z');
assert.equal(rawInputs[0].sourceType, 'slack');
assert.equal(rawInputs[0].externalId, 's1');
assert.equal(rawInputs[0].sourceRef, 'https://slack.example/1');
assert.equal(rawInputs[1].sensitivity, 'restricted');

const artifact = renderIngestReviewArtifact([...slackRecords, ...gmailRecords], { title: 'Scoped import review', generatedAt: '2024-04-04T00:00:00Z' });
assert.match(artifact, /#\+TITLE: Scoped import review/);
assert.match(artifact, /:ORG2_REVIEW_STATUS: review-required/);
assert.match(artifact, /:ORG2_SOURCE_KIND: slack/);
assert.match(artifact, /:ORG2_SOURCE_KIND: gmail/);
assert.match(artifact, /:ORG2_SENSITIVITY: sensitive/);
assert.match(artifact, /Redact private\/sensitive details before promotion/);

console.log('✓ agent ingest connectors');
