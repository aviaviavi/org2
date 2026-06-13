import AppKit
import SwiftUI

struct OrgSyntaxTextEditorSubmitContext {
  let text: String
  let selectedRange: NSRange
}

enum OrgSyntaxTextEditorTextPublishing: Equatable {
  case immediate
  case deferred(milliseconds: Int)
}

final class OrgSyntaxTextEditorDraftBuffer {
  var text: String?

  func update(_ text: String) {
    self.text = text
  }

  func current(fallback: String) -> String {
    text ?? fallback
  }
}

struct OrgSyntaxTextEditor: NSViewRepresentable {
  @Binding var text: String
  let monospaced: Bool
  let showsScrollers: Bool
  let textInset: NSSize
  let focusOnAppear: Bool
  let textPublishing: OrgSyntaxTextEditorTextPublishing
  let selection: Binding<NSRange>?
  let isFocused: Binding<Bool>?
  let onLocalTextChange: ((String) -> Void)?
  let shouldPublishTextImmediately: ((String) -> Bool)?
  let onSubmit: (() -> Bool)?
  let onSubmitContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)?

  init(
    text: Binding<String>,
    monospaced: Bool = false,
    showsScrollers: Bool = true,
    textInset: NSSize = NSSize(width: 8, height: 8),
    focusOnAppear: Bool = false,
    textPublishing: OrgSyntaxTextEditorTextPublishing = .immediate,
    selection: Binding<NSRange>? = nil,
    isFocused: Binding<Bool>? = nil,
    onLocalTextChange: ((String) -> Void)? = nil,
    shouldPublishTextImmediately: ((String) -> Bool)? = nil,
    onSubmit: (() -> Bool)? = nil,
    onSubmitContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)? = nil
  ) {
    _text = text
    self.monospaced = monospaced
    self.showsScrollers = showsScrollers
    self.textInset = textInset
    self.focusOnAppear = focusOnAppear
    self.textPublishing = textPublishing
    self.selection = selection
    self.isFocused = isFocused
    self.onLocalTextChange = onLocalTextChange
    self.shouldPublishTextImmediately = shouldPublishTextImmediately
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

    var appliedProgrammaticText = false
    if Self.shouldApplyProgrammaticText(
      editorText: textView.string,
      boundText: text,
      hasPendingLocalText: context.coordinator.hasPendingTextPublishing(for: textView.string)
    ) {
      context.coordinator.cancelDeferredHighlighting()
      context.coordinator.cancelDeferredTextPublishing()
      context.coordinator.isApplyingProgrammaticChange = true
      textView.string = text
      context.coordinator.isApplyingProgrammaticChange = false
      context.coordinator.invalidateHighlighting()
      appliedProgrammaticText = true
    }

    if let selection {
      let requestedSelection = Self.clampedRange(selection.wrappedValue, in: textView.string)
      let currentSelection = textView.selectedRange()
      if currentSelection != requestedSelection,
         Coordinator.shouldApplyExternalSelection(
          requestedSelection: requestedSelection,
          currentSelection: currentSelection,
          isFirstResponder: textView.window?.firstResponder === textView,
          didApplyProgrammaticText: appliedProgrammaticText
         ) {
        textView.setSelectedRange(requestedSelection)
      }
    }

    if appliedProgrammaticText || !context.coordinator.hasDeferredHighlighting(for: textView) {
      context.coordinator.applyHighlightingIfNeeded(to: textView)
    }
  }

  private static func clampedRange(_ range: NSRange, in text: String) -> NSRange {
    let length = (text as NSString).length
    let location = min(max(0, range.location), length)
    return NSRange(
      location: location,
      length: min(max(0, range.length), length - location)
    )
  }

  static func shouldApplyProgrammaticText(
    editorText: String,
    boundText: String,
    hasPendingLocalText: Bool
  ) -> Bool {
    editorText != boundText && !hasPendingLocalText
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: OrgSyntaxTextEditor
    var isApplyingProgrammaticChange = false
    private var lastHighlightedText: String?
    private var lastHighlightedMonospaced: Bool?
    private var hasHighlightedText = false
    private var deferredHighlightText: String?
    private var deferredHighlightMonospaced: Bool?
    private var deferredHighlightWorkItem: DispatchWorkItem?
    private var deferredTextPublishText: String?
    private var deferredTextPublishWorkItem: DispatchWorkItem?

    init(parent: OrgSyntaxTextEditor) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      let currentText = textView.string
      parent.onLocalTextChange?(currentText)
      if !isApplyingProgrammaticChange {
        publishTextChange(currentText)
      }
      publishSelectionIfNeeded(textView.selectedRange())
      let shouldScheduleHighlighting = Self.shouldScheduleDeferredHighlighting(
        text: currentText,
        previousHighlightedText: lastHighlightedText,
        monospacedUnchanged: lastHighlightedMonospaced == parent.monospaced
      )
      markUserTextChangedForHighlighting(in: textView, willScheduleDeferredHighlighting: shouldScheduleHighlighting)
      if shouldScheduleHighlighting {
        scheduleDeferredHighlighting(to: textView)
      } else {
        cancelDeferredHighlighting()
      }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      publishSelectionIfNeeded(textView.selectedRange())
    }

    func textDidBeginEditing(_ notification: Notification) {
      parent.isFocused?.wrappedValue = true
    }

    func textDidEndEditing(_ notification: Notification) {
      if let textView = notification.object as? NSTextView {
        flushTextPublishing(from: textView)
      }
      parent.isFocused?.wrappedValue = false
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

      flushTextPublishing(from: textView)
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

    func invalidateHighlighting() {
      lastHighlightedText = nil
      lastHighlightedMonospaced = nil
      hasHighlightedText = false
    }

    func markUserTextChangedForHighlighting(
      in textView: NSTextView,
      willScheduleDeferredHighlighting: Bool = true
    ) {
      if canPreserveLargeBufferAttributes(for: textView) {
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: parent.monospaced)
        recordHighlightedState(for: textView)
        return
      }
      if !willScheduleDeferredHighlighting {
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: parent.monospaced)
        recordHighlightedState(for: textView)
        return
      }
      invalidateHighlighting()
    }

    func cancelDeferredHighlighting() {
      deferredHighlightWorkItem?.cancel()
      deferredHighlightWorkItem = nil
      deferredHighlightText = nil
      deferredHighlightMonospaced = nil
    }

    func cancelDeferredTextPublishing() {
      deferredTextPublishWorkItem?.cancel()
      deferredTextPublishWorkItem = nil
      deferredTextPublishText = nil
    }

    func hasPendingTextPublishing(for text: String) -> Bool {
      deferredTextPublishWorkItem != nil && deferredTextPublishText == text
    }

    func hasDeferredHighlighting(for textView: NSTextView) -> Bool {
      deferredHighlightWorkItem != nil
        && deferredHighlightText == textView.string
        && deferredHighlightMonospaced == parent.monospaced
    }

    func applyHighlightingIfNeeded(to textView: NSTextView) {
      if canPreserveLargeBufferAttributes(for: textView) {
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: parent.monospaced)
        recordHighlightedState(for: textView)
        return
      }

      guard lastHighlightedText != textView.string
              || lastHighlightedMonospaced != parent.monospaced
      else {
        return
      }
      applyHighlighting(to: textView)
    }

    private func canPreserveLargeBufferAttributes(for textView: NSTextView) -> Bool {
      guard hasHighlightedText,
            lastHighlightedMonospaced == parent.monospaced
      else {
        return false
      }
      return OrgSyntaxHighlighter.shouldPreserveExistingAttributesAfterEdit(
        utf16Length: (textView.string as NSString).length,
        hasHighlightedBefore: hasHighlightedText,
        monospacedUnchanged: lastHighlightedMonospaced == parent.monospaced
      )
    }

    private func publishTextChange(_ currentText: String) {
      guard parent.text != currentText else {
        cancelDeferredTextPublishing()
        return
      }

      if parent.shouldPublishTextImmediately?(currentText) == true {
        cancelDeferredTextPublishing()
        parent.text = currentText
        return
      }

      switch parent.textPublishing {
      case .immediate:
        cancelDeferredTextPublishing()
        parent.text = currentText
      case .deferred(let milliseconds):
        scheduleDeferredTextPublishing(currentText, milliseconds: milliseconds)
      }
    }

    private func flushTextPublishing(from textView: NSTextView) {
      cancelDeferredTextPublishing()
      if parent.text != textView.string {
        parent.text = textView.string
      }
    }

    private func scheduleDeferredTextPublishing(_ text: String, milliseconds: Int) {
      cancelDeferredTextPublishing()
      let expectedText = text
      deferredTextPublishText = expectedText

      let workItem = DispatchWorkItem { [weak self] in
        Task { @MainActor in
          guard let self,
                self.deferredTextPublishText == expectedText
          else {
            return
          }
          self.deferredTextPublishWorkItem = nil
          self.deferredTextPublishText = nil
          if self.parent.text != expectedText {
            self.parent.text = expectedText
          }
        }
      }
      deferredTextPublishWorkItem = workItem
      DispatchQueue.main.asyncAfter(
        deadline: .now() + .milliseconds(max(0, milliseconds)),
        execute: workItem
      )
    }

    private func scheduleDeferredHighlighting(to textView: NSTextView) {
      cancelDeferredHighlighting()
      let expectedText = textView.string
      let expectedMonospaced = parent.monospaced
      deferredHighlightText = expectedText
      deferredHighlightMonospaced = expectedMonospaced

      let workItem = DispatchWorkItem { [weak self, weak textView] in
        Task { @MainActor in
          guard let self, let textView else { return }
          guard self.deferredHighlightText == expectedText,
                self.deferredHighlightMonospaced == expectedMonospaced,
                textView.string == expectedText
          else {
            return
          }

          self.deferredHighlightWorkItem = nil
          self.deferredHighlightText = nil
          self.deferredHighlightMonospaced = nil
          self.applyHighlightingIfNeeded(to: textView)
        }
      }
      deferredHighlightWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(90), execute: workItem)
    }

    private func publishSelectionIfNeeded(_ selectedRange: NSRange) {
      guard let selection = parent.selection,
            selection.wrappedValue != selectedRange
      else {
        return
      }
      guard Self.shouldPublishSelection(
        selectedRange,
        previousRange: selection.wrappedValue,
        text: parent.text
      ) else {
        return
      }
      selection.wrappedValue = selectedRange
    }

    static func shouldPublishSelection(
      _ selectedRange: NSRange,
      previousRange: NSRange,
      text: String
    ) -> Bool {
      if selectedRange.length > 0 || previousRange.length > 0 {
        return true
      }
      return OrgInlineParser.hasInlineSyntaxCandidate(text)
    }

    static func shouldApplyExternalSelection(
      requestedSelection: NSRange,
      currentSelection: NSRange,
      isFirstResponder: Bool,
      didApplyProgrammaticText: Bool
    ) -> Bool {
      if didApplyProgrammaticText {
        return true
      }
      if !isFirstResponder {
        return true
      }
      return requestedSelection.length > 0 || currentSelection.length > 0
    }

    static func shouldScheduleDeferredHighlighting(
      text: String,
      previousHighlightedText: String?,
      monospacedUnchanged: Bool
    ) -> Bool {
      guard OrgSyntaxHighlighter.shouldTokenizeLiveText(utf16Length: (text as NSString).length) else {
        return false
      }
      guard monospacedUnchanged else {
        return true
      }
      if OrgSyntaxHighlighter.hasSyntaxCandidate(text) {
        return true
      }
      if let previousHighlightedText {
        return OrgSyntaxHighlighter.hasSyntaxCandidate(previousHighlightedText)
      }
      return false
    }

    func applyHighlighting(to textView: NSTextView) {
      cancelDeferredHighlighting()
      guard let storage = textView.textStorage else { return }
      let selectedRanges = textView.selectedRanges
      let typingAttributes = OrgSyntaxHighlighter.apply(
        to: storage,
        monospaced: parent.monospaced
      )
      textView.typingAttributes = typingAttributes
      textView.selectedRanges = selectedRanges
      recordHighlightedState(for: textView)
    }

    private func recordHighlightedState(for textView: NSTextView) {
      hasHighlightedText = true
      lastHighlightedMonospaced = parent.monospaced
      if OrgSyntaxHighlighter.shouldTokenizeLiveText(utf16Length: (textView.string as NSString).length) {
        lastHighlightedText = textView.string
      } else {
        lastHighlightedText = nil
      }
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
  case linkTarget
  case code
  case emphasis
  case timestamp
  case syntaxDelimiter
  case comment
}

/// Presentation-only tokenization for the native editor. Semantic org2 structure
/// should come from the canonical org2 parser/CLI, not this highlighter.
enum OrgSyntaxHighlighter {
  static let liveTokenizationUTF16Limit = 25_000

  static func baseTypingAttributes(monospaced: Bool) -> [NSAttributedString.Key: Any] {
    let baseFont = monospaced
      ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      : NSFont.systemFont(ofSize: NSFont.systemFontSize)
    return baseAttributes(font: baseFont)
  }

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
    let baseFont = baseFont(monospaced: monospaced)
    let baseAttributes = baseAttributes(font: baseFont)
    let fullRange = NSRange(location: 0, length: storage.length)

    storage.beginEditing()
    storage.setAttributes(baseAttributes, range: fullRange)
    if shouldTokenizeLiveText(utf16Length: storage.length) {
      let text = storage.string
      for token in tokens(in: text) where NSMaxRange(token.range) <= storage.length {
        storage.addAttributes(attributes(for: token.kind, baseFont: baseFont), range: token.range)
      }
    }
    storage.endEditing()
    return baseAttributes
  }

  static func shouldTokenizeLiveText(utf16Length: Int) -> Bool {
    utf16Length <= liveTokenizationUTF16Limit
  }

  static func hasSyntaxCandidate(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    var httpMatchIndex = 0
    let http = Array("http".utf8)
    for byte in text.utf8 {
      switch byte {
      case 35, 40, 42, 43, 47, 58, 60, 61, 91, 93, 95, 96, 126:
        return true
      default:
        if byte == http[httpMatchIndex] {
          httpMatchIndex += 1
          if httpMatchIndex == http.count {
            return true
          }
        } else {
          httpMatchIndex = byte == http[0] ? 1 : 0
        }
      }
    }
    return false
  }

  static func shouldPreserveExistingAttributesAfterEdit(
    utf16Length: Int,
    hasHighlightedBefore: Bool,
    monospacedUnchanged: Bool
  ) -> Bool {
    hasHighlightedBefore
      && monospacedUnchanged
      && !shouldTokenizeLiveText(utf16Length: utf16Length)
  }

  private static func baseFont(monospaced: Bool) -> NSFont {
    monospaced
      ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      : NSFont.systemFont(ofSize: NSFont.systemFontSize)
  }

  private static func collectLineTokens(in text: String, into tokens: inout [OrgSyntaxHighlightToken]) {
    guard !text.isEmpty else { return }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var lineOffset = 0
    for (index, line) in lines.enumerated() {
      collectHeadingTokens(line: line, lineOffset: lineOffset, into: &tokens)
      collectLineRegex(regex: keywordLineRegex, kind: .keyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
      collectLineRegex(regex: blockKeywordLineRegex, kind: .keyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
      collectLineRegex(regex: planningLineRegex, kind: .planningKeyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
      collectLineRegex(regex: propertyLineRegex, kind: .propertyKey, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
      collectLineRegex(regex: commentLineRegex, kind: .comment, line: line, lineOffset: lineOffset, into: &tokens)
      lineOffset += (line as NSString).length
      if index < lines.count - 1 {
        lineOffset += 1
      }
    }
  }

  private static func collectHeadingTokens(line: String, lineOffset: Int, into tokens: inout [OrgSyntaxHighlightToken]) {
    let ns = line as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    guard let match = headingLineRegex.firstMatch(in: line, range: fullRange),
          match.range.location == 0
    else {
      return
    }

    append(match.range(at: 1), kind: .headingStars, lineOffset: lineOffset, into: &tokens)
    append(match.range(at: 2), kind: .todo, lineOffset: lineOffset, into: &tokens)
    append(match.range(at: 3), kind: .priority, lineOffset: lineOffset, into: &tokens)

    collectLineRegex(
      regex: headingTagRegex,
      kind: .tag,
      line: line,
      lineOffset: lineOffset,
      capture: 1,
      into: &tokens
    )
  }

  private static func collectInlineTokens(in text: String, into tokens: inout [OrgSyntaxHighlightToken]) {
    collectRegex(regex: orgLinkRegex, kind: .link, text: text, into: &tokens)
    collectRegex(regex: markdownLinkRegex, kind: .link, text: text, into: &tokens)
    collectRegex(regex: urlRegex, kind: .link, text: text, into: &tokens)
    collectRegex(regex: filePathRegex, kind: .link, text: text, into: &tokens)
    collectRegex(regex: backtickCodeRegex, kind: .code, text: text, into: &tokens)
    collectRegex(regex: orgCodeRegex, kind: .code, text: text, into: &tokens)
    collectRegex(regex: emphasisRegex, kind: .emphasis, text: text, into: &tokens)
    collectRegex(regex: timestampRegex, kind: .timestamp, text: text, into: &tokens)
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
        appendLinkTarget(
          location: tokenRange.location + 2,
          length: separator.lowerBound.utf16Offset(in: raw) - 2,
          into: &tokens
        )
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
      appendLinkTarget(
        location: tokenRange.location + separator.upperBound.utf16Offset(in: raw),
        length: raw.utf16.count - separator.upperBound.utf16Offset(in: raw) - 1,
        into: &tokens
      )
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

  private static func appendLinkTarget(
    location: Int,
    length: Int,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    guard length > 0 else { return }
    tokens.append(OrgSyntaxHighlightToken(
      kind: .linkTarget,
      range: NSRange(location: location, length: length)
    ))
  }

  private static func substring(in text: String, range: NSRange) -> String? {
    guard let swiftRange = Range(range, in: text) else { return nil }
    return String(text[swiftRange])
  }

  private static func collectLineRegex(
    regex: NSRegularExpression,
    kind: OrgSyntaxHighlightKind,
    line: String,
    lineOffset: Int,
    capture: Int = 0,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    let ns = line as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    for match in regex.matches(in: line, range: fullRange) {
      append(match.range(at: capture), kind: kind, lineOffset: lineOffset, into: &tokens)
    }
  }

  private static func collectRegex(
    regex: NSRegularExpression,
    kind: OrgSyntaxHighlightKind,
    text: String,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    let ns = text as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    for match in regex.matches(in: text, range: fullRange) {
      append(match.range, kind: kind, lineOffset: 0, into: &tokens)
    }
  }

  private static let headingLineRegex = regex(
    #"^(\*+)\s+(?:(TODO|IN_PROGRESS|PROG|WAIT|HOLD|PAUSED|DONE|CANCELED|CANCELLED)\b)?\s*(?:(\[#.\]))?"#
  )
  private static let headingTagRegex = regex(#"\s(:[A-Za-z0-9_@#%:.-]+:)\s*$"#)
  private static let keywordLineRegex = regex(#"^\s*#\+([A-Za-z0-9_-]+):"#)
  private static let blockKeywordLineRegex = regex(#"^\s*#\+(begin_src|end_src|begin_quote|end_quote|begin_example|end_example)\b"#)
  private static let planningLineRegex = regex(#"^\s*(SCHEDULED|DEADLINE|CLOSED):"#)
  private static let propertyLineRegex = regex(#"^\s*:([^:\s]+):"#)
  private static let commentLineRegex = regex(#"^\s*#(?!\+).*$"#)
  private static let orgLinkRegex = regex(#"\[\[[^\n\]]+(?:\]\[[^\n\]]+)?\]\]"#)
  private static let markdownLinkRegex = regex(#"\[[^\n\]]+\]\([^\n\)]+\)"#)
  private static let urlRegex = regex(#"https?://[^\s\]\)"'`<>]+"#)
  private static let filePathRegex = regex(#"(?:(?:file:(?://)?)?(?:~|/|[A-Za-z0-9_.-]+/)[^\s\]\)"'`<>]*\.(?:org2?|md))(?:[:#]\d+)?"#)
  private static let backtickCodeRegex = regex(#"`[^`\n]+`"#)
  private static let orgCodeRegex = regex(#"(?<!\w)[~=][^\s~=](?:[^\n]*?[^\s~=])?[~=](?!\w)"#)
  private static let emphasisRegex = regex(#"(?<!\w)[*/_+][^\s*/_+](?:[^\n]*?[^\s*/_+])?[*/_+](?!\w)"#)
  private static let timestampRegex = regex(#"[<\[]\d{4}-\d{2}-\d{2}[^>\]]*[>\]]"#)

  private static func regex(_ pattern: String) -> NSRegularExpression {
    do {
      return try NSRegularExpression(pattern: pattern)
    } catch {
      preconditionFailure("Invalid org syntax regex: \(pattern)")
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
    case .linkTarget:
      return [
        .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.18),
        .backgroundColor: NSColor.clear,
        .underlineStyle: 0,
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
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
        .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
        .backgroundColor: NSColor.clear,
        .underlineStyle: 0,
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
      ]
    case .comment:
      return [
        .foregroundColor: NSColor.secondaryLabelColor
      ]
    }
  }
}
