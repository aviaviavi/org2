import XCTest
@testable import Org2WorkspaceCore

final class AIChatWorkspaceDiscoveryTests: XCTestCase {
  func testCodexWorkspaceToolsExposeCorpusAndChatDiscovery() throws {
    let tools = CodexAppServerClient.localEditDynamicTools
    let names = tools.compactMap { $0["name"]?.stringValue }
    XCTAssertTrue(names.contains("celorga_workspace_search"))
    XCTAssertTrue(names.contains("celorga_workspace_chat_read"))

    let search = try XCTUnwrap(tools.first {
      $0["name"]?.stringValue == "celorga_workspace_search"
    })
    XCTAssertEqual(
      search["inputSchema"]?["required"]?.arrayValue?.compactMap(\.stringValue),
      ["turnId", "query"]
    )
    XCTAssertFalse(names.contains { $0.hasPrefix("org2_") }, "advertise Celorga tool names only")
  }

  @MainActor
  func testBundledAgentToolsAdvertiseCelorgaNames() {
    let names = BundledAgentWorkspaceTools.definitions.compactMap { $0["name"]?.stringValue }
    XCTAssertEqual(Set(names), [
      "celorga_workspace_read",
      "celorga_workspace_patch_preview",
      "celorga_workspace_patch_apply",
      "celorga_workspace_search",
    ])
  }

  func testChatHistorySearchReturnsStableCitationsAndBoundedReadWindow() throws {
    let first = AIChatMessage(role: .user, content: "I made Nutella cookies last weekend")
    let recipe = AIChatMessage(
      role: .assistant,
      content: "Use flour, butter, brown sugar, and one cup of Nutella. Bake for ten minutes."
    )
    let unrelated = AIChatMessage(role: .assistant, content: "The release is ready.")
    let matching = AIChatThread(
      title: "Nutella cookie recipe",
      sessionKey: "recipe",
      messages: [first, recipe]
    )
    let other = AIChatThread(
      title: "Release",
      sessionKey: "release",
      messages: [unrelated]
    )

    let results = WorkspaceStore.aiChatHistorySearchPayload(
      query: "nutella recipe",
      threads: [other, matching],
      limit: 10
    ).arrayValue
    XCTAssertEqual(results?.count, 2)
    XCTAssertEqual(results?.first?["threadId"]?.stringValue, matching.id.uuidString.lowercased())
    XCTAssertTrue(results?.first?["citation"]?.stringValue?.hasPrefix("org2-chat:") == true)

    let read = WorkspaceStore.aiChatHistoryReadPayload(
      thread: matching,
      aroundMessageID: recipe.id,
      maxMessages: 1
    )
    XCTAssertEqual(read["threadId"]?.stringValue, matching.id.uuidString.lowercased())
    XCTAssertEqual(read["messages"]?.arrayValue?.count, 1)
    XCTAssertEqual(read["messages"]?.arrayValue?.first?["content"]?.stringValue, recipe.content)
  }
}
