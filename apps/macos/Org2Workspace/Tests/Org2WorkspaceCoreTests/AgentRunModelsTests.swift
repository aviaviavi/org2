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
        "approvals": [{"id":"release","title":"Release","action":"publish","riskClass":"external-action","status":"pending","requirementId":"release-gate","requestedAt":"2026-07-14T00:00:00.000Z"}],
        "approvalRequirements": [{"id":"release-gate","title":"Release","action":"publish","riskClass":"external-action","requestedRole":"owner","beforeStepId":"draft"}],
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
    let requirement = try XCTUnwrap(run.declaredApprovalRequirements.first)
    XCTAssertEqual(run.approvalRequirement(for: try XCTUnwrap(run.approvals.first))?.id, "release-gate")
    XCTAssertEqual(run.approvalRequirementState(for: requirement), .pending)
    XCTAssertEqual(requirement.beforeStepId, "draft")
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
      "queueId": "run:run-1:approval-1",
      "nativeApprovalId": "approval-1",
      "fingerprint": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "binding": "native",
      "canApprove": false,
      "approvalBlockedReason": "Exact review material is required.",
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
      "action": "publish report",
      "riskClass": "external-action",
      "requestedRole": "owner",
      "requestedAt": "2026-07-21T00:00:00.000Z",
      "requirement": {
        "id": "release-gate",
        "title": "Approve report release",
        "action": "publish the reviewed report",
        "riskClass": "external-action",
        "requestedRole": "owner",
        "beforeStepId": "publish",
        "state": "pending"
      },
      "runId": "run-1",
      "runGoal": "Prepare report",
      "runStatus": "waiting-approval",
      "runPendingApprovalCount": 2,
      "runApprovalCount": 3,
      "runDecisionEffect": "Approving this leaves 1 other pending approval before the run can resume."
    }
    """#.utf8)

    let item = try JSONDecoder().decode(ApprovalItem.self, from: data)
    XCTAssertTrue(item.isRunApproval)
    XCTAssertEqual(item.id, "run:run-1:approval-1")
    XCTAssertEqual(item.sourceLabel, "Run run-1")
    XCTAssertEqual(item.runDependencyText, "Approving this leaves 1 other pending approval before the run can resume.")
    XCTAssertFalse(item.isApprovable)
    XCTAssertEqual(item.approvalBlockedReason, "Exact review material is required.")
    XCTAssertEqual(item.requirement?.id, "release-gate")
    XCTAssertEqual(item.requirement?.title, "Approve report release")
    XCTAssertEqual(item.requirement?.action, "publish the reviewed report")
    XCTAssertEqual(item.requirement?.riskClass, "external-action")
    XCTAssertEqual(item.requirement?.requestedRole, "owner")
    XCTAssertEqual(item.requirement?.beforeStepId, "publish")
    XCTAssertEqual(item.requirement?.state, .pending)
    XCTAssertTrue(item.boundReviewText.contains("Bound workflow approval requirement"))
    XCTAssertTrue(item.boundReviewText.contains("Required before step: publish"))
    XCTAssertTrue(item.matchesApprovalFilter("prepare report external-action"))
  }

  func testDerivesCurrentWorkflowApprovalRequirementStatesFromNewestBoundRequest() throws {
    let data = Data(#"""
    {
      "id": "requirement-states",
      "goal": "Exercise workflow approval requirements",
      "acceptanceCriteria": [],
      "status": "waiting-approval",
      "riskClass": "external-action",
      "capabilities": [],
      "context": [],
      "plan": [{"id":"publish","title":"Publish","kind":"tool","status":"pending"}],
      "artifacts": [],
      "approvals": [
        {"id":"release-v1","title":"Release","action":"publish","riskClass":"external-action","status":"rejected","requirementId":"release","requestedAt":"2026-07-25T00:00:00.000Z"},
        {"id":"release-v2","title":"Release","action":"publish","riskClass":"external-action","status":"pending","requirementId":"release","supersedesId":"release-v1","requestedAt":"2026-07-25T00:01:00.000Z"},
        {"id":"legal-v1","title":"Legal","action":"release","riskClass":"high-impact","status":"approved","requirementId":"legal","requestedAt":"2026-07-25T00:00:00.000Z"},
        {"id":"security-v1","title":"Security","action":"release","riskClass":"high-impact","status":"canceled","requirementId":"security","requestedAt":"2026-07-25T00:00:00.000Z"}
      ],
      "approvalRequirements": [
        {"id":"release","title":"Release","action":"publish","riskClass":"external-action","beforeStepId":"publish"},
        {"id":"legal","title":"Legal","action":"release","riskClass":"high-impact"},
        {"id":"security","title":"Security","action":"release","riskClass":"high-impact"},
        {"id":"finance","title":"Finance","action":"release","riskClass":"high-impact"}
      ],
      "validations": [],
      "comments": [],
      "events": [],
      "createdAt": "2026-07-25T00:00:00.000Z",
      "updatedAt": "2026-07-25T00:01:00.000Z"
    }
    """#.utf8)

    let run = try JSONDecoder().decode(AgentRunItem.self, from: data)
    let requirements = Dictionary(
      uniqueKeysWithValues: run.declaredApprovalRequirements.map { ($0.id, $0) }
    )
    XCTAssertEqual(
      run.currentApproval(for: try XCTUnwrap(requirements["release"]))?.id,
      "release-v2"
    )
    XCTAssertEqual(
      run.approvalRequirementState(for: try XCTUnwrap(requirements["release"])),
      .pending
    )
    XCTAssertEqual(
      run.approvalRequirementState(for: try XCTUnwrap(requirements["legal"])),
      .approved
    )
    XCTAssertEqual(
      run.approvalRequirementState(for: try XCTUnwrap(requirements["security"])),
      .denied
    )
    XCTAssertEqual(
      run.approvalRequirementState(for: try XCTUnwrap(requirements["finance"])),
      .unbound
    )
    XCTAssertTrue(
      try XCTUnwrap(requirements["release"]).reviewText(state: .pending)
        .contains("Required before step: publish")
    )
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
      "--note", "Publish the exact reviewed report.",
      "--material-json", #"{"kind":"artifact-release","target":"compiled/report.pdf","artifacts":[{"id":"report","sha256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}"#,
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
        "--note", "Send the exact reviewed draft \(index).",
        "--material-json", #"{"kind":"message","target":"reviewer@example.test","content":"Exact reviewed draft \#(index)."}"#,
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

  @MainActor
  func testRunCenterRejectionRequiresAndPersistsAuditReason() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-center-rejection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    _ = try await cli.run([
      "run", "create", "--id", "run-center-rejection", "--goal", "Send reviewed message",
      "--dir", root.path, "--json"
    ])
    _ = try await cli.run(["run", "start", "run-center-rejection", "--dir", root.path, "--json"])
    _ = try await cli.run([
      "run", "approval-request", "run-center-rejection",
      "--title", "Approve message", "--action", "send message",
      "--risk", "external-action", "--role", "approver", "--from", "Avi",
      "--material-json", #"{"kind":"message","target":"reviewer@example.test","content":"Exact reviewed message."}"#,
      "--dir", root.path, "--json"
    ])

    let store = WorkspaceStore(cli: cli)
    store.setCorpusRoot(root, persistsDefault: false)
    await store.refreshAgentRuns()
    let run = try XCTUnwrap(store.agentRuns.first)
    let approval = try XCTUnwrap(run.approvals.first)

    await store.decideAgentRunApproval(run, approval: approval, decision: "rejected")
    XCTAssertEqual(store.statusText, "Rejection reason required")
    XCTAssertEqual(store.errorText, "A rejection reason is required.")
    XCTAssertEqual(store.agentRuns.first?.approvals.first?.status, "pending")

    await store.decideAgentRunApproval(
      run,
      approval: approval,
      decision: "rejected",
      note: "Recipient and content are not correct."
    )

    let updatedApproval = try XCTUnwrap(store.agentRuns.first?.approvals.first)
    XCTAssertEqual(updatedApproval.status, "rejected")
    XCTAssertEqual(updatedApproval.decisionNote, "Recipient and content are not correct.")
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

  func testFreeFormLifecycleCommentDoesNotCreateApprovalAuthority() throws {
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
    XCTAssertTrue(run.approvals.isEmpty)
    XCTAssertEqual(
      run.comments.first?.body,
      "OPENCLAW_KEY: draft:exec:default:IC_example123\nOPENCLAW_KIND: external-draft"
    )
  }

  func testApprovalItemRendersTheCompleteBoundEnvelope() throws {
    let bodyTail = "BODY_TAIL_" + String(repeating: "x", count: 320)
    let pairedTail = "PAIRED_TAIL_" + String(repeating: "y", count: 320)
    let object: [String: Any] = [
      "kind": "headline",
      "queueId": "headline:approval-1",
      "fingerprint": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "binding": "legacy",
      "canApprove": true,
      "title": "Approve the exact launch message",
      "status": "draft-needs-review",
      "todo": "TODO",
      "level": 1,
      "file": "/tmp/corpus/review.org2",
      "line": 7,
      "idValue": "approval-1",
      "properties": [
        "ORG2_APPROVAL_ID": "approval-1",
        "PAIRED_SEND_TODO": "Send the exact launch message",
        "STATUS": "draft-needs-review",
      ],
      "body": "Review body\n\(bodyTail)",
      "tags": [],
      "action": "send launch message",
      "material": [
        "kind": "command",
        "target": "gateway",
        "content": "Exact content including a hidden tail: MATERIAL_TAIL",
        "command": [
          "text": "send launch message",
          "argv": ["/usr/local/bin/send", "--recipient", "reviewer@example.test"],
          "cwd": "/tmp/corpus",
        ],
        "runtimeTarget": [
          "system": "openclaw",
          "kind": "typed-tool",
          "id": "approval-1",
        ],
      ],
      "pairedAction": [
        "mode": "send",
        "title": "Send the exact launch message",
        "todo": "TODO",
        "properties": [
          "ASSIGNEE": "OpenClaw",
          "STATUS": "blocked",
        ],
        "body": "Paired action body\n\(pairedTail)",
      ],
    ]

    let data = try JSONSerialization.data(withJSONObject: object)
    let item = try JSONDecoder().decode(ApprovalItem.self, from: data)

    XCTAssertEqual(item.properties["PAIRED_SEND_TODO"], "Send the exact launch message")
    XCTAssertEqual(item.pairedAction?.properties["STATUS"], "blocked")
    XCTAssertGreaterThan(item.boundReviewText.count, 700)
    XCTAssertTrue(item.boundReviewText.contains(bodyTail))
    XCTAssertTrue(item.boundReviewText.contains("PAIRED_SEND_TODO: Send the exact launch message"))
    XCTAssertTrue(item.boundReviewText.contains(pairedTail))
    let materialText = try XCTUnwrap(item.material).reviewText
    XCTAssertTrue(materialText.contains("MATERIAL_TAIL"))
    XCTAssertTrue(materialText.contains("[2] reviewer@example.test"))
    XCTAssertTrue(materialText.contains("Working directory: /tmp/corpus"))
    XCTAssertTrue(materialText.contains("Runtime target: openclaw · typed-tool · approval-1"))
  }

  func testExactApprovalMaterialMirrorsCoreKindSpecificReviewability() throws {
    func material(_ json: String) throws -> AgentRunApprovalMaterialItem {
      try JSONDecoder().decode(AgentRunApprovalMaterialItem.self, from: Data(json.utf8))
    }

    XCTAssertFalse(try material(#"{"kind":"message","content":"Legacy content without a recipient"}"#).hasExactApprovalMaterial)
    XCTAssertTrue(try material(#"{"kind":"message","target":"reviewer@example.test","content":""}"#).hasExactApprovalMaterial)
    XCTAssertFalse(try material(#"{"kind":"command","command":{"text":"  "}}"#).hasExactApprovalMaterial)
    XCTAssertTrue(try material(#"{"kind":"command","command":{"text":"send --reviewed"}}"#).hasExactApprovalMaterial)
    XCTAssertFalse(try material(#"{"kind":"artifact-release","artifacts":[{"id":"report","sha256":"not-a-digest"}]}"#).hasExactApprovalMaterial)
    XCTAssertTrue(
      try material(
        #"{"kind":"artifact-release","artifacts":[{"id":"report","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}"#
      ).hasExactApprovalMaterial
    )
    XCTAssertFalse(
      try material(
        #"{"kind":"external-action","runtimeTarget":{"system":"openclaw","kind":"typed-tool","id":"approval-1"}}"#
      ).hasExactApprovalMaterial
    )
  }

  func testDecodesAndRendersInFlightApprovalEffectReservation() throws {
    let data = Data(#"""
    {
      "id": "approval-1",
      "title": "Send reviewed message",
      "action": "send",
      "riskClass": "external-action",
      "status": "approved",
      "fingerprint": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "requestedAt": "2026-07-25T00:00:00.000Z",
      "effectReservation": {
        "fingerprint": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "materialDigest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "toolCallId": "tool-call-42",
        "reservedAt": "2026-07-25T00:01:00.000Z"
      }
    }
    """#.utf8)

    let approval = try JSONDecoder().decode(AgentRunApprovalItem.self, from: data)
    XCTAssertEqual(approval.effectReservation?.toolCallId, "tool-call-42")
    XCTAssertEqual(approval.effectReservation?.reservedAt, "2026-07-25T00:01:00.000Z")
    XCTAssertEqual(
      approval.effectReservation?.materialDigest,
      "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    )
    let effectState = try XCTUnwrap(approval.effectStateText)
    XCTAssertTrue(effectState.contains("reconciliation is required"))
    XCTAssertTrue(effectState.contains("Tool call: tool-call-42"))
    XCTAssertTrue(effectState.contains("Fingerprint: sha256:aaaaaaaa"))
    XCTAssertTrue(effectState.contains("Material digest: sha256:bbbbbbbb"))
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
      reviewRequired: true
    )

    XCTAssertFalse(run.needsAttention)
    XCTAssertTrue(run.isFinished)
    XCTAssertEqual(run.attentionValidations.map(\.status), ["warning"])
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
    if let workflowId { value["workflowId"] = workflowId }
    if let parentRunId { value["parentRunId"] = parentRunId }
    if let blockedReason { value["blockedReason"] = blockedReason }
    return try JSONDecoder().decode(
      AgentRunItem.self,
      from: JSONSerialization.data(withJSONObject: value)
    )
  }
}
