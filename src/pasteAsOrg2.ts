import { classifyPasteLines, heuristicPasteLabel, type PasteLabel, type PasteStructureModel } from "./pasteStructureClassifier.js";

export interface PasteBlock {
  text: string;
  label: PasteLabel;
  origin: "html" | "model" | "heuristic" | "fallback";
  confidence?: number;
  level?: number;
  cells?: string[];
  /** UTF-16 offsets into original plain text, including its original line ending. */
  sourceStart?: number;
  sourceEnd?: number;
  sourceLine?: number;
}
export interface PastePreview {
  schema: "org2:paste-preview-experiment:v1";
  originalText: string;
  originalHtml?: string;
  sourceUrl?: string;
  blocks: PasteBlock[];
  links: string[];
  org: string;
  warnings: string[];
}
export const MAX_PASTE_CHARACTERS = 200_000;

export function plainPasteBlocks(text: string, model?: PasteStructureModel): PasteBlock[] {
  if (text.length > MAX_PASTE_CHARACTERS) throw new Error("Paste exceeds prototype limit of 200,000 characters");
  const slices = text.match(/[^\r\n]*(?:\r\n|\r|\n|$)/g)?.filter(value => value !== "") ?? [];
  const lines = slices.map(value => value.replace(/(?:\r\n|\r|\n)$/, ""));
  const predictions = model ? classifyPasteLines(lines, model) : undefined;
  let offset = 0;
  return slices.map((slice, index) => {
    const prediction = predictions?.[index];
    const accepted = prediction && prediction.confidence >= model!.threshold;
    const block: PasteBlock = {
      text: lines[index]!,
      label: accepted ? prediction.label : prediction ? "paragraph" : heuristicPasteLabel(lines[index]!),
      origin: accepted ? "model" : prediction ? "fallback" : "heuristic",
      ...(prediction ? { confidence: prediction.confidence } : {}),
      sourceStart: offset, sourceEnd: offset + slice.length, sourceLine: index + 1,
    };
    offset += slice.length;
    return block;
  });
}

// Fixed-width Org is the conservative literal fallback: even block delimiters,
// drawers and TODO syntax stay data. Original payload and offsets stay in preview.
export function literalPasteOrg(text: string): string {
  return text.split(/\r\n|\r|\n/).map(line => `: ${line}`).join("\n");
}
const hazardousInline = (text: string) => /\[\[|\]\]|\{\{\{|@@|\[fn:|<<|[\u0000-\u0008]/.test(text);
const structuralLine = (text: string) => /^\s*(?:\*+\s|#\+|:[\w@#%]+:|\||(?:SCHEDULED|DEADLINE|CLOSED):)/i.test(text);

/** Only adds structure; never edits, completes, summarizes, or regenerates words. */
export function serializePasteBlocks(blocks: readonly PasteBlock[], links: readonly string[] = []): string {
  const parts = blocks.map(block => {
    const text = block.text;
    if (!text) return "";
    if (block.origin === "fallback" || hazardousInline(text)) return literalPasteOrg(text);
    if (block.label === "heading" && !/[\r\n]/.test(text)
      && !/^(?:TODO|DONE|WAITING|CANCELED|COMMENT)\b|\s:[\w:]+:$|^\[#/.test(text)) {
      return `${"*".repeat(Math.min(6, Math.max(1, block.level ?? 1)))} ${text}`;
    }
    if (block.label === "list" && !/[\r\n]/.test(text) && !/^\s*\[[ xX-]\]/.test(text)) {
      // Keep existing numbering/bullets as source data; avoid renumbering quantities.
      return `- ${text}`;
    }
    if (block.label === "table" && block.cells?.length && block.cells.every(cell => !/[|\r\n]/.test(cell) && !hazardousInline(cell))) {
      return `| ${block.cells.join(" | ")} |`;
    }
    if (block.label === "quote" && !text.split(/\r\n|\r|\n/).some(structuralLine)) {
      return `#+begin_quote\n${text}\n#+end_quote`;
    }
    if (block.label === "paragraph" && !text.split(/\r\n|\r|\n/).some(line => structuralLine(line) || /^\s*(?:[-+]|\d+[.)])\s|^\s*:/.test(line))) return text;
    // Code is deliberately never an executable src block; ambiguous tables retain
    // their literal delimiters instead of guessing columns or deleting characters.
    return literalPasteOrg(text);
  });
  for (const link of [...new Set(links)]) {
    // Link target is preserved verbatim. Unrepresentable targets stay literal.
    parts.push(/^https?:\/\/[^\s\[\]<>]+$|^mailto:[^\s\[\]<>]+$/i.test(link)
      ? `[[${link}]]` : literalPasteOrg(link));
  }
  return parts.map((part, index) => {
    if (!index) return part;
    const adjacentRows = blocks[index]?.label === "table" && blocks[index - 1]?.label === "table"
      && part.startsWith("| ") && parts[index - 1]!.startsWith("| ");
    const current = blocks[index];
    const previous = blocks[index - 1];
    const samePlainStructure = current && previous && current.origin !== "html" && previous.origin !== "html"
      && (current.label === previous.label && current.label !== "quote" || !part || !parts[index - 1]);
    return (adjacentRows || samePlainStructure ? "\n" : "\n\n") + part;
  }).join("");
}

export function createPastePreview(input: {
  text: string; html?: string; sourceUrl?: string;
  semantic?: { blocks: PasteBlock[]; links: string[]; warnings: string[]; fallbackText?: string };
  model?: PasteStructureModel;
}): PastePreview {
  if (input.text.length > MAX_PASTE_CHARACTERS || (input.html?.length ?? 0) > MAX_PASTE_CHARACTERS) throw new Error("Paste exceeds prototype limit of 200,000 characters");
  const semantic = input.semantic?.blocks.length ? input.semantic : undefined;
  const blocks = semantic?.blocks ?? (input.text ? plainPasteBlocks(input.text, input.model)
    : input.semantic?.fallbackText ? [{ text: input.semantic.fallbackText, label: "paragraph" as const, origin: "fallback" as const }]
      : plainPasteBlocks(input.text, input.model));
  const links = [...(input.semantic?.links ?? []), ...(input.sourceUrl ? [input.sourceUrl] : [])];
  const warnings = [...(input.semantic?.warnings ?? [])];
  if (!semantic) warnings.push(input.model
    ? "Experimental model suggestions; low confidence lines remain literal. Scores are not calibrated probabilities."
    : "Heuristic baseline: ambiguous structure is not inferred.");
  if (blocks.some(block => block.origin === "fallback")) warnings.push("Uncertain lines retained as literal Org text.");
  return { schema: "org2:paste-preview-experiment:v1", originalText: input.text,
    ...(input.html !== undefined ? { originalHtml: input.html } : {}),
    ...(input.sourceUrl ? { sourceUrl: input.sourceUrl } : {}),
    blocks, links, warnings, org: serializePasteBlocks(blocks, links) };
}

/** In-memory preview/edit/insertion boundary used by the local harness. */
export class PastePreviewSession {
  preview?: PastePreview;
  editedOrg = "";
  private target?: { text: string; start: number; end: number };
  begin(preview: PastePreview, text: string, start: number, end: number): void {
    if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end < start || end > text.length) throw new Error("Invalid insertion selection");
    this.preview = preview; this.editedOrg = preview.org;
    this.target = { text, start, end };
  }
  cancel(): void { this.preview = undefined; this.editedOrg = ""; this.target = undefined; }
  insert(currentText: string): string {
    if (!this.preview || !this.target) throw new Error("Preview required before insertion");
    if (currentText !== this.target.text) throw new Error("Document changed; preview again before insertion");
    const result = currentText.slice(0, this.target.start) + this.editedOrg + currentText.slice(this.target.end);
    this.cancel();
    return result;
  }
}
