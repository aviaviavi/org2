import fs from "node:fs";
import path from "node:path";
import { sha256Hex } from "./artifactMetadata.js";
import { renderCaptureEntry } from "./captureEntry.js";
import { todoSequencesForFile } from "./todo.js";
import { buildRawCapture } from "./ingestionPipeline.js";
import { guardedContentRevision, guardedWriteFile } from "./guardedFile.js";

export interface BrowserClip {
  schema: "org2:browser-clip:v1";
  url: string;
  title: string;
  author?: string;
  capturedAt: string;
  mode: "article" | "selection";
  template: "note" | "task";
  content: string;
}

export function parseBrowserClip(value: unknown): BrowserClip {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Expected a browser clip object");
  const clip = value as Record<string, unknown>;
  if (clip.schema !== "org2:browser-clip:v1") throw new Error("Unsupported browser clip schema");
  for (const key of ["url", "title", "capturedAt", "content"] as const) {
    if (typeof clip[key] !== "string" || !(clip[key] as string).trim()) throw new Error(`Browser clip ${key} is required`);
  }
  const url = new URL(clip.url as string);
  if (!["https:", "http:"].includes(url.protocol) || url.username || url.password) throw new Error("Browser clip URL must be HTTP(S) without credentials");
  for (const key of ["url", "title", "capturedAt", "author"]) {
    if (clip[key] !== undefined && (typeof clip[key] !== "string" || /[\r\n\u0000]/.test(clip[key] as string) || (clip[key] as string).length > 8192)) throw new Error(`Invalid browser clip ${key}`);
  }
  if (!Number.isFinite(Date.parse(clip.capturedAt as string))) throw new Error("Invalid browser capture time");
  if (!["article", "selection"].includes(clip.mode as string)) throw new Error("Invalid browser clip mode");
  if (!["note", "task"].includes(clip.template as string)) throw new Error("Invalid browser clip template");
  if (Buffer.byteLength(clip.content as string) > 2_000_000 || (clip.content as string).includes("\0")) throw new Error("Browser clip content exceeds the 2 MB limit or contains NUL");
  return { schema: "org2:browser-clip:v1", url: url.href, title: (clip.title as string).trim(), author: clip.author as string | undefined,
    capturedAt: new Date(clip.capturedAt as string).toISOString(), mode: clip.mode as BrowserClip["mode"], template: clip.template as BrowserClip["template"], content: (clip.content as string).replace(/\r\n/g, "\n") };
}

function corpusPath(root: string, relative: string): string {
  const realRoot = fs.realpathSync(root);
  const target = path.resolve(realRoot, relative);
  if (!target.startsWith(realRoot + path.sep)) throw new Error("Clip destination must be inside the active corpus");
  let parent = target;
  while (!fs.existsSync(parent)) parent = path.dirname(parent);
  const realParent = fs.realpathSync(parent);
  if (realParent !== realRoot && !realParent.startsWith(realRoot + path.sep)) throw new Error("Clip destination escapes the corpus through a symlink");
  return target;
}

export function importBrowserClip(input: { clip: unknown; root: string; apply?: boolean; expectedRevision?: string; expectedClipRevision?: string; template?: "note" | "task" }) {
  const clip = parseBrowserClip(input.clip);
  if (input.template) clip.template = input.template;
  const canonical = JSON.stringify(clip, null, 2) + "\n";
  const clipHash = sha256Hex(canonical);
  if (input.expectedClipRevision && input.expectedClipRevision !== clipHash) throw new Error("Browser clip changed after preview; preview again before importing");
  const raw = buildRawCapture({ sourceType: `browser-${clip.mode}`, externalId: clipHash, authors: clip.author ? [clip.author] : [], capturedAt: clip.capturedAt, sourceRef: clip.url, content: clip.content });
  const rawFile = corpusPath(input.root, `raw/browser/${clipHash}.json`);
  const file = corpusPath(input.root, "views/browser-clips.org");
  const before = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
  const revision = fs.existsSync(file) ? guardedContentRevision(before) : "absent";
  if (input.expectedRevision && input.expectedRevision !== revision) throw new Error("Browser clips changed after preview; preview again before importing");
  // Fixed-width Org text keeps untrusted article content literal, including block delimiters.
  const body = clip.content.split("\n").map(line => `: ${line}`).join("\n");
  const sequences = todoSequencesForFile(file, true);
  const todoKeyword = sequences.flatMap(sequence => sequence.keywords.filter(keyword => !sequence.terminal.includes(keyword)))[0] || "TODO";
  const entry = renderCaptureEntry({ todoKeyword, title: clip.title, template: clip.template, now: new Date(clip.capturedAt), body,
    source: { type: raw.sourceType, origin: clip.url, timestamp: clip.capturedAt, title: clip.title, author: clip.author || null, contentHash: raw.contentHash, provenance: `file:../raw/browser/${clipHash}.json` } });
  const marker = `:SOURCE_PROVENANCE: file:../raw/browser/${clipHash}.json`;
  const duplicate = before.split("\n").includes(marker);
  const outText = duplicate ? before : `${before.trimEnd()}${before.trimEnd() ? "\n\n" : ""}${entry.text}`;
  if (input.apply) {
    if (!input.expectedRevision || !input.expectedClipRevision) throw new Error("Browser import requires --if-revision and --if-clip-revision from its preview");
    const rawText = JSON.stringify({ ...raw, browserClip: clip }, null, 2) + "\n";
    if (fs.existsSync(rawFile)) {
      if (fs.readFileSync(rawFile, "utf8") !== rawText) throw new Error("Raw browser capture differs from its immutable content");
    } else guardedWriteFile(rawFile, rawText, { expectedRevision: null });
    if (!duplicate) guardedWriteFile(file, outText, { expectedRevision: revision === "absent" ? null : revision, preserveMode: true });
  }
  return { schema: "org2:browser-clip-import:v1", clip, clipRevision: clipHash, file, rawFile, revision, duplicate, changed: !duplicate, apply: !!input.apply, entryText: entry.text, headingLine: duplicate ? Math.max(1, before.slice(0, before.indexOf(marker)).split("\n").map((line, index) => line.startsWith("* ") ? index + 1 : 0).filter(Boolean).at(-1) || 1) : before.trimEnd() ? before.trimEnd().split("\n").length + 2 : 1 };
}

export async function runBrowserClipCommand(args: string[]): Promise<void> {
  if (args.includes("--help") || args.length === 0) {
    process.stdout.write("org2 browser-clip import --file CLIP.org2clip --dir CORPUS [--template note|task] [--if-revision HASH|absent --if-clip-revision HASH --apply] [--json]\nPreview first; imports create immutable raw/browser captures and append reviewable views/browser-clips.org.\n");
    return;
  }
  if (args[0] !== "import") throw new Error("Expected browser-clip import");
  const flags = new Map<string, string>();
  let apply = false;
  for (let i = 1; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === "--apply") apply = true;
    else if (arg === "--json") continue;
    else if (["--file", "--dir", "--template", "--if-revision", "--if-clip-revision"].includes(arg) && args[i + 1] && !args[i + 1]!.startsWith("--")) flags.set(arg, args[++i]!);
    else throw new Error(`Unknown or incomplete browser clip option: ${arg}`);
  }
  const file = flags.get("--file"), root = flags.get("--dir"), template = flags.get("--template");
  if (!file || !root) throw new Error("Browser import requires --file and --dir");
  if (template && !["note", "task"].includes(template)) throw new Error("Template must be note or task");
  if (fs.statSync(file).size > 4_000_000) throw new Error("Browser clip file exceeds the 4 MB limit");
  const result = importBrowserClip({ clip: JSON.parse(fs.readFileSync(file, "utf8")), root, apply, expectedRevision: flags.get("--if-revision"), expectedClipRevision: flags.get("--if-clip-revision"), template: template as BrowserClip["template"] | undefined });
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
}
