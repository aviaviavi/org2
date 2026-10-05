import SwiftUI

/// Header control that settles or reopens the open AI chat thread, matching
/// the sidebar's Settle Thread / Reopen Thread actions.
struct AIChatThreadSettleButton: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let isSettled = store.selectedAIChatThreadIsSettled
    Button {
      withAnimation(reduceMotion ? nil : WorkspaceMotion.action) {
        store.toggleSelectedAIChatThreadSettlement()
      }
    } label: {
      Label(
        isSettled ? "Reopen" : "Settle",
        systemImage: isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle"
      )
    }
    .help(isSettled ? "Reopen this thread" : "Settle this thread")
    .disabled(store.selectedAIChatThread == nil)
    .accessibilityIdentifier("ai-chat-settle-thread")
  }
}
