import AppKit
import SwiftUI

struct OrgSyntaxTextEditorSubmitContext {
  let text: String
  let selectedRange: NSRange
}

struct OrgSyntaxTextEditor: NSViewRepresentable {
  @Binding var text: String
  let monospaced: Bool
  let showsScrollers: Bool
  let textInset: NSSize
  let focusOnAppear: Bool
  let selection: Binding<NSRange>?
  let onSubmit: (() -> Bool)?
  let onSubmitContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)?

  init(
    text: Binding<String>,
    monospaced: Bool = false,
    showsScrollers: Bool = true,
    textInset: NSSize = NSSize(width: 8, height: 8),
    focusOnAppear: Bool = false,
    selection: Binding<NSRange>? = nil,
    onSubmit: (() -> Bool)? = nil,
    onSubmitContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)? = nil
  ) {
    _text = text
    self.monospaced = monospaced
    self.showsScrollers = showsScrollers
    self.textInset = textInset
    self.focusOnAppear = focusOnAppear
    self.selection = selection
    self.onSubmit = onSubmit
    self.onSubmitContext = onSubmitContext
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = showsScrollers
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = showsScrollers
    scrollView.borderType = .noBorder

    let textView = NSTextView()
    textView.delegate = context.coordinator
    textView.string = text
    textView.drawsBackground = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.textContainerInset = textInset
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    context.coordinator.applyHighlighting(to: textView)
    if focusOnAppear {
      DispatchQueue.main.async {
        textView.window?.makeFirstResponder(textView)
      }
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scrollView.documentView as? NSTextView else { return }

    if textView.string != text {
      context.coordinator.isApplyingProgrammaticChange = true
      textView.string = text
      context.coordinator.isApplyingProgrammaticChange = false
    }

    if let selection {
      let requestedSelection = Self.clampedRange(selection.wrappedValue, in: textView.string)
      if textView.selectedRange() != requestedSelection {
        textView.setSelectedRange(requestedSelection)
      }
    }

    context.coordinator.applyHighlighting(to: textView)
  }

  private static func clampedRange(_ range: NSRange, in text: String) -> NSRange {
    let length = (text as NSString).length
    let location = min(max(0, range.location), length)
    return NSRange(
      location: location,
      length: min(max(0, range.length), length - location)
    )
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: OrgSyntaxTextEditor
    var isApplyingProgrammaticChange = false

    init(parent: OrgSyntaxTextEditor) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      if !isApplyingProgrammaticChange {
        parent.text = textView.string
      }
      parent.selection?.wrappedValue = textView.selectedRange()
      applyHighlighting(to: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.selection?.wrappedValue = textView.selectedRange()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
        return false
      }

      if let event = NSApp.currentEvent {
        let modifiers = event.modifierFlags.intersection([.shift, .option, .control])
        if !modifiers.isEmpty {
          return false
        }
      }

      parent.text = textView.string
      let context = OrgSyntaxTextEditorSubmitContext(
        text: textView.string,
        selectedRange: textView.selectedRange()
      )
      if let onSubmitContext = parent.onSubmitContext,
         onSubmitContext(context) {
        return true
      }
      guard let onSubmit = parent.onSubmit else {
        return false
      }
      return onSubmit()
    }

    func applyHighlighting(to textView: NSTextView) {
      guard let storage = textView.textStorage else { return }
      let selectedRanges = textView.selectedRanges
      let typingAttributes = OrgSyntaxHighlighter.apply(
        to: storage,
        monospaced: parent.monospaced
      )
      textView.typingAttributes = typingAttributes
      textView.selectedRanges = selectedRanges
    }
  }
}

struct OrgSyntaxHighlightToken: Equatable {
  let kind: OrgSyntaxHighlightKind
  let range: NSRange
}

enum OrgSyntaxHighlightKind: String {
  case headingStars
  case keyword
  case planningKeyword
  case propertyKey
  case todo
  case priority
  case tag
  case link
  case code
  case emphasis
  case timestamp
  case syntaxDelimiter
  case comment
}

/// Presentation-only tokenization for the native editor. Semantic org2 structure
/// should come from the canonical org2 parser/CLI, not this highlighter.
enum OrgSyntaxHighlighter {
  static func tokens(in text: String) -> [OrgSyntaxHighlightToken] {
    var tokens: [OrgSyntaxHighlightToken] = []
    collectLineTokens(in: text, into: &tokens)
    collectInlineTokens(in: text, into: &tokens)
    return tokens.sorted {
      if $0.range.location != $1.range.location {
        return $0.range.location < $1.range.location
      }
      return $0.range.length > $1.range.length
    }
  }

  @discardableResult
  static func apply(to storage: NSTextStorage, monospaced: Bool) -> [NSAttributedString.Key: Any] {
    let baseFont = monospaced
      ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      : NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let baseAttributes = baseAttributes(font: baseFont)
    let fullRange = NSRange(location: 0, length: storage.length)

    storage.beginEditing()
    storage.setAttributes(baseAttributes, range: fullRange)
    let text = storage.string
    for token in tokens(in: text) where NSMaxRange(token.range) <= storage.length {
      storage.addAttributes(attributes(for: token.kind, baseFont: baseFont), range: token.range)
    }
    storage.endEditing()
    return baseAttributes
  }

  private static func collectLineTokens(in text: String, into tokens: inout [OrgSyntaxHighlightToken]) {
    guard !text.isEmpty else { return }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var lineOffset = 0
    for (index, line) in lines.enumerated() {
      collectHeadingTokens(line: line, lineOffset: lineOffset, into: &tokens)
      collectLineRegex(pattern: #"^\s*#\+([A-Za-z0-9_-]+):"#, kind: .keyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
      collectLineRegex(pattern: #"^\s*#\+(begin_src|end_src|begin_quote|end_quote|begin_example|end_example)\b"#, kind: .keyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
      collectLineRegex(pattern: #"^\s*(SCHEDULED|DEADLINE|CLOSED):"#, kind: .planningKeyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
      collectLineRegex(pattern: #"^\s*:([^:\s]+):"#, kind: .propertyKey, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
      collectLineRegex(pattern: #"^\s*#(?!\+).*$"#, kind: .comment, line: line, lineOffset: lineOffset, into: &tokens)
      lineOffset += (line as NSString).length
      if index < lines.count - 1 {
        lineOffset += 1
      }
    }
  }

  private static func collectHeadingTokens(line: String, lineOffset: Int, into tokens: inout [OrgSyntaxHighlightToken]) {
    let ns = line as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    guard let regex = try? NSRegularExpression(pattern: #"^(\*+)\s+(?:(TODO|IN_PROGRESS|PROG|WAIT|HOLD|PAUSED|DONE|CANCELED|CANCELLED)\b)?\s*(?:(\[#.\]))?"#),
          let match = regex.firstMatch(in: line, range: fullRange),
          match.range.location == 0
    else {
      return
    }

    append(match.range(at: 1), kind: .headingStars, lineOffset: lineOffset, into: &tokens)
    append(match.range(at: 2), kind: .todo, lineOffset: lineOffset, into: &tokens)
    append(match.range(at: 3), kind: .priority, lineOffset: lineOffset, into: &tokens)

    collectLineRegex(
      pattern: #"\s(:[A-Za-z0-9_@#%:.-]+:)\s*$"#,
      kind: .tag,
      line: line,
      lineOffset: lineOffset,
      capture: 1,
      into: &tokens
    )
  }

  private static func collectInlineTokens(in text: String, into tokens: inout [OrgSyntaxHighlightToken]) {
    collectRegex(pattern: #"\[\[[^\n\]]+(?:\]\[[^\n\]]+)?\]\]"#, kind: .link, text: text, into: &tokens)
    collectRegex(pattern: #"\[[^\n\]]+\]\([^\n\)]+\)"#, kind: .link, text: text, into: &tokens)
    collectRegex(pattern: #"https?://[^\s\]\)"'`<>]+"#, kind: .link, text: text, into: &tokens)
    collectRegex(pattern: #"(?:(?:file:(?://)?)?(?:~|/|[A-Za-z0-9_.-]+/)[^\s\]\)"'`<>]*\.(?:org2?|md))(?:[:#]\d+)?"#, kind: .link, text: text, into: &tokens)
    collectRegex(pattern: #"`[^`\n]+`"#, kind: .code, text: text, into: &tokens)
    collectRegex(pattern: #"(?<!\w)[~=][^\s~=](?:[^\n]*?[^\s~=])?[~=](?!\w)"#, kind: .code, text: text, into: &tokens)
    collectRegex(pattern: #"(?<!\w)[*/_+][^\s*/_+](?:[^\n]*?[^\s*/_+])?[*/_+](?!\w)"#, kind: .emphasis, text: text, into: &tokens)
    collectRegex(pattern: #"[<\[]\d{4}-\d{2}-\d{2}[^>\]]*[>\]]"#, kind: .timestamp, text: text, into: &tokens)
    collectInlineDelimiterTokens(in: text, into: &tokens)
  }

  private static func collectInlineDelimiterTokens(in text: String, into tokens: inout [OrgSyntaxHighlightToken]) {
    let inlineTokens = tokens.filter { [.link, .code, .emphasis, .timestamp].contains($0.kind) }
    for token in inlineTokens {
      guard let raw = substring(in: text, range: token.range) else { continue }
      switch token.kind {
      case .link:
        collectLinkDelimiters(raw: raw, tokenRange: token.range, into: &tokens)
      case .code, .emphasis, .timestamp:
        appendEdgeDelimiters(token.range, openingLength: 1, closingLength: 1, into: &tokens)
      default:
        break
      }
    }
  }

  private static func collectLinkDelimiters(
    raw: String,
    tokenRange: NSRange,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    if raw.hasPrefix("[["), raw.hasSuffix("]]") {
      appendSyntaxDelimiter(location: tokenRange.location, length: 2, into: &tokens)
      appendSyntaxDelimiter(location: NSMaxRange(tokenRange) - 2, length: 2, into: &tokens)
      if let separator = raw.range(of: "][") {
        appendSyntaxDelimiter(
          location: tokenRange.location + separator.lowerBound.utf16Offset(in: raw),
          length: 2,
          into: &tokens
        )
      }
      return
    }

    if raw.hasPrefix("["), raw.hasSuffix(")"),
       let separator = raw.range(of: "](") {
      appendSyntaxDelimiter(location: tokenRange.location, length: 1, into: &tokens)
      appendSyntaxDelimiter(
        location: tokenRange.location + separator.lowerBound.utf16Offset(in: raw),
        length: 2,
        into: &tokens
      )
      appendSyntaxDelimiter(location: NSMaxRange(tokenRange) - 1, length: 1, into: &tokens)
    }
  }

  private static func appendEdgeDelimiters(
    _ tokenRange: NSRange,
    openingLength: Int,
    closingLength: Int,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    guard tokenRange.length >= openingLength + closingLength else { return }
    appendSyntaxDelimiter(location: tokenRange.location, length: openingLength, into: &tokens)
    appendSyntaxDelimiter(location: NSMaxRange(tokenRange) - closingLength, length: closingLength, into: &tokens)
  }

  private static func appendSyntaxDelimiter(
    location: Int,
    length: Int,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    guard length > 0 else { return }
    tokens.append(OrgSyntaxHighlightToken(
      kind: .syntaxDelimiter,
      range: NSRange(location: location, length: length)
    ))
  }

  private static func substring(in text: String, range: NSRange) -> String? {
    guard let swiftRange = Range(range, in: text) else { return nil }
    return String(text[swiftRange])
  }

  private static func collectLineRegex(
    pattern: String,
    kind: OrgSyntaxHighlightKind,
    line: String,
    lineOffset: Int,
    capture: Int = 0,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    let ns = line as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    for match in regex.matches(in: line, range: fullRange) {
      append(match.range(at: capture), kind: kind, lineOffset: lineOffset, into: &tokens)
    }
  }

  private static func collectRegex(
    pattern: String,
    kind: OrgSyntaxHighlightKind,
    text: String,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    let ns = text as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    for match in regex.matches(in: text, range: fullRange) {
      append(match.range, kind: kind, lineOffset: 0, into: &tokens)
    }
  }

  private static func append(
    _ range: NSRange,
    kind: OrgSyntaxHighlightKind,
    lineOffset: Int,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    guard range.location != NSNotFound, range.length > 0 else { return }
    tokens.append(OrgSyntaxHighlightToken(
      kind: kind,
      range: NSRange(location: lineOffset + range.location, length: range.length)
    ))
  }

  private static func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2
    return [
      .font: font,
      .foregroundColor: NSColor.textColor,
      .paragraphStyle: paragraph
    ]
  }

  private static func attributes(for kind: OrgSyntaxHighlightKind, baseFont: NSFont) -> [NSAttributedString.Key: Any] {
    switch kind {
    case .headingStars:
      return [
        .foregroundColor: NSColor.secondaryLabelColor,
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .medium)
      ]
    case .keyword:
      return [
        .foregroundColor: NSColor.systemPurple,
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .medium)
      ]
    case .planningKeyword:
      return [
        .foregroundColor: NSColor.systemOrange,
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold)
      ]
    case .propertyKey:
      return [
        .foregroundColor: NSColor.secondaryLabelColor,
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .medium)
      ]
    case .todo:
      return [
        .foregroundColor: NSColor.controlAccentColor,
        .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.12),
        .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
      ]
    case .priority:
      return [
        .foregroundColor: NSColor.systemOrange,
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold)
      ]
    case .tag:
      return [
        .foregroundColor: NSColor.secondaryLabelColor,
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
      ]
    case .link:
      return [
        .foregroundColor: NSColor.controlAccentColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue
      ]
    case .code:
      return [
        .foregroundColor: NSColor.labelColor,
        .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
      ]
    case .emphasis:
      return [
        .foregroundColor: NSColor.labelColor,
        .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .medium)
      ]
    case .timestamp:
      return [
        .foregroundColor: NSColor.labelColor,
        .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10),
        .font: NSFont.monospacedDigitSystemFont(ofSize: baseFont.pointSize, weight: .regular)
      ]
    case .syntaxDelimiter:
      return [
        .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.58),
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
      ]
    case .comment:
      return [
        .foregroundColor: NSColor.secondaryLabelColor
      ]
    }
  }
}
