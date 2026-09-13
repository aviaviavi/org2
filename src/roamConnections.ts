import fs from "node:fs";
import path from "node:path";
import { guardedContentRevision, guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { loadConfig, resolveFilesFromDir } from "./config.js";
import { parseHeadlineTitleForRoam } from "./headlineTitle.js";
import {
  buildRoamGraph, buildRoamLinkifyIndex, collectRoamNodesForIndex, escapeRegExp,
  isRoamLinkifyGenericLabel, isRoamLinkifyLabelEligible, lineAllowsRoamLinkify,
  normalizeRoamLinkLabel, renderRoamLink, splitRoamLinkifyProtectedSegments,
  type RoamGraphData, type RoamGraphNode, type RoamLinkifyCandidate,
} from "./roam.js";

export interface RoamMention {
  id: string;
  file: string;
  line: number;
  /** Zero-based UTF-16 columns; end is exclusive. */
  start: number;
  end: number;
  text: string;
  context: string;
  revision: string;
  candidates: Array<{ id: string; label: string; file: string }>;
  ambiguous: boolean;
}

/** Respect the active root, corpus ignores, default archive boundaries, and no symlink traversal. */
export function connectionFiles(root: string): string[] {
  const configFile = path.join(root, "org2.json");
  const config = fs.existsSync(configFile) ? loadConfig(configFile) : {};
  return resolveFilesFromDir(root, ["**/*.org", "**/*.org2"], [
    "**/node_modules", "**/dist", "**/build", "**/DerivedData", "**/sync-conflicts",
    "**/archive", "**/archives", ...(config.ignorePatterns || []),
  ]).filter(file => !/(?:\.archive\.|_archive$)/i.test(path.basename(file)));
}

export function findUnlinkedMentions(
  content: string, file: string, index: Map<string, RoamLinkifyCandidate[]>, targetId?: string,
): RoamMention[] {
  const ownNodes = collectRoamNodesForIndex(content, file);
  const ownIDs = new Set(ownNodes.map(node => node.id));
  const ownLabels = new Set(ownNodes.flatMap(node => node.labels.map(normalizeRoamLinkLabel)));
  const labels = [...index.keys()].filter(isRoamLinkifyLabelEligible).filter(label => !isRoamLinkifyGenericLabel(label))
    .filter(label => !ownLabels.has(label) && !/[\[\]\r\n]/.test(label)).sort((a, b) => b.length - a.length || a.localeCompare(b));
  const revision = guardedContentRevision(content);
  const mentions: RoamMention[] = [];
  let inBlock = false, inDrawer = false;
  let backlinksLevel: number | null = null;
  for (const [lineIndex, line] of content.split(/\r\n|\n/).entries()) {
    const trimmed = line.trim();
    if (/^#\+begin_/i.test(trimmed)) { inBlock = true; continue; }
    if (/^#\+end_/i.test(trimmed)) { inBlock = false; continue; }
    if (inBlock) continue;
    if (/^:(?:PROPERTIES|LOGBOOK):$/i.test(trimmed)) { inDrawer = true; continue; }
    if (/^:END:$/i.test(trimmed)) { inDrawer = false; continue; }
    const heading = /^(\*+)\s/.exec(line);
    if (heading && !inDrawer) {
      if (backlinksLevel !== null && heading[1]!.length <= backlinksLevel) backlinksLevel = null;
      if (normalizeRoamLinkLabel(parseHeadlineTitleForRoam(line)) === "backlinks") backlinksLevel = heading[1]!.length;
    }
    if (backlinksLevel !== null || !lineAllowsRoamLinkify(line, inBlock, inDrawer)) continue;
    const claimed: Array<{ start: number; end: number }> = [];
    for (const label of labels) {
      const candidates = (index.get(label) || []).filter(candidate => !ownIDs.has(candidate.id));
      if (!candidates.length || (targetId && !candidates.some(candidate => candidate.id === targetId))) continue;
      const regex = new RegExp(`(^|[^A-Za-z0-9_])(${escapeRegExp(candidates[0]!.label)})(?=$|[^A-Za-z0-9_])`, "gi");
      let offset = 0;
      for (const segment of splitRoamLinkifyProtectedSegments(line)) {
        if (!segment.protected) {
          regex.lastIndex = 0;
          for (const match of segment.text.matchAll(regex)) {
            const start = offset + match.index! + match[1]!.length;
            const end = start + match[2]!.length;
            if (claimed.some(range => start < range.end && end > range.start)) continue;
            claimed.push({ start, end });
            const lineNumber = lineIndex + 1;
            mentions.push({
              id: guardedContentRevision(`${file}\n${lineNumber}:${start}:${end}:${label}`).slice(7),
              file, line: lineNumber, start, end, text: match[2]!, context: line, revision,
              candidates: candidates.map(candidate => ({ id: candidate.id, label: candidate.label, file: candidate.file })),
              ambiguous: candidates.length > 1,
            });
          }
        }
        offset += segment.text.length;
      }
    }
  }
  return mentions.sort((a, b) => a.line - b.line || a.start - b.start);
}

export function localRoamNeighborhood(graph: RoamGraphData, focusId: string, depth = 1, limit = 60) {
  if (![1, 2].includes(depth)) throw new Error("--depth must be 1 or 2");
  const focus = graph.nodes.find(node => node.id === focusId);
  if (!focus) throw new Error(`No graph node with ID ${focusId}`);
  const included = new Set([focusId]);
  let frontier = new Set([focusId]);
  let truncated = false;
  for (let level = 0; level < depth; level += 1) {
    const next = new Set<string>();
    for (const edge of graph.edges) {
      const candidates = [frontier.has(edge.source) ? edge.target : null, frontier.has(edge.target) ? edge.source : null];
      for (const id of candidates) {
        if (!id || included.has(id)) continue;
        if (included.size >= limit) { truncated = true; continue; }
        included.add(id); next.add(id);
      }
    }
    frontier = next;
  }
  return { focus, depth, truncated, nodes: graph.nodes.filter(node => included.has(node.id)), edges: graph.edges.filter(edge => included.has(edge.source) && included.has(edge.target)) };
}

export function readRoamConnections(root: string, options: { id?: string; file?: string; line?: number; depth?: number }) {
  const files = connectionFiles(root);
  const graph = buildRoamGraph(files);
  let focus: RoamGraphNode | undefined;
  if (options.id) focus = graph.nodes.find(node => node.id === options.id!.toLowerCase());
  else if (options.file) {
    const file = path.resolve(options.file);
    const line = options.line || 1;
    focus = graph.nodes.filter(node => node.file === file && node.line <= line && node.lineEnd >= line)
      .sort((a, b) => b.line - a.line)[0];
  }
  const neighborhood = focus ? localRoamNeighborhood(graph, focus.id, options.depth) : null;
  const mentions: RoamMention[] = [];
  let mentionsTruncated = false;
  if (focus) {
    const index = buildRoamLinkifyIndex(files);
    for (const file of files) {
      if (path.relative(path.resolve(root), file).split(path.sep)[0] === "raw") continue;
      for (const mention of findUnlinkedMentions(fs.readFileSync(file, "utf8"), file, index, focus.id)) {
        if (mentions.length >= 200) { mentionsTruncated = true; break; }
        mentions.push({ ...mention, candidates: mention.candidates.map(candidate => ({ ...candidate, label: graph.nodes.find(node => node.id === candidate.id)?.label || candidate.label })) });
      }
      if (mentionsTruncated) break;
    }
  }
  return { $schema: "org2:connections:v1", root, scannedFiles: files.length, neighborhood, mentions, mentionsTruncated };
}

export function linkRoamMention(root: string, options: { file: string; mention: string; target: string; revision: string; apply?: boolean }) {
  const files = connectionFiles(root);
  const file = path.resolve(options.file);
  if (!files.includes(file)) throw new Error("Mention source must be an indexed file inside the active corpus (symlinks and ignored files are excluded).");
  if (path.relative(path.resolve(root), file).split(path.sep)[0] === "raw") throw new Error("Raw captures are immutable; link a reviewable or canonical source instead.");
  const snapshot = readGuardedFile(file);
  if (snapshot.revision !== options.revision) throw new Error("Mention source changed. Refresh connections before linking.");
  const index = buildRoamLinkifyIndex(files);
  const target = options.target.toLowerCase();
  if (!/^[^\s\[\]<>]+$/.test(target)) throw new Error("Target ID cannot be represented as an Org ID link.");
  const mention = findUnlinkedMentions(snapshot.content, file, index, target).find(item => item.id === options.mention);
  if (!mention || !mention.candidates.some(candidate => candidate.id === target)) throw new Error("Mention or target changed. Refresh connections before linking.");
  // Duplicate IDs cannot safely identify a destination, even after an explicit choice.
  const occurrences = files.flatMap(source => collectRoamNodesForIndex(fs.readFileSync(source, "utf8"), source, true)).filter(node => node.id === target);
  if (occurrences.length !== 1) throw new Error("Target ID is duplicated; resolve the duplicate before linking.");
  const lines = snapshot.content.split(/(?<=\n)/);
  const oldLine = lines[mention.line - 1]!;
  const replacement = renderRoamLink(mention.text, { style: "id", id: target });
  lines[mention.line - 1] = oldLine.slice(0, mention.start) + replacement + oldLine.slice(mention.end);
  const after = lines.join("");
  if (options.apply) guardedWriteFile(file, after, { expectedRevision: options.revision, preserveMode: true });
  return { $schema: "org2:mention-link:v1", file, applied: !!options.apply, mention, target, replacement, revision: guardedContentRevision(after), preview: after };
}
