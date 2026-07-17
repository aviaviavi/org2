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

  var width: CGFloat {
    switch self {
    case .mini: 13
    case .small: 19
    case .regular: 38
    }
  }
}

enum WorkspaceActivityIndicatorStyle {
  case signal
  case typing
  case scan
}

struct WorkspaceActivityIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var size: WorkspaceActivityIndicatorSize = .small
  var tint: Color = .accentColor
  var style: WorkspaceActivityIndicatorStyle = .signal

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
      let phase = reduceMotion
        ? 0.18
        : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2

      indicator(phase: phase)
    }
      .frame(width: size.width, height: size.diameter)
      .accessibilityLabel("Loading")
  }

  @ViewBuilder
  private func indicator(phase: Double) -> some View {
    switch style {
    case .signal:
      HStack(alignment: .center, spacing: max(1.5, size.diameter * 0.12)) {
        ForEach(0..<3, id: \.self) { index in
          Capsule()
            .fill(tint.opacity(0.52 + Double(wave(phase, index: index)) * 0.48))
            .frame(
              width: max(2, size.diameter * 0.17),
              height: max(3, size.diameter * (0.30 + wave(phase, index: index) * 0.58))
            )
        }
      }
    case .typing:
      HStack(spacing: max(2, size.diameter * 0.18)) {
        ForEach(0..<3, id: \.self) { index in
          Circle()
            .fill(tint.opacity(0.38 + Double(wave(phase, index: index)) * 0.62))
            .frame(width: max(3, size.diameter * 0.25), height: max(3, size.diameter * 0.25))
            .offset(y: -wave(phase, index: index) * size.diameter * 0.22)
        }
      }
    case .scan:
      GeometryReader { proxy in
        let travel = max(0, proxy.size.width - proxy.size.height * 0.38)
        Capsule()
          .fill(tint.opacity(0.12))
          .frame(height: max(2, proxy.size.height * 0.24))
          .overlay(alignment: .leading) {
            Capsule()
              .fill(tint)
              .frame(width: max(4, proxy.size.height * 0.38))
              .offset(x: travel * CGFloat(pingPong(phase)))
          }
          .frame(maxHeight: .infinity, alignment: .center)
      }
    }
  }

  private func wave(_ phase: Double, index: Int) -> CGFloat {
    let angle = (phase * 2 * Double.pi) - (Double(index) * 0.85)
    return CGFloat((sin(angle) + 1) / 2)
  }

  private func pingPong(_ phase: Double) -> Double {
    phase < 0.5 ? phase * 2 : (1 - phase) * 2
  }
}

struct WorkspaceLoadingStateView: View {
  let title: String

  init(_ title: String = "Loading") {
    self.title = title
  }

  var body: some View {
    VStack(spacing: 12) {
      WorkspaceShimmerPlaceholder()
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .padding(14)
  }
}

private struct WorkspaceShimmerPlaceholder: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
      let phase = reduceMotion
        ? 0.45
        : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6

      VStack(alignment: .leading, spacing: 7) {
        shimmerLine(width: 112, phase: phase)
        shimmerLine(width: 84, phase: phase)
        shimmerLine(width: 98, phase: phase)
      }
    }
    .accessibilityHidden(true)
  }

  private func shimmerLine(width: CGFloat, phase: Double) -> some View {
    RoundedRectangle(cornerRadius: 3, style: .continuous)
      .fill(Color.secondary.opacity(0.10))
      .frame(width: width, height: 7)
      .overlay(alignment: .leading) {
        LinearGradient(
          colors: [.clear, Color.accentColor.opacity(0.25), .clear],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: 48)
        .offset(x: (width + 48) * CGFloat(phase) - 48)
      }
      .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
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
