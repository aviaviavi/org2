import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceListSelectionTests: XCTestCase {
  func testPrimaryWorkspaceViewsKeepPaneLocalRefreshActions() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentViewSource, encoding: .utf8)

    XCTAssertTrue(source.contains(#"Label("Refresh All", systemImage: "arrow.clockwise")"#))
    XCTAssertTrue(source.contains("Task { await store.refreshCorpusFiles() }"))
    XCTAssertTrue(source.contains("Task { await store.refreshAgentRuns(updatesStatus: true) }"))
    XCTAssertTrue(source.contains("Task { await store.refreshApprovals(updatesStatus: true) }"))
    XCTAssertTrue(source.contains("Task { await store.refreshAgentWorkflows(updatesStatus: true) }"))
    XCTAssertTrue(source.contains("Task { await store.refreshMeetings() }"))
    XCTAssertTrue(source.contains("if let error = store.approvalLoadErrorText"))
    XCTAssertFalse(source.contains("Use the toolbar Refresh to retry."))
  }

  func testVerticallyStackedNodeContextPaneHasNoLeadingDividerOverlay() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentViewSource, encoding: .utf8)
    let contextPaneStart = try XCTUnwrap(source.range(of: "private struct NodeContextPane: View"))
    let overviewStart = try XCTUnwrap(
      source.range(of: "private struct NodeContextOverview: View", range: contextPaneStart.upperBound..<source.endIndex)
    )
    let contextPane = source[contextPaneStart.lowerBound..<overviewStart.lowerBound]

    XCTAssertFalse(
      contextPane.contains(".overlay(alignment: .leading)"),
      "The Context pane is stacked below the document; an unconstrained leading Divider resolves horizontally and draws a line through the pane"
    )
  }

  func testIOSNotificationOpenUsesStableTranscriptPresentationLifecycle() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let mobileRemoteViews = packageRoot
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("ios/Org2Mobile/Org2Mobile/MobileRemoteViews.swift")
    let source = try String(contentsOf: mobileRemoteViews, encoding: .utf8)

    XCTAssertTrue(source.contains(".task(id: remote.threadDetail?.thread.id)"))
    XCTAssertFalse(source.contains("loadingView(detailIsAvailable: true)\n            .task"))
    XCTAssertTrue(
      source.contains(
        "openPendingReplyIfNeeded()\n          await remote.refresh()\n          openPendingReplyIfNeeded()"
      )
    )
  }

  func testIOSSharedRoomProgressUsesTheActiveDestinationName() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let mobileRemoteViews = packageRoot
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("ios/Org2Mobile/Org2Mobile/MobileRemoteViews.swift")
    let source = try String(contentsOf: mobileRemoteViews, encoding: .utf8)

    XCTAssertTrue(source.contains("detail.activeDestinationName"))
    XCTAssertTrue(source.contains("return activeDestinationName"))
  }

  func testMeetingAutomationIsDiscoverableOnlyInMeetingSettings() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let meetingSettingsSource = packageRoot
      .appendingPathComponent("Sources/Org2Workspace/MobileRemoteSettingsView.swift")
    let aiChatSettingsSource = packageRoot
      .appendingPathComponent("Sources/Org2Workspace/AIChatSettingsView.swift")
    let meetingSettings = try String(contentsOf: meetingSettingsSource, encoding: .utf8)
    let aiChatSettings = try String(contentsOf: aiChatSettingsSource, encoding: .utf8)

    XCTAssertTrue(meetingSettings.contains(#"Label("Meeting Automation", systemImage: "calendar.badge.clock")"#))
    XCTAssertTrue(meetingSettings.contains("Process every completed meeting"))
    XCTAssertTrue(meetingSettings.contains("saveMeetingReadyAutomationConfiguration"))
    XCTAssertFalse(aiChatSettings.contains("Meeting Automation"))
    XCTAssertFalse(aiChatSettings.contains("Process every completed meeting"))
  }

  func testOpeningSettingsDoesNotSynchronouslyProbeTheTranscriptionRuntime() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let settingsSource = packageRoot
      .appendingPathComponent("Sources/Org2Workspace/MobileRemoteSettingsView.swift")
    let settings = try String(contentsOf: settingsSource, encoding: .utf8)
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let contentView = try String(contentsOf: contentViewSource, encoding: .utf8)

    XCTAssertFalse(settings.contains(".onAppear {\n      store.refreshAudioSettingsStatus()"))
    XCTAssertTrue(contentView.contains("Task { await store.refreshAudioSettingsStatusAsync() }"))
  }

  func testFluidVoiceSetupConnectsAutomaticallyAndKeepsTheEndpointAdvanced() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentViewSource, encoding: .utf8)

    XCTAssertTrue(source.contains(".task(id: store.meetingTranscriptionProvider)"))
    XCTAssertTrue(source.contains("await store.connectFluidVoice()"))
    XCTAssertTrue(source.contains(#"Label("Connect Fluid Voice", systemImage: "bolt.horizontal.circle")"#))
    XCTAssertTrue(source.contains(#"DisclosureGroup("Advanced")"#))
    XCTAssertFalse(source.contains("Enable Fluid Voice Local API"))
  }

  func testRenderedApprovalTitleAndActionRemainSelectable() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentViewSource, encoding: .utf8)

    XCTAssertTrue(
      source.contains(
        """
        Text(approval.title)
                            .font(.body.weight(.semibold))
                            .textSelection(.enabled)
        """
      )
    )
    XCTAssertTrue(
      source.contains(
        """
        Text(approval.action)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
        """
      ),
      "The full rendered approval body must support drag selection and standard Copy"
    )
  }

  func testCommandNStartsANewAIThreadInsteadOfOpeningAnotherWindow() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSource = packageRoot
      .appendingPathComponent("Sources/Org2Workspace/Org2WorkspaceApp.swift")
    let source = try String(contentsOf: appSource, encoding: .utf8)

    XCTAssertTrue(source.contains("CommandGroup(replacing: .newItem)"))
    XCTAssertTrue(source.contains("Button(\"New AI Thread\")"))
    XCTAssertTrue(source.contains("store.createAIChatThread()"))
    XCTAssertTrue(source.contains("store.makeSurfacePrimary(.openClaw)"))
    XCTAssertTrue(source.contains(#".keyboardShortcut("n", modifiers: [.command])"#))
  }

  func testGlobalSearchFocusWaitsForTheCachedSurfaceToAttach() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentViewSource, encoding: .utf8)

    XCTAssertTrue(source.contains(".task(id: store.searchFocusToken)"))
    XCTAssertTrue(source.contains(
      """
      isSearchFocused = false
            await Task.yield()
            guard !Task.isCancelled, store.selectedSurface == .search else { return }
            isSearchFocused = true
      """
    ))
  }

  func testAppActivationDoesNotInvalidateTheEntireWorkspaceView() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSource = packageRoot
      .appendingPathComponent("Sources/Org2Workspace/Org2WorkspaceApp.swift")
    let source = try String(contentsOf: appSource, encoding: .utf8)

    XCTAssertFalse(source.contains(#"@Environment(\.scenePhase)"#))
    XCTAssertTrue(source.contains("NSApplication.didBecomeActiveNotification"))
    XCTAssertTrue(source.contains("refreshImmediately: false"))
  }

  func testPerpetualActivityMotionDoesNotDriveTheSwiftUIFrameClock() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcesRoot = packageRoot.appendingPathComponent("Sources", isDirectory: true)
    let sourceFiles = try XCTUnwrap(
      FileManager.default.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: nil
      )?.allObjects as? [URL]
    )
    var offenders: [String] = []

    for sourceFile in sourceFiles where sourceFile.pathExtension == "swift" {
      let source = try String(contentsOf: sourceFile, encoding: .utf8)
      if source.contains("TimelineView(") || source.contains(".repeatForever(") {
        offenders.append(sourceFile.path.replacingOccurrences(of: packageRoot.path + "/", with: ""))
      }
    }

    XCTAssertTrue(
      offenders.isEmpty,
      "SwiftUI clocks and perpetual animations relayout the full workspace and delay app activation; use compositor-backed Core Animation or a local AppKit timer instead: \(offenders.joined(separator: ", "))"
    )
  }

  func testMainWorkspaceAvoidsUnreadableNativeListSelection() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcesRoot = packageRoot.appendingPathComponent("Sources", isDirectory: true)
    let nativeSelection = try NSRegularExpression(
      pattern: #"\bList\s*\(\s*selection\s*:"#,
      options: []
    )
    let sourceFiles = try XCTUnwrap(
      FileManager.default.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: nil
      )?.allObjects as? [URL]
    )
    var offenders: [String] = []
    for sourceFile in sourceFiles where sourceFile.pathExtension == "swift" {
      let source = try String(contentsOf: sourceFile, encoding: .utf8)
      if nativeSelection.firstMatch(
        in: source,
        options: [],
        range: NSRange(source.startIndex..., in: source)
      ) != nil {
        offenders.append(sourceFile.path.replacingOccurrences(of: packageRoot.path + "/", with: ""))
      }
    }

    XCTAssertTrue(
      offenders.isEmpty,
      "Use readable explicit selection instead of native List selection highlighting: \(offenders.joined(separator: ", "))"
    )
  }

  func testSidebarSelectionAddsVerticalPaddingWithoutChangingOtherLists() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentView = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentView, encoding: .utf8)

    XCTAssertTrue(
      source.contains(
        """
        ReadableListSelectionModifier(
                        isSelected: store.selectedSurface == surface,
                        verticalPadding: 4
                      )
        """
      )
    )
    XCTAssertTrue(source.contains("var verticalPadding: CGFloat = 0"))
    XCTAssertEqual(
      source.components(separatedBy: ".workspaceSelectableRow(").count - 1,
      7,
      "Every selected-row implementation should use the shared gutter and marker chrome"
    )
    XCTAssertFalse(source.contains("WorkspaceSelectionMarker()"))
  }

  func testOrgSyntaxMarkersStayCompact() {
    XCTAssertEqual(WorkspaceSyntax.selectionMarker, "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 0), "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 1), "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 2), "**")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 8), "***")
    XCTAssertEqual(WorkspaceDesign.selectionMarkerGutterWidth, 22)
    XCTAssertEqual(WorkspaceDesign.selectionMarkerVerticalOffset, -1)
  }

  func testSettledThreadDisclosurePreservesTheUsersChoice() {
    XCTAssertFalse(
      OpenClawSettledThreadDisclosure.updated(isExpanded: false, settledThreadCount: 3)
    )
    XCTAssertTrue(
      OpenClawSettledThreadDisclosure.updated(isExpanded: true, settledThreadCount: 4)
    )
    XCTAssertFalse(
      OpenClawSettledThreadDisclosure.updated(isExpanded: true, settledThreadCount: 0)
    )
  }

  func testSettledThreadPaginationLoadsBoundedBatches() {
    XCTAssertEqual(OpenClawSettledThreadPagination.pageSize, 30)
    XCTAssertEqual(
      OpenClawSettledThreadPagination.nextLimit(currentLimit: 30, totalCount: 253),
      60
    )
    XCTAssertEqual(
      OpenClawSettledThreadPagination.nextLimit(currentLimit: 240, totalCount: 253),
      253
    )
    XCTAssertEqual(
      OpenClawSettledThreadPagination.clampedLimit(currentLimit: 90, totalCount: 25),
      25
    )
    XCTAssertEqual(
      OpenClawSettledThreadPagination.moreTitle(currentLimit: 240, totalCount: 253),
      "Show 13 more · 13 remaining"
    )
  }

  func testReopenedThreadGetsAFreshSidebarRowIdentity() {
    let threadID = UUID()
    let activeThread = OpenClawChatThread(
      id: threadID,
      title: "Thread",
      sessionKey: "agent:main:thread"
    )
    let settledThread = activeThread.replacingOpenClawChatMetadata(
      isArchived: true,
      settledAt: .some(Date(timeIntervalSince1970: 1_700_000_000))
    )

    XCTAssertNotEqual(
      OpenClawSidebarThreadRowIdentity(thread: activeThread, isSending: false),
      OpenClawSidebarThreadRowIdentity(thread: settledThread, isSending: false)
    )
    XCTAssertFalse(OpenClawSidebarThreadRowIdentity(thread: activeThread, isSending: false).isSettled)
    XCTAssertTrue(OpenClawSidebarThreadRowIdentity(thread: settledThread, isSending: false).isSettled)
  }

  func testFinishedThreadGetsAFreshSidebarRowIdentity() {
    let thread = OpenClawChatThread(
      title: "Thread",
      sessionKey: "agent:main:thread"
    )

    XCTAssertNotEqual(
      OpenClawSidebarThreadRowIdentity(thread: thread, isSending: true),
      OpenClawSidebarThreadRowIdentity(thread: thread, isSending: false)
    )
  }

  func testSelectingAnotherWorkingThreadTransfersTheActivityAnimationHost() {
    let thread = OpenClawChatThread(
      title: "Thread",
      sessionKey: "agent:main:thread"
    )

    XCTAssertNotEqual(
      OpenClawSidebarThreadRowIdentity(
        thread: thread,
        isSending: true,
        isSelected: true
      ),
      OpenClawSidebarThreadRowIdentity(
        thread: thread,
        isSending: true,
        isSelected: false
      )
    )
  }

  func testChatSidebarSummaryDoesNotRetainTranscriptContent() {
    let threadID = UUID()
    let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let firstThread = OpenClawChatThread(
      id: threadID,
      title: "Thread",
      updatedAt: updatedAt,
      sessionKey: "agent:main:thread",
      messages: [
        OpenClawChatMessage(role: .assistant, content: String(repeating: "a", count: 10_000))
      ]
    )
    let secondThread = OpenClawChatThread(
      id: threadID,
      title: "Thread",
      updatedAt: updatedAt,
      sessionKey: "agent:main:thread",
      messages: [
        OpenClawChatMessage(role: .assistant, content: String(repeating: "b", count: 10_000))
      ]
    )

    XCTAssertEqual(
      OpenClawSidebarThreadSummary(thread: firstThread),
      OpenClawSidebarThreadSummary(thread: secondThread),
      "Sidebar redraws should compare compact row metadata instead of entire transcript payloads"
    )
  }

  func testChatThreadContextMenusStayBoundToTheirOwnRow() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentView = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentView, encoding: .utf8)

    XCTAssertFalse(source.contains("contextualThreadID"))
    XCTAssertFalse(source.contains("contextThread:"))
    XCTAssertTrue(source.contains("rename(summary.id)"))
    XCTAssertTrue(source.contains("OpenClawSidebarThreadContextMenuTarget("))
    XCTAssertTrue(source.contains("NSApp.currentEvent?.type == .rightMouseDown"))
    XCTAssertTrue(source.contains("rename?(threadID)"))
    XCTAssertTrue(source.contains("presenting: renameRequest"))
    XCTAssertTrue(source.contains("let threadID = request.threadID"))
    XCTAssertTrue(source.contains("store.renameOpenClawChatThread(threadID, title: title)"))
    XCTAssertGreaterThanOrEqual(
      source.components(separatedBy: "renameRequest = nil").count - 1,
      2,
      "Both cancel and commit must clear the previous rename request explicitly"
    )
    XCTAssertEqual(
      source.components(separatedBy: #".alert("Rename Thread""#).count - 1,
      0,
      "Thread rows must not each install an alert; SwiftUI can hoist the first pinned row's alert"
    )
    XCTAssertTrue(source.contains("if summary.isSettled"))
  }
}
