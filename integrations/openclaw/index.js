import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { cronKey, Org2Lifecycle, shouldTrackMainTurn, workflowMarker } from "./lib/lifecycle.js";

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
        respond(true, await lifecycle.serialize(() => lifecycle.prepareWorkflowRun(workflowId, inputs)));
      } catch (error) {
        respond(false, undefined, { code: "ORG2_WORKFLOW_ERROR", message: error.message });
      }
    }, { scope: "operator.write" });

    api.registerGatewayMethod("org2.workflow.sync", async ({ respond }) => {
      try { respond(true, await lifecycle.serialize(() => lifecycle.reconcile())); }
      catch (error) { respond(false, undefined, { code: "ORG2_WORKFLOW_ERROR", message: error.message }); }
    }, { scope: "operator.write" });

    api.registerGatewayMethod("org2.workflow.status", async ({ respond }) => {
      try { respond(true, await lifecycle.workflowStatus()); }
      catch (error) { respond(false, undefined, { code: "ORG2_WORKFLOW_ERROR", message: error.message }); }
    }, { scope: "operator.read" });

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
        }));
        return;
      }
      await lifecycle.serialize(() => lifecycle.ensure(key, {
        kind: "agent-turn",
        goal: event.prompt,
        sessionKey: ctx.sessionKey,
        openclawRunId: ctx.runId,
      }));
    });

    api.on("agent_end", async (event, ctx) => {
      const key = `turn:${ctx.sessionKey || ctx.sessionId || "unknown"}:${event.runId || ctx.runId || "unknown"}`;
      await lifecycle.serialize(() => lifecycle.finish(key, event.success ? "ok" : "error", event.error));
    });

    api.on("subagent_spawned", async (event) => {
      if (!trackSubagents) return;
      await lifecycle.serialize(() => lifecycle.ensure(`subagent:${event.childSessionKey}`, {
        kind: event.mode === "session" ? "subagent-session" : "subagent",
        goal: event.label || `Subagent ${event.childSessionKey}`,
        sessionKey: event.childSessionKey,
        openclawRunId: event.runId,
      }));
    });

    api.on("subagent_ended", async (event) => {
      if (!trackSubagents) return;
      await lifecycle.serialize(() => lifecycle.finish(
        `subagent:${event.targetSessionKey}`,
        event.outcome || "ok",
        event.error,
      ));
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
          }));
          return;
        }
        await lifecycle.serialize(() => lifecycle.ensure(key, {
          kind: "cron",
          goal: event.job?.name || `Cron ${event.jobId}`,
          sessionKey: event.sessionKey,
          openclawRunId: event.runId,
        }));
      }
      if (event.action === "finished") {
        await lifecycle.serialize(() => lifecycle.finish(
          key,
          event.status === "ok" || event.status === "skipped" ? "ok" : "error",
          event.error,
        ));
      }
    });
  },
});
