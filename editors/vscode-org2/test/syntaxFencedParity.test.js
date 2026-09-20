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
      // Generic fallback so any embedded `source.*` grammar referenced by org2.tmLanguage.json
      // resolves to a minimal-but-real grammar instead of null, letting tests assert that an
      // `include` actually fired (as opposed to silently no-opping).
      if (scopeName.startsWith('source.')) return parseRawGrammar(JSON.stringify(fakeGrammar(scopeName)), `${scopeName}.json`);
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

test('checkbox progress cookies receive progress-cookie syntax highlighting', async () => {
  const registry = await createRegistry();
  const grammar = await registry.loadGrammar('source.org2');
  const line = '- [ ] Project [1/3] [33%] [/] [%]';
  const result = grammar.tokenizeLine(line, null);

  for (const fragment of ['[1/3]', '[33%]', '[/]', '[%]']) {
    const token = result.tokens.find((candidate) => line.slice(candidate.startIndex, candidate.endIndex) === fragment);
    assert(token, `expected token for ${fragment}`);
    assert(token.scopes.includes('constant.other.progress-cookie.org2'), `expected progress-cookie scope for ${fragment}`);
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

test('headline tags support shared colons and trailing whitespace without consuming the title', async () => {
  const registry = await createRegistry();
  const grammar = await registry.loadGrammar('source.org2');
  const cases = [
    ['* Title :work:', ':work:'],
    ['** TODO Title :work:   ', ':work:'],
    ['*** Title :work:urgent:', ':work:urgent:'],
    ['******* Title :one:two:three:  ', ':one:two:three:'],
  ];

  for (const [line, tags] of cases) {
    const result = grammar.tokenizeLine(line, null);
    const titleIndex = line.indexOf('Title');
    const tagIndex = line.indexOf(tags);
    const titleToken = result.tokens.find((token) => token.startIndex <= titleIndex && token.endIndex > titleIndex);
    const tagToken = result.tokens.find((token) => token.startIndex <= tagIndex && token.endIndex > tagIndex);
    assert(titleToken?.scopes.includes('entity.name.section.org2'), `expected headline title scope for ${line}`);
    assert(!titleToken?.scopes.includes('entity.other.attribute-name.tag.org2'), `title was consumed as a tag for ${line}`);
    assert(tagToken?.scopes.includes('entity.other.attribute-name.tag.org2'), `expected tag scope for ${tags}`);
    if (line.endsWith(' ')) {
      const trailingToken = result.tokens.find((token) => token.startIndex <= line.length - 1 && token.endIndex > line.length - 1);
      assert(!trailingToken?.scopes.includes('entity.other.attribute-name.tag.org2'), `trailing whitespace was consumed as a tag for ${line}`);
      assert(!trailingToken?.scopes.includes('entity.name.section.org2'), `trailing whitespace was consumed as title text for ${line}`);
    }
  }

  for (const line of ['* Title', '* Namespace: remains title', '* Title :not-a-tag']) {
    const result = grammar.tokenizeLine(line, null);
    assert(!result.tokens.some((token) => token.scopes.includes('entity.other.attribute-name.tag.org2')), `unexpected tag scope for ${line}`);
  }
});

test('table formula lines receive a dedicated expression scope', async () => {
  const registry = await createRegistry();
  const grammar = await registry.loadGrammar('source.org2');
  const line = '#+TBLFM: $4=$2*$3;%.2f::@5$4=vsum(@2$4..@4$4)';
  const result = grammar.tokenizeLine(line, null);
  assert(result.tokens.some((token) => token.scopes.includes('keyword.control.table-formula.org2')));
  assert(result.tokens.some((token) => token.scopes.includes('meta.expression.table-formula.org2')));
});

test('#+begin_src blocks embed their language grammar for every declared language, not just the ones listed before the generic fallback rule', async () => {
  // Regression test: `blocks.patterns` is a flat, order-sensitive list. A generic
  // `#+begin_src <word>` catch-all rule (meta.block.src.org2) used to sit ahead of the
  // haskell/java/c/cpp/csharp/ruby/php/kotlin/swift/scala/lua rules in that array. Since
  // TextMate breaks same-position ties by array order, the catch-all always won for those
  // eleven languages and their `include: source.<lang>` never fired, so their #+begin_src
  // bodies stayed unhighlighted plain text while every other language worked fine.
  const registry = await createRegistry();
  const grammar = await registry.loadGrammar('source.org2');

  const languages = [
    ['haskell', 'meta.block.src.haskell.org2'],
    ['java', 'meta.block.src.java.org2'],
    ['c', 'meta.block.src.c.org2'],
    ['cpp', 'meta.block.src.cpp.org2'],
    ['csharp', 'meta.block.src.csharp.org2', 'cs'], // embeds source.cs, not source.csharp
    ['ruby', 'meta.block.src.ruby.org2'],
    ['php', 'meta.block.src.php.org2'],
    ['kotlin', 'meta.block.src.kotlin.org2'],
    ['swift', 'meta.block.src.swift.org2'],
    ['scala', 'meta.block.src.scala.org2'],
    ['lua', 'meta.block.src.lua.org2'],
  ];

  for (const [lang, expectedBlockScope, embeddedScope] of languages) {
    const embedLang = embeddedScope || lang;
    let ruleStack = null;
    const beginLine = `#+begin_src ${lang}`;
    let result = grammar.tokenizeLine(beginLine, ruleStack);
    ruleStack = result.ruleStack;
    assert(
      result.tokens.some((t) => t.scopes.includes(expectedBlockScope)),
      `expected ${expectedBlockScope} on "${beginLine}", got ${JSON.stringify(result.tokens.map((t) => t.scopes))}`
    );

    const bodyLine = 'placeholder_token';
    result = grammar.tokenizeLine(bodyLine, ruleStack);
    assert(
      result.tokens.some((t) => t.scopes.includes(`source.${embedLang}.identifier`)),
      `expected embedded source.${embedLang} grammar to tokenize the body of a "${lang}" #+begin_src block, got ${JSON.stringify(result.tokens.map((t) => t.scopes))}`
    );
  }
});

test('#+begin_src language aliases route to the right embedded grammar, including symbol-bearing aliases like c++', async () => {
  // Regression test: the cpp rule ended its language alternation with `\b`, but the `c++`
  // alias ends in a non-word character, so `\b` could not hold at end-of-line and the cpp
  // rule never matched `#+begin_src c++`. The looser `c` rule (`(?:c)\b`, where the boundary
  // between `c` and `+` *is* valid) then captured it, silently giving C++ blocks plain C
  // highlighting. The fenced (```) variant was unaffected because it anchors with `\s*$`.
  const registry = await createRegistry();
  const grammar = await registry.loadGrammar('source.org2');

  const aliases = [
    ['c', 'source.c'],
    ['cpp', 'source.cpp'],
    ['c++', 'source.cpp'],
    ['cc', 'source.cpp'],
    ['cxx', 'source.cpp'],
    ['cs', 'source.cs'],
    ['csharp', 'source.cs'],
    ['hs', 'source.haskell'],
    ['kt', 'source.kotlin'],
    ['rb', 'source.ruby'],
  ];

  for (const [alias, expectedEmbed] of aliases) {
    let result = grammar.tokenizeLine(`#+begin_src ${alias}`, null);
    result = grammar.tokenizeLine('placeholder_token', result.ruleStack);
    const scopes = result.tokens.map((t) => t.scopes).flat();
    assert(
      scopes.some((s) => s === `${expectedEmbed}.identifier`),
      `expected "${alias}" to embed ${expectedEmbed}, got ${JSON.stringify(scopes)}`
    );
  }
});

test('#+begin_src cpp keeps embedding source.cpp when header arguments follow the language', async () => {
  const registry = await createRegistry();
  const grammar = await registry.loadGrammar('source.org2');
  let result = grammar.tokenizeLine('#+begin_src cpp :results output :exports both', null);
  result = grammar.tokenizeLine('placeholder_token', result.ruleStack);
  const scopes = result.tokens.map((t) => t.scopes).flat();
  assert(scopes.some((s) => s === 'source.cpp.identifier'), JSON.stringify(scopes));
});
