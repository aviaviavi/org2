import XCTest
@testable import Org2WorkspaceCore

final class AgentRunModelsTests: XCTestCase {
  func testRunReviewAutoRefreshUsesOneMinuteInterval() {
    XCTAssertEqual(WorkspaceStore.runReviewAutoRefreshIntervalNanoseconds, 60_000_000_000)
  }

  func testDecodesDurableRunListPayload() throws {
    let data = Data(#"""
    {
      "schema": "org2:run-list:v1",
      "runs": [{
        "id": "run-1",
        "goal": "Prepare a cited briefing",
        "acceptanceCriteria": ["PDF exists"],
        "status": "waiting-approval",
        "riskClass": "external-action",
        "owner": "Avi",
        "assignee": "writer",
        "capabilities": ["publish"],
        "context": [{"ref":"notes/source.org2","citation":"notes/source.org2:1"}],
        "plan": [{"id":"draft","title":"Draft","kind":"agent","status":"completed"}],
        "artifacts": [{"id":"pdf","path":"compiled/brief.pdf","role":"export","reviewStatus":"review-required","createdAt":"2026-07-14T00:00:00.000Z"}],
        "approvals": [{"id":"release","title":"Release","action":"publish","riskClass":"external-action","status":"pending","requestedAt":"2026-07-14T00:00:00.000Z"}],
        "validations": [{"id":"citations","name":"citations","status":"passed","checkedAt":"2026-07-14T00:00:00.000Z"}],
        "comments": [{"id":"comment","author":"Avi","body":"Please revise.","createdAt":"2026-07-14T00:00:00.000Z"}],
        "events": [{"id":"event","type":"created","at":"2026-07-14T00:00:00.000Z"}],
        "createdAt": "2026-07-14T00:00:00.000Z",
        "updatedAt": "2026-07-14T00:01:00.000Z"
      }]
    }
    """#.utf8)

    let payload = try JSONDecoder().decode(AgentRunListPayload.self, from: data)
    let run = try XCTUnwrap(payload.runs.first)
    XCTAssertEqual(run.id, "run-1")
    XCTAssertEqual(run.pendingApprovalCount, 1)
    XCTAssertEqual(run.progressText, "1/1 completed")
    XCTAssertTrue(run.needsAttention)
  }

  func testCompletedRunPresentsOutcomeAndCollapsesSupersededValidationResults() throws {
    let data = Data(#"""
    {
      "id": "meeting-run",
      "goal": "Process the meeting",
      "acceptanceCriteria": [],
      "status": "completed",
      "riskClass": "local-draft",
      "workflowId": "meeting-to-controlled-execution",
      "workflowVersion": "1.0.0",
      "capabilities": [],
      "context": [],
      "plan": [
        {"id":"summarize","title":"Summarize","kind":"agent","status":"completed"},
        {"id":"publish","title":"Publish","kind":"tool","status":"skipped"}
      ],
      "artifacts": [{"id":"pdf","path":"views/meeting/publication.pdf","role":"export","createdAt":"2026-07-14T00:00:00.000Z"}],
      "approvals": [],
      "validations": [
        {"id":"old","name":"artifact-files-present","status":"skipped","checkedAt":"2026-07-14T00:00:00.000Z"},
        {"id":"new","name":"artifact-files-present","status":"passed","checkedAt":"2026-07-14T00:01:00.000Z"}
      ],
      "comments": [],
      "events": [],
      "outcome": {
        "summary": "Prepared the meeting briefing and publication PDF.",
        "highlights": ["Captured the decisions."],
        "nextActions": []
      },
      "createdAt": "2026-07-14T00:00:00.000Z",
      "updatedAt": "2026-07-14T00:01:00.000Z"
    }
    """#.utf8)

    let run = try JSONDecoder().decode(AgentRunItem.self, from: data)
    XCTAssertEqual(run.humanOutcomeSummary, "Prepared the meeting briefing and publication PDF.")
    XCTAssertEqual(run.progressText, "1 completed · 1 skipped")
    XCTAssertEqual(run.workflowDisplayName, "Meeting To Controlled Execution")
    XCTAssertEqual(run.artifacts.first?.displayTitle, "Publication PDF")
    XCTAssertEqual(run.latestValidations.map(\.status), ["passed"])
    XCTAssertFalse(run.needsAttention)
    XCTAssertEqual(run.humanNextAction, "No action required")
  }

  func testAgentRunTimestampUsesLocalReadableTime() throws {
    let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let locale = Locale(identifier: "en_US")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let now = try XCTUnwrap(AgentRunTimestampPresentation.date(from: "2026-07-15T21:19:42.000Z"))

    let display = AgentRunTimestampPresentation.displayText(
      for: "2026-07-15T18:33:41.286Z",
      now: now,
      calendar: calendar,
      locale: locale,
      timeZone: timeZone
    )
    XCTAssertTrue(display.hasPrefix("today at "))
    XCTAssertTrue(display.contains("11:33"), display)

    let detail = AgentRunTimestampPresentation.detailText(
      for: "2026-07-15T18:33:41.286Z",
      locale: locale,
      timeZone: timeZone
    )
    XCTAssertTrue(detail.contains("11:33:41"), detail)
    XCTAssertTrue(detail.contains("PDT"), detail)
  }

  func testAgentRunTimestampSupportsSecondsAndFallsBackForInvalidInput() {
    XCTAssertNotNil(AgentRunTimestampPresentation.date(from: "2026-07-15T18:33:41Z"))
    XCTAssertEqual(
      AgentRunTimestampPresentation.displayText(for: "not-a-timestamp"),
      "not-a-timestamp"
    )
  }

  func testAgentRunClarificationDistinguishesActionableAndLegacyFallbackReasons() throws {
    XCTAssertEqual(
      try makeRun(status: "blocked", blockedReason: "Which reporting period should this cover?").clarificationPrompt,
      "Which reporting period should this cover?"
    )
    XCTAssertNil(
      try makeRun(status: "blocked", blockedReason: "Blocked pending clarification").clarificationPrompt
    )
    XCTAssertNil(try makeRun(status: "running", blockedReason: nil).clarificationPrompt)
  }

  func testAgentRunClarificationResponseRequiresText() {
    XCTAssertNil(WorkspaceStore.normalizedAgentRunClarificationResponse(" \n\t"))
    XCTAssertEqual(
      WorkspaceStore.normalizedAgentRunClarificationResponse("  Use Q3 actuals. \n"),
      "Use Q3 actuals."
    )
  }

  func testCanceledRunDoesNotNeedAttentionWhenOldReviewSignalsRemain() throws {
    let run = try makeRun(
      status: "canceled",
      validationStatus: "failed",
      reviewRequired: true
    )

    XCTAssertFalse(run.needsAttention)
    XCTAssertTrue(run.isFinished)
  }

  func testRunCenterScopeCountsUseTheSamePredicatesAsTheirLists() throws {
    let runs = try [
      makeRun(id: "queued", goal: "Queued work", status: "queued"),
      makeRun(id: "approval", goal: "Approval work", status: "waiting-approval"),
      makeRun(id: "blocked", goal: "Blocked work", status: "blocked"),
      makeRun(id: "failed", goal: "Failed work", status: "failed"),
      makeRun(id: "completed", goal: "Completed work", status: "completed"),
      makeRun(id: "canceled", goal: "Canceled work", status: "canceled", validationStatus: "failed", reviewRequired: true),
    ]

    XCTAssertEqual(AgentRunScope.active.count(in: runs), 1)
    XCTAssertEqual(AgentRunScope.attention.count(in: runs), 3)
    XCTAssertEqual(AgentRunScope.completed.count(in: runs), 2)
    XCTAssertEqual(AgentRunScope.all.count(in: runs), 6)
  }

  func testNeedsAttentionCollapsesRepeatedFailuresAndUsesLatestSeriesState() throws {
    let oldFailure = try makeRun(
      id: "heartbeat-1",
      goal: "Agent heartbeat: MeetingBot",
      status: "failed",
      updatedAt: "2026-07-16T18:00:00.000Z"
    )
    let latestFailure = try makeRun(
      id: "heartbeat-2",
      goal: "Agent heartbeat: MeetingBot",
      status: "failed",
      updatedAt: "2026-07-16T18:15:00.000Z"
    )

    let failedEntries = AgentRunScope.attention.entries(in: [oldFailure, latestFailure])
    XCTAssertEqual(failedEntries.map(\.id), ["heartbeat-2"])
    XCTAssertEqual(failedEntries.first?.representedFailureCount, 2)
    XCTAssertEqual(AgentRunScope.all.count(in: [oldFailure, latestFailure]), 2)

    let successfulRetry = try makeRun(
      id: "heartbeat-3",
      goal: "Agent heartbeat: MeetingBot",
      status: "completed",
      updatedAt: "2026-07-16T18:30:00.000Z"
    )
    XCTAssertTrue(AgentRunScope.attention.entries(in: [oldFailure, latestFailure, successfulRetry]).isEmpty)
    XCTAssertEqual(AgentRunScope.all.count(in: [oldFailure, latestFailure, successfulRetry]), 3)
  }

  @MainActor
  func testOpenAgentRunRecordUsesInAppDetailWithoutLeavingRunsSurface() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-record-navigation-\(UUID().uuidString)", isDirectory: true)
    let runs = root.appendingPathComponent(".org2/runs", isDirectory: true)
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let record = runs.appendingPathComponent("run-1.org2")
    try "#+TITLE: Durable run\n\n* Plan\n- Review the source\n".write(
      to: record,
      atomically: true,
      encoding: .utf8
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.openAgentRunRecord(try makeRun())

    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertEqual(store.selectedLocation?.file, record.path)
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
  }

  @MainActor
  func testRunDetailUsesWorkspaceDetailAndArtifactNavigationReturnsWithBack() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-detail-navigation-\(UUID().uuidString)", isDirectory: true)
    let runs = root.appendingPathComponent(".org2/runs", isDirectory: true)
    let views = root.appendingPathComponent("views", isDirectory: true)
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let output = views.appendingPathComponent("brief.org2")
    try "#+TITLE: Brief\n\n* Result\nReady.\n".write(to: output, atomically: true, encoding: .utf8)
    let runValue: [String: Any] = [
      "schema": "org2:agent-run:v1",
      "id": "run-detail",
      "goal": "Prepare a cited briefing",
      "acceptanceCriteria": [],
      "status": "running",
      "riskClass": "local-draft",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [[
        "id": "brief",
        "path": "views/brief.org2",
        "role": "report",
        "createdAt": "2026-07-14T00:00:00.000Z"
      ]],
      "approvals": [],
      "validations": [],
      "comments": [],
      "events": [],
      "createdAt": "2026-07-14T00:00:00.000Z",
      "updatedAt": "2026-07-14T00:01:00.000Z"
    ]
    let machineState = String(
      data: try JSONSerialization.data(withJSONObject: runValue, options: [.prettyPrinted, .sortedKeys]),
      encoding: .utf8
    )!
    try """
    #+TITLE: Run: Prepare a cited briefing
    #+ORG2_KIND: agent-run

    * TODO Prepare a cited briefing :agent-run:
    #+begin_src json :org2-agent-run
    \(machineState)
    #+end_src
    """.write(
      to: runs.appendingPathComponent("run-detail.org2"),
      atomically: true,
      encoding: .utf8
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    await store.refreshAgentRuns()
    let run = try XCTUnwrap(store.agentRuns.first)

    store.selectAgentRun(run)
    XCTAssertEqual(store.presentedAgentRun?.id, run.id)
    XCTAssertNil(store.selectedLocation)
    XCTAssertEqual(store.selectedSurface, .approvals)

    store.openAgentRunArtifact(try XCTUnwrap(run.artifacts.first))
    XCTAssertNil(store.presentedAgentRun)
    XCTAssertEqual(store.selectedLocation?.file, output.path)
    XCTAssertEqual(store.selectedSurface, .approvals)

    store.navigateBack()
    XCTAssertEqual(store.presentedAgentRun?.id, run.id)
    XCTAssertEqual(store.selectedSurface, .approvals)
  }

  private func makeRun(
    id: String = "run-1",
    goal: String = "Prepare a cited briefing",
    status: String = "queued",
    blockedReason: String? = nil,
    validationStatus: String? = nil,
    reviewRequired: Bool = false,
    updatedAt: String = "2026-07-14T00:01:00.000Z"
  ) throws -> AgentRunItem {
    var value: [String: Any] = [
      "id": id,
      "goal": goal,
      "acceptanceCriteria": [],
      "status": status,
      "riskClass": "local-draft",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": reviewRequired ? [[
        "id": "artifact-1",
        "path": "views/output.org2",
        "role": "report",
        "reviewStatus": "review-required",
        "createdAt": "2026-07-14T00:00:00.000Z"
      ]] : [],
      "approvals": [],
      "validations": validationStatus.map { status in [[
        "id": "validation-1",
        "name": "output-check",
        "status": status,
        "checkedAt": "2026-07-14T00:00:00.000Z"
      ]] } ?? [],
      "comments": [],
      "events": [],
      "createdAt": "2026-07-14T00:00:00.000Z",
      "updatedAt": updatedAt
    ]
    if let blockedReason { value["blockedReason"] = blockedReason }
    return try JSONDecoder().decode(
      AgentRunItem.self,
      from: JSONSerialization.data(withJSONObject: value)
    )
  }
}
