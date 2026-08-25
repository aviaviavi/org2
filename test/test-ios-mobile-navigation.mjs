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
const remoteStore = readFileSync(
  resolve("apps/ios/Org2Mobile/Org2Mobile/MobileRemoteStore.swift"),
  "utf8",
);
const corpusStore = readFileSync(
  resolve("apps/ios/Org2Mobile/Org2Mobile/CorpusStore.swift"),
  "utf8",
);
const remoteCoordinator = readFileSync(
  resolve("apps/macos/Org2Workspace/Sources/Org2Workspace/MobileRemoteCoordinator.swift"),
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
assert.match(
  workspaceTabs,
  /MobileRemoteThreadView\(threadID: threadID\)[\s\S]*?\.id\(threadID\)/,
  "Each sidebar-selected chat should have a distinct SwiftUI view identity",
);
assert.match(
  workspaceTabs,
  /openWorkspace: \{\s*selection = \.newNote\s*route = \.workspace/,
);
assert.match(
  workspaceTabs,
  /\.simultaneousGesture\([\s\S]*DragGesture\([\s\S]*coordinateSpace: \.global[\s\S]*MobileSidebarEdgeSwipe\.shouldOpen/,
  "The workspace should recognize the sidebar reveal without replacing child gestures",
);
assert.match(
  workspaceTabs,
  /guard !isSidebarPresented,[\s\S]*startLocation: value\.startLocation,[\s\S]*translation: value\.translation/,
  "The edge swipe should only reveal a closed sidebar",
);

const sidebarEdgeSwipe = contentView.slice(
  contentView.indexOf("private enum MobileSidebarEdgeSwipe"),
  contentView.indexOf("private enum MobileWorkspaceRoute"),
);
assert.match(sidebarEdgeSwipe, /activationWidth: CGFloat = 24/);
assert.match(sidebarEdgeSwipe, /minimumHorizontalTravel: CGFloat = 44/);
assert.match(
  sidebarEdgeSwipe,
  /\(0\.\.\.activationWidth\)\.contains\(startLocation\.x\)/,
  "Sidebar reveal gestures must begin at the physical left edge",
);
assert.match(
  sidebarEdgeSwipe,
  /translation\.width >= abs\(translation\.height\) \* horizontalDominance/,
  "Vertical scrolling should not open the sidebar",
);

const newNote = contentView.slice(
  contentView.indexOf("private struct NewNoteView"),
  contentView.indexOf("private enum NewNoteFocusedField"),
);
assert.doesNotMatch(newNote, /Section\("Corpus"\)/);
assert.match(newNote, /Menu \{[\s\S]*Photo Library[\s\S]*Camera/);
assert.match(newNote, /Button\("Save"\)/);

assert.match(remoteViews, /struct MobileAISidebarView/);
assert.match(remoteViews, /sidebarButton\([\s\S]*?"External Threads"/);
const mobileSidebar = remoteViews.slice(
  remoteViews.indexOf("struct MobileAISidebarView"),
  remoteViews.indexOf("struct MobileSettingsView"),
);
assert.ok(
  mobileSidebar.indexOf('sidebarButton("Settings"') < mobileSidebar.indexOf('Section("Threads")'),
  "Settings should stay in the sidebar's fixed navigation group above chat threads",
);
assert.equal(
  mobileSidebar.match(/sidebarButton\("Settings"/g)?.length,
  1,
  "Settings should appear once in the mobile sidebar",
);
assert.match(
  remoteViews,
  /Label\("New \\\(destination\.name\) Chat", systemImage: "plus\.bubble"\)/,
);
assert.doesNotMatch(remoteViews, /New \(destination\.name\) Chat/);
assert.match(remoteViews, /struct MobileSettingsView/);
assert.match(remoteViews, /Text\("Reply Notifications"\)/);
assert.match(remoteViews, /Label\("Send Test Notification"/);
assert.match(remoteViews, /LabeledContent\("Endpoint", value: remote\.pairedEndpoint\)/);
assert.match(remoteViews, /Label\("Reconnect", systemImage: "arrow\.clockwise"\)/);
assert.match(remoteViews, /Button\("Pair Again", role: \.destructive\)/);

const mobileThreadView = remoteViews.slice(
  remoteViews.indexOf("struct MobileRemoteThreadView"),
  remoteViews.indexOf("private struct MobileRemotePhotoThumbnail"),
);
assert.match(
  mobileThreadView,
  /\.task\(id: threadID\) \{[\s\S]*remote\.beginPolling\(threadID: threadID\)/,
  "Changing the selected chat should restart transcript polling",
);
assert.doesNotMatch(
  mobileThreadView,
  /\.onAppear \{[\s\S]{0,180}remote\.beginPolling/,
  "Transcript polling must not depend only on onAppear",
);

const createThread = remoteStore.slice(
  remoteStore.indexOf("func createThread(destination:"),
  remoteStore.indexOf("func refreshExternalThreads()"),
);
assert.match(createThread, /guard let threadID = response\.threadID/);
assert.match(createThread, /guard isConnected else/);
assert.doesNotMatch(createThread, /await refresh\(\)/);
assert.match(createThread, /Task \{ \[weak self\][\s\S]*refresh\(reportsErrors: false\)/);

assert.match(corpusStore, /content\.title = "OpenOrg due today"/);
assert.match(remoteCoordinator, /title: "OpenOrg reply notifications"/);
assert.doesNotMatch(corpusStore, /content\.title = "Org2/);
assert.doesNotMatch(remoteCoordinator, /title: "Org2 reply notifications"/);
assert.match(remoteStore, /serverName = "OpenOrg on Mac"/);
assert.match(remoteStore, /storedServerName == "Org2 on Mac"/);

console.log("iOS mobile navigation tests passed");
