import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspacePluginActionsTests: XCTestCase {
  func testActionContextsMapToSharedCLIArguments() {
    XCTAssertEqual(WorkspacePluginActionContext.heading(file: "/c/notes/a.org", line: 0).arguments,
                   ["--context", "heading", "--file", "/c/notes/a.org", "--line", "1"])
    XCTAssertEqual(WorkspacePluginActionContext.note(file: "a.org").arguments, ["--context", "note", "--file", "a.org"])
    XCTAssertEqual(WorkspacePluginActionContext.run("r1").arguments, ["--context", "run", "--run", "r1"])
    XCTAssertEqual(WorkspacePluginActionContext.approval(runID: "r1", approvalID: "a1").arguments,
                   ["--context", "approval", "--run", "r1", "--approval", "a1"])
    let thread = UUID()
    XCTAssertEqual(WorkspacePluginActionContext.thread(thread).arguments, ["--context", "thread", "--thread", thread.uuidString])
  }

  func testDecodesActionListsAndProposalPreviews() throws {
    let list = try JSONDecoder().decode(WorkspacePluginActionListPayload.self, from: Data(#"""
    {"$schema":"org2:plugin-action-list:v1","sandbox":"macos-sandbox-exec",
     "actions":[{"id":"x.helper:mark","pluginId":"x.helper","pluginName":"Helper","actionId":"mark","title":"Mark reviewed","contexts":["heading"],"capabilities":[],"trusted":true}],
     "hooks":[{"id":"x.helper:on-blocked","pluginId":"x.helper","pluginName":"Helper","hookId":"on-blocked","events":["run.blocked"],"capabilities":[],"trusted":false}]}
    """#.utf8))
    XCTAssertEqual(list.actions.first?.title, "Mark reviewed")
    XCTAssertEqual(list.hooks.first?.events, ["run.blocked"])

    let preview = try JSONDecoder().decode(WorkspacePluginProposalPreview.self, from: Data(#"""
    {"schema":"org2:plugin-proposal-apply:v1","applied":false,
     "proposal":{"schema":"org2:plugin-proposal:v1","id":"11111111-2222-3333-4444-555555555555","createdAt":"2026-10-05T12:00:00.000Z","status":"pending",
       "source":{"kind":"hook","pluginId":"x.helper","pluginName":"Helper","pluginVersion":"0.1.0","contentHash":"sha256:00","contributionId":"on-blocked","title":"Comment when a run blocks"},
       "proposals":[{"kind":"run-comment","runId":"r1","body":"hi"},{"kind":"edit","path":"notes/a.org","find":"a","replace":"b","summary":"Tag"}],"sandbox":"macos-sandbox-exec"},
     "changes":[{"index":0,"kind":"run-comment","target":"run:r1","ok":true,"detail":"comment"},{"index":1,"kind":"edit","target":"notes/a.org","summary":"Tag","ok":false,"detail":"text to replace was not found"}]}
    """#.utf8))
    XCTAssertEqual(preview.proposal.proposals.map(\.target), ["run r1", "notes/a.org"])
    XCTAssertFalse(preview.changes[1].ok)
  }

  func testPendingProposalsNeedYouInActivityAndRowsOfferActions() throws {
    let suite = "plugin-actions-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    let proposal = try JSONDecoder().decode(WorkspacePluginProposal.self, from: Data(#"""
    {"id":"11111111-2222-3333-4444-555555555555","createdAt":"2026-10-05T12:00:00.000Z","status":"pending",
     "source":{"kind":"action","pluginId":"x.helper","pluginName":"Helper","contributionId":"mark","title":"Mark reviewed"},
     "proposals":[{"kind":"edit","path":"notes/a.org"}],"sandbox":"none"}
    """#.utf8))
    store.pendingPluginProposals = [proposal]
    store.pluginActions = [WorkspacePluginAction(
      id: "x.helper:summarize", pluginId: "x.helper", pluginName: "Helper", actionId: "summarize",
      title: "Summarize", description: nil, contexts: ["run", "thread"], capabilities: [], trusted: true
    )]
    let snapshot = store.activitySnapshot()
    let item = try XCTUnwrap(snapshot.needsYou.first { $0.id == "plugin-proposal:\(proposal.id)" })
    XCTAssertEqual(item.relativePath, "notes/a.org")
    XCTAssertEqual(item.agent, "Helper")
    XCTAssertNil(store.pluginActionContext(for: item), "proposals are reviewed, not acted on")
    XCTAssertFalse(store.canExplainActivityItem(item))

    let run = WorkspaceActivityItem(id: "run:r", kind: .working, title: "r", detail: "", target: .run("r"))
    let context = try XCTUnwrap(store.pluginActionContext(for: run))
    XCTAssertEqual(store.pluginActions(for: context).map(\.id), ["x.helper:summarize"])
    XCTAssertTrue(store.pluginActions(for: .heading(file: "a.org", line: 1)).isEmpty)
  }
}
