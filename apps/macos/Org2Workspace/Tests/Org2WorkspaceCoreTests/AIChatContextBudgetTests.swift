import XCTest
@testable import Org2WorkspaceCore

final class AIChatContextBudgetTests: XCTestCase {
  func testPersistentContextUsesRecoveryThenDeltaOnly() throws {
    let transcript = "Selected AI chat thread continuation\n\n" + String(repeating: "old turn ", count: 8_000)
    let initialPrompt = [
      "Org2 working rules\n\nKeep citations stable.",
      "Project context\n\nVersion one.",
      transcript,
    ].joined(separator: "\n\n---\n\n")

    let recovery = AIChatContextBudget.persistentEnvelope(
      fullPrompt: initialPrompt,
      previousSections: nil,
      forceRecovery: false,
      includesTranscript: true
    )
    XCTAssertEqual(recovery.telemetry.mode, .recovery)
    XCTAssertLessThanOrEqual(
      recovery.telemetry.transcriptTokens,
      AIChatContextBudget.recoveryTranscriptTokenBudget
    )
    XCTAssertFalse(recovery.sectionSnapshot.keys.contains {
      $0.hasPrefix("Selected AI chat thread continuation#")
    })

    let unchanged = AIChatContextBudget.persistentEnvelope(
      fullPrompt: initialPrompt,
      previousSections: recovery.sectionSnapshot,
      forceRecovery: false,
      includesTranscript: true
    )
    XCTAssertEqual(unchanged.telemetry.mode, .delta)
    XCTAssertNil(unchanged.prompt)
    XCTAssertEqual(unchanged.telemetry.totalTokens, 0)

    let changedPrompt = initialPrompt.replacingOccurrences(
      of: "Project context\n\nVersion one.",
      with: "Project context\n\nVersion two."
    )
    let changed = AIChatContextBudget.persistentEnvelope(
      fullPrompt: changedPrompt,
      previousSections: recovery.sectionSnapshot,
      forceRecovery: false,
      includesTranscript: true
    )
    XCTAssertEqual(changed.telemetry.mode, .delta)
    XCTAssertTrue(try XCTUnwrap(changed.prompt).contains("Version two"))
    XCTAssertFalse(try XCTUnwrap(changed.prompt).contains("Selected AI chat thread continuation"))

    let removed = AIChatContextBudget.persistentEnvelope(
      fullPrompt: "Org2 working rules\n\nKeep citations stable.",
      previousSections: changed.sectionSnapshot,
      forceRecovery: false,
      includesTranscript: true
    )
    XCTAssertTrue(try XCTUnwrap(removed.prompt).contains("Project context"))
    XCTAssertTrue(try XCTUnwrap(removed.prompt).contains("no longer present"))
  }

  func testStatelessHistoryHasOneHardTokenBudget() {
    let messages = (0..<80).map { index in
      OpenClawChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: String(repeating: "x", count: 1_000))
    }
    let bounded = AIChatContextBudget.boundedHistory(messages)
    let estimated = bounded.reduce(0) {
      $0 + AIChatContextBudget.estimatedTokens($1.content)
        + AIChatContextBudget.estimatedAttachmentTokens($1.attachments) + 8
    }
    XCTAssertLessThanOrEqual(estimated, AIChatContextBudget.statelessHistoryTokenBudget)
    XCTAssertLessThan(bounded.count, messages.count)
    XCTAssertEqual(bounded.last?.id, messages.last?.id)
  }

  func testStatelessHistoryNeverTruncatesCurrentRequest() throws {
    let earlier = OpenClawChatMessage(role: .assistant, content: String(repeating: "history ", count: 2_000))
    let currentContent = "BEGIN-CURRENT\n" + String(repeating: "instruction ", count: 8_000) + "\nEND-CURRENT"
    let current = OpenClawChatMessage(role: .user, content: currentContent)

    let bounded = AIChatContextBudget.boundedHistory(
      [earlier, current],
      tokenBudget: 100
    )

    XCTAssertEqual(bounded.count, 1)
    XCTAssertEqual(try XCTUnwrap(bounded.last).content, currentContent)
  }

  func testBoundedSuffixIsUTF8SafeAndWithinBudget() {
    let bounded = AIChatContextBudget.boundedSuffix(
      String(repeating: "🙂é", count: 1_000),
      tokenBudget: 64
    )

    XCTAssertLessThanOrEqual(bounded.utf8.count, 64 * 4)
    XCTAssertTrue(bounded.hasPrefix("[Earlier content omitted]"))
    XCTAssertFalse(bounded.contains("�"))
  }

  func testPersistentContinuationBenchmarkMeetsRegressionBudget() {
    let baseProject = "Project context\n\n" + String(repeating: "project ", count: 1_000)
    let fullPrompt = [
      "Org2 working rules\n\n" + String(repeating: "rules ", count: 2_000),
      baseProject,
      "Selected AI chat thread continuation\n\n" + String(repeating: "history ", count: 4_000),
    ].joined(separator: "\n\n---\n\n")
    let turns = 20
    let before = AIChatContextBudget.estimatedTokens(fullPrompt) * turns
    let first = AIChatContextBudget.persistentEnvelope(
      fullPrompt: fullPrompt,
      previousSections: nil,
      forceRecovery: false,
      includesTranscript: true
    )
    var after = first.telemetry.totalTokens
    var snapshot = first.sectionSnapshot
    for turn in 1..<turns {
      let projectVersion = turn.isMultiple(of: 5)
        ? baseProject + "\nProject delta \(turn)"
        : baseProject
      let turnPrompt = fullPrompt.replacingOccurrences(of: baseProject, with: projectVersion)
      let next = AIChatContextBudget.persistentEnvelope(
        fullPrompt: turnPrompt,
        previousSections: snapshot,
        forceRecovery: turn == 10,
        includesTranscript: true
      )
      after += next.telemetry.totalTokens
      snapshot = next.sectionSnapshot
    }
    let reductionPercent = 100 - (after * 100 / before)
    XCTAssertGreaterThanOrEqual(reductionPercent, 80)
  }

  func testResponseTraceRoundTripsProviderAndComponentTelemetry() throws {
    let trace = OpenClawResponseTrace(
      usage: AIChatTokenUsage(
        inputTokens: 120,
        cachedInputTokens: 80,
        outputTokens: 30,
        totalTokens: 150
      ),
      context: OpenOrgContextTelemetry(
        mode: .delta,
        staticTokens: 20,
        projectTokens: 10,
        roomTokens: 5
      )
    )
    let decoded = try JSONDecoder().decode(
      OpenClawResponseTrace.self,
      from: JSONEncoder().encode(trace)
    )
    XCTAssertEqual(decoded, trace)
    XCTAssertEqual(decoded.context?.totalTokens, 35)
  }

  func testTelemetryClassifiesDynamicWorkspaceContextAndExcludesCurrentRequest() {
    let system = [
      "Org2 workspace operating context\n\nCorpus roots",
      "Project notes linked to this chat\n\nProject brief",
      "Org2 working rules\n\nStable instruction",
    ].joined(separator: "\n\n---\n\n")
    let history = [
      OpenClawChatMessage(role: .assistant, content: "Earlier answer"),
      OpenClawChatMessage(role: .user, content: "Current request"),
    ]

    let telemetry = AIChatContextBudget.statelessTelemetry(
      systemPrompt: system,
      history: history
    )

    XCTAssertGreaterThan(telemetry.projectTokens, 0)
    XCTAssertGreaterThan(telemetry.staticTokens, 0)
    XCTAssertEqual(
      telemetry.transcriptTokens,
      AIChatContextBudget.estimatedTokens("Earlier answer") + 8
    )
  }
}
