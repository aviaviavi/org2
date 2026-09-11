import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class ChatAgentProfileTests: XCTestCase {
  func testThreadAgentSurvivesPersistenceHydrationAndMetadataUpdates() throws {
    let ref = UUID().uuidString
    let original = OpenClawChatThread(title: "Agent chat", sessionKey: "test", agentRef: ref)
    let restored = try JSONDecoder().decode(OpenClawChatThread.self, from: JSONEncoder().encode(original))
    XCTAssertEqual(restored.agentRef, ref)
    XCTAssertEqual(restored.replacingOpenClawChatMetadata(title: "Renamed").agentRef, ref)
    XCTAssertEqual(restored.replacingPendingTurn(nil).agentRef, ref)
    XCTAssertEqual(restored.hydrating(messages: []).agentRef, ref)
    XCTAssertNil(restored.replacingOpenClawChatMetadata(agentRef: .some(nil)).agentRef)
    let legacy = OpenClawChatThread(title: "Old chat", sessionKey: "legacy")
    XCTAssertNil(try JSONDecoder().decode(OpenClawChatThread.self, from: JSONEncoder().encode(legacy)).agentRef)
  }

  func testAgentContextIsIncludedForEveryRuntimeAndKeepsStableIdentity() {
    let ref = UUID().uuidString, goal = UUID().uuidString
    let profile = AgentProfileItem(schema: "org2:agent-profile:v1", id: ref, name: "Revenue Scout",
      description: "Find useful revenue signals", status: "active", responsibilities: ["Research accounts"],
      capabilities: ["Research"], skills: ["account-research"], runtimeBindings: [], goalRefs: [goal],
      primaryGoalRef: goal, reportsToAgentRef: nil, file: "/local/agent-profiles/scout.org", createdAt: "today", updatedAt: "today")
    let context = OpenClawWorkspaceContext(localCorpusRoot: "/local", remoteCorpusRoot: "/remote",
      selectedSurface: "AI Chat", selectedLocation: nil, selectedEntrySource: nil, backlinks: nil,
      agenda: nil, searchQuery: "", searchResults: [], chatAgentRef: ref, chatAgentProfile: profile)
    for prompt in [context.systemPrompt(), context.codexSystemPrompt(), context.localAgentSystemPrompt(runtime: "claude", runtimeTitle: "Claude Code")] {
      XCTAssertTrue(prompt.contains("Revenue Scout"))
      XCTAssertTrue(prompt.contains("Research accounts"))
      XCTAssertTrue(prompt.contains("account-research"))
      XCTAssertTrue(prompt.contains("AGENT_REF: \(ref)"))
      XCTAssertTrue(prompt.contains("GOAL_REF: \(goal)"))
    }
  }
}
