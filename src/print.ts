#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { printCanonicalAstToOrg } from "./printer.js";

function usage(): never {
  const cmd = path.basename(process.argv[1] ?? "print");
  console.error(`Usage: ${cmd} <ast.json>`);
  process.exit(2);
}

function main() {
  const filePath = process.argv[2];
  if (!filePath) usage();

  const raw = fs.readFileSync(filePath, "utf8");
  const ast = JSON.parse(raw);
  const out = printCanonicalAstToOrg(ast);
  process.stdout.write(out);
}

main();
