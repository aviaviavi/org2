import Combine
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
        "parentRunId": "parent-run",
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
    XCTAssertEqual(run.parentRunId, "parent-run")
    XCTAssertEqual(run.pendingApprovalCount, 1)
    XCTAssertEqual(run.progressText, "1/1 completed")
    XCTAssertTrue(run.needsAttention)
    XCTAssertTrue(run.matchesRunFilter("cited briefing"))
    XCTAssertTrue(run.matchesRunFilter("writer publish"))
    XCTAssertTrue(run.matchesRunFilter("notes source"))
    XCTAssertTrue(run.matchesRunFilter("brief pdf"))
    XCTAssertTrue(run.matchesRunFilter("release pending"))
    XCTAssertTrue(run.matchesRunFilter("please revise"))
    XCTAssertTrue(run.matchesRunFilter("  \n "))
    XCTAssertFalse(run.matchesRunFilter("deployment checklist"))
    XCTAssertTrue(try XCTUnwrap(run.artifacts.first).isPDF)
  }

  func testDecodesRunApprovalAsUnifiedQueueItem() throws {
    let data = Data(#"""
    {
      "kind": "run",
      "title": "Release report",
      "status": "pending",
      "todo": null,
      "level": null,
      "file": "/tmp/corpus/.org2/runs/run-1.org2",
      "line": 1,
      "idValue": "approval-1",
      "properties": {},
      "body": "publish report",
      "tags": [],
      "approvalId": "approval-1",
      "fingerprint": "sha256:abc123",
      "action": "publish report",
      "riskClass": "external-action",
      "requestedRole": "owner",
      "requestedAt": "2026-07-21T00:00:00.000Z",
      "runId": "run-1",
      "runGoal": "Prepare report",
      "runStatus": "waiting-approval",
      "runPendingApprovalCount": 2,
      "runApprovalCount": 3,
      "runDecisionEffect": "Approving this leaves 1 other pending approval before the run can resume.",
      "decisionKeys": ["artifact:gmail:gog:r123"]
    }
    """#.utf8)

    let item = try JSONDecoder().decode(ApprovalItem.self, from: data)
    XCTAssertTrue(item.isRunApproval)
    XCTAssertEqual(item.id, "run:run-1:approval-1")
    XCTAssertEqual(item.fingerprint, "sha256:abc123")
    XCTAssertEqual(item.decisionKeys, ["artifact:gmail:gog:r123"])
    XCTAssertEqual(item.sourceLabel, "Run run-1")
    XCTAssertEqual(item.runDependencyText, "Approving this leaves 1 other pending approval before the run can resume.")
    XCTAssertTrue(item.matchesApprovalFilter("prepare report external-action"))
  }

  func testRecognizesOpenClawExternalDraftRunForApprovalContinuation() throws {
    let data = Data(#"""
    {
      "id": "draft-run-1",
      "goal": "Review provider draft",
      "acceptanceCriteria": [],
      "status": "running",
      "riskClass": "external-action",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [],
      "validations": [],
      "comments": [{
        "id": "comment-1",
        "author": "org2-lifecycle",
        "body": "OPENCLAW_KEY: draft:gmail:gog:default:r123\nOPENCLAW_KIND: external-draft",
        "createdAt": "2026-07-30T16:56:25.154Z"
      }],
      "events": [],
      "createdAt": "2026-07-30T16:56:25.154Z",
      "updatedAt": "2026-07-30T18:08:14.385Z"
    }
    """#.utf8)

    let run = try JSONDecoder().decode(AgentRunItem.self, from: data)
    XCTAssertTrue(run.isOpenClawExternalDraft)
  }

  @MainActor
  func testUnifiedQueueDecisionUpdatesTheCanonicalRunApproval() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-approval-queue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    _ = try await cli.run([
      "run", "create", "--id", "approval-run", "--goal", "Release report",
      "--dir", root.path, "--json"
    ])
    _ = try await cli.run(["run", "start", "approval-run", "--dir", root.path, "--json"])
    _ = try await cli.run([
      "run", "approval-request", "approval-run",
      "--title", "Approve release", "--action", "publish report",
      "--risk", "external-action", "--role", "owner", "--from", "Avi",
      "--dir", root.path, "--json"
    ])

    let store = WorkspaceStore(cli: cli)
    store.setCorpusRoot(root, persistsDefault: false)
    await store.refreshAgentRuns()
    await store.refreshApprovals()

    let queueItem = try XCTUnwrap(store.approvalItems.first(where: { $0.isRunApproval }))
    XCTAssertEqual(queueItem.runId, "approval-run")
    XCTAssertEqual(queueItem.runPendingApprovalCount, 1)
    XCTAssertEqual(queueItem.runDependencyText, "This is the last pending approval; approving it resumes the run.")

    await store.approve(queueItem)
    await store.refreshApprovals()

    let updatedRun = try XCTUnwrap(store.agentRuns.first(where: { $0.id == "approval-run" }))
    XCTAssertEqual(updatedRun.status, "running")
    XCTAssertEqual(updatedRun.approvals.first?.status, "approved")
    XCTAssertFalse(store.approvalItems.contains(where: { $0.id == queueItem.id }))
  }

  @MainActor
  func testMacRunApprovalRejectionAndCancellationAlsoCancelOriginatingRuns() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-approval-terminal-decisions-\(UUID().uuidString)", isDirectory: true)

    func run(id: String, status: String, approvalStatus: String) throws -> AgentRunItem {
      var approval: [String: Any] = [
        "id": "\(id)-approval",
        "fingerprint": "sha256:\(id)",
        "title": "Approve \(id)",
        "action": "perform protected action",
        "riskClass": "external-action",
        "status": approvalStatus,
        "requestedRole": "owner",
        "requestedFrom": "Avi",
        "requestedAt": "2026-07-30T18:00:01.000Z",
      ]
      if approvalStatus != "pending" {
        approval["decidedAt"] = "2026-07-30T18:00:02.000Z"
        approval["decidedBy"] = "Avi"
      }
      let object: [String: Any] = [
        "id": id,
        "goal": "Protect \(id)",
        "acceptanceCriteria": [],
        "status": status,
        "riskClass": "external-action",
        "capabilities": [],
        "context": [],
        "plan": [],
        "artifacts": [],
        "approvals": [approval],
        "validations": [],
        "comments": [],
        "events": [[
          "id": "\(id)-waiting",
          "type": "status-changed",
          "at": "2026-07-30T18:00:01.000Z",
          "detail": "running -> waiting-approval",
        ]],
        "createdAt": "2026-07-30T18:00:00.000Z",
        "updatedAt": "2026-07-30T18:00:02.000Z",
      ]
      return try JSONDecoder().decode(
        AgentRunItem.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    }

    let rejectedRun = try run(
      id: "rejected-run",
      status: "waiting-approval",
      approvalStatus: "pending"
    )
    let rejectedApproval = try XCTUnwrap(rejectedRun.approvals.first)
    let canceledRun = try run(
      id: "canceled-run",
      status: "waiting-approval",
      approvalStatus: "pending"
    )
    let canceledApproval = try XCTUnwrap(canceledRun.approvals.first)
    let updatedRejectedRun = try run(
      id: "rejected-run",
      status: "canceled",
      approvalStatus: "rejected"
    )
    let updatedCanceledRun = try run(
      id: "canceled-run",
      status: "canceled",
      approvalStatus: "canceled"
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([rejectedRun, canceledRun])
    store.agentRunApprovalDecisionForTesting = { runID, approvalID, decision, note in
      XCTAssertEqual(approvalID, "\(runID)-approval")
      switch decision {
      case "rejected":
        XCTAssertEqual(note, "The protected action should not proceed.")
        return updatedRejectedRun
      case "canceled":
        XCTAssertNil(note)
        return updatedCanceledRun
      default:
        XCTFail("Unexpected decision \(decision)")
        return rejectedRun
      }
    }

    func queueItem(run: AgentRunItem, approval: AgentRunApprovalItem) -> ApprovalItem {
      ApprovalItem(
        title: approval.title,
        status: approval.status,
        todo: nil,
        level: nil,
        file: root.appendingPathComponent(".org2/runs/\(run.id).org2").path,
        line: 1,
        idValue: approval.id,
        properties: [:],
        body: approval.action,
        tags: [],
        kind: "run",
        approvalId: approval.id,
        fingerprint: approval.fingerprint,
        action: approval.action,
        riskClass: approval.riskClass,
        requestedRole: approval.requestedRole,
        requestedFrom: approval.requestedFrom,
        requestedAt: approval.requestedAt,
        runId: run.id,
        runGoal: run.goal,
        runStatus: run.status,
        runPendingApprovalCount: run.pendingApprovalCount,
        runApprovalCount: run.approvals.count
      )
    }

    let rejectedItem = queueItem(run: rejectedRun, approval: rejectedApproval)
    let canceledItem = queueItem(run: canceledRun, approval: canceledApproval)
    store.replaceApprovalItemsForTesting([rejectedItem, canceledItem])
    await store.rejectApproval(
      rejectedItem,
      endStatus: .canceled,
      reason: "The protected action should not proceed."
    )

    await store.decideAgentRunApproval(
      canceledRun,
      approval: canceledApproval,
      decision: "canceled"
    )

    let displayedRejectedRun = try XCTUnwrap(store.agentRuns.first(where: {
      $0.id == "rejected-run"
    }))
    let displayedCanceledRun = try XCTUnwrap(store.agentRuns.first(where: {
      $0.id == "canceled-run"
    }))
    XCTAssertEqual(displayedRejectedRun.status, "canceled")
    XCTAssertEqual(displayedRejectedRun.approvals.first?.status, "rejected")
    XCTAssertEqual(displayedRejectedRun.pendingApprovalCount, 0)
    XCTAssertEqual(displayedCanceledRun.status, "canceled")
    XCTAssertEqual(displayedCanceledRun.approvals.first?.status, "canceled")
    XCTAssertFalse(store.approvalItems.contains(where: {
      $0.runId == "rejected-run" || $0.runId == "canceled-run"
    }))
  }

  @MainActor
  func testFinishedRunQueueCleanupImmediatelyRemovesAllOfItsApprovalRows() throws {
    let run = try makeRun(status: "completed", pendingApproval: true)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.replaceAgentRunsForTesting([run])
    let approval = try XCTUnwrap(run.approvals.first)
    let queueItem = ApprovalItem(
      title: approval.title,
      status: approval.status,
      todo: nil,
      level: nil,
      file: "/tmp/corpus/.org2/runs/\(run.id).org2",
      line: 1,
      idValue: approval.id,
      properties: [:],
      body: approval.action,
      tags: [],
      kind: "run",
      approvalId: approval.id,
      fingerprint: approval.fingerprint,
      action: approval.action,
      riskClass: approval.riskClass,
      requestedRole: approval.requestedRole,
      requestedFrom: approval.requestedFrom,
      requestedAt: approval.requestedAt,
      runId: run.id,
      runGoal: run.goal,
      runStatus: run.status,
      runPendingApprovalCount: 1,
      runApprovalCount: 1
    )
    store.replaceApprovalItemsForTesting([queueItem])
    store.selectApprovalItem(queueItem)

    store.removeFinishedRunApprovalsFromQueue(run.id)

    XCTAssertFalse(store.approvalItems.contains(where: { $0.runId == run.id }))
    XCTAssertNotEqual(store.selectedApprovalItemID, queueItem.id)
  }

  func testRevisionFeedbackNormalizationAndResumableBoundary() throws {
    XCTAssertNil(WorkspaceStore.normalizedApprovalRevisionFeedback("   \n"))
    XCTAssertEqual(
      WorkspaceStore.normalizedApprovalRevisionFeedback(
        "  Lead with the recommendation and remove the internal acronym.  "
      ),
      "Lead with the recommendation and remove the internal acronym."
    )

    let data = Data(#"""
    {
      "id": "revision-run",
      "goal": "Prepare launch copy",
      "acceptanceCriteria": [],
      "status": "blocked",
      "riskClass": "local-draft",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [{
        "id": "review-copy",
        "title": "Review launch copy",
        "action": "send launch copy",
        "riskClass": "external-action",
        "status": "revised",
        "requestedAt": "2026-07-27T10:01:00.000Z",
        "decidedAt": "2026-07-27T10:02:00.000Z",
        "decisionNote": "Lead with the recommendation."
      }],
      "validations": [],
      "comments": [],
      "events": [
        {
          "id": "waiting",
          "type": "status-changed",
          "at": "2026-07-27T10:01:00.000Z",
          "detail": "running -> waiting-approval"
        }
      ],
      "createdAt": "2026-07-27T10:00:00.000Z",
      "updatedAt": "2026-07-27T10:02:00.000Z",
      "blockedReason": "One or more approvals were not approved"
    }
    """#.utf8)
    let run = try JSONDecoder().decode(AgentRunItem.self, from: data)
    XCTAssertEqual(run.currentApprovalBoundary.map(\.id), ["review-copy"])
    XCTAssertEqual(run.resumableRevisionApproval?.id, "review-copy")
  }

  @MainActor
  func testRunCenterDecisionUsesAssignedReviewerAndClearsUnifiedQueueItem() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-center-approval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    _ = try await cli.run([
      "run", "create", "--id", "run-center-approval", "--goal", "Release three drafts",
      "--dir", root.path, "--json"
    ])
    _ = try await cli.run(["run", "start", "run-center-approval", "--dir", root.path, "--json"])
    for index in 1...3 {
      _ = try await cli.run([
        "run", "approval-request", "run-center-approval",
        "--title", "Approve draft \(index)", "--action", "send draft \(index)",
        "--risk", "external-action", "--role", "approver", "--from", "Avi",
        "--dir", root.path, "--json"
      ])
    }

    let store = WorkspaceStore(cli: cli)
    store.setCorpusRoot(root, persistsDefault: false)
    await store.refreshAgentRuns()
    await store.refreshApprovals()

    let run = try XCTUnwrap(store.agentRuns.first(where: { $0.id == "run-center-approval" }))
    let approval = try XCTUnwrap(run.approvals.first)
    let queueItemID = "run:\(run.id):\(approval.id)"
    XCTAssertEqual(run.pendingApprovalCount, 3)
    XCTAssertTrue(store.approvalItems.contains(where: { $0.id == queueItemID }))

    await store.decideAgentRunApproval(run, approval: approval, decision: "approved")

    let updatedRun = try XCTUnwrap(store.agentRuns.first(where: { $0.id == run.id }))
    XCTAssertEqual(updatedRun.pendingApprovalCount, 2)
    XCTAssertEqual(updatedRun.approvals.first?.status, "approved")
    XCTAssertFalse(store.approvalItems.contains(where: { $0.id == queueItemID }))
  }

  func testRunApprovalDecisionActorUsesAssignedReviewerWhenPresent() {
    XCTAssertEqual(WorkspaceStore.agentRunApprovalDecisionActor(requestedFrom: " Avi "), "Avi")
    XCTAssertEqual(WorkspaceStore.agentRunApprovalDecisionActor(requestedFrom: "  "), "Org2Workspace")
    XCTAssertEqual(WorkspaceStore.agentRunApprovalDecisionActor(requestedFrom: nil), "Org2Workspace")
  }

  func testRecognizesPDFRunArtifactsFromExtensionOrMediaType() throws {
    let extensionArtifact = try JSONDecoder().decode(
      AgentRunArtifactItem.self,
      from: Data(#"{"id":"pdf","path":"compiled/BRIEF.PDF","role":"export","createdAt":"2026-07-14T00:00:00.000Z"}"#.utf8)
    )
    let mediaTypeArtifact = try JSONDecoder().decode(
      AgentRunArtifactItem.self,
      from: Data(#"{"id":"pdf","path":"compiled/brief","role":"export","mediaType":"application/pdf; charset=binary","createdAt":"2026-07-14T00:00:00.000Z"}"#.utf8)
    )
    let textArtifact = try JSONDecoder().decode(
      AgentRunArtifactItem.self,
      from: Data(#"{"id":"note","path":"compiled/brief.org2","role":"draft","mediaType":"text/plain","createdAt":"2026-07-14T00:00:00.000Z"}"#.utf8)
    )

    XCTAssertTrue(extensionArtifact.isPDF)
    XCTAssertTrue(mediaTypeArtifact.isPDF)
    XCTAssertFalse(textArtifact.isPDF)
  }

  func testFindsOpenClawExecApprovalIDInLifecycleComment() throws {
    let data = Data(#"""
    {
      "id": "run-1",
      "goal": "Prepare an external message",
      "acceptanceCriteria": [],
      "status": "waiting-approval",
      "riskClass": "external-action",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [],
      "validations": [],
      "comments": [{
        "id": "comment-1",
        "author": "org2-lifecycle",
        "body": "OPENCLAW_KEY: draft:exec:default:IC_example123\nOPENCLAW_KIND: external-draft",
        "createdAt": "2026-07-20T00:00:00.000Z"
      }],
      "events": [],
      "createdAt": "2026-07-20T00:00:00.000Z",
      "updatedAt": "2026-07-20T00:00:00.000Z"
    }
    """#.utf8)

    let run = try JSONDecoder().decode(AgentRunItem.self, from: data)
    XCTAssertEqual(run.openClawExecApprovalID, "IC_example123")
  }

  @MainActor
  func testRunsAndReviewSearchFocusSignalsBothPossibleVisibleTabs() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))

    store.focusRunsAndReviewFilter()

    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertEqual(store.agentRunFilterFocusToken, 1)
    XCTAssertEqual(store.approvalFilterFocusToken, 1)
  }

  func testDecodesPlainTextWorkflowCatalog() throws {
    let data = Data(#"""
    {
      "schema": "org2:workflow-list:v1",
      "workflows": [{
        "id": "weekly-review",
        "version": "1.2.0",
        "title": "Weekly review",
        "description": "Prepare a cited weekly review.",
        "state": "active",
        "instructions": "Prepare {{week}}.",
        "riskClass": "local-draft",
        "capabilities": ["agent-context"],
        "inputs": [{"id":"week","description":"Week","required":true,"default":"current"}],
        "triggers": [{"id":"openclaw-schedule","type":"schedule","enabled":true,"schedule":"0 9 * * 1","timezone":"America/Los_Angeles"}],
        "file": "/tmp/workflows/weekly-review.org2",
        "legacyLocation": false,
        "createdAt": "2026-07-17T00:00:00.000Z",
        "updatedAt": "2026-07-17T00:00:00.000Z"
      }]
    }
    """#.utf8)

    let workflow = try XCTUnwrap(JSONDecoder().decode(AgentWorkflowListPayload.self, from: data).workflows.first)
    XCTAssertEqual(workflow.id, "weekly-review")
    XCTAssertEqual(workflow.inputs.first?.default, "current")
    XCTAssertEqual(workflow.scheduleSummary, "0 9 * * 1 · America/Los_Angeles")
    XCTAssertFalse(workflow.legacyLocation)
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

  func testRunCenterKeepsMultipleMeetingOutcomesIndependentlyVisible() throws {
    let meetingRef = "meetings/2026-07-17-080044-dev-standup.org2"
    let envelope = try makeRun(
      id: "meeting-workflow",
      goal: "Turn a provenance-preserving meeting capture into cited decisions and reviewable tasks",
      status: "blocked",
      workflowId: "meeting-to-controlled-execution",
      contextRefs: [meetingRef]
    )
    let feedbackDigest = try makeRun(
      id: "feedback-digest",
      goal: "Set up the Tuesday/Friday customer-feedback digest",
      status: "blocked",
      parentRunId: envelope.id
    )
    let runnerDocs = try makeRun(
      id: "runner-docs",
      goal: "Document hosted versus self-hosted runner recovery",
      status: "completed",
      contextRefs: [meetingRef]
    )

    let runs = [feedbackDigest, envelope, runnerDocs]
    let sections = RunCenterPresentation.sections(
      for: AgentRunScope.all.entries(in: runs),
      allRuns: runs
    )

    let section = try XCTUnwrap(sections.first)
    XCTAssertEqual(sections.count, 1)
    XCTAssertEqual(section.sourceMeeting?.displayTitle, "Dev Standup · 2026-07-17")
    XCTAssertEqual(section.entries.map(\.id), ["feedback-digest", "meeting-workflow", "runner-docs"])
    XCTAssertEqual(section.entries.map(\.run.goal), [
      "Set up the Tuesday/Friday customer-feedback digest",
      "Turn a provenance-preserving meeting capture into cited decisions and reviewable tasks",
      "Document hosted versus self-hosted runner recovery",
    ])
    XCTAssertEqual(section.entries.map(\.run.status), ["blocked", "blocked", "completed"])
  }

  func testRunCenterResolvesSharedAncestorContextOnceForLargeRunFamilies() throws {
    let meetingRef = "meetings/2026-07-17-080044-dev-standup.org2"
    let envelope = try makeRun(
      id: "meeting-workflow",
      goal: "Process the meeting",
      contextRefs: [meetingRef]
    )
    let children = try (0..<1_000).map { index in
      try makeRun(
        id: "child-\(index)",
        goal: "Child outcome \(index)",
        parentRunId: envelope.id
      )
    }

    let contexts = RunCenterPresentation.sourceMeetingContextsByRunID(
      in: children + [envelope]
    )

    XCTAssertEqual(contexts.count, children.count + 1)
    XCTAssertEqual(contexts["child-999"]?.ref, meetingRef)
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

  func testRunningRunDoesNotNeedAttentionWhileReviewSignalsRemain() throws {
    let run = try makeRun(
      status: "running",
      validationStatus: "warning",
      reviewRequired: true
    )

    XCTAssertFalse(run.needsAttention)
    XCTAssertFalse(run.isFinished)
    XCTAssertEqual(AgentRunScope.active.entries(in: [run]).map(\.id), [run.id])
    XCTAssertTrue(AgentRunScope.attention.entries(in: [run]).isEmpty)
  }

  func testCompletedRunDoesNotNeedAttentionWhenOldReviewSignalsRemain() throws {
    let run = try makeRun(
      status: "completed",
      validationStatus: "warning",
      reviewRequired: true,
      pendingApproval: true
    )

    XCTAssertFalse(run.needsAttention)
    XCTAssertTrue(run.isFinished)
    XCTAssertEqual(run.attentionValidations.map(\.status), ["warning"])
    XCTAssertTrue(run.actionablePendingApprovals.isEmpty)
    XCTAssertEqual(run.retainedPendingApprovals.map(\.id), ["approval-1"])
  }

  func testRunCenterScopeCountsUseTheSamePredicatesAsTheirLists() throws {
    let runs = try [
      makeRun(id: "queued", goal: "Queued work", status: "queued"),
      makeRun(id: "approval", goal: "Approval work", status: "waiting-approval"),
      makeRun(id: "blocked", goal: "Blocked work", status: "blocked"),
      makeRun(id: "failed", goal: "Failed work", status: "failed"),
      makeRun(
        id: "completed",
        goal: "Completed work",
        status: "completed",
        validationStatus: "warning",
        reviewRequired: true
      ),
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
  func testMeetingSourceContextOpensInsideRunCenter() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-meeting-context-\(UUID().uuidString)", isDirectory: true)
    let meetings = root.appendingPathComponent("meetings", isDirectory: true)
    try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let meeting = meetings.appendingPathComponent("2026-07-17-080044-dev-standup.org2")
    try "#+TITLE: Meeting: Dev Standup\n".write(to: meeting, atomically: true, encoding: .utf8)
    let run = try makeRun(contextRefs: ["meetings/2026-07-17-080044-dev-standup.org2"])
    let context = try XCTUnwrap(run.sourceMeetingContext)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)

    store.openAgentRunContext(context)

    XCTAssertEqual(store.selectedLocation?.file, meeting.path)
    XCTAssertEqual(store.selectedSurface, .approvals)
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
  func testAskAIAboutAgentRunStartsChatWithDurableRecordContext() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-ask-ai-\(UUID().uuidString)", isDirectory: true)
    let runs = root.appendingPathComponent(".org2/runs", isDirectory: true)
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "#+TITLE: Durable run\n".write(
      to: runs.appendingPathComponent("run-1.org2"),
      atomically: true,
      encoding: .utf8
    )

    let suiteName = "org2-run-ask-ai-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.openClawRemoteCorpusPath = "/remote/org2"

    store.askOpenClawAboutAgentRun(try makeRun())

    XCTAssertEqual(store.selectedSurface, .openClaw)
    XCTAssertEqual(store.openClawChatThreads.first?.title, "Run: Prepare a cited briefing")
    XCTAssertEqual(
      store.openClawDraft,
      "Use agent run “Prepare a cited briefing” at /remote/org2/.org2/runs/run-1.org2:1 as context.\n\n"
    )
    XCTAssertEqual(store.openClawStatusText, "Added .org2/runs/run-1.org2:1 to OpenClaw")
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
    XCTAssertNil(store.errorText, store.errorText ?? "")
    let run = try XCTUnwrap(store.agentRuns.first)

    store.selectAgentRun(run)
    XCTAssertEqual(store.presentedAgentRun?.id, run.id)
    XCTAssertNil(store.selectedLocation)
    XCTAssertEqual(store.selectedSurface, .approvals)

    var repeatedSelectionPublishCount = 0
    let repeatedSelectionCancellable = store.objectWillChange.sink {
      repeatedSelectionPublishCount += 1
    }
    store.selectAgentRun(run)
    XCTAssertEqual(repeatedSelectionPublishCount, 0)
    repeatedSelectionCancellable.cancel()

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
    workflowId: String? = nil,
    parentRunId: String? = nil,
    contextRefs: [String] = [],
    blockedReason: String? = nil,
    validationStatus: String? = nil,
    reviewRequired: Bool = false,
    pendingApproval: Bool = false,
    updatedAt: String = "2026-07-14T00:01:00.000Z"
  ) throws -> AgentRunItem {
    var value: [String: Any] = [
      "id": id,
      "goal": goal,
      "acceptanceCriteria": [],
      "status": status,
      "riskClass": "local-draft",
      "capabilities": [],
      "context": contextRefs.map { ["ref": $0] },
      "plan": [],
      "artifacts": reviewRequired ? [[
        "id": "artifact-1",
        "path": "views/output.org2",
        "role": "report",
        "reviewStatus": "review-required",
        "createdAt": "2026-07-14T00:00:00.000Z"
      ]] : [],
      "approvals": pendingApproval ? [[
        "id": "approval-1",
        "title": "Approve output",
        "action": "publish output",
        "riskClass": "external-action",
        "status": "pending",
        "requestedAt": "2026-07-14T00:00:00.000Z"
      ]] : [],
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
    if let workflowId { value["workflowId"] = workflowId }
    if let parentRunId { value["parentRunId"] = parentRunId }
    if let blockedReason { value["blockedReason"] = blockedReason }
    return try JSONDecoder().decode(
      AgentRunItem.self,
      from: JSONSerialization.data(withJSONObject: value)
    )
  }
}
