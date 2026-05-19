import fs from "node:fs";

export type AiJobManifestValidationIssue = {
  path: string;
  message: string;
};

export type AiJobManifestValidationResult = {
  valid: boolean;
  issues: AiJobManifestValidationIssue[];
};

const SCHEMA_VERSION = "org2-ai-job/v1";

const TASK_TYPES = new Set([
  "summarize",
  "summarize-meeting",
  "extract-entities",
  "suggest-links",
  "generate-todos",
  "classify",
  "digest",
  "answer",
]);

const OUTPUT_TARGETS = new Set(["stdout", "compiled", "views", "draft-note", "patch-file"]);
const REVIEW_POLICIES = new Set(["require-approval", "auto-write-draft", "stdout-only"]);
const SECRET_KEY_PARTS = ["apikey", "api_key", "token", "secret", "password", "credential", "authorization"];
const SECRET_VALUE_PATTERN = /(sk-[a-z0-9_-]{12,}|gh[pousr]_[a-z0-9_]{12,}|xox[baprs]-[a-z0-9-]{12,}|api[_-]?key=|access[_-]?token=|secret=|password=)/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function addIssue(issues: AiJobManifestValidationIssue[], path: string, message: string): void {
  issues.push({ path, message });
}

function requireString(
  value: unknown,
  path: string,
  issues: AiJobManifestValidationIssue[],
  options: { nonEmpty?: boolean; pattern?: RegExp; patternMessage?: string } = {},
): value is string {
  if (typeof value !== "string") {
    addIssue(issues, path, "must be a string");
    return false;
  }

  if (options.nonEmpty && value.trim() === "") {
    addIssue(issues, path, "must not be empty");
    return false;
  }

  if (options.pattern && !options.pattern.test(value)) {
    addIssue(issues, path, options.patternMessage || "has an invalid format");
    return false;
  }

  return true;
}

function requireBoolean(value: unknown, path: string, issues: AiJobManifestValidationIssue[]): value is boolean {
  if (typeof value !== "boolean") {
    addIssue(issues, path, "must be a boolean");
    return false;
  }

  return true;
}

function validateStringArray(value: unknown, path: string, issues: AiJobManifestValidationIssue[]): boolean {
  if (!Array.isArray(value)) {
    addIssue(issues, path, "must be an array of strings");
    return false;
  }

  if (value.length === 0) {
    addIssue(issues, path, "must include at least one entry when present");
    return false;
  }

  let ok = true;
  value.forEach((item, index) => {
    ok = requireString(item, `${path}[${index}]`, issues, { nonEmpty: true }) && ok;
  });
  return ok;
}

function validateDateString(value: unknown, path: string, issues: AiJobManifestValidationIssue[]): value is string {
  if (!requireString(value, path, issues, { nonEmpty: true, pattern: /^\d{4}-\d{2}-\d{2}$/, patternMessage: "must be YYYY-MM-DD" })) {
    return false;
  }

  const date = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== value) {
    addIssue(issues, path, "must be a valid calendar date");
    return false;
  }

  return true;
}

function scanForSecrets(value: unknown, path: string, issues: AiJobManifestValidationIssue[]): void {
  if (Array.isArray(value)) {
    value.forEach((item, index) => scanForSecrets(item, `${path}[${index}]`, issues));
    return;
  }

  if (!isRecord(value)) {
    if (typeof value === "string" && SECRET_VALUE_PATTERN.test(value)) {
      addIssue(issues, path, "must not contain inline provider secrets or secret-bearing URLs");
    }
    return;
  }

  for (const [key, child] of Object.entries(value)) {
    const normalizedKey = key.toLowerCase().replace(/[^a-z0-9_]/g, "");
    const childPath = path === "$" ? `$.${key}` : `${path}.${key}`;
    if (SECRET_KEY_PARTS.some((part) => normalizedKey.includes(part))) {
      addIssue(issues, childPath, "must not contain provider secrets; reference a configured adapter by symbolic name instead");
    }
    scanForSecrets(child, childPath, issues);
  }
}

export function validateAiJobManifest(value: unknown): AiJobManifestValidationResult {
  const issues: AiJobManifestValidationIssue[] = [];

  if (!isRecord(value)) {
    return { valid: false, issues: [{ path: "$", message: "manifest must be a JSON object" }] };
  }

  scanForSecrets(value, "$", issues);

  if (value.schemaVersion !== SCHEMA_VERSION) {
    addIssue(issues, "$.schemaVersion", `must be ${JSON.stringify(SCHEMA_VERSION)}`);
  }

  requireString(value.id, "$.id", issues, {
    nonEmpty: true,
    pattern: /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/,
    patternMessage: "must start with an alphanumeric character and contain only letters, numbers, dots, underscores, or dashes",
  });

  if ("description" in value && value.description !== undefined) {
    requireString(value.description, "$.description", issues, { nonEmpty: true });
  }

  const input = value.input;
  if (!isRecord(input)) {
    addIssue(issues, "$.input", "must be an object describing corpus selection");
  } else {
    const selectorKeys = ["files", "headings", "tags", "dateRange", "rawZones", "query"];
    if (!selectorKeys.some((key) => key in input)) {
      addIssue(issues, "$.input", "must include at least one selector: files, headings, tags, dateRange, rawZones, or query");
    }

    if ("files" in input) validateStringArray(input.files, "$.input.files", issues);
    if ("headings" in input) validateStringArray(input.headings, "$.input.headings", issues);
    if ("tags" in input) validateStringArray(input.tags, "$.input.tags", issues);
    if ("rawZones" in input) validateStringArray(input.rawZones, "$.input.rawZones", issues);
    if ("query" in input) requireString(input.query, "$.input.query", issues, { nonEmpty: true });
    if ("recursive" in input) requireBoolean(input.recursive, "$.input.recursive", issues);

    if ("dateRange" in input) {
      if (!isRecord(input.dateRange)) {
        addIssue(issues, "$.input.dateRange", "must be an object with optional from/to dates");
      } else {
        const fromOk = "from" in input.dateRange ? validateDateString(input.dateRange.from, "$.input.dateRange.from", issues) : true;
        const toOk = "to" in input.dateRange ? validateDateString(input.dateRange.to, "$.input.dateRange.to", issues) : true;
        if (!("from" in input.dateRange) && !("to" in input.dateRange)) {
          addIssue(issues, "$.input.dateRange", "must include from and/or to");
        }
        if (fromOk && toOk && typeof input.dateRange.from === "string" && typeof input.dateRange.to === "string" && input.dateRange.from > input.dateRange.to) {
          addIssue(issues, "$.input.dateRange", "from must be before or equal to to");
        }
      }
    }
  }

  const task = value.task;
  if (!isRecord(task)) {
    addIssue(issues, "$.task", "must be an object");
  } else {
    if (requireString(task.type, "$.task.type", issues, { nonEmpty: true }) && !TASK_TYPES.has(task.type)) {
      addIssue(issues, "$.task.type", `must be one of: ${Array.from(TASK_TYPES).join(", ")}`);
    }
    if ("template" in task) requireString(task.template, "$.task.template", issues, { nonEmpty: true });
    if ("instructions" in task) requireString(task.instructions, "$.task.instructions", issues, { nonEmpty: true });
    if (!("template" in task) && !("instructions" in task)) {
      addIssue(issues, "$.task", "must include template or instructions");
    }
  }

  const adapter = value.adapter;
  if (!isRecord(adapter)) {
    addIssue(issues, "$.adapter", "must be an object with a symbolic name");
  } else {
    requireString(adapter.name, "$.adapter.name", issues, {
      nonEmpty: true,
      pattern: /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/,
      patternMessage: "must be a symbolic adapter name, not a URL or secret",
    });
    if ("model" in adapter) requireString(adapter.model, "$.adapter.model", issues, { nonEmpty: true });
  }

  const output = value.output;
  if (!isRecord(output)) {
    addIssue(issues, "$.output", "must be an object");
  } else {
    if (requireString(output.target, "$.output.target", issues, { nonEmpty: true }) && !OUTPUT_TARGETS.has(output.target)) {
      addIssue(issues, "$.output.target", `must be one of: ${Array.from(OUTPUT_TARGETS).join(", ")}`);
    }
    if (output.target !== "stdout") {
      requireString(output.path, "$.output.path", issues, { nonEmpty: true });
    }
    if (typeof output.path === "string") {
      if (output.path.startsWith("/") || /^[A-Za-z]:[\\/]/.test(output.path)) {
        addIssue(issues, "$.output.path", "must be a relative path inside the workspace");
      }
      if (output.path.includes("..")) {
        addIssue(issues, "$.output.path", "must not contain '..' path traversal segments");
      }
    }
  }

  const provenance = value.provenance;
  if (!isRecord(provenance)) {
    addIssue(issues, "$.provenance", "must be an object describing audit requirements");
  } else {
    requireBoolean(provenance.requireSourceRefs, "$.provenance.requireSourceRefs", issues);
    requireBoolean(provenance.recordModelMetadata, "$.provenance.recordModelMetadata", issues);
    requireBoolean(provenance.recordGeneratedAt, "$.provenance.recordGeneratedAt", issues);
    requireString(provenance.promptTemplateVersion, "$.provenance.promptTemplateVersion", issues, { nonEmpty: true });
  }

  const review = value.review;
  if (!isRecord(review)) {
    addIssue(issues, "$.review", "must be an object");
  } else {
    if (requireString(review.policy, "$.review.policy", issues, { nonEmpty: true }) && !REVIEW_POLICIES.has(review.policy)) {
      addIssue(issues, "$.review.policy", `must be one of: ${Array.from(REVIEW_POLICIES).join(", ")}`);
    }
  }

  if (isRecord(output) && output.target === "draft-note" && isRecord(review) && review.policy !== "require-approval") {
    addIssue(issues, "$.review.policy", "draft-note outputs must require approval before promotion to canonical notes");
  }

  return { valid: issues.length === 0, issues };
}

export function loadAiJobManifest(path: string): unknown {
  const raw = fs.readFileSync(path, "utf8");
  try {
    return JSON.parse(raw);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    throw new Error(`Invalid JSON in ${path}: ${message}`);
  }
}
