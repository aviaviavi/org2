import AppKit
import Org2WorkspaceCore
import SwiftUI
import WebKit

@main
struct Org2WorkspaceScreenshotRenderer {
  static func main() async {
    do {
      let outputPath = try outputPathArgument()
      let width = Double(ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_WIDTH"] ?? "") ?? 1400
      let height = Double(ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_HEIGHT"] ?? "") ?? 900
      let scale = Double(ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_SCALE"] ?? "") ?? 1
      let verifiesTabs = CommandLine.arguments.contains("--verify-tabs")
      let verifiesCodeCopy = CommandLine.arguments.contains("--verify-code-copy")

      _ = await MainActor.run {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
      }
      let defaults = UserDefaults(suiteName: "org2-workspace-screenshot-\(UUID().uuidString)") ?? .standard
      if verifiesCodeCopy {
        defaults.set(true, forKey: "Org2Workspace.openOrgLaunchGuideCompleted.v1")
      }
      let store = await MainActor.run {
        WorkspaceStore(defaults: defaults)
      }
      await store.bootstrap()
      await MainActor.run {
        let rawContextTab = ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_CONTEXT_TAB"]?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        if let rawContextTab,
           let contextTab = NodeContextTab(rawValue: rawContextTab) {
          store.isNodeContextPanePresented = true
          store.nodeContextTab = contextTab
        }
      }
      if verifiesCodeCopy {
        await MainActor.run {
          store.selectedSurface = .openClaw
          store.openClawMessages = [
            OpenClawChatMessage(
              role: .assistant,
              content: """
              Here are two independent snippets.

              #+begin_src swift
              let answer = 42
              print(answer)
              #+end_src

              #+begin_src sh
              org2 lint --recursive
              #+end_src
              """
            )
          ]
        }
      }
      let verificationTabIDs: [WorkspaceTab.ID] = await MainActor.run {
        guard verifiesTabs else { return [] }
        let firstTabID = store.selectedWorkspaceTabID
        let secondTabID = store.newWorkspaceTab()
        let thirdTabID = store.newWorkspaceTab()
        return [firstTabID, secondTabID, thirdTabID]
      }
      for _ in 0..<100 {
        let renderState = await MainActor.run {
          (
            hasSelection: store.selectedLocation != nil,
            hasHTML: store.selectedEntryHTML != nil,
            renderError: store.selectedEntryRenderError
          )
        }
        if !renderState.hasSelection || renderState.hasHTML || renderState.renderError != nil {
          break
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      if ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_EDIT_SOURCE"] != nil {
        await MainActor.run {
          store.beginEditingCurrentScope()
          if ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_SPLIT_PREVIEW"] != nil {
            store.sourceEditorPresentation = .split
            store.scheduleSourceEditorPreview(immediate: true)
          }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }

      try await renderScreenshot(
        store: store,
        outputPath: outputPath,
        width: width,
        height: height,
        scale: scale,
        verificationTabIDs: verificationTabIDs,
        verifiesCodeCopy: verifiesCodeCopy
      )
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      Foundation.exit(1)
    }
  }

  private static func outputPathArgument() throws -> String {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--out"),
          args.indices.contains(index + 1),
          !args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ScreenshotRenderError.missingOutputPath
    }
    return args[index + 1]
  }

  @MainActor
  private static func renderScreenshot(
    store: WorkspaceStore,
    outputPath: String,
    width: Double,
    height: Double,
    scale: Double,
    verificationTabIDs: [WorkspaceTab.ID],
    verifiesCodeCopy: Bool
  ) async throws {
    let content = ZStack {
      Color(nsColor: .windowBackgroundColor)
      ContentView()
        .environment(store)
        .frame(width: width, height: height)
    }
    .frame(width: width, height: height)
    let hostingView = NSHostingView(rootView: content)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    hostingView.frame = bounds
    hostingView.setFrameSize(NSSize(width: width, height: height))
    hostingView.autoresizingMask = [.width, .height]

    let window = NSWindow(
      contentRect: bounds,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.setFrame(bounds, display: false)
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    // HTML-backed document panes are created only after the SwiftUI hierarchy is
    // attached to a window. Give WKWebView enough time to finish its first paint
    // so deterministic docs captures include the selected document body.
    let renderSettleNanoseconds: UInt64 = ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_EDIT_SOURCE"] == nil
      ? 2_000_000_000
      : 2_500_000_000
    try? await Task.sleep(nanoseconds: renderSettleNanoseconds)
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()

    if !verificationTabIDs.isEmpty {
      try await verifyTabInteractions(
        in: window,
        hostingView: hostingView,
        store: store,
        expectedTabIDs: verificationTabIDs
      )
    }
    guard var bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
      throw ScreenshotRenderError.renderFailed
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

    if let webView = firstWebView(in: hostingView) {
      let configuration = WKSnapshotConfiguration()
      configuration.rect = webView.bounds
      if let webSnapshot = try? await webView.takeSnapshot(configuration: configuration),
         let composedBitmap = compose(
           base: bitmap,
           webSnapshot: webSnapshot,
           webFrame: webView.convert(webView.bounds, to: hostingView),
           size: bounds.size
         ) {
        bitmap = composedBitmap
      }
    }
    let expectedPixelWidth = max(1, Int(width * scale))
    let expectedPixelHeight = max(1, Int(height * scale))
    if bitmap.pixelsWide != expectedPixelWidth || bitmap.pixelsHigh != expectedPixelHeight {
      guard let normalizedBitmap = normalize(
        base: bitmap,
        size: bounds.size,
        pixelWidth: expectedPixelWidth,
        pixelHeight: expectedPixelHeight
      ) else {
        throw ScreenshotRenderError.renderFailed
      }
      bitmap = normalizedBitmap
    }
    bitmap.size = bounds.size
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw ScreenshotRenderError.renderFailed
    }

    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try png.write(to: outputURL)
    if verifiesCodeCopy {
      try verifyCodeCopy(in: hostingView)
    }
  }

  @MainActor
  private static func verifyCodeCopy(in hostingView: NSView) throws {
    let buttons = descendantButtons(in: hostingView).filter {
      $0.accessibilityLabel() == "Copy code"
    }
    guard buttons.count == 2 else {
      throw ScreenshotRenderError.codeCopyVerificationFailed(
        "rendered \(buttons.count) copy controls instead of two"
      )
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    buttons[0].performClick(nil)
    guard pasteboard.string(forType: .string) == "let answer = 42\nprint(answer)" else {
      throw ScreenshotRenderError.codeCopyVerificationFailed(
        "the visible control did not copy only its source block"
      )
    }
    FileHandle.standardError.write(Data("Verified visible code-block copy control and exact clipboard payload\n".utf8))
  }

  @MainActor
  private static func descendantButtons(in view: NSView) -> [NSButton] {
    view.subviews.flatMap { child in
      (child as? NSButton).map { [$0] } ?? descendantButtons(in: child)
    }
  }

  @MainActor
  private static func verifyTabInteractions(
    in window: NSWindow,
    hostingView: NSView,
    store: WorkspaceStore,
    expectedTabIDs: [WorkspaceTab.ID]
  ) async throws {
    guard expectedTabIDs.count == 3 else {
      throw ScreenshotRenderError.tabVerificationFailed("expected three fixture tabs")
    }
    var tabViews = workspaceTabViews(in: hostingView)
    guard tabViews.count == expectedTabIDs.count else {
      throw ScreenshotRenderError.tabVerificationFailed(
        "rendered \(tabViews.count) tab targets instead of \(expectedTabIDs.count)"
      )
    }

    let firstTabHitView = hitView(atCenterOf: tabViews[0], in: window)
    guard firstTabHitView === tabViews[0] else {
      throw ScreenshotRenderError.tabVerificationFailed(
        "the visible first tab does not own its hit-test area"
      )
    }
    sendClick(to: tabViews[0], in: window)
    await settleTabEvents()
    guard store.selectedWorkspaceTabID == expectedTabIDs[0] else {
      throw ScreenshotRenderError.tabVerificationFailed("an AppKit mouse click did not select the first tab")
    }

    tabViews = workspaceTabViews(in: hostingView)
    let originalFrames = tabViews.map { $0.convert($0.bounds, to: nil) }
    let dragDestination = beginDrag(from: tabViews[0], to: tabViews[2], in: window)
    await settleTabEvents(durationNanoseconds: 180_000_000)
    let liveFrames = tabViews.map { $0.convert($0.bounds, to: nil) }
    guard abs(liveFrames[0].midX - dragDestination.x) < 1,
          abs(liveFrames[1].minX - originalFrames[0].minX) < 1,
          abs(liveFrames[2].minX - originalFrames[1].minX) < 1
    else {
      throw ScreenshotRenderError.tabVerificationFailed(
        "the dragged tab or its neighbors did not move before mouse-up"
      )
    }
    guard store.workspaceTabs.map(\.id) == expectedTabIDs else {
      throw ScreenshotRenderError.tabVerificationFailed("the tab order committed before drop")
    }
    finishDrag(tabViews[0], at: dragDestination, in: window)
    await settleTabEvents(durationNanoseconds: 250_000_000)
    let reorderedTabIDs = store.workspaceTabs.map(\.id)
    guard reorderedTabIDs == [expectedTabIDs[1], expectedTabIDs[2], expectedTabIDs[0]] else {
      throw ScreenshotRenderError.tabVerificationFailed(
        "a real window drag produced \(reorderedTabIDs.map(\.uuidString))"
      )
    }

    tabViews = workspaceTabViews(in: hostingView)
    guard let closeButton = tabViews[2].subviews.compactMap({ $0 as? NSButton }).first else {
      throw ScreenshotRenderError.tabVerificationFailed("the selected tab has no native close button")
    }
    guard hitView(atCenterOf: closeButton, in: window) === closeButton else {
      throw ScreenshotRenderError.tabVerificationFailed("the visible close button does not own its hit-test area")
    }
    sendClick(to: closeButton, in: window)
    await settleTabEvents()
    guard store.workspaceTabs.map(\.id) == [expectedTabIDs[1], expectedTabIDs[2]] else {
      throw ScreenshotRenderError.tabVerificationFailed("the native close action did not close the selected tab")
    }

    FileHandle.standardError.write(Data("Verified integrated tab click, live drag reordering, drop, and native close action\n".utf8))
  }

  @MainActor
  private static func workspaceTabViews(in view: NSView) -> [NSView] {
    var matches: [NSView] = []
    for child in view.subviews {
      if NSStringFromClass(type(of: child)).hasSuffix(".WorkspaceTabInteractionView") {
        matches.append(child)
      }
      matches.append(contentsOf: workspaceTabViews(in: child))
    }
    return matches.sorted {
      $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
    }
  }

  @MainActor
  private static func hitView(atCenterOf view: NSView, in window: NSWindow) -> NSView? {
    guard let contentView = window.contentView else { return nil }
    let windowPoint = view.convert(
      NSPoint(x: view.bounds.midX, y: view.bounds.midY),
      to: nil
    )
    return contentView.hitTest(windowPoint)
  }

  @MainActor
  private static func sendClick(to view: NSView, in window: NSWindow) {
    let location = view.convert(
      NSPoint(x: view.bounds.midX, y: view.bounds.midY),
      to: nil
    )
    if let button = view as? NSButton {
      button.performClick(nil)
      return
    }
    view.mouseDown(with: mouseEvent(.leftMouseDown, at: location, in: window, eventNumber: 1))
    view.mouseUp(with: mouseEvent(.leftMouseUp, at: location, in: window, eventNumber: 2))
  }

  @MainActor
  private static func beginDrag(from source: NSView, to target: NSView, in window: NSWindow) -> NSPoint {
    let start = source.convert(
      NSPoint(x: source.bounds.midX, y: source.bounds.midY),
      to: nil
    )
    let destination = target.convert(
      NSPoint(x: target.bounds.midX - 30, y: target.bounds.midY),
      to: nil
    )
    let threshold = NSPoint(x: start.x + 8, y: start.y)

    source.mouseDown(with: mouseEvent(.leftMouseDown, at: start, in: window, eventNumber: 3))
    source.mouseDragged(with: mouseEvent(.leftMouseDragged, at: threshold, in: window, eventNumber: 4))
    source.mouseDragged(with: mouseEvent(.leftMouseDragged, at: destination, in: window, eventNumber: 5))
    return destination
  }

  @MainActor
  private static func finishDrag(_ source: NSView, at location: NSPoint, in window: NSWindow) {
    source.mouseUp(with: mouseEvent(.leftMouseUp, at: location, in: window, eventNumber: 6))
  }

  @MainActor
  private static func mouseEvent(
    _ type: NSEvent.EventType,
    at location: NSPoint,
    in window: NSWindow,
    eventNumber: Int
  ) -> NSEvent {
    NSEvent.mouseEvent(
      with: type,
      location: location,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: type == .leftMouseUp ? 0 : 1
    )!
  }

  @MainActor
  private static func settleTabEvents(durationNanoseconds: UInt64 = 100_000_000) async {
    try? await Task.sleep(nanoseconds: durationNanoseconds)
  }

  @MainActor
  private static func firstWebView(in view: NSView) -> WKWebView? {
    if let webView = view as? WKWebView { return webView }
    for subview in view.subviews {
      if let webView = firstWebView(in: subview) { return webView }
    }
    return nil
  }

  @MainActor
  private static func compose(
    base: NSBitmapImageRep,
    webSnapshot: NSImage,
    webFrame: NSRect,
    size: NSSize
  ) -> NSBitmapImageRep? {
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: max(1, Int(size.width)),
      pixelsHigh: max(1, Int(size.height)),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      return nil
    }

    let baseImage = NSImage(size: size)
    baseImage.addRepresentation(base)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    baseImage.draw(in: NSRect(origin: .zero, size: size))
    let bitmapWebFrame = NSRect(
      x: webFrame.minX,
      y: size.height - webFrame.maxY,
      width: webFrame.width,
      height: webFrame.height
    )
    webSnapshot.draw(in: bitmapWebFrame)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }

  @MainActor
  private static func normalize(
    base: NSBitmapImageRep,
    size: NSSize,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> NSBitmapImageRep? {
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelWidth,
      pixelsHigh: pixelHeight,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      return nil
    }

    bitmap.size = size
    let baseImage = NSImage(size: size)
    baseImage.addRepresentation(base)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    baseImage.draw(in: NSRect(origin: .zero, size: size))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }

}

private enum ScreenshotRenderError: LocalizedError {
  case missingOutputPath
  case renderFailed
  case tabVerificationFailed(String)
  case codeCopyVerificationFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingOutputPath:
      return "Usage: Org2WorkspaceScreenshotRenderer --out PATH"
    case .renderFailed:
      return "Could not render OpenOrg screenshot"
    case .tabVerificationFailed(let reason):
      return "Tab interaction verification failed: \(reason)"
    case .codeCopyVerificationFailed(let reason):
      return "Code copy interaction verification failed: \(reason)"
    }
  }
}
