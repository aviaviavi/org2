import assert from 'node:assert/strict';
import { lintArtifactMetadataInText } from './dist/artifactLint.js';
import {
  buildGeneratedArtifactMetadata,
  formatOrg2ArtifactPropertyDrawer,
  formatSourceHashEntry,
} from './dist/artifactMetadata.js';

const sourceHash = {
  kind: 'file',
  value: 'notes/project.org2',
  sha256: 'a'.repeat(64),
};

const metadata = buildGeneratedArtifactMetadata({
  role: 'view',
  generator: 'org2 query --format org',
  generatedAt: '2026-05-19T23:04:00Z',
  provenance: ['id:project-alpha', 'query:todo-status-open', 'id:project-alpha'],
  sourceHashes: [sourceHash],
  reviewStatus: 'review-required',
});

assert.equal(metadata.schemaVersion, 'org2-artifact-metadata/v1');
assert.deepEqual(metadata.provenance, ['id:project-alpha', 'query:todo-status-open']);
assert.equal(formatSourceHashEntry(sourceHash), `file:notes/project.org2=sha256:${'a'.repeat(64)}`);

const drawer = formatOrg2ArtifactPropertyDrawer(metadata, 'project-alpha-dashboard');
assert.match(drawer, /:ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata\/v1/);
assert.match(drawer, /:ORG2_ARTIFACT_ROLE: view/);
assert.match(drawer, /:ORG2_SOURCE_HASHES: file:notes\/project\.org2=sha256:a{64}/);
assert.match(drawer, /:ORG2_REVIEW_STATUS: review-required/);
const generatedIssues = lintArtifactMetadataInText(drawer, 'views/dashboard.org2');
assert.ok(generatedIssues.some((issue) => issue.rule === 'artifact-generated-unreviewed'));
assert.ok(generatedIssues.every((issue) => issue.severity === 'warning'));

const invalid = `:PROPERTIES:
:ID: bad-dashboard
:ORG2_ARTIFACT_ROLE: report
:ORG2_PROVENANCE: id:project-alpha
:ORG2_GENERATOR: org2 query --format org
:ORG2_GENERATED_AT: 2026-05-19T23:04:00Z
:ORG2_SOURCE_HASHES: file:notes/project.org2=sha256:not-a-hash
:ORG2_REVIEW_STATUS: unchecked
:END:
`;
const issues = lintArtifactMetadataInText(invalid, 'views/bad.org2');
assert.ok(issues.some((issue) => issue.rule === 'artifact-source-hash-entry-invalid'));
assert.ok(issues.some((issue) => issue.rule === 'artifact-review-status-invalid'));

console.log('✓ artifact-metadata');
