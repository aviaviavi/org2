const test = require('node:test');
const assert = require('node:assert/strict');
const { findCryptSubtreesNeedingEncryption, hasUnclosedPgpBlock, headingHasCryptTag, replaceLineRanges } = require('../cryptOnSave');

test('detects headings tagged crypt', () => {
  assert.equal(headingHasCryptTag('* Secret :crypt:'), true);
  assert.equal(headingHasCryptTag('** TODO Thing :work:crypt:'), true);
  assert.equal(headingHasCryptTag('* Not encrypted :encrypted:'), false);
});

test('finds plaintext crypt subtree body ranges that need encryption', () => {
  const text = `* Public\nhello\n* Secret :crypt:\n:PROPERTIES:\n:ID: abc\n:END:\nplaintext\n** Child\nmore\n* Next\n`;
  assert.deepEqual(findCryptSubtreesNeedingEncryption(text), [{ line: 3, bodyStartLine: 6, endLine: 9 }]);
});

test('skips crypt subtrees that already contain a PGP message', () => {
  const text = `* Secret :crypt:\n-----BEGIN PGP MESSAGE-----\nabc\n-----END PGP MESSAGE-----\n`;
  assert.deepEqual(findCryptSubtreesNeedingEncryption(text), []);
});

test('replaces line ranges without losing trailing newline', () => {
  const text = '* Secret :crypt:\nplaintext\n* Next\n';
  assert.equal(replaceLineRanges(text, [{ startLine: 1, endLine: 2, text: '-----BEGIN PGP MESSAGE-----\nx\n-----END PGP MESSAGE-----\n' }]), '* Secret :crypt:\n-----BEGIN PGP MESSAGE-----\nx\n-----END PGP MESSAGE-----\n* Next\n');
});

test('detects unclosed PGP blocks', () => {
  assert.equal(hasUnclosedPgpBlock('-----BEGIN PGP MESSAGE-----\nabc\n'), true);
  assert.equal(hasUnclosedPgpBlock('-----BEGIN PGP MESSAGE-----\nabc\n-----END PGP MESSAGE-----\n'), false);
});
