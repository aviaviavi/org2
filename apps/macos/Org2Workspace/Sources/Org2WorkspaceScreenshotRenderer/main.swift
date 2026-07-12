import AppKit
import Org2WorkspaceCore
import SwiftUI

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
      if ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_EXPAND_AUDIO_SETTINGS"] != nil {
        await MainActor.run {
          store.selectedSurface = .meetings
          store.isAudioSettingsExpanded = true
        }
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

      try await MainActor.run {
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
        let renderSettleTime = ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_EDIT_SOURCE"] == nil
          ? 0.25
          : 1.5
        RunLoop.current.run(until: Date().addingTimeInterval(renderSettleTime))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
          throw ScreenshotRenderError.renderFailed
        }
        bitmap.size = NSSize(width: width / scale, height: height / scale)
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
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
