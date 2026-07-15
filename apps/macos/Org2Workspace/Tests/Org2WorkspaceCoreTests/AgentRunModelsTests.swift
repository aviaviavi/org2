import XCTest
@testable import Org2WorkspaceCore

final class AgentRunModelsTests: XCTestCase {
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
    XCTAssertEqual(run.progressText, "1/1 steps")
    XCTAssertTrue(run.needsAttention)
  }
}
