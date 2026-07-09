#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { renderOrgDocumentToAppHtml } from "./export.js";
import { parseOrgToCanonicalAst } from "./parser.js";

function usage(exitCode = 2): never {
  const command = path.basename(process.argv[1] ?? "render-html");
  console.error(`Usage: ${command} [--source-path PATH] [--title TITLE] [--source-line-offset N]`);
  process.exit(exitCode);
}

function main(): void {
  const args = process.argv.slice(2);
  let sourcePath: string | undefined;
  let title: string | undefined;
  let sourceLineOffset = 0;

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--help" || argument === "-h") usage(0);

    if (argument === "--source-path" || argument === "--title" || argument === "--source-line-offset") {
      const value = args[index + 1];
      if (value === undefined) usage();
      index += 1;
      if (argument === "--source-path") sourcePath = value;
      if (argument === "--title") title = value;
      if (argument === "--source-line-offset") {
        sourceLineOffset = Number.parseInt(value, 10);
        if (!Number.isFinite(sourceLineOffset) || sourceLineOffset < 0) usage();
      }
      continue;
    }

    usage();
  }

  const input = fs.readFileSync(0, "utf8").replace(/\r\n/g, "\n");
  const document = parseOrgToCanonicalAst(input, {
    sourceRanges: true,
    sourceLineOffset,
  });
  const rendered = renderOrgDocumentToAppHtml(document, { title, sourcePath });
  process.stdout.write(rendered.html);
}

main();
