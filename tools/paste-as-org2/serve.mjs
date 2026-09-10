import http from 'node:http';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../..', import.meta.url));
const routes = new Map([
  ['/', ['tools/paste-as-org2/preview.html', 'text/html']],
  ['/app.js', ['tools/paste-as-org2/app.mjs', 'text/javascript']],
  ['/style.css', ['tools/paste-as-org2/style.css', 'text/css']],
  ['/model.json', ['tools/paste-as-org2/model.json', 'application/json']],
  ['/pasteAsOrg2.js', ['dist/pasteAsOrg2.js', 'text/javascript']],
  ['/pasteStructureClassifier.js', ['dist/pasteStructureClassifier.js', 'text/javascript']],
  ['/pasteClipboardHtml.js', ['dist/pasteClipboardHtml.js', 'text/javascript']],
]);
export function startPastePreviewServer(port = 0) {
  const server = http.createServer((request, response) => {
    const host = `127.0.0.1:${server.address().port}`;
    response.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Referrer-Policy', 'no-referrer');
    const route = routes.get(request.url);
    if (request.headers.host !== host || request.method !== 'GET' || !route) {
      response.writeHead(404); response.end('Not found'); return;
    }
    try {
      response.setHeader('Content-Type', route[1] + '; charset=utf-8');
      response.end(fs.readFileSync(`${root}/${route[0]}`));
    } catch { response.writeHead(503); response.end('Run npm run build and the classifier experiment first.'); }
  });
  return new Promise(resolve => server.listen(port, '127.0.0.1', () => resolve(server)));
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const server = await startPastePreviewServer(Number(process.argv[2] ?? 0));
  console.log(`Paste as Org2 experimental local preview: http://127.0.0.1:${server.address().port}`);
  console.log('Clipboard data stays in browser memory. Stop with Ctrl-C.');
}
