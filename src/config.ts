import fs from "node:fs";
import path from "node:path";

export interface Org2Config {
  agendaFiles?: string[];
  recursive?: boolean;
  ignorePatterns?: string[];
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

function matchesPattern(filePath: string, pattern: string): boolean {
  if (pattern.includes("**")) {
    const parts = pattern.split("**");
    if (parts.length === 2) {
      const prefix = parts[0].replace(/\/$/, "");
      const suffix = parts[1].replace(/^\//, "");

      if (prefix && !filePath.startsWith(prefix)) return false;
      if (suffix) {
        const remaining = filePath.slice(prefix ? prefix.length + 1 : 0);
        return (
          suffix === "*" ||
          remaining.endsWith(suffix) ||
          new RegExp(`.*${suffix.replace(/\./g, "\\.")}$`).test(remaining)
        );
      }
      return true;
    }
  }

  if (pattern.startsWith("*.")) {
    const ext = pattern.slice(1);
    return filePath.endsWith(ext);
  }

  return filePath === pattern || filePath.startsWith(pattern + "/");
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
