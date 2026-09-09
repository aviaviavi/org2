#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { renderOrgCharts } from "./chartRender.js";
import { findConfigFile, loadConfig } from "./config.js";
import { renderOrgDocumentToAppHtml } from "./export.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import { renderPluginSourceBlocks } from "./pluginRuntime.js";
import { readStdinText } from "./stdin.js";

function usage(exitCode = 2): never {
  const command = path.basename(process.argv[1] ?? "render-html");
  console.error(`Usage: ${command} [--source-path PATH] [--title TITLE] [--source-line-offset N] [--stylesheet PATH]`);
  process.exit(exitCode);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  let sourcePath: string | undefined;
  let title: string | undefined;
  let sourceLineOffset = 0;
  let stylesheetPath: string | undefined;

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--help" || argument === "-h") usage(0);

    if (argument === "--source-path" || argument === "--title" || argument === "--source-line-offset" || argument === "--stylesheet") {
      const value = args[index + 1];
      if (value === undefined) usage();
      index += 1;
      if (argument === "--source-path") sourcePath = value;
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

  const input = (await readStdinText()).replace(/\r\n/g, "\n");
  let renderInput = input;
  let document: ReturnType<typeof parseOrgToCanonicalAst>;
  try {
    document = parseOrgToCanonicalAst(renderInput, {
      sourceRanges: true,
      sourcePath,
      sourceLineOffset,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes("Unsupported construct: tab character")) throw error;
    renderInput = input.replace(/\t/g, "  ");
    document = parseOrgToCanonicalAst(renderInput, {
      sourceRanges: true,
      sourcePath,
      sourceLineOffset,
    });
  }
  const customCss = stylesheetPath ? fs.readFileSync(stylesheetPath, "utf8") : undefined;
  const charts = renderOrgCharts(renderInput, { file: sourcePath, sourceLineOffset })
    .filter((chart): chart is typeof chart & { svg: string; source: NonNullable<typeof chart.source> } => chart.ok && Boolean(chart.svg && chart.source))
    .map((chart) => ({ svg: chart.svg, source: chart.source, presentation: chart.presentation }));
  const pluginRenders = renderPluginSourceBlocks(document, { sourcePath }).renders;
  let linkAbbreviations: Record<string, string> | undefined;
  let linearTeam: string | undefined;
  if (sourcePath) {
    const configPath = findConfigFile(path.dirname(path.resolve(sourcePath)));
    if (configPath) {
      try {
        const config = loadConfig(configPath);
        linkAbbreviations = config.links?.abbreviations;
        linearTeam = config.links?.linearTeam;
      } catch {
        // A malformed workspace config should not make the document preview unavailable.
      }
    }
  }
  const rendered = renderOrgDocumentToAppHtml(document, {
    title,
    sourcePath,
    customCss,
    charts,
    pluginRenders,
    linkAbbreviations,
    linearTeam,
  });
  process.stdout.write(rendered.html);
}

await main();
