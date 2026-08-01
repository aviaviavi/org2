export interface Org2CapabilityWorkflow {
  id: string;
  purpose: string;
  commands: string[];
  writes: "read-only" | "preview-by-default" | "mixed";
}

export interface Org2CapabilityManifest {
  $schema: "org2:capabilities:v1";
  product: string;
  summary: string;
  sourceOfTruth: string;
  discovery: string[];
  safety: string[];
  workflows: Org2CapabilityWorkflow[];
  clients: Array<{ id: string; role: string }>;
  docs: Array<{ id: string; url: string }>;
}

export function buildOrg2CapabilityManifest(): Org2CapabilityManifest {
  return {
    $schema: "org2:capabilities:v1",
    product: "Org2",
    summary: "A local-first knowledge compiler and runtime for Org-shaped plain-text workspaces.",
    sourceOfTruth: "Ordinary .org2 and .org files remain canonical; compiled indexes, views, reports, and app state are derived.",
    discovery: [
      "Run `org2 agent capabilities` for this machine-readable manifest.",
      "Run `org2 --help` for command families and `org2 COMMAND --help` for current flags.",
      "Prefer JSON output for integrations (`--format json` or `--json` where supported).",
      "Use `org2 agent context|search|fetch|bundle` for bounded, cited corpus retrieval.",
      "Use `org2 run --help` for durable delegated work, `org2 workflow` for reusable recipes, and `org2 mcp serve` for MCP discovery.",
      "Use read-only `org2 doctor --dir CORPUS --json` to find contradictory run, approval, workflow-attempt, and projected headline state before an agent acts.",
      "Use `org2 run show ID --with-revision --json` when a client needs a revision token for a later guarded mutation.",
      "Use `org2 ledger` for stable per-account bookkeeping in recurring workflows; canonical accounts live under `notes/LEDGER/accounts/`.",
      "Use `org2 corpus show|validate|init` to inspect or establish portable corpus identity before team mounting.",
      "Use `org2 source list|doctor|status|bind|import|sync` to manage corpus-declared Slack and Notion crawler profiles and stage review packets without storing credentials in the corpus.",
      "Use `org2 workspace agenda|search` only with explicitly granted `--mount` paths for read-only multi-corpus projections.",
    ],
    safety: [
      "Treat corpus files as user-owned source code: make small, reviewable text changes.",
      "Mutating commands generally preview unless `--apply` is present; inspect previews before applying.",
      "Keep generated work in reviewable zones such as views/ or compiled/ before promotion into canonical notes/.",
      "Preserve file and line citations, IDs, provenance, source hashes, and review state when deriving artifacts.",
      "Never block a durable run without an actionable clarification; `org2 run block ID --reason TEXT` requires the specific question or next action.",
      "Never complete a durable run without a concise result for the reviewer; `org2 run complete ID --summary TEXT` requires a human-readable outcome and accepts repeatable highlights and next actions.",
      "A run with a pending approval cannot be completed normally; record the request, stop before the protected action, and resume only after the approval decision returns the run to running.",
      "Treat `org2 approvals` as the unified pending-decision queue: decide `kind=run` items by their exact runId/approvalId through `org2 run approval-decide`, and mutate `kind=headline` items only at their cited source heading. Provider-backed items expose `decisionKeys`; preserve the exact `Provider draft: PROVIDER:TOOL:DRAFT_ID` line so `approval-request` reuses the current durable decision and `approval-decide` closes older duplicate projections.",
      "Use `org2 run approval-resolve --decision-key KEY --json` when an execution guard needs the canonical pending or decided provider authority. Private adapter state is only a cache and must not override this CLI resolution.",
      "Run approvals carry a SHA-256 fingerprint over immutable review material. Pass the queue item's fingerprint back to `run approval-decide --fingerprint` so stale or substituted actions fail closed across clients.",
      "A `run approval-decide --decision revised` request must include `--note \"Requested changes\"`; revision feedback is stored as the decision note and does not authorize the protected action.",
      "Rejecting or canceling a required run approval cancels its originating run immediately; use `revised` with a concrete note when replacement material should keep the workflow open.",
      "Scheduled workflow runs use a stable logicalWorkId plus distinct numbered attempt records. A schedule with an event/fresh-path gate is skipped until `workflow signal` records matching work after the prior attempt.",
      "A run with a review-required artifact cannot be completed normally; after the human decision, use `org2 run artifact-review RUN_ID ARTIFACT_ID --status reviewed|rejected --actor NAME` to update both the durable run and linked Org artifact before completion.",
      "When a person confirms that an unfinished run's outcome was completed outside the workflow, `org2 run complete-external ID --summary TEXT --actor NAME` records that explicit resolution while preserving unresolved approvals and review metadata as history; agents must not infer this resolution on their own.",
      "Record observable runtime metadata with `org2 run runtime ID` when provider, model, token usage, cost, or elapsed time is available; never put credentials in a run record.",
      "Run targeted tests plus `org2 lint` around writes when practical; never put secrets in notes or generated artifacts.",
      "Never infer agent access from corpora remembered by a person's app; every federated CLI mount must be explicit.",
      "Treat `org2 doctor` as a read-only consistency check. Review its evidence before repairing canonical state; the command never mutates files automatically.",
      "Run and workflow mutations use atomic guarded writes. Pass `--if-revision sha256:...` when carrying run state across requests; a stale revision, concurrent writer, duplicate create, or out-of-band readable-state edit fails instead of silently overwriting newer source.",
      "Keep curated account identity, aliases, commercial context, and idempotent work history in a ledger account under notes/. Keep immutable imports and provider payloads under raw/, and link approvals to their canonical run instead of copying decision state.",
      "Resolve every available stable identity before creating recurring account work. Treat ambiguity or source drift as a blocker rather than guessing.",
    ],
    workflows: [
      {
        id: "corpus-identity-and-mounting",
        purpose: "Inspect, validate, or initialize portable personal, shared, and project corpus identities.",
        commands: ["org2 corpus"],
        writes: "preview-by-default",
      },
      {
        id: "federated-workspace-read",
        purpose: "Combine agenda or search output from explicitly named identified corpora while retaining corpus identity on every result.",
        commands: ["org2 workspace agenda", "org2 workspace search"],
        writes: "read-only",
      },
      {
        id: "agentic-workspace",
        purpose: "Manage settled chat history, create and inspect durable agent runs, and package reusable workflows.",
        commands: ["org2 doctor", "org2 thread", "org2 run", "org2 review", "org2 workflow", "org2 eval"],
        writes: "mixed",
      },
      {
        id: "work-ledger",
        purpose: "Maintain stable per-account identity and idempotent event history for high-volume recurring work without growing one monolithic agent note.",
        commands: ["org2 ledger list", "org2 ledger resolve", "org2 ledger show", "org2 ledger create", "org2 ledger update", "org2 ledger event", "org2 doctor"],
        writes: "preview-by-default",
      },
      {
        id: "external-source-sync",
        purpose: "Inspect and run corpus-declared external source mirrors through machine-local slacrawl/notcrawl bindings, validate optional interval/daily schedule intent, then stage bounded raw and review-required Org2 artifacts.",
        commands: ["org2 source list", "org2 source doctor", "org2 source status", "org2 source bind", "org2 source import", "org2 source sync"],
        writes: "mixed",
      },
      {
        id: "portable-runtime",
        purpose: "Track artifact dependencies, select eligible model runtimes by capability policy, and expose or snapshot MCP integrations.",
        commands: ["org2 artifact", "org2 runtime", "org2 mcp"],
        writes: "mixed",
      },
      {
        id: "planning",
        purpose: "Build agendas, inspect the unified run/headline approval queue, and mutate TODO, planning, effort, habit, and clock state.",
        commands: ["org2 agenda", "org2 todo", "org2 approvals", "org2 plan", "org2 clock", "org2 query clocks"],
        writes: "mixed",
      },
      {
        id: "capture-and-organization",
        purpose: "Capture source material and move reviewable subtrees through archive/refile workflows.",
        commands: ["org2 capture", "org2 archive", "org2 refile"],
        writes: "preview-by-default",
      },
      {
        id: "knowledge-graph",
        purpose: "Create and resolve IDs, backlinks, nodes, links, entities, indexes, searches, and graph reports.",
        commands: ["org2 id", "org2 backlinks", "org2 index", "org2 search", "org2 query", "org2 entity", "org2 roam"],
        writes: "mixed",
      },
      {
        id: "agent-context",
        purpose: "Compile and retrieve bounded agent context with source ranges and citations, or render human briefings.",
        commands: ["org2 agent capabilities", "org2 agent context", "org2 agent search", "org2 agent fetch", "org2 agent bundle", "org2 context", "org2 brief", "org2 compile corpus"],
        writes: "mixed",
      },
      {
        id: "data-and-charts",
        purpose: "Inspect or materialize DuckDB-backed datasets and render deterministic charts from note-local declarations.",
        commands: ["org2 query-data", "org2 render-chart"],
        writes: "mixed",
      },
      {
        id: "ai-review-lifecycle",
        purpose: "Validate AI jobs and create, review, suggest, and promote provenance-stamped generated artifacts.",
        commands: ["org2 ai"],
        writes: "preview-by-default",
      },
      {
        id: "publishing",
        purpose: "Export documents and Beamer-compatible slide decks, compile presentation PDFs, or publish a multi-file HTML project.",
        commands: ["org2 export html", "org2 export beamer", "org2 publish"],
        writes: "preview-by-default",
      },
      {
        id: "maintenance",
        purpose: "Format source and audit corpus metadata, links, provenance, generated artifacts, and graph health.",
        commands: ["org2 fmt", "org2 lint", "org2 graph"],
        writes: "mixed",
      },
      {
        id: "encryption",
        purpose: "Encrypt, decrypt, or re-encrypt scoped :crypt: subtrees with GPG recipients.",
        commands: ["org2 crypt"],
        writes: "preview-by-default",
      },
      {
        id: "editor-intelligence",
        purpose: "Expose shared semantic editor behavior through the language server.",
        commands: ["org2 lsp"],
        writes: "read-only",
      },
    ],
    clients: [
      { id: "cli", role: "Canonical automation and integration surface over the shared TypeScript compiler/runtime." },
      { id: "vscode", role: "Best-supported general editing workflow, backed by shared CLI/LSP semantics." },
      { id: "macos-workspace", role: "Native alpha workspace shell with personal/shared corpus mounts, corpus-qualified federated agenda/search, explicit write-corpus switching, capture, reading/editing, meetings, data notebooks, workflow/run/review controls, agent handoffs, and per-thread OpenClaw or ChatGPT-authenticated local Codex chat backed by shared compiler semantics." },
      { id: "ios-mobile", role: "Source-distributed mobile corpus and approval client; run decisions retain the native run, approval, and fingerprint identity when queued through the mobile inbox." },
      { id: "openclaw", role: "First native agent-runtime adapter: Gateway chat plus a lifecycle plugin that maps substantial work into durable runs, prepares workflow attempts, event-gates scheduled work, and reconciles active workflow schedules into OpenClaw cron." },
    ],
    docs: [
      { id: "agent-quickstart", url: "https://org2.avi.press/agent-quickstart.html" },
      { id: "features", url: "https://org2.avi.press/features.html" },
      { id: "tooling-reference", url: "https://org2.avi.press/tooling-reference.html" },
      { id: "language-reference", url: "https://org2.avi.press/language-reference.html" },
      { id: "corpus-flow", url: "https://org2.avi.press/corpus-flow.html" },
      { id: "collaboration", url: "https://org2.avi.press/collaboration.html" },
      { id: "workflows", url: "https://org2.avi.press/workflows.html" },
      { id: "macos-workspace", url: "https://org2.avi.press/editors-macos.html" },
    ],
  };
}
