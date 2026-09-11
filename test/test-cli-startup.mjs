import assert from 'node:assert/strict';
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

// Inspect loaded code rather than relying on machine-specific startup timings.
// These commands must keep working without loading the document/agenda CLI.
for (const args of [['version'], ['agent', 'capabilities'], ['workflow', '--help'], ['server', '--help']]) {
  const coverage = mkdtempSync(join(tmpdir(), 'org2-cli-startup-'));
  try {
    const result = spawnSync(process.execPath, ['dist/cli.js', ...args], {
      cwd: resolve('.'), encoding: 'utf8', timeout: 30_000,
      env: { ...process.env, NODE_V8_COVERAGE: coverage },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.stdout.trim(), `No output for ${args.join(' ')}`);
    const loaded = readdirSync(coverage).filter(file => file.endsWith('.json')).flatMap(file =>
      JSON.parse(readFileSync(join(coverage, file), 'utf8')).result.map(script => script.url));
    assert.ok(loaded.some(url => url.endsWith('/dist/cli.js')));
    assert.ok(!loaded.some(url => url.endsWith('/dist/cliMain.js')), `${args.join(' ')} loaded the full CLI`);
    if (args[0] === 'agent') {
      assert.equal(JSON.parse(result.stdout).$schema, 'org2:capabilities:v1');
      assert.ok(!loaded.some(url => url.endsWith('/dist/parser.js')), 'Capabilities loaded the parser');
    }
  } finally {
    rmSync(coverage, { recursive: true, force: true });
  }
}
console.log('CLI command-family lazy loading passed');
