import Combine
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspacePerformanceRegressionTests: XCTestCase {
  func testLiveChatCoalescesTokenBurstsIntoOnePublication() async throws {
    let liveState = OpenClawChatLiveState()
    let threadID = UUID()
    var publicationCount = 0
    let observation = liveState.objectWillChange.sink {
      publicationCount += 1
    }
    defer { observation.cancel() }

    for _ in 0..<100 {
      liveState.noteEvent(for: threadID, coalesced: true)
      liveState.appendStreamingDelta("x", for: threadID)
      liveState.appendReasoningDelta("r", for: threadID)
    }

    XCTAssertEqual(liveState.streamingReply(for: threadID), String(repeating: "x", count: 100))
    XCTAssertEqual(liveState.reasoning(for: threadID), String(repeating: "r", count: 100))
    XCTAssertEqual(publicationCount, 0)

    try await Task.sleep(
      nanoseconds: OpenClawChatLiveState.streamPublishIntervalNanoseconds + 40_000_000
    )

    XCTAssertEqual(publicationCount, 1)
    XCTAssertEqual(liveState.streamingReply(for: threadID), String(repeating: "x", count: 100))
    XCTAssertEqual(liveState.reasoning(for: threadID), String(repeating: "r", count: 100))
  }

  func testInteractionLatencyP95UsesTheSlowestFivePercentBoundary() {
    let samples = (1...100).map(Double.init)
    XCTAssertEqual(WorkspaceInteractionLatency.percentile95(samples), 95)
    XCTAssertEqual(WorkspaceInteractionLatency.percentile95([]), 0)
  }

  func testRuntimeIdentityReportsTheCompiledOptimizationMode() {
#if DEBUG
    XCTAssertEqual(WorkspaceRuntimeIdentity.compiledBuildConfiguration, "debug")
#else
    XCTAssertEqual(WorkspaceRuntimeIdentity.compiledBuildConfiguration, "release")
#endif
  }
}
