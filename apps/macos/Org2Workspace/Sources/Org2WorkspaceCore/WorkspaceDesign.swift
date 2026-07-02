import SwiftUI

enum WorkspaceDesign {
  static let cornerRadius: CGFloat = 8
  static let controlRadius: CGFloat = 7
  static let contentInset: CGFloat = 16
  static let rowVerticalPadding: CGFloat = 7
  static let compactPaneWidth: CGFloat = 820

  static var barBackground: Color {
    Color(nsColor: .controlBackgroundColor).opacity(0.94)
  }

  static var barMaterial: Material {
    .bar
  }

  static var surfaceBackground: Color {
    Color(nsColor: .textBackgroundColor)
  }

  static var appBackground: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  static var subtleFill: Color {
    Color.secondary.opacity(0.055)
  }

  static var elevatedFill: Color {
    Color(nsColor: .textBackgroundColor).opacity(0.86)
  }

  static var selectedFill: Color {
    Color.accentColor.opacity(0.11)
  }

  static var hairline: Color {
    Color.secondary.opacity(0.13)
  }

  static var strongHairline: Color {
    Color.secondary.opacity(0.20)
  }

  static func tint(for surface: WorkspaceSurface?) -> Color {
    guard let surface else { return .accentColor }
    switch surface {
    case .home: return .accentColor
    case .agenda: return .blue
    case .approvals: return .green
    case .files: return .indigo
    case .search: return .purple
    case .meetings: return .orange
    case .openClaw: return .cyan
    }
  }

  static func snappyAnimation(duration: Double = 0.16) -> Animation {
    .spring(response: duration, dampingFraction: 0.82, blendDuration: 0.04)
  }
}

struct WorkspaceIconBadge: View {
  let systemImage: String
  var tint: Color = .secondary
  var fill: Color = WorkspaceDesign.subtleFill

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(tint)
      .frame(width: 24, height: 24)
      .background(fill, in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
          .stroke(tint.opacity(0.10))
      )
  }
}

struct KeyboardShortcutBadge: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption2.monospaced().weight(.medium))
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .stroke(Color.secondary.opacity(0.10))
      )
  }
}

struct WorkspaceActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.medium))
      .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        configuration.isPressed ? Color.secondary.opacity(0.16) : Color.secondary.opacity(0.055),
        in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
          .stroke(configuration.isPressed ? WorkspaceDesign.strongHairline : WorkspaceDesign.hairline)
      )
      .scaleEffect(configuration.isPressed ? 0.975 : 1)
      .opacity(isEnabled ? 1 : 0.55)
      .animation(WorkspaceDesign.snappyAnimation(duration: 0.14), value: configuration.isPressed)
  }
}

struct WorkspaceActivityIndicator: View {
  var label: String? = nil
  var compact = false

  var body: some View {
    HStack(spacing: compact ? 5 : 7) {
      TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
        HStack(spacing: 3) {
          ForEach(0..<3, id: \.self) { index in
            Circle()
              .fill(Color.accentColor.opacity(dotOpacity(at: context.date, index: index)))
              .frame(width: compact ? 4 : 5, height: compact ? 4 : 5)
              .offset(y: dotOffset(at: context.date, index: index))
          }
        }
        .frame(width: compact ? 20 : 24, height: compact ? 12 : 14)
      }

      if let label, !label.isEmpty {
        Text(label)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label ?? "Working")
  }

  private func dotOpacity(at date: Date, index: Int) -> Double {
    let phase = date.timeIntervalSinceReferenceDate * 3.2 + Double(index) * 0.72
    return 0.35 + (sin(phase) + 1) * 0.28
  }

  private func dotOffset(at date: Date, index: Int) -> CGFloat {
    let phase = date.timeIntervalSinceReferenceDate * 3.2 + Double(index) * 0.72
    return CGFloat(-sin(phase) * (compact ? 1.5 : 2.0))
  }
}
