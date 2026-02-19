import fs from "node:fs";
import path from "node:path";

export type Org2PublishProjectConfig = {
  baseDir: string;
  outDir: string;
  recursive?: boolean;
  include?: string[];
  ignore?: string[];
  index?: string | { file: string; title?: string };
  stylesheets?: string[];
  includeDefaultStyle?: boolean;
  toc?: boolean;
  tocDepth?: number;
  numberHeadings?: boolean;
  numberHeadingsDepth?: number;
  rewriteFileLinks?: boolean;
  postambleHtml?: string;
  headIncludes?: string[];
  syntaxHighlighting?: boolean;
  assets?: {
    include?: string[];
    ignore?: string[];
  };
};

export interface Org2Config {
  agendaFiles?: string[];
  recursive?: boolean;
  ignorePatterns?: string[];
  todo?: {
    writeTransitionLogbook?: boolean;
  };
  publish?: {
    projects?: Record<string, Org2PublishProjectConfig>;
  };
}

export function findConfigFile(startDir: string): string | null {
  let currentDir = path.resolve(startDir);

  for (let i = 0; i < 10; i++) {
    const configPath = path.join(currentDir, "org2.json");
    if (fs.existsSync(configPath)) {
      return configPath;
    }

    const parentDir = path.dirname(currentDir);
    if (parentDir === currentDir) {
      break;
    }
    currentDir = parentDir;
  }

  return null;
}

export function loadConfig(configPath: string): Org2Config {
  try {
    const content = fs.readFileSync(configPath, "utf8");
    return JSON.parse(content) as Org2Config;
  } catch (err) {
    throw new Error(
      `Failed to load config from ${configPath}: ${err instanceof Error ? err.message : String(err)}`
    );
  }
}

export function getDefaultConfig(): Org2Config {
  return {
    agendaFiles: ["*.org"],
    recursive: true,
    ignorePatterns: [".git/**", "node_modules/**", ".#*"],
  };
}

function normalizePathForMatch(value: string): string {
  return String(value || "").replace(/\\/g, "/");
}

function segmentMatches(pathSegment: string, patternSegment: string): boolean {
  const escaped = patternSegment.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  const regex = new RegExp(`^${escaped.replace(/\*/g, ".*")}$`);
  return regex.test(pathSegment);
}

function matchSegments(pathSegments: string[], patternSegments: string[], pi: number = 0, pj: number = 0): boolean {
  if (pj >= patternSegments.length) return pi >= pathSegments.length;

  const pat = patternSegments[pj];
  if (pat === "**") {
    for (let k = pi; k <= pathSegments.length; k += 1) {
      if (matchSegments(pathSegments, patternSegments, k, pj + 1)) return true;
    }
    return false;
  }

  if (pi >= pathSegments.length) return false;
  if (!segmentMatches(pathSegments[pi] ?? "", pat)) return false;
  return matchSegments(pathSegments, patternSegments, pi + 1, pj + 1);
}

function matchesPattern(filePath: string, pattern: string): boolean {
  const normalizedPath = normalizePathForMatch(filePath);
  const normalizedPattern = normalizePathForMatch(pattern);

  if (normalizedPattern.includes("*")) {
    const pathSegments = normalizedPath.split("/").filter((seg) => seg.length > 0);
    const patternSegments = normalizedPattern.split("/").filter((seg) => seg.length > 0);
    return matchSegments(pathSegments, patternSegments);
  }

  return normalizedPath === normalizedPattern || normalizedPath.startsWith(normalizedPattern + "/");
}

function shouldIgnore(filePath: string, ignorePatterns: string[]): boolean {
  for (const pattern of ignorePatterns) {
    if (matchesPattern(filePath, pattern)) {
      return true;
    }
  }
  return false;
}

export function resolveFilesFromDir(
  dir: string,
  patterns: string[],
  ignorePatterns: string[],
  recursive: boolean = true
): string[] {
  const allFiles: string[] = [];

  function walk(currentPath: string, relPath: string = ""): void {
    try {
      const entries = fs.readdirSync(currentPath, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = path.join(currentPath, entry.name);
        const relativePath = relPath ? path.join(relPath, entry.name) : entry.name;

        if (shouldIgnore(relativePath, ignorePatterns)) {
          continue;
        }

        if (entry.isDirectory()) {
          if (recursive && !entry.name.startsWith(".")) {
            walk(fullPath, relativePath);
          }
        } else if (entry.isFile()) {
          for (const pattern of patterns) {
            if (matchesPattern(relativePath, pattern)) {
              allFiles.push(path.resolve(fullPath));
              break;
            }
          }
        }
      }
    } catch (err) {
      console.error(
        `Error reading directory ${currentPath}: ${err instanceof Error ? err.message : String(err)}`
      );
    }
  }

  walk(dir);
  return allFiles.sort();
}

export function resolveFilesFromConfig(
  config: Org2Config,
  baseDir: string = process.cwd()
): string[] {
  const patterns = config.agendaFiles || ["*.org"];
  const ignorePatterns = config.ignorePatterns || [];
  const recursive = config.recursive !== false;

  return resolveFilesFromDir(baseDir, patterns, ignorePatterns, recursive);
}
