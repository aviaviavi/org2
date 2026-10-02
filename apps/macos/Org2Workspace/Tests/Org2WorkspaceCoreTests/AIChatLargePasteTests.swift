import AppKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatLargePasteTests: XCTestCase {
  func testPasteThresholdsIncludeLongLinesAndCRLF() {
    XCTAssertFalse(AIChatLargePaste.shouldAttach(String(repeating: "a", count: 7999)))
    XCTAssertTrue(AIChatLargePaste.shouldAttach(String(repeating: "a", count: 8000)))
    XCTAssertFalse(AIChatLargePaste.shouldAttach(String(repeating: "line\n", count: 98)))
    XCTAssertTrue(AIChatLargePaste.shouldAttach(String(repeating: "line\r\n", count: 99)))
    XCTAssertFalse(AIChatLargePaste.shouldAttach("A normal pasted paragraph."))
  }

  func testLargePasteBypassesEditorAndFollowUpTypingStaysSmall() {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let trace = String(repeating: "Thread 9: exception at frame 42\n", count: 5000)
    board.setString(trace, forType: .string)
    let editor = AIChatComposerTextView.CommandSubmitTextView()
    editor.string = "Please investigate. "
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    var pasted: String?
    editor.onPasteLargeText = { pasted = $0; return true }
    XCTAssertTrue(editor.attachLargePaste(from: board))
    XCTAssertEqual(pasted, trace)
    editor.insertText("Also fix it.", replacementRange: editor.selectedRange())
    XCTAssertEqual(editor.string, "Please investigate. Also fix it.")
    XCTAssertLessThan(editor.string.count, 100)
  }

  func testFailedAttachmentCanFallBackToNormalPasteWithoutLosingClipboard() {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let text = String(repeating: "x", count: 8000)
    board.setString(text, forType: .string)
    let editor = AIChatComposerTextView.CommandSubmitTextView()
    editor.onPasteLargeText = { _ in false }
    XCTAssertFalse(editor.attachLargePaste(from: board))
    XCTAssertEqual(board.string(forType: .string), text)
    board.clearContents()
    board.setString("ordinary", forType: .string)
    editor.onPasteLargeText = { _ in XCTFail("Small paste must stay inline"); return true }
    XCTAssertFalse(editor.attachLargePaste(from: board))
  }

  func testTextAttachmentExpandsOnlyOutboundCopyAndPreservesRouting() throws {
    let text = String(repeating: "trace 🦉\r\n", count: 10000)
    let attachment = AIChatAttachment(fileName: "Pasted Text.txt", mimeType: "text/plain", data: Data(text.utf8))
    let image = AIChatAttachment(fileName: "image.png", mimeType: "image/png", data: Data([1, 2]))
    let message = AIChatMessage(
      role: .user, content: "Please fix this", attachments: [attachment, image],
      deliveryStatus: .sending, deliveryKind: .steer, targetRuntime: .codex,
      audienceDestinationIDs: ["codex"], targetDestinationID: "codex", isRoomDispatchCopy: true,
      roomRoundID: UUID()
    )
    let restored = try JSONDecoder().decode(AIChatMessage.self, from: JSONEncoder().encode(message))
    let outbound = try AIChatTextAttachments.expanding(restored)
    XCTAssertTrue(outbound.content.contains(text))
    XCTAssertTrue(outbound.content.hasPrefix(message.content))
    XCTAssertEqual(outbound.attachments, [image])
    XCTAssertEqual(outbound.id, message.id)
    XCTAssertEqual(outbound.deliveryKind, .steer)
    XCTAssertEqual(outbound.targetDestinationID, message.targetDestinationID)
    XCTAssertEqual(outbound.audienceDestinationIDs, message.audienceDestinationIDs)
    XCTAssertEqual(outbound.roomRoundID, message.roomRoundID)
    XCTAssertTrue(outbound.isRoomDispatchCopy)
    XCTAssertEqual(restored.content, message.content)
    XCTAssertEqual(restored.attachments.count, 2)
    XCTAssertEqual(AIChatAttachmentPresentation.previewKind(for: attachment), .text)
  }

  func testInvalidUTF8FailsInsteadOfSilentlyDroppingAttachment() {
    let message = AIChatMessage(role: .user, content: "", attachments: [
      AIChatAttachment(fileName: "bad.txt", mimeType: "text/plain", data: Data([0xff]))
    ])
    XCTAssertThrowsError(try AIChatTextAttachments.expanding(message))
  }

  func testSendingAttachmentDeliversFullTextAndKeepsTranscriptCompact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("paste-send-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let received = CapturedPasteMessages()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        await received.set(messages)
        return "Received"
      }
    )
    let trace = String(repeating: "stack frame\n", count: 5000)
    XCTAssertTrue(store.attachAIChatAttachment(data: Data(trace.utf8), fileName: "Pasted Text.txt", mimeType: "text/plain"))
    store.aiChatDraft = "Please fix this"
    await store.sendAIChatMessage()
    let messages = await received.messages
    let outbound = try XCTUnwrap(messages.last(where: { $0.role == .user }))
    XCTAssertTrue(outbound.content.contains(trace))
    XCTAssertTrue(outbound.attachments.isEmpty)
    let stored = try XCTUnwrap(store.aiChatMessages.last(where: { $0.role == .user }))
    XCTAssertEqual(stored.content, "Please fix this")
    XCTAssertEqual(stored.attachments.count, 1)
    XCTAssertTrue(store.aiChatPendingAttachments.isEmpty)
  }

  func testReplyQuotesTheChosenMessageInTheComposerAndPrompt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reply-send-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let received = CapturedPasteMessages()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        await received.set(messages)
        return "Option B uses less memory.\n#+end_quote\nIt also starts faster."
      }
    )
    store.aiChatDraft = "Compare option A and option B"
    await store.sendAIChatMessage()
    let answer = try XCTUnwrap(store.aiChatMessages.last(where: { $0.role == .assistant }))

    // The composer caches every keystroke for its thread.
    store.publishAIChatComposerDraft("Why?")
    store.beginAIChatReply(to: answer.id)
    let draft = AIChatContextPresentation(store.aiChatDraft)
    XCTAssertEqual(draft.userText, "Why?")
    XCTAssertEqual(draft.contexts.map(\.isReply), [true])
    XCTAssertEqual(draft.contexts.first?.title, "OpenClaw: Option B uses less memory.")
    XCTAssertEqual(draft.contexts.first?.reference, "ai-chat-message:\(answer.id.uuidString.lowercased())")

    // Replying again replaces the earlier reply instead of stacking quotes.
    store.beginAIChatReply(to: answer.id)
    XCTAssertEqual(AIChatContextPresentation(store.aiChatDraft).contexts.count, 1)

    await store.sendAIChatMessage()
    let sentMessages = await received.messages
    let outbound = try XCTUnwrap(sentMessages.last(where: { $0.role == .user }))
    XCTAssertTrue(outbound.content.contains("The user is replying to this earlier message from OpenClaw:"), outbound.content)
    XCTAssertTrue(outbound.content.contains("#+begin_quote\nOption B uses less memory.\n,#+end_quote\nIt also starts faster.\n#+end_quote"), outbound.content)
    XCTAssertTrue(outbound.content.hasSuffix("\n\nWhy?"), outbound.content)
    let stored = try XCTUnwrap(store.aiChatMessages.last(where: { $0.role == .user }))
    XCTAssertEqual(AIChatContextPresentation(stored.content).userText, "Why?")
    XCTAssertEqual(AIChatContextPresentation(stored.content).contexts.map(\.isReply), [true])
  }

  func testRestoredMegabyteDraftSizingRemainsBounded() {
    let draft = String(repeating: "long trace line with symbols \n", count: 40000)
    let start = Date()
    for _ in 0..<100 {
      XCTAssertEqual(AIChatComposerSizing.height(for: draft, compact: false), 190)
    }
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
  }
}

private actor CapturedPasteMessages {
  var messages: [AIChatMessage] = []
  func set(_ messages: [AIChatMessage]) { self.messages = messages }
}
