import AppKit
import Foundation

public struct OpenClawSlashCommand: Identifiable, Equatable, Sendable {
  public enum Origin: String, Sendable {
    case org2
    case openClaw
  }

  public let name: String
  public let aliases: [String]
  public let arguments: String
  public let summary: String
  public let systemImage: String
  public let isAgentAssisted: Bool
  public let origin: Origin

  public var id: String { "\(origin.rawValue):\(name)" }
  public var invocation: String { arguments.isEmpty ? "/\(name)" : "/\(name) \(arguments)" }

  public init(
    name: String,
    aliases: [String] = [],
    arguments: String = "",
    summary: String,
    systemImage: String,
    isAgentAssisted: Bool = false,
    origin: Origin = .org2
  ) {
    self.name = name
    self.aliases = aliases
    self.arguments = arguments
    self.summary = summary
    self.systemImage = systemImage
    self.isAgentAssisted = isAgentAssisted
    self.origin = origin
  }

  public func matches(_ candidate: String) -> Bool {
    name == candidate || aliases.contains(candidate)
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
    parse(rawValue, gatewayCommands: [])
  }

  public static func parse(
    _ rawValue: String,
    gatewayCommands: [OpenClawSlashCommand]
  ) -> OpenClawSlashCommandParseResult {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("/") else { return .message(value) }
    if value.hasPrefix("//") { return .message(String(value.dropFirst())) }

    let body = String(value.dropFirst())
    let split = body.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
    let name = split.first.map(String.init)?.lowercased() ?? ""
    guard !name.isEmpty else { return .unknown("") }
    guard let command = merged(with: gatewayCommands).first(where: { $0.matches(name) }) else {
      return .unknown(name)
    }
    let arguments = split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return .command(command, arguments: arguments)
  }

  public static func suggestions(for rawValue: String, limit: Int = 7) -> [OpenClawSlashCommand] {
    suggestions(for: rawValue, gatewayCommands: [], limit: limit)
  }

  public static func suggestions(
    for rawValue: String,
    gatewayCommands: [OpenClawSlashCommand],
    limit: Int = 7
  ) -> [OpenClawSlashCommand] {
    guard rawValue.hasPrefix("/"), !rawValue.hasPrefix("//"), !rawValue.contains("\n") else { return [] }
    let fragment = rawValue.dropFirst().split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased() ?? ""
    guard !rawValue.dropFirst().contains(where: { $0.isWhitespace }) else { return [] }
    return Array(merged(with: gatewayCommands).filter { command in
      fragment.isEmpty
        || command.name.hasPrefix(fragment)
        || command.aliases.contains(where: { $0.hasPrefix(fragment) })
    }.prefix(limit))
  }

  public static var helpText: String {
    helpText(gatewayCommands: [])
  }

  public static func helpText(gatewayCommands: [OpenClawSlashCommand]) -> String {
    let localRows = all.map { "\($0.invocation) — \($0.summary)" }.joined(separator: "\n")
    let remote = merged(with: gatewayCommands).filter { $0.origin == .openClaw }
    let remoteSection: String
    if remote.isEmpty {
      remoteSection = ""
    } else {
      let rows = remote.map { "\($0.invocation) — \($0.summary)" }.joined(separator: "\n")
      remoteSection = "\n\nOpenClaw commands\n\n\(rows)"
    }
    return "Org2 commands\n\n\(localRows)\(remoteSection)\n\nUse // at the beginning to send a literal slash message."
  }

  public static func merged(with gatewayCommands: [OpenClawSlashCommand]) -> [OpenClawSlashCommand] {
    let localNames = Set(all.map(\.name))
    return all + gatewayCommands.filter { command in
      command.origin == .openClaw && !localNames.contains(command.name)
    }
  }

  public static func isGatewayCommand(
    _ rawValue: String,
    gatewayCommands: [OpenClawSlashCommand]
  ) -> Bool {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("/"), !value.hasPrefix("//") else { return false }
    switch parse(value, gatewayCommands: gatewayCommands) {
    case .command(let command, _): return command.origin == .openClaw
    case .unknown(let name): return !name.isEmpty
    case .message: return false
    }
  }
}

enum OpenClawGatewayCommandCatalog {
  private struct Payload: Decodable {
    let commands: [Entry]
  }

  private struct Entry: Decodable {
    let name: String
    let textAliases: [String]?
    let description: String
    let category: String?
    let source: String
    let acceptsArgs: Bool
    let args: [Argument]?
  }

  private struct Argument: Decodable {
    let name: String
    let required: Bool?
  }

  static func decode(_ data: Data) throws -> [OpenClawSlashCommand] {
    try JSONDecoder().decode(Payload.self, from: data).commands.compactMap { entry in
      let name = normalizedName(entry.name)
      guard !name.isEmpty else { return nil }
      let aliases = (entry.textAliases ?? [])
        .map(normalizedName)
        .filter { !$0.isEmpty && $0 != name }
      let arguments = argumentSynopsis(for: entry)
      return OpenClawSlashCommand(
        name: name,
        aliases: Array(Set(aliases)).sorted(),
        arguments: arguments,
        summary: entry.description,
        systemImage: systemImage(source: entry.source, category: entry.category),
        origin: .openClaw
      )
    }
  }

  private static func normalizedName(_ rawValue: String) -> String {
    rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.whitespacesAndNewlines)).lowercased()
  }

  private static func argumentSynopsis(for entry: Entry) -> String {
    let arguments = (entry.args ?? []).map { argument in
      argument.required == true ? "<\(argument.name)>" : "[\(argument.name)]"
    }
    if !arguments.isEmpty { return arguments.joined(separator: " ") }
    return entry.acceptsArgs ? "[ARGS]" : ""
  }

  private static func systemImage(source: String, category: String?) -> String {
    switch source {
    case "plugin": return "puzzlepiece.extension"
    case "skill": return "wand.and.stars"
    default:
      switch category {
      case "session": return "bubble.left.and.bubble.right"
      case "status": return "info.circle"
      case "tools": return "wrench.and.screwdriver"
      case "management": return "gearshape"
      default: return "command"
      }
    }
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
