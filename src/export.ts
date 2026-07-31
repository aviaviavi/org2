import path from "node:path";
import type {
  BlockNode,
  DocumentNode,
  EmphasisNode,
  HeadlineNode,
  InlineNode,
  LinkNode,
  ListItemNode,
  ListNode,
  Node,
  ParagraphNode,
  PlanningNode,
  PropertyDrawerNode,
  SrcBlockNode,
  TableHlineNode,
  TableNode,
  TableRowNode,
  TimestampNode,
  TimestampRangeNode,
} from "./ast.js";
import { parseInlinesFromText } from "./parser.js";
import {
  buildBuiltInLinkAbbreviations,
  collectLinkAbbreviationsFromDoc,
  collectLinkAbbreviationsFromRecord,
  expandLinkAbbreviationTarget,
  mergeLinkAbbreviations,
  type LinkAbbreviationMap,
  type LinkAbbreviationRecord,
} from "./link-abbrev.js";
import { COMPAT_CONTENT_CLOSE, COMPAT_CONTENT_OPEN, COMPAT_CONTENT_STYLE_SECTION } from "./publish-defaults.js";

function escapeHtml(value: string): string {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;");
}

function escapeAttr(value: string): string {
  return escapeHtml(value).replace(/`/g, "&#96;");
}

function normalizeStylesheets(stylesheets: string[] | undefined): string[] {
  if (!Array.isArray(stylesheets)) return [];
  return stylesheets.map((href) => String(href || "").trim()).filter((href) => href.length > 0);
}

const DEFAULT_DOCUMENT_STYLE = `:root { color-scheme: light dark; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem auto; max-width: 860px; padding: 0 1rem; line-height: 1.5; }
main { display: grid; gap: 0.75rem; }
section.org2-headline { margin: 0.5rem 0 1rem; }
h1,h2,h3,h4,h5,h6 { margin: 1rem 0 0.5rem; line-height: 1.25; }
.org2-todo { font-size: 0.8em; font-weight: 700; letter-spacing: 0.02em; text-transform: uppercase; opacity: 0.9; }
.org2-tags { font-size: 0.8em; opacity: 0.8; }
.org2-tag { border: 1px solid currentColor; border-radius: 999px; padding: 0 0.35em; }
.org2-planning { font-size: 0.95em; opacity: 0.9; }
.org2-planning-kind { font-weight: 600; }
.org2-properties { display: grid; grid-template-columns: max-content 1fr; gap: 0.15rem 0.75rem; margin: 0.5rem 0; }
.org2-properties dt { font-weight: 600; }
.org2-properties dd { margin: 0; }
.org2-src, .org2-example, .org2-verse, .org2-comment, .org2-directive, pre { overflow-x: auto; padding: 0.75rem; border-radius: 0.5rem; background: rgba(127,127,127,0.12); }
.org2-center { text-align: center; }
.org2-underline { text-decoration: underline; }
table { border-collapse: collapse; width: 100%; margin: 0.5rem 0 1rem; }
th, td { border: 1px solid rgba(127,127,127,0.35); padding: 0.35rem 0.5rem; text-align: left; }
thead th { background: rgba(127,127,127,0.16); }
a { text-decoration-thickness: 0.08em; text-underline-offset: 0.15em; }`;

const DOCUMENT_CHART_STYLE = `.org2-chart { width: min(100%, 800px); margin: 1rem 0 1.35rem; overflow-x: auto; }
.org2-chart-compact { width: min(100%, 680px); }
.org2-chart-wide { width: 100%; }
.org2-chart svg { display: block; width: 100%; height: auto; margin: 0; }`;

const DOCUMENT_TOC_STYLE = `.org2-toc { border: 1px solid rgba(127,127,127,0.35); border-radius: 0.5rem; padding: 0.75rem 1rem; margin: 0.25rem 0 1rem; }
.org2-toc h2 { margin: 0 0 0.5rem; font-size: 1rem; }
.org2-toc ul { margin: 0; padding-left: 1.25rem; display: grid; gap: 0.25rem; }
.org2-toc li.org2-toc-level-2 { margin-left: 0.75rem; }
.org2-toc li.org2-toc-level-3 { margin-left: 1.5rem; }
.org2-toc li.org2-toc-level-4 { margin-left: 2.25rem; }
.org2-toc li.org2-toc-level-5 { margin-left: 3rem; }
.org2-toc li.org2-toc-level-6 { margin-left: 3.75rem; }`;

const APP_DOCUMENT_STYLE = `:root {
  color-scheme: light dark;
  --org2-text: #18201e;
  --org2-muted: #5e6b66;
  --org2-faint: rgba(40, 84, 215, 0.065);
  --org2-rule: #d7d6ce;
  --org2-code: #f1f3ef;
  --org2-surface: #fcfbf7;
  --org2-elevated-surface: #ffffff;
  --org2-shadow: rgba(29, 43, 38, 0.065);
  --org2-link: #2854d7;
  --org2-accent: #2854d7;
  --org2-signal: #c2472c;
  --org2-success: #20804a;
  --org2-danger: #b64238;
  --org2-warning: #966512;
  --org2-chart-axis: rgba(56, 61, 69, 0.54);
  --org2-chart-grid: rgba(56, 61, 69, 0.12);
  --org2-chart-mark: #3478d4;
  --org2-chart-label: #6c7078;
  --org2-chart-title: #24262a;
  --org2-chart-surface: #ffffff;
  --org2-font-mono: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
  --org2-content-width: 960px;
  --org2-page-padding: 28px;
}
@media (prefers-color-scheme: dark) {
  :root {
    --org2-text: #dce3de;
    --org2-muted: #a2ada7;
    --org2-faint: rgba(134, 163, 255, 0.09);
    --org2-rule: #36403c;
    --org2-code: #121715;
    --org2-surface: #1b211f;
    --org2-elevated-surface: #222927;
    --org2-shadow: rgba(0, 0, 0, 0.24);
    --org2-link: #86a3ff;
    --org2-accent: #86a3ff;
    --org2-signal: #ff8668;
    --org2-success: #6ac58c;
    --org2-danger: #ee8178;
    --org2-warning: #e0b361;
    --org2-chart-axis: rgba(233, 234, 237, 0.5);
    --org2-chart-grid: rgba(233, 234, 237, 0.12);
    --org2-chart-mark: #79b8ed;
    --org2-chart-label: #a4a8b0;
    --org2-chart-title: #e9eaed;
    --org2-chart-surface: #202226;
  }
}
*, *::before, *::after { box-sizing: border-box; }
html, body { width: 100%; min-height: 100%; margin: 0; background: transparent; overflow-x: hidden; }
body {
  color: var(--org2-text);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
  font-size: 15px;
  line-height: 1.58;
  letter-spacing: 0;
  -webkit-font-smoothing: antialiased;
  overflow-wrap: anywhere;
}
main.org2-document {
  width: min(100%, var(--org2-content-width));
  max-width: 100%;
  margin: 0 auto;
  padding: 22px min(var(--org2-page-padding), 5vw) 64px;
}
.org2-document-header { margin: 0.15rem 0 1.1rem; }
.org2-document-title {
  margin: 0;
  font-size: clamp(1.9rem, 4vw, 2.45rem);
  font-weight: 650;
  line-height: 1.14;
  letter-spacing: -0.025em;
}
.org2-document-title::before {
  display: inline-block;
  margin-right: 0.48rem;
  color: var(--org2-signal);
  content: "*";
  font-family: var(--org2-font-mono);
  font-size: 0.38em;
  font-weight: 650;
  vertical-align: 0.72em;
}
.org2-document-subtitle { margin: 0.32rem 0 0; color: var(--org2-muted); font-size: 1rem; }
.org2-file-properties {
  margin: 0 0 1rem;
  color: var(--org2-muted);
  font-family: var(--org2-font-mono);
  font-size: 0.84rem;
}
.org2-file-properties > summary {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 0.42rem;
  padding-left: 1rem;
  color: var(--org2-muted);
  cursor: pointer;
  list-style: none;
  font-weight: 600;
  user-select: none;
}
.org2-file-properties > summary::-webkit-details-marker { display: none; }
.org2-file-properties > summary::before {
  content: "▶";
  position: absolute;
  left: 0;
  color: var(--org2-muted);
  font-size: 0.7rem;
}
.org2-file-properties[open] > summary::before { content: "▼"; }
.org2-file-properties-count {
  min-width: 1.35rem;
  padding: 0.04rem 0.32rem;
  border-radius: 999px;
  background: var(--org2-faint);
  text-align: center;
  font-size: 0.72rem;
  font-variant-numeric: tabular-nums;
}
.org2-file-properties-body {
  margin: 0.55rem 0 0;
  padding: 0.58rem 0.72rem;
  border: 1px solid var(--org2-rule);
  border-radius: 10px;
  background: var(--org2-elevated-surface);
  box-shadow: 0 1px 2px var(--org2-shadow);
}
.org2-file-properties .org2-keyword { margin: 0.16rem 0; font-size: inherit; }
.org2-headline { margin: 0; }
.org2-headline + .org2-headline { margin-top: 0.72rem; }
.org2-headline-summary {
  margin: 0.9rem 0 0.36rem;
  padding-left: 1.15rem;
  color: var(--org2-text);
  cursor: pointer;
  list-style: none;
  position: relative;
}
.org2-headline-summary::-webkit-details-marker,
.org2-properties-drawer > summary::-webkit-details-marker,
.org2-drawer > summary::-webkit-details-marker { display: none; }
.org2-headline-summary::before,
.org2-properties-drawer > summary::before,
.org2-drawer > summary::before {
  content: "▶";
  position: absolute;
  left: 0.05rem;
  top: 0.22em;
  color: var(--org2-muted);
  font-size: 0.82rem;
  font-weight: 750;
  line-height: 1.2;
}
details[open] > summary::before { content: "▼"; }
.org2-headline-summary:hover::before,
.org2-properties-drawer > summary:hover::before,
.org2-drawer > summary:hover::before { color: var(--org2-accent); }
.org2-headline-summary > h1,
.org2-headline-summary > h2,
.org2-headline-summary > h3,
.org2-headline-summary > h4,
.org2-headline-summary > h5,
.org2-headline-summary > h6 { display: inline; margin: 0; }
.org2-headline-summary > h1::before,
.org2-headline-summary > h2::before,
.org2-headline-summary > h3::before,
.org2-headline-summary > h4::before,
.org2-headline-summary > h5::before,
.org2-headline-summary > h6::before {
  display: inline-block;
  margin-right: 0.44rem;
  color: var(--org2-accent);
  content: "*";
  font-family: var(--org2-font-mono);
  font-size: 0.64em;
  font-weight: 650;
  vertical-align: 0.08em;
}
.org2-headline-summary > h2::before {
  color: var(--org2-signal);
  content: "**";
  font-size: 0.52em;
  letter-spacing: -0.16em;
}
.org2-headline-summary > h3::before,
.org2-headline-summary > h4::before,
.org2-headline-summary > h5::before,
.org2-headline-summary > h6::before {
  color: var(--org2-muted);
  content: "***";
  font-size: 0.46em;
  letter-spacing: -0.18em;
}
.org2-heading-ai-action {
  display: inline-flex;
  align-items: center;
  margin-left: 0.45rem;
  padding: 0.12rem 0.34rem;
  border: 0;
  border-radius: 4px;
  background: transparent;
  color: var(--org2-muted);
  font: inherit;
  font-size: 0.76rem;
  font-weight: 600;
  line-height: 1.25;
  letter-spacing: 0;
  vertical-align: middle;
  transform: translateY(-2px);
  opacity: 0.46;
  cursor: pointer;
  transition: opacity 110ms ease-out, color 110ms ease-out, background-color 110ms ease-out;
}
.org2-headline-summary:hover > .org2-heading-ai-action,
.org2-section-label:hover > .org2-heading-ai-action,
.org2-heading-ai-action:focus-visible {
  opacity: 1;
}
.org2-heading-ai-action:hover,
.org2-heading-ai-action:focus-visible {
  color: var(--org2-accent);
  background: color-mix(in srgb, var(--org2-accent) 9%, transparent);
  outline: none;
}
.org2-headline.level-1 > .org2-headline-summary { margin-top: 0.08rem; }
.org2-headline-body { min-width: 0; }
.org2-headline-body > .org2-headline.level-2 { margin-left: 0.35rem; padding-left: 0.5rem; border-left: 1px solid var(--org2-rule); }
.org2-headline-body > .org2-headline.level-3 { margin-left: 0.25rem; padding-left: 0.45rem; border-left: 1px solid var(--org2-rule); }
.org2-headline-body > .org2-headline.level-4,
.org2-headline-body > .org2-headline.level-5,
.org2-headline-body > .org2-headline.level-6 { margin-left: 0.2rem; padding-left: 0.35rem; border-left: 1px solid var(--org2-rule); }
h1, h2, h3, h4, h5, h6 {
  color: var(--org2-text);
  font-weight: 620;
  line-height: 1.3;
  letter-spacing: 0;
  margin: 1rem 0 0.42rem;
  text-wrap: balance;
}
h1 { font-size: 1.16rem; margin-top: 0.1rem; }
h2 { font-size: 1.08rem; color: color-mix(in srgb, var(--org2-text) 78%, var(--org2-accent)); }
h3 { font-size: 1.02rem; color: color-mix(in srgb, var(--org2-text) 72%, var(--org2-muted)); }
h4, h5, h6 { font-size: 0.98rem; color: var(--org2-muted); }
p { max-width: 100%; margin: 0.55rem 0 0.8rem; overflow-wrap: anywhere; }
a { color: var(--org2-link); text-decoration: none; border-bottom: 1px solid color-mix(in srgb, var(--org2-link) 35%, transparent); }
a:hover { border-bottom-color: var(--org2-link); }
strong { font-weight: 650; }
code {
  font-family: var(--org2-font-mono);
  font-size: 0.9em;
  background: var(--org2-code);
  border: 1px solid var(--org2-rule);
  border-radius: 4px;
  padding: 0.08em 0.3em;
}
pre, .org2-src, .org2-example, .org2-verse, .org2-export, .org2-directive {
  box-sizing: border-box;
  max-width: 100%;
  overflow: auto;
  margin: 0.85rem 0 1rem;
  padding: 0.9rem 1rem !important;
  color: var(--org2-text);
  background: var(--org2-code) !important;
  border: 1px solid var(--org2-rule) !important;
  border-radius: 10px !important;
  font-family: var(--org2-font-mono);
  font-size: 0.88rem !important;
  line-height: 1.45 !important;
  white-space: pre;
}
pre code { padding: 0; border: 0; background: transparent; font-size: inherit; }
blockquote { margin: 0.9rem 0; padding: 0.15rem 0 0.15rem 1rem; border-left: 3px solid var(--org2-accent); color: var(--org2-muted); }
.org2-quote { white-space: pre-wrap; overflow-wrap: anywhere; }
ul, ol { margin: 0.55rem 0 0.9rem; padding-left: 1.55rem; }
li { min-width: 0; margin: 0.24rem 0; padding-left: 0.12rem; overflow-wrap: anywhere; }
li > p { display: inline; }
input[type="checkbox"] { width: 0.95rem; height: 0.95rem; margin: 0 0.42rem 0 -0.05rem; accent-color: var(--org2-accent); vertical-align: -0.11rem; }
.org2-todo {
  display: inline-block;
  margin-right: 0.35rem;
  padding: 0.08rem 0.34rem;
  color: var(--org2-accent);
  background: color-mix(in srgb, var(--org2-accent) 10%, transparent);
  border-radius: 4px;
  font-size: 0.67em;
  font-weight: 750;
  line-height: 1.35;
  vertical-align: 0.12em;
}
.org2-todo.todo-done { color: var(--org2-success); background: color-mix(in srgb, var(--org2-success) 11%, transparent); }
.org2-todo.todo-canceled, .org2-todo.todo-cancelled { color: var(--org2-danger); background: color-mix(in srgb, var(--org2-danger) 10%, transparent); }
.org2-tags { display: inline-flex; flex-wrap: wrap; gap: 0.28rem; margin-left: 0.35rem; vertical-align: 0.1em; }
.org2-tag { color: var(--org2-muted); background: var(--org2-faint); border-radius: 4px; padding: 0.08rem 0.34rem; font-size: 0.65em; font-weight: 550; }
.org2-planning { color: var(--org2-muted); font-family: var(--org2-font-mono); font-size: 0.82rem; font-variant-numeric: tabular-nums; }
.org2-planning-kind { color: var(--org2-warning); font-size: 0.78em; font-weight: 700; }
.org2-timestamp, .org2-timestamp-range { font-variant-numeric: tabular-nums; }
.org2-properties-drawer {
  margin: 0.75rem 0 1rem;
  padding: 0.58rem 0.72rem;
  border: 1px solid var(--org2-rule);
  border-radius: 10px;
  background: var(--org2-elevated-surface);
  box-shadow: 0 1px 2px var(--org2-shadow);
  font-size: 0.82rem;
}
.org2-properties-drawer > summary {
  position: relative;
  padding-left: 1.15rem;
  color: var(--org2-muted);
  cursor: pointer;
  font-weight: 650;
  list-style: none;
  user-select: none;
}
.org2-properties-drawer[open] > summary { margin-bottom: 0.52rem; }
.org2-properties {
  display: grid;
  grid-template-columns: minmax(6rem, max-content) 1fr;
  gap: 0.3rem 0.9rem;
  margin: 0;
  padding: 0.5rem 0 0;
  border-top: 1px solid var(--org2-rule);
}
.org2-properties dt { color: var(--org2-muted); font-family: var(--org2-font-mono); font-weight: 650; }
.org2-properties dd { margin: 0; min-width: 0; overflow-wrap: anywhere; font-family: var(--org2-font-mono); }
.org2-drawer { margin: 0.75rem 0; color: var(--org2-muted); font-size: 0.9rem; }
.org2-drawer summary { position: relative; padding-left: 1.15rem; cursor: pointer; font-weight: 600; list-style: none; }
.org2-keyword { color: var(--org2-muted); font-size: 0.88rem; }
.org2-keyword-name { font-weight: 650; }
table { width: 100%; margin: 0.8rem 0 1.15rem; border-collapse: collapse; font-size: 0.9rem; font-variant-numeric: tabular-nums; }
th, td { padding: 0.46rem 0.58rem; border-bottom: 1px solid var(--org2-rule); text-align: left; vertical-align: top; }
th { color: var(--org2-muted); background: var(--org2-faint); font-family: var(--org2-font-mono); font-size: 0.78rem; font-weight: 650; }
.org2-table-scroll { width: 100%; max-width: 100%; margin: 0.8rem 0 1.15rem; overflow-x: auto; overscroll-behavior-inline: contain; }
.org2-table-scroll table { width: auto; min-width: 100%; margin: 0; }
.org2-table-scroll th, .org2-table-scroll td { overflow-wrap: normal; word-break: normal; hyphens: none; }
.org2-resizable-table th, .org2-resizable-table td { min-width: 72px; }
.org2-table-resize-anchor { position: relative; }
.org2-chart {
  box-sizing: border-box;
  position: relative;
  width: min(100%, 800px);
  max-width: 100%;
  min-width: min(360px, 100%);
  margin: 0.85rem 0 1.25rem;
  padding: 0.65rem 0.75rem 0.5rem;
  border: 1px solid color-mix(in srgb, var(--org2-text) 11%, transparent);
  border-radius: 12px;
  background: color-mix(in srgb, var(--org2-chart-surface) 96%, var(--org2-faint));
  box-shadow: 0 1px 2px color-mix(in srgb, var(--org2-text) 7%, transparent);
  overflow: hidden;
  resize: horizontal;
}
.org2-chart-compact { width: min(100%, 680px); }
.org2-chart-wide { width: 100%; }
.org2-chart svg { display: block; width: 100%; height: auto; margin: 0; overflow: visible; }
.org2-chart-line { opacity: 0.9; }
.org2-chart-mark { cursor: crosshair; outline: none; transition: opacity 100ms ease-out, stroke-width 100ms ease-out; }
.org2-chart-mark:focus-visible { stroke: var(--org2-text); stroke-width: 3; }
.org2-chart-mark-active { opacity: 1; stroke: var(--org2-text); stroke-width: 3; }
.org2-chart-crosshair { opacity: 0.42; }
.org2-chart-tooltip {
  position: absolute;
  z-index: 3;
  min-width: 108px;
  max-width: min(220px, calc(100% - 20px));
  padding: 0.42rem 0.55rem;
  border: 1px solid color-mix(in srgb, var(--org2-text) 14%, transparent);
  border-radius: 8px;
  color: var(--org2-text);
  background: color-mix(in srgb, var(--org2-chart-surface) 96%, var(--org2-faint));
  box-shadow: 0 7px 22px color-mix(in srgb, var(--org2-text) 16%, transparent);
  font-size: 0.78rem;
  line-height: 1.32;
  pointer-events: none;
}
.org2-chart-tooltip[hidden] { display: none; }
.org2-chart-tooltip-label { display: block; color: var(--org2-muted); }
.org2-chart-tooltip-value { display: block; margin-top: 0.08rem; font-weight: 650; font-variant-numeric: tabular-nums; }
.org2-column-resizer {
  position: absolute;
  top: 0;
  right: -5px;
  bottom: 0;
  width: 10px;
  z-index: 2;
  cursor: col-resize;
  touch-action: none;
}
.org2-column-resizer::after {
  content: "";
  position: absolute;
  top: 18%;
  right: 4px;
  bottom: 18%;
  width: 2px;
  border-radius: 1px;
  background: transparent;
}
.org2-column-resizer:hover::after,
body.org2-resizing-column .org2-column-resizer::after { background: var(--org2-accent); }
body.org2-resizing-column { cursor: col-resize; user-select: none; }
::selection { background: color-mix(in srgb, var(--org2-accent) 30%, transparent); }
@media (max-width: 560px) {
  main.org2-document { padding-top: 18px; padding-bottom: 48px; }
  .org2-properties { grid-template-columns: 1fr; gap: 0.08rem; }
  .org2-properties dd { margin-bottom: 0.35rem; }
}`;

const APP_DOCUMENT_SCRIPT = `(() => {
  const minimumColumnWidth = 72;

  function appendAIAction(container, line) {
    if (!container || !line || container.querySelector(":scope > .org2-heading-ai-action")) return;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "org2-heading-ai-action";
    button.textContent = "✦ Ask AI";
    button.title = "Ask AI about this section";
    button.setAttribute("aria-label", "Ask AI about this section");
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      window.location.href = "org2-workspace://ask-ai?line=" + encodeURIComponent(line);
    });
    container.appendChild(button);
  }

  function installHeadingActions() {
    document.querySelectorAll("details.org2-headline[data-org2-start-line]").forEach((headline) => {
      const summary = headline.querySelector(":scope > .org2-headline-summary");
      const line = headline.dataset.org2StartLine;
      appendAIAction(summary, line);
    });

    document.querySelectorAll("p[data-org2-start-line]").forEach((paragraph) => {
      const meaningfulChildren = Array.from(paragraph.childNodes).filter((node) =>
        node.nodeType !== Node.TEXT_NODE || Boolean(node.textContent && node.textContent.trim())
      );
      if (meaningfulChildren.length !== 1) return;
      const label = meaningfulChildren[0];
      if (!(label instanceof HTMLElement) || label.tagName !== "STRONG") return;
      paragraph.classList.add("org2-section-label");
      appendAIAction(paragraph, paragraph.dataset.org2StartLine);
    });
  }

  function installTableResizers() {
    document.querySelectorAll(".org2-table-scroll table").forEach((table) => {
      if (table.dataset.org2Resizable === "true") return;
      const row = table.tHead && table.tHead.rows.length > 0 ? table.tHead.rows[0] : table.rows[0];
      if (!row || row.cells.length === 0) return;

      const measuredTableWidth = Math.ceil(table.getBoundingClientRect().width);
      const measuredWidths = Array.from(row.cells, (cell) =>
        Math.max(minimumColumnWidth, Math.ceil(cell.getBoundingClientRect().width))
      );
      const colgroup = document.createElement("colgroup");
      const columns = measuredWidths.map((width) => {
        const column = document.createElement("col");
        column.style.width = width + "px";
        colgroup.appendChild(column);
        return column;
      });
      table.insertBefore(colgroup, table.firstChild);
      table.dataset.org2Resizable = "true";
      table.classList.add("org2-resizable-table");
      table.style.tableLayout = "fixed";
      table.style.width = Math.max(
        measuredTableWidth,
        measuredWidths.reduce((total, width) => total + width, 0)
      ) + "px";

      Array.from(row.cells).forEach((cell, index) => {
        cell.classList.add("org2-table-resize-anchor");
        const handle = document.createElement("span");
        handle.className = "org2-column-resizer";
        handle.setAttribute("role", "separator");
        handle.setAttribute("aria-orientation", "vertical");
        handle.setAttribute("aria-label", "Resize table column " + (index + 1));
        handle.title = "Drag to resize column";

        handle.addEventListener("mousedown", (event) => {
          if (event.button !== 0) return;
          event.preventDefault();
          event.stopPropagation();

          const startX = event.clientX;
          const startWidth = parseFloat(columns[index].style.width) || measuredWidths[index];
          const startTableWidth = table.getBoundingClientRect().width;
          document.body.classList.add("org2-resizing-column");

          const move = (moveEvent) => {
            const nextWidth = Math.max(minimumColumnWidth, startWidth + moveEvent.clientX - startX);
            columns[index].style.width = nextWidth + "px";
            table.style.width = Math.max(
              table.parentElement ? table.parentElement.clientWidth : 0,
              startTableWidth + nextWidth - startWidth
            ) + "px";
          };
          const finish = () => {
            document.body.classList.remove("org2-resizing-column");
            window.removeEventListener("mousemove", move);
            window.removeEventListener("mouseup", finish);
          };

          window.addEventListener("mousemove", move);
          window.addEventListener("mouseup", finish);
        });

        cell.appendChild(handle);
      });
    });
  }

  function installInteractiveCharts() {
    document.querySelectorAll("figure.org2-chart[data-org2-chart-interactive='true']").forEach((figure, chartIndex) => {
      if (figure.dataset.org2ChartEnhanced === "true") return;
      const svg = figure.querySelector("svg.org2-chart-svg");
      if (!svg || svg.dataset.org2ChartInteractive !== "true") return;
      const marks = Array.from(svg.querySelectorAll("[data-org2-chart-mark='true']"));
      if (marks.length === 0) return;

      figure.dataset.org2ChartEnhanced = "true";
      const tooltip = document.createElement("div");
      const tooltipID = "org2-chart-tooltip-" + chartIndex;
      tooltip.id = tooltipID;
      tooltip.className = "org2-chart-tooltip";
      tooltip.setAttribute("role", "tooltip");
      tooltip.hidden = true;
      const tooltipLabel = document.createElement("span");
      tooltipLabel.className = "org2-chart-tooltip-label";
      const tooltipValue = document.createElement("span");
      tooltipValue.className = "org2-chart-tooltip-value";
      tooltip.append(tooltipLabel, tooltipValue);
      figure.appendChild(tooltip);

      const crosshair = svg.querySelector(".org2-chart-crosshair");
      let activeMark = null;

      marks.forEach((mark, index) => {
        const nativeTitle = mark.querySelector(":scope > title");
        if (nativeTitle) nativeTitle.remove();
        mark.setAttribute("aria-describedby", tooltipID);
        mark.addEventListener("focus", () => showMark(mark));
        mark.addEventListener("blur", hideMark);
        mark.addEventListener("keydown", (event) => {
          if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
          event.preventDefault();
          const direction = event.key === "ArrowRight" ? 1 : -1;
          const next = marks[Math.max(0, Math.min(marks.length - 1, index + direction))];
          if (next && typeof next.focus === "function") next.focus();
        });
      });

      function showMark(mark) {
        if (!mark) return;
        if (activeMark && activeMark !== mark) activeMark.classList.remove("org2-chart-mark-active");
        activeMark = mark;
        mark.classList.add("org2-chart-mark-active");
        tooltipLabel.textContent = mark.dataset.label || "";
        const yLabel = svg.dataset.org2ChartYLabel || "value";
        tooltipValue.textContent = yLabel + ": " + (mark.dataset.value || "");
        tooltip.hidden = false;

        if (crosshair) {
          const x = mark.dataset.chartX || "0";
          crosshair.setAttribute("x1", x);
          crosshair.setAttribute("x2", x);
          crosshair.setAttribute("visibility", "visible");
        }

        const figureRect = figure.getBoundingClientRect();
        const markRect = mark.getBoundingClientRect();
        const centerX = markRect.left - figureRect.left + markRect.width / 2;
        let left = centerX - tooltip.offsetWidth / 2;
        left = Math.max(10, Math.min(left, figure.clientWidth - tooltip.offsetWidth - 10));
        let top = markRect.top - figureRect.top - tooltip.offsetHeight - 10;
        if (top < 8) top = markRect.bottom - figureRect.top + 10;
        tooltip.style.left = left + "px";
        tooltip.style.top = top + "px";
      }

      function hideMark() {
        if (activeMark) activeMark.classList.remove("org2-chart-mark-active");
        activeMark = null;
        tooltip.hidden = true;
        if (crosshair) crosshair.setAttribute("visibility", "hidden");
      }

      figure.addEventListener("mousemove", (event) => {
        let nearest = null;
        let nearestDistance = Infinity;
        marks.forEach((mark) => {
          const rect = mark.getBoundingClientRect();
          const distance = Math.abs(event.clientX - (rect.left + rect.width / 2));
          if (distance < nearestDistance) {
            nearest = mark;
            nearestDistance = distance;
          }
        });
        showMark(nearest);
      });
      figure.addEventListener("mouseleave", () => {
        if (!marks.includes(document.activeElement)) hideMark();
      });
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      installHeadingActions();
      installTableResizers();
      installInteractiveCharts();
    }, { once: true });
  } else {
    installHeadingActions();
    installTableResizers();
    installInteractiveCharts();
  }
})();`;

const DEFAULT_INDEX_STYLE = `:root { color-scheme: light dark; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem auto; max-width: 860px; padding: 0 1rem; line-height: 1.5; }
main { display: grid; gap: 1rem; }
h1 { margin: 0; }
ul.org2-export-index { padding-left: 1.25rem; margin: 0; display: grid; gap: 0.35rem; }
.org2-export-source { opacity: 0.75; font-size: 0.9em; }
a { text-decoration-thickness: 0.08em; text-underline-offset: 0.15em; }`;

function renderHeadStyleSection(opts: {
  stylesheets?: string[];
  includeDefaultStyle?: boolean;
  defaultStyle: string;
}): string {
  const includeDefaultStyle = opts.includeDefaultStyle !== false;
  const stylesheets = normalizeStylesheets(opts.stylesheets);
  const stylesheetLinks = stylesheets
    .map((href) => `<link rel="stylesheet" href="${escapeAttr(href)}" />`)
    .join("\n");

  const defaultStyleBlock = includeDefaultStyle ? `<style>\n${opts.defaultStyle}\n</style>` : "";

  if (stylesheetLinks && defaultStyleBlock) {
    return `${stylesheetLinks}\n${defaultStyleBlock}\n`;
  }

  if (stylesheetLinks) {
    return `${stylesheetLinks}\n`;
  }

  if (defaultStyleBlock) {
    return `${defaultStyleBlock}\n`;
  }

  return "";
}

type TocItem = {
  id: string;
  title: string;
  level: number;
  number?: string;
};

type RenderContext = {
  headlineIds?: WeakMap<HeadlineNode, string>;
  headlineSlugIds?: Map<string, string>;
  headlineNumbers?: WeakMap<HeadlineNode, string>;
  rewriteFileLinks?: boolean;
  linkAbbreviations?: LinkAbbreviationMap;
  profile?: "publish" | "app";
  chartsByTableLine?: Map<number, OrgEmbeddedChart>;
  chartsByBlockLine?: Map<number, OrgEmbeddedChart>;
};

export type OrgEmbeddedChart = {
  svg: string;
  presentation?: {
    size: "compact" | "medium" | "wide";
    height: number;
    interactive: boolean;
  };
  source: {
    line: number;
    chartLine?: number;
  };
};

export type OrgExportMetadata = {
  author?: string;
  date?: string;
  subtitle?: string;
  description?: string;
  keywords?: string[];
  language?: string;
  htmlHead?: string[];
};

type OrgExportOptions = {
  toc?: boolean;
  tocDepth?: number;
  num?: boolean;
  numDepth?: number;
};

const HIDDEN_DOCUMENT_KEYWORDS = new Set([
  "TITLE",
  "AUTHOR",
  "DATE",
  "SUBTITLE",
  "DESCRIPTION",
  "KEYWORDS",
  "LANGUAGE",
  "HTML_HEAD",
  "HTML_HEAD_EXTRA",
  "OPTIONS",
  "LINK",
]);

function parseKeywordList(value: string): string[] {
  const values = String(value || "")
    .split(/[;,]/)
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
  return Array.from(new Set(values));
}

function normalizeDocumentLanguage(value: string): string | null {
  const normalized = String(value || "").trim();
  if (!normalized) return null;
  if (!/^[A-Za-z0-9-]+$/.test(normalized)) return null;
  return normalized;
}

function parseKeywordOptionsMap(value: string): Map<string, string> {
  const assignments = new Map<string, string>();
  const tokens = String(value || "")
    .trim()
    .split(/\s+/)
    .filter((token) => token.length > 0);

  for (const token of tokens) {
    const separatorIndex = token.indexOf(":");
    if (separatorIndex <= 0) continue;
    const key = token.slice(0, separatorIndex).trim().toLowerCase();
    const optionValue = token.slice(separatorIndex + 1).trim();
    if (!key || !optionValue) continue;
    assignments.set(key, optionValue);
  }

  return assignments;
}

function parseKeywordBooleanOption(value: string | undefined): boolean | null {
  const normalized = String(value || "").trim().toLowerCase();
  if (!normalized) return null;

  if (["t", "true", "yes", "on"].includes(normalized)) return true;
  if (["nil", "false", "no", "off"].includes(normalized)) return false;

  if (/^\d+$/.test(normalized)) {
    return Number(normalized) > 0;
  }

  return null;
}

function parseKeywordPositiveIntegerOption(value: string | undefined): number | null {
  const normalized = String(value || "").trim();
  if (!/^\d+$/.test(normalized)) return null;

  const parsed = Number.parseInt(normalized, 10);
  if (!Number.isFinite(parsed) || parsed < 1) return null;
  return parsed;
}

function collectKeywordOptions(doc: DocumentNode): OrgExportOptions {
  const options: OrgExportOptions = {};

  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    const key = String(node.keyRaw || "").trim().toUpperCase();
    if (key !== "OPTIONS") continue;

    const assignments = parseKeywordOptionsMap(node.valueRaw);
    if (assignments.has("toc")) {
      const tocRaw = assignments.get("toc");
      const parsed = parseKeywordBooleanOption(tocRaw);
      if (parsed !== null) {
        options.toc = parsed;
      }

      const parsedDepth = parseKeywordPositiveIntegerOption(tocRaw);
      if (parsedDepth !== null) {
        options.toc = true;
        options.tocDepth = parsedDepth;
      }
    }

    if (assignments.has("num")) {
      const numRaw = assignments.get("num");
      const parsed = parseKeywordBooleanOption(numRaw);
      if (parsed !== null) {
        options.num = parsed;
      }

      const parsedDepth = parseKeywordPositiveIntegerOption(numRaw);
      if (parsedDepth !== null) {
        options.num = true;
        options.numDepth = parsedDepth;
      }
    }
  }

  return options;
}

function collectKeywordMetadata(doc: DocumentNode): OrgExportMetadata {
  const metadata: OrgExportMetadata = {};

  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    const key = String(node.keyRaw || "").trim().toUpperCase();
    const value = String(node.valueRaw || "").trim();
    if (!value) continue;

    if (key === "AUTHOR" && !metadata.author) {
      metadata.author = value;
      continue;
    }

    if (key === "DATE" && !metadata.date) {
      metadata.date = value;
      continue;
    }

    if (key === "SUBTITLE" && !metadata.subtitle) {
      metadata.subtitle = value;
      continue;
    }

    if (key === "DESCRIPTION" && !metadata.description) {
      metadata.description = value;
      continue;
    }

    if (key === "KEYWORDS" && !metadata.keywords) {
      const parsedKeywords = parseKeywordList(value);
      if (parsedKeywords.length > 0) {
        metadata.keywords = parsedKeywords;
      }
      continue;
    }

    if (key === "LANGUAGE" && !metadata.language) {
      const normalizedLanguage = normalizeDocumentLanguage(value);
      if (normalizedLanguage) {
        metadata.language = normalizedLanguage;
      }
      continue;
    }

    if (key === "HTML_HEAD" || key === "HTML_HEAD_EXTRA") {
      if (!metadata.htmlHead) metadata.htmlHead = [];
      metadata.htmlHead.push(value);
    }
  }

  return metadata;
}

function hasKeywordMetadata(metadata: OrgExportMetadata): boolean {
  return Boolean(
    metadata.author ||
      metadata.date ||
      metadata.subtitle ||
      metadata.description ||
      (Array.isArray(metadata.keywords) && metadata.keywords.length > 0) ||
      metadata.language ||
      (Array.isArray(metadata.htmlHead) && metadata.htmlHead.length > 0),
  );
}

function renderHeadMetaSection(metadata: OrgExportMetadata): string {
  if (!hasKeywordMetadata(metadata)) return "";

  const rows: string[] = [];
  if (metadata.author) {
    rows.push(`<meta name="author" content="${escapeAttr(metadata.author)}" />`);
  }
  if (metadata.date) {
    rows.push(`<meta name="date" content="${escapeAttr(metadata.date)}" />`);
  }
  if (metadata.subtitle) {
    rows.push(`<meta name="subtitle" content="${escapeAttr(metadata.subtitle)}" />`);
  }
  if (metadata.description) {
    rows.push(`<meta name="description" content="${escapeAttr(metadata.description)}" />`);
  }
  if (Array.isArray(metadata.keywords) && metadata.keywords.length > 0) {
    rows.push(`<meta name="keywords" content="${escapeAttr(metadata.keywords.join(", "))}" />`);
  }

  return rows.length > 0 ? `${rows.join("\n")}\n` : "";
}

function renderHeadExtraSection(
  metadata: OrgExportMetadata,
  extraHead?: string[],
  includeDocumentHtml = true,
): string {
  const snippets = [
    ...(includeDocumentHtml && Array.isArray(metadata.htmlHead) ? metadata.htmlHead : []),
    ...(Array.isArray(extraHead) ? extraHead : []),
  ]
    .map((snippet) => String(snippet || "").trim())
    .filter((snippet) => snippet.length > 0);
  return snippets.length > 0 ? `${snippets.join("\n")}\n` : "";
}

function slugifyHeadlineTitle(value: string): string {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return normalized || "section";
}

function normalizeAnchorId(value: string): string | null {
  const normalized = String(value || "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/[^A-Za-z0-9_.:-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return normalized || null;
}

function findHeadlineCustomId(node: HeadlineNode): string | null {
  for (const child of node.children) {
    if (child.type !== "PropertyDrawer") continue;
    for (const property of child.properties) {
      if (String(property.key || "").trim().toUpperCase() !== "CUSTOM_ID") continue;
      const normalized = normalizeAnchorId(property.value);
      if (normalized) return normalized;
    }
  }

  return null;
}

function normalizeTocDepth(value: number | undefined): number | null {
  if (value === undefined || value === null) return null;
  if (!Number.isFinite(value)) return null;
  const normalized = Math.trunc(value);
  if (normalized < 1) return null;
  return Math.min(6, normalized);
}

function normalizeHeadlineNumberDepth(value: number | undefined): number | null {
  if (value === undefined || value === null) return null;
  if (!Number.isFinite(value)) return null;
  const normalized = Math.trunc(value);
  if (normalized < 1) return null;
  return Math.min(6, normalized);
}

function buildHeadlineAnchors(
  doc: DocumentNode,
  opts: {
    includeToc?: boolean;
    includeTocDepth?: number;
    includeHeadlineNumbers?: boolean;
    includeHeadlineNumberDepth?: number;
  } = {},
): {
  items: TocItem[];
  headlineIds: WeakMap<HeadlineNode, string>;
  headlineSlugIds: Map<string, string>;
  headlineNumbers: WeakMap<HeadlineNode, string>;
} {
  const includeToc = opts.includeToc === true;
  const includeTocDepth = normalizeTocDepth(opts.includeTocDepth);
  const includeHeadlineNumbers = opts.includeHeadlineNumbers === true;
  const includeHeadlineNumberDepth = normalizeHeadlineNumberDepth(opts.includeHeadlineNumberDepth);
  const items: TocItem[] = [];
  const headlineIds = new WeakMap<HeadlineNode, string>();
  const headlineSlugIds = new Map<string, string>();
  const headlineNumbers = new WeakMap<HeadlineNode, string>();
  const headlineNumberCounts = [0, 0, 0, 0, 0, 0];
  const idCounts = new Map<string, number>();

  const nextId = (baseId: string): string => {
    const normalizedBase = normalizeAnchorId(baseId) || "section";
    const key = normalizedBase.toLowerCase();
    const count = (idCounts.get(key) || 0) + 1;
    idCounts.set(key, count);
    if (count === 1) return normalizedBase;
    return `${normalizedBase}-${count}`;
  };

  const visitNodes = (nodes: Node[]): void => {
    for (const node of nodes) {
      if (node.type !== "Headline") continue;
      const title = node.title.map((child) => inlineToText(child)).join("").trim() || "Untitled";
      const titleSlug = slugifyHeadlineTitle(title);
      const customId = findHeadlineCustomId(node);
      const id = nextId(customId || titleSlug);
      const level = Math.max(1, Math.min(6, node.level));
      headlineIds.set(node, id);
      const titleKey = titleSlug.toLowerCase();
      if (!headlineSlugIds.has(titleKey)) {
        headlineSlugIds.set(titleKey, id);
      }

      headlineNumberCounts[level - 1] += 1;
      for (let idx = level; idx < headlineNumberCounts.length; idx += 1) {
        headlineNumberCounts[idx] = 0;
      }

      let headlineNumber: string | null = null;
      if (includeHeadlineNumbers && (includeHeadlineNumberDepth === null || level <= includeHeadlineNumberDepth)) {
        const parts = headlineNumberCounts.slice(0, level).filter((value) => value > 0);
        if (parts.length > 0) {
          headlineNumber = parts.join(".");
          headlineNumbers.set(node, headlineNumber);
        }
      }

      if (includeToc && (includeTocDepth === null || level <= includeTocDepth)) {
        items.push({
          id,
          title,
          level,
          ...(headlineNumber ? { number: headlineNumber } : {}),
        });
      }

      visitNodes(node.children);
    }
  };

  visitNodes(doc.children);
  return { items, headlineIds, headlineSlugIds, headlineNumbers };
}

function renderToc(items: TocItem[]): string {
  if (!Array.isArray(items) || items.length === 0) return "";
  const rows = items
    .map((item) => {
      const level = Math.max(1, Math.min(6, item.level));
      const numberPrefix = item.number ? `${escapeHtml(item.number)} ` : "";
      return `<li class="org2-toc-level-${level}"><a href="#${escapeAttr(item.id)}">${numberPrefix}${escapeHtml(item.title)}</a></li>`;
    })
    .join("\n");
  return `<nav class="org2-toc" aria-label="Table of contents">\n<h2>Contents</h2>\n<ul>\n${rows}\n</ul>\n</nav>`;
}

function rewriteOrgFileHrefForHtml(rawHref: string): string {
  const href = String(rawHref || "").trim();
  if (!href) return href;

  const hasScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(href);
  const isFileScheme = /^file:/i.test(href);
  if (hasScheme && !isFileScheme) return href;

  const source = isFileScheme ? href.slice(5) : href;
  const searchSeparatorIndex = source.indexOf("::");
  const pathPart = searchSeparatorIndex >= 0 ? source.slice(0, searchSeparatorIndex) : source;
  const searchSuffix = searchSeparatorIndex >= 0 ? source.slice(searchSeparatorIndex + 2) : "";

  if (!/\.(org|org2)(?=($|[?#]))/i.test(pathPart)) return href;
  const rewrittenPath = pathPart.replace(/\.(org|org2)(?=($|[?#]))/i, ".html");

  if (!searchSuffix.trim()) return rewrittenPath;

  const trimmedSearchSuffix = searchSuffix.trim();
  if (trimmedSearchSuffix.startsWith("#")) {
    return `${rewrittenPath}${trimmedSearchSuffix}`;
  }

  if (trimmedSearchSuffix.startsWith("*")) {
    const headingText = trimmedSearchSuffix.replace(/^\*+\s*/, "").trim();
    return `${rewrittenPath}#${slugifyHeadlineTitle(headingText || "section")}`;
  }

  return href;
}

function rewriteOrgInternalHrefForHtml(rawHref: string, context: RenderContext): string {
  const href = String(rawHref || "").trim();
  if (!href) return href;

  if (href.startsWith("#")) {
    const normalizedAnchor = normalizeAnchorId(href.slice(1));
    return normalizedAnchor ? `#${normalizedAnchor}` : href;
  }

  if (!href.startsWith("*")) return href;

  const headingText = href.replace(/^\*+\s*/, "").trim();
  const headingSlug = slugifyHeadlineTitle(headingText || "section");
  const resolvedHeadingId = context.headlineSlugIds?.get(headingSlug.toLowerCase()) || headingSlug;
  return `#${resolvedHeadingId}`;
}

function linkTargetNeedsHeadingAnchor(rawTarget: string): boolean {
  const target = String(rawTarget || "").trim();
  if (!target) return false;
  return target.startsWith("#") || target.startsWith("*");
}

function resolveDefaultInternalLinkText(rawTarget: string): string | null {
  const target = String(rawTarget || "").trim();
  if (!target) return null;

  if (target.startsWith("*")) {
    const headingText = target.replace(/^\*+\s*/, "").trim();
    return headingText || null;
  }

  if (target.startsWith("#")) {
    const anchorRaw = target.slice(1).trim();
    if (!anchorRaw) return null;
    return normalizeAnchorId(anchorRaw) || anchorRaw;
  }

  return null;
}

function inlineNodesNeedHeadingAnchors(nodes: InlineNode[]): boolean {
  for (const node of nodes) {
    if (node.type !== "Link") continue;
    if (linkTargetNeedsHeadingAnchor(node.targetRaw)) return true;
  }

  return false;
}

function nodesNeedHeadingAnchors(nodes: Node[]): boolean {
  for (const node of nodes) {
    if (node.type === "Headline") {
      if (inlineNodesNeedHeadingAnchors(node.title)) return true;
      if (nodesNeedHeadingAnchors(node.children)) return true;
      continue;
    }

    if (node.type === "Paragraph") {
      if (inlineNodesNeedHeadingAnchors(node.children)) return true;
      continue;
    }

    if (node.type === "List") {
      for (const item of node.items) {
        if (nodesNeedHeadingAnchors(item.children)) return true;
      }
      continue;
    }

    if (node.type === "ListItem") {
      if (nodesNeedHeadingAnchors(node.children)) return true;
    }
  }

  return false;
}

function inlineToText(node: InlineNode): string {
  if (node.type === "Text") return node.value;
  if (node.type === "Timestamp") return node.raw;
  if (node.type === "TimestampRange") return `${node.start.raw}${node.separatorRaw}${node.end.raw}`;
  if (node.type === "Emphasis") return node.content;
  if (node.type === "Link") return node.descriptionRaw || node.targetRaw;
  return "";
}

function renderTimestamp(node: TimestampNode): string {
  const klass = node.active ? "org2-timestamp active" : "org2-timestamp inactive";
  return `<time class="${klass}">${escapeHtml(node.raw)}</time>`;
}

function renderTimestampRange(node: TimestampRangeNode): string {
  const klass = node.start.active ? "org2-timestamp-range active" : "org2-timestamp-range inactive";
  return `<time class="${klass}">${escapeHtml(node.start.raw + node.separatorRaw + node.end.raw)}</time>`;
}

function renderEmphasis(node: EmphasisNode): string {
  const content = escapeHtml(node.content);
  if (node.kind === "bold") return `<strong>${content}</strong>`;
  if (node.kind === "italic") return `<em>${content}</em>`;
  if (node.kind === "underline") return `<span class="org2-underline">${content}</span>`;
  if (node.kind === "strike") return `<del>${content}</del>`;
  return `<code>${content}</code>`;
}

function appLinkHref(rawTarget: string, expandedTarget: string, context: RenderContext): string {
  if (linkTargetNeedsHeadingAnchor(expandedTarget)) {
    return rewriteOrgInternalHrefForHtml(expandedTarget, context);
  }

  if (/^(https?|mailto):/i.test(expandedTarget)) {
    return expandedTarget;
  }

  return `org2-workspace://open-link?target=${encodeURIComponent(rawTarget)}`;
}

function renderLink(node: LinkNode, context: RenderContext): string {
  const hrefRaw = String(node.targetRaw || "").trim();
  const expandedHrefRaw = expandLinkAbbreviationTarget(hrefRaw, context.linkAbbreviations);
  let href = context.profile === "app"
    ? appLinkHref(hrefRaw, expandedHrefRaw, context)
    : expandedHrefRaw;

  if (context.profile !== "app" && context.rewriteFileLinks) {
    href = rewriteOrgFileHrefForHtml(expandedHrefRaw);
  }

  if (context.profile !== "app" && linkTargetNeedsHeadingAnchor(expandedHrefRaw)) {
    href = rewriteOrgInternalHrefForHtml(expandedHrefRaw, context);
  }

  const explicitDescription = String(node.descriptionRaw || "").trim();
  const defaultInternalText = resolveDefaultInternalLinkText(hrefRaw);
  const text = explicitDescription || defaultInternalText || String(node.targetRaw || "").trim() || href;
  return `<a href="${escapeAttr(href)}">${escapeHtml(text)}</a>`;
}

function renderInline(node: InlineNode, context: RenderContext): string {
  if (node.type === "Text") return escapeHtml(node.value);
  if (node.type === "Timestamp") return renderTimestamp(node);
  if (node.type === "TimestampRange") return renderTimestampRange(node);
  if (node.type === "Emphasis") return renderEmphasis(node);
  if (node.type === "Link") return renderLink(node, context);
  return "";
}

function renderInlineChildren(nodes: InlineNode[], context: RenderContext): string {
  return nodes.map((node) => renderInline(node, context)).join("");
}

type SourceRangedNode = Node & { sourceRange?: { startLine: number; endLine: number } };

function renderSourceAttributes(node: Node, context: RenderContext): string {
  if (context.profile !== "app") return "";
  const range = (node as SourceRangedNode).sourceRange;
  if (!range) return "";
  return ` data-org2-start-line="${range.startLine}" data-org2-end-line="${range.endLine}"`;
}

function renderParagraph(node: ParagraphNode, context: RenderContext): string {
  const sourceAttributes = renderSourceAttributes(node, context);
  if (node.children.length === 1 && node.children[0]?.type === "Text") {
    const raw = String(node.children[0].value || "").trim();
    if (raw === "--") return `<p${sourceAttributes}>&#x2013;</p>`;
    if (raw === "---") return `<p${sourceAttributes}>&#x2014;</p>`;
  }
  return `<p${sourceAttributes}>${renderInlineChildren(node.children, context)}</p>`;
}

function renderPlanning(node: PlanningNode, context: RenderContext): string {
  const raw = node.timestamp
    ? node.timestamp.type === "Timestamp"
      ? node.timestamp.raw
      : node.timestamp.start.raw + node.timestamp.separatorRaw + node.timestamp.end.raw
    : node.raw;
  return `<p class="org2-planning"${renderSourceAttributes(node, context)}><span class="org2-planning-kind">${escapeHtml(node.kind)}</span> ${escapeHtml(raw)}</p>`;
}

function renderPropertyDrawer(node: PropertyDrawerNode, context: RenderContext): string {
  if (!node.properties.length) return "";

  const rows = node.properties
    .map((property) => `<dt>${escapeHtml(property.key)}</dt><dd>${escapeHtml(property.value)}</dd>`)
    .join("\n");

  if (context.profile === "app") {
    return `<details class="org2-properties-drawer" open${renderSourceAttributes(node, context)}>\n<summary>Properties</summary>\n<dl class="org2-properties">\n${rows}\n</dl>\n</details>`;
  }

  return `<dl class="org2-properties"${renderSourceAttributes(node, context)}>\n${rows}\n</dl>`;
}

function renderSrcBlock(node: SrcBlockNode, context: RenderContext): string {
  const languageRaw = String(node.begin.afterKeywordRaw || "")
    .trim()
    .split(/\s+/)[0];
  const language = languageRaw.toLowerCase().replace(/[^a-z0-9_+-]/g, "");
  const sourceRange = (node as SourceRangedNode).sourceRange;
  const embeddedChart = sourceRange && (language === "chart" || language === "plot")
    ? context.chartsByBlockLine?.get(sourceRange.startLine)
    : undefined;
  if (embeddedChart) return renderEmbeddedChart(embeddedChart, renderSourceAttributes(node, context));
  const languageClass = language ? ` language-${language}` : "";
  const codeClassAttr = language ? ` class="language-${escapeAttr(language)}"` : "";
  const body = escapeHtml(node.bodyRaw.replace(/\n$/, ""));
  const baseStyle = "padding: 0.9rem 1rem; border: 1px solid rgba(127,127,127,0.28); border-radius: 0.6rem; background: rgba(127,127,127,0.11); font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace; font-size: 0.92rem; line-height: 1.28;";
  return `<pre class="org2-src${languageClass}"${renderSourceAttributes(node, context)} style="${escapeAttr(baseStyle)}"><code${codeClassAttr}>${body}</code></pre>`;
}

function renderEmbeddedChart(chart: OrgEmbeddedChart, sourceAttributes = ""): string {
  const presentation = chart.presentation;
  const size = presentation?.size || "medium";
  const interactive = presentation?.interactive !== false;
  return `<figure class="org2-chart org2-chart-${size}" data-org2-chart-interactive="${interactive}"${sourceAttributes}>\n${chart.svg.trim()}\n</figure>`;
}

function renderBlock(node: BlockNode, context: RenderContext): string {
  const bodyRaw = node.bodyRaw.replace(/\n$/, "");
  const body = escapeHtml(node.kind === "quote" ? dedentBlockBody(bodyRaw, node.begin.indent) : bodyRaw);

  if (node.kind === "quote") {
    const appClass = context.profile === "app" ? ' class="org2-quote"' : "";
    return `<blockquote${appClass}${renderSourceAttributes(node, context)}>${body}</blockquote>`;
  }
  if (node.kind === "center") return `<div class="org2-center">${body}</div>`;
  if (node.kind === "verse") return `<pre class="org2-verse">${body}</pre>`;
  if (node.kind === "comment") return `<pre class="org2-comment">${body}</pre>`;
  if (node.kind === "export") {
    const exportTarget = String(node.begin.afterKeywordRaw || "").trim().toLowerCase();
    if (exportTarget === "html" && context.profile !== "app") return bodyRaw;
    return `<pre class="org2-export">${body}</pre>`;
  }
  return `<pre class="org2-example">${body}</pre>`;
}

function dedentBlockBody(bodyRaw: string, indent: string): string {
  if (!indent) return bodyRaw;
  return bodyRaw
    .split("\n")
    .map((line) => line.startsWith(indent) ? line.slice(indent.length) : line)
    .join("\n");
}

function renderTableRow(row: TableRowNode, asHeader: boolean, context: RenderContext): string {
  const cellTag = asHeader ? "th" : "td";
  const cells = row.cells
    .map((cell) => {
      const parsed = parseInlinesFromText(String(cell || "").trim());
      const rendered = renderInlineChildren(parsed, context);
      return `<${cellTag}>${rendered}</${cellTag}>`;
    })
    .join("");
  return `<tr>${cells}</tr>`;
}

function renderTable(node: TableNode, context: RenderContext): string {
  const rows = node.rows;
  const firstHline = rows.findIndex((row): row is TableHlineNode => row.type === "TableHline");

  const headerRows =
    firstHline > 0
      ? rows.slice(0, firstHline).filter((row): row is TableRowNode => row.type === "TableRow")
      : [];

  const bodyRows =
    firstHline >= 0
      ? rows.slice(firstHline + 1).filter((row): row is TableRowNode => row.type === "TableRow")
      : rows.filter((row): row is TableRowNode => row.type === "TableRow");

  const resolvedBodyRows = bodyRows.length > 0 ? bodyRows : headerRows;
  const renderedHead =
    headerRows.length > 0 ? `<thead>\n${headerRows.map((row) => renderTableRow(row, true, context)).join("\n")}\n</thead>` : "";
  const renderedBody = `<tbody>\n${resolvedBodyRows.map((row) => renderTableRow(row, false, context)).join("\n")}\n</tbody>`;

  const sourceAttributes = renderSourceAttributes(node, context);
  const table = `<table${sourceAttributes}>\n${[renderedHead, renderedBody].filter(Boolean).join("\n")}\n</table>`;
  const tableHtml = context.profile === "app" ? `<div class="org2-table-scroll">\n${table}\n</div>` : table;
  const sourceRange = (node as SourceRangedNode).sourceRange;
  const chart = sourceRange ? context.chartsByTableLine?.get(sourceRange.startLine) : undefined;
  return chart ? `${tableHtml}\n${renderEmbeddedChart(chart)}` : tableHtml;
}

function renderListItem(node: ListItemNode, context: RenderContext): string {
  const body = renderNodes(node.children, context);
  const sourceAttributes = renderSourceAttributes(node, context);
  const checkbox =
    node.checkbox === "checked"
      ? '<input type="checkbox" checked disabled /> '
      : node.checkbox === "unchecked"
        ? '<input type="checkbox" disabled /> '
        : "";

  if (!body.trim()) return `<li${sourceAttributes}>${checkbox}</li>`;
  if (body.includes("\n")) return `<li${sourceAttributes}>${checkbox}\n${body}\n</li>`;
  return `<li${sourceAttributes}>${checkbox}${body}</li>`;
}

function renderList(node: ListNode, context: RenderContext): string {
  const tag = node.ordered ? "ol" : "ul";
  const items = node.items.map((item) => renderListItem(item, context)).join("\n");
  return `<${tag}${renderSourceAttributes(node, context)}>\n${items}\n</${tag}>`;
}

function renderHeadline(node: HeadlineNode, context: RenderContext): string {
  const headingLevel = Math.max(1, Math.min(6, node.level));
  const headingTag = `h${headingLevel}`;
  const title = renderInlineChildren(node.title, context);
  const headingNumberRaw = context.headlineNumbers?.get(node);
  const headingNumber = headingNumberRaw ? `<span class="org2-headline-number">${escapeHtml(headingNumberRaw)}</span> ` : "";
  const todoClass = String(node.todo || "").trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "-");
  const appTodoClass = context.profile === "app" && todoClass ? ` todo-${escapeAttr(todoClass)}` : "";
  const todo = node.todo ? `<span class="org2-todo${appTodoClass}">${escapeHtml(node.todo)}</span> ` : "";
  const tags =
    node.tags && node.tags.length > 0
      ? ` <span class="org2-tags">${node.tags.map((tag) => `<span class="org2-tag">${escapeHtml(tag)}</span>`).join(" ")}</span>`
      : "";
  const headingId = context.headlineIds?.get(node);
  const headingIdAttr = headingId ? ` id="${escapeAttr(headingId)}"` : "";

  const childrenHtml = renderNodes(node.children, context);
  if (context.profile === "app") {
    const body = childrenHtml.trim()
      ? `\n<div class="org2-headline-body">\n${childrenHtml}\n</div>`
      : "";
    return `<details class="org2-headline level-${node.level}" open${renderSourceAttributes(node, context)}>\n<summary class="org2-headline-summary"><${headingTag}${headingIdAttr}>${headingNumber}${todo}${title}${tags}</${headingTag}></summary>${body}\n</details>`;
  }

  if (!childrenHtml.trim()) {
    return `<section class="org2-headline level-${node.level}"${renderSourceAttributes(node, context)}>\n<${headingTag}${headingIdAttr}>${headingNumber}${todo}${title}${tags}</${headingTag}>\n</section>`;
  }

  return `<section class="org2-headline level-${node.level}"${renderSourceAttributes(node, context)}>\n<${headingTag}${headingIdAttr}>${headingNumber}${todo}${title}${tags}</${headingTag}>\n${childrenHtml}\n</section>`;
}

function renderNode(node: Node, context: RenderContext): string {
  if (node.type === "Headline") return renderHeadline(node, context);
  if (node.type === "Paragraph") return renderParagraph(node, context);
  if (node.type === "List") return renderList(node, context);
  if (node.type === "ListItem") return renderListItem(node, context);
  if (node.type === "Planning") return renderPlanning(node, context);
  if (node.type === "PropertyDrawer") return renderPropertyDrawer(node, context);
  if (node.type === "SrcBlock") return renderSrcBlock(node, context);
  if (node.type === "Block") return renderBlock(node, context);
  if (node.type === "Table") return renderTable(node, context);
  if (node.type === "Drawer") {
    const name = escapeHtml(node.nameRaw);
    const body = escapeHtml(node.bodyRaw.replace(/\n$/, ""));
    return `<details class="org2-drawer"${renderSourceAttributes(node, context)}><summary>${name}</summary><pre>${body}</pre></details>`;
  }
  if (node.type === "KeywordLine") {
    const key = String(node.keyRaw || "").trim().toUpperCase();
    if (HIDDEN_DOCUMENT_KEYWORDS.has(key)) return "";
    return `<p class="org2-keyword"><span class="org2-keyword-name">${escapeHtml(node.keyRaw)}</span>: ${escapeHtml(node.valueRaw.trim())}</p>`;
  }
  if (node.type === "DirectiveLine") {
    return `<pre class="org2-directive">${escapeHtml(node.raw)}</pre>`;
  }
  if (node.type === "CommentLine") return "";
  if (node.type === "Text") {
    const text = String(node.value || "");
    return text.trim().length > 0 ? `<p>${escapeHtml(text)}</p>` : "";
  }

  return "";
}

function renderNodes(nodes: Node[], context: RenderContext = {}): string {
  return nodes
    .map((node) => renderNode(node, context))
    .filter((html) => String(html || "").trim().length > 0)
    .join("\n");
}

function splitAppFileProperties(nodes: Node[]): { properties: Node[]; body: Node[] } {
  const properties: Node[] = [];
  const body: Node[] = [];
  let inPreamble = true;

  for (const node of nodes) {
    if (inPreamble && node.type === "CommentLine") continue;
    if (inPreamble && node.type === "KeywordLine") {
      const key = String(node.keyRaw || "").trim().toUpperCase();
      if (!HIDDEN_DOCUMENT_KEYWORDS.has(key)) properties.push(node);
      continue;
    }
    inPreamble = false;
    body.push(node);
  }

  return { properties, body };
}

function renderAppFileProperties(nodes: Node[], context: RenderContext): string {
  if (nodes.length === 0) return "";
  const rows = renderNodes(nodes, context);
  if (!rows.trim()) return "";
  return `<details class="org2-file-properties">\n<summary>File properties <span class="org2-file-properties-count">${nodes.length}</span></summary>\n<div class="org2-file-properties-body">\n${rows}\n</div>\n</details>`;
}

function findTitleFromKeywords(doc: DocumentNode): string | null {
  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    if (String(node.keyRaw || "").trim().toUpperCase() !== "TITLE") continue;
    const value = String(node.valueRaw || "").trim();
    if (value) return value;
  }
  return null;
}

function findSubtitleFromKeywords(doc: DocumentNode): string | null {
  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    if (String(node.keyRaw || "").trim().toUpperCase() !== "SUBTITLE") continue;
    const value = String(node.valueRaw || "").trim();
    if (value) return value;
  }
  return null;
}

function findTitleFromHeadlines(doc: DocumentNode): string | null {
  for (const node of doc.children) {
    if (node.type !== "Headline") continue;
    const text = node.title.map((child) => inlineToText(child)).join("").trim();
    if (text) return text;
  }
  return null;
}

function resolveTitle(doc: DocumentNode, explicitTitle: string | undefined, sourcePath: string | undefined): string {
  const explicit = String(explicitTitle || "").trim();
  if (explicit) return explicit;

  const keyword = findTitleFromKeywords(doc);
  if (keyword) return keyword;

  const headline = findTitleFromHeadlines(doc);
  if (headline) return headline;

  if (sourcePath) return path.basename(sourcePath);
  return "Org2 Document";
}

function renderDocumentHeader(opts: { title: string; subtitle?: string }): string {
  const title = String(opts.title || "").trim();
  if (!title) return "";

  const subtitle = String(opts.subtitle || "").trim();
  const subtitleHtml = subtitle ? `\n<p class="org2-document-subtitle" role="doc-subtitle">${escapeHtml(subtitle)}</p>` : "";
  return `<header class="org2-document-header">\n<h1 class="org2-document-title">${escapeHtml(title)}</h1>${subtitleHtml}\n</header>`;
}

type ResolvedDocumentRenderOptions = {
  includeToc: boolean;
  includeTocDepth: number | undefined;
  includeHeadlineNumbers: boolean;
  includeHeadlineNumberDepth: number | undefined;
  includeDocumentHeader: boolean;
};

function resolveDocumentRenderOptions(
  doc: DocumentNode,
  opts: {
    includeToc?: boolean;
    includeTocDepth?: number;
    includeHeadlineNumbers?: boolean;
    includeHeadlineNumberDepth?: number;
    includeDocumentHeader?: boolean;
  },
): ResolvedDocumentRenderOptions {
  const exportOptions = collectKeywordOptions(doc);
  const includeToc = opts.includeToc === true || (opts.includeToc !== false && exportOptions.toc === true);
  const includeTocDepth =
    normalizeTocDepth(opts.includeTocDepth) ?? normalizeTocDepth(exportOptions.tocDepth) ?? undefined;
  const includeHeadlineNumbers =
    opts.includeHeadlineNumbers === true ||
    (opts.includeHeadlineNumbers !== false && exportOptions.num === true);
  const includeHeadlineNumberDepth =
    normalizeHeadlineNumberDepth(opts.includeHeadlineNumberDepth) ??
    normalizeHeadlineNumberDepth(exportOptions.numDepth) ??
    undefined;
  const includeDocumentHeader =
    opts.includeDocumentHeader === true ||
    (opts.includeDocumentHeader !== false && Boolean(findSubtitleFromKeywords(doc)));

  return {
    includeToc,
    includeTocDepth,
    includeHeadlineNumbers,
    includeHeadlineNumberDepth,
    includeDocumentHeader,
  };
}

function buildDocumentRenderContext(
  doc: DocumentNode,
  opts: {
    includeToc: boolean;
    includeTocDepth?: number;
    includeHeadlineNumbers: boolean;
    includeHeadlineNumberDepth?: number;
    rewriteFileLinks?: boolean;
    linkAbbreviations?: LinkAbbreviationRecord;
    linearTeam?: string;
    profile?: "publish" | "app";
    charts?: OrgEmbeddedChart[];
  },
): { context: RenderContext; tocItems: TocItem[] } {
  let tocItems: TocItem[] = [];
  const includeHeadingAnchors = opts.includeToc || opts.rewriteFileLinks === true || nodesNeedHeadingAnchors(doc.children);
  const includeHeadlineData = includeHeadingAnchors || opts.includeHeadlineNumbers;
  const builtIns = buildBuiltInLinkAbbreviations(opts.linearTeam);
  const configAbbreviations = collectLinkAbbreviationsFromRecord(opts.linkAbbreviations);
  const documentAbbreviations = collectLinkAbbreviationsFromDoc(doc);

  const context: RenderContext = {
    rewriteFileLinks: opts.rewriteFileLinks === true,
    profile: opts.profile,
    // Precedence: built-ins < config < document-local #+LINK
    linkAbbreviations: mergeLinkAbbreviations([builtIns, configAbbreviations, documentAbbreviations]),
  };

  if (opts.charts?.length) {
    context.chartsByTableLine = new Map();
    context.chartsByBlockLine = new Map();
    for (const chart of opts.charts) {
      if (chart.source.chartLine) context.chartsByBlockLine.set(chart.source.chartLine, chart);
      else context.chartsByTableLine.set(chart.source.line, chart);
    }
  }

  if (includeHeadlineData) {
    const anchors = buildHeadlineAnchors(doc, {
      includeToc: opts.includeToc,
      includeTocDepth: opts.includeTocDepth,
      includeHeadlineNumbers: opts.includeHeadlineNumbers,
      includeHeadlineNumberDepth: opts.includeHeadlineNumberDepth,
    });
    tocItems = anchors.items;
    context.headlineIds = anchors.headlineIds;
    context.headlineSlugIds = anchors.headlineSlugIds;
    context.headlineNumbers = anchors.headlineNumbers;
  }

  return { context, tocItems };
}

function renderMainBody(opts: {
  doc: DocumentNode;
  context: RenderContext;
  includeToc: boolean;
  tocItems: TocItem[];
  includeDocumentHeader: boolean;
  title: string;
  subtitle?: string;
}): string {
  const appDocument = opts.context.profile === "app";
  const split = appDocument
    ? splitAppFileProperties(opts.doc.children)
    : { properties: [] as Node[], body: opts.doc.children };
  const body = renderNodes(split.body, opts.context);
  const fileProperties = appDocument ? renderAppFileProperties(split.properties, opts.context) : "";
  const tocHtml = opts.includeToc ? renderToc(opts.tocItems) : "";
  const documentHeader = opts.includeDocumentHeader
    ? renderDocumentHeader({ title: opts.title, subtitle: opts.subtitle })
    : "";

  return [documentHeader, fileProperties, tocHtml, body]
    .filter((segment) => String(segment || "").trim().length > 0)
    .join("\n");
}

function renderDocumentHtml(opts: {
  title: string;
  language: string;
  metadata: OrgExportMetadata;
  headIncludes?: string[];
  stylesheets?: string[];
  includeDefaultStyle?: boolean;
  includeToc: boolean;
  mainBody: string;
  preambleHtml?: string;
  postambleHtml?: string;
  compatContentWrapper?: boolean;
  includeDocumentHtml?: boolean;
}): string {
  const headMetaSection = renderHeadMetaSection(opts.metadata);
  const headExtraSection = renderHeadExtraSection(
    opts.metadata,
    opts.headIncludes,
    opts.includeDocumentHtml,
  );
  const headStyleSection = renderHeadStyleSection({
    stylesheets: opts.stylesheets,
    includeDefaultStyle: opts.includeDefaultStyle,
    defaultStyle: opts.includeToc ? `${DEFAULT_DOCUMENT_STYLE}
${DOCUMENT_TOC_STYLE}` : DEFAULT_DOCUMENT_STYLE,
  });

  const preambleSection = opts.preambleHtml ? `${opts.preambleHtml}
` : "";
  const postambleSection = opts.postambleHtml ? `${opts.postambleHtml}
` : "";
  const compatOpen = opts.compatContentWrapper ? COMPAT_CONTENT_OPEN : "";
  const compatClose = opts.compatContentWrapper ? COMPAT_CONTENT_CLOSE : "";
  const compatStyleSection = opts.compatContentWrapper ? COMPAT_CONTENT_STYLE_SECTION : "";

  return `<!doctype html>
<html lang="${escapeAttr(opts.language)}">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(opts.title)}</title>
${headMetaSection}${headExtraSection}${headStyleSection}${compatStyleSection}</head>
<body>
${compatOpen}<main class="org2-document">
${preambleSection}${opts.mainBody}
</main>
${compatClose}${postambleSection}</body>
</html>
`;
}

export function renderOrgDocumentToHtml(
  doc: DocumentNode,
  opts: {
    title?: string;
    sourcePath?: string;
    stylesheets?: string[];
    includeDefaultStyle?: boolean;
    includeToc?: boolean;
    includeTocDepth?: number;
    includeHeadlineNumbers?: boolean;
    includeHeadlineNumberDepth?: number;
    rewriteFileLinks?: boolean;
    preambleHtml?: string;
    postambleHtml?: string;
    headIncludes?: string[];
    includeDocumentHeader?: boolean;
    compatContentWrapper?: boolean;
    linkAbbreviations?: LinkAbbreviationRecord;
    linearTeam?: string;
    profile?: "publish" | "app";
    charts?: OrgEmbeddedChart[];
  } = {},
): { html: string; title: string; metadata: OrgExportMetadata } {
  const title = resolveTitle(doc, opts.title, opts.sourcePath);
  const metadata = collectKeywordMetadata(doc);
  const renderOptions = resolveDocumentRenderOptions(doc, opts);
  const { context, tocItems } = buildDocumentRenderContext(doc, {
    includeToc: renderOptions.includeToc,
    includeTocDepth: renderOptions.includeTocDepth,
    includeHeadlineNumbers: renderOptions.includeHeadlineNumbers,
    includeHeadlineNumberDepth: renderOptions.includeHeadlineNumberDepth,
    rewriteFileLinks: opts.rewriteFileLinks,
    linkAbbreviations: opts.linkAbbreviations,
    linearTeam: opts.linearTeam,
    profile: opts.profile,
    charts: opts.charts,
  });

  const mainBody = renderMainBody({
    doc,
    context,
    includeToc: renderOptions.includeToc,
    tocItems,
    includeDocumentHeader: renderOptions.includeDocumentHeader,
    title,
    subtitle: metadata.subtitle,
  });

  const html = renderDocumentHtml({
    title,
    language: metadata.language || "en",
    metadata,
    headIncludes: [
      ...(opts.headIncludes || []),
      opts.charts?.length && opts.profile !== "app" ? `<style id="org2-chart-style">\n${DOCUMENT_CHART_STYLE}\n</style>` : "",
    ].filter(Boolean),
    stylesheets: opts.stylesheets,
    includeDefaultStyle: opts.includeDefaultStyle,
    includeToc: renderOptions.includeToc,
    mainBody,
    preambleHtml: String(opts.preambleHtml || "").trim(),
    postambleHtml: String(opts.postambleHtml || "").trim(),
    compatContentWrapper: opts.compatContentWrapper,
    includeDocumentHtml: opts.profile !== "app",
  });

  return { html, title, metadata };
}

export function renderOrgDocumentToAppHtml(
  doc: DocumentNode,
  opts: {
    title?: string;
    sourcePath?: string;
    linkAbbreviations?: LinkAbbreviationRecord;
    linearTeam?: string;
    customCss?: string;
    charts?: OrgEmbeddedChart[];
  } = {},
): { html: string; title: string; metadata: OrgExportMetadata } {
  const customCss = String(opts.customCss || "").trim();
  const customStyle = customCss
    ? `<style id="org2-app-user-style">\n${customCss.replace(/<\/style/gi, "<\\/style")}\n</style>`
    : "";
  return renderOrgDocumentToHtml(doc, {
    title: opts.title,
    sourcePath: opts.sourcePath,
    includeDefaultStyle: false,
    includeToc: false,
    includeHeadlineNumbers: false,
    includeDocumentHeader: true,
    rewriteFileLinks: false,
    headIncludes: [
      `<style id="org2-app-document-style">\n${APP_DOCUMENT_STYLE}\n</style>`,
      `<script id="org2-app-document-script">\n${APP_DOCUMENT_SCRIPT}\n</script>`,
      customStyle,
    ].filter(Boolean),
    linkAbbreviations: opts.linkAbbreviations,
    linearTeam: opts.linearTeam,
    profile: "app",
    charts: opts.charts,
  });
}

export type OrgExportIndexItem = {
  title: string;
  href: string;
  sourcePath?: string;
};

export function renderOrgExportIndexToHtml(opts: {
  title?: string;
  sourcePath?: string;
  items: OrgExportIndexItem[];
  stylesheets?: string[];
  headIncludes?: string[];
  includeDefaultStyle?: boolean;
}): { html: string; title: string } {
  const title = String(opts.title || "").trim() || (opts.sourcePath ? path.basename(opts.sourcePath) : "Org2 Export Index");
  const items = Array.isArray(opts.items) ? opts.items : [];

  const listHtml = items
    .map((item) => {
      const itemTitle = String(item.title || "").trim() || String(item.href || "").trim() || "Untitled";
      const href = String(item.href || "").trim() || "#";
      const source = String(item.sourcePath || "").trim();
      const sourceHtml = source ? ` <span class="org2-export-source">(${escapeHtml(source)})</span>` : "";
      return `<li><a href="${escapeAttr(href)}">${escapeHtml(itemTitle)}</a>${sourceHtml}</li>`;
    })
    .join("\n");

  const body = listHtml || "<li>No exported files.</li>";
  const headStyleSection = renderHeadStyleSection({
    stylesheets: opts.stylesheets,
    includeDefaultStyle: opts.includeDefaultStyle,
    defaultStyle: DEFAULT_INDEX_STYLE,
  });
  const headExtraSection = renderHeadExtraSection({}, opts.headIncludes, false);
  const titleId = slugifyHeadlineTitle(title);

  const html = `<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8" />\n<meta name="viewport" content="width=device-width, initial-scale=1" />\n<title>${escapeHtml(title)}</title>\n${headExtraSection}${headStyleSection}</head>\n<body>\n<main id="content" class="content org2-export-index-document">\n<h1 id="${escapeAttr(titleId)}">${escapeHtml(title)}</h1>\n<ul class="org2-export-index">\n${body}\n</ul>\n</main>\n</body>\n</html>\n`;

  return { html, title };
}
