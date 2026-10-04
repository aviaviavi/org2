import CoreGraphics
import Foundation

/// One thing happening in the corpus, normalized from chat threads, durable
/// runs, approvals, automations, and file changes so every Activity view
/// (list and map) reads the same model.
public struct WorkspaceActivityItem: Identifiable, Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable, CaseIterable {
    case needsYou
    case working
    case scheduled
    case changed
  }

  public enum Target: Hashable, Sendable {
    case thread(UUID)
    case run(String)
    case approval(ApprovalItem.ID)
    case workflow(String)
    case file(path: String, line: Int?)
  }

  public let id: String
  public let kind: Kind
  public let title: String
  public let detail: String
  /// Display name of the agent or destination doing the work, if any.
  public let agent: String?
  /// Corpus-relative path used to place the item on the map.
  public let relativePath: String?
  public let date: Date?
  public let state: HeadingWorkState?
  public let target: Target

  public init(
    id: String,
    kind: Kind,
    title: String,
    detail: String,
    agent: String? = nil,
    relativePath: String? = nil,
    date: Date? = nil,
    state: HeadingWorkState? = nil,
    target: Target
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.detail = detail
    self.agent = agent
    self.relativePath = relativePath
    self.date = date
    self.state = state
    self.target = target
  }
}

public struct WorkspaceActivitySnapshot: Equatable, Sendable {
  public var needsYou: [WorkspaceActivityItem] = []
  public var working: [WorkspaceActivityItem] = []
  public var scheduled: [WorkspaceActivityItem] = []
  public var changed: [WorkspaceActivityItem] = []

  public init() {}

  public var isEmpty: Bool {
    needsYou.isEmpty && working.isEmpty && scheduled.isEmpty && changed.isEmpty
  }

  public var allItems: [WorkspaceActivityItem] { needsYou + working + scheduled + changed }

  /// Agents with live work, with the number of places each is working.
  public var activeAgents: [(name: String, count: Int)] {
    var counts: [String: Int] = [:]
    for item in working {
      guard let agent = item.agent else { continue }
      counts[agent, default: 0] += 1
    }
    return counts.map { (name: $0.key, count: $0.value) }
      .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
  }
}

/// A folder or file tile on the Activity map at one zoom level.
public struct WorkspaceActivityArea: Identifiable, Hashable, Sendable {
  /// Corpus-relative path of the folder or file this tile represents.
  public let path: String
  public let name: String
  public let isFile: Bool
  public var fileCount: Int
  public var changedRecently: Int
  public var working: Int
  public var needsYou: Int
  public var scheduled: Int
  public var visitScore: Double
  public var agents: [String]

  public var id: String { path }

  public var hasSignals: Bool { working + needsYou + scheduled > 0 }

  /// Tile weight: files dominate but are compressed so one huge folder does
  /// not crowd out small active ones; live work and attention enlarge a tile.
  public var weight: Double {
    let base = isFile ? 1.0 : max(1.0, Double(fileCount).squareRoot() * 2)
    let attention = Double(needsYou) * 1.5 + Double(working) * 1.2 + Double(scheduled) * 0.6
    let familiarity = min(2.0, visitScore / 200)
    return base + attention + familiarity
  }
}

public enum WorkspaceActivityMap {
  /// Groups `files` beneath `prefix` ("" for the corpus root) into the
  /// immediate child folders and files, and attributes activity items to
  /// the tile that contains them.
  public static func areas(
    files: [CorpusFile],
    items: [WorkspaceActivityItem],
    prefix: String,
    now: Date,
    visitScores: [String: Double] = [:],
    recentWindow: TimeInterval = 24 * 3600,
    limit: Int = 48
  ) -> [WorkspaceActivityArea] {
    let normalizedPrefix = prefix.isEmpty || prefix.hasSuffix("/") ? prefix : prefix + "/"
    var areas: [String: WorkspaceActivityArea] = [:]

    func childKey(for relativePath: String) -> (path: String, name: String, isFile: Bool)? {
      guard relativePath.hasPrefix(normalizedPrefix) else { return nil }
      let remainder = relativePath.dropFirst(normalizedPrefix.count)
      guard !remainder.isEmpty else { return nil }
      if let slash = remainder.firstIndex(of: "/") {
        let name = String(remainder[..<slash])
        return (normalizedPrefix + name, name, false)
      }
      return (relativePath, String(remainder), true)
    }

    for file in files {
      guard let key = childKey(for: file.relativePath) else { continue }
      var area = areas[key.path] ?? WorkspaceActivityArea(
        path: key.path, name: key.name, isFile: key.isFile,
        fileCount: 0, changedRecently: 0, working: 0, needsYou: 0, scheduled: 0,
        visitScore: 0, agents: []
      )
      area.fileCount += 1
      if let modifiedAt = file.modifiedAt, now.timeIntervalSince(modifiedAt) < recentWindow {
        area.changedRecently += 1
      }
      area.visitScore += visitScores[file.relativePath] ?? 0
      areas[key.path] = area
    }

    for item in items {
      guard let relativePath = item.relativePath,
            let key = childKey(for: relativePath),
            var area = areas[key.path]
      else { continue }
      switch item.kind {
      case .needsYou: area.needsYou += 1
      case .working: area.working += 1
      case .scheduled: area.scheduled += 1
      case .changed: break
      }
      if item.kind == .working, let agent = item.agent, !area.agents.contains(agent) {
        area.agents.append(agent)
      }
      areas[key.path] = area
    }

    var sorted = areas.values.sorted { lhs, rhs in
      if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
      return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
    if sorted.count > limit {
      // Keep every tile that has live signals, then the heaviest of the rest.
      let signaled = sorted.filter(\.hasSignals)
      let rest = sorted.filter { !$0.hasSignals }.prefix(max(0, limit - signaled.count))
      sorted = (signaled + rest).sorted { $0.weight > $1.weight }
    }
    return sorted
  }

  /// Squarified treemap (Bruls, Huizing & van Wijk). Returns one rect per
  /// weight, in input order, tiling `bounds` with near-square cells.
  public static func treemap(weights: [Double], in bounds: CGRect) -> [CGRect] {
    guard !weights.isEmpty, bounds.width > 0, bounds.height > 0 else {
      return Array(repeating: .zero, count: weights.count)
    }
    let positive = weights.map { max($0, 0.0001) }
    let total = positive.reduce(0, +)
    let scale = Double(bounds.width * bounds.height) / total
    let order = positive.indices.sorted { positive[$0] > positive[$1] }
    var result = Array(repeating: CGRect.zero, count: weights.count)
    var remaining = bounds
    var row: [Int] = []

    func worst(_ row: [Int], side: Double) -> Double {
      let areas = row.map { positive[$0] * scale }
      let sum = areas.reduce(0, +)
      guard let maxArea = areas.max(), let minArea = areas.min(), sum > 0, side > 0 else { return .infinity }
      let sideSquared = side * side
      let sumSquared = sum * sum
      return max(sideSquared * maxArea / sumSquared, sumSquared / (sideSquared * minArea))
    }

    func layout(_ row: [Int]) {
      let areas = row.map { positive[$0] * scale }
      let sum = areas.reduce(0, +)
      guard sum > 0 else { return }
      if remaining.width >= remaining.height {
        // Lay the row as a column on the left.
        let width = CGFloat(sum) / max(remaining.height, 0.0001)
        var y = remaining.minY
        for (index, area) in zip(row, areas) {
          let height = CGFloat(area) / max(width, 0.0001)
          result[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
          y += height
        }
        remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                           width: max(0, remaining.width - width), height: remaining.height)
      } else {
        let height = CGFloat(sum) / max(remaining.width, 0.0001)
        var x = remaining.minX
        for (index, area) in zip(row, areas) {
          let width = CGFloat(area) / max(height, 0.0001)
          result[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
          x += width
        }
        remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                           width: remaining.width, height: max(0, remaining.height - height))
      }
    }

    for index in order {
      let side = Double(min(remaining.width, remaining.height))
      if row.isEmpty || worst(row + [index], side: side) <= worst(row, side: side) {
        row.append(index)
      } else {
        layout(row)
        row = [index]
      }
    }
    if !row.isEmpty { layout(row) }
    return result
  }

  /// Breadcrumb components for a map prefix such as "notes/projects".
  public static func breadcrumbs(for prefix: String) -> [(name: String, path: String)] {
    var result: [(String, String)] = []
    var path = ""
    for component in prefix.split(separator: "/") {
      path = path.isEmpty ? String(component) : path + "/" + component
      result.append((String(component), path))
    }
    return result
  }

  /// Normalizes a run context or file reference such as `file:notes/a.org:12`
  /// or an absolute path into a corpus-relative path, without the line suffix.
  public static func relativePath(fromReference raw: String, corpusRoot: String?) -> String? {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("file:") { value.removeFirst("file:".count) }
    if let range = value.range(of: #":\d+(-\d+)?$"#, options: .regularExpression) {
      value.removeSubrange(range)
    }
    guard !value.isEmpty, !value.contains("://") else { return nil }
    if value.hasPrefix("/") {
      guard let corpusRoot else { return nil }
      let root = corpusRoot.hasSuffix("/") ? String(corpusRoot.dropLast()) : corpusRoot
      let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
      guard standardized.hasPrefix(root + "/") else { return nil }
      return String(standardized.dropFirst(root.count + 1))
    }
    if value.hasPrefix("./") { value.removeFirst(2) }
    return value
  }
}
