import AppKit
import SwiftUI

struct AIChatTableCell: Equatable {
  let tableID: UUID
  let row: Int
  let column: Int
  let isHeader: Bool
}

private struct AIChatTableCellKey: EnvironmentKey {
  static let defaultValue: AIChatTableCell? = nil
}

extension EnvironmentValues {
  var aiChatTableCell: AIChatTableCell? {
    get { self[AIChatTableCellKey.self] }
    set { self[AIChatTableCellKey.self] = newValue }
  }
}

enum AIChatRichClipboard {
  struct Fragment {
    let text: String
    let cell: AIChatTableCell?
    var messageID: UUID? = nil
  }

  static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "\n", with: "<br>")
  }

  static let tableOpen = "<table style=\"border-collapse:collapse;font-family:Arial,sans-serif;font-size:13px;color:#222\"><tbody>"

  static func cellHTML(_ text: String, header: Bool) -> String {
    let tag = header ? "th" : "td"
    return "<\(tag) style=\"border:1px solid #ccc;padding:6px 10px;text-align:left;vertical-align:top;\(header ? "background-color:#f0f0f0;font-weight:bold;" : "")\">\(escape(text))</\(tag)>"
  }

  static func document(_ body: String) -> String {
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
  }

  // Table identity and coordinates come from the rendered table, never from
  // guessing column boundaries using screen positions or selected ASCII text.
  static func selectionHTML(_ fragments: [Fragment]) -> String {
    var body = ""
    var tableID: UUID?
    var row: Int?
    var column = 0
    for fragment in fragments {
      if fragment.cell?.tableID != tableID {
        if tableID != nil { body += "</tr></tbody></table>" }
        tableID = fragment.cell?.tableID
        row = nil
        if tableID != nil { body += tableOpen }
      }
      if let cell = fragment.cell {
        if row != cell.row {
          if row != nil { body += "</tr>" }
          body += "<tr>"
          row = cell.row
          column = fragments.filter { $0.cell?.tableID == cell.tableID }.compactMap { $0.cell?.column }.min() ?? 0
        }
        while column < cell.column {
          body += cellHTML("", header: cell.isHeader)
          column += 1
        }
        column = cell.column + 1
        body += cellHTML(fragment.text, header: cell.isHeader)
      } else {
        body += "<div>\(escape(fragment.text))</div>"
      }
    }
    if tableID != nil { body += "</tr></tbody></table>" }
    return document(body)
  }

  static func alignedTable(_ rows: [OrgTableRow]) -> String {
    let cells = rows.compactMap { row -> [String]? in
      if case .cells(let cells) = row { return cells }; return nil
    }
    let count = cells.map(\.count).max() ?? 0
    guard count > 0 else { return "" }
    let widths = (0..<count).map { column in
      max(1, cells.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0)
    }
    return rows.map { row in
      switch row {
      case .separator:
        return "|" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "|"
      case .cells(let values):
        return "| " + widths.enumerated().map { column, width in
          let value = column < values.count ? values[column] : ""
          return value + String(repeating: " ", count: max(0, width - value.count))
        }.joined(separator: " | ") + " |"
      }
    }.joined(separator: "\n")
  }

  static func alignedMessage(_ text: String) -> String {
    let blocks = OrgEntryRenderer.parseEditable(text)
    guard blocks.contains(where: { if case .table = $0.rendered { return true }; return false }) else { return text }
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    var lines = text.components(separatedBy: newline)
    // Source ranges prevent an identical table inside a later code block from
    // being rewritten accidentally.
    for block in blocks.reversed() {
      guard case .table(let table) = block.rendered else { continue }
      lines.replaceSubrange((block.startLine - 1)..<(block.endLineExclusive - 1), with: alignedTable(table.rows).components(separatedBy: "\n"))
    }
    return lines.joined(separator: newline)
  }

  static func selectionText(_ fragments: [Fragment]) -> String {
    var output = ""
    var index = 0
    var previousMessage: UUID?
    while index < fragments.count {
      let fragment = fragments[index]
      if !output.isEmpty { output += previousMessage == fragment.messageID ? "\n" : "\n\n" }
      previousMessage = fragment.messageID
      guard let firstCell = fragment.cell else {
        output += fragment.text
        index += 1
        continue
      }
      var rows: [OrgTableRow] = []
      var row = firstCell.row
      var values: [String] = []
      var header = firstCell.isHeader
      let startColumn = fragments[index...].prefix { $0.cell?.tableID == firstCell.tableID }
        .compactMap { $0.cell?.column }.min() ?? 0
      func finishRow() {
        rows.append(.cells(values))
        if header { rows.append(.separator) }
        values = []
      }
      while index < fragments.count, let cell = fragments[index].cell, cell.tableID == firstCell.tableID {
        if cell.row != row {
          finishRow()
          row = cell.row
          header = cell.isHeader
        }
        while values.count < cell.column - startColumn { values.append("") }
        values.append(fragments[index].text.replacingOccurrences(of: "\n", with: " "))
        index += 1
      }
      finishRow()
      output += alignedTable(rows)
    }
    return output
  }

  static func messageHTML(_ text: String) -> String? {
    let blocks = OrgEntryRenderer.parseEditable(text)
    guard blocks.contains(where: { if case .table = $0.rendered { return true }; return false }) else { return nil }
    let body = blocks.map { block -> String in
      guard case .table(let table) = block.rendered else {
        return "<div>\(escape(block.rawText))</div>"
      }
      var html = tableOpen
      for (index, row) in table.rows.enumerated() {
        guard case .cells(let cells) = row else { continue }
        html += "<tr>" + cells.map { cellHTML($0, header: index == table.headerRowIndex) }.joined() + "</tr>"
      }
      return html + "</tbody></table>"
    }.joined()
    return document(body)
  }
}
