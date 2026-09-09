#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { parseNonNegativeIntegerArgument } from "./cliArguments.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import { readStdinText } from "./stdin.js";

function usage(exitCode = 2): never {
  const cmd = path.basename(process.argv[1] ?? "parse");
  console.error(`Usage: ${cmd} [--source-ranges] [--source-line-offset N] [--source-path FILE] <file.org|->`);
  process.exit(exitCode);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args.includes("--help") || args.includes("-h")) {
    usage(0);
  }

  let sourceRanges = false;
  let sourceLineOffset = 0;
  let sourcePath: string | undefined;
  const positional: string[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--source-path") {
      sourcePath = args[++index];
      if (!sourcePath) usage();
      continue;
    }
    if (arg === "--source-ranges") {
      sourceRanges = true;
      continue;
    }
    if (arg === "--source-line-offset") {
      const raw = args[index + 1];
      const parsed = parseNonNegativeIntegerArgument(raw);
      if (parsed === null) usage();
      sourceLineOffset = parsed;
      index += 1;
      continue;
    }
    if (arg?.startsWith("--source-line-offset=")) {
      const raw = arg.slice("--source-line-offset=".length);
      const parsed = parseNonNegativeIntegerArgument(raw);
      if (parsed === null) usage();
      sourceLineOffset = parsed;
      continue;
    }
    positional.push(arg);
  }

  const filePath = positional[0];
  if (!filePath) {
    usage();
  }
  if (positional.length > 1) {
    usage();
  }

  const input = filePath === "-" ? await readStdinText() : fs.readFileSync(filePath, "utf8");
  const ast = parseOrgToCanonicalAst(input, { sourceRanges, sourceLineOffset, sourcePath: sourcePath ?? (filePath === "-" ? undefined : filePath) });
  process.stdout.write(`${JSON.stringify(ast, null, 2)}\n`);
}

await main();
