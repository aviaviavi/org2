import fs from "node:fs";
import path from "node:path";
import type { Org2Config } from "./config.js";

export const ORG2_CORPUS_SCHEMA = "org2:corpus:v1" as const;
export const ORG2_CORPUS_KINDS = ["personal", "shared", "project"] as const;

export type Org2CorpusKind = typeof ORG2_CORPUS_KINDS[number];

export interface Org2CorpusIdentity {
  schema: typeof ORG2_CORPUS_SCHEMA;
  id: string;
  name: string;
  kind: Org2CorpusKind;
}

export interface CorpusIdentityIssue {
  path: string;
  message: string;
}

export interface CorpusIdentityStatus {
  schema: typeof ORG2_CORPUS_SCHEMA;
  root: string;
  configFile: string;
  identity?: Org2CorpusIdentity;
  valid: boolean;
  issues: CorpusIdentityIssue[];
}

const ID_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/;

export function validateCorpusIdentity(value: unknown): { valid: boolean; issues: CorpusIdentityIssue[]; identity?: Org2CorpusIdentity } {
  const issues: CorpusIdentityIssue[] = [];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { valid: false, issues: [{ path: "corpus", message: "must be an object in org2.json" }] };
  }
  const raw = value as Record<string, unknown>;
  const schema = String(raw.schema || "").trim();
  const id = String(raw.id || "").trim();
  const name = String(raw.name || "").trim();
  const kind = String(raw.kind || "").trim();
  if (schema !== ORG2_CORPUS_SCHEMA) issues.push({ path: "corpus.schema", message: `must equal ${ORG2_CORPUS_SCHEMA}` });
  if (!ID_PATTERN.test(id)) issues.push({ path: "corpus.id", message: "must be a lowercase slug of 1-64 letters, numbers, or hyphens" });
  if (!name || name.length > 120) issues.push({ path: "corpus.name", message: "must contain 1-120 characters" });
  if (!(ORG2_CORPUS_KINDS as readonly string[]).includes(kind)) issues.push({ path: "corpus.kind", message: `must be one of: ${ORG2_CORPUS_KINDS.join(", ")}` });
  return {
    valid: issues.length === 0,
    issues,
    ...(issues.length === 0 ? { identity: { schema: ORG2_CORPUS_SCHEMA, id, name, kind: kind as Org2CorpusKind } } : {}),
  };
}

export function corpusIdentityStatus(root: string): CorpusIdentityStatus {
  const resolvedRoot = path.resolve(root);
  const configFile = path.join(resolvedRoot, "org2.json");
  const issues: CorpusIdentityIssue[] = [];
  if (!fs.existsSync(resolvedRoot) || !fs.statSync(resolvedRoot).isDirectory()) {
    return { schema: ORG2_CORPUS_SCHEMA, root: resolvedRoot, configFile, valid: false, issues: [{ path: "root", message: "must be an existing directory" }] };
  }
  if (!fs.existsSync(configFile)) {
    return { schema: ORG2_CORPUS_SCHEMA, root: resolvedRoot, configFile, valid: false, issues: [{ path: "org2.json", message: "is required for a portable corpus identity" }] };
  }
  let config: Org2Config;
  try {
    config = JSON.parse(fs.readFileSync(configFile, "utf8")) as Org2Config;
  } catch (error) {
    return { schema: ORG2_CORPUS_SCHEMA, root: resolvedRoot, configFile, valid: false, issues: [{ path: "org2.json", message: `could not be read: ${error instanceof Error ? error.message : String(error)}` }] };
  }
  const result = validateCorpusIdentity(config.corpus);
  issues.push(...result.issues);
  return { schema: ORG2_CORPUS_SCHEMA, root: resolvedRoot, configFile, ...(result.identity ? { identity: result.identity } : {}), valid: issues.length === 0, issues };
}

function starterConfig(identity: Org2CorpusIdentity): Org2Config {
  return {
    corpus: identity,
    agendaFiles: ["inbox.org2", "notes/**/*.org2", "notes/**/*.org", "daily/**/*.org2", "daily/**/*.org"],
    recursive: true,
    ignorePatterns: [".git/**", ".#*", "compiled/**"],
    roam: { indexDir: "notes", nodesDir: "notes", dailiesDir: "daily" },
  };
}

export function initializeCorpusIdentity(
  root: string,
  identity: Omit<Org2CorpusIdentity, "schema">,
  options: { apply?: boolean; force?: boolean } = {},
): { status: CorpusIdentityStatus; changed: boolean; applied: boolean } {
  const resolvedRoot = path.resolve(root);
  const configFile = path.join(resolvedRoot, "org2.json");
  const normalized: Org2CorpusIdentity = { schema: ORG2_CORPUS_SCHEMA, id: identity.id.trim(), name: identity.name.trim(), kind: identity.kind };
  const validation = validateCorpusIdentity(normalized);
  if (!validation.valid) throw new Error(validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; "));

  let config: Org2Config = starterConfig(normalized);
  if (fs.existsSync(configFile)) {
    try { config = JSON.parse(fs.readFileSync(configFile, "utf8")) as Org2Config; }
    catch (error) { throw new Error(`cannot update ${configFile}: ${error instanceof Error ? error.message : String(error)}`); }
  }
  const existing = validateCorpusIdentity(config.corpus).identity;
  if (existing && existing.id !== normalized.id && !options.force) {
    throw new Error(`corpus already has identity ${existing.id}; pass --force to replace it`);
  }
  const changed = JSON.stringify(existing) !== JSON.stringify(normalized);
  if (options.apply) {
    fs.mkdirSync(resolvedRoot, { recursive: true });
    for (const directory of ["notes", "daily", "views", "compiled", "workflows"]) fs.mkdirSync(path.join(resolvedRoot, directory), { recursive: true });
    const next = { ...config, corpus: normalized };
    const temporary = `${configFile}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, `${JSON.stringify(next, null, 2)}\n`, "utf8");
    fs.renameSync(temporary, configFile);
  }
  const status = options.apply
    ? corpusIdentityStatus(resolvedRoot)
    : { schema: ORG2_CORPUS_SCHEMA, root: resolvedRoot, configFile, identity: normalized, valid: true, issues: [] } satisfies CorpusIdentityStatus;
  return { status, changed, applied: options.apply === true };
}
