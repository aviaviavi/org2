# Paste as Org2 — local experiment

An additive development prototype, pending human review. It preserves source
text while suggesting document structure. It is **not ready for automatic
insertion** and is available in the native Source editor behind Experimental features.

The native bridge uses the same TypeScript in an ephemeral, network-denied
WebKit view created only on invocation. Regenerate its checked-in resource with
`npm run build:paste-native`; `node tools/paste-as-org2/build-native.mjs --check`
verifies it. No converter, model, or WebKit view is loaded by ordinary paste.

## Try it

From this worktree, with the locked dependencies installed (`npm ci`):

```sh
npm run prototype:paste -- 8126
```

Open the printed `http://127.0.0.1:8126` URL. Paste into **Source**, place the
cursor in the scratch document, then choose **Preview structure**. Edit the
Org preview and choose **Insert reviewed Org**, or cancel. Download the Org
document for opening in OpenOrg; download the JSON review packet to retain the
original plain text, original HTML, source URL, labels, source offsets, proposed
Org and your edited Org. Editing the source invalidates its previous preview and
HTML association. Changing the destination after preview blocks insertion.

The default is a simple heuristic baseline. The trained classifier is an
explicit checkbox. Semantic clipboard HTML takes precedence over both. There
is no LLM API, credential, model download, cloud inference, or telemetry. Only
static assets and the checked-in model are fetched from the loopback server;
clipboard processing is in browser memory. Downloads are explicit. Closing the
tab discards this application's in-memory state. Stop the server with Ctrl-C.

## Integration and boundaries

- `src/pasteAsOrg2.ts`: shared TypeScript source slicing, Org serialization and
  preview/edit/insert state. No second Org parser; tests use the existing compiler.
- `src/pasteClipboardHtml.ts`: inert browser DOM extraction. Selected HTML
  fragments, headings, paragraphs, lists, quotations, code and simple tables use
  markup directly. Anchor targets are retained separately in source order.
- `src/pasteStructureClassifier.ts`: shared training/inference feature map and
  learned six-way softmax classifier. It produces labels and scores only.
- `tools/paste-as-org2/`: small local preview harness, original synthetic fixture
  authoring, deterministic training, exported weights and measured evaluation.

Existing surfaces inspected: `OrgSyntaxTextEditor.swift` pastes plain text;
`WorkspaceStore.captureDraftByImportingPasteboard` appends plain clipboard text
and attachments; `org2 capture` accepts reviewed text/files/stdin. This prototype
uses reviewed Org export as the integration boundary. The focused test feeds its
output into the real preview-first capture command and verifies that no file is
written. For a deliberate capture preview, for example:

```sh
node dist/cli.js capture --file /path/to/reviewed-document.org \
  --to /path/to/scratch-inbox.org --title 'Reviewed paste' --format json
```

No native app is rebuilt, launched, or replaced. A native Paste as Org2 action
would need a separate UI review and plumbing to this shared preview contract.
This developer harness does not add a public CLI capability or change shipped
app behavior; public discovery/docs/generated site are therefore unchanged.

## Preservation contract

The review packet retains the exact original plain-text string (including CRLF
from a paste event) and HTML string. Plain-text blocks contain contiguous UTF-16
source offsets and one-based line numbers. Slices reconstruct the source exactly.
Serialization adds Org structure around the words; it never predicts replacement
words, quantities, temperatures, times, recipe facts or missing metadata. Org
output normalizes line endings and layout; **the Org output is not a byte-exact
copy of the clipboard**. Keep the review packet for exact reconstruction.

Low-confidence model lines, code, ambiguous plain-text tables and problematic
Org delimiters become literal fixed-width Org (`: `). Code is never emitted as
an executable source block. Existing numbering is kept as item text rather than
renumbering a recipe. Unsafe or unrepresentable link targets remain literal;
relative links are retained verbatim, without guessing a source URL. Simple
HTML tables use Org rows; cells with pipes or newlines fall back to literal text.
Only the preview's explicit insertion action changes the scratch document.

HTML is a lossy presentation format boundary: tags/styles are not preserved in
Org; the raw HTML remains in the packet. Scripts, styles and embedded resources
are omitted from extracted content and never mounted or fetched. CSS visibility,
image pixels, attachment import, rich inline formatting and visual columns are
not interpreted. Nested lists are flattened with a warning while retaining text
order; nested/merged tables stay literal. Browser parsing may repair malformed
HTML. These cases need human comparison with the original; this is not a general
webpage importer. Inputs are capped at 200,000 characters per format.

## Reproduce the classifier experiment

```sh
npm run experiment:paste
npm run test:paste
# Browser coverage: use a locally installed Playwright and Chrome.
# PLAYWRIGHT_MODULE may point to an existing playwright-core/index.mjs.
PLAYWRIGHT_MODULE=/path/to/playwright-core/index.mjs \
  node test/test-paste-as-org2-browser.mjs
npm run docs:check
```

Training is handwritten sparse SGD on multinomial logistic regression:
384 hashed token/context features plus 32 shape/bias features, six output
classes, **2,496 learned parameters**. The feature map is fixed and reads no gold
labels; the weights are learned from 2,520 nonempty lines in 240 synthetic
training documents. Seed 20260909, 100 epochs, learning rate 0.12/(1+epoch/25),
small L2 penalty, weights exported to seven decimal places. No pretrained model,
private corpus or external training data is used. Fixtures are original synthetic
material licensed under this repository's Apache-2.0 license.

Six validation documents (49 nonempty lines) choose the lowest listed score
threshold achieving at least 95% structural precision with ten structural
predictions. The resulting threshold is 0.9. Eighteen separately authored test
layouts (138 nonempty lines, six documents per domain) are held out by document
family, not randomly by line. Blank lines provide context but are not scored.
Training templates repeat with changed values; this is a small, narrow spike,
not an independently annotated benchmark. Test labels are not used for training,
threshold selection or feature tuning. Two runs reproduced identical dataset
and model hashes and every held-out metric.

| Held-out measure | Learned classifier | Heuristic baseline |
| --- | ---: | ---: |
| Line accuracy | 70.29% | 52.90% |
| Macro F1, six classes | 0.6661 | 0.4826 |
| Recipe accuracy, 47 lines | 89.36% | 44.68% |
| Email accuracy, 43 lines | 65.12% | 74.42% |
| Webpage accuracy, 48 lines | 56.25% | 41.67% |

At threshold 0.9, 99/138 lines are accepted (71.74% coverage), with 82.83%
accepted-label accuracy. Of 53 accepted structural labels, 44 are correct
(**83.02% precision**). This misses the validation target on held-out layouts.
Softmax scores are not calibrated probabilities: greetings/signatures become
headings, unmarked quotations are missed, and spaced timetable rows become lists.
The baseline is stronger on emails. The model remains opt-in experimental;
keeping literal text and editing the preview is the explicit fallback.

Measurements on this laptop: Apple M2, Node v25.9.0 **x64** process. The model
JSON is 20,038 bytes (gzip 7,757); hypothetical float32 weights are 9,984 bytes,
while the implemented JSON/JS-number representation has different memory costs.
Classifier runtime JS is 4,318 bytes, separately measured. Training took about
0.76 s. A warm 140-line / 3,136-character batch took median **0.923 ms**, p95
**1.141 ms**, including feature extraction and validation; the baseline took
median 0.0217 ms. JSON parsing plus model validation took median 0.0836 ms.
These are 500 in-process CPU trials after 25 warmups, excluding browser startup,
DOM extraction, rendering and clipboard I/O. They are not GPU or end-to-end UI
benchmarks; timing will vary.

`evaluation.json` contains split counts, hashes, size, timing scope, per-class
precision/recall/F1, confusion matrices, domain results and every held-out error.
`test/fixtures/paste-as-org2/documents.json` is the reproducible expanded fixture
set; edit `fixtures.mjs` and rerun the experiment to regenerate it. `model.json`
is the exact model used by the preview. Any future quality tuning needs a new
untouched evaluation set.

The inspiration, [gpu-lexer](https://gpu-lexer.vercel.app/), uses a 41,321-parameter
syntax-labeling classifier for a different task. This spike measures its own
size and quality; the smaller model here does not establish that reliable paste
structure recovery fits that budget.
