#!/usr/bin/env node

import path from "node:path";
import process from "node:process";
import { readStdinText } from "./stdin.js";
import { renderAppHTML } from "./appHtmlRenderer.js";

function usage(exitCode = 2): never {
  const command = path.basename(process.argv[1] ?? "render-html");
  console.error(`Usage: ${command} [--source-path PATH] [--title TITLE] [--source-line-offset N] [--stylesheet PATH] [--corpus-root PATH] [--reference-embeds]`);
  process.exit(exitCode);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  let sourcePath: string | undefined;
  let title: string | undefined;
  let corpusRoot: string | undefined;
  let referenceEmbeds = false;
  let sourceLineOffset = 0;
  let stylesheetPath: string | undefined;

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--help" || argument === "-h") usage(0);

    if (argument === "--reference-embeds") { referenceEmbeds = true; continue; }
    if (argument === "--corpus-root" || argument === "--source-path" || argument === "--title" || argument === "--source-line-offset" || argument === "--stylesheet") {
      const value = args[index + 1];
      if (value === undefined) usage();
      index += 1;
      if (argument === "--source-path") sourcePath = value;
      if (argument === "--corpus-root") corpusRoot = value;
      if (argument === "--title") title = value;
      if (argument === "--stylesheet") stylesheetPath = value;
      if (argument === "--source-line-offset") {
        sourceLineOffset = Number.parseInt(value, 10);
        if (!Number.isFinite(sourceLineOffset) || sourceLineOffset < 0) usage();
      }
      continue;
    }

    usage();
  }

  const input = await readStdinText();
  const html = renderAppHTML(input, {
    title,
    sourcePath,
    corpusRoot,
    referenceEmbeds,
    sourceLineOffset,
    stylesheetPath,
  });
  process.stdout.write(html);
}

await main();
