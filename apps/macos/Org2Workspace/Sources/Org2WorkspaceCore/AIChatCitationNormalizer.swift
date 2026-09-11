import Foundation

/// Compatibility for citations in older chat messages. New output uses Org links.
/// This is a transport conversion before the shared document renderer, not a renderer.
enum AIChatCitationNormalizer {
  private static let link = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((<[^>\n]+>|(?:[^()\n]|\([^()\n]*\))+)\)"#)
  private static let lineSuffix = try! NSRegularExpression(pattern: #"^(.*?)(?::|#L)([0-9]+)(?:-L?[0-9]+)?$"#)

  static func normalized(_ source: String) -> String {
    var literalEnd: String?
    return source.components(separatedBy: "\n").map { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
      if let end = literalEnd {
        if trimmed.hasPrefix(end) { literalEnd = nil }
        return line
      }
      for kind in ["src", "example", "export", "comment"] where trimmed.hasPrefix("#+begin_" + kind) {
        literalEnd = "#+end_" + kind
        return line
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        literalEnd = String(trimmed.prefix(3)); return line
      }
      var output = "", cursor = line.startIndex
      while cursor < line.endIndex {
        let character = line[cursor]
        let next = line.index(after: cursor)
        if character == "\\", next < line.endIndex {
          output += String(line[cursor...next]); cursor = line.index(after: next); continue
        }
        if line[cursor...].hasPrefix("[["), let end = line[next...].range(of: "]]")?.upperBound {
          output += line[cursor..<end]; cursor = end; continue
        }
        if "=~`".contains(character), let end = line[next...].firstIndex(of: character),
           cursor == line.startIndex || line[line.index(before: cursor)].isWhitespace || "([".contains(line[line.index(before: cursor)]) {
          output += line[cursor...end]; cursor = line.index(after: end); continue
        }
        if character == "[", (cursor == line.startIndex || line[line.index(before: cursor)] != "!"),
           let match = link.firstMatch(in: line, options: .anchored, range: NSRange(cursor..<line.endIndex, in: line)),
           let whole = Range(match.range, in: line), let label = Range(match.range(at: 1), in: line),
           let target = Range(match.range(at: 2), in: line) {
          let raw = String(line[target]).trimmingCharacters(in: .whitespaces)
          let unwrapped = raw.hasPrefix("<") && raw.hasSuffix(">") ? String(raw.dropFirst().dropLast()) : raw
          output += "[[" + orgTarget(unwrapped).replacingOccurrences(of: "]", with: "%5D") + "][" + line[label] + "]]"
          cursor = whole.upperBound; continue
        }
        output.append(character); cursor = next
      }
      return output
    }.joined(separator: "\n")
  }

  private static func orgTarget(_ raw: String) -> String {
    if raw.contains("://") || raw.hasPrefix("mailto:") || raw.hasPrefix("id:") { return raw }
    if raw.contains("::") { return raw }
    let path = raw.hasPrefix("file:") ? String(raw.dropFirst(5)) : raw
    if let match = lineSuffix.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
       let file = Range(match.range(at: 1), in: path), let line = Range(match.range(at: 2), in: path) {
      return "file:" + path[file] + "::" + path[line]
    }
    return raw
  }
}
