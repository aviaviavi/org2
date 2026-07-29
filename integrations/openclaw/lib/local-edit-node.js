export const org2WorkspaceNodeCommands = [
  "org2.workspace.read",
  "org2.workspace.patch.preview",
  "org2.workspace.patch.apply",
];

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
          message: "Org2 workspace commands are available only from the paired macOS app node.",
          unavailable: true,
        };
      }
      return await ctx.invokeNode();
    },
  });
}
