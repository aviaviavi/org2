import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceQuitCoordinatorTests: XCTestCase {
  func testActiveWorkRequiresConfirmationAndSecondQuitOverrides() async {
    var prompts: [WorkspaceQuitCoordinator.Prompt] = []
    var saves = 0
    var quits = 0
    let coordinator = WorkspaceQuitCoordinator(deadline: .seconds(5), save: { saves += 1; return true },
      showPrompt: { prompts.append($0) }, quit: { quits += 1 })
    coordinator.requestQuit(hasActiveWork: true)
    XCTAssertEqual(prompts, [.activeWork])
    XCTAssertEqual(saves, 0)
    coordinator.requestQuit(hasActiveWork: true)
    XCTAssertEqual(quits, 1)
    coordinator.respond(to: .activeWork, quit: true)
    XCTAssertEqual(quits, 1)
  }

  func testKeepOpenAllowsAnotherAttempt() {
    var prompts = 0
    let coordinator = WorkspaceQuitCoordinator(deadline: .seconds(5), save: { true },
      showPrompt: { _ in prompts += 1 }, quit: { XCTFail("Cancelled quit") })
    coordinator.requestQuit(hasActiveWork: true)
    coordinator.respond(to: .activeWork, quit: false)
    coordinator.requestQuit(hasActiveWork: true)
    XCTAssertEqual(prompts, 2)
    coordinator.respond(to: .activeWork, quit: false)
  }

  func testFailedSaveOffersVisibleOverride() async {
    let prompt = expectation(description: "Save failure visible")
    var quits = 0
    let coordinator = WorkspaceQuitCoordinator(deadline: .seconds(5), save: { false },
      showPrompt: { XCTAssertEqual($0, .saveFailed); prompt.fulfill() }, quit: { quits += 1 })
    coordinator.requestQuit(hasActiveWork: false)
    await fulfillment(of: [prompt], timeout: 1)
    XCTAssertEqual(quits, 0)
    coordinator.respond(to: .saveFailed, quit: true)
    XCTAssertEqual(quits, 1)
  }

  func testConfirmedQuitDoesNotWaitForUncooperativeSave() async {
    let quit = expectation(description: "Bounded quit")
    var continuation: CheckedContinuation<Bool, Never>?
    var quits = 0
    let coordinator = WorkspaceQuitCoordinator(deadline: .milliseconds(20),
      save: { await withCheckedContinuation { continuation = $0 } },
      showPrompt: { XCTAssertEqual($0, .activeWork) },
      quit: { quits += 1; quit.fulfill() })
    coordinator.requestQuit(hasActiveWork: true)
    coordinator.respond(to: .activeWork, quit: true)
    await fulfillment(of: [quit], timeout: 1)
    continuation?.resume(returning: false)
    await Task.yield()
    XCTAssertEqual(quits, 1)
  }

  func testSlowSaveOffersWaitingThenSecondQuitOverrides() async {
    let prompt = expectation(description: "Slow save visible")
    var continuation: CheckedContinuation<Bool, Never>?
    var quits = 0
    let coordinator = WorkspaceQuitCoordinator(deadline: .milliseconds(20),
      save: { await withCheckedContinuation { continuation = $0 } },
      showPrompt: { XCTAssertEqual($0, .saveTakingTooLong); prompt.fulfill() },
      quit: { quits += 1 })
    coordinator.requestQuit(hasActiveWork: false)
    await fulfillment(of: [prompt], timeout: 1)
    coordinator.respond(to: .saveTakingTooLong, quit: false)
    XCTAssertEqual(quits, 0)
    coordinator.requestQuit(hasActiveWork: false)
    XCTAssertEqual(quits, 1)
    continuation?.resume(returning: true)
    await Task.yield()
    XCTAssertEqual(quits, 1)
  }

  func testSuccessfulSaveQuitsWithoutPrompt() async {
    let quit = expectation(description: "Saved")
    let coordinator = WorkspaceQuitCoordinator(deadline: .seconds(5), save: { true },
      showPrompt: { _ in XCTFail("Unexpected prompt") }, quit: { quit.fulfill() })
    coordinator.requestQuit(hasActiveWork: false)
    await fulfillment(of: [quit], timeout: 1)
  }
}
