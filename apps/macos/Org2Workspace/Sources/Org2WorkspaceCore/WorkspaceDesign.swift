import SwiftUI

enum WorkspaceDesign {
  static let cornerRadius: CGFloat = 7
  static let controlRadius: CGFloat = 6
  static let contentInset: CGFloat = 16
  static let rowVerticalPadding: CGFloat = 6

  static var barBackground: Color {
    Color(nsColor: .windowBackgroundColor).opacity(0.92)
  }

  static var surfaceBackground: Color {
    Color(nsColor: .textBackgroundColor)
  }

  static var subtleFill: Color {
    Color.secondary.opacity(0.065)
  }

  static var selectedFill: Color {
    Color.accentColor.opacity(0.10)
  }

  static var hairline: Color {
    Color.secondary.opacity(0.16)
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
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.medium))
      .lineLimit(1)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        configuration.isPressed ? Color.secondary.opacity(0.14) : WorkspaceDesign.subtleFill,
        in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
          .stroke(WorkspaceDesign.hairline)
      )
  }
}
