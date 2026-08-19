import Foundation

public enum OrgRenderedBlock: Equatable, Sendable {
  case heading(OrgHeadingBlock)
  case planning(OrgPlanningBlock)
  case properties([OrgPropertyRow])
  case quote([String])
  case source(language: String?, lines: [String])
  case table(OrgTableBlock)
  case horizontalRule
  case listItem(indent: Int, marker: String, checkbox: OrgListCheckbox?, text: String)
  case paragraph(String)
  case keyword(key: String, value: String)
  case blank
}

public struct OrgEditableBlock: Identifiable, Equatable, Sendable {
  public let id: String
  public let startLine: Int
  public let endLineExclusive: Int
  public let rawText: String
  public let rendered: OrgRenderedBlock
  public let renderIdentity: OrgEditableBlockRenderIdentity

  public init(startLine: Int, endLineExclusive: Int, rawText: String, rendered: OrgRenderedBlock) {
    self.init(
      id: "\(startLine):\(endLineExclusive):\(Self.kindName(rendered))",
      startLine: startLine,
      endLineExclusive: endLineExclusive,
      rawText: rawText,
      rendered: rendered
    )
  }

  public init(
    id: String,
    startLine: Int,
    endLineExclusive: Int,
    rawText: String,
    rendered: OrgRenderedBlock
  ) {
    self.id = id
    self.startLine = startLine
    self.endLineExclusive = endLineExclusive
    self.rawText = rawText
    self.rendered = rendered
    self.renderIdentity = OrgEditableBlockRenderIdentity(
      id: id,
      startLine: startLine,
      endLineExclusive: endLineExclusive,
      rawText: rawText,
      renderedKind: Self.kindName(rendered)
    )
  }

  public func preservingID(_ id: String) -> OrgEditableBlock {
    OrgEditableBlock(
      id: id,
      startLine: startLine,
      endLineExclusive: endLineExclusive,
      rawText: rawText,
      rendered: rendered
    )
  }

  public var isEditable: Bool {
    if case .blank = rendered { return false }
    return true
  }

  public var displayRange: String {
    if endLineExclusive <= startLine + 1 { return "\(startLine)" }
    return "\(startLine)-\(endLineExclusive - 1)"
  }

  private static func kindName(_ block: OrgRenderedBlock) -> String {
    switch block {
    case .heading: "heading"
    case .planning: "planning"
    case .properties: "properties"
    case .quote: "quote"
    case .source: "source"
    case .table: "table"
    case .horizontalRule: "horizontal-rule"
    case .listItem: "list"
    case .paragraph: "paragraph"
    case .keyword: "keyword"
    case .blank: "blank"
    }
  }
}

public struct OrgEditableBlockRenderIdentity: Equatable, Sendable {
  public let id: String
  public let startLine: Int
  public let endLineExclusive: Int
  public let rawUTF8Count: Int
  public let rawHash: Int
  public let renderedKind: String

  public init(
    id: String,
    startLine: Int,
    endLineExclusive: Int,
    rawText: String,
    renderedKind: String
  ) {
    self.id = id
    self.startLine = startLine
    self.endLineExclusive = endLineExclusive
    self.rawUTF8Count = rawText.utf8.count
    self.rawHash = rawText.hashValue
    self.renderedKind = renderedKind
  }
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

public enum OrgListCheckbox: String, Equatable, Sendable {
  case unchecked
  case checked
  case mixed

  public var rawMarker: String {
    switch self {
    case .unchecked: "[ ]"
    case .checked: "[X]"
    case .mixed: "[-]"
    }
  }

  public var toggled: OrgListCheckbox {
    switch self {
    case .checked:
      return .unchecked
    case .unchecked, .mixed:
      return .checked
    }
  }
}

public struct OrgPropertyRow: Equatable, Sendable {
  public let key: String
  public let value: String
}

public struct OrgEditablePropertyDrawer: Equatable, Sendable {
  public var beginLine: String
  public var endLine: String
  public var rows: [OrgEditablePropertyRow]

  public init(rawText: String, fallbackRows: [OrgPropertyRow] = []) {
    let lines = Self.normalizedLines(rawText)
    let firstLine = lines.first ?? ""
    let lastLine = lines.last ?? ""
    let beginLooksValid = firstLine.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == ":PROPERTIES:"
    let endLooksValid = lastLine.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == ":END:"

    beginLine = beginLooksValid ? firstLine : ":PROPERTIES:"
    endLine = endLooksValid ? lastLine : "\(Self.leadingWhitespace(from: beginLine)):END:"

    let propertyLines: ArraySlice<String>
    if beginLooksValid, endLooksValid, lines.count >= 2 {
      propertyLines = lines.dropFirst().dropLast()
    } else if beginLooksValid {
      propertyLines = lines.dropFirst()
    } else {
      propertyLines = lines[...]
    }

    rows = propertyLines.compactMap(Self.parsePropertyLine)
    if rows.isEmpty, !fallbackRows.isEmpty {
      let indent = Self.leadingWhitespace(from: beginLine)
      rows = fallbackRows.map {
        OrgEditablePropertyRow(indent: indent, key: $0.key, value: $0.value)
      }
    }
  }

  public var formattedRawText: String {
    ([beginLine] + rows.map(\.formattedRawText) + [endLine]).joined(separator: "\n")
  }

  public var renderedRows: [OrgPropertyRow] {
    rows
      .filter { !$0.normalizedKey.isEmpty }
      .map { OrgPropertyRow(key: $0.normalizedKey, value: Org2Display.cleanInline($0.value)) }
  }

  public mutating func addProperty(key: String = "", value: String = "") {
    rows.append(OrgEditablePropertyRow(indent: Self.leadingWhitespace(from: beginLine), key: key, value: value))
  }

  public mutating func removeProperty(at index: Int) {
    guard rows.indices.contains(index) else { return }
    rows.remove(at: index)
  }

  public mutating func setKey(at index: Int, value: String) {
    guard rows.indices.contains(index) else { return }
    rows[index].key = value
  }

  public mutating func setValue(at index: Int, value: String) {
    guard rows.indices.contains(index) else { return }
    rows[index].value = value
  }

  private static func normalizedLines(_ raw: String) -> [String] {
    raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }

  private static func parsePropertyLine(_ line: String) -> OrgEditablePropertyRow? {
    let indent = leadingWhitespace(from: line)
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(":"),
          let secondColon = trimmed.dropFirst().firstIndex(of: ":")
    else {
      return nil
    }

    let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<secondColon])
    let normalizedKey = normalizeKey(key)
    guard !normalizedKey.isEmpty,
          normalizedKey != "PROPERTIES",
          normalizedKey != "END"
    else {
      return nil
    }

    let value = String(trimmed[trimmed.index(after: secondColon)...])
      .trimmingCharacters(in: .whitespaces)
    return OrgEditablePropertyRow(indent: indent, key: key, value: value)
  }

  fileprivate static func normalizeKey(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: CharacterSet(charactersIn: ": \t\r\n"))
      .uppercased()
  }

  private static func leadingWhitespace(from line: String) -> String {
    String(line.prefix { $0 == " " || $0 == "\t" })
  }
}

public struct OrgEditablePropertyRow: Equatable, Sendable {
  public var indent: String
  public var key: String
  public var value: String

  public init(indent: String = "", key: String, value: String) {
    self.indent = indent
    self.key = key
    self.value = value
  }

  public var normalizedKey: String {
    OrgEditablePropertyDrawer.normalizeKey(key)
  }

  public var formattedRawText: String {
    let keyText = normalizedKey.isEmpty ? "PROPERTY" : normalizedKey
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedValue.isEmpty {
      return "\(indent):\(keyText):"
    }
    return "\(indent):\(keyText): \(trimmedValue)"
  }
}

public struct OrgEditableSourceBlock: Equatable, Sendable {
  public var beginKeyword: String
  public var endKeyword: String
  public var language: String
  public var parameters: String
  public var body: String

  public init(rawText: String, fallbackLanguage: String? = nil, fallbackLines: [String] = []) {
    let lines = Self.normalizedLines(rawText)
    let firstLine = lines.first ?? ""
    let lastLine = lines.last ?? ""
    let parsedBegin = Self.parseBeginLine(firstLine)
    let parsedEnd = Self.parseEndLine(lastLine)

    beginKeyword = parsedBegin?.keyword ?? "#+begin_src"
    endKeyword = parsedEnd ?? Self.defaultEndKeyword(for: beginKeyword)
    language = parsedBegin?.language ?? fallbackLanguage ?? ""
    parameters = parsedBegin?.parameters ?? ""

    if lines.count >= 2 {
      body = Array(lines.dropFirst().dropLast()).joined(separator: "\n")
    } else if !fallbackLines.isEmpty {
      body = fallbackLines.joined(separator: "\n")
    } else {
      body = ""
    }
  }

  public var formattedRawText: String {
    let begin = formattedBeginLine
    if body.isEmpty {
      return "\(begin)\n\(endKeyword)"
    }
    return "\(begin)\n\(body)\n\(endKeyword)"
  }

  public var renderedLanguage: String? {
    let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  public var renderedLines: [String] {
    body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  public mutating func setBeginKeyword(_ keyword: String) {
    beginKeyword = keyword
    endKeyword = Self.defaultEndKeyword(for: keyword)
    if keyword.lowercased().hasSuffix("begin_example") {
      language = ""
    }
  }

  private var formattedBeginLine: String {
    let normalizedKeyword = beginKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "#+begin_src"
      : beginKeyword.trimmingCharacters(in: .whitespacesAndNewlines)

    let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedParameters = parameters.trimmingCharacters(in: .whitespacesAndNewlines)

    if normalizedKeyword.lowercased().hasSuffix("begin_example") {
      return [normalizedKeyword, normalizedParameters]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    return [normalizedKeyword, normalizedLanguage, normalizedParameters]
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func normalizedLines(_ raw: String) -> [String] {
    raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }

  private static func parseBeginLine(_ line: String) -> (keyword: String, language: String, parameters: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let match = trimmed.range(
      of: #"(?i)^#\+(begin_src|begin_org2|begin_example)\b"#,
      options: .regularExpression
    ) else {
      return nil
    }

    let keyword = String(trimmed[match]).lowercased()
    let rest = String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces)
    if keyword.lowercased().hasSuffix("begin_example") {
      return (keyword, "", rest)
    }

    let parts = rest.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).map(String.init)
    return (
      keyword,
      parts.first ?? "",
      parts.count > 1 ? parts[1] : ""
    )
  }

  private static func parseEndLine(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let match = trimmed.range(
      of: #"(?i)^#\+(end_src|end_org2|end_example)\b"#,
      options: .regularExpression
    ) else {
      return nil
    }
    return String(trimmed[match]).lowercased()
  }

  private static func defaultEndKeyword(for beginKeyword: String) -> String {
    let lowercased = beginKeyword.lowercased()
    if lowercased.hasSuffix("begin_example") { return "#+end_example" }
    if lowercased.hasSuffix("begin_org2") { return "#+end_org2" }
    return "#+end_src"
  }
}

public struct OrgTableBlock: Equatable, Sendable {
  public let rows: [OrgTableRow]

  public var headerRowIndex: Int? {
    guard let firstCellRowIndex = rows.firstIndex(where: { row in
      if case .cells = row { return true }
      return false
    }) else {
      return nil
    }
    let separatorIndex = rows.index(after: firstCellRowIndex)
    guard rows.indices.contains(separatorIndex),
          case .separator = rows[separatorIndex]
    else {
      return nil
    }
    return firstCellRowIndex
  }

  public var columnCount: Int {
    rows.reduce(0) { count, row in
      switch row {
      case .cells(let cells):
        return max(count, cells.count)
      case .separator:
        return count
      }
    }
  }
}

public enum OrgTableRow: Equatable, Sendable {
  case cells([String])
  case separator
}

public struct OrgEditableTable: Equatable, Sendable {
  public var rows: [OrgEditableTableRow]

  public init(rawText: String, fallback: OrgTableBlock? = nil) {
    let parsedRows = Self.parseRows(rawText)
    if parsedRows.isEmpty, let fallback {
      rows = fallback.rows.map(OrgEditableTableRow.init(row:))
    } else if parsedRows.isEmpty {
      rows = [.cells([""])]
    } else {
      rows = parsedRows
    }
  }

  public var columnCount: Int {
    max(1, rows.reduce(0) { count, row in
      switch row {
      case .cells(let cells):
        return max(count, cells.count)
      case .separator:
        return count
      }
    })
  }

  public var renderedBlock: OrgTableBlock {
    OrgTableBlock(rows: rows.map { row in
      switch row {
      case .cells(let cells):
        return .cells(cells)
      case .separator:
        return .separator
      }
    })
  }

  public var formattedRawText: String {
    let widths = columnWidths
    return normalizedRows.map { row in
      switch row {
      case .cells(let cells):
        return Self.formatCells(cells, widths: widths)
      case .separator:
        return Self.formatSeparator(widths: widths)
      }
    }
    .joined(separator: "\n")
  }

  public func cell(row rowIndex: Int, column columnIndex: Int) -> String {
    guard rows.indices.contains(rowIndex),
          case .cells(let cells) = rows[rowIndex],
          cells.indices.contains(columnIndex)
    else {
      return ""
    }
    return cells[columnIndex]
  }

  public mutating func setCell(row rowIndex: Int, column columnIndex: Int, value: String) {
    guard rows.indices.contains(rowIndex), columnIndex >= 0 else { return }
    guard case .cells(var cells) = rows[rowIndex] else { return }
    while cells.count <= columnIndex {
      cells.append("")
    }
    cells[columnIndex] = value
    rows[rowIndex] = .cells(cells)
  }

  @discardableResult
  public mutating func pasteGrid(row rowIndex: Int, column columnIndex: Int, rawValue: String) -> Bool {
    guard columnIndex >= 0,
          let grid = Self.pastedGrid(from: rawValue)
    else {
      return false
    }

    var destinationRow = max(0, rowIndex)
    for pastedRow in grid {
      let targetRow = ensureCellRow(startingAt: destinationRow)
      for (columnOffset, value) in pastedRow.enumerated() {
        setCell(row: targetRow, column: columnIndex + columnOffset, value: value)
      }
      destinationRow = targetRow + 1
    }
    return true
  }

  public mutating func addRow(after rowIndex: Int? = nil) {
    let newRow = OrgEditableTableRow.cells(Array(repeating: "", count: columnCount))
    if let rowIndex, rows.indices.contains(rowIndex) {
      rows.insert(newRow, at: rows.index(after: rowIndex))
    } else {
      rows.append(newRow)
    }
  }

  public mutating func addSeparator(after rowIndex: Int? = nil) {
    if let rowIndex, rows.indices.contains(rowIndex) {
      rows.insert(.separator, at: rows.index(after: rowIndex))
    } else {
      rows.append(.separator)
    }
  }

  public mutating func addColumn() {
    rows = rows.map { row in
      switch row {
      case .cells(var cells):
        cells.append("")
        return .cells(cells)
      case .separator:
        return .separator
      }
    }
  }

  public mutating func removeRow(_ rowIndex: Int) {
    guard rows.indices.contains(rowIndex) else { return }
    let removingLastCellRow: Bool
    if case .cells = rows[rowIndex] {
      removingLastCellRow = rows.filter(\.isCellRow).count <= 1
    } else {
      removingLastCellRow = false
    }

    if removingLastCellRow {
      rows[rowIndex] = .cells(Array(repeating: "", count: columnCount))
    } else {
      rows.remove(at: rowIndex)
    }

    if rows.isEmpty {
      rows = [.cells([""])]
    }
  }

  public mutating func removeColumn(_ columnIndex: Int) {
    guard columnCount > 1, columnIndex >= 0, columnIndex < columnCount else { return }
    rows = rows.map { row in
      switch row {
      case .cells(var cells):
        while cells.count < columnCount {
          cells.append("")
        }
        cells.remove(at: columnIndex)
        return .cells(cells)
      case .separator:
        return .separator
      }
    }
  }

  private mutating func ensureCellRow(startingAt rowIndex: Int) -> Int {
    if rowIndex < 0 {
      return ensureCellRow(startingAt: 0)
    }

    var cursor = rowIndex
    while rows.indices.contains(cursor) {
      if rows[cursor].isCellRow {
        return cursor
      }
      cursor += 1
    }

    while rows.count <= rowIndex {
      addRow()
    }
    if rows[rowIndex].isCellRow {
      return rowIndex
    }

    rows.insert(.cells(Array(repeating: "", count: columnCount)), at: rowIndex)
    return rowIndex
  }

  public static func isTableLine(_ line: String) -> Bool {
    parseRow(line) != nil
  }

  private var normalizedRows: [OrgEditableTableRow] {
    rows.map { row in
      switch row {
      case .cells(var cells):
        while cells.count < columnCount {
          cells.append("")
        }
        return .cells(cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
      case .separator:
        return .separator
      }
    }
  }

  private var columnWidths: [Int] {
    let normalized = normalizedRows
    return (0..<columnCount).map { columnIndex in
      max(1, normalized.reduce(0) { width, row in
        switch row {
        case .cells(let cells):
          return max(width, cells[columnIndex].count)
        case .separator:
          return width
        }
      })
    }
  }

  private static func parseRows(_ rawText: String) -> [OrgEditableTableRow] {
    rawText
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .compactMap { parseRow(String($0)) }
  }

  private static func parseRow(_ line: String) -> OrgEditableTableRow? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("|") else { return nil }

    var inner = trimmed
    inner.removeFirst()
    if inner.last == "|" {
      inner.removeLast()
    }

    let separatorBody = inner.trimmingCharacters(in: .whitespaces)
    let isSeparator = !separatorBody.isEmpty && separatorBody.allSatisfy { $0 == "-" || $0 == "+" }
    if isSeparator {
      return .separator
    }

    let cells = inner
      .split(separator: "|", omittingEmptySubsequences: false)
      .map { String($0).trimmingCharacters(in: .whitespaces) }
    return .cells(cells.isEmpty ? [""] : cells)
  }

  private static func pastedGrid(from rawValue: String) -> [[String]]? {
    let normalized = rawValue
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .newlines)
    guard normalized.contains("\t") || normalized.contains("\n") else { return nil }

    let rows = normalized
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        line
          .split(separator: "\t", omittingEmptySubsequences: false)
          .map { String($0).trimmingCharacters(in: .whitespaces) }
      }
      .filter { !$0.isEmpty }

    guard rows.contains(where: { $0.count > 1 }) || rows.count > 1 else { return nil }
    return rows
  }

  private static func formatCells(_ cells: [String], widths: [Int]) -> String {
    let paddedCells = zip(cells, widths).map { cell, width in
      cell.padding(toLength: width, withPad: " ", startingAt: 0)
    }
    return "| \(paddedCells.joined(separator: " | ")) |"
  }

  private static func formatSeparator(widths: [Int]) -> String {
    "|" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "|"
  }
}

public enum OrgEditableTableRow: Equatable, Sendable {
  case cells([String])
  case separator

  fileprivate init(row: OrgTableRow) {
    switch row {
    case .cells(let cells):
      self = .cells(cells)
    case .separator:
      self = .separator
    }
  }

  fileprivate var isCellRow: Bool {
    if case .cells = self { return true }
    return false
  }
}

enum OrgRenderedTableViewMutation {
  static func replacement(
    rawText: String,
    visibleBodyRowIndices: [Int],
    expectedBodyRowCount: Int
  ) -> String? {
    guard expectedBodyRowCount > 0,
          !visibleBodyRowIndices.isEmpty,
          Set(visibleBodyRowIndices).count == visibleBodyRowIndices.count
    else {
      return nil
    }

    let normalized = rawText
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let table = OrgEditableTable(rawText: normalized)
    guard lines.count == table.rows.count else { return nil }

    let separatorIndex = table.rows.firstIndex(where: { !$0.isCellRow })
    let bodyStartIndex = separatorIndex.map { table.rows.index(after: $0) } ?? table.rows.startIndex
    let bodyLineIndices = table.rows.indices.filter { index in
      index >= bodyStartIndex && table.rows[index].isCellRow
    }
    guard bodyLineIndices.count == expectedBodyRowCount,
          visibleBodyRowIndices.allSatisfy({ bodyLineIndices.indices.contains($0) })
    else {
      return nil
    }

    let preservedPrefix = Array(lines[..<bodyStartIndex])
    let visibleRows = visibleBodyRowIndices.map { lines[bodyLineIndices[$0]] }
    return (preservedPrefix + visibleRows).joined(separator: "\n")
  }
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

      if isBeginExample(trimmed) {
        let parsed = collectBlock(lines: lines, startingAt: index + 1, endToken: "#+end_example")
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

      if OrgEditableTable.isTableLine(line) {
        let parsed = parseTable(lines: lines, startingAt: index)
        blocks.append(parsed.table)
        index = parsed.nextIndex
        continue
      }

      if isHorizontalRule(trimmed) {
        blocks.append(.horizontalRule)
        index += 1
        continue
      }

      if let listItem = parseListItem(line) {
        blocks.append(.listItem(
          indent: listItem.indent,
          marker: listItem.marker,
          checkbox: listItem.checkbox,
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

  public static func parseEditable(_ raw: String, baseLine: Int = 1) -> [OrgEditableBlock] {
    let lines = raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var blocks: [OrgEditableBlock] = []
    var index = 0

    func rawText(start: Int, end: Int) -> String {
      guard start < end, start < lines.count else { return "" }
      return lines[start..<min(end, lines.count)].joined(separator: "\n")
    }

    func append(start: Int, end: Int, rendered: OrgRenderedBlock) {
      blocks.append(OrgEditableBlock(
        startLine: baseLine + start,
        endLineExclusive: baseLine + end,
        rawText: rawText(start: start, end: end),
        rendered: rendered
      ))
    }

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      if trimmed.isEmpty {
        let start = index
        repeat {
          index += 1
        } while index < lines.count && lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        append(start: start, end: index, rendered: .blank)
        continue
      }

      if let heading = parseHeading(line) {
        append(start: index, end: index + 1, rendered: .heading(heading))
        index += 1
        continue
      }

      if let planning = parsePlanning(line) {
        append(start: index, end: index + 1, rendered: .planning(planning))
        index += 1
        continue
      }

      if trimmed.uppercased() == ":PROPERTIES:" {
        let parsed = parseProperties(lines: lines, startingAt: index)
        append(start: index, end: parsed.nextIndex, rendered: .properties(parsed.rows))
        index = parsed.nextIndex
        continue
      }

      if isBeginQuote(trimmed) {
        let parsed = collectBlock(lines: lines, startingAt: index + 1, endToken: "#+end_quote")
        append(start: index, end: parsed.nextIndex, rendered: .quote(parsed.lines.map(Org2Display.cleanInline)))
        index = parsed.nextIndex
        continue
      }

      if isBeginExample(trimmed) {
        let parsed = collectBlock(lines: lines, startingAt: index + 1, endToken: "#+end_example")
        append(start: index, end: parsed.nextIndex, rendered: .quote(parsed.lines.map(Org2Display.cleanInline)))
        index = parsed.nextIndex
        continue
      }

      if let sourceBlock = sourceBlock(from: trimmed) {
        let parsed = collectBlock(lines: lines, startingAt: index + 1, endToken: sourceBlock.endToken)
        append(start: index, end: parsed.nextIndex, rendered: .source(language: sourceBlock.language, lines: parsed.lines))
        index = parsed.nextIndex
        continue
      }

      if let keyword = parseKeyword(line) {
        append(start: index, end: index + 1, rendered: .keyword(key: keyword.key, value: Org2Display.cleanInline(keyword.value)))
        index += 1
        continue
      }

      if OrgEditableTable.isTableLine(line) {
        let parsed = parseTable(lines: lines, startingAt: index)
        append(start: index, end: parsed.nextIndex, rendered: parsed.table)
        index = parsed.nextIndex
        continue
      }

      if isHorizontalRule(trimmed) {
        append(start: index, end: index + 1, rendered: .horizontalRule)
        index += 1
        continue
      }

      if let listItem = parseListItem(line) {
        append(
          start: index,
          end: index + 1,
          rendered: .listItem(
            indent: listItem.indent,
            marker: listItem.marker,
            checkbox: listItem.checkbox,
            text: Org2Display.cleanInline(listItem.text)
          )
        )
        index += 1
        continue
      }

      let parsed = collectParagraph(lines: lines, startingAt: index)
      append(start: index, end: parsed.nextIndex, rendered: .paragraph(Org2Display.cleanInline(parsed.text)))
      index = parsed.nextIndex
    }

    return blocks
  }

  public static func parseEditable(
    _ raw: String,
    baseLine: Int = 1,
    canonicalDocument: Org2CanonicalDocument
  ) -> [OrgEditableBlock] {
    let lines = normalizedLines(raw)
    let sourceEndExclusive = baseLine + lines.count
    var canonicalBlocks: [OrgEditableBlock] = []
    var covered = Array(repeating: false, count: lines.count)

    func rawText(startLine: Int, endLineExclusive: Int) -> String {
      let start = max(0, startLine - baseLine)
      let end = max(start, min(lines.count, endLineExclusive - baseLine))
      guard start < end else { return "" }
      return lines[start..<end].joined(separator: "\n")
    }

    func markCovered(startLine: Int, endLineExclusive: Int) {
      let start = max(0, startLine - baseLine)
      let end = max(start, min(lines.count, endLineExclusive - baseLine))
      guard start < end else { return }
      for index in start..<end {
        covered[index] = true
      }
    }

    func appendBlock(startLine: Int, endLineExclusive: Int, rendered: OrgRenderedBlock) {
      guard rangesOverlap(
        startLine: startLine,
        endLineExclusive: endLineExclusive,
        sourceStartLine: baseLine,
        sourceEndLineExclusive: sourceEndExclusive
      ) else {
        return
      }

      let clampedStart = max(startLine, baseLine)
      let clampedEnd = min(endLineExclusive, sourceEndExclusive)
      guard clampedStart < clampedEnd else { return }
      canonicalBlocks.append(OrgEditableBlock(
        startLine: clampedStart,
        endLineExclusive: clampedEnd,
        rawText: rawText(startLine: clampedStart, endLineExclusive: clampedEnd),
        rendered: rendered
      ))
      markCovered(startLine: clampedStart, endLineExclusive: clampedEnd)
    }

    func appendNodes(_ nodes: [Org2CanonicalNode]) {
      for node in nodes {
        appendNode(node)
      }
    }

    func appendNode(_ node: Org2CanonicalNode) {
      switch node {
      case .headline(let headline):
        guard let sourceRange = headline.sourceRange else {
          appendNodes(headline.children)
          return
        }
        let lineText = rawText(startLine: sourceRange.startLine, endLineExclusive: sourceRange.startLine + 1)
        let heading = parseHeading(lineText) ?? OrgHeadingBlock(
          level: headline.level,
          todo: headline.todo,
          priority: nil,
          title: inlineText(headline.title),
          tags: headline.tags ?? []
        )
        appendBlock(startLine: sourceRange.startLine, endLineExclusive: sourceRange.startLine + 1, rendered: .heading(heading))
        appendNodes(headline.children)
      case .paragraph(let paragraph):
        guard let sourceRange = paragraph.sourceRange else { return }
        let raw = rawText(startLine: sourceRange.startLine, endLineExclusive: sourceRange.endLine + 1)
        if isHorizontalRule(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
          appendBlock(
            startLine: sourceRange.startLine,
            endLineExclusive: sourceRange.endLine + 1,
            rendered: .horizontalRule
          )
          return
        }
        appendBlock(
          startLine: sourceRange.startLine,
          endLineExclusive: sourceRange.endLine + 1,
          rendered: .paragraph(Org2Display.cleanInline(inlineText(paragraph.children)))
        )
      case .keywordLine(let keyword):
        guard let sourceRange = keyword.sourceRange else { return }
        appendBlock(
          startLine: sourceRange.startLine,
          endLineExclusive: sourceRange.endLine + 1,
          rendered: .keyword(key: keyword.keyRaw.uppercased(), value: Org2Display.cleanInline(keyword.valueRaw.trimmingCharacters(in: .whitespaces)))
        )
      case .planning(let planning):
        guard let sourceRange = planning.sourceRange else { return }
        let lineText = rawText(startLine: sourceRange.startLine, endLineExclusive: sourceRange.endLine + 1)
        let rendered = parsePlanning(lineText)
          ?? OrgPlanningBlock(kind: planning.kind, value: planning.raw)
        appendBlock(startLine: sourceRange.startLine, endLineExclusive: sourceRange.endLine + 1, rendered: .planning(rendered))
      case .propertyDrawer(let drawer):
        guard let sourceRange = drawer.sourceRange else { return }
        appendBlock(
          startLine: sourceRange.startLine,
          endLineExclusive: sourceRange.endLine + 1,
          rendered: .properties(drawer.properties.map { OrgPropertyRow(key: $0.key, value: Org2Display.cleanInline($0.value)) })
        )
      case .srcBlock(let block):
        guard let sourceRange = block.sourceRange else { return }
        let raw = rawText(startLine: sourceRange.startLine, endLineExclusive: sourceRange.endLine + 1)
        let trimmedFirstLine = raw
          .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
          .first
          .map(String.init)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased() ?? ""
        if isBeginQuote(trimmedFirstLine) || isBeginExample(trimmedFirstLine) {
          appendBlock(
            startLine: sourceRange.startLine,
            endLineExclusive: sourceRange.endLine + 1,
            rendered: .quote(blockLines(block.bodyRaw).map(Org2Display.cleanInline))
          )
          return
        }
        appendBlock(
          startLine: sourceRange.startLine,
          endLineExclusive: sourceRange.endLine + 1,
          rendered: .source(language: sourceLanguage(from: block.begin.afterKeywordRaw), lines: blockLines(block.bodyRaw))
        )
      case .block(let block):
        guard let sourceRange = block.sourceRange else { return }
        if ["quote", "example"].contains(block.kind.lowercased()) {
          appendBlock(
            startLine: sourceRange.startLine,
            endLineExclusive: sourceRange.endLine + 1,
            rendered: .quote(blockLines(block.bodyRaw).map(Org2Display.cleanInline))
          )
        }
      case .table(let table):
        guard let sourceRange = table.sourceRange else { return }
        appendBlock(
          startLine: sourceRange.startLine,
          endLineExclusive: sourceRange.endLine + 1,
          rendered: .table(OrgTableBlock(rows: table.rows.map(tableRow)))
        )
      case .unsupported:
        break
      }
    }

    appendNodes(canonicalDocument.children)
    canonicalBlocks.sort {
      if $0.startLine != $1.startLine { return $0.startLine < $1.startLine }
      return $0.endLineExclusive < $1.endLineExclusive
    }

    var output: [OrgEditableBlock] = []
    var canonicalIndex = 0
    var lineIndex = 0
    while lineIndex < lines.count {
      let absoluteLine = baseLine + lineIndex
      while canonicalIndex < canonicalBlocks.count,
            canonicalBlocks[canonicalIndex].startLine == absoluteLine {
        output.append(canonicalBlocks[canonicalIndex])
        lineIndex = max(lineIndex, canonicalBlocks[canonicalIndex].endLineExclusive - baseLine)
        canonicalIndex += 1
      }
      guard lineIndex < lines.count else { break }
      if covered[lineIndex] {
        lineIndex += 1
        continue
      }

      let start = lineIndex
      repeat {
        lineIndex += 1
      } while lineIndex < lines.count && !covered[lineIndex]
      let rawSlice = lines[start..<lineIndex].joined(separator: "\n")
      output.append(contentsOf: parseEditable(rawSlice, baseLine: baseLine + start))
    }

    while canonicalIndex < canonicalBlocks.count {
      output.append(canonicalBlocks[canonicalIndex])
      canonicalIndex += 1
    }

    let sortedOutput = output.sorted {
      if $0.startLine != $1.startLine { return $0.startLine < $1.startLine }
      return $0.endLineExclusive < $1.endLineExclusive
    }
    return coalescingPGPArmorBlocks(sortedOutput)
  }

  private static func coalescingPGPArmorBlocks(_ blocks: [OrgEditableBlock]) -> [OrgEditableBlock] {
    var output: [OrgEditableBlock] = []
    var index = 0
    while index < blocks.count {
      let block = blocks[index]
      guard startsPGPArmor(block.rawText) else {
        output.append(block)
        index += 1
        continue
      }

      var endIndex = index
      var rawParts: [String] = []
      var foundEnd = false
      while endIndex < blocks.count {
        let next = blocks[endIndex]
        rawParts.append(next.rawText)
        if endsPGPArmor(next.rawText) {
          foundEnd = true
          break
        }
        endIndex += 1
      }

      guard foundEnd else {
        output.append(block)
        index += 1
        continue
      }

      let raw = rawParts.joined(separator: "\n")
      let endLineExclusive = blocks[endIndex].endLineExclusive
      output.append(OrgEditableBlock(
        startLine: block.startLine,
        endLineExclusive: endLineExclusive,
        rawText: raw,
        rendered: .paragraph(Org2Display.cleanInline(raw))
      ))
      index = endIndex + 1
    }
    return output
  }

  private static func startsPGPArmor(_ rawText: String) -> Bool {
    rawText
      .split(separator: "\n", omittingEmptySubsequences: false)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines) == "-----BEGIN PGP MESSAGE-----"
  }

  private static func endsPGPArmor(_ rawText: String) -> Bool {
    rawText
      .split(separator: "\n", omittingEmptySubsequences: false)
      .last?
      .trimmingCharacters(in: .whitespacesAndNewlines) == "-----END PGP MESSAGE-----"
  }

  private static func normalizedLines(_ raw: String) -> [String] {
    raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }

  private static func rangesOverlap(
    startLine: Int,
    endLineExclusive: Int,
    sourceStartLine: Int,
    sourceEndLineExclusive: Int
  ) -> Bool {
    startLine < sourceEndLineExclusive && endLineExclusive > sourceStartLine
  }

  private static func inlineText(_ inlines: [Org2CanonicalInline]) -> String {
    inlines.map(inlineText).joined()
  }

  private static func inlineText(_ inline: Org2CanonicalInline) -> String {
    switch inline {
    case .text(let text):
      return text.value
    case .timestamp(let timestamp):
      return timestamp.raw
    case .timestampRange(let range):
      return "\(range.start.raw)\(range.separatorRaw)\(range.end.raw)"
    case .emphasis(let emphasis):
      return "\(emphasis.marker)\(emphasis.content)\(emphasis.marker)"
    case .link(let link):
      return link.descriptionRaw ?? link.targetRaw
    case .progressCookie(let raw):
      return raw
    case .unsupported(let type):
      return type
    }
  }

  private static func blockLines(_ raw: String) -> [String] {
    raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  private static func sourceLanguage(from afterKeywordRaw: String) -> String? {
    let parts = afterKeywordRaw
      .trimmingCharacters(in: .whitespaces)
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    return parts.first
  }

  private static func tableRow(_ row: Org2CanonicalTableRow) -> OrgTableRow {
    switch row {
    case .row(let row):
      return .cells(row.cells)
    case .hline:
      return .separator
    case .unsupported:
      return .separator
    }
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

  private static func isBeginExample(_ trimmed: String) -> Bool {
    trimmed.lowercased().hasPrefix("#+begin_example")
  }

  private static func sourceBlock(from trimmed: String) -> (language: String?, endToken: String)? {
    let lowercased = trimmed.lowercased()
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

  private static func parseTable(lines: [String], startingAt index: Int) -> (table: OrgRenderedBlock, nextIndex: Int) {
    var cursor = index
    var tableLines: [String] = []
    while cursor < lines.count, OrgEditableTable.isTableLine(lines[cursor]) {
      tableLines.append(lines[cursor])
      cursor += 1
    }
    let table = OrgEditableTable(rawText: tableLines.joined(separator: "\n"))
    return (.table(table.renderedBlock), cursor)
  }

  private static func isHorizontalRule(_ trimmed: String) -> Bool {
    trimmed.range(of: #"^-{5,}$"#, options: .regularExpression) != nil
  }

  private static func parseListItem(_ line: String) -> (indent: Int, marker: String, checkbox: OrgListCheckbox?, text: String)? {
    guard let range = line.range(of: #"^(\s*)([-+]|[0-9]+[.)])\s+(.*)$"#, options: .regularExpression) else {
      return nil
    }
    let matched = String(line[range])
    let leadingSpaces = matched.prefix { $0 == " " || $0 == "\t" }
    let rest = String(matched.dropFirst(leadingSpaces.count))
    guard let separator = rest.firstIndex(where: { $0.isWhitespace }) else { return nil }
    let marker = String(rest[..<separator])
    let rawText = String(rest[separator...]).trimmingCharacters(in: .whitespaces)
    let parsedCheckbox = parseListCheckbox(rawText)
    let text = parsedCheckbox.text
    return (leadingSpaces.count / 2, marker, parsedCheckbox.checkbox, text)
  }

  private static func parseListCheckbox(_ text: String) -> (checkbox: OrgListCheckbox?, text: String) {
    if text.hasPrefix("[ ] ") {
      return (.unchecked, String(text.dropFirst(4)))
    }
    if text.hasPrefix("[X] ") || text.hasPrefix("[x] ") {
      return (.checked, String(text.dropFirst(4)))
    }
    if text.hasPrefix("[-] ") {
      return (.mixed, String(text.dropFirst(4)))
    }
    return (nil, text)
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
      || OrgEditableTable.isTableLine(line)
      || isHorizontalRule(trimmed)
      || parseListItem(line) != nil
  }
}
