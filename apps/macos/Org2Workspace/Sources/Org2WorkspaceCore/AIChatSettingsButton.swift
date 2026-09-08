import SwiftUI

/// Shared selection lets chat open the AI pane even when Settings is already open.
public enum WorkspaceSettingsNavigation {
  public static let selectionKey = "workspaceSettingsSelection"
  public static let aiChat = "aiChat"
}

public struct AIChatSettingsButton: View {
  @Environment(\.openSettings) private var openSettings
  @AppStorage(WorkspaceSettingsNavigation.selectionKey) private var selection = "workspace"

  public init() {}

  public var body: some View {
    Button {
      selection = WorkspaceSettingsNavigation.aiChat
      openSettings()
    } label: {
      Label("AI Chat Settings…", systemImage: "gearshape")
    }
    .help("Open Settings → AI Chat")
    .accessibilityIdentifier("ai-chat-settings")
  }
}
