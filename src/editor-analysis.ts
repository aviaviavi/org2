#!/usr/bin/env node

import process from "node:process";
import { parseNonNegativeIntegerArgument } from "./cliArguments.js";
import { parseOrgWithDiagnostics } from "./parser.js";
import { readStdinText } from "./stdin.js";

function usage(exitCode = 2): never {
  console.error("Usage: editor-analysis [--source-line-offset N]");
  process.exit(exitCode);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args.includes("--help") || args.includes("-h")) usage(0);

  let sourceLineOffset = 0;
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--source-line-offset") {
      const raw = args[index + 1];
      const parsed = parseNonNegativeIntegerArgument(raw);
      if (parsed === null) usage();
      sourceLineOffset = parsed;
      index += 1;
      continue;
    }
    if (arg?.startsWith("--source-line-offset=")) {
      const parsed = parseNonNegativeIntegerArgument(arg.slice("--source-line-offset=".length));
      if (parsed === null) usage();
      sourceLineOffset = parsed;
      continue;
    }
    usage();
  }

  const input = await readStdinText();
  const result = parseOrgWithDiagnostics(input, {
    sourceRanges: true,
    sourceLineOffset,
  });
  process.stdout.write(`${JSON.stringify({
    document: result.ast,
    diagnostics: result.diagnostics,
  })}\n`);
}

await main();
