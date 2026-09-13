import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { parseBrowserClip, importBrowserClip } from "../dist/browserClip.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-browser-clip-"));
const clip = { schema: "org2:browser-clip:v1", url: "https://example.com/article?a=1", title: "A useful article", author: "Ada Author", capturedAt: "2026-09-13T12:00:00Z", mode: "selection", template: "task", content: "Selected passage.\n* Untrusted heading\n#+include: /private/secret\n#+end_example\n:PROPERTIES:\n:ID: fake\n:END:" };
try {
  const preview = importBrowserClip({ root, clip });
  assert.equal(fs.existsSync(path.join(root, "raw")), false, "preview cannot create raw files");
  assert.equal(fs.existsSync(path.join(root, "views")), false);
  assert.match(preview.entryText, /^\* TODO A useful article/);
  assert.match(preview.entryText, /:SOURCE_AUTHOR: Ada Author/);
  assert.match(preview.entryText, /:SOURCE_TIMESTAMP: 2026-09-13T12:00:00.000Z/);
  assert.match(preview.entryText, /:SOURCE_ORIGIN: https:\/\/example.com\/article\?a=1/);
  assert.match(preview.entryText, /\n: \* Untrusted heading/);
  const provenance = preview.entryText.match(/:SOURCE_PROVENANCE: file:(.+)/)[1];
  assert.equal(path.resolve(path.dirname(preview.file), provenance), preview.rawFile);
  const applied = importBrowserClip({ root, clip, apply: true, expectedRevision: preview.revision, expectedClipRevision: preview.clipRevision });
  const raw = JSON.parse(fs.readFileSync(applied.rawFile, "utf8"));
  assert.equal(raw.content, clip.content);
  assert.equal(raw.browserClip.mode, "selection");
  assert.equal(raw.sourceRef, clip.url);
  assert.equal(raw.authors[0], clip.author);
  const text = fs.readFileSync(applied.file, "utf8");
  assert.equal((text.match(/^\* /gm) || []).length, 1, "clip content must remain literal");
  const duplicate = importBrowserClip({ root, clip });
  assert.equal(duplicate.duplicate, true);
  importBrowserClip({ root, clip, apply: true, expectedRevision: duplicate.revision, expectedClipRevision: duplicate.clipRevision });
  assert.equal(fs.readFileSync(applied.file, "utf8"), text);
  assert.throws(() => importBrowserClip({ root, clip, apply: true, expectedRevision: preview.revision, expectedClipRevision: preview.clipRevision }), /changed after preview/);
  assert.throws(() => importBrowserClip({ root, clip: { ...clip, content: "changed" }, apply: true, expectedRevision: duplicate.revision, expectedClipRevision: duplicate.clipRevision }), /clip changed after preview/);
  for (const bad of [{ url: "file:///etc/passwd" }, { url: "https://user:pass@example.com" }, { title: "Heading\n:ID: injection" }, { author: "A\n:END:" }, { capturedAt: "invalid" }, { content: "a".repeat(2_000_001) }, { mode: "unknown" }]) {
    assert.throws(() => parseBrowserClip({ ...clip, ...bad }));
  }
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), "org2-clip-outside-"));
  const symlinkRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-clip-symlink-"));
  fs.symlinkSync(outside, path.join(symlinkRoot, "raw"));
  assert.throws(() => importBrowserClip({ root: symlinkRoot, clip }), /symlink/);
  fs.rmSync(outside, { recursive: true }); fs.rmSync(symlinkRoot, { recursive: true });
  const fixture = path.join(root, "article.org2clip");
  fs.writeFileSync(fixture, JSON.stringify({ ...clip, mode: "article", template: "note" }));
  const args = ["dist/cli.js", "browser-clip", "import", "--file", fixture, "--dir", root, "--json"];
  const cliPreview = JSON.parse(execFileSync(process.execPath, args, { encoding: "utf8" }));
  const cliApply = JSON.parse(execFileSync(process.execPath, [...args, "--if-revision", cliPreview.revision, "--if-clip-revision", cliPreview.clipRevision, "--apply"], { encoding: "utf8" }));
  assert.match(cliApply.entryText, /^\* A useful article/);
  assert.match(fs.readFileSync(cliApply.file, "utf8"), /SOURCE_TYPE: browser-article/);
  assert.notEqual(spawnSync(process.execPath, [...args, "--apply"]).status, 0);
  fs.writeFileSync(path.join(root, "org2.json"), JSON.stringify({ todo: { sequences: ["READING | FINISHED"] } }));
  const custom = importBrowserClip({ root, clip: { ...clip, title: "Custom task" } });
  assert.match(custom.entryText, /^\* READING Custom task/);
  console.log("Browser clip validation, literal source, provenance, idempotency, revision conflicts, path containment and CLI preview/apply passed");
} finally { fs.rmSync(root, { recursive: true, force: true }); }
