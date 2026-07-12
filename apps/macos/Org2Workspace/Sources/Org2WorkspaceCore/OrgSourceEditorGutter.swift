import AppKit
import Foundation

enum OrgSourceEditorGutterAction: Equatable, Sendable {
  case command(line: Int, OrgSourceEditorCommand)
  case backlinks(line: Int)
}

struct OrgSourceEditorGutterItem: Equatable, Identifiable, Sendable {
  let line: Int
  let endLine: Int
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
}

enum OrgSourceEditorGutterModel {
  static func items(
    text: String,
    snapshot: OrgSourceEditorSemanticSnapshot,
    foldedHeadlineStartLines: Set<Int>
  ) -> [OrgSourceEditorGutterItem] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let headlines = snapshot.regions
      .filter { $0.kind == .headline }
      .sorted { $0.startLine < $1.startLine }
    let diagnosticLines = Set(snapshot.diagnostics.map(\.line))
    let diagnosticHeadlineLines = Set(diagnosticLines.compactMap { diagnosticLine in
      headlines
        .filter { $0.startLine <= diagnosticLine && $0.endLine >= diagnosticLine }
        .max { $0.startLine < $1.startLine }?
        .startLine
    })

    return headlines.compactMap { headline in
      guard headline.startLine > 0, headline.startLine <= lines.count else { return nil }
      let rawHeading = lines[headline.startLine - 1]
      let nextHeadlineLine = headlines.first { $0.startLine > headline.startLine }?.startLine
      let metadataEndLine = min(
        headline.endLine,
        max(headline.startLine, (nextHeadlineLine ?? (headline.endLine + 1)) - 1)
      )
      let metadataLines = metadataEndLine > headline.startLine
        ? lines[headline.startLine..<min(metadataEndLine, lines.count)]
        : []
      let priority = firstCapture(
        in: rawHeading,
        pattern: #"^\*+\s+(?:(?:TODO|IN_PROGRESS|PROG|WAIT|HOLD|PAUSED|DONE|CANCELED|CANCELLED)\s+)?\[#([A-Za-z0-9])\]"#
      )?.uppercased()
      let title = rawHeading.replacingOccurrences(
        of: #"^\*+\s+(?:(?:TODO|IN_PROGRESS|PROG|WAIT|HOLD|PAUSED|DONE|CANCELED|CANCELLED)\s+)?(?:\[#[A-Za-z0-9]\]\s+)?"#,
        with: "",
        options: .regularExpression
      )
      return OrgSourceEditorGutterItem(
        line: headline.startLine,
        endLine: headline.endLine,
        level: headline.level ?? 1,
        title: title,
        todo: headline.todo,
        priority: priority,
        hasScheduled: metadataLines.contains { $0.range(of: #"^\s*SCHEDULED:"#, options: .regularExpression) != nil },
        hasDeadline: metadataLines.contains { $0.range(of: #"^\s*DEADLINE:"#, options: .regularExpression) != nil },
        hasDiagnostic: diagnosticHeadlineLines.contains(headline.startLine),
        isFolded: foldedHeadlineStartLines.contains(headline.startLine)
      )
    }
  }

  private static func firstCapture(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
          ),
          match.numberOfRanges > 1,
          match.range(at: 1).location != NSNotFound
    else { return nil }
    return (text as NSString).substring(with: match.range(at: 1))
  }
}

@MainActor
final class OrgSourceEditorGutterView: NSRulerView {
  var items: [OrgSourceEditorGutterItem] = [] {
    didSet { needsDisplay = true }
  }
  var performAction: ((OrgSourceEditorGutterAction) -> Void)?

  private let gutterWidth: CGFloat = 46

  init(scrollView: NSScrollView, textView: NSTextView) {
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = gutterWidth
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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

    for item in items {
      guard let y = markerY(forLine: item.line, in: textView),
            y >= bounds.minY - 12,
            y <= bounds.maxY + 12
      else { continue }
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

  func markerY(forLine line: Int, in textView: NSTextView) -> CGFloat? {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer
    else { return nil }
    let nsText = textView.string as NSString
    let lineRange = OrgSourceTextEditing.lineRange(in: nsText, line: line)
    guard lineRange.location <= nsText.length else { return nil }
    let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(lineRange.location, max(0, nsText.length - 1)))
    layoutManager.ensureLayout(for: textContainer)
    let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    let point = NSPoint(
      x: textView.textContainerOrigin.x,
      y: textView.textContainerOrigin.y + fragment.midY
    )
    return convert(point, from: textView).y
  }

  private func item(at point: NSPoint, in textView: NSTextView) -> OrgSourceEditorGutterItem? {
    items.min { lhs, rhs in
      abs((markerY(forLine: lhs.line, in: textView) ?? -.greatestFiniteMagnitude) - point.y)
        < abs((markerY(forLine: rhs.line, in: textView) ?? -.greatestFiniteMagnitude) - point.y)
    }.flatMap { item in
      guard let y = markerY(forLine: item.line, in: textView), abs(y - point.y) <= 10 else { return nil }
      return item
    }
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
