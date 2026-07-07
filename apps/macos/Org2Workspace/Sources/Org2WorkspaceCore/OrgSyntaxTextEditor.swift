import AppKit
import SwiftUI

struct OrgSyntaxTextEditorSubmitContext {
  let text: String
  let selectedRange: NSRange
}

struct OrgSyntaxTextEditReplacement: Equatable {
  let range: NSRange
  let replacement: String

  var selectedRangeAfterReplacement: NSRange {
    NSRange(location: range.location + (replacement as NSString).length, length: 0)
  }
}

enum OrgSourceTextEditing {
  static func newlineReplacement(
    in text: String,
    selectedRange: NSRange
  ) -> OrgSyntaxTextEditReplacement? {
    let nsText = text as NSString
    let selectedRange = clampedRange(selectedRange, utf16Length: nsText.length)
    let lineContext = lineContext(in: nsText, selectedRange: selectedRange)
    guard let continuation = listContinuation(for: lineContext.textBeforeSelection)
      ?? indentationContinuation(for: lineContext.textBeforeSelection)
    else {
      return nil
    }
    return OrgSyntaxTextEditReplacement(
      range: selectedRange,
      replacement: "\n" + continuation
    )
  }

  private static func clampedRange(_ range: NSRange, utf16Length length: Int) -> NSRange {
    let location = min(max(0, range.location), length)
    return NSRange(
      location: location,
      length: min(max(0, range.length), length - location)
    )
  }

  private static func lineContext(
    in text: NSString,
    selectedRange: NSRange
  ) -> (lineText: String, textBeforeSelection: String) {
    let lineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
    let lineEnd = lineContentEnd(in: text, lineRange: lineRange)
    let contentRange = NSRange(location: lineRange.location, length: max(0, lineEnd - lineRange.location))
    let beforeEnd = min(selectedRange.location, lineEnd)
    let beforeRange = NSRange(location: lineRange.location, length: max(0, beforeEnd - lineRange.location))
    return (
      lineText: text.substring(with: contentRange),
      textBeforeSelection: text.substring(with: beforeRange)
    )
  }

  private static func lineContentEnd(in text: NSString, lineRange: NSRange) -> Int {
    var end = lineRange.location + lineRange.length
    while end > lineRange.location {
      let character = text.character(at: end - 1)
      if character == 10 || character == 13 {
        end -= 1
      } else {
        break
      }
    }
    return end
  }

  private static func indentationContinuation(for linePrefix: String) -> String? {
    let indent = leadingWhitespace(in: linePrefix)
    guard !indent.isEmpty,
          linePrefix.trimmingCharacters(in: .whitespaces).isEmpty == false
    else {
      return nil
    }
    return indent
  }

  private static func listContinuation(for linePrefix: String) -> String? {
    let indent = leadingWhitespace(in: linePrefix)
    let rest = String(linePrefix.dropFirst(indent.count))
    guard let marker = listMarker(in: rest) else { return nil }
    let content = rest.dropFirst(marker.consumedUTF16Length)
    guard content.trimmingCharacters(in: .whitespaces).isEmpty == false else {
      return nil
    }
    return indent + marker.nextPrefix
  }

  private static func leadingWhitespace(in text: String) -> String {
    String(text.prefix { $0 == " " || $0 == "\t" })
  }

  private static func listMarker(in text: String) -> (consumedUTF16Length: Int, nextPrefix: String)? {
    guard !text.isEmpty else { return nil }
    if let marker = unorderedListMarker(in: text) {
      return marker
    }
    return orderedListMarker(in: text)
  }

  private static func unorderedListMarker(in text: String) -> (consumedUTF16Length: Int, nextPrefix: String)? {
    guard let first = text.first,
          first == "-" || first == "+",
          text.dropFirst().first?.isWhitespace == true
    else {
      return nil
    }
    let basePrefix = "\(first) "
    let afterMarker = String(text.dropFirst(2))
    if let checkbox = checkboxPrefix(in: afterMarker) {
      return (
        (basePrefix + checkbox).utf16.count,
        basePrefix + checkbox
      )
    }
    return (basePrefix.utf16.count, basePrefix)
  }

  private static func orderedListMarker(in text: String) -> (consumedUTF16Length: Int, nextPrefix: String)? {
    var digits = ""
    var index = text.startIndex
    while index < text.endIndex, text[index].isNumber {
      digits.append(text[index])
      index = text.index(after: index)
    }
    guard !digits.isEmpty,
          index < text.endIndex,
          text[index] == "." || text[index] == ")"
    else {
      return nil
    }
    let delimiter = text[index]
    let afterDelimiter = text.index(after: index)
    guard afterDelimiter < text.endIndex,
          text[afterDelimiter].isWhitespace
    else {
      return nil
    }
    let number = Int(digits) ?? 0
    let basePrefix = "\(number + 1)\(delimiter) "
    let afterMarker = String(text[text.index(after: afterDelimiter)...])
    if let checkbox = checkboxPrefix(in: afterMarker) {
      return (
        "\(digits)\(delimiter) \(checkbox)".utf16.count,
        basePrefix + checkbox
      )
    }
    return ("\(digits)\(delimiter) ".utf16.count, basePrefix)
  }

  private static func checkboxPrefix(in text: String) -> String? {
    for candidate in ["[ ] ", "[X] ", "[x] ", "[-] "] where text.hasPrefix(candidate) {
      return candidate
    }
    return nil
  }
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

struct OrgSyntaxTextSelectionContext: Equatable {
  let blockID: String
  let startLine: Int
  let endLineExclusive: Int
  let editorToSourceUTF16Offset: Int
}

struct OrgSyntaxTextSelectionDocumentFragment: Equatable {
  let context: OrgSyntaxTextSelectionContext
  let editorRange: NSRange
  let editorUTF16Length: Int
  let editorText: String

  var sourceRange: NSRange {
    NSRange(
      location: context.editorToSourceUTF16Offset + editorRange.location,
      length: editorRange.length
    )
  }

  var selectsEntireEditor: Bool {
    editorRange.location == 0 && editorRange.length >= editorUTF16Length
  }
}

fileprivate enum OrgSyntaxTextBoundaryDirection {
  case previous
  case next
}

fileprivate enum OrgSyntaxTextBoundaryCaretPlacement {
  case start
  case end
}

final class OrgSyntaxTextView: NSTextView {
  var documentSelectionContext: OrgSyntaxTextSelectionContext?
  var onSaveCommand: ((OrgSyntaxTextEditorSubmitContext) -> Bool)?
  var onDeleteDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment]) -> Bool)?
  var onReplaceDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment], String) -> Bool)?
  var isApplyingCrossEditorSelection = false
  private var crossEditorHighlightedRange: NSRange?

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 1,
       OrgSyntaxTextSelectionBridge.trackMouseSelection(from: self, event: event) {
      return
    }
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    if OrgSyntaxTextSelectionBridge.updateSelection(from: self, event: event) {
      return
    }
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if OrgSyntaxTextSelectionBridge.endSelection(from: self) {
      return
    }
    super.mouseUp(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if handlesCrossEditorCopyShortcut(event) {
      copy(nil)
      return
    }
    if handlesSaveShortcut(event), performSaveShortcut() {
      return
    }
    if handlesDocumentSelectAllShortcut(event),
       OrgSyntaxTextSelectionBridge.selectAllDocumentText(containing: self) {
      return
    }
    if handlesDocumentSelectionDelete(event),
       performDocumentSelectionDelete() {
      return
    }
    if let replacement = documentSelectionReplacementText(for: event),
       performDocumentSelectionReplacement(with: replacement) {
      return
    }
    OrgSyntaxTextSelectionBridge.clearCrossEditorSelection(containing: self, preserving: self)
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if handlesCrossEditorCopyShortcut(event) {
      copy(nil)
      return true
    }
    if handlesSaveShortcut(event), performSaveShortcut() {
      return true
    }
    if handlesDocumentSelectAllShortcut(event),
       OrgSyntaxTextSelectionBridge.selectAllDocumentText(containing: self) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func selectAll(_ sender: Any?) {
    if OrgSyntaxTextSelectionBridge.selectAllDocumentText(containing: self) {
      return
    }
    super.selectAll(sender)
  }

  override func deleteBackward(_ sender: Any?) {
    if performDocumentSelectionDelete() {
      return
    }
    super.deleteBackward(sender)
  }

  override func deleteForward(_ sender: Any?) {
    if performDocumentSelectionDelete() {
      return
    }
    super.deleteForward(sender)
  }

  override func paste(_ sender: Any?) {
    if let pastedText = NSPasteboard.general.string(forType: .string),
       performDocumentSelectionReplacement(with: pastedText) {
      return
    }
    super.paste(sender)
  }

  override func copy(_ sender: Any?) {
    guard let selectedText = OrgSyntaxTextSelectionBridge.selectedText(containing: self) else {
      super.copy(sender)
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(selectedText, forType: .string)
  }

  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(copy(_:)),
       OrgSyntaxTextSelectionBridge.selectedText(containing: self) != nil {
      return true
    }
    return super.validateUserInterfaceItem(item)
  }

  @MainActor
  static func saveFocusedTextViewIfPossible(for event: NSEvent) -> Bool {
    guard let textView = focusedSyntaxTextView(for: event),
          textView.handlesSaveShortcut(event)
    else {
      return false
    }
    return textView.performSaveShortcut()
  }

  @MainActor
  private static func focusedSyntaxTextView(for event: NSEvent) -> OrgSyntaxTextView? {
    var windows: [NSWindow] = []
    for window in [event.window, NSApplication.shared.keyWindow, NSApplication.shared.mainWindow].compactMap(\.self) {
      if !windows.contains(where: { $0 === window }) {
        windows.append(window)
      }
    }
    for window in NSApplication.shared.windows where !windows.contains(where: { $0 === window }) {
      windows.append(window)
    }
    return windows.compactMap { $0.firstResponder as? OrgSyntaxTextView }.first
  }

  private func performSaveShortcut() -> Bool {
    onSaveCommand?(OrgSyntaxTextEditorSubmitContext(text: string, selectedRange: selectedRange())) == true
  }

  private func handlesCrossEditorCopyShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command
      && event.charactersIgnoringModifiers?.lowercased() == "c"
      && OrgSyntaxTextSelectionBridge.selectedText(containing: self) != nil
  }

  private func handlesSaveShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command
      && event.charactersIgnoringModifiers?.lowercased() == "s"
  }

  private func handlesDocumentSelectAllShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command
      && event.charactersIgnoringModifiers?.lowercased() == "a"
      && documentSelectionContext != nil
  }

  private func handlesDocumentSelectionDelete(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifiers.subtracting([.function]).isEmpty else { return false }
    if event.keyCode == 51 || event.keyCode == 117 {
      return true
    }
    return event.charactersIgnoringModifiers == "\u{7F}"
      || event.charactersIgnoringModifiers == String(UnicodeScalar(NSDeleteCharacter)!)
  }

  private func documentSelectionReplacementText(for event: NSEvent) -> String? {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard !modifiers.contains(.command),
          !modifiers.contains(.control),
          !modifiers.contains(.option),
          let characters = event.characters,
          !characters.isEmpty,
          characters.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.controlCharacters.contains(scalar)
              && !(0xF700...0xF8FF).contains(Int(scalar.value))
          })
    else {
      return nil
    }
    return characters
  }

  private func performDocumentSelectionDelete() -> Bool {
    if performDocumentSelectionReplacement(with: "") {
      return true
    }
    guard let fragments = OrgSyntaxTextSelectionBridge.selectedDocumentFragments(containing: self),
          !fragments.isEmpty,
          onDeleteDocumentSelection?(fragments) == true
    else {
      return false
    }
    OrgSyntaxTextSelectionBridge.clearCrossEditorSelection(containing: self)
    return true
  }

  private func performDocumentSelectionReplacement(with replacement: String) -> Bool {
    guard let fragments = OrgSyntaxTextSelectionBridge.selectedDocumentFragments(containing: self),
          !fragments.isEmpty,
          onReplaceDocumentSelection?(fragments, replacement) == true
    else {
      return false
    }
    OrgSyntaxTextSelectionBridge.clearCrossEditorSelection(containing: self)
    return true
  }

  func applyCrossEditorHighlight(_ range: NSRange) {
    clearCrossEditorHighlight()
    if range.length > 0 {
      let clampedRange = OrgSyntaxTextEditor.clampedRange(
        range,
        utf16Length: (string as NSString).length
      )
      guard clampedRange.length > 0 else { return }
      crossEditorHighlightedRange = clampedRange
      layoutManager?.addTemporaryAttribute(
        .backgroundColor,
        value: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55),
        forCharacterRange: clampedRange
      )
    }
  }

  func clearCrossEditorHighlight() {
    guard let range = crossEditorHighlightedRange else { return }
    layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
    crossEditorHighlightedRange = nil
  }
}

@MainActor
enum OrgSyntaxTextSelectionBridge {
  private struct ActiveSelection {
    weak var anchorView: OrgSyntaxTextView?
    let anchorLocation: Int
    var crossedEditorBoundary: Bool
  }

  private struct SelectionFragment {
    weak var view: OrgSyntaxTextView?
    let range: NSRange
  }

  private static var activeSelection: ActiveSelection?
  private static var selectedFragments: [SelectionFragment] = []

  static func beginSelection(in textView: OrgSyntaxTextView, event: NSEvent) {
    clearCrossEditorSelection(containing: textView)
    activeSelection = ActiveSelection(
      anchorView: textView,
      anchorLocation: characterLocation(in: textView, event: event),
      crossedEditorBoundary: false
    )
  }

  static func trackMouseSelection(from textView: OrgSyntaxTextView, event: NSEvent) -> Bool {
    guard let window = textView.window else { return false }
    clearCrossEditorSelection(containing: textView)
    window.makeFirstResponder(textView)

    let anchorLocation = characterLocation(in: textView, event: event)
    let initialPoint = event.locationInWindow
    activeSelection = ActiveSelection(
      anchorView: textView,
      anchorLocation: anchorLocation,
      crossedEditorBoundary: false
    )

    var didDrag = false
    var handledCrossEditorSelection = false
    while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      switch nextEvent.type {
      case .leftMouseDragged:
        let deltaX = nextEvent.locationInWindow.x - initialPoint.x
        let deltaY = nextEvent.locationInWindow.y - initialPoint.y
        if hypot(deltaX, deltaY) > 2 {
          didDrag = true
        }

        guard didDrag else { continue }
        let targetView = targetTextView(in: window, at: nextEvent.locationInWindow)
        if let targetView,
           targetView !== textView || handledCrossEditorSelection {
          handledCrossEditorSelection = true
          activeSelection?.crossedEditorBoundary = true
          selectTextAcrossEditors(
            anchorView: textView,
            anchorLocation: anchorLocation,
            targetView: targetView,
            targetLocation: characterLocation(in: targetView, windowPoint: nextEvent.locationInWindow)
          )
        } else if !handledCrossEditorSelection {
          let targetLocation = characterLocation(in: textView, windowPoint: nextEvent.locationInWindow)
          let location = min(anchorLocation, targetLocation)
          let length = abs(targetLocation - anchorLocation)
          textView.setSelectedRange(NSRange(location: location, length: length))
        }
      case .leftMouseUp:
        activeSelection = nil
        if !didDrag {
          textView.setSelectedRange(NSRange(location: anchorLocation, length: 0))
        }
        return true
      default:
        continue
      }
    }

    activeSelection = nil
    return true
  }

  static func updateSelection(from textView: OrgSyntaxTextView, event: NSEvent) -> Bool {
    guard var activeSelection,
          let anchorView = activeSelection.anchorView,
          let targetView = targetTextView(in: anchorView.window, at: event.locationInWindow)
    else {
      return false
    }

    let crossedEditorBoundary = targetView !== anchorView || activeSelection.crossedEditorBoundary
    guard crossedEditorBoundary else {
      return false
    }

    activeSelection.crossedEditorBoundary = true
    self.activeSelection = activeSelection
    selectTextAcrossEditors(
      anchorView: anchorView,
      anchorLocation: activeSelection.anchorLocation,
      targetView: targetView,
      targetLocation: characterLocation(in: targetView, windowPoint: event.locationInWindow)
    )
    return true
  }

  static func endSelection(from textView: OrgSyntaxTextView) -> Bool {
    let handled = activeSelection?.crossedEditorBoundary == true
    activeSelection = nil
    return handled
  }

  static func clearCrossEditorSelection(containing textView: OrgSyntaxTextView, preserving preservedView: OrgSyntaxTextView? = nil) {
    for candidate in orderedTextViews(in: textView.window) {
      candidate.clearCrossEditorHighlight()
      guard candidate !== preservedView else { continue }
      if candidate.selectedRange().length > 0 {
        candidate.setSelectedRange(NSRange(location: 0, length: 0))
      }
    }
    selectedFragments = []
    activeSelection = nil
  }

  static func selectAllDocumentText(containing textView: OrgSyntaxTextView) -> Bool {
    let textViews = orderedDocumentTextViews(in: textView.window)
    guard !textViews.isEmpty else { return false }

    var nextFragments: [SelectionFragment] = []
    for view in textViews {
      if view.selectedRange().length > 0 {
        view.setSelectedRange(NSRange(location: 0, length: 0))
      }
      let length = (view.string as NSString).length
      let range = NSRange(location: 0, length: length)
      view.applyCrossEditorHighlight(range)
      if length > 0 {
        nextFragments.append(SelectionFragment(view: view, range: range))
      }
    }

    selectedFragments = nextFragments
    activeSelection = nil
    textView.window?.makeFirstResponder(textView)
    return !nextFragments.isEmpty
  }

  static func selectTextAcrossEditors(
    anchorView: OrgSyntaxTextView,
    anchorLocation: Int,
    targetView: OrgSyntaxTextView,
    targetLocation: Int
  ) {
    let textViews = orderedTextViews(in: anchorView.window)
    guard let anchorIndex = textViews.firstIndex(where: { $0 === anchorView }),
          let targetIndex = textViews.firstIndex(where: { $0 === targetView })
    else {
      return
    }

    let lowerIndex = min(anchorIndex, targetIndex)
    let upperIndex = max(anchorIndex, targetIndex)
    var nextFragments: [SelectionFragment] = []
    for (index, view) in textViews.enumerated() {
      if view.selectedRange().length > 0 {
        view.setSelectedRange(NSRange(location: 0, length: 0))
      }
      guard lowerIndex...upperIndex ~= index else {
        view.clearCrossEditorHighlight()
        continue
      }
      let range = selectionRange(
        for: view,
        index: index,
        anchorIndex: anchorIndex,
        anchorLocation: anchorLocation,
        targetIndex: targetIndex,
        targetLocation: targetLocation
      )
      view.applyCrossEditorHighlight(range)
      if range.length > 0 {
        nextFragments.append(SelectionFragment(view: view, range: range))
      }
    }
    selectedFragments = nextFragments
  }

  static func selectedText(containing textView: OrgSyntaxTextView) -> String? {
    guard let liveFragments = liveSelectedFragments(containing: textView) else {
      return nil
    }
    let selectedText = liveFragments.compactMap { view, range -> String? in
      guard range.length > 0,
            let swiftRange = Range(range, in: view.string)
      else {
        return nil
      }
      return String(view.string[swiftRange])
    }
    guard !selectedText.isEmpty else {
      return nil
    }
    return selectedText.joined(separator: "\n")
  }

  static func selectedDocumentFragments(
    containing textView: OrgSyntaxTextView
  ) -> [OrgSyntaxTextSelectionDocumentFragment]? {
    guard let liveFragments = liveSelectedFragments(containing: textView) else {
      return nil
    }

    let documentFragments = liveFragments.compactMap { view, range -> OrgSyntaxTextSelectionDocumentFragment? in
      guard let context = view.documentSelectionContext else { return nil }
      return OrgSyntaxTextSelectionDocumentFragment(
        context: context,
        editorRange: range,
        editorUTF16Length: (view.string as NSString).length,
        editorText: view.string
      )
    }
    guard documentFragments.count == liveFragments.count,
          !documentFragments.isEmpty
    else {
      return nil
    }
    return documentFragments
  }

  fileprivate static func moveCaretAcrossDocumentEditors(
    from textView: OrgSyntaxTextView,
    direction: OrgSyntaxTextBoundaryDirection,
    placement: OrgSyntaxTextBoundaryCaretPlacement
  ) -> Bool {
    guard textView.documentSelectionContext != nil else { return false }
    let textViews = orderedDocumentTextViews(in: textView.window)
    guard let currentIndex = textViews.firstIndex(where: { $0 === textView }) else {
      return false
    }

    let targetIndex: Int
    switch direction {
    case .previous:
      targetIndex = currentIndex - 1
    case .next:
      targetIndex = currentIndex + 1
    }
    guard textViews.indices.contains(targetIndex) else {
      return false
    }

    let targetView = textViews[targetIndex]
    clearCrossEditorSelection(containing: textView, preserving: targetView)
    targetView.window?.makeFirstResponder(targetView)
    let targetLength = (targetView.string as NSString).length
    let targetLocation: Int
    switch placement {
    case .start:
      targetLocation = 0
    case .end:
      targetLocation = targetLength
    }
    targetView.setSelectedRange(NSRange(location: targetLocation, length: 0))
    targetView.scrollRangeToVisible(NSRange(location: targetLocation, length: 0))
    return true
  }

  static func orderedTextViews(in window: NSWindow?) -> [OrgSyntaxTextView] {
    guard let contentView = window?.contentView else { return [] }
    var seen = Set<ObjectIdentifier>()
    let textViews = collectTextViews(in: contentView, seen: &seen)
      .filter { !$0.isHidden && $0.window === window && $0.isEditable }
    return textViews.sorted { lhs, rhs in
      let lhsFrame = lhs.convert(lhs.bounds, to: nil)
      let rhsFrame = rhs.convert(rhs.bounds, to: nil)
      if abs(lhsFrame.midY - rhsFrame.midY) > 0.5 {
        return lhsFrame.midY > rhsFrame.midY
      }
      return lhsFrame.minX < rhsFrame.minX
    }
  }

  private static func liveSelectedFragments(
    containing textView: OrgSyntaxTextView
  ) -> [(OrgSyntaxTextView, NSRange)]? {
    guard let window = textView.window else { return nil }
    let liveFragments = selectedFragments.compactMap { fragment -> (OrgSyntaxTextView, NSRange)? in
      guard let view = fragment.view,
            view.window === window
      else {
        return nil
      }
      return (view, fragment.range)
    }
    guard !liveFragments.isEmpty else { return nil }
    if liveFragments.contains(where: { $0.0 === textView }) {
      return liveFragments
    }
    guard textView.documentSelectionContext != nil,
          orderedDocumentTextViews(in: window).contains(where: { $0 === textView })
    else {
      return nil
    }
    return liveFragments
  }

  private static func orderedDocumentTextViews(in window: NSWindow?) -> [OrgSyntaxTextView] {
    orderedTextViews(in: window).filter { $0.documentSelectionContext != nil }
  }

  private static func collectTextViews(in view: NSView, seen: inout Set<ObjectIdentifier>) -> [OrgSyntaxTextView] {
    var result: [OrgSyntaxTextView] = []
    if let textView = view as? OrgSyntaxTextView {
      let identifier = ObjectIdentifier(textView)
      if !seen.contains(identifier) {
        seen.insert(identifier)
        result.append(textView)
      }
    }
    if let scrollView = view as? NSScrollView,
       let documentView = scrollView.documentView {
      result.append(contentsOf: collectTextViews(in: documentView, seen: &seen))
    }
    for subview in view.subviews {
      result.append(contentsOf: collectTextViews(in: subview, seen: &seen))
    }
    return result
  }

  private static func targetTextView(in window: NSWindow?, at windowPoint: NSPoint) -> OrgSyntaxTextView? {
    let textViews = orderedTextViews(in: window)
    if let containing = textViews.first(where: { view in
      view.convert(view.bounds, to: nil).insetBy(dx: -12, dy: -6).contains(windowPoint)
    }) {
      return containing
    }
    return textViews.min { lhs, rhs in
      distance(from: windowPoint, to: lhs.convert(lhs.bounds, to: nil))
        < distance(from: windowPoint, to: rhs.convert(rhs.bounds, to: nil))
    }
  }

  private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return hypot(dx, dy)
  }

  private static func selectionRange(
    for textView: OrgSyntaxTextView,
    index: Int,
    anchorIndex: Int,
    anchorLocation: Int,
    targetIndex: Int,
    targetLocation: Int
  ) -> NSRange {
    let length = (textView.string as NSString).length
    if anchorIndex == targetIndex {
      let start = min(anchorLocation, targetLocation)
      let end = max(anchorLocation, targetLocation)
      return NSRange(location: start, length: end - start)
    }

    if anchorIndex < targetIndex {
      if index == anchorIndex {
        return NSRange(location: anchorLocation, length: max(0, length - anchorLocation))
      }
      if index == targetIndex {
        return NSRange(location: 0, length: min(length, targetLocation))
      }
      return NSRange(location: 0, length: length)
    }

    if index == targetIndex {
      return NSRange(location: targetLocation, length: max(0, length - targetLocation))
    }
    if index == anchorIndex {
      return NSRange(location: 0, length: min(length, anchorLocation))
    }
    return NSRange(location: 0, length: length)
  }

  private static func characterLocation(in textView: OrgSyntaxTextView, event: NSEvent) -> Int {
    characterLocation(in: textView, windowPoint: event.locationInWindow)
  }

  private static func characterLocation(in textView: OrgSyntaxTextView, windowPoint: NSPoint) -> Int {
    let localPoint = textView.convert(windowPoint, from: nil)
    let length = (textView.string as NSString).length
    return min(max(0, textView.characterIndexForInsertion(at: localPoint)), length)
  }
}

struct OrgSyntaxTextEditor: NSViewRepresentable {
  @Binding var text: String
  let monospaced: Bool
  let showsScrollers: Bool
  let textInset: NSSize
  let focusOnAppear: Bool
  let textPublishing: OrgSyntaxTextEditorTextPublishing
  let liveHighlighting: Bool
  let orgWritingCommands: Bool
  let selection: Binding<NSRange>?
  let isFocused: Binding<Bool>?
  let contentHeight: Binding<CGFloat>?
  let onLocalTextChange: ((String) -> Void)?
  let shouldPublishTextImmediately: ((String) -> Bool)?
  let onSaveCommand: ((OrgSyntaxTextEditorSubmitContext) -> Bool)?
  let onSubmit: (() -> Bool)?
  let onSubmitContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)?
  let onDeleteBackwardContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)?
  let documentSelectionContext: OrgSyntaxTextSelectionContext?
  let onDeleteDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment]) -> Bool)?
  let onReplaceDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment], String) -> Bool)?

  init(
    text: Binding<String>,
    monospaced: Bool = false,
    showsScrollers: Bool = true,
    textInset: NSSize = NSSize(width: 8, height: 8),
    focusOnAppear: Bool = false,
    textPublishing: OrgSyntaxTextEditorTextPublishing = .immediate,
    liveHighlighting: Bool = true,
    orgWritingCommands: Bool = false,
    selection: Binding<NSRange>? = nil,
    isFocused: Binding<Bool>? = nil,
    contentHeight: Binding<CGFloat>? = nil,
    onLocalTextChange: ((String) -> Void)? = nil,
    shouldPublishTextImmediately: ((String) -> Bool)? = nil,
    onSaveCommand: ((OrgSyntaxTextEditorSubmitContext) -> Bool)? = nil,
    onSubmit: (() -> Bool)? = nil,
    onSubmitContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)? = nil,
    onDeleteBackwardContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)? = nil,
    documentSelectionContext: OrgSyntaxTextSelectionContext? = nil,
    onDeleteDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment]) -> Bool)? = nil,
    onReplaceDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment], String) -> Bool)? = nil
  ) {
    _text = text
    self.monospaced = monospaced
    self.showsScrollers = showsScrollers
    self.textInset = textInset
    self.focusOnAppear = focusOnAppear
    self.textPublishing = textPublishing
    self.liveHighlighting = liveHighlighting
    self.orgWritingCommands = orgWritingCommands
    self.selection = selection
    self.isFocused = isFocused
    self.contentHeight = contentHeight
    self.onLocalTextChange = onLocalTextChange
    self.shouldPublishTextImmediately = shouldPublishTextImmediately
    self.onSaveCommand = onSaveCommand
    self.onSubmit = onSubmit
    self.onSubmitContext = onSubmitContext
    self.onDeleteBackwardContext = onDeleteBackwardContext
    self.documentSelectionContext = documentSelectionContext
    self.onDeleteDocumentSelection = onDeleteDocumentSelection
    self.onReplaceDocumentSelection = onReplaceDocumentSelection
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

    let textView = OrgSyntaxTextView()
    textView.delegate = context.coordinator
    textView.documentSelectionContext = documentSelectionContext
    textView.onSaveCommand = onSaveCommand
    textView.onDeleteDocumentSelection = onDeleteDocumentSelection
    textView.onReplaceDocumentSelection = onReplaceDocumentSelection
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
    textView.font = OrgSyntaxHighlighter.baseFont(monospaced: monospaced)
    textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: monospaced)
    textView.textContainerInset = textInset
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    context.coordinator.recordKnownText(text, utf16Length: textView.textStorage?.length)
    context.coordinator.applyHighlighting(to: textView)
    context.coordinator.publishContentHeight(for: textView)
    context.coordinator.applyFocusRequestIfNeeded(to: textView, enabled: focusOnAppear)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scrollView.documentView as? OrgSyntaxTextView else { return }
    textView.documentSelectionContext = documentSelectionContext
    textView.onSaveCommand = onSaveCommand
    textView.onDeleteDocumentSelection = onDeleteDocumentSelection
    textView.onReplaceDocumentSelection = onReplaceDocumentSelection

    var currentUTF16Length = textView.textStorage?.length
    let cachedEditorText = context.coordinator.knownText(matchingUTF16Length: currentUTF16Length)
    var editorText = cachedEditorText ?? textView.string
    if cachedEditorText == nil {
      context.coordinator.recordKnownText(editorText, utf16Length: currentUTF16Length)
    }
    var appliedProgrammaticText = false
    if Self.shouldApplyProgrammaticText(
      editorText: editorText,
      boundText: text,
      hasPendingLocalText: context.coordinator.hasPendingTextPublishing(for: editorText)
    ) {
      context.coordinator.cancelDeferredHighlighting()
      context.coordinator.cancelDeferredTextPublishing()
      context.coordinator.isApplyingProgrammaticChange = true
      textView.string = text
      context.coordinator.isApplyingProgrammaticChange = false
      currentUTF16Length = textView.textStorage?.length
      context.coordinator.recordKnownText(text, utf16Length: currentUTF16Length)
      context.coordinator.invalidateHighlighting()
      editorText = text
      appliedProgrammaticText = true
    }

    if let selection {
      let requestedSelection = Self.clampedRange(
        selection.wrappedValue,
        utf16Length: currentUTF16Length ?? OrgSyntaxHighlighter.utf16Length(of: editorText)
      )
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
    context.coordinator.applyFocusRequestIfNeeded(to: textView, enabled: focusOnAppear)

    if appliedProgrammaticText || !context.coordinator.hasDeferredHighlighting(for: editorText) {
      context.coordinator.applyHighlightingIfNeeded(to: textView, currentText: editorText)
    }
    context.coordinator.publishContentHeight(for: textView)
  }

  private static func clampedRange(_ range: NSRange, in text: String) -> NSRange {
    clampedRange(range, utf16Length: OrgSyntaxHighlighter.utf16Length(of: text))
  }

  static func clampedRange(_ range: NSRange, utf16Length length: Int) -> NSRange {
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
    private var deferredTextPublishGeneration = 0
    private var lastKnownText: String?
    private var lastKnownTextUTF16Length: Int?
    private var hasAppliedFocusRequest = false

    init(parent: OrgSyntaxTextEditor) {
      self.parent = parent
    }

    func applyFocusRequestIfNeeded(to textView: NSTextView, enabled: Bool) {
      guard enabled else {
        hasAppliedFocusRequest = false
        return
      }
      guard !hasAppliedFocusRequest else { return }
      hasAppliedFocusRequest = true
      DispatchQueue.main.async { [weak textView] in
        guard let textView else { return }
        if textView.window?.firstResponder !== textView {
          textView.window?.makeFirstResponder(textView)
        }
      }
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      let currentText = textView.string
      let currentUTF16Length = textView.textStorage?.length ?? (currentText as NSString).length
      recordKnownText(currentText, utf16Length: currentUTF16Length)
      parent.onLocalTextChange?(currentText)
      if !isApplyingProgrammaticChange {
        publishTextChange(currentText)
      }
      publishSelectionIfNeeded(textView.selectedRange(), in: currentText)
      guard parent.liveHighlighting else {
        cancelDeferredHighlighting()
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: parent.monospaced)
        recordHighlightedState(text: currentText, utf16Length: currentUTF16Length)
        publishContentHeight(for: textView)
        return
      }
      let shouldScheduleHighlighting = Self.shouldScheduleDeferredHighlighting(
        text: currentText,
        utf16Length: currentUTF16Length,
        previousHighlightedText: lastHighlightedText,
        monospacedUnchanged: lastHighlightedMonospaced == parent.monospaced
      )
      markUserTextChangedForHighlighting(
        in: textView,
        currentText: currentText,
        utf16Length: currentUTF16Length,
        willScheduleDeferredHighlighting: shouldScheduleHighlighting
      )
      if shouldScheduleHighlighting {
        scheduleDeferredHighlighting(to: textView, expectedText: currentText)
      } else {
        cancelDeferredHighlighting()
      }
      publishContentHeight(for: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      if (textView as? OrgSyntaxTextView)?.isApplyingCrossEditorSelection == true {
        return
      }
      let selectedRange = textView.selectedRange()
      guard shouldReadTextForSelectionPublishing(selectedRange) else { return }
      publishSelectionIfNeeded(selectedRange, in: textView.string)
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
      if handleBoundaryArrowCommand(commandSelector, in: textView) {
        return true
      }

      if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
        return handleDeleteBackwardCommand(in: textView)
      }

      guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
        return false
      }

      if let event = NSApp.currentEvent {
        let modifiers = event.modifierFlags.intersection([.shift, .option, .control, .command])
        if !modifiers.isEmpty {
          return false
        }
      }

      if handleOrgNewlineCommand(in: textView) {
        return true
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

    private func handleOrgNewlineCommand(in textView: NSTextView) -> Bool {
      guard parent.orgWritingCommands,
            let replacement = OrgSourceTextEditing.newlineReplacement(
              in: textView.string,
              selectedRange: textView.selectedRange()
            )
      else {
        return false
      }
      textView.insertText(replacement.replacement, replacementRange: replacement.range)
      textView.setSelectedRange(replacement.selectedRangeAfterReplacement)
      publishSelectionIfNeeded(replacement.selectedRangeAfterReplacement, in: textView.string)
      return true
    }

    private func handleBoundaryArrowCommand(_ commandSelector: Selector, in textView: NSTextView) -> Bool {
      guard let syntaxTextView = textView as? OrgSyntaxTextView,
            syntaxTextView.documentSelectionContext != nil
      else {
        return false
      }
      let selectedRange = textView.selectedRange()
      guard selectedRange.length == 0 else {
        return false
      }
      let textLength = (textView.string as NSString).length
      let clampedLocation = min(max(0, selectedRange.location), textLength)

      switch commandSelector {
      case #selector(NSResponder.moveUp(_:)):
        guard clampedLocation == 0 else { return false }
        return OrgSyntaxTextSelectionBridge.moveCaretAcrossDocumentEditors(
          from: syntaxTextView,
          direction: .previous,
          placement: .end
        )
      case #selector(NSResponder.moveDown(_:)):
        guard clampedLocation == textLength else { return false }
        return OrgSyntaxTextSelectionBridge.moveCaretAcrossDocumentEditors(
          from: syntaxTextView,
          direction: .next,
          placement: .end
        )
      case #selector(NSResponder.moveLeft(_:)):
        guard clampedLocation == 0 else { return false }
        return OrgSyntaxTextSelectionBridge.moveCaretAcrossDocumentEditors(
          from: syntaxTextView,
          direction: .previous,
          placement: .end
        )
      case #selector(NSResponder.moveRight(_:)):
        guard clampedLocation == textLength else { return false }
        return OrgSyntaxTextSelectionBridge.moveCaretAcrossDocumentEditors(
          from: syntaxTextView,
          direction: .next,
          placement: .start
        )
      default:
        return false
      }
    }

    private func handleDeleteBackwardCommand(in textView: NSTextView) -> Bool {
      let selectedRange = textView.selectedRange()
      guard Self.shouldOfferDeleteBackwardCommand(selectedRange: selectedRange) else {
        return false
      }

      guard let onDeleteBackwardContext = parent.onDeleteBackwardContext else {
        return false
      }

      flushTextPublishing(from: textView)
      return onDeleteBackwardContext(OrgSyntaxTextEditorSubmitContext(
        text: textView.string,
        selectedRange: selectedRange
      ))
    }

    func invalidateHighlighting() {
      lastHighlightedText = nil
      lastHighlightedMonospaced = nil
      hasHighlightedText = false
    }

    func recordKnownText(_ text: String, utf16Length providedUTF16Length: Int? = nil) {
      lastKnownText = text
      lastKnownTextUTF16Length = providedUTF16Length ?? (text as NSString).length
    }

    func knownText(matchingUTF16Length utf16Length: Int?) -> String? {
      guard let utf16Length,
            let lastKnownText,
            lastKnownTextUTF16Length == utf16Length
      else {
        return nil
      }
      return lastKnownText
    }

    func markUserTextChangedForHighlighting(
      in textView: NSTextView,
      currentText: String? = nil,
      utf16Length providedUTF16Length: Int? = nil,
      willScheduleDeferredHighlighting: Bool = true
    ) {
      let text = currentText ?? textView.string
      let utf16Length = providedUTF16Length ?? textView.textStorage?.length ?? (text as NSString).length
      if canPreserveLargeBufferAttributes(utf16Length: utf16Length) {
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: parent.monospaced)
        recordHighlightedState(text: text, utf16Length: utf16Length)
        return
      }
      if !willScheduleDeferredHighlighting {
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: parent.monospaced)
        recordHighlightedState(text: text, utf16Length: utf16Length)
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
      deferredTextPublishGeneration += 1
    }

    func hasPendingTextPublishing(for text: String) -> Bool {
      deferredTextPublishWorkItem != nil && deferredTextPublishText == text
    }

    func hasDeferredHighlighting(for text: String) -> Bool {
      deferredHighlightWorkItem != nil
        && deferredHighlightText == text
        && deferredHighlightMonospaced == parent.monospaced
    }

    func applyHighlightingIfNeeded(to textView: NSTextView, currentText: String? = nil) {
      let text = currentText ?? textView.string
      let utf16Length = textView.textStorage?.length ?? (text as NSString).length
      if canPreserveLargeBufferAttributes(utf16Length: utf16Length) {
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: parent.monospaced)
        recordHighlightedState(text: text, utf16Length: utf16Length)
        return
      }

      guard lastHighlightedText != text
              || lastHighlightedMonospaced != parent.monospaced
      else {
        return
      }
      applyHighlighting(to: textView)
    }

    private func canPreserveLargeBufferAttributes(utf16Length: Int) -> Bool {
      guard hasHighlightedText,
            lastHighlightedMonospaced == parent.monospaced
      else {
        return false
      }
      return OrgSyntaxHighlighter.shouldPreserveExistingAttributesAfterEdit(
        utf16Length: utf16Length,
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
      deferredTextPublishGeneration += 1
      let generation = deferredTextPublishGeneration
      deferredTextPublishText = text

      let workItem = DispatchWorkItem { [weak self] in
        Task { @MainActor in
          guard let self,
                self.deferredTextPublishGeneration == generation,
                let expectedText = self.deferredTextPublishText
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

    private func scheduleDeferredHighlighting(to textView: NSTextView, expectedText: String) {
      cancelDeferredHighlighting()
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
          self.applyHighlightingIfNeeded(to: textView, currentText: expectedText)
        }
      }
      deferredHighlightWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(90), execute: workItem)
    }

    private func publishSelectionIfNeeded(_ selectedRange: NSRange, in text: String) {
      guard let selection = parent.selection,
            selection.wrappedValue != selectedRange
      else {
        return
      }
      guard Self.shouldPublishSelection(
        selectedRange,
        previousRange: selection.wrappedValue,
        text: text
      ) else {
        return
      }
      selection.wrappedValue = selectedRange
    }

    func shouldReadTextForSelectionPublishing(_ selectedRange: NSRange) -> Bool {
      guard let selection = parent.selection else { return false }
      return selection.wrappedValue != selectedRange
    }

    static func shouldPublishSelection(
      _ selectedRange: NSRange,
      previousRange: NSRange,
      text: String
    ) -> Bool {
      if selectedRange.length > 0 || previousRange.length > 0 {
        return true
      }
      if abs(selectedRange.location - previousRange.location) <= selectionInlineSyntaxRadius {
        return hasInlineSyntaxNearSelectionWindow(
          text,
          selectedRange: selectedRange,
          previousRange: previousRange
        )
      }
      return OrgInlineParser.hasInlineSyntaxCandidate(
        text,
        near: selectedRange,
        radius: selectionInlineSyntaxRadius
      ) || OrgInlineParser.hasInlineSyntaxCandidate(
        text,
        near: previousRange,
        radius: selectionInlineSyntaxRadius
      )
    }

    static func hasInlineSyntaxNearSelectionWindow(
      _ text: String,
      selectedRange: NSRange,
      previousRange: NSRange
    ) -> Bool {
      let midpoint = (selectedRange.location + previousRange.location) / 2
      let distance = abs(selectedRange.location - previousRange.location)
      return OrgInlineParser.hasInlineSyntaxCandidate(
        text,
        near: NSRange(location: midpoint, length: 0),
        radius: selectionInlineSyntaxRadius + (distance / 2) + 1
      )
    }

    static let selectionInlineSyntaxRadius = 512

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

    static func shouldOfferDeleteBackwardCommand(selectedRange: NSRange) -> Bool {
      selectedRange.location == 0 && selectedRange.length == 0
    }

    static func shouldScheduleDeferredHighlighting(
      text: String,
      previousHighlightedText: String?,
      monospacedUnchanged: Bool
    ) -> Bool {
      shouldScheduleDeferredHighlighting(
        text: text,
        utf16Length: OrgSyntaxHighlighter.utf16Length(
          of: text,
          upTo: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1
        ),
        previousHighlightedText: previousHighlightedText,
        monospacedUnchanged: monospacedUnchanged
      )
    }

    static func shouldScheduleDeferredHighlighting(
      text: String,
      utf16Length: Int,
      previousHighlightedText: String?,
      monospacedUnchanged: Bool
    ) -> Bool {
      guard OrgSyntaxHighlighter.shouldTokenizeLiveText(utf16Length: utf16Length) else {
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
      let visibleOrigin = Self.visibleOrigin(of: textView)
      let typingAttributes = OrgSyntaxHighlighter.apply(
        to: storage,
        monospaced: parent.monospaced
      )
      textView.typingAttributes = typingAttributes
      textView.selectedRanges = selectedRanges
      Self.restoreVisibleOrigin(visibleOrigin, of: textView)
      recordHighlightedState(for: textView)
      publishContentHeight(for: textView)
    }

    func publishContentHeight(for textView: NSTextView) {
      guard let contentHeight = parent.contentHeight else { return }
      let nextHeight = Self.measuredContentHeight(for: textView)
      guard abs(contentHeight.wrappedValue - nextHeight) > 0.5 else { return }
      DispatchQueue.main.async {
        guard abs(contentHeight.wrappedValue - nextHeight) > 0.5 else { return }
        contentHeight.wrappedValue = nextHeight
      }
    }

    static func measuredContentHeight(for textView: NSTextView) -> CGFloat {
      guard let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
      else {
        return 0
      }
      textContainer.containerSize = NSSize(
        width: max(1, textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width),
        height: CGFloat.greatestFiniteMagnitude
      )
      layoutManager.ensureLayout(for: textContainer)
      let usedRect = layoutManager.usedRect(for: textContainer)
      return ceil(max(0, usedRect.height) + textView.textContainerInset.height * 2 + 2)
    }

    static func visibleOrigin(of textView: NSTextView) -> NSPoint? {
      textView.enclosingScrollView?.contentView.bounds.origin
    }

    static func restoreVisibleOrigin(_ origin: NSPoint?, of textView: NSTextView) {
      guard let origin,
            let scrollView = textView.enclosingScrollView
      else {
        return
      }
      let clipView = scrollView.contentView
      guard !NSEqualPoints(clipView.bounds.origin, origin) else { return }
      clipView.scroll(to: origin)
      scrollView.reflectScrolledClipView(clipView)
    }

    private func recordHighlightedState(for textView: NSTextView) {
      let text = textView.string
      let utf16Length = textView.textStorage?.length ?? (text as NSString).length
      recordHighlightedState(text: text, utf16Length: utf16Length)
    }

    private func recordHighlightedState(text: String, utf16Length: Int) {
      hasHighlightedText = true
      lastHighlightedMonospaced = parent.monospaced
      if OrgSyntaxHighlighter.shouldTokenizeLiveText(utf16Length: utf16Length) {
        lastHighlightedText = text
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
  case headingTitle
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

  static func shouldTokenizeLiveText(_ text: String) -> Bool {
    utf16Length(of: text, upTo: liveTokenizationUTF16Limit + 1) <= liveTokenizationUTF16Limit
  }

  static func utf16Length(of text: String, upTo limit: Int? = nil) -> Int {
    var count = 0
    for _ in text.utf16 {
      count += 1
      if let limit, count >= limit {
        return count
      }
    }
    return count
  }

  static func hasSyntaxCandidate(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    var httpMatchIndex = 0
    for byte in text.utf8 {
      switch byte {
      case 35, 40, 42, 43, 47, 58, 60, 61, 91, 93, 95, 96, 126:
        return true
      default:
        if byte == httpBytes[httpMatchIndex] {
          httpMatchIndex += 1
          if httpMatchIndex == httpBytes.count {
            return true
          }
        } else {
          httpMatchIndex = byte == httpBytes[0] ? 1 : 0
        }
      }
    }
    return false
  }

  private static let httpBytes: [UInt8] = [104, 116, 116, 112]

  static func shouldPreserveExistingAttributesAfterEdit(
    utf16Length: Int,
    hasHighlightedBefore: Bool,
    monospacedUnchanged: Bool
  ) -> Bool {
    hasHighlightedBefore
      && monospacedUnchanged
      && !shouldTokenizeLiveText(utf16Length: utf16Length)
  }

  static func baseFont(monospaced: Bool) -> NSFont {
    monospaced
      ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      : NSFont.systemFont(ofSize: NSFont.systemFontSize)
  }

  private static func collectLineTokens(in text: String, into tokens: inout [OrgSyntaxHighlightToken]) {
    guard !text.isEmpty else { return }
    var lineOffset = 0
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, lineSlice) in lines.enumerated() {
      let lineLength = lineSlice.utf16.count
      if lineMayContainBlockSyntax(lineSlice) {
        let line = String(lineSlice)
        collectHeadingTokens(line: line, lineOffset: lineOffset, into: &tokens)
        collectLineRegex(regex: keywordLineRegex, kind: .keyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
        collectLineRegex(regex: blockKeywordLineRegex, kind: .keyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
        collectLineRegex(regex: planningLineRegex, kind: .planningKeyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
        collectLineRegex(regex: propertyLineRegex, kind: .propertyKey, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
        collectLineRegex(regex: commentLineRegex, kind: .comment, line: line, lineOffset: lineOffset, into: &tokens)
      }
      lineOffset += lineLength
      if index < lines.count - 1 {
        lineOffset += 1
      }
    }
  }

  static func lineMayContainBlockSyntax(_ line: Substring) -> Bool {
    guard !line.isEmpty else { return false }
    if line.first == "*" {
      return true
    }

    var cursor = line.startIndex
    while cursor < line.endIndex, line[cursor].isWhitespace {
      cursor = line.index(after: cursor)
    }
    guard cursor < line.endIndex else { return false }

    switch line[cursor] {
    case "#", ":":
      return true
    case "C":
      return line[cursor...].hasPrefix("CLOSED")
    case "D":
      return line[cursor...].hasPrefix("DEADLINE")
    case "S":
      return line[cursor...].hasPrefix("SCHEDULED")
    default:
      return false
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

    let tagMatch = headingTagRegex.firstMatch(in: line, range: fullRange)
    if let tagMatch {
      append(tagMatch.range(at: 1), kind: .tag, lineOffset: lineOffset, into: &tokens)
    }

    var titleStart = match.range.location + match.range.length
    while titleStart < ns.length,
          CharacterSet.whitespaces.contains(UnicodeScalar(ns.character(at: titleStart)) ?? " ") {
      titleStart += 1
    }
    var titleEnd = tagMatch?.range.location ?? ns.length
    while titleEnd > titleStart,
          CharacterSet.whitespaces.contains(UnicodeScalar(ns.character(at: titleEnd - 1)) ?? " ") {
      titleEnd -= 1
    }
    append(
      NSRange(location: titleStart, length: titleEnd - titleStart),
      kind: .headingTitle,
      lineOffset: lineOffset,
      into: &tokens
    )
  }

  private static func collectInlineTokens(in text: String, into tokens: inout [OrgSyntaxHighlightToken]) {
    guard textMayContainInlineSyntax(text) else { return }

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

  static func textMayContainInlineSyntax(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    var httpMatchIndex = 0
    for byte in text.utf8 {
      switch byte {
      case 42, 43, 46, 47, 60, 61, 91, 95, 96, 126:
        return true
      default:
        if byte == httpBytes[httpMatchIndex] {
          httpMatchIndex += 1
          if httpMatchIndex == httpBytes.count {
            return true
          }
        } else {
          httpMatchIndex = byte == httpBytes[0] ? 1 : 0
        }
      }
    }
    return false
  }

  private static func collectInlineDelimiterTokens(in text: String, into tokens: inout [OrgSyntaxHighlightToken]) {
    let tokenCount = tokens.count
    guard tokenCount > 0 else { return }
    for index in 0..<tokenCount {
      let token = tokens[index]
      guard isInlineDelimitedKind(token.kind) else { continue }
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

  private static func isInlineDelimitedKind(_ kind: OrgSyntaxHighlightKind) -> Bool {
    switch kind {
    case .link, .code, .emphasis, .timestamp:
      return true
    case .headingStars, .headingTitle, .keyword, .planningKeyword, .propertyKey, .todo, .priority, .tag, .linkTarget, .syntaxDelimiter, .comment:
      return false
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
      return hiddenSyntaxAttributes(baseFont: baseFont)
    case .headingTitle:
      return [
        .foregroundColor: NSColor.labelColor,
        .font: NSFont.systemFont(ofSize: baseFont.pointSize + 2, weight: .semibold)
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
      return hiddenSyntaxAttributes(baseFont: baseFont)
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
      return hiddenSyntaxAttributes(baseFont: baseFont)
    case .comment:
      return [
        .foregroundColor: NSColor.secondaryLabelColor
      ]
    }
  }

  private static func hiddenSyntaxAttributes(baseFont: NSFont) -> [NSAttributedString.Key: Any] {
    [
      .foregroundColor: NSColor.clear,
      .backgroundColor: NSColor.clear,
      .underlineStyle: 0,
      .font: NSFont.monospacedSystemFont(ofSize: max(0.1, baseFont.pointSize * 0.01), weight: .regular)
    ]
  }
}
