import Foundation

/// Per-corpus "frecency" (frequency × recency) for opened files, used to rank
/// Quick Open and the Activity view. Keyed by corpus-relative path and stored in
/// UserDefaults; it is disposable app state, never corpus content.
public struct WorkspaceFileFrecency: Codable, Equatable, Sendable {
  public static let maximumTrackedFiles = 400
  public static let visitsPerFile = 10

  /// Visit timestamps (seconds since 1970), newest last, per relative path.
  public private(set) var visitsByPath: [String: [Double]] = [:]

  public init(visitsByPath: [String: [Double]] = [:]) {
    self.visitsByPath = visitsByPath
  }

  public var isEmpty: Bool { visitsByPath.isEmpty }

  public mutating func recordVisit(_ relativePath: String, at date: Date) {
    guard !relativePath.isEmpty else { return }
    var visits = visitsByPath[relativePath] ?? []
    let time = date.timeIntervalSince1970
    // Collapse re-opens within a few seconds (reloads, tab restores) into one visit.
    if let last = visits.last, time - last < 5 {
      visits[visits.count - 1] = time
    } else {
      visits.append(time)
    }
    if visits.count > Self.visitsPerFile {
      visits.removeFirst(visits.count - Self.visitsPerFile)
    }
    visitsByPath[relativePath] = visits
    prune(now: date)
  }

  public mutating func rename(from oldPath: String, to newPath: String) {
    guard let visits = visitsByPath.removeValue(forKey: oldPath) else { return }
    visitsByPath[newPath] = visits
  }

  public func score(_ relativePath: String, now: Date) -> Double {
    guard let visits = visitsByPath[relativePath] else { return 0 }
    return Self.score(visits: visits, now: now)
  }

  /// Every tracked path with a positive score, highest first.
  public func ranked(now: Date) -> [(path: String, score: Double)] {
    visitsByPath
      .map { (path: $0.key, score: Self.score(visits: $0.value, now: now)) }
      .filter { $0.score > 0 }
      .sorted { lhs, rhs in
        lhs.score != rhs.score ? lhs.score > rhs.score : lhs.path < rhs.path
      }
  }

  public func scores(now: Date) -> [String: Double] {
    var result: [String: Double] = [:]
    for (path, visits) in visitsByPath {
      let value = Self.score(visits: visits, now: now)
      if value > 0 { result[path] = value }
    }
    return result
  }

  /// Bucketed recency weights in the style of browser frecency: recent visits
  /// dominate, but files opened often over weeks remain near the top.
  static func score(visits: [Double], now: Date) -> Double {
    let current = now.timeIntervalSince1970
    return visits.reduce(0) { total, time in
      let age = max(0, current - time)
      let weight: Double
      switch age {
      case ..<(4 * 3600): weight = 100
      case ..<(24 * 3600): weight = 70
      case ..<(7 * 24 * 3600): weight = 50
      case ..<(30 * 24 * 3600): weight = 30
      case ..<(90 * 24 * 3600): weight = 10
      default: weight = 0
      }
      return total + weight
    }
  }

  /// Quick Open bonus added to a fuzzy-match score. Bounded so frecency breaks
  /// ties and lifts familiar files without overriding a clearly better match.
  static func quickOpenBonus(_ score: Double) -> Int {
    guard score > 0 else { return 0 }
    return min(45, Int((score / 10).rounded()) + 5)
  }

  private mutating func prune(now: Date) {
    guard visitsByPath.count > Self.maximumTrackedFiles else { return }
    let keep = Set(ranked(now: now).prefix(Self.maximumTrackedFiles).map(\.path))
    visitsByPath = visitsByPath.filter { keep.contains($0.key) }
  }
}
