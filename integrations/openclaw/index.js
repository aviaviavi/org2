import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { cronKey, cronSessionKey, durableRunMarker, executionSummary, Org2Lifecycle, shouldTrackMainTurn, workflowMarker } from "./lib/lifecycle.js";
import { approvalAction, approvalContext, approvalTitle, draftCreatedEffect, draftSendEffect, hydrateGogDraftEffect } from "./lib/draft-approvals.js";
import { registerOrg2WorkspaceNodePolicy } from "./lib/local-edit-node.js";

function runtimeAgentId(event = {}, ctx = {}) {
  const direct = ctx.agentId || ctx.agentID || event.agentId || event.agentID || event.runtimeAgentId || event.job?.agentId || event.job?.agentID;
  if (String(direct || "").trim()) return String(direct).trim();
  const sessionKey = String(ctx.sessionKey || event.sessionKey || event.childSessionKey || "");
  return /^agent:([^:]+):/i.exec(sessionKey)?.[1];
}

function selectedCoordination(prompt) {
  const text = String(prompt || "");
  return {
    selectedAgentRef: text.match(/^ORG2_SELECTED_AGENT_REF:[ \t]*(\S+)[ \t]*$/mi)?.[1],
    selectedGoalRef: text.match(/^ORG2_SELECTED_GOAL_REF:[ \t]*(\S+)[ \t]*$/mi)?.[1],
  };
}

export default definePluginEntry({
  id: "org2-lifecycle",
  name: "Org2 Lifecycle",
  description: "Synchronizes substantial OpenClaw executions into Org2 Run Center.",
  register(api) {
    const config = api.pluginConfig || {};
    const lifecycle = new Org2Lifecycle({ ...config, log: api.logger });
    const trackMainTurns = config.trackMainTurns !== false;
    const trackCron = config.trackCron !== false;
    const trackSubagents = config.trackSubagents !== false;
    const trackDraftApprovals = config.trackDraftApprovals !== false;

    registerOrg2WorkspaceNodePolicy(api);

    api.on("gateway_start", async (_event, ctx) => {
      lifecycle.setCron(ctx.getCron?.());
      await lifecycle.init();
      await lifecycle.reconcile();
    });

    api.registerGatewayMethod("org2.workflow.prepareRun", async ({ params, respond }) => {
      try {
        const workflowId = String(params?.workflowId || "").trim();
        if (!workflowId) return respond(false, undefined, { code: "INVALID_REQUEST", message: "workflowId is required" });
        const inputs = params?.inputs && typeof params.inputs === "object" ? params.inputs : {};
        const expectedCorpusId = String(params?.corpusId || "").trim() || undefined;
        respond(true, await lifecycle.serialize(() => lifecycle.prepareWorkflowRun(workflowId, inputs, { expectedCorpusId })));
      } catch (error) {
        respond(false, undefined, { code: "ORG2_WORKFLOW_ERROR", message: error.message });
      }
    }, { scope: "operator.write" });

    api.registerGatewayMethod("org2.workflow.sync", async ({ params, respond }) => {
      try { respond(true, await lifecycle.serialize(() => lifecycle.reconcile(String(params?.corpusId || "").trim() || undefined))); }
      catch (error) { respond(false, undefined, { code: "ORG2_WORKFLOW_ERROR", message: error.message }); }
    }, { scope: "operator.write" });

    api.registerGatewayMethod("org2.workflow.status", async ({ params, respond }) => {
      try { respond(true, await lifecycle.workflowStatus(String(params?.corpusId || "").trim() || undefined)); }
      catch (error) { respond(false, undefined, { code: "ORG2_WORKFLOW_ERROR", message: error.message }); }
    }, { scope: "operator.read" });

    api.registerGatewayMethod("org2.workflow.resume", async ({ params, respond }) => {
      try {
        const runId = String(params?.runId || "").trim();
        if (!runId) return respond(false, undefined, { code: "INVALID_REQUEST", message: "runId is required" });
        const expectedCorpusId = String(params?.corpusId || "").trim() || undefined;
        respond(true, await lifecycle.serialize(() => lifecycle.resumeWorkflowRun(runId, { expectedCorpusId })));
      } catch (error) {
        respond(false, undefined, { code: "ORG2_WORKFLOW_ERROR", message: error.message });
      }
    }, { scope: "operator.write" });

    api.registerGatewayMethod("org2.draft.resume", async ({ params, respond }) => {
      try {
        const runId = String(params?.runId || "").trim();
        if (!runId) return respond(false, undefined, { code: "INVALID_REQUEST", message: "runId is required" });
        const expectedCorpusId = String(params?.corpusId || "").trim() || undefined;
        respond(true, await lifecycle.serialize(() => lifecycle.resumeDraftRun(runId, { expectedCorpusId })));
      } catch (error) {
        respond(false, undefined, { code: "ORG2_DRAFT_ERROR", message: error.message });
      }
    }, { scope: "operator.write" });

    api.registerGatewayMethod("org2.run.resumeApproved", async ({ params, respond }) => {
      try {
        const runId = String(params?.runId || "").trim();
        if (!runId) return respond(false, undefined, { code: "INVALID_REQUEST", message: "runId is required" });
        const expectedCorpusId = String(params?.corpusId || "").trim() || undefined;
        respond(true, await lifecycle.serialize(() => lifecycle.resumeApprovedRun(runId, { expectedCorpusId })));
      } catch (error) {
        respond(false, undefined, { code: "ORG2_RUN_ERROR", message: error.message });
      }
    }, { scope: "operator.write" });

    api.registerGatewayMethod("org2.run.replyAndResume", async ({ params, respond }) => {
      try {
        const runId = String(params?.runId || "").trim();
        const response = String(params?.response || "").trim();
        if (!runId) return respond(false, undefined, { code: "INVALID_REQUEST", message: "runId is required" });
        if (!response) return respond(false, undefined, { code: "INVALID_REQUEST", message: "response is required" });
        const expectedCorpusId = String(params?.corpusId || "").trim() || undefined;
        respond(true, await lifecycle.serialize(() => lifecycle.replyAndResumeRun(runId, response, { expectedCorpusId })));
      } catch (error) {
        respond(false, undefined, { code: "ORG2_RUN_ERROR", message: error.message });
      }
    }, { scope: "operator.write" });

    api.registerGatewayMethod("org2.workflow.resumeRevision", async ({ params, respond }) => {
      try {
        const runId = String(params?.runId || "").trim();
        const approvalId = String(params?.approvalId || "").trim();
        if (!runId) return respond(false, undefined, { code: "INVALID_REQUEST", message: "runId is required" });
        if (!approvalId) return respond(false, undefined, { code: "INVALID_REQUEST", message: "approvalId is required" });
        const expectedCorpusId = String(params?.corpusId || "").trim() || undefined;
        respond(true, await lifecycle.serialize(() => lifecycle.resumeWorkflowRevision(runId, approvalId, { expectedCorpusId })));
      } catch (error) {
        respond(false, undefined, { code: "ORG2_WORKFLOW_ERROR", message: error.message });
      }
    }, { scope: "operator.write" });

    api.on("before_agent_run", async (event, ctx) => {
      if (!trackMainTurns || !shouldTrackMainTurn(event.prompt, ctx)) return;
      const key = `turn:${ctx.sessionKey || ctx.sessionId || "unknown"}:${ctx.runId || "unknown"}`;
      const selected = selectedCoordination(event.prompt);
      const marker = workflowMarker(event.prompt);
      if (marker?.workflowRunId) {
        await lifecycle.serialize(() => lifecycle.attach(key, marker.workflowRunId, {
          kind: "workflow",
          workflowId: marker.workflowId,
          sessionKey: ctx.sessionKey,
          openclawRunId: ctx.runId,
          provider: ctx.modelProviderId,
          model: ctx.modelId,
          runtimeAgentId: runtimeAgentId(event, ctx),
          runAlreadyStarted: marker.workflowRunStarted,
          ...selected,
        }));
        return;
      }
      const durableRunId = durableRunMarker(event.prompt);
      if (durableRunId) {
        await lifecycle.serialize(() => lifecycle.attach(key, durableRunId, {
          kind: "durable-run",
          sessionKey: ctx.sessionKey,
          openclawRunId: ctx.runId,
          provider: ctx.modelProviderId,
          model: ctx.modelId,
          runtimeAgentId: runtimeAgentId(event, ctx),
          ...selected,
        }));
        return;
      }
      await lifecycle.serialize(() => lifecycle.ensure(key, {
        kind: "agent-turn",
        goal: event.prompt,
        sessionKey: ctx.sessionKey,
        openclawRunId: ctx.runId,
        provider: ctx.modelProviderId,
        model: ctx.modelId,
        runtimeAgentId: runtimeAgentId(event, ctx),
        ...selected,
      }));
    });

    api.on("llm_output", async (event, ctx) => {
      await lifecycle.serialize(() => lifecycle.recordUsage(event.runId || ctx.runId, event.usage));
    });

    api.on("before_tool_call", async (event, ctx) => {
      if (!trackDraftApprovals) return;
      const effect = draftSendEffect(event.toolName, event.params);
      if (!effect) return;
      const readable = await hydrateGogDraftEffect(effect);
      const decision = await lifecycle.serialize(() => lifecycle.draftSendDecision({
        ...readable,
        action: approvalAction(readable),
      }));
      if (decision.allowed) return;
      return { block: true, blockReason: `${decision.reason} Approve the matching item in Org2, then retry the send.` };
    });

    api.on("after_tool_call", async (event, ctx) => {
      if (!trackDraftApprovals) return;
      const sent = draftSendEffect(event.toolName, event.params);
      if (sent && !event.error) {
        await lifecycle.serialize(() => lifecycle.recordDraftSent(sent));
        return;
      }
      const created = draftCreatedEffect(event.toolName, event.params, event.result, event.error);
      if (!created) return;
      const readable = await hydrateGogDraftEffect(created);
      await lifecycle.serialize(() => lifecycle.requestDraftApproval({
        ...readable,
        context: approvalContext(readable),
        title: approvalTitle(readable),
        action: approvalAction(readable),
      }, {
        openclawRunId: event.runId || ctx.runId,
        sessionKey: ctx.sessionKey,
      }));
    });

    api.on("agent_end", async (event, ctx) => {
      const key = `turn:${ctx.sessionKey || ctx.sessionId || "unknown"}:${event.runId || ctx.runId || "unknown"}`;
      await lifecycle.serialize(() => lifecycle.finish(key, event.success ? "ok" : "error", {
        error: event.error,
        summary: executionSummary(event.messages),
        durationMs: event.durationMs,
        provider: ctx.modelProviderId,
        model: ctx.modelId,
      }));
    });

    api.on("subagent_spawned", async (event) => {
      if (!trackSubagents) return;
      await lifecycle.serialize(() => lifecycle.ensure(`subagent:${event.childSessionKey}`, {
        kind: event.mode === "session" ? "subagent-session" : "subagent",
        goal: event.label || `Subagent ${event.childSessionKey}`,
        sessionKey: event.childSessionKey,
        openclawRunId: event.runId,
        provider: event.resolvedProvider,
        model: event.resolvedModel,
        runtimeAgentId: runtimeAgentId(event),
      }));
    });

    api.on("subagent_ended", async (event) => {
      if (!trackSubagents) return;
      await lifecycle.serialize(() => lifecycle.finish(`subagent:${event.targetSessionKey}`, event.outcome || "ok", {
        error: event.error,
        summary: event.reason ? `OpenClaw subagent finished: ${event.reason}` : "OpenClaw subagent completed successfully.",
      }));
    });

    api.on("session_end", async (event, ctx) => {
      const sessionKey = event.sessionKey || ctx.sessionKey;
      await lifecycle.serialize(() => lifecycle.interruptSession(sessionKey, event.reason || "unknown", {
        durationMs: event.durationMs,
      }));
    });

    api.on("cron_changed", async (event) => {
      if (!trackCron) return;
      const key = cronKey(event);
      const agentId = runtimeAgentId(event);
      const sessionKey = cronSessionKey(event, agentId);
      if (event.action === "started") {
        const marker = workflowMarker(event.job?.payload?.text);
        if (marker) {
          await lifecycle.serialize(() => lifecycle.ensureWorkflow(key, marker.workflowId, marker.inputs, {
            triggerId: marker.triggerId || "schedule",
            attemptId: key.replace(/[^A-Za-z0-9._-]+/g, "-"),
            scheduledFor: Number.isFinite(event.runAtMs) ? new Date(event.runAtMs).toISOString() : undefined,
            logicalWorkId: `workflow:${marker.workflowId}`,
            sessionKey,
            openclawRunId: event.runId,
            provider: event.provider,
            model: event.model,
            runtimeAgentId: agentId,
          }));
          return;
        }
        await lifecycle.serialize(() => lifecycle.ensure(key, {
          kind: "cron",
          goal: event.job?.name || `Cron ${event.jobId}`,
          sessionKey,
          openclawRunId: event.runId,
          provider: event.provider,
          model: event.model,
          runtimeAgentId: agentId,
        }));
      }
      if (event.action === "finished") {
        await lifecycle.serialize(() => lifecycle.finish(key, event.status === "ok" || event.status === "skipped" ? "ok" : "error", {
          error: event.error,
          summary: event.summary || (event.status === "skipped" ? "OpenClaw skipped the scheduled execution." : "OpenClaw scheduled execution completed successfully."),
          durationMs: event.durationMs,
          provider: event.provider,
          model: event.model,
          sessionKey,
          openclawRunId: event.runId,
          runtimeAgentId: agentId,
        }));
      }
    });
  },
});
