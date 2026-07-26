import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const LOCK_SCHEMA = "org2:mutation-lock-owner:v2";
const LOCK_OWNER_KEYS = new Set([
  "schema",
  "host",
  "pid",
  "token",
  "phase",
  "ticket",
  "createdAt",
]);
const UUID_TOKEN_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

interface LockParticipant {
  schema: typeof LOCK_SCHEMA;
  host: string;
  pid: number;
  token: string;
  phase: "choosing" | "ticket";
  ticket?: number;
  createdAt: string;
}

interface PublishedParticipant {
  file: string;
  raw: string;
  participant: LockParticipant;
}

function mutationLockPath(file: string): string {
  return path.join(path.dirname(file), `.${path.basename(file)}.org2-mutation.lock`);
}

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== "ESRCH";
  }
}

function participantRaw(participant: LockParticipant): string {
  return `${JSON.stringify(participant)}\n`;
}

function parseParticipant(raw: string): LockParticipant | undefined {
  try {
    const parsed = JSON.parse(raw) as Partial<LockParticipant>;
    if (
      !Object.keys(parsed).every((key) => LOCK_OWNER_KEYS.has(key))
      || parsed.schema !== LOCK_SCHEMA
      || typeof parsed.host !== "string"
      || parsed.host.length === 0
      || !Number.isSafeInteger(parsed.pid)
      || Number(parsed.pid) <= 0
      || Number(parsed.pid) > 2_147_483_647
      || typeof parsed.token !== "string"
      || !UUID_TOKEN_PATTERN.test(parsed.token)
      || (parsed.phase !== "choosing" && parsed.phase !== "ticket")
      || typeof parsed.createdAt !== "string"
      || parsed.createdAt.length === 0
      || (parsed.phase === "ticket" && (!Number.isSafeInteger(parsed.ticket) || Number(parsed.ticket) <= 0))
      || (parsed.phase === "choosing" && parsed.ticket !== undefined)
    ) {
      return undefined;
    }
    return parsed as LockParticipant;
  } catch {
    return undefined;
  }
}

function participantIdentity(name: string): Pick<LockParticipant, "phase" | "ticket" | "token"> | undefined {
  const choosing = /^choosing\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.json$/.exec(name);
  if (choosing) return { phase: "choosing", token: choosing[1]! };
  const ticket = /^ticket\.(\d{16})\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.json$/.exec(name);
  if (!ticket) return undefined;
  const value = Number(ticket[1]);
  if (!Number.isSafeInteger(value) || value <= 0 || String(value).padStart(16, "0") !== ticket[1]) {
    return undefined;
  }
  return { phase: "ticket", ticket: value, token: ticket[2]! };
}

function publishParticipant(lockDirectory: string, name: string, raw: string): string {
  const file = path.join(lockDirectory, name);
  const candidate = path.join(
    lockDirectory,
    `.candidate.${process.pid}.${crypto.randomUUID()}`,
  );
  fs.writeFileSync(candidate, raw, { encoding: "utf8", mode: 0o600, flag: "wx" });
  try {
    fs.linkSync(candidate, file);
  } finally {
    try {
      fs.unlinkSync(candidate);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
  return file;
}

function removeIfUnchanged(file: string, raw: string): void {
  try {
    if (fs.readFileSync(file, "utf8") === raw) fs.unlinkSync(file);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

function activeParticipants(lockDirectory: string, currentHost: string): PublishedParticipant[] {
  const active: PublishedParticipant[] = [];
  for (const name of fs.readdirSync(lockDirectory)) {
    if (name.startsWith(".candidate.")) continue;
    const identity = participantIdentity(name);
    if (!identity) {
      throw new Error(`unrecognized Org2 mutation-lock participant ${path.join(lockDirectory, name)}`);
    }
    const file = path.join(lockDirectory, name);
    let raw: string;
    try {
      raw = fs.readFileSync(file, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
      throw error;
    }
    const participant = parseParticipant(raw);
    if (
      !participant
      || participant.phase !== identity.phase
      || participant.token !== identity.token
      || participant.ticket !== identity.ticket
    ) {
      throw new Error(`invalid Org2 mutation-lock participant ${file}`);
    }
    if (participant.host === currentHost && !processIsAlive(participant.pid)) {
      // Participant paths contain a random immutable token and are never reused,
      // so dead same-host owners can be removed without touching a successor.
      removeIfUnchanged(file, raw);
      continue;
    }
    active.push({ file, raw, participant });
  }
  return active;
}

function compareTickets(
  left: Pick<LockParticipant, "ticket" | "token">,
  right: Pick<LockParticipant, "ticket" | "token">,
): number {
  const ticketDifference = Number(left.ticket) - Number(right.ticket);
  if (ticketDifference !== 0) return ticketDifference;
  return Buffer.compare(Buffer.from(left.token, "utf8"), Buffer.from(right.token, "utf8"));
}

function acquireMutationLock(lockDirectory: string): PublishedParticipant {
  try {
    fs.mkdirSync(lockDirectory, { recursive: true, mode: 0o700 });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") {
      throw new Error(
        `the legacy Org2 mutation lock at ${lockDirectory} is not compatible with the crash-safe lock protocol`,
      );
    }
    throw error;
  }
  if (!fs.lstatSync(lockDirectory).isDirectory()) {
    throw new Error(`the Org2 mutation lock at ${lockDirectory} is not a directory`);
  }

  const host = os.hostname();
  const token = crypto.randomUUID();
  const createdAt = new Date().toISOString();
  const choosing: LockParticipant = {
    schema: LOCK_SCHEMA,
    host,
    pid: process.pid,
    token,
    phase: "choosing",
    createdAt,
  };
  const choosingRaw = participantRaw(choosing);
  const choosingFile = publishParticipant(lockDirectory, `choosing.${token}.json`, choosingRaw);
  let ticketFile: string | undefined;
  let ticketRaw: string | undefined;

  try {
    const existing = activeParticipants(lockDirectory, host);
    const nextTicket = existing.reduce(
      (maximum, item) => item.participant.phase === "ticket"
        ? Math.max(maximum, Number(item.participant.ticket))
        : maximum,
      0,
    ) + 1;
    if (!Number.isSafeInteger(nextTicket) || nextTicket <= 0) {
      throw new Error(`the Org2 mutation-lock ticket space is exhausted for ${lockDirectory}`);
    }
    const ticket: LockParticipant = {
      ...choosing,
      phase: "ticket",
      ticket: nextTicket,
    };
    ticketRaw = participantRaw(ticket);
    ticketFile = publishParticipant(
      lockDirectory,
      `ticket.${String(nextTicket).padStart(16, "0")}.${token}.json`,
      ticketRaw,
    );
    removeIfUnchanged(choosingFile, choosingRaw);

    const contenders = activeParticipants(lockDirectory, host);
    const blocker = contenders.find((item) => (
      item.participant.token !== token
      && (
        item.participant.phase === "choosing"
        || compareTickets(item.participant, ticket) < 0
      )
    ));
    if (blocker) {
      throw new Error(`another Org2 process is already updating ${lockDirectory}`);
    }
    return { file: ticketFile, raw: ticketRaw, participant: ticket };
  } catch (error) {
    removeIfUnchanged(choosingFile, choosingRaw);
    if (ticketFile && ticketRaw) removeIfUnchanged(ticketFile, ticketRaw);
    throw error;
  }
}

export function withFileMutationLock<T>(file: string, mutate: () => T): T {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const lockDirectory = mutationLockPath(file);
  const owner = acquireMutationLock(lockDirectory);

  try {
    return mutate();
  } finally {
    removeIfUnchanged(owner.file, owner.raw);
  }
}

export function withFileMutationLocks<T>(files: string[], mutate: () => T): T {
  const ordered = [...new Set(files.map((file) => path.resolve(file)))].sort();
  const acquire = (index: number): T => (
    index >= ordered.length
      ? mutate()
      : withFileMutationLock(ordered[index]!, () => acquire(index + 1))
  );
  return acquire(0);
}

export function writeTextAtomicallyIfUnchanged(file: string, expected: string, updated: string): void {
  const current = fs.readFileSync(file, "utf8");
  if (current !== expected) {
    throw new Error(`concurrent modification detected for ${file}; refresh and retry`);
  }

  const stat = fs.statSync(file);
  const temporary = path.join(
    path.dirname(file),
    `.${path.basename(file)}.${process.pid}.${crypto.randomUUID()}.tmp`,
  );
  try {
    fs.writeFileSync(temporary, updated, { encoding: "utf8", mode: stat.mode });
    fs.renameSync(temporary, file);
  } finally {
    if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
  }
}
