import { randomUUID } from "node:crypto";
import { existsSync, renameSync, rmSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

export function installStagedAppBundle({ stagedAppPath, targetAppPath }) {
  const stagedPath = resolve(stagedAppPath);
  const targetPath = resolve(targetAppPath);
  if (stagedPath === targetPath) {
    throw new Error("The staged and target app paths must be different");
  }
  if (!existsSync(stagedPath)) {
    throw new Error(`Staged app bundle not found at ${stagedPath}`);
  }

  const backupPath = join(
    dirname(targetPath),
    `.${basename(targetPath)}.backup-${randomUUID()}`
  );
  const hadExistingTarget = existsSync(targetPath);
  if (hadExistingTarget) {
    renameSync(targetPath, backupPath);
  }

  try {
    renameSync(stagedPath, targetPath);
  } catch (error) {
    if (hadExistingTarget && !existsSync(targetPath) && existsSync(backupPath)) {
      renameSync(backupPath, targetPath);
    }
    throw error;
  }

  if (hadExistingTarget) {
    rmSync(backupPath, { recursive: true, force: true });
  }
}
