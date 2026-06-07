#!/usr/bin/env node

import assert from 'node:assert/strict';
import {
  GmailFixtureConnector,
  MessageThreadFixtureConnector,
  applyCapturePolicy,
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


const messages = new MessageThreadFixtureConnector();
const messageRecords = messages.ingest({ threads: [
  { service: 'whatsapp', conversationId: 'chat-1', conversationTitle: 'Scarf plans', participants: ['avi', '+15551234567'], group: false, messages: [
    { id: 'm1', timestamp: '2024-04-03T13:00:00Z', sender: '+15551234567', text: 'Can you follow up on the Scarf pilot tomorrow?', sensitivity: 'private' },
    { id: 'm2', timestamp: '2024-04-03T13:05:00Z', sender: 'avi', text: 'Yes, TODO: send the pilot recap.' },
  ] },
  { service: 'imessage', conversationId: 'chat-2', conversationTitle: 'Old thread', participants: ['avi', 'friend'], messages: [
    { id: 'm3', timestamp: '2023-01-01T13:00:00Z', sender: 'friend', text: 'Too old.' },
  ] },
] }, { since: '2024-04-01T00:00:00Z', allowlist: ['Scarf plans'], limit: 10 });
assert.equal(messageRecords.length, 2);
assert.equal(messageRecords[0].source.kind, 'message');
assert.equal(messageRecords[0].source.service, 'whatsapp');
assert.equal(messageRecords[0].source.conversationId, 'chat-1');
assert.equal(messageRecords[0].source.conversationTitle, 'Scarf plans');
assert.deepEqual(messageRecords[0].source.participants, ['avi', '+15551234567']);
assert.equal(messageRecords[0].source.group, false);
assert.equal(messageRecords[0].source.author, '+15551234567');
assert.equal(messageRecords[0].source.sensitivity, 'private');
assert.match(messageRecords[0].cursor, /^2024-04-03T13:00:00Z#m1$/);
validateConnectorManifest(messages.manifest);
assert.equal(messages.manifest.auth.mode, 'external');
assert.match(messages.manifest.auth.note, /plugins/);

const messagePolicyPreview = previewConnectorIngest(messages, [
  { service: 'imessage', conversationId: 'chat-3', conversationTitle: 'Allowed', participants: ['avi', 'friend'], id: 'm4', timestamp: '2024-04-07T12:00:00Z', author: 'friend', text: 'Please call me at 555-1212.' },
  { service: 'whatsapp', conversationId: 'chat-4', conversationTitle: 'Denied', participants: ['avi', 'unknown'], id: 'm5', timestamp: '2024-04-07T13:00:00Z', author: 'unknown', text: 'Ignore.' },
], { policy: { sourceAllowlist: ['message'], participants: ['friend'], maxCount: 1, sensitiveRedactions: [{ pattern: '\\b\\d{3}-\\d{4}\\b' }] } });
assert.equal(messagePolicyPreview.records.length, 1);
assert.equal(messagePolicyPreview.records[0].id, 'm4');
assert.match(messagePolicyPreview.records[0].text, /\[redacted\]/);
assert.equal(messagePolicyPreview.policyReport.redactedCount, 1);

const gmail = new GmailFixtureConnector();
const gmailRecords = gmail.ingest({ threads: [
  { threadId: 'thr-1', subject: 'Important project thread', messages: [
    { id: 'g1', date: '2024-04-03T12:00:00Z', from: 'avi@example.com', to: ['team@example.com'], labels: ['important', 'project'], unread: true, starred: true, text: 'Follow up: review packet needs redaction.', sensitivity: 'sensitive' },
    { id: 'g1b', date: '2024-04-03T12:30:00Z', from: 'teammate@example.com', to: ['avi@example.com'], labels: ['important'], unread: true, text: 'TODO: confirm retention policy before importing more mail.' },
  ] },
  { threadId: 'thr-2', subject: 'Old mail', messages: [
    { id: 'g2', date: '2023-01-01T12:00:00Z', from: 'old@example.com', to: ['team@example.com'], labels: ['important'], text: 'Too old.' },
  ] },
] }, { since: '2024-04-01T00:00:00Z', labels: ['important'], domains: ['example.com'], unread: true, limit: 10 });
assert.equal(gmailRecords.length, 2);
assert.equal(gmailRecords[0].source.kind, 'gmail');
assert.equal(gmailRecords[0].source.label, 'important');
assert.deepEqual(gmailRecords[0].source.labels, ['important', 'project']);
assert.equal(gmailRecords[0].source.threadId, 'thr-1');
assert.equal(gmailRecords[0].source.subject, 'Important project thread');
assert.equal(gmailRecords[0].source.unread, true);
assert.equal(gmailRecords[0].source.starred, true);
assert.equal(gmailRecords[0].source.sensitivity, 'sensitive');
assert.match(gmailRecords[0].cursor, /^2024-04-03T12:00:00Z#g1$/);
validateConnectorManifest(gmail.manifest);

const starredFromAvi = gmail.ingest([
  { id: 'g4', subject: 'From Avi', date: '2024-04-06T12:00:00Z', from: 'avi@example.com', to: ['team@example.com'], labels: ['inbox'], starred: true, text: 'Please review the draft.' },
  { id: 'g5', subject: 'From someone else', date: '2024-04-06T12:05:00Z', from: 'other@example.net', to: ['team@example.com'], labels: ['inbox'], starred: true, text: 'Ignore.' },
], { senders: ['avi@example.com'], starred: true });
assert.equal(starredFromAvi.length, 1);
assert.equal(starredFromAvi[0].id, 'g4');

const privacyPreview = previewConnectorIngest(gmail, [
  { id: 'g3', subject: 'Private mail', date: '2024-04-05T12:00:00Z', from: 'avi@example.com', to: ['team@example.com'], labels: ['important'], text: 'Private import candidate.', sensitivity: 'private' },
], { privacyPolicy: 'skip-private' });
assert.equal(privacyPreview.records.length, 0);
assert.equal(privacyPreview.skipped[0].reason, 'privacy-policy');


const policyPreview = previewConnectorIngest(gmail, [
  { id: 'g6', subject: 'Allowed', date: '2024-04-07T12:00:00Z', from: 'avi@example.com', to: ['team@example.com'], labels: ['inbox'], text: 'Please call me at 555-1212 about Scarf.' },
  { id: 'g7', subject: 'Denied domain', date: '2024-04-07T13:00:00Z', from: 'spam@example.net', to: ['team@example.com'], labels: ['inbox'], text: 'Ignore.' },
], { policy: { sourceAllowlist: ['gmail'], domains: ['example.com'], maxCount: 1, sensitiveRedactions: [{ pattern: '\\b\\d{3}-\\d{4}\\b' }] } });
assert.equal(policyPreview.records.length, 1);
assert.equal(policyPreview.records[0].id, 'g6');
assert.match(policyPreview.records[0].text, /\[redacted\]/);
assert.equal(policyPreview.policyReport.acceptedCount, 1);
assert.equal(policyPreview.policyReport.redactedCount, 1);
assert.equal(policyPreview.policyReport.defaultReviewStatus, 'review-required');
assert.equal(policyPreview.skipped.some((item) => item.id === 'g7' && item.reason === 'capture-policy'), true);

const directPolicy = applyCapturePolicy(slackRecords, { sourceDenylist: ['gmail'], maxCount: 1 }, { dryRun: true });
assert.equal(directPolicy.records.length, 1);
assert.equal(directPolicy.report.dryRun, true);

const rawInputs = connectorRecordsToRawCaptureInputs([...slackRecords, ...messageRecords, ...gmailRecords], '2024-04-04T00:00:00Z');
assert.equal(rawInputs[0].sourceType, 'slack');
assert.equal(rawInputs[0].externalId, 's1');
assert.equal(rawInputs[0].sourceRef, 'https://slack.example/1');
assert.equal(rawInputs[1].sourceType, 'message');
assert.equal(rawInputs[1].sensitivity, 'private');
assert.equal(rawInputs[3].sensitivity, 'restricted');

const artifact = renderIngestReviewArtifact([...slackRecords, ...messageRecords, ...gmailRecords], { title: 'Scoped import review', generatedAt: '2024-04-04T00:00:00Z' });
assert.match(artifact, /#\+TITLE: Scoped import review/);
assert.match(artifact, /:ORG2_REVIEW_STATUS: review-required/);
assert.match(artifact, /:ORG2_SOURCE_KIND: slack/);
assert.match(artifact, /:ORG2_SOURCE_KIND: gmail/);
assert.match(artifact, /:ORG2_SOURCE_KIND: message/);
assert.match(artifact, /:ORG2_MESSAGE_SERVICE: whatsapp/);
assert.match(artifact, /:ORG2_MESSAGE_CONVERSATION_ID: chat-1/);
assert.match(artifact, /:ORG2_MESSAGE_PARTICIPANTS: avi,\+15551234567/);
assert.match(artifact, /Generated candidates \(review required\)/);
assert.match(artifact, /TODO candidate: gmail:g1b/);
assert.match(artifact, /:ORG2_EMAIL_THREAD_ID: thr-1/);
assert.match(artifact, /:ORG2_SENSITIVITY: sensitive/);
assert.match(artifact, /Redact private\/sensitive details before promotion/);

console.log('✓ agent ingest connectors');
