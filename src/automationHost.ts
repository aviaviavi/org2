import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { safeIdentifier } from "./safeIdentifier.js";

/** A portable, symbolic owner; addresses and credentials belong to local server config. */
export function automationHostRef(root: string): string {
  const file = path.join(root, "org2.json");
  if (!fs.existsSync(file)) return "desktop";
  const config = JSON.parse(fs.readFileSync(file, "utf8"));
  return safeIdentifier(config.automationHostRef ?? "desktop");
}

export function assignAutomationHost(root: string, hostRef: string, apply: boolean) {
  const owner = safeIdentifier(hostRef);
  const snapshot = readGuardedFile(path.join(root, "org2.json"));
  const config = JSON.parse(snapshot.content);
  const previousHostRef = config.automationHostRef ?? "desktop";
  config.automationHostRef = owner;
  const changed = previousHostRef !== owner;
  if (apply && changed) guardedWriteFile(snapshot.file, `${JSON.stringify(config, null, 2)}\n`, { expectedRevision: snapshot.revision });
  return { hostRef: owner, previousHostRef, changed, applied: apply && changed, file: snapshot.file };
}

/** Serialize check-and-create for one workflow on an actual shared filesystem. */
export function acquireWorkflowDispatchLock(root: string, workflowID: string): () => void {
  const directory = path.join(root, ".org2", "workflow-dispatch-locks");
  fs.mkdirSync(directory, { recursive: true });
  const file = path.join(directory, `${safeIdentifier(workflowID)}.lock`);
  // Do not reclaim ambiguous locks or locks owned by another machine. A person
  // can inspect/remove an orphan after confirming that its executor has stopped.
  const descriptor = fs.openSync(file, "wx", 0o600);
  try { fs.writeFileSync(descriptor, JSON.stringify({ pid: process.pid, hostname: os.hostname() })); }
  catch (error) { fs.closeSync(descriptor); fs.unlinkSync(file); throw error; }
  return () => { fs.closeSync(descriptor); fs.unlinkSync(file); };
}
