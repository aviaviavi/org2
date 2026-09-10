import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { performance } from 'node:perf_hooks';
import { PASTE_LABELS as labels, PASTE_FEATURE_COUNT as dimensions, PASTE_FEATURE_VERSION,
  pasteLineFeatures, classifyPasteLines, heuristicPasteLabel, validatePasteModel } from '../../dist/pasteStructureClassifier.js';
import { trainingFixtures, validationFixtures, heldOutFixtures } from './fixtures.mjs';
const root = fileURLToPath(new URL('../..', import.meta.url));
const output = path.join(root, 'tools/paste-as-org2');
const sha = value => createHash('sha256').update(value).digest('hex');
const training = trainingFixtures();
const all = [...training, ...validationFixtures, ...heldOutFixtures];
if (new Set(all.map(doc => doc.id)).size !== all.length) throw new Error('Duplicate document IDs');
const families = [training, validationFixtures, heldOutFixtures].map(docs => new Set(docs.map(doc => doc.family)));
if (families.some((set, i) => families.some((other, j) => i !== j && [...set].some(family => other.has(family))))) throw new Error('Family leakage');
const dataset = JSON.stringify({ license: 'Apache-2.0; original synthetic fixtures', documents: all }, null, 2) + '\n';
fs.writeFileSync(path.join(root, 'test/fixtures/paste-as-org2/documents.json'), dataset);
let state = 20260909;
const random = () => { state ^= state << 13; state ^= state >>> 17; state ^= state << 5; return (state >>> 0) / 4294967296; };
const examples = training.flatMap(doc => {
  const texts = doc.lines.map(line => line.text);
  return doc.lines.flatMap((line, index) => line.text.trim() ? [{ features: pasteLineFeatures(texts, index), target: labels.indexOf(line.label) }] : []);
});
const weights = new Float64Array(labels.length * dimensions);
const start = performance.now();
const epochs = 100;
let finalLoss = 0;
for (let epoch = 0; epoch < epochs; epoch++) {
  const shuffled = [...examples];
  for (let i = shuffled.length - 1; i > 0; i--) { const j = Math.floor(random() * (i + 1)); [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]]; }
  let loss = 0;
  const rate = 0.12 / (1 + epoch / 25);
  for (const { features, target } of shuffled) {
    const logits = labels.map((_, label) => features.reduce((sum, [index, value]) => sum + weights[label * dimensions + index] * value, 0));
    const max = Math.max(...logits);
    const exp = logits.map(value => Math.exp(value - max));
    const sum = exp.reduce((a, b) => a + b, 0);
    loss -= Math.log(Math.max(1e-12, exp[target] / sum));
    for (let label = 0; label < labels.length; label++) {
      const gradient = exp[label] / sum - Number(label === target);
      for (const [index, value] of features) {
        const offset = label * dimensions + index;
        weights[offset] -= rate * (gradient * value + 0.00002 * weights[offset]);
      }
    }
  }
  finalLoss = loss / examples.length;
}
const trainingMs = performance.now() - start;
const model = { schema: 'org2:paste-classifier-experiment:v1', featureVersion: PASTE_FEATURE_VERSION,
  labels, weights: [...weights].map(value => Number(value.toFixed(7))), threshold: 0.95 };
validatePasteModel(model);
const predicted = docs => docs.flatMap(doc => {
  const predictions = classifyPasteLines(doc.lines.map(line => line.text), model);
  return doc.lines.flatMap((line, i) => line.text.trim() ? [{ ...line, ...predictions[i], gold: line.label, id: doc.id, domain: doc.domain }] : []);
});
const valid = predicted(validationFixtures);
function selective(rows, threshold) {
  const accepted = rows.filter(row => row.confidence >= threshold);
  const structure = accepted.filter(row => row.label !== 'paragraph');
  return { threshold, accepted: accepted.length, total: rows.length, coverage: accepted.length / rows.length,
    accuracy: accepted.length ? accepted.filter(row => row.label === row.gold).length / accepted.length : null,
    structuralAccepted: structure.length,
    structuralPrecision: structure.length ? structure.filter(row => row.label === row.gold).length / structure.length : null };
}
const candidates = [0.6, 0.7, 0.8, 0.9, 0.95, 0.98, 0.995].map(value => selective(valid, value));
model.threshold = candidates.find(row => row.structuralAccepted >= 10 && row.structuralPrecision >= 0.95)?.threshold ?? 0.995;
const modelText = JSON.stringify(model) + '\n';
fs.writeFileSync(path.join(output, 'model.json'), modelText);
const rows = predicted(heldOutFixtures);
function metrics(rows, predict) {
  const matrix = labels.map(() => labels.map(() => 0));
  for (const row of rows) matrix[labels.indexOf(row.gold)][labels.indexOf(predict(row))]++;
  const perLabel = Object.fromEntries(labels.map((label, index) => {
    const tp = matrix[index][index];
    const support = matrix[index].reduce((a, b) => a + b, 0);
    const predicted = matrix.reduce((sum, row) => sum + row[index], 0);
    const precision = predicted ? tp / predicted : 0;
    const recall = support ? tp / support : 0;
    return [label, { support, precision, recall, f1: precision + recall ? 2 * precision * recall / (precision + recall) : 0 }];
  }));
  return { accuracy: matrix.reduce((sum, row, i) => sum + row[i], 0) / rows.length,
    macroF1: Object.values(perLabel).reduce((sum, value) => sum + value.f1, 0) / labels.length,
    perLabel, confusion: { order: labels, rowsGoldColumnsPredicted: matrix } };
}
function timing(fn, count = 500) {
  for (let i = 0; i < 25; i++) fn();
  const samples = [];
  for (let i = 0; i < count; i++) { const start = performance.now(); fn(); samples.push(performance.now() - start); }
  samples.sort((a, b) => a - b);
  return { iterations: count, p50Ms: samples[Math.floor(count * .5)], p95Ms: samples[Math.floor(count * .95)] };
}
const texts = heldOutFixtures.flatMap(doc => doc.lines.map(line => line.text));
const report = {
  schema: 'org2:paste-classifier-evaluation:v1', measuredAt: new Date().toISOString(),
  implementation: 'Multinomial logistic regression (six-way softmax), trained sparse SGD on fixed hashed token/context + numeric shape features; CPU JavaScript. No LLM, GPU or cloud service.',
  seed: 20260909, epochs, trainingExamples: examples.length, trainingMs, finalTrainingCrossEntropy: finalLoss,
  fixtures: Object.fromEntries([['train', training], ['validation', validationFixtures], ['test', heldOutFixtures]].map(([split, docs]) =>
    [split, { documents: docs.length, nonemptyLines: docs.reduce((sum, doc) => sum + doc.lines.filter(line => line.text.trim()).length, 0), families: [...new Set(docs.map(doc => doc.family))] }])),
  datasetSha256: sha(dataset), modelSha256: sha(modelText),
  size: { parameters: weights.length, featureCount: dimensions, classes: labels.length,
    float32WeightsBytes: weights.length * 4, modelJsonBytes: Buffer.byteLength(modelText), modelGzipBytes: gzipSync(modelText).length,
    runtimeJsBytes: fs.statSync(path.join(root, 'dist/pasteStructureClassifier.js')).size },
  thresholdSelection: { target: 'At least 95% structural precision on validation with >=10 accepted structural lines; lowest passing threshold, else 0.995. Not a production quality gate.', candidates, selected: model.threshold },
  heldOut: { rawModel: metrics(rows, row => row.label), heuristic: metrics(rows, row => heuristicPasteLabel(row.text)),
    selectiveModel: selective(rows, model.threshold), fallbackAsParagraph: metrics(rows, row => row.confidence >= model.threshold ? row.label : 'paragraph'),
    byDomain: Object.fromEntries(['recipe', 'email', 'webpage'].map(domain => [domain, {
      model: metrics(rows.filter(row => row.domain === domain), row => row.label),
      heuristic: metrics(rows.filter(row => row.domain === domain), row => heuristicPasteLabel(row.text)),
    }])), errors: rows.filter(row => row.label !== row.gold),
  },
  latency: { environment: { node: process.version, platform: process.platform, arch: process.arch, cpu: os.cpus()[0]?.model },
    batch: { lines: texts.length, characters: texts.join('\n').length },
    model: timing(() => classifyPasteLines(texts, model)), heuristic: timing(() => texts.map(heuristicPasteLabel)),
    modelJsonParseAndValidate: timing(() => validatePasteModel(JSON.parse(modelText))),
    scope: 'Warm in-process CPU wall time including feature extraction and model validation; excludes browser startup, rendering, clipboard and file I/O.' },
  limitations: ['Small synthetic English-dominant test set; labels authored by the implementer, not independently annotated.',
    'Train templates repeat with changed values; test layouts and families are disjoint, but the domain remains synthetic.',
    'Some plain text is semantically ambiguous without its DOM or author intent. Softmax scores are uncalibrated.',
    'No claimed equivalence to gpu-lexer parameter budget, GPU throughput, or real clipboard accuracy.',
    'Classifier remains opt-in experimental. Default baseline plus literal fallback and user editing is required.'],
};
fs.writeFileSync(path.join(output, 'evaluation.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({ trainingMs, size: report.size, test: report.fixtures.test, model: report.heldOut.rawModel.accuracy,
  macroF1: report.heldOut.rawModel.macroF1, baseline: report.heldOut.heuristic.accuracy,
  baselineMacroF1: report.heldOut.heuristic.macroF1, selective: report.heldOut.selectiveModel, latency: report.latency }, null, 2));
