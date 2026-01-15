#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { parseOrgToCanonicalAst } from "./parser.js";

function usage(): never {
  const cmd = path.basename(process.argv[1] ?? "parse");
  console.error(`Usage: ${cmd} <file.org>`);
  process.exit(2);
}

function main() {
  const filePath = process.argv[2];
  if (!filePath) usage();

  const input = fs.readFileSync(filePath, "utf8");
  const ast = parseOrgToCanonicalAst(input);
  process.stdout.write(`${JSON.stringify(ast, null, 2)}\n`);
}

main();
