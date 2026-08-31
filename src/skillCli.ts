import path from "node:path";
import { installPackagedOrg2Skill } from "./skillRuntime.js";

const HELP = `org2 skill install

Install the packaged general Org2 agent skill into a corpus.

Usage:
  org2 skill install [--dir CORPUS] [--apply] [--format text|json]

The command previews by default. --apply creates
.agents/skills/org2/SKILL.md only when that path is absent. It never overwrites
an existing skill; a different existing copy is reported as a conflict.`;

function flag(args: string[], name: string): string | undefined {
  const exact = args.lastIndexOf(`--${name}`);
  if (exact >= 0) return args[exact + 1];
  const prefix = `--${name}=`;
  for (let index = args.length - 1; index >= 0; index -= 1) {
    const value = args[index]!;
    if (value.startsWith(prefix)) return value.slice(prefix.length);
  }
  return undefined;
}

export async function runSkillCommand(args: string[]): Promise<boolean> {
  if (args[0] !== "skill") return false;
  const values = args.slice(1);
  if (values.includes("--help") || values.includes("-h") || values[0] === "help") {
    process.stdout.write(`${HELP}\n`);
    return true;
  }
  const action = values.find((value) => !value.startsWith("-")) || "install";
  if (action !== "install") throw new Error(`unknown skill action: ${action}`);

  const result = installPackagedOrg2Skill({
    corpus: path.resolve(flag(values, "dir") || "."),
    apply: values.includes("--apply"),
  });
  if (flag(values, "format") === "json" || values.includes("--json")) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else if (result.status === "would-create") {
    process.stdout.write(`would install Org2 skill at ${result.destination}\nRun again with --apply to create it.\n`);
  } else if (result.status === "created") {
    process.stdout.write(`installed Org2 skill at ${result.destination}\n`);
  } else if (result.status === "unchanged") {
    process.stdout.write(`Org2 skill is already current at ${result.destination}\n`);
  } else {
    process.stdout.write(`kept existing Org2 skill at ${result.destination}\nThe installer never overwrites a user-managed copy.\n`);
  }
  if (result.status === "conflict") process.exitCode = 2;
  return true;
}
