#!/usr/bin/env node
import fs from 'node:fs';

function readStdin() {
  return fs.readFileSync(0, 'utf8');
}

function parseLimit(argv) {
  const raw = argv.find((arg) => arg.startsWith('--limit='));
  if (!raw) return 8;
  const value = Number.parseInt(raw.slice('--limit='.length), 10);
  return Number.isFinite(value) && value > 0 ? value : 8;
}

function basename(file) {
  return String(file || '').split(/[\\/]/).filter(Boolean).pop() || String(file || 'unknown');
}

function citationFor(result) {
  const file = result.file || 'unknown';
  const range = result.sourceRange || {};
  const start = Number.isInteger(range.startLine) ? range.startLine : result.line;
  const end = Number.isInteger(range.endLine) ? range.endLine : result.lineEnd || start;
  const suffix = start && end && start !== end ? `${start}-${end}` : `${start || '?'}`;
  return `${file}:${suffix}`;
}

function textFor(result) {
  if (typeof result.answerContext === 'string' && result.answerContext.trim()) {
    return result.answerContext.trim();
  }
  if (result.context && Array.isArray(result.context.lines) && result.context.lines.length > 0) {
    return result.context.lines.join('\n').trim();
  }
  return String(result.snippet || '').trim();
}

export function formatOrg2QueryContext(payload, options = {}) {
  const limit = options.limit ?? 8;
  const results = Array.isArray(payload?.results) ? payload.results.slice(0, limit) : [];
  const lines = [];

  lines.push('# Org2 cited context packet');
  lines.push('');
  lines.push('Use only the evidence below. Preserve citations as [S1], [S2], etc. If the evidence is insufficient, say so.');
  lines.push('');
  lines.push(`Query: ${payload?.query || '(unknown)'}`);
  lines.push(`Results included: ${results.length}`);
  lines.push('');

  results.forEach((result, index) => {
    const id = `S${index + 1}`;
    const title = result.heading || basename(result.file);
    lines.push(`[${id}] ${title}`);
    lines.push(`Citation: ${citationFor(result)}`);
    const text = textFor(result);
    if (text) {
      lines.push('Context:');
      lines.push(text);
    } else {
      lines.push('Context: (empty)');
    }
    lines.push('');
  });

  lines.push('Answer format:');
  lines.push('- Direct answer with inline source markers like [S1].');
  lines.push('- Short caveats when sources disagree or context is missing.');
  return `${lines.join('\n').trimEnd()}\n`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const input = readStdin();
  let payload;
  try {
    payload = JSON.parse(input);
  } catch (error) {
    console.error(`Expected org2 query --format json on stdin: ${error.message}`);
    process.exit(1);
  }
  process.stdout.write(formatOrg2QueryContext(payload, { limit: parseLimit(process.argv.slice(2)) }));
}
