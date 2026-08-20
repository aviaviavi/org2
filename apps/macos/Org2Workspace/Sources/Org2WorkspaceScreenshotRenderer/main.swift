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

      _ = await MainActor.run {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
      }
      let defaults = UserDefaults(suiteName: "org2-workspace-screenshot-\(UUID().uuidString)") ?? .standard
      let store = await MainActor.run {
        WorkspaceStore(defaults: defaults)
      }
      await store.bootstrap()
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
        scale: scale
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
    scale: Double
  ) async throws {
    let content = ZStack {
      Color(nsColor: .windowBackgroundColor)
      ContentView()
        .environmentObject(store)
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
    bitmap.size = NSSize(width: width / scale, height: height / scale)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw ScreenshotRenderError.renderFailed
    }

    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try png.write(to: outputURL)
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

}

private enum ScreenshotRenderError: LocalizedError {
  case missingOutputPath
  case renderFailed

  var errorDescription: String? {
    switch self {
    case .missingOutputPath:
      return "Usage: Org2WorkspaceScreenshotRenderer --out PATH"
    case .renderFailed:
      return "Could not render Org2 Workspace screenshot"
    }
  }
}
