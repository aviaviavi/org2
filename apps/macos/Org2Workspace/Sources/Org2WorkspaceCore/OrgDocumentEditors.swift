import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InlineBlockEditorView: View {
  let block: OrgEditableBlock

  var body: some View {
    switch block.rendered {
    case .heading(let heading):
      HeadingBlockEditor(block: block, heading: heading)
    case .planning(let planning):
      PlanningBlockEditor(block: block, planning: planning)
    case .quote:
      QuoteBlockEditor(block: block)
    case .listItem(let indent, let marker, let checkbox, let text):
      ListItemBlockEditor(block: block, indent: indent, marker: marker, checkbox: checkbox, text: text)
    case .keyword(let key, let value):
      KeywordBlockEditor(block: block, key: key, value: value)
    case .paragraph(let text):
      ParagraphBlockEditor(block: block, text: text)
    case .properties(let rows):
      PropertyDrawerBlockEditor(block: block, rows: rows)
    case .source(let language, let lines):
      SourceBlockEditor(block: block, language: language, lines: lines)
    case .table(let table):
      TableBlockEditor(block: block, table: table)
    case .horizontalRule:
      HorizontalRuleBlockEditor(block: block)
    case .blank:
      EmptyView()
    }
  }
}

private struct HorizontalRuleBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock

  var body: some View {
    HStack(spacing: 10) {
      Label("Divider", systemImage: "minus")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

      Rectangle()
        .fill(Color.secondary.opacity(0.26))
        .frame(height: 1)
        .frame(maxWidth: .infinity)

      if store.isSavingBlock {
        ProgressView()
          .controlSize(.small)
      }

      Button {
        saveDivider()
      } label: {
        Image(systemName: "checkmark")
      }
      .buttonStyle(.borderless)
      .keyboardShortcut("s", modifiers: [.command])
      .disabled(store.isSavingBlock)
      .help("Save")

      Button {
        store.cancelEditingBlock()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .keyboardShortcut(.cancelAction)
      .disabled(store.isSavingBlock)
      .help("Cancel")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.accentColor.opacity(0.2))
    )
  }

  private func saveDivider() {
    store.editableBlockText = "-----"
    Task { await store.saveEditedBlock(block) }
  }
}

private struct HeadingBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  private let level: Int
  @State private var todo: String
  @State private var priority: String
  @State private var title: String
  @State private var tags: String
  @State private var showsDetails = false
  @State private var isHovered = false
  @FocusState private var titleFocused: Bool

  init(block: OrgEditableBlock, heading: OrgHeadingBlock) {
    self.block = block
    let raw = Self.rawHeadingParts(from: block.rawText, fallback: heading)
    self.level = raw.level
    _todo = State(initialValue: raw.todo)
    _priority = State(initialValue: raw.priority)
    _title = State(initialValue: raw.title)
    _tags = State(initialValue: raw.tags)
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Menu {
            Button("None") {
              todo = ""
            }
            Divider()
            ForEach(Self.todoKeywords, id: \.self) { keyword in
              Button(keyword) {
                todo = keyword
              }
            }
          } label: {
            if todo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Image(systemName: "circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            } else {
              StatusPill(text: todo)
            }
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Status")

          Menu {
            Button("None") {
              priority = ""
            }
            Divider()
            ForEach(["A", "B", "C"], id: \.self) { value in
              Button("[#\(value)]") {
                priority = value
              }
            }
          } label: {
            if priority.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Image(systemName: "flag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            } else {
              Label("[#\(priority.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())]", systemImage: "flag.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
            }
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Priority")

          TextField("Untitled", text: $title)
            .textFieldStyle(.plain)
            .font(headingFont)
            .focused($titleFocused)
            .onSubmit {
              saveHeading()
            }

          Spacer(minLength: 0)
        }
        .padding(.trailing, 78)

        if showsDetails || !tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          HStack(spacing: 8) {
            Text("H\(level)")
              .font(.caption.monospacedDigit().weight(.medium))
              .foregroundStyle(.secondary)
            Image(systemName: "tag")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            TextField("tags", text: $tags)
              .textFieldStyle(.plain)
              .font(.caption)
              .onSubmit {
                saveHeading()
              }
          }
          .padding(.leading, metadataIndent)
          .padding(.trailing, 78)
        }
      }
      .padding(.leading, editorIndent)

      HStack(spacing: 4) {
        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }
        Button {
          showsDetails.toggle()
        } label: {
          Image(systemName: showsDetails ? "slider.horizontal.3" : "slider.horizontal.2.square")
        }
        .buttonStyle(.borderless)
        .help(showsDetails ? "Hide heading details" : "Show heading details")

        Button {
          saveHeading()
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(store.isSavingBlock)
        .help("Save")

        Button {
          store.cancelEditingBlock()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSavingBlock)
        .help("Cancel")
      }
      .controlSize(.small)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(.regularMaterial, in: Capsule())
      .opacity(isHovered || showsDetails || store.isSavingBlock ? 1 : 0.66)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(Color.accentColor.opacity(isHovered ? 0.04 : 0.02), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.accentColor.opacity(isHovered ? 0.18 : 0.1))
    )
    .onHover { isHovered = $0 }
    .onAppear {
      titleFocused = true
    }
  }

  private var rawHeading: String {
    var parts = [String(repeating: "*", count: max(1, level))]
    let normalizedTodo = todo.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if !normalizedTodo.isEmpty {
      parts.append(normalizedTodo)
    }
    let normalizedPriority = priority.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if !normalizedPriority.isEmpty {
      parts.append("[#\(normalizedPriority)]")
    }
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedTitle.isEmpty {
      parts.append(normalizedTitle)
    }
    var line = parts.joined(separator: " ")
    let normalizedTags = tags
      .split { $0.isWhitespace || $0 == "," }
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#:")) }
      .filter { !$0.isEmpty }
    if !normalizedTags.isEmpty {
      line += " :\(normalizedTags.joined(separator: ":")):"
    }
    return line
  }

  private func saveHeading() {
    store.editableBlockText = rawHeading
    Task { await store.saveEditedBlock(block) }
  }

  private var headingFont: Font {
    switch level {
    case 1:
      return .title3.weight(.semibold)
    case 2:
      return .headline.weight(.semibold)
    case 3:
      return .callout.weight(.semibold)
    default:
      return .body.weight(.semibold)
    }
  }

  private var editorIndent: CGFloat {
    CGFloat(max(0, level - 1)) * 14
  }

  private var metadataIndent: CGFloat {
    todo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 3
  }

  private static let todoKeywords = ["TODO", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED"]

  private static func rawHeadingParts(
    from rawText: String,
    fallback: OrgHeadingBlock
  ) -> (level: Int, todo: String, priority: String, title: String, tags: String) {
    let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else {
      return (
        fallback.level,
        fallback.todo ?? "",
        fallback.priority ?? "",
        fallback.title,
        fallback.tags.joined(separator: " ")
      )
    }

    var rest = String(line.dropFirst(stars.count)).trimmingCharacters(in: .whitespaces)
    var tags = fallback.tags.joined(separator: " ")
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      tags = String(rest[tagRange])
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ":")
        .map(String.init)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    var todo = ""
    var priority = ""
    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
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

    return (
      stars.count,
      todo,
      priority,
      tokens.joined(separator: " "),
      tags
    )
  }
}

private struct PlanningBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @State private var kind: String
  @State private var value: String
  @State private var isHovered = false
  @FocusState private var valueFocused: Bool

  init(block: OrgEditableBlock, planning: OrgPlanningBlock) {
    self.block = block
    _kind = State(initialValue: planning.kind)
    _value = State(initialValue: planning.value)
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Menu {
          ForEach(Self.planningKinds, id: \.self) { value in
            Button(value.capitalized) {
              kind = value
            }
          }
        } label: {
          Text(kind.capitalized)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 78, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Planning kind")

        TextField("<yyyy-mm-dd>", text: $value)
          .textFieldStyle(.plain)
          .font(.callout.monospacedDigit())
          .focused($valueFocused)
          .onSubmit {
            savePlanning()
          }

        Spacer(minLength: 0)
      }
      .padding(.trailing, 74)

      HStack(spacing: 4) {
        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          savePlanning()
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(store.isSavingBlock)
        .help("Save")

        Button {
          store.cancelEditingBlock()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSavingBlock)
        .help("Cancel")
      }
      .controlSize(.small)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(.regularMaterial, in: Capsule())
      .opacity(isHovered || store.isSavingBlock ? 1 : 0.66)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(Color.accentColor.opacity(isHovered ? 0.035 : 0.018), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.accentColor.opacity(isHovered ? 0.18 : 0.1))
    )
    .onHover { isHovered = $0 }
    .onAppear {
      valueFocused = true
    }
  }

  private var rawPlanning: String {
    "\(kind): \(value.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private func savePlanning() {
    store.editableBlockText = rawPlanning
    Task { await store.saveEditedBlock(block) }
  }

  private static let planningKinds = ["SCHEDULED", "DEADLINE", "CLOSED"]
}

private struct ListItemBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  let leadingWhitespace: String
  @State private var marker: String
  @State private var checkbox: OrgListCheckbox?
  @State private var text: String
  @State private var isHovered = false
  @FocusState private var textFocused: Bool

  init(block: OrgEditableBlock, indent: Int, marker: String, checkbox: OrgListCheckbox?, text: String) {
    self.block = block
    let raw = Self.rawListItemParts(
      from: block.rawText,
      fallbackIndent: indent,
      fallbackMarker: marker,
      fallbackCheckbox: checkbox,
      fallbackText: text
    )
    self.leadingWhitespace = raw.leadingWhitespace
    _marker = State(initialValue: raw.marker)
    _checkbox = State(initialValue: raw.checkbox)
    _text = State(initialValue: raw.text)
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Menu {
          ForEach(Self.markerChoices, id: \.self) { value in
            Button(value) {
              marker = value
            }
          }
          Divider()
          Button(checkbox == nil ? "Add Checkbox" : "Remove Checkbox") {
            checkbox = checkbox == nil ? .unchecked : nil
          }
        } label: {
          Text(markerLabel)
            .font(.callout.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("List marker")

        if let checkbox {
          Button {
            self.checkbox = checkbox == .checked ? .unchecked : .checked
          } label: {
            Image(systemName: checkboxSystemImage(checkbox))
              .font(.callout.weight(.medium))
              .foregroundStyle(checkbox == .checked ? Color.accentColor : Color.secondary)
          }
          .buttonStyle(.plain)
          .help(checkbox == .checked ? "Mark incomplete" : "Mark complete")
        }

        TextField("List item", text: $text)
          .textFieldStyle(.plain)
          .focused($textFocused)
          .strikethrough(checkbox == .checked)
          .foregroundStyle(checkbox == .checked ? .secondary : .primary)
          .onSubmit {
            continueListItem()
          }

        Spacer(minLength: 0)
      }
      .padding(.leading, editorIndent)
      .padding(.trailing, 74)

      HStack(spacing: 4) {
        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          saveListItem()
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(store.isSavingBlock)
        .help("Save")

        Button {
          store.cancelEditingBlock()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSavingBlock)
        .help("Cancel")
      }
      .controlSize(.small)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(.regularMaterial, in: Capsule())
      .opacity(isHovered || store.isSavingBlock ? 1 : 0.66)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(Color.accentColor.opacity(isHovered ? 0.035 : 0.018), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.accentColor.opacity(isHovered ? 0.18 : 0.1))
    )
    .onHover { isHovered = $0 }
    .onAppear {
      textFocused = true
    }
  }

  private var rawListItem: String {
    let markerValue = marker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "-"
      : marker.trimmingCharacters(in: .whitespacesAndNewlines)
    let checkboxPrefix = checkbox.map { "\($0.rawMarker) " } ?? ""
    return "\(leadingWhitespace)\(markerValue) \(checkboxPrefix)\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private var checkboxEnabledBinding: Binding<Bool> {
    Binding(
      get: { checkbox != nil },
      set: { checkbox = $0 ? .unchecked : nil }
    )
  }

  private var checkboxCheckedBinding: Binding<Bool> {
    Binding(
      get: { checkbox == .checked },
      set: { checkbox = $0 ? .checked : .unchecked }
    )
  }

  private var markerLabel: String {
    let normalized = marker.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized == "-" { return "•" }
    return normalized.isEmpty ? "•" : normalized
  }

  private var editorIndent: CGFloat {
    CGFloat(leadingWhitespace.count) * 4
  }

  private func saveListItem() {
    store.editableBlockText = rawListItem
    Task { await store.saveEditedBlock(block) }
  }

  private func continueListItem() {
    store.editableBlockText = rawListItem
    Task { await store.splitEditingBlock(block, atUTF16Offset: (rawListItem as NSString).length) }
  }

  private func checkboxSystemImage(_ checkbox: OrgListCheckbox) -> String {
    switch checkbox {
    case .checked:
      return "checkmark.square.fill"
    case .mixed:
      return "minus.square.fill"
    case .unchecked:
      return "square"
    }
  }

  private static let markerChoices = ["-", "+", "1.", "1)"]

  private static func rawListItemParts(
    from rawText: String,
    fallbackIndent: Int,
    fallbackMarker: String,
    fallbackCheckbox: OrgListCheckbox?,
    fallbackText: String
  ) -> (leadingWhitespace: String, marker: String, checkbox: OrgListCheckbox?, text: String) {
    let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let leadingWhitespace = String(line.prefix { $0 == " " || $0 == "\t" })
    let rest = String(line.dropFirst(leadingWhitespace.count))
    guard let separator = rest.firstIndex(where: { $0.isWhitespace }) else {
      return (String(repeating: " ", count: max(0, fallbackIndent) * 2), fallbackMarker, fallbackCheckbox, fallbackText)
    }
    let marker = String(rest[..<separator])
    let textStart = rest[separator...].firstIndex { !$0.isWhitespace } ?? rest.endIndex
    let parsed = Self.parseCheckbox(String(rest[textStart...]))
    return (leadingWhitespace, marker, parsed.checkbox ?? fallbackCheckbox, parsed.text)
  }

  private static func parseCheckbox(_ text: String) -> (checkbox: OrgListCheckbox?, text: String) {
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
}

private struct KeywordBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @State private var key: String
  @State private var value: String
  @State private var isHovered = false
  @FocusState private var valueFocused: Bool

  init(block: OrgEditableBlock, key: String, value: String) {
    self.block = block
    let raw = Self.rawKeywordParts(from: block.rawText, fallbackKey: key, fallbackValue: value)
    _key = State(initialValue: raw.key)
    _value = State(initialValue: raw.value)
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        HStack(spacing: 0) {
          Text("#+")
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(.tertiary)

          TextField("KEYWORD", text: $key)
            .textFieldStyle(.plain)
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(.secondary)
            .onSubmit {
              valueFocused = true
            }
        }
        .frame(width: 78, alignment: .leading)

        TextField("Value", text: $value)
          .textFieldStyle(.plain)
          .focused($valueFocused)
          .onSubmit {
            saveKeyword()
          }

        Spacer(minLength: 0)
      }
      .padding(.trailing, 74)

      HStack(spacing: 4) {
        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          saveKeyword()
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(store.isSavingBlock)
        .help("Save")

        Button {
          store.cancelEditingBlock()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSavingBlock)
        .help("Cancel")
      }
      .controlSize(.small)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(.regularMaterial, in: Capsule())
      .opacity(isHovered || store.isSavingBlock ? 1 : 0.66)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(Color.accentColor.opacity(isHovered ? 0.035 : 0.018), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.accentColor.opacity(isHovered ? 0.18 : 0.1))
    )
    .onHover { isHovered = $0 }
    .onAppear {
      valueFocused = true
    }
  }

  private var rawKeyword: String {
    let normalizedKey = key.trimmingCharacters(in: CharacterSet(charactersIn: "#+: \n\t")).uppercased()
    return "#+\(normalizedKey.isEmpty ? "KEYWORD" : normalizedKey): \(value.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private func saveKeyword() {
    store.editableBlockText = rawKeyword
    Task { await store.saveEditedBlock(block) }
  }

  private static func rawKeywordParts(
    from rawText: String,
    fallbackKey: String,
    fallbackValue: String
  ) -> (key: String, value: String) {
    let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("#+"),
          let separator = trimmed.firstIndex(of: ":")
    else {
      return (fallbackKey, fallbackValue)
    }
    let keyStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
    let key = String(trimmed[keyStart..<separator])
    let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    return (key, value)
  }
}

private struct PropertyDrawerBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @State private var drawer: OrgEditablePropertyDrawer
  @FocusState private var focusedProperty: PropertyFocus?

  private enum PropertyFocus: Hashable {
    case key(Int)
    case value(Int)
  }

  init(block: OrgEditableBlock, rows: [OrgPropertyRow]) {
    self.block = block
    _drawer = State(initialValue: OrgEditablePropertyDrawer(rawText: block.rawText, fallbackRows: rows))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Label("Properties", systemImage: "tag")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)

        Button {
          drawer.addProperty()
          focusedProperty = .key(max(0, drawer.rows.count - 1))
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Add property")

        Text("line \(block.displayRange)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)

        Spacer(minLength: 0)

        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          saveProperties()
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(store.isSavingBlock)
        .help("Save")

        Button {
          store.cancelEditingBlock()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSavingBlock)
        .help("Cancel")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color.secondary.opacity(0.07))

      if drawer.rows.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "tag")
            .foregroundStyle(.secondary)
          Text("No properties")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(10)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(drawer.rows.enumerated()), id: \.offset) { index, row in
            propertyRow(index: index, row: row)
            if index < drawer.rows.count - 1 {
              Divider()
            }
          }
        }
        .background(Color(nsColor: .textBackgroundColor))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.accentColor.opacity(0.24))
    )
    .onAppear {
      if focusedProperty == nil, !drawer.rows.isEmpty {
        focusedProperty = .value(0)
      }
    }
  }

  private func propertyRow(index: Int, row: OrgEditablePropertyRow) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(":")
        .font(.caption.monospaced().weight(.medium))
        .foregroundStyle(.tertiary)

      TextField("Key", text: propertyKeyBinding(index))
        .textFieldStyle(.plain)
        .font(.callout.monospaced().weight(.medium))
        .foregroundStyle(.secondary)
        .frame(width: 150)
        .focused($focusedProperty, equals: .key(index))
        .onSubmit {
          focusedProperty = .value(index)
        }

      TextField("Value", text: propertyValueBinding(index))
        .textFieldStyle(.plain)
        .font(.callout)
        .focused($focusedProperty, equals: .value(index))
        .onSubmit {
          saveProperties()
        }

      Text(":")
        .font(.caption.monospaced().weight(.medium))
        .foregroundStyle(.tertiary)

      Button {
        drawer.removeProperty(at: index)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help("Delete \(row.normalizedKey.isEmpty ? "property" : row.normalizedKey)")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(rowBackground(index))
  }

  private func rowBackground(_ index: Int) -> Color {
    index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.035)
  }

  private func propertyKeyBinding(_ index: Int) -> Binding<String> {
    Binding(
      get: {
        guard drawer.rows.indices.contains(index) else { return "" }
        return drawer.rows[index].key
      },
      set: { drawer.setKey(at: index, value: $0) }
    )
  }

  private func propertyValueBinding(_ index: Int) -> Binding<String> {
    Binding(
      get: {
        guard drawer.rows.indices.contains(index) else { return "" }
        return drawer.rows[index].value
      },
      set: { drawer.setValue(at: index, value: $0) }
    )
  }

  private func saveProperties() {
    store.editableBlockText = drawer.formattedRawText
    Task { await store.saveEditedBlock(block) }
  }
}

private struct ParagraphBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  let text: String
  @State private var draftText: String
  @State private var selectedRange = NSRange(location: 0, length: 0)
  @State private var showsInlineDetails = false
  @State private var isHovered = false

  init(block: OrgEditableBlock, text: String) {
    self.block = block
    self.text = text
    _draftText = State(initialValue: block.rawText)
  }

  var body: some View {
    if let media = OrgEditableMediaLink(rawText: block.rawText) {
      MediaBlockEditor(block: block, media: media)
    } else {
      paragraphEditorContent
    }
  }

  private var paragraphEditorContent: some View {
    ZStack(alignment: .topTrailing) {
      VStack(alignment: .leading, spacing: 5) {
        OrgSyntaxTextEditor(
          text: $draftText,
          showsScrollers: false,
          textInset: NSSize(width: 0, height: 2),
          focusOnAppear: true,
          selection: $selectedRange,
          onSubmitContext: submitParagraph
        )
        .frame(minHeight: editorHeight, maxHeight: editorHeight)
        .padding(.trailing, 74)

        if selectedRange.length > 0 {
          ParagraphInlineFormatBar(text: $draftText, selectedRange: $selectedRange)
        }

        if !slashCommandKinds.isEmpty {
          HStack(spacing: 8) {
            Text("Turn into")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)

            ForEach(slashCommandKinds) { kind in
              Button {
                convertParagraph(to: kind)
              } label: {
                Label("/\(kind.slashCommand)", systemImage: kind.systemImage)
              }
              .buttonStyle(.borderless)
              .controlSize(.small)
              .help("Convert to \(kind.title)")
            }
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 4)
          .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }

        if showsInlineDetails {
          VStack(alignment: .leading, spacing: 6) {
            ParagraphInlineMarkupEditor(text: $draftText)
            ParagraphInlineLinkEditor(text: $draftText)
            ParagraphInlineTimestampEditor(text: $draftText)
          }
        }
      }

      HStack(spacing: 4) {
        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }
        Button {
          showsInlineDetails.toggle()
        } label: {
          Image(systemName: showsInlineDetails ? "slider.horizontal.3" : "slider.horizontal.2.square")
        }
        .buttonStyle(.borderless)
        .help(showsInlineDetails ? "Hide inline details" : "Show inline details")

        Button {
          saveParagraph()
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command])
        .help("Save")
        .disabled(store.isSavingBlock)

        Button {
          store.cancelEditingBlock()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .help("Cancel")
        .disabled(store.isSavingBlock)
      }
      .controlSize(.small)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(.regularMaterial, in: Capsule())
      .opacity(isHovered || selectedRange.length > 0 || showsInlineDetails || store.isSavingBlock ? 1 : 0.66)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(Color.accentColor.opacity(isHovered ? 0.035 : 0.018), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.accentColor.opacity(isHovered ? 0.18 : 0.1))
    )
    .onHover { isHovered = $0 }
  }

  private var editorHeight: CGFloat {
    let lineCount = max(1, draftText.split(separator: "\n", omittingEmptySubsequences: false).count)
    return min(320, max(30, CGFloat(lineCount) * 21 + 8))
  }

  private var slashCommandKinds: [OrgInsertBlockKind] {
    guard let query = slashCommandQuery else { return [] }
    return OrgInsertBlockKind.allCases.filter { kind in
      query.isEmpty
        || kind.slashCommand.localizedCaseInsensitiveContains(query)
        || kind.title.localizedCaseInsensitiveContains(query)
    }
  }

  private var primarySlashCommandKind: OrgInsertBlockKind? {
    guard let query = slashCommandQuery,
          !query.isEmpty
    else {
      return nil
    }
    return slashCommandKinds.first
  }

  private var slashCommandQuery: String? {
    let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }

    let command = trimmed
      .dropFirst()
      .prefix { !$0.isWhitespace }
    return String(command)
  }

  private func submitParagraph(_ context: OrgSyntaxTextEditorSubmitContext) -> Bool {
    draftText = context.text
    if let kind = primarySlashCommandKind {
      convertParagraph(to: kind)
      return true
    }

    store.editableBlockText = context.text
    Task { await store.splitEditingBlock(block, atUTF16Offset: context.selectedRange.location) }
    return true
  }

  private func saveParagraph() {
    store.editableBlockText = draftText
    Task { await store.saveEditedBlock(block) }
  }

  private func convertParagraph(to kind: OrgInsertBlockKind) {
    store.editableBlockText = draftText
    Task { await store.convertEditingBlock(block, to: kind) }
  }
}

private struct MediaBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @State private var media: OrgEditableMediaLink
  @FocusState private var targetFocused: Bool

  init(block: OrgEditableBlock, media: OrgEditableMediaLink) {
    self.block = block
    _media = State(initialValue: media)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label(title, systemImage: systemImage)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)

        Picker("Kind", selection: mediaKindBinding) {
          ForEach(OrgMediaAttachment.Kind.allCases, id: \.self) { kind in
            Label(kind.editorTitle, systemImage: kind.editorSystemImage)
              .tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 148)
        .help("Media kind")

        Text("line \(block.displayRange)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)

        Spacer(minLength: 0)

        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          chooseFile()
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .disabled(store.isSavingBlock)
        .help("Choose file")

        Button {
          saveMedia()
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(store.isSavingBlock)
        .help("Save")

        Button {
          store.cancelEditingBlock()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSavingBlock)
        .help("Cancel")
      }

      RenderedBlockView(
        block: .paragraph(media.formattedRawText),
        rawText: media.formattedRawText,
        editableBlock: block,
        sourceFile: store.selectedEntrySource?.file,
        corpusRoot: store.corpusRoot
      )
      .padding(.vertical, 2)

      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
        GridRow {
          Text("File")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextField("path/to/file", text: targetBinding)
            .textFieldStyle(.roundedBorder)
            .focused($targetFocused)
            .onSubmit {
              saveMedia()
            }
        }

        GridRow {
          Text("Caption")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextField("caption", text: $media.label)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              saveMedia()
            }
        }
      }
      .frame(maxWidth: 620, alignment: .leading)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.accentColor.opacity(0.2))
    )
    .onAppear {
      targetFocused = true
    }
  }

  private var title: String {
    media.kind == .image ? "Image" : "Video"
  }

  private var systemImage: String {
    media.kind == .image ? "photo" : "film"
  }

  private var mediaKindBinding: Binding<OrgMediaAttachment.Kind> {
    Binding(
      get: { media.kind },
      set: { media.kind = $0 }
    )
  }

  private var targetBinding: Binding<String> {
    Binding(
      get: { media.target },
      set: { newTarget in
        media.target = newTarget
        inferKindFromTarget(newTarget)
      }
    )
  }

  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = allowedContentTypes

    guard panel.runModal() == .OK, let url = panel.url else { return }
    media.target = relativeTarget(for: url)
    inferKindFromTarget(url.path)
    if media.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      media.label = url.deletingPathExtension().lastPathComponent
    }
  }

  private var allowedContentTypes: [UTType] {
    var types: [UTType] = [.image, .movie, .mpeg4Movie, .quickTimeMovie, .avi]
    for extensionName in ["webp", "webm"] {
      if let type = UTType(filenameExtension: extensionName) {
        types.append(type)
      }
    }
    return types
  }

  private func inferKindFromTarget(_ target: String) {
    if let kind = OrgMediaAttachment.kind(forTarget: target) {
      media.kind = kind
    }
  }

  private func relativeTarget(for url: URL) -> String {
    let path = url.standardizedFileURL.path
    if let sourceFile = store.selectedEntrySource?.file {
      let sourceDirectory = URL(fileURLWithPath: sourceFile)
        .deletingLastPathComponent()
        .standardizedFileURL
        .path
      if let relative = relativePath(path, from: sourceDirectory) {
        return relative
      }
    }
    if let root = store.corpusRoot?.standardizedFileURL.path,
       let relative = relativePath(path, from: root) {
      return relative
    }
    return path
  }

  private func relativePath(_ path: String, from base: String) -> String? {
    guard path.hasPrefix(base + "/") else { return nil }
    return String(path.dropFirst(base.count + 1))
  }

  private func saveMedia() {
    store.editableBlockText = media.formattedRawText
    Task { await store.saveEditedBlock(block) }
  }
}

private extension OrgMediaAttachment.Kind {
  var editorTitle: String {
    switch self {
    case .image:
      return "Image"
    case .video:
      return "Video"
    }
  }

  var editorSystemImage: String {
    switch self {
    case .image:
      return "photo"
    case .video:
      return "film"
    }
  }
}

private struct QuoteBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  private let beginLine: String
  private let endLine: String
  @State private var quoteText: String

  init(block: OrgEditableBlock) {
    self.block = block
    let lines = block.rawText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    self.beginLine = lines.first ?? "#+begin_quote"
    self.endLine = lines.last ?? "#+end_quote"
    let body = lines.count >= 2 ? Array(lines.dropFirst().dropLast()).joined(separator: "\n") : ""
    _quoteText = State(initialValue: body)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("Quote")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)

        Text("line \(block.displayRange)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)

        Spacer(minLength: 0)

        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          saveQuote()
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(store.isSavingBlock)
        .help("Save")

        Button {
          store.cancelEditingBlock()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSavingBlock)
        .help("Cancel")
      }

      HStack(alignment: .top, spacing: 9) {
        Rectangle()
          .fill(Color.secondary.opacity(0.35))
          .frame(width: 3)
          .clipShape(Capsule())

        OrgSyntaxTextEditor(
          text: $quoteText,
          showsScrollers: false,
          textInset: NSSize(width: 2, height: 4),
          focusOnAppear: true
        )
        .frame(minHeight: editorHeight, maxHeight: editorHeight)
        .background(Color.clear)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.accentColor.opacity(0.2))
    )
  }

  private var rawQuote: String {
    "\(beginLine)\n\(quoteText)\n\(endLine)"
  }

  private var editorHeight: CGFloat {
    let lineCount = max(2, quoteText.split(separator: "\n", omittingEmptySubsequences: false).count)
    return min(260, max(58, CGFloat(lineCount) * 23 + 12))
  }

  private func saveQuote() {
    store.editableBlockText = rawQuote
    Task { await store.saveEditedBlock(block) }
  }
}

private struct SourceBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @State private var source: OrgEditableSourceBlock

  init(block: OrgEditableBlock, language: String?, lines: [String]) {
    self.block = block
    _source = State(initialValue: OrgEditableSourceBlock(
      rawText: block.rawText,
      fallbackLanguage: language,
      fallbackLines: lines
    ))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Menu {
          Button("Source") {
            source.setBeginKeyword("#+begin_src")
          }
          Button("Example") {
            source.setBeginKeyword("#+begin_example")
          }
          Button("Org2") {
            source.setBeginKeyword("#+begin_org2")
          }
        } label: {
          Text(sourceKindTitle)
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Source block kind")

        if !source.beginKeyword.lowercased().hasSuffix("begin_example") {
          TextField("language", text: languageBinding)
            .textFieldStyle(.plain)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .frame(width: 110)
            .help("Language")
        }

        TextField("parameters", text: parametersBinding)
          .textFieldStyle(.plain)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .help("Source parameters")

        Spacer(minLength: 0)

        if let runState {
          SourceRunStatusLabel(state: runState)
        }

        if runPlan != nil {
          Button {
            Task { await store.runSourceBlock(block, rawText: source.formattedRawText) }
          } label: {
            Image(systemName: "play.fill")
          }
          .buttonStyle(.borderless)
          .keyboardShortcut("r", modifiers: [.command])
          .disabled(store.isSavingBlock || runState?.status == .running)
          .help("\(sourceRunHelp) (Command-R)")
        }

        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          saveSource()
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(store.isSavingBlock)
        .help("Save")

        Button {
          store.cancelEditingBlock()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSavingBlock)
        .help("Cancel")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color.secondary.opacity(0.07))

      OrgSyntaxTextEditor(
        text: bodyBinding,
        monospaced: true,
        showsScrollers: false,
        textInset: NSSize(width: 10, height: 10),
        focusOnAppear: true
      )
      .frame(minHeight: editorHeight, maxHeight: editorHeight)

      if let state = runState, state.status != .running || state.message != nil {
        SourceRunOutputView(state: state)
          .padding(10)
          .background(Color(nsColor: .textBackgroundColor))
      }
    }
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.accentColor.opacity(0.24))
    )
  }

  private var languageBinding: Binding<String> {
    Binding(
      get: { source.language },
      set: { source.language = $0 }
    )
  }

  private var parametersBinding: Binding<String> {
    Binding(
      get: { source.parameters },
      set: { source.parameters = $0 }
    )
  }

  private var bodyBinding: Binding<String> {
    Binding(
      get: { source.body },
      set: { source.body = $0 }
    )
  }

  private var editorHeight: CGFloat {
    let lineCount = max(3, source.body.split(separator: "\n", omittingEmptySubsequences: false).count)
    return min(360, max(96, CGFloat(lineCount) * 22 + 34))
  }

  private var sourceKindTitle: String {
    let normalized = source.beginKeyword.lowercased()
    if normalized.hasSuffix("begin_example") { return "example" }
    if normalized.hasSuffix("begin_org2") { return "org2" }
    return source.renderedLanguage ?? "source"
  }

  private var runPlan: SourceBlockRunPlan? {
    SourceBlockRunPlan.plan(for: source.renderedLanguage)
  }

  private var runState: SourceBlockRunState? {
    store.sourceBlockRunState(for: block)
  }

  private var sourceRunHelp: String {
    if source.formattedRawText != block.rawText {
      return "Run current source draft"
    }
    return "Run source block"
  }

  private func saveSource() {
    store.editableBlockText = source.formattedRawText
    Task { await store.saveEditedBlock(block) }
  }
}

private struct TableBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @State private var table: OrgEditableTable
  @FocusState private var focusedCell: TableCellFocus?

  init(block: OrgEditableBlock, table: OrgTableBlock) {
    self.block = block
    _table = State(initialValue: OrgEditableTable(rawText: block.rawText, fallback: table))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Label("Table", systemImage: "tablecells")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)

        Button {
          table.addRow()
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Add row")

        Button {
          table.addColumn()
        } label: {
          Image(systemName: "rectangle.split.3x1")
        }
        .buttonStyle(.borderless)
        .help("Add column")

        Button {
          table.addSeparator()
        } label: {
          Image(systemName: "minus")
        }
        .buttonStyle(.borderless)
        .help("Add separator")

        Spacer(minLength: 0)

        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          saveTable()
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(store.isSavingBlock)
        .help("Save")

        Button {
          store.cancelEditingBlock()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSavingBlock)
        .help("Cancel")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color.secondary.opacity(0.07))

      ScrollView(.horizontal) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
            switch row {
            case .cells:
              editableRow(rowIndex: rowIndex)
            case .separator:
              separatorRow(rowIndex: rowIndex)
            }
          }
        }
        .background(Color(nsColor: .textBackgroundColor))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.accentColor.opacity(0.24))
    )
    .onAppear {
      focusedCell = firstEditableCellFocus
    }
  }

  private func editableRow(rowIndex: Int) -> some View {
    HStack(spacing: 0) {
      ForEach(0..<table.columnCount, id: \.self) { columnIndex in
        let focus = TableCellFocus(row: rowIndex, column: columnIndex)
        TableCellTextField(
          text: cellBinding(row: rowIndex, column: columnIndex),
          focusedCell: $focusedCell,
          focus: focus,
          onAdvance: {
            advanceCellFocus(from: focus)
          },
          onRetreat: {
            retreatCellFocus(from: focus)
          }
        )
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .frame(width: 150, alignment: .leading)
          .background(cellBackground(row: rowIndex, column: columnIndex))
          .overlay(alignment: .trailing) {
            Divider()
          }
      }

      rowMenu(rowIndex: rowIndex)
        .frame(width: 34)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func separatorRow(rowIndex: Int) -> some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(Color.secondary.opacity(0.28))
        .frame(width: CGFloat(table.columnCount) * 150, height: 1)
        .padding(.vertical, 12)
      rowMenu(rowIndex: rowIndex)
        .frame(width: 34)
    }
    .background(Color.secondary.opacity(0.05))
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func rowMenu(rowIndex: Int) -> some View {
    Menu {
      Button("Add Row Below") {
        table.addRow(after: rowIndex)
      }
      Button("Add Separator Below") {
        table.addSeparator(after: rowIndex)
      }
      Button("Delete Row", role: .destructive) {
        table.removeRow(rowIndex)
      }
      Divider()
      ForEach(0..<table.columnCount, id: \.self) { columnIndex in
        Button("Delete Column \(columnIndex + 1)", role: .destructive) {
          table.removeColumn(columnIndex)
        }
        .disabled(table.columnCount <= 1)
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.caption.weight(.semibold))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .help("Table row actions")
  }

  private func cellBinding(row rowIndex: Int, column columnIndex: Int) -> Binding<String> {
    Binding(
      get: { table.cell(row: rowIndex, column: columnIndex) },
      set: { newValue in
        if !table.pasteGrid(row: rowIndex, column: columnIndex, rawValue: newValue) {
          table.setCell(row: rowIndex, column: columnIndex, value: newValue)
        }
      }
    )
  }

  private var firstEditableCellFocus: TableCellFocus? {
    guard let rowIndex = table.rows.firstIndex(where: { row in
      if case .cells = row { return true }
      return false
    }) else {
      return nil
    }
    return TableCellFocus(row: rowIndex, column: 0)
  }

  private func advanceCellFocus(from current: TableCellFocus) {
    if current.column + 1 < table.columnCount {
      focusedCell = TableCellFocus(row: current.row, column: current.column + 1)
      return
    }

    let nextRow = table.rows.indices
      .filter { $0 > current.row }
      .first { rowIndex in
        if case .cells = table.rows[rowIndex] { return true }
        return false
      }

    if let nextRow {
      focusedCell = TableCellFocus(row: nextRow, column: 0)
    } else {
      table.addRow(after: current.row)
      focusedCell = TableCellFocus(row: min(current.row + 1, table.rows.count - 1), column: 0)
    }
  }

  private func retreatCellFocus(from current: TableCellFocus) {
    if current.column > 0 {
      focusedCell = TableCellFocus(row: current.row, column: current.column - 1)
      return
    }

    let previousRow = table.rows.indices
      .reversed()
      .filter { $0 < current.row }
      .first { rowIndex in
        if case .cells = table.rows[rowIndex] { return true }
        return false
      }

    if let previousRow {
      focusedCell = TableCellFocus(row: previousRow, column: max(0, table.columnCount - 1))
    }
  }

  private func cellBackground(row rowIndex: Int, column columnIndex: Int) -> Color {
    let focus = TableCellFocus(row: rowIndex, column: columnIndex)
    if focusedCell == focus {
      return Color.accentColor.opacity(0.12)
    }
    return Color(nsColor: .controlBackgroundColor)
  }

  private func saveTable() {
    store.editableBlockText = table.formattedRawText
    Task { await store.saveEditedBlock(block) }
  }
}

private struct TableCellFocus: Hashable {
  let row: Int
  let column: Int
}

private struct TableCellTextField: NSViewRepresentable {
  @Binding var text: String
  let focusedCell: FocusState<TableCellFocus?>.Binding
  let focus: TableCellFocus
  let onAdvance: () -> Void
  let onRetreat: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSTextField {
    let textField = NSTextField(string: text)
    textField.delegate = context.coordinator
    textField.isBordered = false
    textField.isBezeled = false
    textField.drawsBackground = false
    textField.focusRingType = .none
    textField.lineBreakMode = .byTruncatingTail
    textField.usesSingleLineMode = true
    textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    return textField
  }

  func updateNSView(_ textField: NSTextField, context: Context) {
    context.coordinator.parent = self
    if textField.stringValue != text {
      textField.stringValue = text
    }

    guard focusedCell.wrappedValue == focus,
          textField.window?.firstResponder !== textField.currentEditor()
    else {
      return
    }

    DispatchQueue.main.async {
      textField.window?.makeFirstResponder(textField)
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: TableCellTextField

    init(parent: TableCellTextField) {
      self.parent = parent
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
      parent.focusedCell.wrappedValue = parent.focus
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let textField = notification.object as? NSTextField else { return }
      parent.text = textField.stringValue
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      parent.text = textView.string
      switch commandSelector {
      case #selector(NSResponder.insertNewline(_:)),
           #selector(NSResponder.insertTab(_:)):
        parent.onAdvance()
        return true
      case #selector(NSResponder.insertBacktab(_:)):
        parent.onRetreat()
        return true
      default:
        return false
      }
    }
  }
}
