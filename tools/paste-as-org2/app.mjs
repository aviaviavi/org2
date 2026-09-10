import { createPastePreview, PastePreviewSession } from '/pasteAsOrg2.js';
import { extractPasteHtml } from '/pasteClipboardHtml.js';
import { validatePasteModel } from '/pasteStructureClassifier.js';
const byId = id => document.getElementById(id);
const session = new PastePreviewSession();
let html;
let clipboardText;
let model;
const status = message => { byId('status').textContent = message; };
const invalidate = () => {
  session.cancel(); byId('org').value = ''; byId('org').disabled = true;
  for (const id of ['insert', 'cancel', 'packet']) byId(id).disabled = true;
  byId('labels').textContent = ''; status('Source changed. Preview again before insertion.');
};
function download(name, content, type) {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const link = document.createElement('a'); link.href = url; link.download = name; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
byId('source').addEventListener('paste', event => {
  if (!event.clipboardData) return;
  event.preventDefault();
  invalidate();
  // Replaces this source buffer as a single clipboard payload. No ambient read.
  clipboardText = event.clipboardData.getData('text/plain');
  byId('source').value = clipboardText;
  html = event.clipboardData.getData('text/html') || undefined;
  byId('html-status').textContent = html ? `Captured ${html.length} HTML characters. Semantic markup takes precedence.` : 'No HTML captured.';
});
byId('source').addEventListener('input', () => { html = undefined; clipboardText = undefined; byId('html-status').textContent = 'Text edited; using plain text.'; invalidate(); });
byId('url').addEventListener('input', invalidate);
byId('model').addEventListener('change', invalidate);
byId('preview').addEventListener('click', () => {
  try {
    invalidate();
    const text = clipboardText ?? byId('source').value;
    if (!text && !html) throw new Error('Paste some content first.');
    if (byId('model').checked && !model) throw new Error('Classifier unavailable. Disable it to use the baseline.');
    const semantic = html ? extractPasteHtml(html, document) : undefined;
    const preview = createPastePreview({ text, html, sourceUrl: byId('url').value || undefined, semantic,
      model: byId('model').checked ? model : undefined });
    const target = byId('document');
    session.begin(preview, target.value, target.selectionStart, target.selectionEnd);
    byId('org').value = session.editedOrg; byId('org').disabled = false;
    for (const id of ['insert', 'cancel', 'packet']) byId(id).disabled = false;
    byId('labels').textContent = preview.blocks.map(block => `${block.sourceLine ?? 'DOM'}\t${block.label}\t${block.origin}\t${block.confidence?.toFixed(3) ?? '—'}\t${block.text}`).join('\n');
    status(preview.warnings.join('\n') || 'Semantic HTML converted locally. Check the editable Org before inserting.');
  } catch (error) { status(error.message); }
});
byId('org').addEventListener('input', () => { session.editedOrg = byId('org').value; });
byId('insert').addEventListener('click', () => {
  try {
    byId('document').value = session.insert(byId('document').value);
    invalidate(); status('Reviewed Org inserted into the scratch document.');
  } catch (error) { status(error.message); }
});
byId('cancel').addEventListener('click', () => { invalidate(); status('Preview canceled. Document unchanged.'); });
byId('download').addEventListener('click', () => download('document.org', byId('document').value, 'text/plain'));
byId('packet').addEventListener('click', () => download('paste-review.json', JSON.stringify({ ...session.preview, editedOrg: session.editedOrg }, null, 2), 'application/json'));
byId('example').addEventListener('click', () => {
  invalidate(); html = undefined; clipboardText = undefined; byId('html-status').textContent = 'Synthetic plain-text example.';
  byId('source').value = 'Chickpea skillet\nPrep 12 min • Cook 18 min\n\nWhat goes in\n1½ cans chickpeas, drained\n2–3 tbsp olive oil\n½ lemon, juice only\nSalt to taste\n\nHow to make it\nHeat oil. Add chickpeas and cook for 18 minutes.\nFinish with lemon; do not add water.';
  byId('url').value = 'https://example.test/chickpea';
});
try {
  model = validatePasteModel(await (await fetch('/model.json')).json());
  byId('model-status').textContent = `${model.weights.length.toLocaleString()} learned parameters · experimental`;
} catch { byId('model-status').textContent = 'Model unavailable · baseline available'; }
