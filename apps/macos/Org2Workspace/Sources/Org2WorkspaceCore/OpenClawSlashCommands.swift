import AppKit
import Foundation

public struct OpenClawSlashCommand: Identifiable, Equatable, Sendable {
  public enum Origin: String, Sendable {
    case org2
    case builtInSkill
    case corpusSkill
    case openClaw
  }

  public let name: String
  public let aliases: [String]
  public let arguments: String
  public let summary: String
  public let systemImage: String
  public let isAgentAssisted: Bool
  public let origin: Origin
  public let skillInstructions: String?

  public var id: String { "\(origin.rawValue):\(name)" }
  public var invocation: String { arguments.isEmpty ? "/\(name)" : "/\(name) \(arguments)" }

  public init(
    name: String,
    aliases: [String] = [],
    arguments: String = "",
    summary: String,
    systemImage: String,
    isAgentAssisted: Bool = false,
    origin: Origin = .org2,
    skillInstructions: String? = nil
  ) {
    self.name = name
    self.aliases = aliases
    self.arguments = arguments
    self.summary = summary
    self.systemImage = systemImage
    self.isAgentAssisted = isAgentAssisted
    self.origin = origin
    self.skillInstructions = skillInstructions
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
    .init(name: "publish", arguments: "document | preview [PROJECT]", summary: "Publish this document or build a site project", systemImage: "globe"),
    .init(name: "brief", summary: "Ask the agent for a cited document brief", systemImage: "doc.text.magnifyingglass", isAgentAssisted: true),
    .init(name: "summarize", summary: "Ask the agent to summarize the current document", systemImage: "text.alignleft", isAgentAssisted: true),
  ]

  public static func parse(_ rawValue: String) -> OpenClawSlashCommandParseResult {
    parse(rawValue, gatewayCommands: [])
  }

  public static func parse(
    _ rawValue: String,
    gatewayCommands: [OpenClawSlashCommand],
    corpusSkills: [OpenClawSlashCommand] = []
  ) -> OpenClawSlashCommandParseResult {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("/") else { return .message(value) }
    if value.hasPrefix("//") { return .message(String(value.dropFirst())) }

    let body = String(value.dropFirst())
    let split = body.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
    let name = split.first.map(String.init)?.lowercased() ?? ""
    guard !name.isEmpty else { return .unknown("") }
    guard let command = merged(
      with: gatewayCommands,
      corpusSkills: corpusSkills
    ).first(where: { $0.matches(name) }) else {
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
    corpusSkills: [OpenClawSlashCommand] = [],
    limit: Int = 7
  ) -> [OpenClawSlashCommand] {
    guard rawValue.hasPrefix("/"), !rawValue.hasPrefix("//"), !rawValue.contains("\n") else { return [] }
    let fragment = rawValue.dropFirst().split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased() ?? ""
    guard !rawValue.dropFirst().contains(where: { $0.isWhitespace }) else { return [] }
    return Array(merged(with: gatewayCommands, corpusSkills: corpusSkills).filter { command in
      fragment.isEmpty
        || command.name.hasPrefix(fragment)
        || command.aliases.contains(where: { $0.hasPrefix(fragment) })
    }.prefix(limit))
  }

  public static var helpText: String {
    helpText(gatewayCommands: [])
  }

  public static func helpText(
    gatewayCommands: [OpenClawSlashCommand],
    corpusSkills: [OpenClawSlashCommand] = []
  ) -> String {
    let localRows = all.map { "\($0.invocation) — \($0.summary)" }.joined(separator: "\n")
    let skills = merged(with: gatewayCommands, corpusSkills: corpusSkills).filter {
      $0.origin == .builtInSkill || $0.origin == .corpusSkill
    }
    let skillSection: String
    if skills.isEmpty {
      skillSection = ""
    } else {
      let rows = skills.map { "\($0.invocation) — \($0.summary)" }.joined(separator: "\n")
      skillSection = "\n\nAgent skills\n\n\(rows)"
    }
    let remote = merged(with: gatewayCommands, corpusSkills: corpusSkills).filter {
      $0.origin == .openClaw
    }
    let remoteSection: String
    if remote.isEmpty {
      remoteSection = ""
    } else {
      let rows = remote.map { "\($0.invocation) — \($0.summary)" }.joined(separator: "\n")
      remoteSection = "\n\nOpenClaw commands\n\n\(rows)"
    }
    return "Org2 commands\n\n\(localRows)\(skillSection)\(remoteSection)\n\nUse // at the beginning to send a literal slash message."
  }

  public static func merged(
    with gatewayCommands: [OpenClawSlashCommand],
    corpusSkills: [OpenClawSlashCommand] = []
  ) -> [OpenClawSlashCommand] {
    let localNames = Set(all.map(\.name))
    let uniqueSkills = corpusSkills.filter { command in
      (command.origin == .builtInSkill || command.origin == .corpusSkill)
        && !localNames.contains(command.name)
    }
    let knownNames = localNames.union(uniqueSkills.map(\.name))
    return all + uniqueSkills + gatewayCommands.filter { command in
      command.origin == .openClaw && !knownNames.contains(command.name)
    }
  }

  public static func isGatewayCommand(
    _ rawValue: String,
    gatewayCommands: [OpenClawSlashCommand],
    corpusSkills: [OpenClawSlashCommand] = []
  ) -> Bool {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("/"), !value.hasPrefix("//") else { return false }
    switch parse(value, gatewayCommands: gatewayCommands, corpusSkills: corpusSkills) {
    case .command(let command, _): return command.origin != .org2
    case .unknown(let name): return !name.isEmpty
    case .message: return false
    }
  }
}

enum CorpusAgentSkillCatalog {
  static func commands(
    in corpusRoot: URL,
    bundledSkillURL: URL? = BuiltInOrg2Skill.availableSourceURL()
  ) -> [OpenClawSlashCommand] {
    let skillsRoot = corpusRoot
      .appendingPathComponent(".agents", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
    let directories = (try? FileManager.default.contentsOfDirectory(
      at: skillsRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []

    var seenNames: Set<String> = []
    var commands: [OpenClawSlashCommand] = directories
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
      .compactMap { directory -> OpenClawSlashCommand? in
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
          return nil
        }
        return command(
          at: directory.appendingPathComponent("SKILL.md"),
          fallbackName: directory.lastPathComponent,
          origin: .corpusSkill,
          seenNames: &seenNames
        )
      }
    if let bundledSkillURL,
       let bundled = command(
         at: bundledSkillURL,
         fallbackName: "org2",
         origin: .builtInSkill,
         seenNames: &seenNames
       ) {
      commands.append(bundled)
    }
    return commands
  }

  private static func command(
    at skillURL: URL,
    fallbackName: String,
    origin: OpenClawSlashCommand.Origin,
    seenNames: inout Set<String>
  ) -> OpenClawSlashCommand? {
    guard let source = try? String(contentsOf: skillURL, encoding: .utf8),
          let frontMatter = frontMatter(from: source),
          frontMatter["user-invocable"]?.lowercased() != "false"
    else {
      return nil
    }

    let name = normalizedCommandName(frontMatter["name"] ?? fallbackName)
    guard !name.isEmpty, seenNames.insert(name).inserted else { return nil }
    let declaredSummary = frontMatter["description"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = declaredSummary?.isEmpty == false
      ? declaredSummary ?? ""
      : "Use the \(name) corpus skill"
    return OpenClawSlashCommand(
      name: name,
      arguments: "[ARGS]",
      summary: summary,
      systemImage: "wand.and.stars",
      isAgentAssisted: true,
      origin: origin,
      skillInstructions: source
    )
  }

  private static func frontMatter(from source: String) -> [String: String]? {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
          let closingIndex = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
          })
    else {
      return nil
    }

    let frontMatterLines = Array(lines[1..<closingIndex])
    var values: [String: String] = [:]
    var index = 0
    while index < frontMatterLines.count {
      let line = frontMatterLines[index]
      guard let separator = line.firstIndex(of: ":") else {
        index += 1
        continue
      }
      let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      var value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasPrefix(">") || value.hasPrefix("|") {
        var continuation: [String] = []
        index += 1
        while index < frontMatterLines.count,
              frontMatterLines[index].first?.isWhitespace == true {
          continuation.append(frontMatterLines[index].trimmingCharacters(in: .whitespacesAndNewlines))
          index += 1
        }
        value = continuation.joined(separator: value.hasPrefix("|") ? "\n" : " ")
        values[key] = value
        continue
      }
      values[key] = unquoted(value)
      index += 1
    }
    return values
  }

  private static func normalizedCommandName(_ rawValue: String) -> String {
    let candidate = unquoted(rawValue).lowercased()
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    guard !candidate.isEmpty,
          candidate.unicodeScalars.allSatisfy(allowed.contains),
          candidate.first != "-",
          candidate.last != "-"
    else {
      return ""
    }
    return candidate
  }

  private static func unquoted(_ rawValue: String) -> String {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count >= 2,
          let first = value.first,
          let last = value.last,
          (first == "\"" && last == "\"") || (first == "'" && last == "'")
    else {
      return value
    }
    return String(value.dropFirst().dropLast())
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
