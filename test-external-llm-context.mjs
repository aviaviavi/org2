#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { formatOrg2QueryContext } from './examples/external-llm-context.mjs';

const repo = path.dirname(fileURLToPath(import.meta.url));
const payload = {
  query: 'hosted AI integration',
  results: [
    {
      file: '/tmp/corpus/notes/project-alpha.org2',
      heading: 'Project Alpha',
      line: 12,
      lineEnd: 12,
      sourceRange: { startLine: 12, endLine: 14 },
      context: {
        lines: [
          '* Project Alpha',
          'Ship the local compiler path before hosted AI integration.',
          'External agents may synthesize answers from cited Org2 query output.'
        ]
      }
    },
    {
      file: '/tmp/corpus/notes/project-beta.org2',
      heading: 'Project Beta',
      line: 22,
      snippet: 'Keep provider calls outside Org2 core.'
    }
  ]
};

const formatted = formatOrg2QueryContext(payload, { limit: 1 });
assert.match(formatted, /# Org2 cited context packet/);
assert.match(formatted, /Use only the evidence below/);
assert.match(formatted, /\[S1\] Project Alpha/);
assert.match(formatted, /Citation: \/tmp\/corpus\/notes\/project-alpha.org2:12-14/);
assert.match(formatted, /Ship the local compiler path before hosted AI integration/);
assert.doesNotMatch(formatted, /Project Beta/);

const cli = spawnSync(process.execPath, [path.join(repo, 'examples/external-llm-context.mjs'), '--limit=2'], {
  input: JSON.stringify(payload),
  encoding: 'utf8'
});
assert.equal(cli.status, 0, cli.stderr);
assert.match(cli.stdout, /\[S2\] Project Beta/);
assert.match(cli.stdout, /Citation: \/tmp\/corpus\/notes\/project-beta.org2:22/);
assert.match(cli.stdout, /Keep provider calls outside Org2 core/);

const bad = spawnSync(process.execPath, [path.join(repo, 'examples/external-llm-context.mjs')], {
  input: 'not json',
  encoding: 'utf8'
});
assert.equal(bad.status, 1);
assert.match(bad.stderr, /Expected org2 query --format json/);

console.log('external LLM context formatter tests passed');
