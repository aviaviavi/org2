import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const contentView = readFileSync(
  resolve("apps/ios/Org2Mobile/Org2Mobile/ContentView.swift"),
  "utf8",
);
const remoteViews = readFileSync(
  resolve("apps/ios/Org2Mobile/Org2Mobile/MobileRemoteViews.swift"),
  "utf8",
);

const workspaceTabs = contentView.slice(
  contentView.indexOf("private struct WorkspaceTabs"),
  contentView.indexOf("private struct AgendaView"),
);
assert.match(workspaceTabs, /Label\("Files", systemImage: "folder"\)/);
assert.doesNotMatch(workspaceTabs, /Label\("Remote"/);
assert.doesNotMatch(workspaceTabs, /Label\("Workflows"/);
assert.match(workspaceTabs, /case \.thread\(let threadID\):[\s\S]*MobileRemoteThreadView/);

const newNote = contentView.slice(
  contentView.indexOf("private struct NewNoteView"),
  contentView.indexOf("private enum NewNoteFocusedField"),
);
assert.doesNotMatch(newNote, /Section\("Corpus"\)/);
assert.match(newNote, /Menu \{[\s\S]*Photo Library[\s\S]*Camera/);
assert.match(newNote, /Button\("Save"\)/);

assert.match(remoteViews, /struct MobileAISidebarView/);
assert.match(remoteViews, /sidebarButton\([\s\S]*?"External Threads"/);
assert.match(remoteViews, /struct MobileSettingsView/);
assert.match(remoteViews, /Text\("Reply Notifications"\)/);
assert.match(remoteViews, /Label\("Send Test Notification"/);

console.log("iOS mobile navigation tests passed");
