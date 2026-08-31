import type { DocumentNode } from "./ast.js";

type MutableRecord = Record<string, unknown>;

function asRecord(value: unknown): MutableRecord | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as MutableRecord
    : undefined;
}

function canonicalSourceArguments(raw: unknown): string {
  const trimmed = String(raw ?? "").trim();
  return trimmed ? ` ${trimmed}` : "";
}

function walkAndCanonicalize(value: unknown): void {
  if (Array.isArray(value)) {
    value.forEach(walkAndCanonicalize);
    return;
  }

  const node = asRecord(value);
  if (!node) return;

  if (node.type === "Emphasis" && node.kind === "code" && node.marker === "`") {
    const content = String(node.content ?? "");
    if (!content.includes("~")) node.marker = "~";
    else if (!content.includes("=")) node.marker = "=";
  }

  if (node.type === "SrcBlock") {
    const begin = asRecord(node.begin);
    const end = asRecord(node.end);
    const beginKeyword = String(begin?.keywordRaw ?? "").toLowerCase();

    const bodyContainsCanonicalEnd = /(^|\n)\s*#\+end_src(?:\s|$)/i.test(String(node.bodyRaw ?? ""));

    if (begin && beginKeyword === "```" && !bodyContainsCanonicalEnd) {
      begin.keywordRaw = "begin_src";
      begin.afterKeywordRaw = canonicalSourceArguments(begin.afterKeywordRaw);
      if (end) {
        end.keywordRaw = "end_src";
        end.afterKeywordRaw = "";
      }
    } else if (begin && beginKeyword === "begin_org2") {
      const argumentsRaw = canonicalSourceArguments(begin.afterKeywordRaw);
      begin.keywordRaw = "begin_src";
      begin.afterKeywordRaw = ` org2${argumentsRaw}`;
      if (end && String(end.keywordRaw ?? "").toLowerCase() === "end_org2") {
        end.keywordRaw = "end_src";
        end.afterKeywordRaw = "";
      }
    }
  }

  Object.values(node).forEach(walkAndCanonicalize);
}

/**
 * Rewrite accepted Org2 input conveniences to ordinary Org surface syntax.
 *
 * The parser and default printer remain lossless. This explicit transformation
 * mutates a freshly parsed AST before canonical `.org` serialization.
 */
export function canonicalizeOrgSyntaxSugar(document: DocumentNode): DocumentNode {
  walkAndCanonicalize(document);
  return document;
}
