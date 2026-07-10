#!/usr/bin/env node

import fs from "node:fs";
import process from "node:process";
import { parseOrgWithDiagnostics } from "./parser.js";

function usage(exitCode = 2): never {
  console.error("Usage: editor-analysis [--source-line-offset N]");
  process.exit(exitCode);
}

function main() {
  const args = process.argv.slice(2);
  if (args.includes("--help") || args.includes("-h")) usage(0);

  let sourceLineOffset = 0;
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--source-line-offset") {
      const raw = args[index + 1];
      if (raw === undefined) usage();
      sourceLineOffset = Number.parseInt(raw, 10);
      if (!Number.isFinite(sourceLineOffset) || sourceLineOffset < 0) usage();
      index += 1;
      continue;
    }
    if (arg?.startsWith("--source-line-offset=")) {
      sourceLineOffset = Number.parseInt(arg.slice("--source-line-offset=".length), 10);
      if (!Number.isFinite(sourceLineOffset) || sourceLineOffset < 0) usage();
      continue;
    }
    usage();
  }

  const input = fs.readFileSync(0, "utf8");
  const result = parseOrgWithDiagnostics(input, {
    sourceRanges: true,
    sourceLineOffset,
  });
  process.stdout.write(`${JSON.stringify({
    document: result.ast,
    diagnostics: result.diagnostics,
  })}\n`);
}

main();
