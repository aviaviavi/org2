import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export interface GuardedFileSnapshot {
  file: string;
  content: string;
  revision: string;
}

export interface GuardedFileWriteOptions {
  /** Preserve permissions when editing an existing ordinary source document. */
  preserveMode?: boolean;
  /** A SHA-256 revision requires an exact match. null requires the file to be absent. */
  expectedRevision?: string | null;
}

export interface GuardedFileDeleteOptions {
  /** A SHA-256 revision requires an exact match before deletion. */
  expectedRevision?: string;
}

export class GuardedFileConflictError extends Error {
  readonly code = "ORG2_WRITE_CONFLICT";
  readonly file: string;
  readonly expectedRevision?: string | null;
  readonly actualRevision?: string | null;

  constructor(
    message: string,
    input: { file: string; expectedRevision?: string | null; actualRevision?: string | null },
  ) {
    super(message);
    this.name = "GuardedFileConflictError";
    this.file = input.file;
    this.expectedRevision = input.expectedRevision;
    this.actualRevision = input.actualRevision;
  }
}

export function guardedContentRevision(content: string | Buffer): string {
  return `sha256:${crypto.createHash("sha256").update(content).digest("hex")}`;
}

export function readGuardedFile(file: string): GuardedFileSnapshot {
  const absolute = path.resolve(file);
  const content = fs.readFileSync(absolute, "utf8");
  return { file: absolute, content, revision: guardedContentRevision(content) };
}

function currentRevision(file: string): string | null {
  return fs.existsSync(file) ? guardedContentRevision(fs.readFileSync(file)) : null;
}

function writeFullyAndSync(file: string, content: string): void {
  const descriptor = fs.openSync(file, "wx", 0o600);
  try {
    fs.writeFileSync(descriptor, content, "utf8");
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

function syncDirectory(directory: string): void {
  let descriptor: number | undefined;
  try {
    descriptor = fs.openSync(directory, "r");
    fs.fsyncSync(descriptor);
  } catch {
    // Some filesystems do not permit fsync on directories. The file rename is
    // still atomic; durability falls back to the filesystem's normal policy.
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function lockOwner(lockFile: string): string {
  try {
    const parsed = JSON.parse(fs.readFileSync(lockFile, "utf8")) as {
      pid?: number;
      hostname?: string;
      createdAt?: string;
    };
    const parts = [
      Number.isInteger(parsed.pid) ? `pid ${parsed.pid}` : undefined,
      parsed.hostname ? `host ${parsed.hostname}` : undefined,
      parsed.createdAt ? `since ${parsed.createdAt}` : undefined,
    ].filter(Boolean);
    return parts.length ? ` (${parts.join(", ")})` : "";
  } catch {
    return "";
  }
}

export function guardedWriteFile(
  file: string,
  content: string,
  options: GuardedFileWriteOptions = {},
): GuardedFileSnapshot {
  const absolute = path.resolve(file);
  const directory = path.dirname(absolute);
  fs.mkdirSync(directory, { recursive: true });
  const lockFile = `${absolute}.lock`;
  let lockDescriptor: number;
  try {
    lockDescriptor = fs.openSync(lockFile, "wx", 0o600);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    throw new GuardedFileConflictError(
      `file is already being updated${lockOwner(lockFile)}: ${absolute}`,
      { file: absolute },
    );
  }

  let temporary: string | undefined;
  try {
    fs.writeFileSync(lockDescriptor, `${JSON.stringify({
      schema: "org2:write-lock:v1",
      pid: process.pid,
      hostname: os.hostname(),
      createdAt: new Date().toISOString(),
      file: absolute,
    }, null, 2)}\n`, "utf8");
    fs.fsyncSync(lockDescriptor);

    const actualRevision = currentRevision(absolute);
    if (options.expectedRevision === null && actualRevision !== null) {
      throw new GuardedFileConflictError(
        `refusing to replace an existing file that was expected to be absent: ${absolute}`,
        { file: absolute, expectedRevision: null, actualRevision },
      );
    }
    if (typeof options.expectedRevision === "string" && actualRevision !== options.expectedRevision) {
      throw new GuardedFileConflictError(
        `file changed after it was read; expected ${options.expectedRevision}, found ${actualRevision || "absent"}: ${absolute}`,
        { file: absolute, expectedRevision: options.expectedRevision, actualRevision },
      );
    }

    temporary = `${absolute}.${process.pid}.${crypto.randomUUID()}.tmp`;
    writeFullyAndSync(temporary, content);
    if (options.preserveMode && actualRevision !== null) fs.chmodSync(temporary, fs.statSync(absolute).mode & 0o777);
    fs.renameSync(temporary, absolute);
    temporary = undefined;
    syncDirectory(directory);
    return { file: absolute, content, revision: guardedContentRevision(content) };
  } finally {
    if (temporary && fs.existsSync(temporary)) fs.unlinkSync(temporary);
    fs.closeSync(lockDescriptor);
    if (fs.existsSync(lockFile)) fs.unlinkSync(lockFile);
  }
}

export function guardedDeleteFile(
  file: string,
  options: GuardedFileDeleteOptions = {},
): GuardedFileSnapshot {
  const absolute = path.resolve(file);
  const directory = path.dirname(absolute);
  const lockFile = `${absolute}.lock`;
  let lockDescriptor: number;
  try {
    lockDescriptor = fs.openSync(lockFile, "wx", 0o600);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    throw new GuardedFileConflictError(
      `file is already being updated${lockOwner(lockFile)}: ${absolute}`,
      { file: absolute },
    );
  }

  try {
    fs.writeFileSync(lockDescriptor, `${JSON.stringify({
      schema: "org2:write-lock:v1",
      pid: process.pid,
      hostname: os.hostname(),
      createdAt: new Date().toISOString(),
      file: absolute,
    }, null, 2)}\n`, "utf8");
    fs.fsyncSync(lockDescriptor);

    const actualRevision = currentRevision(absolute);
    if (typeof options.expectedRevision === "string" && actualRevision !== options.expectedRevision) {
      throw new GuardedFileConflictError(
        `file changed after it was read; expected ${options.expectedRevision}, found ${actualRevision || "absent"}: ${absolute}`,
        { file: absolute, expectedRevision: options.expectedRevision, actualRevision },
      );
    }

    const snapshot = readGuardedFile(absolute);
    fs.unlinkSync(absolute);
    syncDirectory(directory);
    return snapshot;
  } finally {
    fs.closeSync(lockDescriptor);
    if (fs.existsSync(lockFile)) fs.unlinkSync(lockFile);
  }
}
