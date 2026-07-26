import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { cronKey, executionSummary, Org2Lifecycle, shouldTrackMainTurn, workflowMarker } from "./lib/lifecycle.js";
import {
  draftCreatedEffect,
  hydrateGogDraftEffect,
  inspectOutboundEmailCommand,
} from "./lib/approval-effects.js";
import {
  createGmailDraftSendTool,
  resolveCanonicalGogExecutable,
} from "./lib/gmail-draft-send-tool.js";

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
    const configuredGogExecutable = config.gogExecutable || "/usr/local/bin/gog";

    api.registerTool(createGmailDraftSendTool({
      lifecycle,
      gogExecutable: configuredGogExecutable,
    }), { name: "org2_gmail_draft_send" });

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

    api.on("before_agent_run", async (event, ctx) => {
      if (!trackMainTurns || !shouldTrackMainTurn(event.prompt, ctx)) return;
      const key = `turn:${ctx.sessionKey || ctx.sessionId || "unknown"}:${ctx.runId || "unknown"}`;
      const marker = workflowMarker(event.prompt);
      if (marker?.workflowRunId) {
        await lifecycle.serialize(() => lifecycle.attach(key, marker.workflowRunId, {
          kind: "workflow",
          workflowId: marker.workflowId,
          sessionKey: ctx.sessionKey,
          openclawRunId: ctx.runId,
          provider: ctx.modelProviderId,
          model: ctx.modelId,
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
      }));
    });

    api.on("llm_output", async (event, ctx) => {
      await lifecycle.serialize(() => lifecycle.recordUsage(event.runId || ctx.runId, event.usage));
    });

    api.on("before_tool_call", async (event) => {
      const inspection = inspectOutboundEmailCommand(event.toolName, event.params);
      if (inspection.kind === "blocked") {
        return {
          block: true,
          blockReason: `${inspection.reason} Use org2_gmail_draft_send for the reviewed external effect.`,
        };
      }
      if (inspection.kind === "send") {
        return {
          block: true,
          blockReason: "Direct shell Gmail sends are disabled. Use org2_gmail_draft_send so the final parameters are bound to a durable native Org2 effect reservation.",
        };
      }
    });

    api.on("after_tool_call", async (event, ctx) => {
      const created = draftCreatedEffect(event.toolName, event.params, event.result, event.error);
      if (!created) return;
      const gogExecutable = await resolveCanonicalGogExecutable(configuredGogExecutable);
      const exact = await hydrateGogDraftEffect(created, { gogExecutable });
      await lifecycle.serialize(() => lifecycle.requestDraftApproval(exact, {
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
      }));
    });

    api.on("subagent_ended", async (event) => {
      if (!trackSubagents) return;
      await lifecycle.serialize(() => lifecycle.finish(`subagent:${event.targetSessionKey}`, event.outcome || "ok", {
        error: event.error,
        summary: event.reason ? `OpenClaw subagent finished: ${event.reason}` : "OpenClaw subagent completed successfully.",
      }));
    });

    api.on("cron_changed", async (event) => {
      if (!trackCron) return;
      const key = cronKey(event);
      if (event.action === "started") {
        const marker = workflowMarker(event.job?.payload?.text);
        if (marker) {
          await lifecycle.serialize(() => lifecycle.ensureWorkflow(key, marker.workflowId, marker.inputs, {
            sessionKey: event.sessionKey,
            openclawRunId: event.runId,
            provider: event.provider,
            model: event.model,
          }));
          return;
        }
        await lifecycle.serialize(() => lifecycle.ensure(key, {
          kind: "cron",
          goal: event.job?.name || `Cron ${event.jobId}`,
          sessionKey: event.sessionKey,
          openclawRunId: event.runId,
          provider: event.provider,
          model: event.model,
        }));
      }
      if (event.action === "finished") {
        await lifecycle.serialize(() => lifecycle.finish(key, event.status === "ok" || event.status === "skipped" ? "ok" : "error", {
          error: event.error,
          summary: event.summary || (event.status === "skipped" ? "OpenClaw skipped the scheduled execution." : "OpenClaw scheduled execution completed successfully."),
          durationMs: event.durationMs,
          provider: event.provider,
          model: event.model,
        }));
      }
    });
  },
});
