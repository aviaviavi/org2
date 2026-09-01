import AppKit
import OSLog
import QuartzCore

@MainActor
enum WorkspaceInteractionLatency {
  enum Kind: String, CaseIterable, Sendable {
    case pointerToWindowUpdate = "pointer-to-window-update"
    case sourceEditorKeyToDraw = "source-editor-key-to-draw"
    case sourceEditorPointerToDraw = "source-editor-pointer-to-draw"
    case sourceEditorDragToDraw = "source-editor-drag-to-draw"
    case composerKeyToDraw = "composer-key-to-draw"
    case applicationActivationToDraw = "application-activation-to-draw"
    case workspaceNavigationToDraw = "workspace-navigation-to-draw"
    case threadSwitchToDraw = "thread-switch-to-draw"
    case windowResizeToDraw = "window-resize-to-draw"
    case corpusEventBurst = "corpus-event-burst"

    var budgetMilliseconds: Double {
      switch self {
      case .pointerToWindowUpdate,
           .sourceEditorKeyToDraw,
           .sourceEditorPointerToDraw,
           .composerKeyToDraw:
        16.7
      case .sourceEditorDragToDraw:
        33.4
      case .applicationActivationToDraw,
           .threadSwitchToDraw:
        50
      case .workspaceNavigationToDraw,
           .corpusEventBurst:
        50
      case .windowResizeToDraw:
        33.4
      }
    }
  }

  struct Snapshot: Equatable, Sendable {
    let kind: Kind
    let sampleCount: Int
    let retainedSampleCount: Int
    let budgetViolationCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let maximumMilliseconds: Double
    let budgetMilliseconds: Double

    var exceedsBudget: Bool {
      p95Milliseconds > budgetMilliseconds
    }
  }

  struct Token {
    let kind: Kind
    let startedAt: CFTimeInterval
    let interval: OSSignpostIntervalState
  }

  private struct RetainedSampleBuffer {
    var values: [Double] = []
    var nextReplacementIndex = 0

    mutating func append(_ value: Double, limit: Int) {
      guard limit > 0 else { return }
      if values.count < limit {
        values.append(value)
        return
      }
      values[nextReplacementIndex] = value
      nextReplacementIndex = (nextReplacementIndex + 1) % limit
    }
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
  private static let retainedSampleLimit = 2_048
  private static var rollingSamplesByKind: [Kind: [Double]] = [:]
  private static var retainedSamplesByKind: [Kind: RetainedSampleBuffer] = [:]
  private static var sampleCountByKind: [Kind: Int] = [:]
  private static var budgetViolationCountByKind: [Kind: Int] = [:]

  static func begin(_ kind: Kind) -> Token {
    Token(
      kind: kind,
      startedAt: CACurrentMediaTime(),
      interval: signposter.beginInterval("UI interaction to draw")
    )
  }

  @discardableResult
  static func finish(
    _ token: Token,
    finishedAt: CFTimeInterval = CACurrentMediaTime()
  ) -> Double {
    signposter.endInterval("UI interaction to draw", token.interval)
    let elapsedMilliseconds = max(0, finishedAt - token.startedAt) * 1_000
    record(elapsedMilliseconds, for: token.kind)
    if elapsedMilliseconds > token.kind.budgetMilliseconds {
      logger.warning(
        "\(token.kind.rawValue, privacy: .public) exceeded its \(token.kind.budgetMilliseconds, format: .fixed(precision: 1)) ms budget: \(elapsedMilliseconds, format: .fixed(precision: 1)) ms"
      )
    }
    return elapsedMilliseconds
  }

  static func percentile95(_ samples: [Double]) -> Double {
    percentile(samples, fraction: 0.95)
  }

  static func snapshot(for kind: Kind) -> Snapshot {
    let retained = retainedSamplesByKind[kind]?.values ?? []
    return Snapshot(
      kind: kind,
      sampleCount: sampleCountByKind[kind, default: 0],
      retainedSampleCount: retained.count,
      budgetViolationCount: budgetViolationCountByKind[kind, default: 0],
      p50Milliseconds: percentile(retained, fraction: 0.50),
      p95Milliseconds: percentile95(retained),
      p99Milliseconds: percentile(retained, fraction: 0.99),
      maximumMilliseconds: retained.max() ?? 0,
      budgetMilliseconds: kind.budgetMilliseconds
    )
  }

  static func snapshots() -> [Snapshot] {
    Kind.allCases.map(snapshot(for:))
  }

  static func resetRecordedSamples() {
    rollingSamplesByKind = [:]
    retainedSamplesByKind = [:]
    sampleCountByKind = [:]
    budgetViolationCountByKind = [:]
  }

  static func recordForTesting(_ elapsedMilliseconds: Double, for kind: Kind) {
    record(max(0, elapsedMilliseconds), for: kind)
  }

  private static func percentile(_ samples: [Double], fraction: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let ordered = samples.sorted()
    let boundedFraction = min(1, max(0, fraction))
    let index = min(
      ordered.count - 1,
      Int(ceil(Double(ordered.count) * boundedFraction)) - 1
    )
    return ordered[max(0, index)]
  }

  private static func record(_ elapsedMilliseconds: Double, for kind: Kind) {
    sampleCountByKind[kind, default: 0] += 1
    if elapsedMilliseconds > kind.budgetMilliseconds {
      budgetViolationCountByKind[kind, default: 0] += 1
    }

    var retainedSamples = retainedSamplesByKind[kind] ?? RetainedSampleBuffer()
    retainedSamples.append(elapsedMilliseconds, limit: retainedSampleLimit)
    retainedSamplesByKind[kind] = retainedSamples

    var rollingSamples = rollingSamplesByKind[kind] ?? []
    rollingSamples.append(elapsedMilliseconds)
    guard rollingSamples.count >= rollingSampleLimit else {
      rollingSamplesByKind[kind] = rollingSamples
      return
    }

    let p95 = percentile95(rollingSamples)
    if p95 > kind.budgetMilliseconds {
      logger.warning(
        "\(kind.rawValue, privacy: .public) rolling p95 exceeded its \(kind.budgetMilliseconds, format: .fixed(precision: 1)) ms budget: \(p95, format: .fixed(precision: 1)) ms"
      )
    } else {
      logger.info(
        "\(kind.rawValue, privacy: .public) rolling p95: \(p95, format: .fixed(precision: 1)) ms"
      )
    }
    rollingSamplesByKind[kind] = []
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

  func beginPointerSampleForTesting(in window: NSWindow) {
    pending = (
      window.windowNumber,
      WorkspaceInteractionLatency.begin(.pointerToWindowUpdate)
    )
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
