#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { parseOrgToCanonicalAst } from "./parser.js";

function usage(exitCode = 2): never {
  const cmd = path.basename(process.argv[1] ?? "parse");
  console.error(`Usage: ${cmd} [--source-ranges] [--source-line-offset N] <file.org|->`);
  process.exit(exitCode);
}

function main() {
  const args = process.argv.slice(2);
  if (args.includes("--help") || args.includes("-h")) {
    usage(0);
  }

  let sourceRanges = false;
  let sourceLineOffset = 0;
  const positional: string[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--source-ranges") {
      sourceRanges = true;
      continue;
    }
    if (arg === "--source-line-offset") {
      const raw = args[index + 1];
      if (raw === undefined) usage();
      sourceLineOffset = Number.parseInt(raw, 10);
      if (!Number.isFinite(sourceLineOffset) || sourceLineOffset < 0) usage();
      index += 1;
      continue;
    }
    if (arg?.startsWith("--source-line-offset=")) {
      const raw = arg.slice("--source-line-offset=".length);
      sourceLineOffset = Number.parseInt(raw, 10);
      if (!Number.isFinite(sourceLineOffset) || sourceLineOffset < 0) usage();
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

  const input = filePath === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(filePath, "utf8");
  const ast = parseOrgToCanonicalAst(input, { sourceRanges, sourceLineOffset });
  process.stdout.write(`${JSON.stringify(ast, null, 2)}\n`);
}

main();
