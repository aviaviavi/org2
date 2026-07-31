import fs from "node:fs";
import path from "node:path";
import type { HeadlineNode, InlineNode, Node } from "./ast.js";
import {
  AGENT_RUN_APPROVAL_BLOCK_REASON,
  agentRunSourceConsistency,
  agentRunApprovalDecisionKeys,
  agentRunDirectory,
  parseAgentRunOrg,
  type AgentRun,
  type AgentRunApproval,
} from "./agentRun.js";
import {
  legacyWorkflowDirectory,
  parseWorkflowOrg,
  workflowDirectory,
  type AgentWorkflow,
} from "./agentWorkflow.js";
import { parseOrgToCanonicalAst } from "./parser.js";

export const ORG2_AGENTIC_DOCTOR_SCHEMA = "org2:agentic-doctor:v1" as const;

export type AgenticDoctorSeverity = "error" | "warning" | "info";
export type AgenticDoctorCategory = "run" | "approval" | "workflow" | "projection" | "source";

export interface AgenticDoctorFinding {
  rule: string;
  severity: AgenticDoctorSeverity;
  category: AgenticDoctorCategory;
  message: string;
  suggestion: string;
  runId?: string;
  approvalId?: string;
  workflowId?: string;
  file?: string;
  line?: number;
  key?: string;
  related?: Record<string, unknown>;
}

export interface AgenticDoctorReport {
  $schema: typeof ORG2_AGENTIC_DOCTOR_SCHEMA;
  root: string;
  readOnly: true;
  ok: boolean;
  summary: {
    runFiles: number;
    validRuns: number;
    workflowFiles: number;
    validWorkflows: number;
    corpusFiles: number;
    linkedHeadlines: number;
    findingCount: number;
    errorCount: number;
    warningCount: number;
    infoCount: number;
  };
  findings: AgenticDoctorFinding[];
}

interface HeadlineRecord {
  title: string;
  todo?: string;
  level: number;
  properties: Record<string, string>;
  file: string;
  line: number;
  parent?: HeadlineRecord;
}

interface LoadedRuns {
  fileCount: number;
  runs: AgentRun[];
  rawById: Map<string, { file: string; raw: string }>;
}

interface LoadedWorkflows {
  fileCount: number;
  workflows: AgentWorkflow[];
}

const TERMINAL_RUN_STATUSES = new Set(["completed", "failed", "canceled"]);
const TERMINAL_TODOS = new Set(["DONE", "CANCELED", "CANCELLED"]);
const PENDING_HEADLINE_STATUS_PARTS = [
  "review-required",
  "requires-review",
  "approval-required",
  "needs-approval",
  "need-approval",
  "needs-review",
  "need-review",
  "pending-review",
  "pending-approval",
  "waiting-on-approval",
  "draft-needs-review",
  "draft-needs-approval",
  "reply-review",
  "needs-avi",
  "avi-approval",
  "needs-human",
  "human-review",
] as const;

function finding(
  findings: AgenticDoctorFinding[],
  value: AgenticDoctorFinding,
): void {
  findings.push(value);
}

function loadRuns(root: string, findings: AgenticDoctorFinding[]): LoadedRuns {
  const dir = agentRunDirectory(root);
  const entries = fs.existsSync(dir) ? fs.readdirSync(dir).sort() : [];
  const names = entries.filter((name) => /\.org2$/i.test(name));
  for (const name of entries.filter((entry) => /\.org2\.lock$/i.test(entry))) {
    const file = path.join(dir, name);
    let owner: Record<string, unknown> = {};
    try { owner = JSON.parse(fs.readFileSync(file, "utf8")) as Record<string, unknown>; } catch {}
    const created = typeof owner.createdAt === "string" ? new Date(owner.createdAt).getTime() : Number.NaN;
    const stale = !Number.isFinite(created) || Date.now() - created > 5 * 60_000;
    finding(findings, {
      rule: "run-write-lock-present",
      severity: stale ? "warning" : "info",
      category: "run",
      message: `${stale ? "Stale or unreadable" : "Active"} guarded-write lock is present for a run file.`,
      suggestion: stale
        ? "Confirm no writer is active, then remove the abandoned lock before retrying the lifecycle mutation."
        : "Retry after the current writer completes; do not bypass the revision check.",
      file,
      related: owner,
    });
  }
  const runs: AgentRun[] = [];
  const rawById = new Map<string, { file: string; raw: string }>();
  for (const name of names) {
    const file = path.join(dir, name);
    try {
      const raw = fs.readFileSync(file, "utf8");
      const run = parseAgentRunOrg(raw);
      runs.push(run);
      rawById.set(run.id, { file, raw });
    } catch (error) {
      finding(findings, {
        rule: "invalid-run-record",
        severity: "error",
        category: "run",
        message: `Run record ${name} could not be parsed or validated: ${error instanceof Error ? error.message : String(error)}`,
        suggestion: "Repair the canonical machine-state block before attempting any lifecycle mutation.",
        file,
      });
    }
  }
  return { fileCount: names.length, runs, rawById };
}

function loadWorkflows(root: string, findings: AgenticDoctorFinding[]): LoadedWorkflows {
  const entries: Array<{ file: string; visible: boolean }> = [];
  for (const [dir, visible] of [
    [legacyWorkflowDirectory(root), false],
    [workflowDirectory(root), true],
  ] as const) {
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir).filter((item) => /\.org2$/i.test(item)).sort()) {
      entries.push({ file: path.join(dir, name), visible });
    }
  }

  const byId = new Map<string, { workflow: AgentWorkflow; file: string; visible: boolean }>();
  for (const entry of entries) {
    try {
      const workflow = parseWorkflowOrg(fs.readFileSync(entry.file, "utf8"));
      const existing = byId.get(workflow.id);
      if (existing) {
        finding(findings, {
          rule: "duplicate-workflow-definition",
          severity: "warning",
          category: "workflow",
          message: `Workflow ${workflow.id} exists in more than one authored location.`,
          suggestion: "Keep the visible workflows/ definition and migrate or remove the legacy duplicate after comparing them.",
          workflowId: workflow.id,
          file: entry.file,
          related: { otherFile: existing.file },
        });
      }
      if (!existing || entry.visible) byId.set(workflow.id, { workflow, file: entry.file, visible: entry.visible });
    } catch (error) {
      finding(findings, {
        rule: "invalid-workflow-record",
        severity: "error",
        category: "workflow",
        message: `Workflow record could not be parsed or validated: ${error instanceof Error ? error.message : String(error)}`,
        suggestion: "Repair the workflow source before scheduling or instantiating it.",
        file: entry.file,
      });
    }
  }
  return { fileCount: entries.length, workflows: [...byId.values()].map((entry) => entry.workflow) };
}

function inlineText(node: InlineNode): string {
  switch (node.type) {
    case "Text": return node.value;
    case "Timestamp": return node.raw;
    case "TimestampRange": return `${node.start.raw}${node.separatorRaw}${node.end.raw}`;
    case "Emphasis": return `${node.marker}${node.content}${node.marker}`;
    case "Link": return node.descriptionRaw ?? node.targetRaw;
    case "ProgressCookie": return node.raw;
  }
}

function headlineTitle(headline: HeadlineNode): string {
  return headline.title.map(inlineText).join("").replace(/^\s*\[#[A-Za-z0-9]\]\s*/, "").trim();
}

function headlineProperties(headline: HeadlineNode): Record<string, string> {
  const drawer = headline.children.find((child) => child.type === "PropertyDrawer");
  if (!drawer || drawer.type !== "PropertyDrawer") return {};
  return Object.fromEntries(drawer.properties.map((property) => [property.key.toUpperCase(), property.value.trim()]));
}

function collectHeadlines(
  nodes: Node[],
  file: string,
  output: HeadlineRecord[],
  parent?: HeadlineRecord,
): void {
  for (const node of nodes) {
    if (node.type !== "Headline") continue;
    const record: HeadlineRecord = {
      title: headlineTitle(node),
      ...(node.todo ? { todo: node.todo.toUpperCase() } : {}),
      level: node.level,
      properties: headlineProperties(node),
      file,
      line: (node as HeadlineNode & { sourceRange?: { startLine: number } }).sourceRange?.startLine || 1,
      ...(parent ? { parent } : {}),
    };
    output.push(record);
    collectHeadlines(node.children, file, output, record);
  }
}

function walkCorpusFiles(root: string, output: string[] = []): string[] {
  if (!fs.existsSync(root)) return output;
  const ignoredDirectories = new Set([".git", ".org2", ".stversions", "node_modules", "dist", "site"]);
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    if (entry.isDirectory() && ignoredDirectories.has(entry.name)) continue;
    const absolute = path.join(root, entry.name);
    if (entry.isDirectory()) walkCorpusFiles(absolute, output);
    else if (entry.isFile() && /\.(?:org2?|ORG2?)$/.test(entry.name) && !entry.name.includes(".sync-conflict-")) output.push(absolute);
  }
  return output;
}

function loadCorpusHeadlines(root: string, findings: AgenticDoctorFinding[]): { files: string[]; headlines: HeadlineRecord[] } {
  const files = walkCorpusFiles(root).sort();
  const headlines: HeadlineRecord[] = [];
  for (const file of files) {
    try {
      const raw = fs.readFileSync(file, "utf8");
      collectHeadlines(parseOrgToCanonicalAst(raw, { sourceRanges: true }).children, file, headlines);
    } catch (error) {
      finding(findings, {
        rule: "unreadable-corpus-source",
        severity: "warning",
        category: "source",
        message: `Corpus source could not be inspected for linked work state: ${error instanceof Error ? error.message : String(error)}`,
        suggestion: "Run the parser or lint command on this file and repair its syntax before relying on projected work state.",
        file,
      });
    }
  }
  return { files, headlines };
}

function isTerminalTodo(todo?: string): boolean {
  return Boolean(todo && TERMINAL_TODOS.has(todo));
}

function headlineStatus(headline: HeadlineRecord): string {
  return String(
    headline.properties.ORG2_REVIEW_STATUS
      || headline.properties.REVIEW_STATUS
      || headline.properties.STATUS
      || headline.properties.FOLLOWUP_STATUS
      || headline.properties.REPLY_STATUS
      || "",
  ).trim().toLowerCase();
}

function isPendingHeadline(headline: HeadlineRecord): boolean {
  if (isTerminalTodo(headline.todo)) return false;
  const status = headlineStatus(headline);
  return PENDING_HEADLINE_STATUS_PARTS.some((part) => status.includes(part));
}

function isApprovedHeadline(headline: HeadlineRecord): boolean {
  const status = headlineStatus(headline);
  return (headline.todo === "DONE" && status === "approved")
    || ["approved", "approved-to-send", "ready-for-agent"].includes(status);
}

function linkedApprovalId(headline: HeadlineRecord): string | undefined {
  return headline.properties.ORG2_APPROVAL_ID || headline.properties.APPROVAL_ID || undefined;
}

function isLikelyProviderApproval(approval: AgentRunApproval): boolean {
  if (!new Set(["external-action", "high-impact"]).has(approval.riskClass)) return false;
  return /\b(?:draft|email|mail|message|outreach|reply|send)\b/i.test(
    `${approval.title}\n${approval.action}\n${approval.note || ""}`,
  );
}

function openClawCronSeries(run: AgentRun): string | null {
  for (const comment of run.comments) {
    if (!/^OPENCLAW_KIND:\s*cron\s*$/im.test(comment.body)) continue;
    const key = /^OPENCLAW_KEY:\s*cron:([^:\s]+):/im.exec(comment.body)?.[1];
    return key ? `openclaw:cron:${key}` : "openclaw:cron:unknown";
  }
  return null;
}

function auditRuns(
  runs: AgentRun[],
  rawById: LoadedRuns["rawById"],
  workflows: AgentWorkflow[],
  findings: AgenticDoctorFinding[],
): void {
  const workflowIds = new Set(workflows.map((workflow) => workflow.id));
  const approvalKeys = new Map<string, Array<{ run: AgentRun; approval: AgentRunApproval }>>();
  const attemptsByNumber = new Map<string, AgentRun[]>();
  const activeAttemptsByLogicalWork = new Map<string, AgentRun[]>();
  const cronSeries = new Map<string, AgentRun[]>();

  for (const run of runs) {
    const pending = run.approvals.filter((approval) => approval.status === "pending");
    const terminal = TERMINAL_RUN_STATUSES.has(run.status);
    if (terminal && pending.length > 0) {
      finding(findings, {
        rule: "terminal-run-pending-approval",
        severity: "error",
        category: "approval",
        message: `Terminal ${run.status} run retains ${pending.length} pending approval${pending.length === 1 ? "" : "s"}.`,
        suggestion: "Settle the pending approvals as non-actionable historical decisions when the run enters a terminal state.",
        runId: run.id,
        file: rawById.get(run.id)?.file,
        related: { pendingApprovalIds: pending.map((approval) => approval.id) },
      });
    }
    if (run.status === "waiting-approval" && pending.length === 0) {
      finding(findings, {
        rule: "waiting-run-without-pending-approval",
        severity: "error",
        category: "run",
        message: "Run is waiting for approval but has no pending approval.",
        suggestion: "Resume, block with a concrete clarification, or terminate the run after reviewing its decision history.",
        runId: run.id,
        file: rawById.get(run.id)?.file,
      });
    }
    if (!terminal && pending.length > 0 && run.status !== "waiting-approval") {
      finding(findings, {
        rule: "pending-approval-outside-waiting-state",
        severity: run.status === "blocked" ? "info" : "warning",
        category: "approval",
        message: `Run has ${pending.length} pending approval${pending.length === 1 ? "" : "s"} while its status is ${run.status}.`,
        suggestion: run.status === "blocked"
          ? "Confirm that the separate clarification blocker is intentional and remains visible alongside the approval."
          : "Move the run to waiting-approval or settle the stale pending decision.",
        runId: run.id,
        file: rawById.get(run.id)?.file,
      });
    }
    if (run.status === "blocked" && run.blockedReason === AGENT_RUN_APPROVAL_BLOCK_REASON && pending.length > 0) {
      finding(findings, {
        rule: "approval-block-retains-pending-decision",
        severity: "warning",
        category: "approval",
        message: "Run is blocked because approvals were not approved but still retains a pending decision.",
        suggestion: "Settle the entire current approval boundary before representing its outcome as an approval block.",
        runId: run.id,
        file: rawById.get(run.id)?.file,
      });
    }
    if (run.workflowId && !workflowIds.has(run.workflowId)) {
      finding(findings, {
        rule: "run-workflow-missing",
        severity: "warning",
        category: "workflow",
        message: `Run references workflow ${run.workflowId}, but no readable workflow definition exists.`,
        suggestion: "Restore the workflow definition or retain an explicit immutable workflow snapshot with the run.",
        runId: run.id,
        workflowId: run.workflowId,
        file: rawById.get(run.id)?.file,
      });
    }

    const raw = rawById.get(run.id)?.raw || "";
    const sourceIssues = agentRunSourceConsistency(raw, run);
    if (sourceIssues.length > 0) {
      finding(findings, {
        rule: "run-readable-state-diverged",
        severity: "warning",
        category: "source",
        message: "The readable run header no longer agrees with its canonical machine-state block.",
        suggestion: "Inspect the direct edit, then normalize the file from the accepted canonical state before another client writes it.",
        runId: run.id,
        file: rawById.get(run.id)?.file,
        related: { fields: sourceIssues },
      });
    }

    for (const approval of pending) {
      const keys = agentRunApprovalDecisionKeys(approval);
      for (const key of keys) approvalKeys.set(key, [...(approvalKeys.get(key) || []), { run, approval }]);
      if (keys.length === 0 && isLikelyProviderApproval(approval)) {
        finding(findings, {
          rule: "provider-approval-missing-decision-key",
          severity: "warning",
          category: "approval",
          message: "Likely provider-backed approval has no deterministic provider decision key.",
          suggestion: "Include the exact `Provider draft: PROVIDER:TOOL:DRAFT_ID` line in immutable review material.",
          runId: run.id,
          approvalId: approval.id,
          file: rawById.get(run.id)?.file,
        });
      }
    }

    if (run.attempt && run.logicalWorkId) {
      const attemptNumberKey = `${run.logicalWorkId}#${run.attempt.number}`;
      attemptsByNumber.set(attemptNumberKey, [...(attemptsByNumber.get(attemptNumberKey) || []), run]);
      if (!terminal) activeAttemptsByLogicalWork.set(run.logicalWorkId, [...(activeAttemptsByLogicalWork.get(run.logicalWorkId) || []), run]);
    }
    const cronKey = openClawCronSeries(run);
    if (cronKey && !run.workflowId && !run.logicalWorkId && !run.attempt) {
      cronSeries.set(cronKey, [...(cronSeries.get(cronKey) || []), run]);
    }
  }

  for (const [key, references] of approvalKeys) {
    if (references.length < 2) continue;
    finding(findings, {
      rule: "duplicate-pending-decision-key",
      severity: "error",
      category: "approval",
      message: `${references.length} pending approvals claim the same provider decision key.`,
      suggestion: "Choose the newest canonical material and supersede the older pending projections.",
      key,
      related: { approvals: references.map(({ run, approval }) => ({ runId: run.id, approvalId: approval.id, requestedAt: approval.requestedAt })) },
    });
  }
  for (const [key, attempts] of attemptsByNumber) {
    if (attempts.length < 2) continue;
    finding(findings, {
      rule: "duplicate-workflow-attempt-number",
      severity: "error",
      category: "workflow",
      message: `${attempts.length} runs share the same logical-work attempt number.`,
      suggestion: "Give every scheduled execution a unique attempt identity and monotonically increasing number.",
      key,
      related: { runIds: attempts.map((run) => run.id) },
    });
  }
  for (const [logicalWorkId, attempts] of activeAttemptsByLogicalWork) {
    if (attempts.length < 2) continue;
    finding(findings, {
      rule: "overlapping-active-attempts",
      severity: "warning",
      category: "workflow",
      message: `${attempts.length} attempts for one logical work item are simultaneously nonterminal.`,
      suggestion: "Confirm overlap is intentional; recurring reconciliation workflows should normally coalesce or lease one active attempt.",
      key: logicalWorkId,
      related: { runIds: attempts.map((run) => run.id), statuses: attempts.map((run) => run.status) },
    });
  }
  for (const [key, series] of cronSeries) {
    if (series.length < 2) continue;
    finding(findings, {
      rule: "unmanaged-openclaw-cron-series",
      severity: "warning",
      category: "workflow",
      message: `${series.length} OpenClaw cron run${series.length === 1 ? "" : "s"} are not grouped under a workflow, logical-work ID, or numbered attempt.`,
      suggestion: "Convert the recurring job into an authored workflow and preserve this cron identity as its stable logical-work key.",
      key,
      related: {
        runIds: series.slice(-20).map((run) => run.id),
        totalRuns: series.length,
        statuses: Object.fromEntries([...new Set(series.map((run) => run.status))].map((status) => [status, series.filter((run) => run.status === status).length])),
      },
    });
  }
}

function auditHeadlineProjections(
  headlines: HeadlineRecord[],
  runs: AgentRun[],
  findings: AgenticDoctorFinding[],
): number {
  const runsById = new Map(runs.map((run) => [run.id, run]));
  const linked = headlines.filter((headline) => headline.properties.ORG2_RUN_ID);
  const openTitles = new Map<string, HeadlineRecord[]>();
  const openGmailDrafts = new Map<string, HeadlineRecord[]>();

  for (const headline of headlines) {
    if (headline.todo && !isTerminalTodo(headline.todo)) {
      const titleKey = `${headline.file}\n${headline.title.toLowerCase().replace(/\s+/g, " ")}`;
      openTitles.set(titleKey, [...(openTitles.get(titleKey) || []), headline]);
    }
    const draftId = headline.properties.GMAIL_DRAFT_ID;
    if (draftId && !isTerminalTodo(headline.todo)) openGmailDrafts.set(draftId, [...(openGmailDrafts.get(draftId) || []), headline]);

    const runId = headline.properties.ORG2_RUN_ID;
    if (!runId) continue;
    const run = runsById.get(runId);
    if (!run) {
      finding(findings, {
        rule: "headline-run-reference-missing",
        severity: "warning",
        category: "projection",
        message: `Headline references missing run ${runId}.`,
        suggestion: "Restore the run or remove the stale projection link after confirming its history.",
        runId,
        file: headline.file,
        line: headline.line,
      });
      continue;
    }

    const approvalId = linkedApprovalId(headline);
    const approval = approvalId ? run.approvals.find((candidate) => candidate.id === approvalId) : undefined;
    if (approvalId && !approval) {
      finding(findings, {
        rule: "headline-approval-reference-missing",
        severity: "warning",
        category: "projection",
        message: `Headline references approval ${approvalId}, which is not present on run ${run.id}.`,
        suggestion: "Relink the heading to the canonical approval or remove the obsolete approval reference.",
        runId: run.id,
        approvalId,
        file: headline.file,
        line: headline.line,
      });
    }

    const pendingApprovals = run.approvals.filter((candidate) => candidate.status === "pending");
    if (isPendingHeadline(headline)) {
      const duplicatesRunDecision = approval?.status === "pending" || (!approvalId && pendingApprovals.length === 1);
      if (duplicatesRunDecision) {
        const canonical = approval || pendingApprovals[0]!;
        finding(findings, {
          rule: "duplicate-headline-run-approval-projection",
          severity: "warning",
          category: "projection",
          message: "Pending headline duplicates a canonical pending run approval.",
          suggestion: "Keep the run approval as the writable decision and render the heading only as a derived projection.",
          runId: run.id,
          approvalId: canonical.id,
          file: headline.file,
          line: headline.line,
        });
      }
      if (approval && approval.status !== "pending") {
        finding(findings, {
          rule: "pending-headline-decided-approval",
          severity: "warning",
          category: "projection",
          message: `Headline remains pending after its linked approval was ${approval.status}.`,
          suggestion: "Refresh or settle the stale headline projection from the canonical decision.",
          runId: run.id,
          approvalId: approval.id,
          file: headline.file,
          line: headline.line,
        });
      }
      if (TERMINAL_RUN_STATUSES.has(run.status)) {
        finding(findings, {
          rule: "pending-headline-terminal-run",
          severity: "error",
          category: "projection",
          message: `Headline remains pending although its linked run is ${run.status}.`,
          suggestion: "Settle the headline projection or explicitly create new work instead of reopening terminal history implicitly.",
          runId: run.id,
          file: headline.file,
          line: headline.line,
        });
      }
    }
    if (isApprovedHeadline(headline) && approval?.status === "pending") {
      finding(findings, {
        rule: "approved-headline-pending-approval",
        severity: "error",
        category: "projection",
        message: "Headline records approval while the linked canonical approval is still pending.",
        suggestion: "Reconcile the human decision into the run before any protected action continues.",
        runId: run.id,
        approvalId: approval.id,
        file: headline.file,
        line: headline.line,
      });
    }
  }

  for (const headline of headlines) {
    const parent = headline.parent;
    if (!parent) continue;
    const approvalChild = /^(?:approve|review)\b/i.test(headline.title);
    const actionParent = /^(?:send approved|continue approved)\b/i.test(parent.title);
    if (!approvalChild || !actionParent) continue;
    if (isApprovedHeadline(headline) && isPendingHeadline(parent)) {
      finding(findings, {
        rule: "approved-child-parent-still-waiting",
        severity: "error",
        category: "projection",
        message: "Nested approval is complete, but its parent agent action is still waiting for approval.",
        suggestion: "Advance the parent to approved-to-send or ready-for-agent while leaving it open until execution completes.",
        file: parent.file,
        line: parent.line,
        related: { childLine: headline.line, childTitle: headline.title },
      });
    }
    if (isTerminalTodo(parent.todo) && isPendingHeadline(headline)) {
      finding(findings, {
        rule: "terminal-parent-pending-child",
        severity: "error",
        category: "projection",
        message: "Terminal parent action still contains a pending nested review or approval.",
        suggestion: "Reopen the parent action or settle the child boundary; do not leave an actionable child under terminal work.",
        file: parent.file,
        line: parent.line,
        related: { childLine: headline.line, childTitle: headline.title },
      });
    }
  }

  for (const group of openTitles.values()) {
    if (group.length < 2) continue;
    finding(findings, {
      rule: "duplicate-open-headline-title",
      severity: "warning",
      category: "projection",
      message: `${group.length} open headings in one file have the same normalized title.`,
      suggestion: "Confirm they are distinct work; otherwise retain one canonical heading and link any projections to it.",
      file: group[0]!.file,
      line: group[0]!.line,
      key: group[0]!.title,
      related: { lines: group.map((headline) => headline.line) },
    });
  }
  for (const [draftId, group] of openGmailDrafts) {
    if (group.length < 2) continue;
    finding(findings, {
      rule: "duplicate-open-provider-draft",
      severity: "error",
      category: "projection",
      message: `${group.length} open headings claim the same Gmail draft ID.`,
      suggestion: "Choose one canonical action and convert the other headings into read-only references or settled history.",
      file: group[0]!.file,
      line: group[0]!.line,
      key: `gmail:gog:${draftId}`,
      related: { headings: group.map((headline) => ({ file: headline.file, line: headline.line, title: headline.title })) },
    });
  }
  return linked.length;
}

function compareFindings(lhs: AgenticDoctorFinding, rhs: AgenticDoctorFinding): number {
  const severityOrder = { error: 0, warning: 1, info: 2 } as const;
  return severityOrder[lhs.severity] - severityOrder[rhs.severity]
    || lhs.rule.localeCompare(rhs.rule)
    || String(lhs.file || "").localeCompare(String(rhs.file || ""))
    || (lhs.line || 0) - (rhs.line || 0)
    || String(lhs.runId || "").localeCompare(String(rhs.runId || ""));
}

export function auditAgenticWorkspace(corpusRoot: string): AgenticDoctorReport {
  const root = path.resolve(corpusRoot);
  const findings: AgenticDoctorFinding[] = [];
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    findings.push({
      rule: "corpus-root-unreadable",
      severity: "error",
      category: "source",
      message: "Corpus root does not exist or is not a directory.",
      suggestion: "Pass the intended corpus directory with --dir before relying on this audit.",
      file: root,
    });
    return {
      $schema: ORG2_AGENTIC_DOCTOR_SCHEMA,
      root,
      readOnly: true,
      ok: false,
      summary: {
        runFiles: 0,
        validRuns: 0,
        workflowFiles: 0,
        validWorkflows: 0,
        corpusFiles: 0,
        linkedHeadlines: 0,
        findingCount: 1,
        errorCount: 1,
        warningCount: 0,
        infoCount: 0,
      },
      findings,
    };
  }
  const loadedRuns = loadRuns(root, findings);
  const loadedWorkflows = loadWorkflows(root, findings);
  auditRuns(loadedRuns.runs, loadedRuns.rawById, loadedWorkflows.workflows, findings);
  const corpus = loadCorpusHeadlines(root, findings);
  const linkedHeadlines = auditHeadlineProjections(corpus.headlines, loadedRuns.runs, findings);
  findings.sort(compareFindings);
  const errorCount = findings.filter((item) => item.severity === "error").length;
  const warningCount = findings.filter((item) => item.severity === "warning").length;
  const infoCount = findings.filter((item) => item.severity === "info").length;
  return {
    $schema: ORG2_AGENTIC_DOCTOR_SCHEMA,
    root,
    readOnly: true,
    ok: errorCount === 0,
    summary: {
      runFiles: loadedRuns.fileCount,
      validRuns: loadedRuns.runs.length,
      workflowFiles: loadedWorkflows.fileCount,
      validWorkflows: loadedWorkflows.workflows.length,
      corpusFiles: corpus.files.length,
      linkedHeadlines,
      findingCount: findings.length,
      errorCount,
      warningCount,
      infoCount,
    },
    findings,
  };
}

export function renderAgenticDoctorReport(report: AgenticDoctorReport): string {
  const lines = [
    "Org2 agentic workspace doctor",
    `Root: ${report.root}`,
    `Scanned ${report.summary.validRuns}/${report.summary.runFiles} runs, ${report.summary.validWorkflows}/${report.summary.workflowFiles} workflows, and ${report.summary.corpusFiles} corpus files (${report.summary.linkedHeadlines} linked headings).`,
    `Findings: ${report.summary.errorCount} error(s), ${report.summary.warningCount} warning(s), ${report.summary.infoCount} info.`,
  ];
  if (report.findings.length === 0) return `${lines.join("\n")}\nNo agentic workspace inconsistencies found.`;
  for (const item of report.findings) {
    const location = item.file ? ` ${item.file}${item.line ? `:${item.line}` : ""}` : item.runId ? ` run:${item.runId}` : item.key ? ` ${item.key}` : "";
    lines.push("", `${item.severity.toUpperCase()} ${item.rule}${location}`, item.message, `Suggestion: ${item.suggestion}`);
  }
  return lines.join("\n");
}
