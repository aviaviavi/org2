import { listProjectNotes } from "./project.js";
import path from "node:path";
import { listAgentRuns, summarizeAgentRunAttempts } from "./agentRun.js";
import { listWorkflows, workflowSourcePath } from "./agentWorkflow.js";
import { listGoals, goalPath, listAgentProfiles, agentProfilePath } from "./coordination.js";

export function workspaceRunList(root: string, status?: string) {
  const runs = listAgentRuns(root).filter((run) => !status || run.status === status);
  return { schema: "org2:run-list:v1", runs, logicalWork: summarizeAgentRunAttempts(runs) };
}

export function workspaceWorkflowList(root: string) {
  const workflows = listWorkflows(root).map((workflow) => {
    const file = workflowSourcePath(root, workflow.id);
    return { ...workflow, file, legacyLocation: file.includes(`${path.sep}.org2${path.sep}workflows${path.sep}`) };
  });
  return { schema: "org2:workflow-list:v1", workflows };
}

export function workspaceGoalList(root: string, status?: string) {
  const goals = listGoals(root).filter((goal) => !status || goal.status === status)
    .map((goal) => ({ ...goal, file: goalPath(root, goal.id) }));
  return { schema: "org2:goal-list:v1", goals };
}

export function workspaceProfileList(root: string, status?: string) {
  const profiles = listAgentProfiles(root).filter((profile) => !status || profile.status === status)
    .map((profile) => ({ ...profile, file: agentProfilePath(root, profile.id) }));
  return { schema: "org2:agent-profile-list:v1", profiles };
}

// Each section retains its ordinary list envelope. One unreadable section must
// not discard successful reads of the other independent workspace projections.
function section<T>(read: () => T) {
  const started = performance.now();
  try {
    return { value: read(), elapsedMilliseconds: performance.now() - started };
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error), elapsedMilliseconds: performance.now() - started };
  }
}

export function workspaceAgentState(root: string) {
  return {
    schema: "org2:workspace-agent-state:v1",
    runs: section(() => workspaceRunList(root)),
    workflows: section(() => workspaceWorkflowList(root)),
    goals: section(() => workspaceGoalList(root)),
    profiles: section(() => workspaceProfileList(root)),
    projects: section(() => listProjectNotes(root)),
  };
}
