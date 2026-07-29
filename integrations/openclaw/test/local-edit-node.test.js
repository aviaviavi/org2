import test from "node:test";
import assert from "node:assert/strict";
import {
  org2WorkspaceNodeCommands,
  registerOrg2WorkspaceNodePolicy,
} from "../lib/local-edit-node.js";

test("registers the typed Org2 workspace commands for macOS nodes", async () => {
  let registered;
  registerOrg2WorkspaceNodePolicy({
    registerNodeInvokePolicy(policy) {
      registered = policy;
    },
  });

  assert.deepEqual(registered.commands, [
    "org2.workspace.read",
    "org2.workspace.patch.preview",
    "org2.workspace.patch.apply",
  ]);
  assert.deepEqual(registered.commands, org2WorkspaceNodeCommands);
  assert.deepEqual(registered.defaultPlatforms, ["macos", "unknown"]);
  assert.equal(registered.dangerous, false);

  const expected = { ok: true, payload: { applied: true } };
  let invoked = 0;
  const result = await registered.handle({
    node: {
      platform: "darwin",
      deviceFamily: "Mac",
    },
    async invokeNode() {
      invoked += 1;
      return expected;
    },
  });
  assert.equal(invoked, 1);
  assert.equal(result, expected);
});

test("rejects the compatibility allowlist on a non-Mac node", async () => {
  let registered;
  registerOrg2WorkspaceNodePolicy({
    registerNodeInvokePolicy(policy) {
      registered = policy;
    },
  });

  let invoked = 0;
  const result = await registered.handle({
    node: {
      platform: "linux",
      deviceFamily: "Linux",
    },
    async invokeNode() {
      invoked += 1;
      return { ok: true };
    },
  });

  assert.equal(invoked, 0);
  assert.deepEqual(result, {
    ok: false,
    code: "ORG2_LOCAL_EDIT_NODE_REQUIRED",
    message: "Org2 workspace commands are available only from the paired macOS app node.",
    unavailable: true,
  });
});

test("remains compatible with an older OpenClaw plugin API", () => {
  assert.doesNotThrow(() => registerOrg2WorkspaceNodePolicy({}));
});
