/** Experimental, entirely local, learned line classifier. No text generation. */
export const PASTE_LABELS = ["heading", "list", "paragraph", "quote", "code", "table"] as const;
export type PasteLabel = typeof PASTE_LABELS[number];
export const PASTE_FEATURE_VERSION = "hashed-line-context-v1";
export const PASTE_FEATURE_COUNT = 416;
export interface PasteStructureModel {
  schema: "org2:paste-classifier-experiment:v1";
  featureVersion: string;
  labels: readonly PasteLabel[];
  weights: number[];
  threshold: number;
}
export interface StructurePrediction { label: PasteLabel; confidence: number }

function hash(text: string): number {
  let value = 2166136261;
  for (let i = 0; i < text.length; i++) value = Math.imul(value ^ text.charCodeAt(i), 16777619);
  return value >>> 0;
}

/** Fixed feature map shared by training and inference; it never reads gold labels. */
export function pasteLineFeatures(lines: readonly string[], index: number): Array<[number, number]> {
  const raw = lines[index] ?? "";
  const line = raw.trim();
  const previous = lines[index - 1]?.trim() ?? "";
  const next = lines[index + 1]?.trim() ?? "";
  const features = new Map<number, number>();
  const add = (key: number, value: number) => { if (value) features.set(key, (features.get(key) ?? 0) + value); };
  const tokens = (value: string, prefix: string, scale: number) => {
    for (const token of value.toLowerCase().match(/[\p{L}]+|\d+|[^\s\p{L}\d]/gu)?.slice(0, 80) ?? []) {
      add(hash(prefix + token.replace(/^\d+$/, "#")) % 384, scale);
    }
  };
  tokens(line, "self:", 0.4);
  tokens(previous, "prev:", 0.15);
  tokens(next, "next:", 0.15);
  const flags = [
    1, Math.min(line.length / 100, 2), Math.min(line.split(/\s+/).length / 20, 2),
    Number(index === 0), Number(!previous), Number(!next), Number(/[:.!?]$/.test(line)),
    Number(/:$/.test(line)), Number(/^[-+*•]\s/.test(line)), Number(/^\d+[.)]\s/.test(line)),
    Number(/^>/.test(line)), Number(/^\s{2,}\S/.test(raw)), Number(/\t/.test(raw)),
    Number(/\|/.test(line)), Number(/^[A-Z][A-Z\s\d:]+$/.test(line)),
    Number(/^\d|^[¼½¾⅓⅔⅛]/.test(line)), Number(/[{};=]/.test(line)), Number(/^#{1,6}\s/.test(line)),
    Number(/^```|^~~~/.test(line)), Number(/^[A-Z][a-z]+(?: [A-Z][a-z]+){0,6}$/.test(line)),
    Number(/https?:\/\//.test(line)), Number(/^\w+:\s/.test(line)),
    Math.min((line.match(/\d/g)?.length ?? 0) / 10, 1), Number(/  \S/.test(raw.trim())),
    Number(/^[\w.-]+\([^)]*\)/.test(line)), Number(/^[A-Z]/.test(line)),
    Number(/[.!?]$/.test(previous)), Number(/:$/.test(previous)), Number(/^\d/.test(next)),
    Number(/^>/.test(previous)), Number(/^>/.test(next)), Number(!line),
  ];
  flags.forEach((value, i) => add(384 + i, value));
  return [...features];
}

export function validatePasteModel(value: unknown): PasteStructureModel {
  const model = value as PasteStructureModel;
  if (model?.schema !== "org2:paste-classifier-experiment:v1"
    || model.featureVersion !== PASTE_FEATURE_VERSION
    || JSON.stringify(model.labels) !== JSON.stringify(PASTE_LABELS)
    || !Array.isArray(model.weights) || model.weights.length !== PASTE_FEATURE_COUNT * PASTE_LABELS.length
    || model.weights.some(weight => !Number.isFinite(weight))
    || !Number.isFinite(model.threshold) || model.threshold < 0 || model.threshold > 1) {
    throw new Error("Unsupported or invalid experimental paste classifier");
  }
  return model;
}

export function predictPasteFeatures(features: Array<[number, number]>, model: PasteStructureModel): StructurePrediction {
  const logits = PASTE_LABELS.map((_, label) => features.reduce((sum, [index, value]) =>
    sum + model.weights[label * PASTE_FEATURE_COUNT + index]! * value, 0));
  const max = Math.max(...logits);
  const probabilities = logits.map(logit => Math.exp(logit - max));
  const sum = probabilities.reduce((a, b) => a + b, 0);
  const best = logits.indexOf(max);
  return { label: PASTE_LABELS[best]!, confidence: probabilities[best]! / sum };
}

export function classifyPasteLines(lines: readonly string[], model: PasteStructureModel): StructurePrediction[] {
  validatePasteModel(model);
  return lines.map((_, index) => predictPasteFeatures(pasteLineFeatures(lines, index), model));
}

/** Baseline: obvious markup only; ambiguous prose remains a paragraph. */
export function heuristicPasteLabel(line: string): PasteLabel {
  if (/^\s*>/.test(line)) return "quote";
  if (/^\s*(?:[-+*•]|\d+[.)])\s+/.test(line)) return "list";
  if (/\t|^\s*\|.*\|\s*$/.test(line)) return "table";
  if (/^\s{4}\S|^```|^~~~|[{};]\s*$/.test(line)) return "code";
  if (/^#{1,6}\s|^[A-Z][A-Z \d]+:?$/.test(line) || /^(ingredients|instructions|directions|method|notes):?$/i.test(line.trim())) return "heading";
  return "paragraph";
}
