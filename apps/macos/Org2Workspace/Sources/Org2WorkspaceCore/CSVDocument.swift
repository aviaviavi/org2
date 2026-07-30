import AppKit
import SwiftUI

enum CSVDocumentError: LocalizedError, Equatable {
  case unterminatedQuotedField

  var errorDescription: String? {
    switch self {
    case .unterminatedQuotedField:
      return "A quoted field is missing its closing quote."
    }
  }
}

struct CSVDocument: Equatable, Sendable {
  private(set) var rows: [[String]]
  var hasTrailingNewline: Bool

  init(rows: [[String]] = [], hasTrailingNewline: Bool = false) {
    self.rows = rows
    self.hasTrailingNewline = hasTrailingNewline
  }

  init(parsing text: String) throws {
    guard !text.isEmpty else {
      self.init()
      return
    }

    let normalizedText = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var parsedRows: [[String]] = []
    var row: [String] = []
    var field = ""
    var isInsideQuotes = false
    var justEndedRow = false
    var index = normalizedText.startIndex

    func finishField() {
      row.append(field)
      field = ""
    }

    func finishRow() {
      finishField()
      parsedRows.append(row)
      row = []
      justEndedRow = true
    }

    while index < normalizedText.endIndex {
      let character = normalizedText[index]
      let nextIndex = normalizedText.index(after: index)

      if character == "\"" {
        if isInsideQuotes {
          if nextIndex < normalizedText.endIndex, normalizedText[nextIndex] == "\"" {
            field.append("\"")
            index = normalizedText.index(after: nextIndex)
            justEndedRow = false
            continue
          }
          isInsideQuotes = false
        } else if field.isEmpty {
          isInsideQuotes = true
        } else {
          field.append(character)
        }
        justEndedRow = false
        index = nextIndex
        continue
      }

      if !isInsideQuotes {
        if character == "," {
          finishField()
          justEndedRow = false
          index = nextIndex
          continue
        }
        if character == "\n" {
          finishRow()
          index = nextIndex
          continue
        }
      }

      field.append(character)
      justEndedRow = false
      index = nextIndex
    }

    guard !isInsideQuotes else {
      throw CSVDocumentError.unterminatedQuotedField
    }

    if !justEndedRow {
      finishField()
      parsedRows.append(row)
    }

    self.init(rows: parsedRows, hasTrailingNewline: justEndedRow)
  }

  var rowCount: Int {
    rows.count
  }

  var columnCount: Int {
    rows.map(\.count).max() ?? 0
  }

  func value(row: Int, column: Int) -> String {
    guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
    return rows[row][column]
  }

  mutating func setValue(_ value: String, row: Int, column: Int) {
    guard row >= 0, column >= 0 else { return }
    while rows.count <= row {
      rows.append(Array(repeating: "", count: max(1, columnCount)))
    }
    while rows[row].count <= column {
      rows[row].append("")
    }
    rows[row][column] = value
  }

  mutating func appendRow() {
    rows.append(Array(repeating: "", count: max(1, columnCount)))
  }

  mutating func appendColumn() {
    if rows.isEmpty {
      rows = [[""]]
      return
    }
    let existingColumnCount = columnCount
    for index in rows.indices {
      while rows[index].count < existingColumnCount {
        rows[index].append("")
      }
      rows[index].append("")
    }
  }

  mutating func removeRow(at index: Int) {
    guard rows.indices.contains(index) else { return }
    rows.remove(at: index)
  }

  mutating func removeColumn(at index: Int) {
    guard index >= 0 else { return }
    for rowIndex in rows.indices where rows[rowIndex].indices.contains(index) {
      rows[rowIndex].remove(at: index)
    }
  }

  func serialized() -> String {
    var text = rows
      .map { row in row.map(Self.serializeField).joined(separator: ",") }
      .joined(separator: "\n")
    if hasTrailingNewline, !rows.isEmpty {
      text.append("\n")
    }
    return text
  }

  private static func serializeField(_ field: String) -> String {
    guard field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")
    else {
      return field
    }
    return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
  }
}

private enum CSVEditorPresentation: String, CaseIterable, Identifiable {
  case table
  case raw

  var id: String { rawValue }

  var title: String {
    switch self {
    case .table: "Table"
    case .raw: "Raw"
    }
  }
}

struct CSVDocumentEditorView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let source: EntrySource

  @State private var document: CSVDocument
  @State private var rawText: String
  @State private var presentation: CSVEditorPresentation
  @State private var parseError: String?

  init(source: EntrySource) {
    self.source = source
    let parsed = try? CSVDocument(parsing: source.text)
    _document = State(initialValue: parsed ?? CSVDocument())
    _rawText = State(initialValue: source.text)
    _presentation = State(initialValue: parsed == nil ? .raw : .table)
    _parseError = State(initialValue: parsed == nil
      ? CSVDocumentError.unterminatedQuotedField.localizedDescription
      : nil)
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()

      if let parseError {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(parseError)
            .font(.callout)
          Spacer()
          Button("Try Table Again") {
            switchToTable()
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.08))
        Divider()
      }

      switch presentation {
      case .table:
        CSVTableEditor(document: $document, publish: publish)
      case .raw:
        OrgSyntaxTextEditor(
          text: rawTextBinding,
          monospaced: true,
          showsScrollers: true,
          textInset: NSSize(width: 14, height: 14),
          focusOnAppear: false,
          textPublishing: .immediate,
          liveHighlighting: false,
          incrementalHighlighting: false,
          concealsSyntax: false,
          orgWritingCommands: false,
          textChecking: .disabled,
          onSaveCommand: { context in
            rawText = context.text
            store.noteLiveFileEditorTextChanged(context.text)
            Task { await store.saveLiveFileEditor(explicit: true) }
            return true
          }
        )
      }
    }
    .background(WorkspaceDesign.surfaceBackground)
    .onChange(of: source.text) { _, newText in
      guard newText != rawText,
            store.editableEntryText == newText
      else {
        return
      }
      rawText = newText
      if let parsed = try? CSVDocument(parsing: newText) {
        document = parsed
        parseError = nil
      }
    }
    .onChange(of: store.editableEntryText) { _, newText in
      guard newText != rawText else { return }
      rawText = newText
      if let parsed = try? CSVDocument(parsing: newText) {
        document = parsed
        parseError = nil
      }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Picker("CSV View", selection: presentationBinding) {
        ForEach(CSVEditorPresentation.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()

      Text("\(document.rowCount) rows · \(document.columnCount) columns")
        .font(.caption.monospacedDigit())
        .foregroundStyle(WorkspaceDesign.secondaryText)

      Spacer()

      if presentation == .table {
        Button {
          mutateDocument { $0.appendRow() }
        } label: {
          Label("Add Row", systemImage: "plus")
        }
        .help("Add row")

        Button {
          mutateDocument { $0.appendColumn() }
        } label: {
          Label("Add Column", systemImage: "rectangle.split.3x1")
        }
        .help("Add column")
      }
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  private var presentationBinding: Binding<CSVEditorPresentation> {
    Binding(
      get: { presentation },
      set: { next in
        if next == .table {
          switchToTable()
        } else {
          presentation = .raw
        }
      }
    )
  }

  private var rawTextBinding: Binding<String> {
    Binding(
      get: { rawText },
      set: { text in
        rawText = text
        store.noteLiveFileEditorTextChanged(text)
      }
    )
  }

  private func switchToTable() {
    do {
      document = try CSVDocument(parsing: rawText)
      parseError = nil
      presentation = .table
    } catch {
      parseError = error.localizedDescription
      presentation = .raw
    }
  }

  private func mutateDocument(_ mutation: (inout CSVDocument) -> Void) {
    var updated = document
    mutation(&updated)
    document = updated
    publish(updated)
  }

  private func publish(_ updated: CSVDocument) {
    let text = updated.serialized()
    rawText = text
    parseError = nil
    store.noteLiveFileEditorTextChanged(text)
  }
}

private struct CSVTableEditor: View {
  @Binding var document: CSVDocument
  let publish: (CSVDocument) -> Void

  private let rowNumberWidth: CGFloat = 48
  private let cellWidth: CGFloat = 180
  private let rowHeight: CGFloat = 34

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
        Section {
          ForEach(0..<max(1, document.rowCount), id: \.self) { row in
            dataRow(row)
          }
        } header: {
          columnHeader
        }
      }
    }
    .background(WorkspaceDesign.surfaceBackground)
  }

  private var columnHeader: some View {
    HStack(spacing: 0) {
      Color.clear
        .frame(width: rowNumberWidth, height: rowHeight)
        .background(WorkspaceDesign.barBackground)
        .overlay(alignment: .trailing) {
          Divider()
        }

      ForEach(0..<max(1, document.columnCount), id: \.self) { column in
        Menu {
          Button("Delete Column", role: .destructive) {
            mutate { $0.removeColumn(at: column) }
          }
          .disabled(document.columnCount == 0)
        } label: {
          Text(Self.columnName(column))
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(WorkspaceDesign.secondaryText)
            .frame(width: cellWidth, height: rowHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .background(WorkspaceDesign.barBackground)
        .overlay(alignment: .trailing) {
          Divider()
        }
      }
    }
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func dataRow(_ row: Int) -> some View {
    HStack(spacing: 0) {
      Menu {
        Button("Delete Row", role: .destructive) {
          mutate { $0.removeRow(at: row) }
        }
        .disabled(!document.rows.indices.contains(row))
      } label: {
        Text("\(row + 1)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(WorkspaceDesign.tertiaryText)
          .frame(width: rowNumberWidth, height: rowHeight)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .background(WorkspaceDesign.barBackground)
      .overlay(alignment: .trailing) {
        Divider()
      }

      ForEach(0..<max(1, document.columnCount), id: \.self) { column in
        TextField("", text: cellBinding(row: row, column: column))
          .textFieldStyle(.plain)
          .accessibilityLabel("Row \(row + 1), column \(Self.columnName(column))")
          .font(.system(
            size: 12,
            weight: row == 0 ? .semibold : .regular,
            design: .monospaced
          ))
          .padding(.horizontal, 9)
          .frame(width: cellWidth, height: rowHeight)
          .background(row == 0 ? WorkspaceDesign.subtleFill : Color.clear)
          .overlay(alignment: .trailing) {
            Divider()
          }
      }
    }
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func cellBinding(row: Int, column: Int) -> Binding<String> {
    Binding(
      get: { document.value(row: row, column: column) },
      set: { value in
        var updated = document
        updated.setValue(value, row: row, column: column)
        document = updated
        publish(updated)
      }
    )
  }

  private func mutate(_ mutation: (inout CSVDocument) -> Void) {
    var updated = document
    mutation(&updated)
    document = updated
    publish(updated)
  }

  private static func columnName(_ index: Int) -> String {
    var number = index + 1
    var name = ""
    while number > 0 {
      number -= 1
      name.insert(Character(UnicodeScalar(65 + (number % 26))!), at: name.startIndex)
      number /= 26
    }
    return name
  }
}
