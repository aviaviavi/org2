import AppKit
import QuartzCore
import SwiftUI

/// A compositor-driven activity pulse. Keeping this animation out of SwiftUI's
/// frame clock prevents a tiny status affordance from invalidating the layout
/// graph for an entire (potentially very large) workspace window.
struct CoreAnimationActivityDot: NSViewRepresentable {
  enum ColorStyle {
    case accent
    case secondary
  }

  let animates: Bool
  let colorStyle: ColorStyle

  init(animates: Bool, colorStyle: ColorStyle = .accent) {
    self.animates = animates
    self.colorStyle = colorStyle
  }

  func makeNSView(context: Context) -> CoreAnimationActivityDotNSView {
    CoreAnimationActivityDotNSView()
  }

  func updateNSView(_ view: CoreAnimationActivityDotNSView, context: Context) {
    view.configure(animates: animates, color: color)
  }

  private var color: NSColor {
    switch colorStyle {
    case .accent:
      return .controlAccentColor
    case .secondary:
      return .secondaryLabelColor
    }
  }
}

final class CoreAnimationActivityDotNSView: NSView {
  private static let pulseAnimationKey = "org2.activity-pulse"
  private let dotLayer = CAShapeLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.addSublayer(dotLayer)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
    layer?.addSublayer(dotLayer)
  }

  override func layout() {
    super.layout()
    let diameter = min(bounds.width, bounds.height)
    let dotBounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
    dotLayer.bounds = dotBounds
    dotLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    dotLayer.path = CGPath(ellipseIn: dotBounds, transform: nil)
  }

  func configure(animates: Bool, color: NSColor) {
    dotLayer.fillColor = color.cgColor

    if animates {
      guard dotLayer.animation(forKey: Self.pulseAnimationKey) == nil else { return }

      let opacity = CABasicAnimation(keyPath: "opacity")
      opacity.fromValue = 0.58
      opacity.toValue = 1

      let scale = CABasicAnimation(keyPath: "transform.scale")
      scale.fromValue = 0.78
      scale.toValue = 1

      let group = CAAnimationGroup()
      group.animations = [opacity, scale]
      group.duration = 0.85
      group.autoreverses = true
      group.repeatCount = .infinity
      group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      group.isRemovedOnCompletion = false
      dotLayer.add(group, forKey: Self.pulseAnimationKey)
    } else {
      dotLayer.removeAnimation(forKey: Self.pulseAnimationKey)
      dotLayer.opacity = 1
      dotLayer.setAffineTransform(.identity)
    }
  }

  var isAnimatingForTesting: Bool {
    dotLayer.animation(forKey: Self.pulseAnimationKey) != nil
  }
}

/// A small clock-backed label whose updates stay inside AppKit instead of
/// invalidating the surrounding SwiftUI graph every second. This is used for
/// live elapsed/freshness text in large chat views.
struct AppKitPeriodicLabel: NSViewRepresentable {
  let interval: TimeInterval
  let font: NSFont
  let color: NSColor
  let textProvider: (Date) -> String

  init(
    interval: TimeInterval = 1,
    font: NSFont,
    color: NSColor,
    textProvider: @escaping (Date) -> String
  ) {
    self.interval = interval
    self.font = font
    self.color = color
    self.textProvider = textProvider
  }

  func makeNSView(context: Context) -> AppKitPeriodicTextField {
    AppKitPeriodicTextField()
  }

  func updateNSView(_ view: AppKitPeriodicTextField, context: Context) {
    view.configure(
      interval: interval,
      font: font,
      color: color,
      textProvider: textProvider
    )
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: AppKitPeriodicTextField,
    context: Context
  ) -> CGSize? {
    // AppKit's intrinsic text width can exceed SwiftUI's reserved status slot.
    // Honor the proposal so truncation happens inside that slot, even as the
    // timer changes the label without invalidating the surrounding layout.
    let intrinsic = nsView.intrinsicContentSize
    return CGSize(
      width: max(0, proposal.width ?? intrinsic.width),
      height: max(0, intrinsic.height)
    )
  }

  static func dismantleNSView(_ view: AppKitPeriodicTextField, coordinator: ()) {
    view.stopUpdating()
  }
}

final class AppKitPeriodicTextField: NSTextField {
  private var updateTimer: Timer?
  private var updateInterval: TimeInterval = 1
  private var textProvider: ((Date) -> String)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureLabelBehavior()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureLabelBehavior()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      stopUpdating()
    } else {
      startUpdatingIfNeeded()
    }
  }

  func configure(
    interval: TimeInterval,
    font: NSFont,
    color: NSColor,
    textProvider: @escaping (Date) -> String
  ) {
    self.font = font
    textColor = color
    self.textProvider = textProvider

    let normalizedInterval = max(0.25, interval)
    if abs(updateInterval - normalizedInterval) > 0.001 {
      updateInterval = normalizedInterval
      stopUpdating()
    }

    refresh(at: Date())
    startUpdatingIfNeeded()
  }

  func stopUpdating() {
    updateTimer?.invalidate()
    updateTimer = nil
  }

  private func configureLabelBehavior() {
    isEditable = false
    isSelectable = false
    isBezeled = false
    drawsBackground = false
    lineBreakMode = .byTruncatingTail
    maximumNumberOfLines = 1
    focusRingType = .none
  }

  /// `NSTextField` normally invalidates its intrinsic size whenever its text
  /// changes. In a SwiftUI hosting hierarchy that can turn a one-second clock
  /// tick into a layout pass for the entire workspace window. The surrounding
  /// stack already gives these compact status labels their layout footprint;
  /// only their layer contents need to change while the clock advances.
  override func invalidateIntrinsicContentSize() {
    // Intentionally keep the initial SwiftUI measurement stable.
  }

  private func startUpdatingIfNeeded() {
    guard window != nil, updateTimer == nil else { return }
    let timer = Timer(
      timeInterval: updateInterval,
      target: self,
      selector: #selector(updateTimerDidFire),
      userInfo: nil,
      repeats: true
    )
    RunLoop.main.add(timer, forMode: .common)
    updateTimer = timer
  }

  @objc private func updateTimerDidFire() {
    guard NSApplication.shared.isActive else { return }
    refresh(at: Date())
  }

  private func refresh(at date: Date) {
    guard let textProvider else { return }
    let nextValue = textProvider(date)
    guard stringValue != nextValue else { return }
    stringValue = nextValue
  }

  var isUpdatingForTesting: Bool {
    updateTimer != nil
  }
}
