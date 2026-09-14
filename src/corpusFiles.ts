import fs from "node:fs";
import path from "node:path";

const DEFAULT_IGNORED_CORPUS_DIRECTORIES = new Set([
  ".git",
  ".hg",
  ".svn",
  ".stversions",
  ".trash",
  ".org2",
  "node_modules",
  "dist",
  "build",
  ".build",
  "DerivedData",
  "sync-conflicts",
]);

export function isDefaultArchivePath(filePath: string): boolean {
  const normalized = filePath.replace(/\\/g, "/").toLowerCase();
  const base = path.basename(normalized);
  return (
    normalized.includes("/archive/") ||
    normalized.includes("/archives/") ||
    base.endsWith(".org_archive") ||
    base.endsWith(".org2_archive") ||
    base.endsWith(".archive") ||
    base.includes(".archive.") ||
    base.endsWith("_archive")
  );
}

function isDefaultIgnoredCorpusDirectoryName(name: string): boolean {
  return name.startsWith(".") || DEFAULT_IGNORED_CORPUS_DIRECTORIES.has(name);
}

function hasDefaultIgnoredCorpusPathComponent(filePath: string): boolean {
  return path.normalize(filePath)
    .split(path.sep)
    .some((component) => DEFAULT_IGNORED_CORPUS_DIRECTORIES.has(component));
}

export function isDefaultIgnoredSyncArtifactPath(filePath: string): boolean {
  const base = path.basename(filePath);
  return hasDefaultIgnoredCorpusPathComponent(filePath)
    || base.startsWith(".syncthing.")
    || base.includes(".sync-conflict-")
    || base.endsWith(".tmp");
}

export function isOrgLikeFileName(fileName: string, includeArchives = false): boolean {
  if (fileName.startsWith(".")) return false;
  if (isDefaultIgnoredSyncArtifactPath(fileName)) return false;
  if (fileName.endsWith(".org") || fileName.endsWith(".org2")) return true;
  return includeArchives && isDefaultArchivePath(fileName);
}

export function listOrgLikeFiles(rootDir: string, recursiveScan: boolean, includeArchives = false): string[] {
  const out: string[] = [];

  const walk = (directory: string): void => {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (isDefaultIgnoredCorpusDirectoryName(entry.name)) continue;
        if (recursiveScan) walk(full);
        continue;
      }

      if (!entry.isFile()) continue;
      if (!isOrgLikeFileName(entry.name, includeArchives)) continue;
      if (!includeArchives && isDefaultArchivePath(full)) continue;
      out.push(full);
    }
  };

  walk(rootDir);
  return out;
}
