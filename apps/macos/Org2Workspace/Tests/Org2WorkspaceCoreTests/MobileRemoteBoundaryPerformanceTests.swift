import Foundation
import XCTest
@testable import Org2WorkspaceCore

private func mobileRemoteTestIsMainThread() -> Bool {
  Thread.isMainThread
}

private actor MobileRemoteDetachedWorkGate {
  private var didStart = false
  private var startedOnMainThread = false
  private var isOpen = false
  private var startWaiters: [CheckedContinuation<Bool, Never>] = []
  private var openWaiters: [CheckedContinuation<Void, Never>] = []

  func pause(startedOnMainThread: Bool) async {
    self.startedOnMainThread = startedOnMainThread
    didStart = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: startedOnMainThread)
    }
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      if isOpen {
        continuation.resume()
      } else {
        openWaiters.append(continuation)
      }
    }
  }

  func waitUntilStarted() async -> Bool {
    if didStart { return startedOnMainThread }
    return await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let waiters = openWaiters
    openWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private final class MobileRemoteWorkerThreadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Bool] = []

  func append(_ value: Bool) {
    lock.withLock {
      values.append(value)
    }
  }

  var recordedValues: [Bool] {
    lock.withLock { values }
  }
}

final class MobileRemoteBoundaryPerformanceTests: XCTestCase {
  func testMessagePreviewInspectsABoundedUnicodeSafePrefixAndHidesLargeAutomaticContext() throws {
    let reply = "✅ Ready. " + String(repeating: "界", count: 1_000_000)
    let assistant = OpenClawChatMessage(role: .assistant, content: reply)

    let assistantPreview = try XCTUnwrap(
      MobileRemoteMessagePreview.make(from: assistant, characterLimit: 220)
    )

    XCTAssertEqual(assistantPreview.text.count, 220)
    XCTAssertTrue(assistantPreview.text.hasPrefix("✅ Ready. "))
    XCTAssertTrue(assistantPreview.sourceWasTruncated)
    XCTAssertLessThanOrEqual(
      assistantPreview.sourceUTF8BytesInspected,
      MobileRemoteMessagePreview.sourceUTF8ByteLimit + 1
    )
    XCTAssertFalse(assistantPreview.text.contains("�"))

    let secret = String(repeating: "hidden-provider-prompt ", count: 120_000)
    let contextualUserMessage = OpenClawChatMessage(
      role: .user,
      content: """
      Use selected page “Roadmap” at notes/roadmap.org2 as context.
      #+begin_org2_ai_context
      \(secret)
      #+end_org2_ai_context

      What should change?
      """
    )
    let contextPreview = try XCTUnwrap(
      MobileRemoteMessagePreview.make(from: contextualUserMessage, characterLimit: 220)
    )

    XCTAssertEqual(contextPreview.text, "[Context: Roadmap]")
    XCTAssertFalse(contextPreview.text.contains("hidden-provider-prompt"))
    XCTAssertTrue(contextPreview.sourceWasTruncated)
    XCTAssertLessThanOrEqual(
      contextPreview.sourceUTF8BytesInspected,
      MobileRemoteMessagePreview.sourceUTF8ByteLimit + 1
    )
  }

  @MainActor
  func testLargeThreadListProjectionAndEncodingLeaveMainActorResponsive() async throws {
    let hugeReply = "List preview " + String(repeating: "x", count: 2_000_000)
    let threads = (0..<96).map { index in
      OpenClawChatThread(
        title: "Thread \(index)",
        sessionKey: "mobile-list-\(index)",
        messages: [OpenClawChatMessage(role: .assistant, content: hugeReply)]
      )
    }
    let context = MobileRemoteThreadProjectionContext(
      destinationNamesByID: [AIChatDestinationConfiguration.openClawID: "OpenClaw"],
      runningThreadIDs: [threads[0].id]
    )
    let gate = MobileRemoteDetachedWorkGate()
    let recorder = MobileRemoteWorkerThreadRecorder()
    let work = MobileRemoteBackgroundWork(
      beforeWork: {
        await gate.pause(startedOnMainThread: mobileRemoteTestIsMainThread())
      },
      didFinishWork: recorder.append
    )

    let responseTask = Task {
      await work.threadListResponse(threads: threads, context: context)
    }
    let listWorkStartedOnMainThread = await gate.waitUntilStarted()
    XCTAssertFalse(listWorkStartedOnMainThread)
    let mainActorPulse = await Task { @MainActor in true }.value
    XCTAssertTrue(mainActorPulse)

    await gate.open()
    let response = await responseTask.value
    let decoded = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteThreadList.self,
      from: response.body
    )

    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(decoded.threads.count, threads.count)
    XCTAssertEqual(decoded.threads.first?.preview?.count, 180)
    XCTAssertEqual(decoded.threads.first?.isRunning, true)
    XCTAssertLessThan(response.body.count, 100_000)
    XCTAssertEqual(recorder.recordedValues, [false])
  }

  @MainActor
  func testLargeThreadDetailProjectionAndEncodingLeaveMainActorResponsiveAndPreserveFullText() async throws {
    let hugeReply = "Full detail " + String(repeating: "reply-body-", count: 240_000)
    let message = OpenClawChatMessage(
      role: .assistant,
      content: hugeReply,
      authorDestinationID: AIChatDestinationConfiguration.openClawID
    )
    let thread = OpenClawChatThread(
      title: "Large detail",
      sessionKey: "mobile-detail",
      messages: [message]
    )
    let threadContext = MobileRemoteThreadProjectionContext(
      destinationNamesByID: [AIChatDestinationConfiguration.openClawID: "OpenClaw"],
      runningThreadIDs: [thread.id]
    )
    let detailContext = MobileRemoteThreadDetailProjectionContext(
      threads: threadContext,
      activeDestinationName: "OpenClaw",
      streamingReply: String(repeating: "s", count: 32 * 1_024),
      reasoning: String(repeating: "r", count: 32 * 1_024),
      activities: [],
      connectionState: "connected",
      connectionDetail: nil
    )
    let gate = MobileRemoteDetachedWorkGate()
    let recorder = MobileRemoteWorkerThreadRecorder()
    let work = MobileRemoteBackgroundWork(
      beforeWork: {
        await gate.pause(startedOnMainThread: mobileRemoteTestIsMainThread())
      },
      didFinishWork: recorder.append
    )

    let responseTask = Task {
      await work.threadDetailResponse(thread: thread, context: detailContext)
    }
    let detailWorkStartedOnMainThread = await gate.waitUntilStarted()
    XCTAssertFalse(detailWorkStartedOnMainThread)
    let mainActorPulse = await Task { @MainActor in true }.value
    XCTAssertTrue(mainActorPulse)

    await gate.open()
    let response = await responseTask.value
    let decoded = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteThreadDetail.self,
      from: response.body
    )

    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(decoded.messages.first?.content, hugeReply)
    XCTAssertEqual(decoded.messages.first?.authorDestinationName, "OpenClaw")
    XCTAssertEqual(decoded.streamingReply.count, 32 * 1_024)
    XCTAssertGreaterThan(response.body.count, hugeReply.utf8.count)
    XCTAssertEqual(recorder.recordedValues, [false])
  }

  @MainActor
  func testMultiMegabyteAttachmentDecodeValidationAndDigestLeaveMainActorResponsive() async throws {
    let attachmentData = Data(repeating: 0xa5, count: 4_500_000)
    let request = try await Task.detached {
      let body = try MobileRemoteProtocol.encoder().encode(
        MobileRemoteSendMessageRequest(
          content: "Inspect this image",
          attachments: [
            MobileRemoteAttachment(
              fileName: "../capture.png",
              mimeType: " image/png ",
              data: attachmentData
            )
          ],
          delivery: "followUp"
        )
      )
      return MobileRemoteHTTPRequest(
        method: "POST",
        path: "/v1/threads/example/messages",
        body: body
      )
    }.value
    let gate = MobileRemoteDetachedWorkGate()
    let recorder = MobileRemoteWorkerThreadRecorder()
    let work = MobileRemoteBackgroundWork(
      beforeWork: {
        await gate.pause(startedOnMainThread: mobileRemoteTestIsMainThread())
      },
      didFinishWork: recorder.append
    )

    let preparationTask = Task {
      try await work.prepareSendMessage(from: request)
    }
    let attachmentWorkStartedOnMainThread = await gate.waitUntilStarted()
    XCTAssertFalse(attachmentWorkStartedOnMainThread)
    let mainActorPulse = await Task { @MainActor in true }.value
    XCTAssertTrue(mainActorPulse)

    await gate.open()
    let prepared = try await preparationTask.value

    XCTAssertEqual(prepared.content, "Inspect this image")
    XCTAssertEqual(prepared.delivery, "followUp")
    XCTAssertEqual(prepared.attachments.count, 1)
    XCTAssertEqual(prepared.attachments.first?.fileName, "capture.png")
    XCTAssertEqual(prepared.attachments.first?.mimeType, "image/png")
    XCTAssertEqual(prepared.attachments.first?.byteCount, attachmentData.count)
    XCTAssertEqual(prepared.attachments.first?.data, attachmentData)
    XCTAssertEqual(recorder.recordedValues, [false])
  }
}
