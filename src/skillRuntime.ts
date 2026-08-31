import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ORG2_SKILL_RELATIVE_PATH = path.join("skills", "org2", "SKILL.md");
export const ORG2_SKILL_DESTINATION = path.join(".agents", "skills", "org2", "SKILL.md");

export type Org2SkillInstallStatus = "would-create" | "created" | "unchanged" | "conflict";

export interface Org2SkillInstallResult {
  schema: "org2:skill-install:v1";
  apply: boolean;
  status: Org2SkillInstallStatus;
  source: string;
  destination: string;
  sha256: string;
}

export function packagedOrg2SkillPath(moduleUrl: string = import.meta.url): string {
  const moduleDirectory = path.dirname(fileURLToPath(moduleUrl));
  return path.resolve(moduleDirectory, "..", ORG2_SKILL_RELATIVE_PATH);
}

function skillSource(sourcePath: string): string {
  const source = fs.readFileSync(sourcePath, "utf8");
  if (!source.startsWith("---\n") || !source.includes("\nname: org2\n")) {
    throw new Error(`packaged Org2 skill is invalid: ${sourcePath}`);
  }
  return source;
}

function hash(source: string): string {
  return crypto.createHash("sha256").update(source).digest("hex");
}

function existingStatus(destination: string, source: string): "unchanged" | "conflict" | undefined {
  if (!fs.existsSync(destination)) return undefined;
  const stats = fs.lstatSync(destination);
  if (!stats.isFile() || stats.isSymbolicLink()) return "conflict";
  return fs.readFileSync(destination, "utf8") === source ? "unchanged" : "conflict";
}

function assertSafeDestinationParents(corpus: string): void {
  let current = corpus;
  for (const component of [".agents", "skills", "org2"]) {
    current = path.join(current, component);
    if (!fs.existsSync(current)) continue;
    const stats = fs.lstatSync(current);
    if (stats.isSymbolicLink() || !stats.isDirectory()) {
      throw new Error(`skill destination parent is not a directory: ${current}`);
    }
  }
}

export function installPackagedOrg2Skill(options: {
  corpus: string;
  apply?: boolean;
  sourcePath?: string;
}): Org2SkillInstallResult {
  const corpus = path.resolve(options.corpus);
  const source = path.resolve(options.sourcePath || packagedOrg2SkillPath());
  const contents = skillSource(source);
  const destination = path.join(corpus, ORG2_SKILL_DESTINATION);
  const current = existingStatus(destination, contents);
  const base = {
    schema: "org2:skill-install:v1" as const,
    apply: options.apply === true,
    source,
    destination,
    sha256: hash(contents),
  };

  if (current === "conflict") {
    return { ...base, status: "conflict" };
  }
  if (current === "unchanged") {
    return { ...base, status: "unchanged" };
  }
  if (!options.apply) {
    return { ...base, status: "would-create" };
  }

  assertSafeDestinationParents(corpus);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  assertSafeDestinationParents(corpus);
  const afterDirectoryCreation = existingStatus(destination, contents);
  if (afterDirectoryCreation) {
    return { ...base, status: afterDirectoryCreation };
  }
  try {
    fs.writeFileSync(destination, contents, { encoding: "utf8", flag: "wx" });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    return { ...base, status: existingStatus(destination, contents) || "conflict" };
  }
  return { ...base, status: "created" };
}
