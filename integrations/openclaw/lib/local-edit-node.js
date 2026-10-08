import { methodNames } from "./brand.js";

// Celorga names first; the org2.* names stay accepted for paired 0.8.x apps.
export const org2WorkspaceNodeCommands = [
  "workspace.read",
  "workspace.patch.preview",
  "workspace.patch.apply",
].flatMap(methodNames);

export function registerOrg2WorkspaceNodePolicy(api) {
  api.registerNodeInvokePolicy?.({
    commands: org2WorkspaceNodeCommands,
    // The native app historically identifies itself as "darwin". OpenClaw
    // normalizes that legacy label to "unknown", so keep that compatibility
    // entry and then enforce the Mac metadata again in the handler.
    defaultPlatforms: ["macos", "unknown"],
    dangerous: false,
    async handle(ctx) {
      const platform = ctx.node?.platform?.trim().toLowerCase();
      const deviceFamily = ctx.node?.deviceFamily?.trim().toLowerCase();
      if (!["darwin", "macos"].includes(platform) || deviceFamily !== "mac") {
        return {
          ok: false,
          code: "ORG2_LOCAL_EDIT_NODE_REQUIRED",
          message: "Celorga workspace commands are available only from the paired macOS app node.",
          unavailable: true,
        };
      }
      return await ctx.invokeNode();
    },
  });
}
