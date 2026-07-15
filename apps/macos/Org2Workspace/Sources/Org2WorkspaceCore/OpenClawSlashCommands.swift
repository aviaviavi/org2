import AppKit
import Foundation

public struct OpenClawSlashCommand: Identifiable, Equatable, Sendable {
  public let name: String
  public let arguments: String
  public let summary: String
  public let systemImage: String
  public let isAgentAssisted: Bool

  public var id: String { name }
  public var invocation: String { arguments.isEmpty ? "/\(name)" : "/\(name) \(arguments)" }

  public init(
    name: String,
    arguments: String = "",
    summary: String,
    systemImage: String,
    isAgentAssisted: Bool = false
  ) {
    self.name = name
    self.arguments = arguments
    self.summary = summary
    self.systemImage = systemImage
    self.isAgentAssisted = isAgentAssisted
  }
}

public enum OpenClawSlashCommandParseResult: Equatable, Sendable {
  case message(String)
  case command(OpenClawSlashCommand, arguments: String)
  case unknown(String)
}

public enum OpenClawSlashCommands {
  public static let all: [OpenClawSlashCommand] = [
    .init(name: "help", summary: "Show every available command", systemImage: "questionmark.circle"),
    .init(name: "search", arguments: "QUERY", summary: "Search the current corpus", systemImage: "magnifyingglass"),
    .init(name: "open", arguments: "PATH", summary: "Open a corpus file", systemImage: "doc.text"),
    .init(name: "today", summary: "Open today's daily note", systemImage: "calendar"),
    .init(name: "agenda", summary: "Open the agenda", systemImage: "checklist"),
    .init(name: "related", summary: "Show backlinks to the current document", systemImage: "point.3.connected.trianglepath.dotted"),
    .init(name: "spellcheck", summary: "Check prose in the current document", systemImage: "textformat.abc.dottedunderline"),
    .init(name: "lint", summary: "Lint the current corpus", systemImage: "checkmark.seal"),
    .init(name: "export", arguments: "pdf|html", summary: "Export the current document", systemImage: "square.and.arrow.up"),
    .init(name: "publish", arguments: "preview [PROJECT]", summary: "Preview or build a publish project", systemImage: "globe"),
    .init(name: "brief", summary: "Ask the agent for a cited document brief", systemImage: "doc.text.magnifyingglass", isAgentAssisted: true),
    .init(name: "summarize", summary: "Ask the agent to summarize the current document", systemImage: "text.alignleft", isAgentAssisted: true),
  ]

  public static func parse(_ rawValue: String) -> OpenClawSlashCommandParseResult {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("/") else { return .message(value) }
    if value.hasPrefix("//") { return .message(String(value.dropFirst())) }

    let body = String(value.dropFirst())
    let split = body.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
    let name = split.first.map(String.init)?.lowercased() ?? ""
    guard !name.isEmpty else { return .unknown("") }
    guard let command = all.first(where: { $0.name == name }) else { return .unknown(name) }
    let arguments = split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return .command(command, arguments: arguments)
  }

  public static func suggestions(for rawValue: String, limit: Int = 7) -> [OpenClawSlashCommand] {
    guard rawValue.hasPrefix("/"), !rawValue.hasPrefix("//"), !rawValue.contains("\n") else { return [] }
    let fragment = rawValue.dropFirst().split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased() ?? ""
    guard !rawValue.dropFirst().contains(where: { $0.isWhitespace }) else { return [] }
    return Array(all.filter { fragment.isEmpty || $0.name.hasPrefix(fragment) }.prefix(limit))
  }

  public static var helpText: String {
    let rows = all.map { "\($0.invocation) — \($0.summary)" }.joined(separator: "\n")
    return "Available commands\n\n\(rows)\n\nUse // at the beginning to send a literal slash message."
  }
}

public struct OpenClawSpellingIssue: Equatable, Sendable {
  public let word: String
  public let line: Int
  public let suggestions: [String]
}

@MainActor
public enum OpenClawSpellchecker {
  public static func issues(
    in text: String,
    snapshot: OrgSourceEditorSemanticSnapshot,
    lineOffset: Int = 0,
    limit: Int = 50
  ) -> [OpenClawSpellingIssue] {
    let proseLines = Set(snapshot.regions
      .filter { $0.kind == .headline || $0.kind == .paragraph }
      .flatMap { $0.startLine...$0.endLine })
    let lines = text.components(separatedBy: .newlines)
    let checker = NSSpellChecker.shared
    var result: [OpenClawSpellingIssue] = []
    var seen = Set<String>()

    for (index, originalLine) in lines.enumerated() where proseLines.contains(index + 1) {
      var line = originalLine
      if snapshot.regions.contains(where: { $0.kind == .headline && $0.startLine == index + 1 }) {
        line = line.replacingOccurrences(of: #"^\*+\s+(?:[A-Z][A-Z0-9_-]*\s+)?(?:\[#[A-Z]\]\s+)?"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\s+:[[:alnum:]_@#%:]+:\s*$"#, with: "", options: .regularExpression)
      }
      let nsLine = line as NSString
      var cursor = 0
      while cursor < nsLine.length, result.count < limit {
        let range = checker.checkSpelling(
          of: line,
          startingAt: cursor,
          language: nil,
          wrap: false,
          inSpellDocumentWithTag: 0,
          wordCount: nil
        )
        guard range.location != NSNotFound, range.length > 0 else { break }
        let word = nsLine.substring(with: range)
        cursor = max(NSMaxRange(range), cursor + 1)
        guard word.unicodeScalars.contains(where: CharacterSet.letters.contains),
              !word.allSatisfy({ $0.isUppercase }),
              !line.contains("http://\(word)"), !line.contains("https://\(word)")
        else { continue }
        let key = "\(index):\(word.lowercased())"
        guard seen.insert(key).inserted else { continue }
        let guesses = checker.guesses(
          forWordRange: range,
          in: line,
          language: nil,
          inSpellDocumentWithTag: 0
        ) ?? []
        result.append(.init(word: word, line: lineOffset + index + 1, suggestions: Array(guesses.prefix(3))))
      }
      if result.count >= limit { break }
    }
    return result
  }
}
