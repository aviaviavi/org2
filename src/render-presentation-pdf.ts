#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { compileBeamerPdf } from "./beamerCompile.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import { renderPresentationToBeamer } from "./presentation.js";

function usage(exitCode = 2): never {
  const command = path.basename(process.argv[1] ?? "render-presentation-pdf");
  console.error(`Usage: ${command} --source-path PATH [--latex-engine COMMAND] [--passes N]`);
  process.exit(exitCode);
}

function main(): void {
  const args = process.argv.slice(2);
  let sourcePath: string | undefined;
  let latexEngine: string | undefined;
  let passes = 1;

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--help" || argument === "-h") usage(0);

    if (argument === "--source-path" || argument === "--latex-engine" || argument === "--passes") {
      const value = args[index + 1];
      if (value === undefined) usage();
      index += 1;
      if (argument === "--source-path") sourcePath = value;
      if (argument === "--latex-engine") latexEngine = value;
      if (argument === "--passes") {
        passes = Number.parseInt(value, 10);
        if (!Number.isFinite(passes) || passes < 1 || passes > 4) usage();
      }
      continue;
    }

    usage();
  }

  if (!sourcePath) usage();

  const input = fs.readFileSync(0, "utf8").replace(/\r\n/g, "\n");
  let rendered: ReturnType<typeof renderPresentationToBeamer>;
  try {
    const document = parseOrgToCanonicalAst(input, { sourceRanges: true });
    rendered = renderPresentationToBeamer(document);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`Error: ${message}`);
    process.exit(1);
  }
  const fatalDiagnostics = rendered.diagnostics.filter((diagnostic) => diagnostic.severity === "error");
  if (fatalDiagnostics.length > 0) {
    for (const diagnostic of fatalDiagnostics.slice(0, 3)) {
      console.error(
        `Error${diagnostic.line ? `:${diagnostic.line}` : ""}: ${diagnostic.message} (${diagnostic.code})`,
      );
    }
    process.exit(1);
  }

  const compiled = compileBeamerPdf(rendered.tex, {
    sourcePath,
    engine: latexEngine,
    passes,
  });
  if (!compiled.ok) {
    console.error(`Error: ${compiled.message}`);
    process.exit(1);
  }

  process.stdout.write(compiled.pdf);
}

main();
