import crypto from "node:crypto";
import os from "node:os";
import path from "node:path";

function expandHome(input: string): string {
  if (input === "~") return os.homedir();
  if (input.startsWith("~/")) return path.join(os.homedir(), input.slice(2));
  return input;
}

function slugForPath(input: string): string {
  const base = path.basename(path.resolve(input)) || "corpus";
  const slug = base
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug || "corpus";
}

export function org2IndexHome(): string {
  const configured = String(process.env.ORG2_INDEX_HOME || "").trim();
  if (configured) return path.resolve(expandHome(configured));
  return path.join(os.homedir(), ".org2", "index");
}

export function org2CorpusIndexDir(rootDir: string): string {
  const resolvedRoot = path.resolve(rootDir);
  const slug = slugForPath(resolvedRoot);
  const hash = crypto.createHash("sha256").update(resolvedRoot).digest("hex").slice(0, 12);
  return path.join(org2IndexHome(), `${slug}-${hash}`);
}

export function defaultSearchIndexPath(rootDir: string): string {
  return path.join(org2CorpusIndexDir(rootDir), "search-v1.json");
}

export function defaultRunApprovalIndexPath(rootDir: string): string {
  return path.join(org2CorpusIndexDir(rootDir), "run-approvals-v1.json");
}

export function defaultCorpusCachePath(rootDir: string): string {
  return path.join(org2CorpusIndexDir(rootDir), "corpus-index-cache.json");
}
