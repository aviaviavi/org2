import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class OrgSyntaxTextEditorSelectionPerformanceTests: XCTestCase {
  func testClickNearEndOfLargeDocumentPublishesOnlyBoundedIndexedContextWithinFrame() throws {
    let text = String(repeating: "plain source line\n", count: 100_000) + "Discuss [[Sar"
    var selection = NSRange(location: 0, length: 0)
    var publishedSnapshot: OrgSyntaxTextEditorSelectionSnapshot?
    var completionMatch: ParagraphWikiLinkCompletionMatch?
    let editor = OrgSyntaxTextEditor(
      text: .constant(text),
      liveHighlighting: false,
      caretPublishingDelayMilliseconds: 0,
      selection: Binding(
        get: { selection },
        set: { selection = $0 }
      ),
      onSelectionSnapshot: { snapshot in
        publishedSnapshot = snapshot
        completionMatch = ParagraphWikiLinkCompletion.match(in: snapshot)
      }
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = OrgSyntaxTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
    textView.layoutManager?.allowsNonContiguousLayout = true
    textView.string = text
    coordinator.attach(to: textView)
    coordinator.resetLineIndex(from: textView)
    defer { coordinator.prepareForDismantle(textView) }

    let distantCaret = NSRange(location: textView.textStorage?.length ?? 0, length: 0)
    textView.setSelectedRange(distantCaret)

    let startedAt = CACurrentMediaTime()
    coordinator.textViewDidChangeSelection(Notification(
      name: NSTextView.didChangeSelectionNotification,
      object: textView
    ))
    let elapsed = CACurrentMediaTime() - startedAt

    let snapshot = try XCTUnwrap(publishedSnapshot)
    XCTAssertLessThan(
      elapsed,
      1.0 / 60.0,
      "A deep click must use the line index and a bounded text window within one frame"
    )
    XCTAssertEqual(selection, distantCaret)
    XCTAssertEqual(snapshot.sourceLine, 100_001)
    XCTAssertLessThanOrEqual(
      snapshot.localTextRange.length,
      OrgSyntaxTextEditor.Coordinator.selectionSnapshotLookbehindUTF16Length + 1
    )
    XCTAssertTrue(snapshot.localText.hasSuffix("Discuss [[Sar"))
    XCTAssertEqual(completionMatch?.query, "Sar")
    XCTAssertEqual(coordinator.fullDocumentSnapshotCount, 0)
    XCTAssertEqual(coordinator.mainActorFullDocumentSnapshotCount, 0)
  }
}
