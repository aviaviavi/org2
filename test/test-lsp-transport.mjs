#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';

const server = spawn(process.execPath, ['dist/lsp.js'], { stdio: ['pipe', 'pipe', 'pipe'] });
let buffer = Buffer.alloc(0);
let stderr = '';
const messages = [];
const waiters = new Set();
server.stderr.on('data', chunk => { stderr += chunk; });
server.stdout.on('data', chunk => {
  buffer = Buffer.concat([buffer, chunk]);
  for (;;) {
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd < 0) break;
    const header = buffer.subarray(0, headerEnd).toString('ascii');
    const match = /^Content-Length:\s*(\d+)$/im.exec(header);
    assert.ok(match, `Invalid LSP response header: ${header}`);
    const end = headerEnd + 4 + Number(match[1]);
    if (buffer.length < end) break;
    messages.push(JSON.parse(buffer.subarray(headerEnd + 4, end).toString('utf8')));
    buffer = buffer.subarray(end);
    for (const check of [...waiters]) check();
  }
});
function frame(message) {
  const body = Buffer.from(typeof message === 'string' ? message : JSON.stringify(message));
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
}
function send(message) { server.stdin.write(frame(message)); }
function response(id) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { waiters.delete(check); reject(new Error(`No response for ${id}: ${stderr}`)); }, 3000);
    const check = () => {
      const message = messages.find(item => Object.hasOwn(item, 'id') && item.id === id);
      if (message) { clearTimeout(timer); waiters.delete(check); resolve(message); }
    };
    waiters.add(check);
    check();
  });
}
const request = (id, method, params) => send({ jsonrpc: '2.0', id, method, params });
const notify = (method, params) => send({ jsonrpc: '2.0', method, params });
try {
  request('initialize', 'initialize', { capabilities: {} });
  assert.ok((await response('initialize')).result.capabilities);
  notify('initialized', {});
  notify('workspace/didChangeConfiguration', { settings: {} });
  notify('textDocument/didSave', { textDocument: { uri: 'file:///empty.org' } });
  notify('$/cancelRequest', { id: 999 });
  // Even a failed notification must not produce a JSON-RPC response.
  notify('textDocument/didOpen', null);
  request(0, 'unknown/request', {});
  assert.equal((await response(0)).error.code, -32601);
  assert.equal(messages.filter(item => item.error).length, 1, 'Notifications must not emit error responses');

  const uri = 'file:///unicode.org';
  const opening = frame({ jsonrpc: '2.0', method: 'textDocument/didOpen', params: {
    textDocument: { uri, languageId: 'org', version: 1, text: '* Café 東京 🌍\nBody\n' },
  } });
  const emoji = opening.indexOf(Buffer.from('🌍'));
  server.stdin.write(opening.subarray(0, emoji + 1));
  await new Promise(resolve => setImmediate(resolve));
  // Split a multi-byte character across reads and pipeline the next message.
  server.stdin.write(Buffer.concat([opening.subarray(emoji + 1), frame({ jsonrpc: '2.0', id: 'symbols', method: 'textDocument/documentSymbol', params: { textDocument: { uri } } })]));
  assert.deepEqual((await response('symbols')).result.map(item => item.name), ['Café 東京 🌍']);
  assert.ok(messages.some(item => item.method === 'textDocument/publishDiagnostics' && item.params.uri === uri));
  for (const method of ['textDocument/documentSymbol', 'textDocument/completion']) {
    request(method, method, { textDocument: { uri: 'file:///missing.org' }, position: { line: 0, character: 0 } });
    assert.deepEqual((await response(method)).result, []);
  }
  send('{invalid JSON');
  const parseError = await response(null);
  assert.equal(parseError.error.code, -32700);
  request('after-error', 'textDocument/documentSymbol', { textDocument: { uri } });
  assert.equal((await response('after-error')).result.length, 1);
  for (const message of messages) {
    assert.equal(message.jsonrpc, '2.0');
    if (Object.hasOwn(message, 'method')) {
      assert.equal(typeof message.method, 'string');
      assert.ok(!Object.hasOwn(message, 'id'));
    } else {
      assert.ok(Object.hasOwn(message, 'id'), 'Every response must have an id, including parse errors');
      assert.notEqual(Object.hasOwn(message, 'result'), Object.hasOwn(message, 'error'));
    }
  }
  console.log('LSP transport regression tests passed');
} finally {
  const exited = once(server, 'exit');
  server.kill();
  await exited;
}
