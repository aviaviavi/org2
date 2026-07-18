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
    ],
    safety: [
      "Treat corpus files as user-owned source code: make small, reviewable text changes.",
      "Mutating commands generally preview unless `--apply` is present; inspect previews before applying.",
      "Keep generated work in reviewable zones such as views/ or compiled/ before promotion into canonical notes/.",
      "Preserve file and line citations, IDs, provenance, source hashes, and review state when deriving artifacts.",
      "Never block a durable run without an actionable clarification; `org2 run block ID --reason TEXT` requires the specific question or next action.",
      "Never complete a durable run without a concise result for the reviewer; `org2 run complete ID --summary TEXT` requires a human-readable outcome and accepts repeatable highlights and next actions.",
      "Run targeted tests plus `org2 lint` around writes when practical; never put secrets in notes or generated artifacts.",
    ],
    workflows: [
      {
        id: "agentic-workspace",
        purpose: "Create, inspect, resume, review, validate, fork, and package durable agent runs and reusable workflows.",
        commands: ["org2 run", "org2 review", "org2 workflow", "org2 eval"],
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
        purpose: "Build agendas and mutate TODO, approval, planning, effort, habit, and clock state.",
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
        purpose: "Export one file or publish a multi-file project as HTML.",
        commands: ["org2 export", "org2 publish"],
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
      { id: "macos-workspace", role: "Native alpha workspace shell with first-run corpus setup, agenda, capture, reading/editing, meetings, data notebooks, workflow/run/review controls, agent handoffs, and discoverable chat slash commands backed by shared compiler semantics." },
      { id: "ios-mobile", role: "Source-distributed mobile corpus and approval client." },
      { id: "openclaw", role: "First native agent-runtime adapter: Gateway chat plus a lifecycle plugin that maps substantial work into durable runs, prepares manual workflow execution, and reconciles active workflow schedules into OpenClaw cron." },
    ],
    docs: [
      { id: "agent-quickstart", url: "https://org2.avi.press/agent-quickstart.html" },
      { id: "features", url: "https://org2.avi.press/features.html" },
      { id: "tooling-reference", url: "https://org2.avi.press/tooling-reference.html" },
      { id: "language-reference", url: "https://org2.avi.press/language-reference.html" },
      { id: "corpus-flow", url: "https://org2.avi.press/corpus-flow.html" },
      { id: "workflows", url: "https://org2.avi.press/workflows.html" },
      { id: "macos-workspace", url: "https://org2.avi.press/editors-macos.html" },
    ],
  };
}
