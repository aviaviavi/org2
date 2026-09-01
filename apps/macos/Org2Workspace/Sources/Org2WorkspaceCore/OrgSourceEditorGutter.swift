import AppKit
import Foundation

enum OrgSourceEditorGutterAction: Equatable, Sendable {
  case command(line: Int, OrgSourceEditorCommand)
  case backlinks(line: Int)
}

struct OrgSourceEditorGutterItem: Equatable, Identifiable, Sendable {
  let line: Int
  let endLine: Int
  let utf16Offset: Int
  let level: Int
  let title: String
  let todo: String?
  let priority: String?
  let hasScheduled: Bool
  let hasDeadline: Bool
  let hasDiagnostic: Bool
  let isFolded: Bool

  var id: Int { line }
  var isFoldable: Bool { endLine > line }

  func withFoldedState(_ isFolded: Bool) -> Self {
    Self(
      line: line,
      endLine: endLine,
      utf16Offset: utf16Offset,
      level: level,
      title: title,
      todo: todo,
      priority: priority,
      hasScheduled: hasScheduled,
      hasDeadline: hasDeadline,
      hasDiagnostic: hasDiagnostic,
      isFolded: isFolded
    )
  }
}

enum OrgSourceEditorGutterModel {
  private static let priorityPattern = try! NSRegularExpression(
    pattern: #"^\*+\s+(?:(?:TODO|IN_PROGRESS|PROG|WAIT|HOLD|PAUSED|DONE|CANCELED|CANCELLED)\s+)?\[#([A-Za-z0-9])\]"#
  )
  private static let titlePattern = try! NSRegularExpression(
    pattern: #"^\*+\s+(?:(?:TODO|IN_PROGRESS|PROG|WAIT|HOLD|PAUSED|DONE|CANCELED|CANCELLED)\s+)?(?:\[#[A-Za-z0-9]\]\s+)?"#
  )
  private static let scheduledPattern = try! NSRegularExpression(pattern: #"^\s*SCHEDULED:"#)
  private static let deadlinePattern = try! NSRegularExpression(pattern: #"^\s*DEADLINE:"#)

  static func items(
    text: String,
    snapshot: OrgSourceEditorSemanticSnapshot,
    foldedHeadlineStartLines: Set<Int>
  ) -> [OrgSourceEditorGutterItem] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var lineUTF16Offsets: [Int] = []
    lineUTF16Offsets.reserveCapacity(lines.count)
    var nextUTF16Offset = 0
    for line in lines {
      lineUTF16Offsets.append(nextUTF16Offset)
      nextUTF16Offset += (line as NSString).length + 1
    }
    let headlines = snapshot.regions
      .filter { $0.kind == .headline }
      .sorted { $0.startLine < $1.startLine }
    let diagnosticHeadlineLines = diagnosticHeadlineLines(
      for: Set(snapshot.diagnostics.map(\.line)),
      in: headlines
    )

    return headlines.enumerated().compactMap { index, headline in
      guard headline.startLine > 0, headline.startLine <= lines.count else { return nil }
      let rawHeading = lines[headline.startLine - 1]
      let nextHeadlineLine = index + 1 < headlines.count ? headlines[index + 1].startLine : nil
      let metadataEndLine = min(
        headline.endLine,
        max(headline.startLine, (nextHeadlineLine ?? (headline.endLine + 1)) - 1)
      )
      let metadataLines = metadataEndLine > headline.startLine
        ? lines[headline.startLine..<min(metadataEndLine, lines.count)]
        : []
      let priority = firstCapture(
        in: rawHeading,
        regex: priorityPattern
      )?.uppercased()
      let rawHeadingRange = NSRange(location: 0, length: (rawHeading as NSString).length)
      let title = titlePattern.stringByReplacingMatches(
        in: rawHeading,
        range: rawHeadingRange,
        withTemplate: ""
      )
      return OrgSourceEditorGutterItem(
        line: headline.startLine,
        endLine: headline.endLine,
        utf16Offset: lineUTF16Offsets[headline.startLine - 1],
        level: headline.level ?? 1,
        title: title,
        todo: headline.todo,
        priority: priority,
        hasScheduled: metadataLines.contains { firstMatch(of: scheduledPattern, in: $0) },
        hasDeadline: metadataLines.contains { firstMatch(of: deadlinePattern, in: $0) },
        hasDiagnostic: diagnosticHeadlineLines.contains(headline.startLine),
        isFolded: foldedHeadlineStartLines.contains(headline.startLine)
      )
    }
  }

  private static func diagnosticHeadlineLines(
    for lines: Set<Int>,
    in headlines: [OrgSourceSemanticRegion]
  ) -> Set<Int> {
    guard !lines.isEmpty, !headlines.isEmpty else { return [] }
    var result = Set<Int>()
    var active: [OrgSourceSemanticRegion] = []
    var headlineIndex = 0
    for line in lines.sorted() {
      while headlineIndex < headlines.count,
            headlines[headlineIndex].startLine <= line {
        let headline = headlines[headlineIndex]
        while let last = active.last,
              last.endLine < headline.startLine {
          active.removeLast()
        }
        while let last = active.last,
              !(last.startLine <= headline.startLine && last.endLine >= headline.endLine) {
          active.removeLast()
        }
        active.append(headline)
        headlineIndex += 1
      }
      while let last = active.last, last.endLine < line {
        active.removeLast()
      }
      if let last = active.last,
         last.startLine <= line,
         last.endLine >= line {
        result.insert(last.startLine)
      }
    }
    return result
  }

  private static func firstCapture(in text: String, regex: NSRegularExpression) -> String? {
    guard let match = regex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
          ),
          match.numberOfRanges > 1,
          match.range(at: 1).location != NSNotFound
    else { return nil }
    return (text as NSString).substring(with: match.range(at: 1))
  }

  private static func firstMatch(of regex: NSRegularExpression, in text: String) -> Bool {
    regex.firstMatch(
      in: text,
      range: NSRange(location: 0, length: (text as NSString).length)
    ) != nil
  }
}

@MainActor
final class OrgSourceEditorGutterView: NSRulerView {
  var items: [OrgSourceEditorGutterItem] = [] {
    didSet {
      invalidateVisibleGeometry()
    }
  }
  var performAction: ((OrgSourceEditorGutterAction) -> Void)?

  private let gutterWidth: CGFloat = 46
  private var visibleMarkers: [(item: OrgSourceEditorGutterItem, y: CGFloat)] = []
  private(set) var lastDrawnItemCount = 0

  init(scrollView: NSScrollView, textView: NSTextView) {
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = gutterWidth
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func invalidateVisibleGeometry() {
    visibleMarkers = []
    lastDrawnItemCount = 0
    needsDisplay = true
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView = clientView as? NSTextView else { return }
    NSColor.textBackgroundColor.withAlphaComponent(0.72).setFill()
    rect.intersection(bounds).fill()
    NSColor.separatorColor.withAlphaComponent(0.38).setStroke()
    let separator = NSBezierPath()
    separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
    separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
    separator.stroke()

    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer
    else { return }
    layoutManager.ensureLayout(forBoundingRect: textView.visibleRect, in: textContainer)
    let glyphRange = layoutManager.glyphRange(
      forBoundingRect: textView.visibleRect,
      in: textContainer
    )
    let characterRange = layoutManager.characterRange(
      forGlyphRange: glyphRange,
      actualGlyphRange: nil
    )
    visibleMarkers = []
    lastDrawnItemCount = 0
    for item in visibleItems(around: characterRange) {
      guard let y = markerY(for: item, in: textView),
            y >= bounds.minY - 12,
            y <= bounds.maxY + 12
      else { continue }
      visibleMarkers.append((item, y))
      lastDrawnItemCount += 1
      draw(item, at: y)
    }
  }

  override func mouseDown(with event: NSEvent) {
    guard let textView = clientView as? NSTextView,
          let hit = item(at: convert(event.locationInWindow, from: nil), in: textView)
    else { return }
    let point = convert(event.locationInWindow, from: nil)
    if point.x < 17, hit.isFoldable {
      performAction?(.command(line: hit.line, .toggleFold))
    } else if point.x < 31, hit.todo != nil {
      performAction?(.command(line: hit.line, .cycleTodo))
    } else {
      NSMenu.popUpContextMenu(menu(for: hit), with: event, for: self)
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let textView = clientView as? NSTextView,
          let hit = item(at: convert(event.locationInWindow, from: nil), in: textView)
    else { return }
    NSMenu.popUpContextMenu(menu(for: hit), with: event, for: self)
  }

  private func draw(_ item: OrgSourceEditorGutterItem, at y: CGFloat) {
    if item.isFoldable {
      let triangle = NSBezierPath()
      if item.isFolded {
        triangle.move(to: NSPoint(x: 6, y: y - 4))
        triangle.line(to: NSPoint(x: 12, y: y))
        triangle.line(to: NSPoint(x: 6, y: y + 4))
      } else {
        triangle.move(to: NSPoint(x: 5, y: y - 3))
        triangle.line(to: NSPoint(x: 13, y: y - 3))
        triangle.line(to: NSPoint(x: 9, y: y + 3))
      }
      triangle.close()
      NSColor.secondaryLabelColor.withAlphaComponent(0.82).setFill()
      triangle.fill()
    }

    if let todo = item.todo {
      statusColor(todo).setFill()
      NSBezierPath(ovalIn: NSRect(x: 20, y: y - 4, width: 8, height: 8)).fill()
    } else {
      NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setStroke()
      NSBezierPath(ovalIn: NSRect(x: 21, y: y - 3, width: 6, height: 6)).stroke()
    }

    if let priority = item.priority {
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8, weight: .bold),
        .foregroundColor: priority == "A" ? NSColor.systemOrange : NSColor.secondaryLabelColor
      ]
      priority.draw(at: NSPoint(x: 33, y: y - 5), withAttributes: attributes)
    } else if item.hasDeadline || item.hasScheduled {
      let color = item.hasDeadline ? NSColor.systemOrange : NSColor.systemBlue
      color.setFill()
      NSBezierPath(roundedRect: NSRect(x: 34, y: y - 1, width: 6, height: 2), xRadius: 1, yRadius: 1).fill()
    }

    if item.hasDiagnostic {
      NSColor.systemRed.setFill()
      NSBezierPath(ovalIn: NSRect(x: 41, y: y - 2, width: 4, height: 4)).fill()
    }
  }

  private func statusColor(_ todo: String) -> NSColor {
    switch todo.uppercased() {
    case "DONE": return .systemGreen
    case "CANCELED", "CANCELLED": return .systemRed
    case "IN_PROGRESS", "PROG": return .systemOrange
    case "WAIT", "HOLD", "PAUSED": return .systemGray
    default: return .controlAccentColor
    }
  }

  func markerY(for item: OrgSourceEditorGutterItem, in textView: NSTextView) -> CGFloat? {
    guard let layoutManager = textView.layoutManager else { return nil }
    let textLength = textView.textStorage?.length ?? 0
    guard textLength > 0, item.utf16Offset < textLength else { return nil }
    let glyphIndex = layoutManager.glyphIndexForCharacter(at: item.utf16Offset)
    let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    let point = NSPoint(
      x: textView.textContainerOrigin.x,
      y: textView.textContainerOrigin.y + fragment.midY
    )
    return convert(point, from: textView).y
  }

  func markerY(forLine line: Int, in textView: NSTextView) -> CGFloat? {
    guard let item = items.first(where: { $0.line == line }) else { return nil }
    return markerY(for: item, in: textView)
  }

  private func item(at point: NSPoint, in textView: NSTextView) -> OrgSourceEditorGutterItem? {
    visibleMarkers.min { lhs, rhs in
      abs(lhs.y - point.y) < abs(rhs.y - point.y)
    }.flatMap { marker in
      abs(marker.y - point.y) <= 10 ? marker.item : nil
    }
  }

  private func visibleItems(around range: NSRange) -> ArraySlice<OrgSourceEditorGutterItem> {
    guard !items.isEmpty else { return [] }
    let lowerOffset = max(0, range.location)
    let upperOffset = max(lowerOffset, NSMaxRange(range))
    var lower = 0
    var upper = items.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if items[middle].utf16Offset < lowerOffset {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    let start = max(0, lower - 1)
    var end = lower
    while end < items.count, items[end].utf16Offset <= upperOffset {
      end += 1
    }
    return items[start..<min(items.count, end + 1)]
  }

  private func menu(for item: OrgSourceEditorGutterItem) -> NSMenu {
    let menu = NSMenu(title: item.title)
    if item.isFoldable {
      menu.addItem(menuItem(item.isFolded ? "Expand Heading" : "Collapse Heading", action: .command(line: item.line, .toggleFold)))
    }
    menu.addItem(menuItem("Cycle TODO", action: .command(line: item.line, .cycleTodo)))

    let priorityItem = NSMenuItem(title: "Priority", action: nil, keyEquivalent: "")
    let priorityMenu = NSMenu(title: "Priority")
    for value in ["A", "B", "C"] {
      let menuItem = menuItem(value, action: .command(line: item.line, .setPriority(value)))
      menuItem.state = item.priority == value ? .on : .off
      priorityMenu.addItem(menuItem)
    }
    priorityMenu.addItem(.separator())
    priorityMenu.addItem(menuItem("Clear", action: .command(line: item.line, .setPriority(nil))))
    priorityItem.submenu = priorityMenu
    menu.addItem(priorityItem)

    menu.addItem(.separator())
    menu.addItem(menuItem("Schedule Today", action: .command(line: item.line, .scheduleToday)))
    menu.addItem(menuItem("Deadline Today", action: .command(line: item.line, .deadlineToday)))
    if item.hasScheduled || item.hasDeadline {
      menu.addItem(menuItem("Clear Planning", action: .command(line: item.line, .clearPlanning)))
    }

    menu.addItem(.separator())
    menu.addItem(menuItem("Show References", action: .backlinks(line: item.line)))
    menu.addItem(menuItem("Set Property...", action: .command(line: item.line, .insertProperty)))
    menu.addItem(.separator())
    menu.addItem(menuItem("Promote", action: .command(line: item.line, .promote)))
    menu.addItem(menuItem("Demote", action: .command(line: item.line, .demote)))
    menu.addItem(menuItem("Insert Heading", action: .command(line: item.line, .insertHeading)))
    return menu
  }

  private func menuItem(_ title: String, action: OrgSourceEditorGutterAction) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = OrgSourceEditorGutterActionBox(action)
    return item
  }

  @objc private func performMenuAction(_ sender: NSMenuItem) {
    guard let box = sender.representedObject as? OrgSourceEditorGutterActionBox else { return }
    performAction?(box.action)
  }
}

private final class OrgSourceEditorGutterActionBox: NSObject {
  let action: OrgSourceEditorGutterAction

  init(_ action: OrgSourceEditorGutterAction) {
    self.action = action
  }
}
