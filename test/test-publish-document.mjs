import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  GOOGLE_DRIVE_FILE_SCOPE,
  prepareGoogleDocsUpload,
  preparePublishedDocument,
  publishToGoogleDocs,
} from "../dist/publishDocument.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cliPath = path.join(repoRoot, "dist", "cli.js");
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-publish-document-"));
const sourcePath = path.join(fixtureRoot, "research.org2");
const webOut = path.join(fixtureRoot, "published");
const privateId = "92ba16ea-a2cb-4c2a-895f-6096a23dfaed";
const secretValue = "NEVER-PUBLISH-THIS";
const source = `#+TITLE: Quantum Sensing Brief
#+DESCRIPTION: A disclosure-safe market brief.
#+HTML_HEAD: <script>window.privateValue = "${secretValue}"</script>
#+LINK: unsafe javascript:%s

Document preface.

# internal author note
* TODO Research findings :private:internal:
SCHEDULED: <2026-09-01 Tue>
:PROPERTIES:
:ID: ${privateId}
:SECRET: ${secretValue}
:END:
The cited market is growing. [[id:${privateId}][Internal source]] [[https://example.com/report][External source]] [[unsafe:alert(1)][Unsafe alias]].
Inline export must disappear: @@html:<script>${secretValue}</script>@@

[[file:chart.png]]
[[file:chart.png]]

| Claim | Source |
|-------+--------|
| Public evidence | [[id:${privateId}][Private evidence row]] |
| Unsafe cell | @@html:<script>${secretValue}</script>@@ |
#+TBLFM: $1='(identity remote-code)

#+begin_export html
<script>${secretValue}</script>
#+end_export

** COMMENT Hidden working notes
${secretValue}
`;

function runCli(extraArgs, options = {}) {
  return spawnSync(process.execPath, [cliPath, "publish", "document", "--file", sourcePath, ...extraArgs], {
    cwd: fixtureRoot,
    encoding: "utf8",
    env: { ...process.env, ORG2_GOOGLE_DRIVE_ACCESS_TOKEN: "", ...(options.env || {}) },
  });
}

function storedZipEntries(bytes) {
  const entries = new Map();
  let offset = 0;
  while (offset + 30 <= bytes.length && bytes.readUInt32LE(offset) === 0x04034b50) {
    const compression = bytes.readUInt16LE(offset + 8);
    assert.equal(compression, 0, "test reader expects deterministic stored DOCX entries");
    const size = bytes.readUInt32LE(offset + 18);
    const nameLength = bytes.readUInt16LE(offset + 26);
    const extraLength = bytes.readUInt16LE(offset + 28);
    const nameStart = offset + 30;
    const dataStart = nameStart + nameLength + extraLength;
    const name = bytes.subarray(nameStart, nameStart + nameLength).toString("utf8");
    entries.set(name, bytes.subarray(dataStart, dataStart + size));
    offset = dataStart + size;
  }
  return entries;
}

try {
  fs.writeFileSync(sourcePath, source);
  fs.writeFileSync(
    path.join(fixtureRoot, "chart.png"),
    Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64"),
  );

  const preview = runCli(["--to", "web", "--out-dir", webOut, "--format", "json"]);
  assert.equal(preview.status, 0, preview.stderr || preview.stdout);
  const previewPayload = JSON.parse(preview.stdout);
  assert.equal(previewPayload.applied, false);
  assert.equal(previewPayload.destination.destination, "web");
  assert.equal(previewPayload.destination.requiresHosting, true);
  assert.equal(previewPayload.artifact.assets.length, 1);
  assert.equal(previewPayload.artifact.assets[0].name, "chart.png");
  assert.ok(Object.values(previewPayload.disclosure.redactions).reduce((sum, count) => sum + count, 0) >= 8);
  assert.equal(fs.existsSync(webOut), false, "preview must not write a web bundle");

  const publish = runCli(["--to", "web", "--out-dir", webOut, "--apply", "--format", "json"]);
  assert.equal(publish.status, 0, publish.stderr || publish.stdout);
  const publishPayload = JSON.parse(publish.stdout);
  assert.equal(publishPayload.applied, true);
  const html = fs.readFileSync(path.join(webOut, "index.html"), "utf8");
  const manifestText = fs.readFileSync(path.join(webOut, "manifest.json"), "utf8");
  const manifest = JSON.parse(manifestText);

  assert.match(html, /<meta name="referrer" content="no-referrer" \/>/);
  assert.match(html, /<meta name="robots" content="noindex, nofollow, noarchive" \/>/);
  assert.match(html, /Content-Security-Policy/);
  assert.match(html, /data:image\/png;base64,/);
  assert.match(html, /<a rel="noopener noreferrer" href="https:\/\/example\.com\/report">External source<\/a>/);
  assert.match(html, /Internal source/);
  assert.match(html, /Private evidence row/);
  assert.doesNotMatch(html, /<span class="org2-todo|<span class="org2-tags|private:internal/);
  assert.doesNotMatch(html, new RegExp(privateId));
  assert.doesNotMatch(html, new RegExp(secretValue));
  assert.doesNotMatch(html, /javascript:|file:|TBLFM|remote-code|<script>/i);
  assert.doesNotMatch(html, new RegExp(fixtureRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.doesNotMatch(manifestText, new RegExp(fixtureRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.equal(manifest.$schema, "org2:published-document:v1");
  assert.equal(manifest.artifactHash, publishPayload.artifact.artifactHash);
  assert.equal(publishPayload.artifact.assets[0].mediaType, "image/png");
  assert.equal("sourceHash" in manifest, false, "public manifests must not expose the private source revision");
  assert.equal("redactions" in manifest, false, "public manifests must not expose private disclosure details");
  assert.equal("assets" in manifest, false, "public manifests must not expose local asset names");

  const subtreeLine = source.slice(0, source.indexOf("* TODO Research findings")).split("\n").length;
  const subtree = preparePublishedDocument({ sourceText: source, sourcePath, line: subtreeLine });
  assert.equal(subtree.manifest.selection, "subtree");
  assert.match(subtree.html, /<h1>Research findings<\/h1>/);
  assert.doesNotMatch(subtree.html, /Document preface|org2-document-header/);

  const repeat = runCli(["--to", "web", "--out-dir", webOut, "--replace-existing", "--apply", "--format", "json"]);
  assert.equal(repeat.status, 0, repeat.stderr || repeat.stdout);
  assert.equal(JSON.parse(repeat.stdout).artifact.artifactHash, manifest.artifactHash, "same source should produce the same artifact");
  assert.equal(fs.readFileSync(path.join(webOut, "manifest.json"), "utf8"), manifestText);

  const guardedWeb = runCli(["--to", "web", "--out-dir", webOut, "--apply"]);
  assert.notEqual(guardedWeb.status, 0);
  assert.match(guardedWeb.stderr, /--replace-existing/);

  const googlePreview = runCli(["--to", "google-docs", "--folder-id", "folder-123", "--format", "json"]);
  assert.equal(googlePreview.status, 0, googlePreview.stderr || googlePreview.stdout);
  const googlePreviewPayload = JSON.parse(googlePreview.stdout);
  assert.equal(googlePreviewPayload.applied, false);
  assert.equal(googlePreviewPayload.destination.action, "create");
  assert.equal(googlePreviewPayload.destination.requiredOAuthScope, GOOGLE_DRIVE_FILE_SCOPE);
  assert.equal(googlePreviewPayload.destination.folderId, "folder-123");
  assert.equal(googlePreviewPayload.destination.inputMediaType, "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
  assert.ok(googlePreviewPayload.destination.uploadBytes > 0);
  assert.doesNotMatch(googlePreview.stdout, /Bearer|access.?token/i);

  const missingCredential = runCli(["--to", "google-docs", "--apply"]);
  assert.notEqual(missingCredential.status, 0);
  assert.match(missingCredential.stderr, /ORG2_GOOGLE_DRIVE_ACCESS_TOKEN/);

  const prepared = preparePublishedDocument({ sourceText: source, sourcePath });
  const docx = prepareGoogleDocsUpload(prepared);
  assert.deepEqual(docx.bytes.subarray(0, 2), Buffer.from("PK"));
  assert.deepEqual(prepareGoogleDocsUpload(prepared).bytes, docx.bytes, "Google Docs media should be deterministic");
  const docxEntries = storedZipEntries(docx.bytes);
  assert.ok(docxEntries.has("[Content_Types].xml"));
  assert.ok(docxEntries.has("word/document.xml"));
  assert.ok(docxEntries.has("word/_rels/document.xml.rels"));
  assert.ok(docxEntries.has("word/media/image1.png"));
  const documentXml = docxEntries.get("word/document.xml").toString("utf8");
  assert.match(documentXml, /Quantum Sensing Brief/);
  assert.match(documentXml, /Private evidence row/);
  assert.match(documentXml, /<w:tbl>/);
  assert.match(documentXml, /r:embed="rId/);
  assert.deepEqual([...documentXml.matchAll(/<wp:docPr id="(\d+)"/g)].map((match) => match[1]), ["1", "2"]);
  assert.doesNotMatch(documentXml, new RegExp(privateId));
  assert.doesNotMatch(documentXml, new RegExp(secretValue));
  assert.doesNotMatch(documentXml, /javascript:|TBLFM|remote-code/i);
  const createCalls = [];
  const created = await publishToGoogleDocs(prepared, {
    accessToken: "ephemeral-test-token",
    folderId: "folder-123",
    fetchImpl: async (url, init) => {
      createCalls.push({ url: String(url), init });
      return new Response(JSON.stringify({
        id: "doc-created",
        name: "Quantum Sensing Brief",
        mimeType: "application/vnd.google-apps.document",
        version: "7",
        webViewLink: "https://docs.google.com/document/d/doc-created/edit",
      }), { status: 200, headers: { "content-type": "application/json" } });
    },
  });
  assert.equal(createCalls.length, 1);
  assert.equal(createCalls[0].init.method, "POST");
  assert.match(createCalls[0].url, /\/upload\/drive\/v3\/files\?/);
  assert.match(String(createCalls[0].init.headers["content-type"]), /multipart\/related/);
  const createBody = Buffer.from(createCalls[0].init.body);
  assert.match(createBody.toString("latin1"), /application\/vnd\.google-apps\.document/);
  assert.match(createBody.toString("latin1"), /application\/vnd\.openxmlformats-officedocument\.wordprocessingml\.document/);
  assert.match(createBody.toString("latin1"), /"parents":\["folder-123"\]/);
  assert.ok(createBody.indexOf(Buffer.from("PK")) > 0, "multipart upload should contain a DOCX package");
  assert.equal(created.fileId, "doc-created");
  assert.equal(created.version, "7");
  assert.doesNotMatch(JSON.stringify(created), /ephemeral-test-token/);

  await assert.rejects(
    () => publishToGoogleDocs(prepared, {
      accessToken: "ephemeral-test-token",
      fetchImpl: async () => new Response("provider echoed ephemeral-test-token", { status: 403 }),
    }),
    (error) => {
      assert.match(String(error), /\[redacted\]/);
      assert.doesNotMatch(String(error), /ephemeral-test-token/);
      return true;
    },
  );

  const updateCalls = [];
  const updated = await publishToGoogleDocs(prepared, {
    accessToken: "ephemeral-test-token",
    documentId: "doc-created",
    expectedVersion: "7",
    replaceExisting: true,
    fetchImpl: async (url, init) => {
      updateCalls.push({ url: String(url), init });
      if (init?.method === "GET") {
        if (String(url).includes("/comments?")) {
          return new Response(JSON.stringify({ comments: [] }), { status: 200 });
        }
        return new Response(JSON.stringify({
          id: "doc-created",
          name: "Quantum Sensing Brief",
          mimeType: "application/vnd.google-apps.document",
          version: "7",
          capabilities: { canEdit: true },
        }), { status: 200, headers: { etag: '"remote-etag"' } });
      }
      return new Response(JSON.stringify({
        id: "doc-created",
        name: "Quantum Sensing Brief",
        mimeType: "application/vnd.google-apps.document",
        version: "8",
        webViewLink: "https://docs.google.com/document/d/doc-created/edit",
      }), { status: 200 });
    },
  });
  assert.deepEqual(updateCalls.map((call) => call.init.method), ["GET", "GET", "PATCH"]);
  assert.match(updateCalls[1].url, /\/comments\?/);
  assert.equal(updateCalls[2].init.headers["if-match"], '"remote-etag"');
  assert.equal(updated.action, "update");
  assert.equal(updated.version, "8");

  let mismatchCallCount = 0;
  await assert.rejects(
    () => publishToGoogleDocs(prepared, {
      accessToken: "ephemeral-test-token",
      documentId: "doc-created",
      expectedVersion: "6",
      replaceExisting: true,
      fetchImpl: async () => {
        mismatchCallCount += 1;
        return new Response(JSON.stringify({
          id: "doc-created",
          mimeType: "application/vnd.google-apps.document",
          version: "7",
          capabilities: { canEdit: true },
        }), { status: 200 });
      },
    }),
    /version changed.*Import the remote changes or publish as a new copy/i,
  );
  assert.equal(mismatchCallCount, 1, "a version mismatch must not send the replacement upload");

  const commentedCalls = [];
  await assert.rejects(
    () => publishToGoogleDocs(prepared, {
      accessToken: "ephemeral-test-token",
      documentId: "doc-created",
      expectedVersion: "7",
      replaceExisting: true,
      fetchImpl: async (url, init) => {
        commentedCalls.push({ url: String(url), init });
        if (String(url).includes("/comments?")) {
          return new Response(JSON.stringify({ comments: [{ id: "comment-1" }] }), { status: 200 });
        }
        return new Response(JSON.stringify({
          id: "doc-created",
          mimeType: "application/vnd.google-apps.document",
          version: "7",
          capabilities: { canEdit: true },
        }), { status: 200, headers: { etag: '"remote-etag"' } });
      },
    }),
    /has comments.*publish as a new copy/i,
  );
  assert.deepEqual(commentedCalls.map((call) => call.init.method), ["GET", "GET"], "comments must stop the replacement upload");
} finally {
  fs.rmSync(fixtureRoot, { recursive: true, force: true });
}

console.log("single-document web and Google Docs publishing tests passed");
