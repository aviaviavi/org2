import Foundation

struct MobileSearchEntry: Codable, Hashable, Identifiable, Sendable {
  let path: String
  let title: String
  let parent: String
  let line: Int
  let nodeID: String
  let body: String
  var id: String { "\(path):\(line)" }

  func preview(query: String) -> String {
    let text = body.replacingOccurrences(of: "\n", with: " ")
    let term = query.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? query
    let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
    let start = match.map { text.index($0.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
    return (start == text.startIndex ? "" : "…") + text[start...].prefix(180)
  }
}

struct MobileCorpusSearchIndex: Sendable {
  let id = UUID()
  let entries: [MobileSearchEntry]
  private let keys: [(title: String, titleBytes: Data, path: Data, body: Data)]

  init(entries: [MobileSearchEntry] = []) {
    self.entries = entries
    // Normalized UTF-8 makes literal lookup independent of Foundation's repeated
    // Unicode string searches; normalization happens once when the index changes.
    keys = entries.map {
      let title = Self.normalize($0.title)
      return (title, Data(title.utf8), Data(Self.normalize($0.path).utf8), Data(Self.normalize($0.body).utf8))
    }
  }

  static func normalize(_ text: String) -> String {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
  }

  func search(_ query: String, limit: Int = 100) -> [MobileSearchEntry] {
    let needle = Self.normalize(query)
    guard !needle.isEmpty else { return [] }
    let needleBytes = Data(needle.utf8)
    let needleCount = needle.count
    let terms = query.split(whereSeparator: \.isWhitespace).map { Data(Self.normalize(String($0)).utf8) }.filter { !$0.isEmpty }
    var matches: [(Int, Int)] = []
    for (offset, key) in keys.enumerated() {
      if Task.isCancelled { return [] }
      let score: Int
      if key.title == needle { score = 1000 }
      else if key.title.hasPrefix(needle) { score = 900 }
      else if key.titleBytes.range(of: needleBytes) != nil { score = 800 }
      else if needleCount >= 3, key.title.count <= max(needleCount * 3, 24), Self.isSubsequence(needle, of: key.title) { score = 600 }
      else if key.path.range(of: needleBytes) != nil { score = 400 }
      else if !terms.isEmpty && terms.allSatisfy({ term in
        key.titleBytes.range(of: term) != nil
          || key.path.range(of: term) != nil
          || key.body.range(of: term) != nil
      }) { score = 200 }
      else { continue }
      matches.append((offset, score))
    }
    return matches.sorted {
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      let left = entries[$0.0], right = entries[$1.0]
      if left.path != right.path { return left.path < right.path }
      return left.line < right.line
    }.prefix(max(0, limit)).map { entries[$0.0] }
  }

  private static func isSubsequence(_ needle: String, of value: String) -> Bool {
    var index = needle.startIndex
    for character in value where index < needle.endIndex {
      if character == needle[index] { index = needle.index(after: index) }
    }
    return index == needle.endIndex
  }
}

// Link transport only. Entry semantics are resolved by the shared Org2 runtime.
struct MobileDocumentLink: Hashable, Sendable {
  let path: String
  let selector: String
  let nodeID: String?

  static func parse(_ raw: String, relativeTo sourcePath: String? = nil) -> Self? {
    var target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
    if let url = URL(string: target), url.scheme == "org2-workspace", url.host == "open-link",
       let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "target" })?.value {
      target = value
    }
    target = target.removingPercentEncoding ?? target
    if target.hasPrefix("id:"), target.count > 3 {
      return Self(path: "", selector: target, nodeID: String(target.dropFirst(3)))
    }
    if target.hasPrefix("file:") { target = String(target.dropFirst(5)) }
    // URLs belonging to other apps are never interpreted as corpus paths.
    if let range = target.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) {
      let prefix = target[range].dropLast().lowercased()
      if !prefix.hasSuffix(".org"), !prefix.hasSuffix(".org2") { return nil }
    }
    if (target.hasPrefix("#") || target.hasPrefix("*")), let sourcePath {
      return Self(path: sourcePath, selector: target, nodeID: nil)
    }
    guard let range = target.range(of: #"\.(?:org2|org)(?=$|::|:[1-9][0-9]*(?:-[1-9][0-9]*)?$|#)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
    var path = String(target[..<range.upperBound])
    let suffix = String(target[range.upperBound...])
    let selector: String
    if suffix.hasPrefix("::") { selector = String(suffix.dropFirst(2)) }
    else if suffix.hasPrefix(":") { selector = String(suffix.dropFirst().split(separator: "-").first ?? "") }
    else { selector = suffix }
    if let sourcePath, !path.hasPrefix("/"), !path.hasPrefix("~") {
      path = (sourcePath as NSString).deletingLastPathComponent + "/" + path
      if path.hasPrefix("/") && !(sourcePath.hasPrefix("/")) { path.removeFirst() }
    }
    return Self(path: path, selector: selector, nodeID: nil)
  }
}
