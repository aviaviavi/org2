import fs from "node:fs";
import path from "node:path";
import { renderOrgCharts } from "./chartRender.js";
import { findConfigFile, loadConfig } from "./config.js";
import { renderOrgDocumentToAppHtml } from "./export.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import { renderPluginSourceBlocks } from "./pluginRuntime.js";
import { createLiveEmbedResolver } from "./liveEmbeds.js";

export interface AppHTMLRenderOptions {
  sourcePath?: string;
  title?: string;
  corpusRoot?: string;
  referenceEmbeds?: boolean;
  sourceLineOffset?: number;
  stylesheetPath?: string;
}

export function renderAppHTML(input: string, options: AppHTMLRenderOptions): string {
  const sourcePath = options.sourcePath;
  const sourceLineOffset = options.sourceLineOffset ?? 0;
  const normalizedInput = input.replace(/\r\n/g, "\n");
  let renderInput = normalizedInput;
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
    renderInput = normalizedInput.replace(/\t/g, "  ");
    document = parseOrgToCanonicalAst(renderInput, {
      sourceRanges: true,
      sourcePath,
      sourceLineOffset,
    });
  }

  const customCss = options.stylesheetPath
    ? fs.readFileSync(options.stylesheetPath, "utf8")
    : undefined;
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

  return renderOrgDocumentToAppHtml(document, {
    title: options.title,
    sourcePath,
    customCss,
    charts,
    pluginRenders,
    linkAbbreviations,
    linearTeam,
    embedResolver: sourcePath && !options.referenceEmbeds
      ? createLiveEmbedResolver({ sourcePath, rootDir: options.corpusRoot })
      : undefined,
  }).html;
}
