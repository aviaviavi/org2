import SwiftUI

struct OpenClawSidebarThreadSettlementButton: View {
  let isSettled: Bool
  let isVisible: Bool
  let action: () -> Void

  private var title: String { isSettled ? "Reopen thread" : "Settle thread" }

  var body: some View {
    Button(action: action) {
      Image(systemName: isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle")
        .font(.callout)
        .fixedSize()
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .layoutPriority(1)
    .foregroundStyle(.secondary)
    .help(title)
    .accessibilityLabel(title)
    // Keep the same control and width when hovering so the title cannot squeeze it.
    .opacity(isVisible ? 1 : 0)
    .allowsHitTesting(isVisible)
    .accessibilityHidden(!isVisible)
  }
}
