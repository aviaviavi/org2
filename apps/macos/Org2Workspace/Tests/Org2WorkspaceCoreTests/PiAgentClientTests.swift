import XCTest
@testable import Org2WorkspaceCore

final class PiAgentClientTests: XCTestCase {
  func testArgumentsResumeSessionAndRestrictReadOnlyTools() {
    let arguments = PiAgentClient.arguments(
      sessionID: "session-123",
      model: "openai/gpt-5",
      reasoningEffort: "high",
      sandboxAccess: .readOnly,
      systemPromptPath: "/tmp/context.txt",
      attachmentPaths: ["/tmp/file.txt"],
      message: "Review this"
    )

    XCTAssertEqual(arguments.prefix(6), [
      "--mode", "json", "--append-system-prompt", "/tmp/context.txt",
      "--tools", "read,grep,find,ls"
    ])
    XCTAssertTrue(arguments.contains(["--session", "session-123"]))
    XCTAssertTrue(arguments.contains(["--model", "openai/gpt-5"]))
    XCTAssertTrue(arguments.contains(["--thinking", "high"]))
    XCTAssertEqual(arguments.suffix(2), ["@/tmp/file.txt", "Review this"])
  }

  func testJSONStreamDecodesSessionTextAndTools() async {
    var decoder = PiAgentStreamDecoder()
    let events = PiEventLog()
    await decoder.consume(#"{"type":"session","id":"pi-session"}"#) { event in
      if case .sessionStarted(let id) = event { await events.append("session:\(id)") }
    }
    await decoder.consume(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hi"}}"#) { event in
      if case .textDelta(let text) = event { await events.append("text:\(text)") }
    }
    await decoder.consume(#"{"type":"tool_execution_start","toolCallId":"tool-1","toolName":"read"}"#) { event in
      if case .activity(let id, let title, let status) = event {
        await events.append("tool:\(id):\(title):\(status.rawValue)")
      }
    }
    await decoder.consume(#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hi"}],"stopReason":"stop"}}"#) { _ in }

    XCTAssertEqual(decoder.result.sessionID, "pi-session")
    XCTAssertEqual(decoder.result.reply, "Hi")
    XCTAssertTrue(decoder.result.succeeded)
    let loggedEvents = await events.values
    XCTAssertEqual(loggedEvents, ["session:pi-session", "text:Hi", "tool:tool-1:Reading:running"])
  }

  func testManagedRemoteRejectsCommandInjectionHost() {
    XCTAssertThrowsError(try PiAgentClient.managedRemoteSSHArguments(
      sshHost: "press.local; touch /tmp/nope"
    ))
    XCTAssertNoThrow(try PiAgentClient.managedRemoteSSHArguments(sshHost: "press.local"))
  }
}

private actor PiEventLog {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private extension Array where Element == String {
  func contains(_ adjacent: [String]) -> Bool {
    guard !adjacent.isEmpty, adjacent.count <= count else { return false }
    return indices.contains { start in
      let end = index(start, offsetBy: adjacent.count, limitedBy: endIndex) ?? endIndex
      return end - start == adjacent.count && Array(self[start..<end]) == adjacent
    }
  }
}
