const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Registry, parseRawGrammar } = require('vscode-textmate');
const oniguruma = require('vscode-oniguruma');

function fakeGrammar(scopeName) {
  return {
    scopeName,
    patterns: [{ include: '#main' }],
    repository: {
      main: {
        patterns: [
          { name: `${scopeName}.const-token`, match: '\\bconst\\b' },
          { name: `${scopeName}.identifier`, match: '\\b[a-zA-Z_][a-zA-Z0-9_]*\\b' }
        ]
      }
    }
  };
}

async function createRegistry() {
  const wasmPath = require.resolve('vscode-oniguruma/release/onig.wasm');
  const wasmBin = fs.readFileSync(wasmPath).buffer;
  await oniguruma.loadWASM(wasmBin);

  const orgGrammarPath = path.join(__dirname, '..', 'syntaxes', 'org2.tmLanguage.json');
  const orgGrammar = fs.readFileSync(orgGrammarPath, 'utf8');

  const registry = new Registry({
    onigLib: Promise.resolve({
      createOnigScanner(patterns) {
        return new oniguruma.OnigScanner(patterns);
      },
      createOnigString(s) {
        return new oniguruma.OnigString(s);
      }
    }),
    loadGrammar: async (scopeName) => {
      if (scopeName === 'source.org2') return parseRawGrammar(orgGrammar, orgGrammarPath);
      if (scopeName === 'source.python') return parseRawGrammar(JSON.stringify(fakeGrammar(scopeName)), `${scopeName}.json`);
      if (scopeName === 'source.shell') return parseRawGrammar(JSON.stringify(fakeGrammar(scopeName)), `${scopeName}.json`);
      if (scopeName === 'source.yaml') return parseRawGrammar(JSON.stringify(fakeGrammar(scopeName)), `${scopeName}.json`);
      return null;
    }
  });

  return registry;
}

test('fenced code blocks and #+begin_src aliases get equivalent tokenization', async () => {
  const fixturePath = path.join(__dirname, 'fixtures', 'fenced-src-parity.org2');
  const lines = fs.readFileSync(fixturePath, 'utf8').split(/\r?\n/);
  const registry = await createRegistry();
  const grammar = await registry.loadGrammar('source.org2');

  let ruleStack = null;
  const scopedByLine = [];
  for (const line of lines) {
    const result = grammar.tokenizeLine(line, ruleStack);
    scopedByLine.push(result.tokens.map((t) => t.scopes));
    ruleStack = result.ruleStack;
  }

  const pySrcScopes = scopedByLine[3].flat();
  const pyFenceScopes = scopedByLine[7].flat();
  assert(pySrcScopes.some((s) => s.includes('source.python.const-token')));
  assert(pyFenceScopes.some((s) => s.includes('source.python.const-token')));

  const shellSrcScopes = scopedByLine[11].flat();
  const shellFenceScopes = scopedByLine[15].flat();
  assert(shellSrcScopes.some((s) => s.includes('source.shell.const-token')));
  assert(shellFenceScopes.some((s) => s.includes('source.shell.const-token')));

  const unknownSrcScopes = scopedByLine[19].flat();
  const unknownFenceScopes = scopedByLine[23].flat();
  assert(unknownSrcScopes.includes('markup.bold.org2'));
  assert(unknownFenceScopes.includes('markup.bold.org2'));
});

test('unlabeled fenced and #+begin_src blocks use default embedded grammar scopes', async () => {
  const fixturePath = path.join(__dirname, 'fixtures', 'unlabeled-src-fence-default.org2');
  const lines = fs.readFileSync(fixturePath, 'utf8').split(/\r?\n/);
  const registry = await createRegistry();
  const grammar = await registry.loadGrammar('source.org2');

  let ruleStack = null;
  const scopedByLine = [];
  for (const line of lines) {
    const result = grammar.tokenizeLine(line, ruleStack);
    scopedByLine.push(result.tokens.map((t) => t.scopes));
    ruleStack = result.ruleStack;
  }

  const unlabeledFenceScopes = scopedByLine[3].flat();
  const unlabeledSrcScopes = scopedByLine[7].flat();

  assert(unlabeledFenceScopes.some((s) => s.includes('source.yaml.const-token')));
  assert(unlabeledSrcScopes.some((s) => s.includes('source.yaml.const-token')));
});

test('timestamp repeaters and warnings stay within timestamp syntax highlighting', async () => {
  const registry = await createRegistry();
  const grammar = await registry.loadGrammar('source.org2');
  const line = 'SCHEDULED: <2026-05-20 Wed ++1w --2d> DEADLINE: [2026-05-21 Thu .+2d -1w]';
  const result = grammar.tokenizeLine(line, null);

  for (const fragment of ['++1w', '--2d', '.+2d', '-1w']) {
    const token = result.tokens.find((candidate) => {
      const tokenText = line.slice(candidate.startIndex, candidate.endIndex);
      return tokenText.includes(fragment);
    });

    assert(token, `expected token containing ${fragment}`);
    assert(
      token.scopes.includes('constant.other.timestamp.org2') || token.scopes.includes('string.other.timestamp.org2'),
      `expected timestamp scope for ${fragment}`
    );
  }
});

test('headline TODO aliases still receive TODO keyword syntax highlighting', async () => {
  const registry = await createRegistry();
  const grammar = await registry.loadGrammar('source.org2');
  const lines = [
    '* OPEN Inbox capture',
    '* BACKLOG Later maybe',
    '* BLOCKED Waiting on review',
    '* PAUSED On ice',
    '* COMPLETED Wrapped up',
    '* FINISHED Wrapped up for real',
    '* CLOSED Duplicate path',
    '* RESOLVED Fixed elsewhere',
    '* CANCELED Duplicate',
  ];

  for (const line of lines) {
    const keyword = line.split(/\s+/)[1];
    const result = grammar.tokenizeLine(line, null);
    const keywordToken = result.tokens.find((token) => line.slice(token.startIndex, token.endIndex) === keyword);

    assert(keywordToken, `expected token for ${keyword}`);
    assert(keywordToken.scopes.includes('keyword.other.todo.org2'), `expected TODO scope for ${keyword}`);
  }
});
