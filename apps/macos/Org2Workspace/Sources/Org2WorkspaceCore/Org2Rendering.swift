import Foundation

public enum OrgRenderedBlock: Equatable, Sendable {
  case heading(OrgHeadingBlock)
  case planning(OrgPlanningBlock)
  case properties([OrgPropertyRow])
  case quote([String])
  case source(language: String?, lines: [String])
  case listItem(indent: Int, marker: String, text: String)
  case paragraph(String)
  case keyword(key: String, value: String)
  case blank
}

public struct OrgHeadingBlock: Equatable, Sendable {
  public let level: Int
  public let todo: String?
  public let priority: String?
  public let title: String
  public let tags: [String]
}

public struct OrgPlanningBlock: Equatable, Sendable {
  public let kind: String
  public let value: String
}

public struct OrgPropertyRow: Equatable, Sendable {
  public let key: String
  public let value: String
}

public enum OrgEntryRenderer {
  public static func parse(_ raw: String) -> [OrgRenderedBlock] {
    let lines = raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var blocks: [OrgRenderedBlock] = []
    var index = 0

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      if trimmed.isEmpty {
        appendBlank(to: &blocks)
        index += 1
        continue
      }

      if let heading = parseHeading(line) {
        blocks.append(.heading(heading))
        index += 1
        continue
      }

      if let planning = parsePlanning(line) {
        blocks.append(.planning(planning))
        index += 1
        continue
      }

      if trimmed.uppercased() == ":PROPERTIES:" {
        let parsed = parseProperties(lines: lines, startingAt: index)
        blocks.append(.properties(parsed.rows))
        index = parsed.nextIndex
        continue
      }

      if isBeginQuote(trimmed) {
        let parsed = collectBlock(lines: lines, startingAt: index + 1, endToken: "#+end_quote")
        blocks.append(.quote(parsed.lines.map(Org2Display.cleanInline)))
        index = parsed.nextIndex
        continue
      }

      if let sourceBlock = sourceBlock(from: trimmed) {
        let parsed = collectBlock(lines: lines, startingAt: index + 1, endToken: sourceBlock.endToken)
        blocks.append(.source(language: sourceBlock.language, lines: parsed.lines))
        index = parsed.nextIndex
        continue
      }

      if let keyword = parseKeyword(line) {
        blocks.append(.keyword(key: keyword.key, value: Org2Display.cleanInline(keyword.value)))
        index += 1
        continue
      }

      if let listItem = parseListItem(line) {
        blocks.append(.listItem(
          indent: listItem.indent,
          marker: listItem.marker,
          text: Org2Display.cleanInline(listItem.text)
        ))
        index += 1
        continue
      }

      let parsed = collectParagraph(lines: lines, startingAt: index)
      blocks.append(.paragraph(Org2Display.cleanInline(parsed.text)))
      index = parsed.nextIndex
    }

    return blocks
  }

  private static func appendBlank(to blocks: inout [OrgRenderedBlock]) {
    if case .blank? = blocks.last { return }
    blocks.append(.blank)
  }

  private static func parseHeading(_ line: String) -> OrgHeadingBlock? {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return nil }
    let afterStars = line.dropFirst(stars.count)
    guard afterStars.first?.isWhitespace == true else { return nil }

    var rest = String(afterStars).trimmingCharacters(in: .whitespaces)
    var tags: [String] = []
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      let rawTags = String(rest[tagRange]).trimmingCharacters(in: .whitespacesAndNewlines)
      tags = rawTags
        .split(separator: ":")
        .map(String.init)
        .filter { !$0.isEmpty }
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    let todoKeywords = Set(["TODO", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED", "CANCELLED"])
    var todo: String?
    var priority: String?

    if let first = tokens.first, todoKeywords.contains(first.uppercased()) {
      todo = first.uppercased()
      tokens.removeFirst()
    }

    if let first = tokens.first,
       first.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      priority = first
        .replacingOccurrences(of: "[#", with: "")
        .replacingOccurrences(of: "]", with: "")
        .uppercased()
      tokens.removeFirst()
    }

    return OrgHeadingBlock(
      level: stars.count,
      todo: todo,
      priority: priority,
      title: Org2Display.cleanInline(tokens.joined(separator: " ")),
      tags: tags
    )
  }

  private static func parsePlanning(_ line: String) -> OrgPlanningBlock? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    for kind in ["SCHEDULED", "DEADLINE", "CLOSED"] {
      let prefix = "\(kind):"
      guard trimmed.uppercased().hasPrefix(prefix) else { continue }
      let value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
      return OrgPlanningBlock(kind: kind, value: value)
    }
    return nil
  }

  private static func parseProperties(lines: [String], startingAt index: Int) -> (rows: [OrgPropertyRow], nextIndex: Int) {
    var rows: [OrgPropertyRow] = []
    var cursor = index + 1
    while cursor < lines.count {
      let trimmed = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.uppercased() == ":END:" {
        return (rows, cursor + 1)
      }
      if let property = parsePropertyLine(trimmed) {
        rows.append(property)
      }
      cursor += 1
    }
    return (rows, cursor)
  }

  private static func parsePropertyLine(_ line: String) -> OrgPropertyRow? {
    guard line.hasPrefix(":"),
          let secondColon = line.dropFirst().firstIndex(of: ":")
    else {
      return nil
    }
    let key = String(line[line.index(after: line.startIndex)..<secondColon])
    let value = String(line[line.index(after: secondColon)...]).trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    return OrgPropertyRow(key: key, value: Org2Display.cleanInline(value))
  }

  private static func isBeginQuote(_ trimmed: String) -> Bool {
    trimmed.lowercased() == "#+begin_quote"
  }

  private static func sourceBlock(from trimmed: String) -> (language: String?, endToken: String)? {
    let lowercased = trimmed.lowercased()
    if lowercased.hasPrefix("#+begin_example") {
      return (nil, "#+end_example")
    }
    guard lowercased.hasPrefix("#+begin_src") else { return nil }
    let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return (parts.count > 1 ? parts[1] : nil, "#+end_src")
  }

  private static func collectBlock(lines: [String], startingAt index: Int, endToken: String) -> (lines: [String], nextIndex: Int) {
    var output: [String] = []
    var cursor = index
    while cursor < lines.count {
      let trimmed = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if trimmed == endToken {
        return (output, cursor + 1)
      }
      output.append(lines[cursor])
      cursor += 1
    }
    return (output, cursor)
  }

  private static func parseKeyword(_ line: String) -> (key: String, value: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("#+"),
          let separator = trimmed.firstIndex(of: ":")
    else {
      return nil
    }
    let keyStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
    let key = String(trimmed[keyStart..<separator]).uppercased()
    let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    return (key, value)
  }

  private static func parseListItem(_ line: String) -> (indent: Int, marker: String, text: String)? {
    guard let range = line.range(of: #"^(\s*)([-+]|[0-9]+[.)])\s+(.*)$"#, options: .regularExpression) else {
      return nil
    }
    let matched = String(line[range])
    let leadingSpaces = matched.prefix { $0 == " " || $0 == "\t" }
    let rest = String(matched.dropFirst(leadingSpaces.count))
    guard let separator = rest.firstIndex(where: { $0.isWhitespace }) else { return nil }
    let marker = String(rest[..<separator])
    let text = String(rest[separator...]).trimmingCharacters(in: .whitespaces)
    return (leadingSpaces.count / 2, marker, text)
  }

  private static func collectParagraph(lines: [String], startingAt index: Int) -> (text: String, nextIndex: Int) {
    var output: [String] = []
    var cursor = index
    while cursor < lines.count {
      let line = lines[cursor]
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || isBoundary(line) {
        break
      }
      output.append(trimmed)
      cursor += 1
    }
    return (output.joined(separator: "\n"), cursor)
  }

  private static func isBoundary(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    return parseHeading(line) != nil
      || parsePlanning(line) != nil
      || trimmed.uppercased() == ":PROPERTIES:"
      || isBeginQuote(trimmed)
      || sourceBlock(from: trimmed) != nil
      || parseKeyword(line) != nil
      || parseListItem(line) != nil
  }
}
