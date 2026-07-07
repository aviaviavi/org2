import SwiftUI

enum WorkspaceDesign {
  static let cornerRadius: CGFloat = 8
  static let controlRadius: CGFloat = 8
  static let contentInset: CGFloat = 14
  static let rowVerticalPadding: CGFloat = 7

  static var barBackground: Color {
    Color(nsColor: .windowBackgroundColor).opacity(0.92)
  }

  static var surfaceBackground: Color {
    Color(nsColor: .textBackgroundColor)
  }

  static var appBackground: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  static var subtleFill: Color {
    Color.secondary.opacity(0.038)
  }

  static var selectedFill: Color {
    Color.accentColor.opacity(0.11)
  }

  static var hairline: Color {
    Color.secondary.opacity(0.09)
  }

  static var controlFill: Color {
    Color.secondary.opacity(0.048)
  }

  static var controlPressedFill: Color {
    Color.secondary.opacity(0.11)
  }

  static var panelFill: Color {
    Color.secondary.opacity(0.032)
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
      .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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

  var lineWidth: CGFloat {
    switch self {
    case .mini: 1.25
    case .small: 1.7
    case .regular: 2.4
    }
  }
}

struct WorkspaceActivityIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var size: WorkspaceActivityIndicatorSize = .small
  var tint: Color = .accentColor

  @ViewBuilder
  var body: some View {
    Group {
      if reduceMotion {
        indicator(phase: 0.34)
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
          indicator(phase: timeline.date.timeIntervalSinceReferenceDate)
        }
      }
    }
    .accessibilityLabel("Loading")
  }

  private func indicator(phase: TimeInterval) -> some View {
    let rotation = Angle.degrees(phase.truncatingRemainder(dividingBy: 1.18) / 1.18 * 360)
    let pulse = 0.55 + 0.45 * (sin(phase * 3.2) + 1) / 2
    let diameter = size.diameter

    return ZStack {
      Circle()
        .stroke(tint.opacity(0.13), lineWidth: size.lineWidth)

      Circle()
        .trim(from: 0.04, to: 0.74)
        .stroke(
          AngularGradient(
            colors: [
              tint.opacity(0.12),
              tint.opacity(0.58),
              Color.primary.opacity(0.82),
              tint.opacity(0.18),
            ],
            center: .center
          ),
          style: StrokeStyle(lineWidth: size.lineWidth, lineCap: .round)
        )
        .rotationEffect(rotation)

      Circle()
        .fill(tint.opacity(0.16 + 0.12 * pulse))
        .frame(width: diameter * 0.22, height: diameter * 0.22)
        .scaleEffect(0.82 + 0.22 * pulse)
    }
    .frame(width: diameter, height: diameter)
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
        .workspaceShimmer()
    }
    .padding(14)
  }
}

private struct WorkspaceShimmerModifier: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let isActive: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isActive && !reduceMotion {
      TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
        content
          .overlay {
            GeometryReader { proxy in
              let width = max(proxy.size.width, 1)
              let travel = width * 2.4
              let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.65) / 1.65

              LinearGradient(
                stops: [
                  .init(color: .clear, location: 0.0),
                  .init(color: .white.opacity(0.12), location: 0.28),
                  .init(color: .white.opacity(0.70), location: 0.50),
                  .init(color: .white.opacity(0.12), location: 0.72),
                  .init(color: .clear, location: 1.0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
              .frame(width: width * 0.72, height: proxy.size.height * 1.7)
              .offset(x: -width * 0.95 + travel * phase, y: -proxy.size.height * 0.35)
            }
            .allowsHitTesting(false)
          }
          .mask(content)
      }
    } else {
      content
    }
  }
}

extension View {
  func workspaceShimmer(isActive: Bool = true) -> some View {
    modifier(WorkspaceShimmerModifier(isActive: isActive))
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
        ? Color.primary.opacity(configuration.isPressed ? 0.86 : 0.93)
        : Color.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(
        configuration.isPressed ? WorkspaceDesign.controlPressedFill : WorkspaceDesign.controlFill,
        in: Capsule()
      )
      .overlay(
        Capsule()
          .stroke(configuration.isPressed ? WorkspaceDesign.hairline : Color.clear)
      )
      .opacity(isEnabled ? 1 : 0.55)
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
  }
}
