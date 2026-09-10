import assert from 'node:assert/strict';
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { startPastePreviewServer } from '../tools/paste-as-org2/serve.mjs';
// Reuse an installed Playwright or pass its module path. No downloads in this test.
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const server = await startPastePreviewServer();
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1250 } });
  const requests = [];
  const errors = [];
  page.on('request', request => requests.push(request.url()));
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(origin);
  await page.waitForFunction(() => document.getElementById('model-status').textContent.includes('learned parameters'));
  // The exact checked-in native bundle must run without module loaders or network.
  await page.evaluate(readFileSync(new URL('../apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/Resources/PasteAsOrg2.js', import.meta.url), 'utf8'));
  const native = await page.evaluate(() => {
    const html = globalThis.openOrgPastePreview({text: 'fallback', html: '<h2>Ingredients</h2><p>2½ cups milk</p>', useModel: true});
    const text = ('Ingredients\n1½ cans chickpeas\n2–3 tbsp oil\nCook 18 minutes.\n').repeat(35);
    const timings = [];
    for (let i = 0; i < 100; i++) {
      const start = performance.now();
      const preview = globalThis.openOrgPastePreview({text, useModel: true});
      if (!preview.org.includes('1½ cans chickpeas')) throw new Error('Native bundle lost a quantity');
      timings.push(performance.now() - start);
    }
    timings.sort((a, b) => a - b);
    return {org: html.org, p50: timings[50], p95: timings[95]};
  });
  assert.equal(native.org, '** Ingredients\n\n2½ cups milk');
  console.log('Native bundle 140-line preview milliseconds:', JSON.stringify({p50: native.p50, p95: native.p95}));
  const domResults = await page.evaluate(async () => {
    const { extractPasteHtml } = await import('/pasteClipboardHtml.js');
    const { createPastePreview } = await import('/pasteAsOrg2.js');
    const html = '<h2>Crêpes</h2><p>Keep <b>250 ml</b> milk &amp; ½ tsp salt.</p><ul><li>2 eggs</li><li>125 g flour<ul><li>sifted</li></ul></li></ul><blockquote><p>Do not double salt.</p></blockquote><pre>if (x &lt; 2) {\n  x += 1;\n}</pre><table><caption>Amounts</caption><tr><th>Item</th><th>Quantity</th></tr><tr><td>Oil</td><td>2 tbsp</td></tr></table><p><a href="https://example.test/recipe?q=½">Recipe source</a></p><img src="https://example.test/MUST-NOT-FETCH" onerror="window.pastePwned=true"><script>window.pastePwned=true</script>';
    const semantic = extractPasteHtml(html, document);
    const preview = createPastePreview({ text: 'fallback', html, semantic, model: {} });
    const complex = extractPasteHtml('<table><tr><td colspan="2">1½ tbsp salt</td></tr></table>', document);
    const inline = extractPasteHtml('<h1>Title</h1><div>Hello <b>world</b><br>Again</div>', document);
    const linksOnly = extractPasteHtml('<div><a href="/recipe">Link</a></div>', document);
    const nested = extractPasteHtml('<ul><li>before<ul><li>inner</li></ul>after</li></ul>', document);
    const ordered = extractPasteHtml('<ol start="4"><li value="9">a</li><li>b</li></ol><ol reversed><li>c</li><li>d</li></ol>', document);
    const nestedTable = extractPasteHtml('<table><caption>Caption</caption><tr><td>A<table><tr><td>Inner</td><td>2.5</td></tr></table></td></tr></table>', document);
    const noPlain = createPastePreview({ text: '', html: '<div>First</div><div>Second</div>', semantic: extractPasteHtml('<div>First</div><div>Second</div>', document) });
    const fragment = extractPasteHtml('<p>Excluded</p><!--StartFragment--><p>Selected</p><!--EndFragment--><p>Excluded too</p>', document);
    return { preview, complex, inline, linksOnly, nested, ordered, nestedTable, noPlain, fragment, pwned: window.pastePwned ?? false };
  });
  assert.equal(domResults.pwned, false);
  assert.ok(domResults.preview.blocks.every(block => block.origin === 'html'));
  assert.deepEqual(domResults.preview.blocks.slice(0, 5).map(block => block.text), ['Crêpes', 'Keep 250 ml milk & ½ tsp salt.', '2 eggs', '125 g flour', 'sifted']);
  assert.ok(domResults.preview.org.includes('[[https://example.test/recipe?q=½]]'));
  assert.equal(domResults.preview.originalText, 'fallback');
  assert.ok(domResults.complex.warnings.some(value => value.includes('Merged')));
  assert.ok(domResults.complex.blocks[0].text.includes('1½ tbsp salt'));
  assert.equal(domResults.inline.blocks[1].text, 'Hello world\nAgain');
  assert.deepEqual(domResults.linksOnly.links, ['/recipe']);
  assert.deepEqual(domResults.nested.blocks.map(block => block.text), ['before', 'inner', 'after']);
  assert.deepEqual(domResults.ordered.blocks.map(block => block.text), ['9. a', '10. b', '2. c', '1. d']);
  assert.equal(domResults.nestedTable.blocks[0].text.match(/Inner/g).length, 1);
  assert.ok(domResults.nestedTable.blocks[0].text.includes('Caption'));
  assert.equal(domResults.noPlain.org, ': First\n: Second');
  assert.deepEqual(domResults.fragment.blocks.map(block => block.text), ['Selected']);
  assert.equal(await page.getByRole('button', { name: 'Insert reviewed Org' }).isDisabled(), true);
  await page.getByRole('button', { name: 'Load synthetic recipe' }).click();
  await page.getByLabel('Use experimental local classifier for plain text').check();
  const before = await page.getByLabel('Scratch Org document').inputValue();
  await page.getByRole('button', { name: 'Preview structure' }).click();
  assert.equal(await page.getByLabel('Scratch Org document').inputValue(), before);
  const output = await page.getByLabel('Editable Org preview').inputValue();
  assert.ok(output.includes('1½ cans chickpeas, drained'));
  assert.ok(output.includes('2–3 tbsp olive oil'));
  assert.ok(output.includes('https://example.test/chickpea'));
  await page.getByLabel('Editable Org preview').fill('- 1½ cans chickpeas, drained\n- 2–3 tbsp olive oil');
  await page.getByRole('button', { name: 'Insert reviewed Org' }).click();
  assert.ok((await page.getByLabel('Scratch Org document').inputValue()).includes('- 2–3 tbsp olive oil'));
  assert.equal(await page.getByRole('button', { name: 'Insert reviewed Org' }).isDisabled(), true);
  await page.getByRole('button', { name: 'Preview structure' }).click();
  const inserted = await page.getByLabel('Scratch Org document').inputValue();
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  assert.equal(await page.getByLabel('Scratch Org document').inputValue(), inserted);
  await page.getByRole('button', { name: 'Preview structure' }).click();
  await page.getByLabel('Scratch Org document').fill('changed after preview');
  await page.getByRole('button', { name: 'Insert reviewed Org' }).click();
  assert.ok((await page.getByRole('status').textContent()).includes('Document changed'));
  assert.equal(await page.getByLabel('Scratch Org document').inputValue(), 'changed after preview');
  await page.locator('#source').fill('2.50 g salt');
  assert.equal(await page.getByRole('button', { name: 'Insert reviewed Org' }).isDisabled(), true);
  // A real paste event with both formats must use semantic DOM and preserve raw.
  await page.evaluate(() => {
    const data = new DataTransfer(); data.setData('text/plain', 'Ingredients\r\n2.50 g salt\r\n');
    data.setData('text/html', '<h2>Ingredients</h2><ul><li>2.50 g salt</li></ul>');
    document.getElementById('source').dispatchEvent(new ClipboardEvent('paste', { bubbles: true, clipboardData: data }));
  });
  await page.getByRole('button', { name: 'Preview structure' }).click();
  assert.equal(await page.getByLabel('Editable Org preview').inputValue(), '** Ingredients\n\n- 2.50 g salt\n\n[[https://example.test/chickpea]]');
  assert.ok((await page.locator('#labels').textContent()).includes('html'));
  // Download explicitly reviewed Org and a packet containing the untouched source.
  const packetDownload = page.waitForEvent('download');
  await page.getByText('Clipboard HTML & original source', { exact: true }).click();
  await page.getByRole('button', { name: 'Download original + preview packet' }).click();
  const packet = await packetDownload;
  assert.equal(packet.suggestedFilename(), 'paste-review.json');
  let packetText = '';
  for await (const chunk of await packet.createReadStream()) packetText += chunk;
  assert.equal(JSON.parse(packetText).originalText, 'Ingredients\r\n2.50 g salt\r\n');
  await page.getByRole('button', { name: 'Load synthetic recipe' }).click();
  await page.getByLabel('Scratch Org document').fill('#+TITLE: Paste experiment\n\n');
  await page.getByLabel('Scratch Org document').evaluate(element => element.setSelectionRange(element.value.length, element.value.length));
  await page.getByRole('button', { name: 'Preview structure' }).click();
  if (process.env.PASTE_SCREENSHOT) await page.screenshot({ path: process.env.PASTE_SCREENSHOT, fullPage: true });
  assert.deepEqual(errors, []);
  assert.ok(requests.every(url => url.startsWith(origin + '/')), JSON.stringify(requests));
  assert.equal(requests.some(url => /MUST-NOT-FETCH/.test(url)), false);
  assert.equal((await fetch(origin, { method: 'POST', body: 'clipboard-must-not-be-accepted' })).status, 404);
  const wrongHostStatus = await new Promise((resolve, reject) => {
    http.get(origin, { headers: { Host: 'untrusted.example' } }, response => { response.resume(); resolve(response.statusCode); }).on('error', reject);
  });
  assert.equal(wrongHostStatus, 404);
  console.log('PASS: real Chromium DOM, HTML priority, no clipboard network requests, source quantities, edit/insert/cancel/stale target, paste event, download, server origin/method boundaries.');
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
