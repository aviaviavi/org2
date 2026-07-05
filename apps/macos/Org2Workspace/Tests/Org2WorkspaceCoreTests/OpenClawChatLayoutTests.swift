import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class OpenClawChatLayoutTests: XCTestCase {
  func testAssistantBubbleExpandsVerticallyForWrappedText() throws {
    let message = OpenClawChatMessage(
      role: .assistant,
      content: """
      The raw version already has the bones of a very good essay. I'd expand facts and examples before editing prose: Scarf's production history, the AI workflow loop, concrete migration outcomes, and a constructive "what Haskell could become" section.
      """
    )
    let view = ChatBubbleView(message: message, compact: true)
      .frame(width: 540, alignment: .leading)
    let hostingView = NSHostingView(rootView: view)

    hostingView.frame = NSRect(x: 0, y: 0, width: 540, height: 1)
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertGreaterThan(hostingView.fittingSize.height, 118)
  }
}
