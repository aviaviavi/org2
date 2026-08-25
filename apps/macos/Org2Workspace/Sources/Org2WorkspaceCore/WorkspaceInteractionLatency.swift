import AppKit
import OSLog
import QuartzCore

@MainActor
enum WorkspaceInteractionLatency {
  enum Kind: String, CaseIterable {
    case pointerToWindowUpdate = "pointer-to-window-update"
    case sourceEditorKeyToDraw = "source-editor-key-to-draw"
    case sourceEditorDragToDraw = "source-editor-drag-to-draw"
    case composerKeyToDraw = "composer-key-to-draw"

    var budgetMilliseconds: Double { 16.7 }
  }

  struct Token {
    let kind: Kind
    let startedAt: CFTimeInterval
    let interval: OSSignpostIntervalState
  }

  private static let signposter = OSSignposter(
    subsystem: "org.org2.workspace",
    category: "InteractionLatency"
  )
  private static let logger = Logger(
    subsystem: "org.org2.workspace",
    category: "InteractionLatency"
  )
  private static let rollingSampleLimit = 120
  private static var samplesByKind: [Kind: [Double]] = [:]

  static func begin(_ kind: Kind) -> Token {
    Token(
      kind: kind,
      startedAt: CACurrentMediaTime(),
      interval: signposter.beginInterval("UI interaction to draw")
    )
  }

  static func finish(_ token: Token, finishedAt: CFTimeInterval = CACurrentMediaTime()) {
    signposter.endInterval("UI interaction to draw", token.interval)
    let elapsedMilliseconds = max(0, finishedAt - token.startedAt) * 1_000
    record(elapsedMilliseconds, for: token.kind)
    if elapsedMilliseconds > token.kind.budgetMilliseconds {
      logger.warning(
        "\(token.kind.rawValue, privacy: .public) exceeded the 16.7 ms frame budget: \(elapsedMilliseconds, format: .fixed(precision: 1)) ms"
      )
    }
  }

  static func percentile95(_ samples: [Double]) -> Double {
    guard !samples.isEmpty else { return 0 }
    let ordered = samples.sorted()
    let index = min(ordered.count - 1, Int(ceil(Double(ordered.count) * 0.95)) - 1)
    return ordered[max(0, index)]
  }

  private static func record(_ elapsedMilliseconds: Double, for kind: Kind) {
    var samples = samplesByKind[kind] ?? []
    samples.append(elapsedMilliseconds)
    guard samples.count >= rollingSampleLimit else {
      samplesByKind[kind] = samples
      return
    }

    let p95 = percentile95(samples)
    if p95 > kind.budgetMilliseconds {
      logger.warning(
        "\(kind.rawValue, privacy: .public) rolling p95 exceeded the 16.7 ms frame budget: \(p95, format: .fixed(precision: 1)) ms"
      )
    } else {
      logger.info(
        "\(kind.rawValue, privacy: .public) rolling p95: \(p95, format: .fixed(precision: 1)) ms"
      )
    }
    samplesByKind[kind] = []
  }
}

/// Measures a click from AppKit event delivery until the affected window's
/// next update pass. Instruments can display the emitted points-of-interest
/// intervals; slow samples and rolling p95 are also written to unified logs.
@MainActor
public final class WorkspacePointerLatencyMonitor: NSObject {
  public static let shared = WorkspacePointerLatencyMonitor()

  private var eventMonitor: Any?
  private var observesWindowUpdates = false
  private var pending: (windowNumber: Int, token: WorkspaceInteractionLatency.Token)?

  private override init() {
    super.init()
  }

  public func start() {
    guard eventMonitor == nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
      MainActor.assumeIsolated {
        if let window = event.window {
          self?.pending = (
            window.windowNumber,
            WorkspaceInteractionLatency.begin(.pointerToWindowUpdate)
          )
        }
      }
      return event
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidUpdate(_:)),
      name: NSWindow.didUpdateNotification,
      object: nil
    )
    observesWindowUpdates = true
  }

  public func stop() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    if observesWindowUpdates {
      NotificationCenter.default.removeObserver(
        self,
        name: NSWindow.didUpdateNotification,
        object: nil
      )
      observesWindowUpdates = false
    }
    pending = nil
  }

  @objc private func windowDidUpdate(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          let pending,
          pending.windowNumber == window.windowNumber
    else { return }
    self.pending = nil
    WorkspaceInteractionLatency.finish(pending.token)
  }
}
