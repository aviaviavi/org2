const headingRe = /^(\*+)\s+(.*)$/;
const cryptTagRe = /(?:^|:)crypt(?::|$)/i;
const pgpBeginRe = /^-----BEGIN PGP MESSAGE-----\s*$/;
const pgpEndRe = /^-----END PGP MESSAGE-----\s*$/;
const propertiesBeginRe = /^\s*:PROPERTIES:\s*$/i;
const drawerEndRe = /^\s*:END:\s*$/i;

function headingHasCryptTag(text) {
  const m = headingRe.exec(String(text || ''));
  if (!m) return false;
  return cryptTagRe.test(m[2] || '');
}

function lineIsHeading(text) {
  return headingRe.test(String(text || ''));
}

function headingLevel(text) {
  const m = headingRe.exec(String(text || ''));
  return m ? m[1].length : 0;
}

function subtreeEndLine(lines, headingLine) {
  const level = headingLevel(lines[headingLine] || '');
  if (!level) return headingLine + 1;
  for (let i = headingLine + 1; i < lines.length; i += 1) {
    if (lineIsHeading(lines[i]) && headingLevel(lines[i]) <= level) return i;
  }
  return lines.length;
}

function encryptedBodyStartLine(lines, headingLine, endLine) {
  let bodyStart = headingLine + 1;
  if (propertiesBeginRe.test(lines[bodyStart] || '')) {
    for (let i = bodyStart + 1; i < endLine; i += 1) {
      if (drawerEndRe.test(lines[i] || '')) return i + 1;
    }
  }
  return bodyStart;
}

function subtreeContainsPgpBlock(lines, startLine, endLine) {
  for (let i = startLine; i < endLine; i += 1) {
    if (pgpBeginRe.test(lines[i] || '')) return true;
  }
  return false;
}

function findCryptSubtreesNeedingEncryption(text) {
  const normalized = String(text || '').replace(/\r\n/g, '\n');
  const lines = normalized.split('\n');
  const out = [];

  for (let i = 0; i < lines.length; i += 1) {
    if (!headingHasCryptTag(lines[i])) continue;
    const endLine = subtreeEndLine(lines, i);
    const bodyStartLine = encryptedBodyStartLine(lines, i, endLine);
    if (subtreeContainsPgpBlock(lines, bodyStartLine, endLine)) continue;
    const plainBody = lines.slice(bodyStartLine, endLine).join('\n').trim();
    if (!plainBody) continue;
    out.push({ line: i + 1, bodyStartLine, endLine });
  }

  return out;
}

function replaceLineRanges(text, replacements) {
  const hadTrailingNewline = /\n$/.test(String(text || ''));
  const lines = String(text || '').replace(/\r\n/g, '\n').split('\n');
  if (hadTrailingNewline && lines[lines.length - 1] === '') lines.pop();

  for (const replacement of replacements.slice().sort((a, b) => b.startLine - a.startLine)) {
    const newLines = String(replacement.text || '').replace(/\r\n/g, '\n').replace(/\n$/, '').split('\n');
    lines.splice(replacement.startLine, replacement.endLine - replacement.startLine, ...newLines);
  }

  return lines.join('\n') + (hadTrailingNewline ? '\n' : '');
}

function hasUnclosedPgpBlock(text) {
  const lines = String(text || '').replace(/\r\n/g, '\n').split('\n');
  let inBlock = false;
  for (const line of lines) {
    if (pgpBeginRe.test(line || '')) inBlock = true;
    if (pgpEndRe.test(line || '')) inBlock = false;
  }
  return inBlock;
}

module.exports = {
  findCryptSubtreesNeedingEncryption,
  hasUnclosedPgpBlock,
  headingHasCryptTag,
  replaceLineRanges,
  subtreeEndLine,
};
