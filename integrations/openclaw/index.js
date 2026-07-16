import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { cronKey, Org2Lifecycle, shouldTrackMainTurn } from "./lib/lifecycle.js";

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

    api.on("gateway_start", async () => {
      await lifecycle.init();
      await lifecycle.reconcile();
    });

    api.on("before_agent_run", async (event, ctx) => {
      if (!trackMainTurns || !shouldTrackMainTurn(event.prompt, ctx)) return;
      const key = `turn:${ctx.sessionKey || ctx.sessionId || "unknown"}:${ctx.runId || "unknown"}`;
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
