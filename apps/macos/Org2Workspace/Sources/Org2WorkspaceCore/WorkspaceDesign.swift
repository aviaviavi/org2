import AppKit
import SwiftUI

enum WorkspaceDesign {
  static let cornerRadius: CGFloat = 7
  static let controlRadius: CGFloat = 6
  static let contentInset: CGFloat = 16
  static let rowVerticalPadding: CGFloat = 8
  static let headerHorizontalInset: CGFloat = 16
  static let headerVerticalInset: CGFloat = 11

  // AppKit's semantic label colors can become extremely faint when a hosted
  // editor hierarchy is treated as inactive. Keep document chrome and source
  // text tied to the current appearance, not window activation.
  static let stablePrimaryNSColor = NSColor(name: nil) { appearance in
    isDark(appearance) ? NSColor(deviceWhite: 0.92, alpha: 1) : NSColor(deviceWhite: 0.12, alpha: 1)
  }

  static let stableSecondaryNSColor = NSColor(name: nil) { appearance in
    isDark(appearance) ? NSColor(deviceWhite: 0.68, alpha: 1) : NSColor(deviceWhite: 0.40, alpha: 1)
  }

  static let stableTertiaryNSColor = NSColor(name: nil) { appearance in
    isDark(appearance) ? NSColor(deviceWhite: 0.50, alpha: 1) : NSColor(deviceWhite: 0.58, alpha: 1)
  }

  static var primaryText: Color { Color(nsColor: stablePrimaryNSColor) }
  static var secondaryText: Color { Color(nsColor: stableSecondaryNSColor) }
  static var tertiaryText: Color { Color(nsColor: stableTertiaryNSColor) }

  private static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  static var barBackground: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  static var surfaceBackground: Color {
    Color(nsColor: .textBackgroundColor)
  }

  static var appBackground: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  static var subtleFill: Color {
    Color.secondary.opacity(0.045)
  }

  static var selectedFill: Color {
    Color.accentColor.opacity(0.105)
  }

  static var hairline: Color {
    Color.secondary.opacity(0.12)
  }

  static var controlFill: Color {
    Color.secondary.opacity(0.055)
  }

  static var controlPressedFill: Color {
    Color.accentColor.opacity(0.12)
  }

  static var panelFill: Color {
    Color.secondary.opacity(0.04)
  }
}

enum WorkspaceMotion {
  static let quick = Animation.easeOut(duration: 0.14)
  static let disclosure = Animation.easeInOut(duration: 0.16)
}

struct WorkspaceIconBadge: View {
  let systemImage: String
  var tint: Color = .secondary
  var fill: Color = WorkspaceDesign.subtleFill

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(tint)
      .frame(width: 26, height: 26)
      .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

enum WorkspaceActivityIndicatorSize {
  case mini
  case small
  case regular

  var diameter: CGFloat {
    switch self {
    case .mini: 10
    case .small: 14
    case .regular: 28
    }
  }

  var controlSize: ControlSize {
    switch self {
    case .mini: .mini
    case .small: .small
    case .regular: .regular
    }
  }
}

struct WorkspaceActivityIndicator: View {
  var size: WorkspaceActivityIndicatorSize = .small
  var tint: Color = .accentColor

  var body: some View {
    ProgressView()
      .progressViewStyle(.circular)
      .controlSize(size.controlSize)
      .tint(tint)
      .frame(width: size.diameter, height: size.diameter)
      .accessibilityLabel("Loading")
  }
}

struct WorkspaceLoadingStateView: View {
  let title: String

  init(_ title: String = "Loading") {
    self.title = title
  }

  var body: some View {
    VStack(spacing: 10) {
      WorkspaceActivityIndicator(size: .regular)
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .padding(14)
  }
}

struct KeyboardShortcutBadge: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption2.monospaced().weight(.medium))
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(WorkspaceDesign.controlFill, in: Capsule())
  }
}

struct WorkspaceActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(isEnabled
        ? WorkspaceDesign.primaryText.opacity(configuration.isPressed ? 0.86 : 0.93)
        : WorkspaceDesign.secondaryText)
      .lineLimit(1)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 8)
      .padding(.vertical, 4.5)
      .background(
        configuration.isPressed ? WorkspaceDesign.controlPressedFill : WorkspaceDesign.controlFill,
        in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
          .stroke(WorkspaceDesign.hairline)
      )
      .opacity(isEnabled ? 1 : 0.55)
  }
}
