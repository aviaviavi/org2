import AppKit
import SwiftUI

enum WorkspaceDesign {
  static let cornerRadius: CGFloat = 11
  static let controlRadius: CGFloat = 7
  static let contentInset: CGFloat = 16
  static let rowVerticalPadding: CGFloat = 8
  static let headerHorizontalInset: CGFloat = 16
  static let headerVerticalInset: CGFloat = 11
  static let selectionMarkerGutterWidth: CGFloat = 22
  static let selectionMarkerVerticalOffset: CGFloat = -1

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

  // These surfaces mirror the restrained, warm editorial palette used by the
  // Org2 site. They keep the app recognizably native while avoiding a stack of
  // indistinguishable system-gray panes.
  static let canvasNSColor = NSColor(name: nil) { appearance in
    isDark(appearance)
      ? NSColor(srgbRed: 0.082, green: 0.102, blue: 0.094, alpha: 1)
      : NSColor(srgbRed: 0.949, green: 0.941, blue: 0.914, alpha: 1)
  }

  static let documentNSColor = NSColor(name: nil) { appearance in
    isDark(appearance)
      ? NSColor(srgbRed: 0.106, green: 0.129, blue: 0.122, alpha: 1)
      : NSColor(srgbRed: 0.988, green: 0.984, blue: 0.969, alpha: 1)
  }

  static let structuralNSColor = NSColor(name: nil) { appearance in
    isDark(appearance)
      ? NSColor(srgbRed: 0.525, green: 0.639, blue: 1.000, alpha: 1)
      : NSColor(srgbRed: 0.157, green: 0.329, blue: 0.843, alpha: 1)
  }

  static let signalNSColor = NSColor(name: nil) { appearance in
    isDark(appearance)
      ? NSColor(srgbRed: 1.000, green: 0.525, blue: 0.408, alpha: 1)
      : NSColor(srgbRed: 0.761, green: 0.278, blue: 0.173, alpha: 1)
  }

  static let hairlineNSColor = NSColor(name: nil) { appearance in
    isDark(appearance)
      ? NSColor(srgbRed: 0.212, green: 0.251, blue: 0.235, alpha: 1)
      : NSColor(srgbRed: 0.843, green: 0.839, blue: 0.808, alpha: 1)
  }

  static var primaryText: Color { Color(nsColor: stablePrimaryNSColor) }
  static var secondaryText: Color { Color(nsColor: stableSecondaryNSColor) }
  static var tertiaryText: Color { Color(nsColor: stableTertiaryNSColor) }
  static var structuralAccent: Color { Color(nsColor: structuralNSColor) }
  static var signalAccent: Color { Color(nsColor: signalNSColor) }

  private static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  static var barBackground: Color {
    Color(nsColor: documentNSColor)
  }

  static var surfaceBackground: Color {
    Color(nsColor: documentNSColor)
  }

  static var appBackground: Color {
    Color(nsColor: canvasNSColor)
  }

  static var subtleFill: Color {
    Color.secondary.opacity(0.045)
  }

  static var selectedFill: Color {
    Color.accentColor.opacity(0.105)
  }

  static var hairline: Color {
    Color(nsColor: hairlineNSColor)
  }

  static var controlFill: Color {
    Color.secondary.opacity(0.055)
  }

  static var controlHoverFill: Color {
    Color.secondary.opacity(0.085)
  }

  static var controlGroupFill: Color {
    structuralAccent.opacity(0.045)
  }

  static var controlPressedFill: Color {
    Color.accentColor.opacity(0.12)
  }

  static var panelFill: Color {
    structuralAccent.opacity(0.035)
  }
}

enum WorkspaceSyntax {
  static let selectionMarker = "*"

  static func headingMarker(for level: Int) -> String {
    String(repeating: "*", count: min(max(level, 1), 3))
  }
}

struct WorkspaceAsteriskMarker: View {
  var level = 1
  var color: Color = WorkspaceDesign.structuralAccent
  var size: CGFloat = 11

  var body: some View {
    Text(WorkspaceSyntax.headingMarker(for: level))
      .font(.system(size: size, weight: .semibold, design: .monospaced))
      .foregroundStyle(color)
      .fixedSize()
      .accessibilityHidden(true)
  }
}

struct WorkspaceSelectionMarker: View {
  var body: some View {
    Text(WorkspaceSyntax.selectionMarker)
      .font(.system(size: 12, weight: .bold, design: .monospaced))
      .foregroundStyle(Color.accentColor)
      .frame(width: WorkspaceDesign.selectionMarkerGutterWidth, height: 20, alignment: .center)
      .offset(y: WorkspaceDesign.selectionMarkerVerticalOffset)
      .accessibilityHidden(true)
  }
}

struct WorkspaceSelectableRowModifier: ViewModifier {
  @State private var isHovered = false
  let isSelected: Bool
  var showsSelectionMarker = true
  var leadingPadding = WorkspaceDesign.selectionMarkerGutterWidth
  var trailingPadding: CGFloat = 10
  var verticalPadding: CGFloat = 0
  var cornerRadius: CGFloat = 8
  var selectedFill = WorkspaceDesign.selectedFill

  func body(content: Content) -> some View {
    content
      .padding(.leading, leadingPadding)
      .padding(.trailing, trailingPadding)
      .padding(.vertical, verticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected
          ? selectedFill
          : isHovered ? Color.primary.opacity(0.035) : Color.clear,
        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
      .overlay(alignment: .leading) {
        if isSelected && showsSelectionMarker {
          WorkspaceSelectionMarker()
        }
      }
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .onHover { hovering in
        withAnimation(.easeOut(duration: 0.08)) {
          isHovered = hovering
        }
      }
  }
}

enum WorkspaceMotion {
  static let quick = Animation.easeOut(duration: 0.14)
  static let disclosure = Animation.easeInOut(duration: 0.16)
}

enum WorkspaceSidebarLayout {
  static let minimumWidth: CGFloat = 180

  static func defaultWidth(for containerWidth: CGFloat) -> CGFloat {
    maximumWidth(for: containerWidth)
  }

  static func maximumWidth(for containerWidth: CGFloat) -> CGFloat {
    max(minimumWidth, containerWidth * 0.25)
  }
}

struct WorkspaceIconBadge: View {
  let systemImage: String
  var tint: Color = .secondary
  var fill: Color = WorkspaceDesign.subtleFill

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 12, weight: .medium))
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

  @ViewBuilder
  var body: some View {
    if reduceMotion {
      Image(systemName: "ellipsis")
        .font(.system(size: max(8, size.diameter * 0.65), weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: size.width, height: size.diameter)
        .accessibilityLabel("Loading")
    } else {
      WorkspaceNativeProgressIndicator(size: size)
        .frame(width: size.width, height: size.diameter)
        .accessibilityLabel("Loading")
    }
  }
}

private struct WorkspaceNativeProgressIndicator: NSViewRepresentable {
  let size: WorkspaceActivityIndicatorSize

  func makeNSView(context: Context) -> NSProgressIndicator {
    let indicator = NSProgressIndicator()
    indicator.style = .spinning
    indicator.isIndeterminate = true
    indicator.usesThreadedAnimation = true
    indicator.controlSize = controlSize
    indicator.startAnimation(nil)
    return indicator
  }

  func updateNSView(_ indicator: NSProgressIndicator, context: Context) {
    indicator.controlSize = controlSize
    indicator.startAnimation(nil)
  }

  static func dismantleNSView(_ indicator: NSProgressIndicator, coordinator: ()) {
    indicator.stopAnimation(nil)
  }

  private var controlSize: NSControl.ControlSize {
    switch size {
    case .mini: .mini
    case .small: .small
    case .regular: .regular
    }
  }
}

struct WorkspaceLoadingStateView: View {
  let title: String

  init(_ title: String = "Loading") {
    self.title = title
  }

  var body: some View {
    VStack(spacing: 12) {
      WorkspaceActivityIndicator(size: .regular, style: .scan)
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
    WorkspaceActionButtonBody(
      configuration: configuration,
      isEnabled: isEnabled
    )
  }
}

private struct WorkspaceActionButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let isEnabled: Bool
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .font(.callout.weight(.medium))
      .foregroundStyle(isEnabled
        ? WorkspaceDesign.primaryText.opacity(configuration.isPressed ? 0.86 : 0.93)
        : WorkspaceDesign.secondaryText)
      .lineLimit(1)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(minHeight: 26)
      .contentShape(RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous))
      .background(
        backgroundFill,
        in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
      )
      .opacity(isEnabled ? 1 : 0.55)
      .animation(WorkspaceMotion.quick, value: isHovering)
      .onHover { isHovering = $0 }
  }

  private var backgroundFill: Color {
    if configuration.isPressed {
      return WorkspaceDesign.controlPressedFill
    }
    if isHovering {
      return WorkspaceDesign.controlHoverFill
    }
    return .clear
  }
}

struct WorkspaceControlStrip<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 1) {
      content
    }
    .padding(3)
    .background(
      WorkspaceDesign.controlGroupFill,
      in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
        .stroke(WorkspaceDesign.hairline, lineWidth: 0.75)
    }
  }
}

struct WorkspaceCardSurface: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
          .fill(WorkspaceDesign.surfaceBackground)
          .shadow(color: Color.black.opacity(0.055), radius: 4, x: 0, y: 1)
      }
      .overlay {
        RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
          .stroke(WorkspaceDesign.hairline, lineWidth: 0.75)
      }
  }
}

extension View {
  func workspaceSelectableRow(
    isSelected: Bool,
    showsSelectionMarker: Bool = true,
    leadingPadding: CGFloat = WorkspaceDesign.selectionMarkerGutterWidth,
    trailingPadding: CGFloat = 10,
    verticalPadding: CGFloat = 0,
    cornerRadius: CGFloat = 8,
    selectedFill: Color = WorkspaceDesign.selectedFill
  ) -> some View {
    modifier(WorkspaceSelectableRowModifier(
      isSelected: isSelected,
      showsSelectionMarker: showsSelectionMarker,
      leadingPadding: leadingPadding,
      trailingPadding: trailingPadding,
      verticalPadding: verticalPadding,
      cornerRadius: cornerRadius,
      selectedFill: selectedFill
    ))
  }

  func workspaceCardSurface() -> some View {
    modifier(WorkspaceCardSurface())
  }
}
