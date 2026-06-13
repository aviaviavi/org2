import SwiftUI

struct ChatBubbleView: View {
  let message: OpenClawChatMessage

  var body: some View {
    HStack {
      if message.role == .user {
        Spacer(minLength: 48)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(message.role == .user ? "You" : "OpenClaw")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        OrgInlineText(message.content)
          .frame(maxWidth: 640, alignment: .leading)
      }
      .padding(10)
      .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.secondary.opacity(message.role == .user ? 0 : 0.16))
      )

      if message.role != .user {
        Spacer(minLength: 48)
      }
    }
    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
  }

  private var background: Color {
    switch message.role {
    case .user:
      return Color.accentColor.opacity(0.14)
    case .assistant:
      return Color.secondary.opacity(0.08)
    case .system:
      return Color.orange.opacity(0.10)
    }
  }
}

struct OpenClawTypingIndicatorView: View {
  let startedAt: Date?

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          TimelineView(.periodic(from: startedAt ?? Date(), by: 1)) { context in
            Text("OpenClaw is thinking\(elapsedSuffix(now: context.date))")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
          }
        }
        Text("Waiting for the gateway response")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(10)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.secondary.opacity(0.16))
      )
      Spacer(minLength: 48)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func elapsedSuffix(now: Date) -> String {
    guard let startedAt else { return "" }
    let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
    if seconds < 1 { return "" }
    if seconds < 60 { return " \(seconds)s" }
    return " \(seconds / 60)m \(seconds % 60)s"
  }
}
