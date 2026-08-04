import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseOrgToCanonicalAst } from "../dist/parser.js";
import { compilePresentation, isPresentationDocument, renderPresentationToBeamer } from "../dist/presentation.js";
import { compileBeamerPdf, summarizeLatexFailure } from "../dist/beamerCompile.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixture = path.join(root, "test", "fixtures", "presentation-beamer.org2");
const source = fs.readFileSync(fixture, "utf8");
const document = parseOrgToCanonicalAst(source, { sourceRanges: true });
const presentation = compilePresentation(document);

assert.equal(isPresentationDocument(document), true);
assert.equal(
  isPresentationDocument(parseOrgToCanonicalAst("#+TITLE: Ordinary note\n* Heading\nBody.\n")),
  false,
);
assert.equal(
  isPresentationDocument(parseOrgToCanonicalAst("* Section\n** Slide\n*** Block\n:PROPERTIES:\n:SLIDE_ENV: block\n:END:\n")),
  true,
);
assert.equal(
  isPresentationDocument(parseOrgToCanonicalAst("#+LATEX_CLASS_OPTIONS: [presentation,aspectratio=169]\n* Slide\n")),
  true,
);
assert.equal(presentation.metadata.title, "Org2 Presentation Compatibility");
assert.equal(presentation.metadata.frameLevel, 2);
assert.equal(presentation.metadata.toc, true);
assert.deepEqual(presentation.metadata.classOptions, ["presentation", "aspectratio=169"]);
assert.equal(presentation.sections.length, 2);
assert.equal(presentation.sections.reduce((count, section) => count + section.slides.length, 0), 3);
assert.deepEqual(presentation.diagnostics, []);

const left = presentation.sections[0].slides[0].elements.find(
  (element) => element.kind === "group" && element.columnWidth === "0.45",
);
assert.ok(left, "expected an indented legacy property drawer to produce a column");
assert.equal(left.environment, "block");

const rendered = renderPresentationToBeamer(document);
assert.ok(rendered.tex.includes("\\documentclass[presentation,aspectratio=169]{beamer}"));
assert.ok(rendered.tex.includes("\\usetheme{Madrid}"));
assert.ok(rendered.tex.includes("\\begin{column}{0.45\\columnwidth}"));
assert.ok(rendered.tex.includes("\\begin{block}<2->{Right}"));
assert.ok(rendered.tex.includes("\\begin{frame}[label={org2:1-columns-and-source},fragile]"));
assert.ok(rendered.tex.includes("\\href{org2-source-line://11}"));
assert.ok(rendered.tex.includes("\\begin{verbatim}\nconst answer = 42;"));
assert.equal(rendered.tex.includes("generated-result.png"), false);
assert.ok(rendered.tex.includes("\\includegraphics[height=0.5\\textwidth]{\\detokenize{diagram.png}}"));
assert.ok(rendered.tex.includes("\\note{Remember this\n\nMention the source ranges.}"));
assert.ok(rendered.tex.includes("\\begin{block}<3->{Native block}"));
assert.ok(rendered.tex.includes("southeast path \\ensuremath{\\searrow} and verify x \\ensuremath{\\geq} 2."));
assert.ok(rendered.tex.includes("\\usepackage{listings}"));
assert.ok(rendered.tex.includes("literate={↘}{{\\ensuremath{\\searrow}}}1"));
assert.ok(rendered.tex.includes("flow ↘ target"));
assert.ok(rendered.tex.includes("\\pause"));
assert.ok(rendered.tex.includes("\\begin{quote}"));
assert.ok(rendered.tex.includes("\\begin{tabular}{ll}"));
assert.ok(rendered.tex.includes("\\vfill"));

const topLevelList = document.children
  .flatMap((node) => node.type === "Headline" ? node.children : [])
  .flatMap((node) => node.type === "Headline" ? node.children : [])
  .find((node) => node.type === "Headline" && node.title[0]?.type === "Text" && node.title[0].value === "Left")
  ?.children.find((node) => node.type === "List");
assert.ok(topLevelList && topLevelList.type === "List");
assert.equal(topLevelList.items.length, 2, "dedenting after a nested list must resume the parent list");
assert.equal(topLevelList.items[0].children.filter((node) => node.type === "List").length, 1);

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-presentation-test-"));
try {
  const output = path.join(tmp, "deck.tex");
  const cli = path.join(root, "dist", "cli.js");
  const preview = JSON.parse(execFileSync(
    "node",
    [cli, "export", "beamer", "--file", fixture, "--out", output, "--format", "json"],
    { encoding: "utf8", cwd: root },
  ));
  assert.equal(preview.kind, "export-beamer-tex");
  assert.equal(preview.slideCount, 3);
  assert.equal(fs.existsSync(output), false);

  execFileSync(
    "node",
    [cli, "export", "beamer", "--file", fixture, "--out", output, "--apply"],
    { encoding: "utf8", cwd: root },
  );
  assert.equal(fs.readFileSync(output, "utf8"), rendered.tex);
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

const missingEngine = compileBeamerPdf(rendered.tex, {
  sourcePath: fixture,
  engine: "org2-definitely-missing-latex-engine",
});
assert.equal(missingEngine.ok, false);
assert.match(missingEngine.message, /Could not run/);

assert.equal(
  summarizeLatexFailure(
    "/tmp/deck.tex:18\n7: Package inputenc Error: Unicode character ↘ (U+2198)\n(inputenc) not set up for use with LaTeX.",
    "pdflatex",
    1,
  ),
  "pdflatex failed at generated line 187: Unicode character ↘ (U+2198) not set up for use with LaTeX.",
);
assert.equal(
  summarizeLatexFailure(
    "/tmp/deck.tex:54: Package pdftex.def Error: File `diagram.png' not found.",
    "pdflatex",
    1,
  ),
  "pdflatex failed at generated line 54: File `diagram.png' not found.",
);

console.log("presentation beamer tests passed");
