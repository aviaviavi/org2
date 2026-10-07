import Foundation

/// Open Graph and Twitter card tags for shared pages, so chat apps such as
/// Slack, iMessage, and Discord can render a title and summary when a share
/// link is pasted. Tags describe only what the shared page already shows.
enum SharePreviewMetadata {
  static let siteName = WorkspaceProductIdentity.displayName
  static let descriptionLimit = 200

  /// `<meta>` tags for a page with `title` and an optional plain-text summary.
  static func tags(title: String, description: String?, type: String = "article") -> String {
    let cleanTitle = collapsedWhitespace(title)
    let resolvedTitle = cleanTitle.isEmpty ? siteName : cleanTitle
    let summary = description.map { truncated(collapsedWhitespace($0), limit: descriptionLimit) }
      .flatMap { $0.isEmpty ? nil : $0 }
    var lines = [
      #"<meta property="og:type" content="\#(escape(type))">"#,
      #"<meta property="og:site_name" content="\#(siteName)">"#,
      #"<meta property="og:title" content="\#(escape(resolvedTitle))">"#,
      #"<meta name="twitter:card" content="summary">"#,
      #"<meta name="twitter:title" content="\#(escape(resolvedTitle))">"#,
    ]
    if let summary {
      lines.append(#"<meta name="description" content="\#(escape(summary))">"#)
      lines.append(#"<meta property="og:description" content="\#(escape(summary))">"#)
      lines.append(#"<meta name="twitter:description" content="\#(escape(summary))">"#)
    }
    return lines.joined(separator: "\n")
  }

  /// Adds preview tags to published HTML that does not declare its own. The
  /// summary comes from an existing `<meta name="description">`, otherwise
  /// from the first paragraph of the document body. Non-HTML or already
  /// annotated data is returned unchanged.
  static func annotated(html data: Data, title: String) -> Data {
    guard let html = String(data: data, encoding: .utf8),
          html.range(of: #"<meta\s[^>]*property\s*=\s*["']og:title["']"#, options: [.regularExpression, .caseInsensitive]) == nil,
          let head = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive])
    else { return data }
    let existingDescription = firstCapture(
      in: html,
      pattern: #"<meta\s+name\s*=\s*["']description["']\s+content\s*=\s*"([^"]*)""#
    ).map(decodedEntities)
    let description = existingDescription ?? firstParagraphText(in: html)
    var tagLines = tags(title: title, description: description)
    if existingDescription != nil {
      // Keep the document's own description tag rather than duplicating it.
      tagLines = tagLines
        .split(separator: "\n")
        .filter { !$0.hasPrefix(#"<meta name="description""#) }
        .joined(separator: "\n")
    }
    var result = html
    result.insert(contentsOf: "\n" + tagLines, at: head.upperBound)
    return Data(result.utf8)
  }

  /// Plain text of the first non-empty paragraph inside `<main>` (or the
  /// whole body when there is no `<main>`).
  static func firstParagraphText(in html: String) -> String? {
    let scope = firstCapture(in: html, pattern: #"<main[^>]*>([\s\S]*)</main>"#)
      ?? firstCapture(in: html, pattern: #"<body[^>]*>([\s\S]*)</body>"#)
      ?? html
    guard let regex = try? NSRegularExpression(pattern: #"<p(?:\s[^>]*)?>([\s\S]*?)</p>"#, options: [.caseInsensitive])
    else { return nil }
    let range = NSRange(scope.startIndex..., in: scope)
    for match in regex.matches(in: scope, range: range) {
      guard let captured = Range(match.range(at: 1), in: scope) else { continue }
      let text = collapsedWhitespace(decodedEntities(strippingTags(String(scope[captured]))))
      if !text.isEmpty { return text }
    }
    return nil
  }

  static func truncated(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let prefix = text.prefix(limit - 1)
    let cut = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
    return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
  }

  static func collapsedWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
  }

  private static func strippingTags(_ html: String) -> String {
    html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
  }

  private static func decodedEntities(_ text: String) -> String {
    var result = text
    for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                            ("&#x27;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
      result = result.replacingOccurrences(of: entity, with: value)
    }
    return result
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private static func firstCapture(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }
}
