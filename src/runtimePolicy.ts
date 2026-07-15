import fs from "node:fs";
import path from "node:path";

export const ORG2_RUNTIME_POLICY_SCHEMA = "org2:runtime-policy:v1" as const;

export interface RuntimeDescriptor {
  id: string;
  provider: string;
  model: string;
  transport: "hosted" | "local" | "external";
  capabilities: string[];
  privacy: "local" | "private-cloud" | "cloud";
  contextWindow?: number;
  costClass?: "free" | "low" | "medium" | "high";
  enabled?: boolean;
}

export interface RuntimePolicy {
  schema: typeof ORG2_RUNTIME_POLICY_SCHEMA;
  policies: Record<string, {
    requireCapabilities?: string[];
    allowedPrivacy?: RuntimeDescriptor["privacy"][];
    allowedTransports?: RuntimeDescriptor["transport"][];
    maxCostClass?: RuntimeDescriptor["costClass"];
    minimumContextWindow?: number;
    prefer?: string[];
  }>;
  runtimes: RuntimeDescriptor[];
}

const costRank = { free: 0, low: 1, medium: 2, high: 3 } as const;

export function defaultRuntimePolicy(): RuntimePolicy {
  return {
    schema: ORG2_RUNTIME_POLICY_SCHEMA,
    policies: {
      "private-local": { allowedPrivacy: ["local"], allowedTransports: ["local"], prefer: ["local"] },
      "fast-draft": { maxCostClass: "low" },
      "deep-analysis": { requireCapabilities: ["reasoning"], minimumContextWindow: 100000 },
      vision: { requireCapabilities: ["vision"] },
      "regulated-cloud": { allowedPrivacy: ["private-cloud"] },
      offline: { allowedTransports: ["local"], allowedPrivacy: ["local"] },
    },
    runtimes: [],
  };
}

export function selectRuntime(config: RuntimePolicy, policyName: string, requiredCapabilities: string[] = []): RuntimeDescriptor {
  const policy = config.policies[policyName];
  if (!policy) throw new Error(`unknown runtime policy: ${policyName}`);
  const required = new Set([...(policy.requireCapabilities || []), ...requiredCapabilities]);
  const eligible = config.runtimes.filter((runtime) => {
    if (runtime.enabled === false) return false;
    if ([...required].some((capability) => !runtime.capabilities.includes(capability))) return false;
    if (policy.allowedPrivacy && !policy.allowedPrivacy.includes(runtime.privacy)) return false;
    if (policy.allowedTransports && !policy.allowedTransports.includes(runtime.transport)) return false;
    if (policy.minimumContextWindow && (runtime.contextWindow || 0) < policy.minimumContextWindow) return false;
    if (policy.maxCostClass && costRank[runtime.costClass || "medium"] > costRank[policy.maxCostClass]) return false;
    return true;
  });
  if (!eligible.length) throw new Error(`no eligible runtime for policy ${policyName}`);
  const preferred = policy.prefer || [];
  return eligible.sort((a, b) => {
    const ai = preferred.indexOf(a.id) >= 0 ? preferred.indexOf(a.id) : preferred.indexOf(a.transport);
    const bi = preferred.indexOf(b.id) >= 0 ? preferred.indexOf(b.id) : preferred.indexOf(b.transport);
    const ar = ai < 0 ? Number.MAX_SAFE_INTEGER : ai;
    const br = bi < 0 ? Number.MAX_SAFE_INTEGER : bi;
    return ar - br || costRank[a.costClass || "medium"] - costRank[b.costClass || "medium"] || a.id.localeCompare(b.id);
  })[0]!;
}

export function validateRuntimePaths(config: RuntimePolicy, requiredCapabilities: string[] = []): { valid: boolean; local?: RuntimeDescriptor; hosted?: RuntimeDescriptor; issues: string[] } {
  const eligible = config.runtimes.filter((runtime) => runtime.enabled !== false && requiredCapabilities.every((capability) => runtime.capabilities.includes(capability)));
  const local = eligible.find((runtime) => runtime.transport === "local" && runtime.privacy === "local");
  const hosted = eligible.find((runtime) => runtime.transport === "hosted" && (runtime.privacy === "private-cloud" || runtime.privacy === "cloud"));
  const issues = [
    ...(!local ? [`no enabled local/private runtime provides: ${requiredCapabilities.join(", ") || "the requested baseline"}`] : []),
    ...(!hosted ? [`no enabled hosted runtime provides: ${requiredCapabilities.join(", ") || "the requested baseline"}`] : []),
  ];
  return { valid: issues.length === 0, ...(local ? { local } : {}), ...(hosted ? { hosted } : {}), issues };
}

export function runtimePolicyPath(root: string): string { return path.join(path.resolve(root), ".org2", "runtime-policy.json"); }
export function loadRuntimePolicy(root: string): RuntimePolicy {
  const file = runtimePolicyPath(root);
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) as RuntimePolicy : defaultRuntimePolicy();
}
export function saveRuntimePolicy(root: string, policy: RuntimePolicy): string {
  const file = runtimePolicyPath(root);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(policy, null, 2)}\n`, "utf8");
  return file;
}
