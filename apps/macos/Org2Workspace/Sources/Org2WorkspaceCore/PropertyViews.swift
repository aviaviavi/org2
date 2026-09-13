import Foundation
import SwiftUI

struct PropertyViewDefinition: Codable, Equatable, Sendable, Identifiable {
  struct Scope: Codable, Equatable, Sendable { var kind = "heading"; var filePrefix: String? }
  struct Filter: Codable, Equatable, Sendable {
    var field = "STATUS"
    var `operator` = "is"
    var value = ""
  }
  struct Sort: Codable, Equatable, Sendable { var field = "title"; var direction = "asc" }
  var schema = "org2:property-view:v1"
  var id = UUID().uuidString.lowercased()
  var title = "New property view"
  var layout = "table"
  var scope = Scope()
  var columns = ["title", "STATUS", "ASSIGNEE"]
  var match = "all"
  var filters: [Filter] = []
  var sort = [Sort()]
  var groupBy: String?
  var limit = 500

  func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}
struct SavedPropertyView: Decodable, Identifiable, Sendable {
  let definition: PropertyViewDefinition
  let file: String
  let revision: String
  var id: String { definition.id }
}
struct PropertyViewList: Decodable, Sendable {
  struct Diagnostic: Decodable, Sendable { let file: String; let message: String }
  let views: [SavedPropertyView]
  let diagnostics: [Diagnostic]
}
struct PropertyViewResult: Decodable, Sendable {
  struct Row: Decodable, Identifiable, Sendable {
    let key: String
    let kind: String
    let file: String
    let line: Int
    let title: String
    let revision: String
    let properties: [String: String]
    let inheritedProperties: [String: String]
    let values: [String: String]
    let group: String
    let editable: Bool
    var id: String { key }
  }
  let definition: PropertyViewDefinition
  let total: Int
  let truncated: Bool
  let fields: [String]
  let editableFields: [String]
  let diagnostics: [PropertyViewList.Diagnostic]?
  let rows: [Row]

  // Preserve the shared runtime's ordering within each group and its first
  // appearance order across groups; Swift does not reinterpret property values.
  var groups: [(name: String, rows: [Row])] {
    var names: [String] = []
    var grouped: [String: [Row]] = [:]
    for row in rows {
      if grouped[row.group] == nil { names.append(row.group) }
      grouped[row.group, default: []].append(row)
    }
    return names.map { ($0, grouped[$0] ?? []) }
  }
}
struct PropertyViewSaveResult: Decodable, Sendable { let revision: String; let definition: PropertyViewDefinition }
struct PropertyViewEditResult: Decodable, Sendable {
  let revision: String
  let changed: Bool
  let property: String
  let oldValue: String?
  let value: String
}
struct PropertyViewCellEdit: Identifiable {
  let row: PropertyViewResult.Row
  let field: String
  var id: String { row.key + ":" + field }
}

enum PropertyViewCommands {
  static func edit(root: String, cell: PropertyViewCellEdit, value: String, revision: String? = nil, apply: Bool = false) -> [String] {
    ["property-view", "edit", "--dir", root, "--file", cell.row.file,
     "--kind", cell.row.kind, "--line", String(cell.row.line), "--property", cell.field,
     "--value", value, "--if-revision", revision ?? cell.row.revision] + (apply ? ["--apply"] : [])
  }
}

struct PropertyViewsSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var saved: [SavedPropertyView] = []
  @State private var draft = PropertyViewDefinition()
  @State private var revision: String?
  @State private var result: PropertyViewResult?
  @State private var busy = false
  @State private var error: String?
  @State private var notice: String?
  @State private var discoveryWarnings: [String] = []
  @State private var editingCell: PropertyViewCellEdit?
  @State private var isBuilderExpanded = true

  private var root: String? { store.corpusRoot?.path }
  private var canEditSource: Bool { !store.hasActiveEdit && !store.liveFileEditorHasUnsavedChanges }
  private var hasUnrunChanges: Bool { result?.definition != draft }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Property Views", systemImage: "tablecells").font(.title2.bold())
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text("Saved tables and cards over notes and headings in the active corpus. Edit a property cell to update its source.")
        .foregroundStyle(.secondary)
      HStack {
        Picker("Saved view", selection: Binding(get: { revision == nil ? "" : draft.id }, set: { value in selectSaved(value) })) {
          Text("Unsaved view").tag("")
          ForEach(saved) { view in Text(view.definition.title).tag(view.id) }
        }
        .frame(maxWidth: 340)
        Button("New", systemImage: "plus") {
          draft = PropertyViewDefinition(); revision = nil; result = nil; notice = nil; error = nil
        }
        Button("Duplicate", systemImage: "doc.on.doc") {
          draft.id = UUID().uuidString.lowercased(); draft.title += " copy"; revision = nil; result = nil
        }
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
          .help("Reload the saved definition and current source rows")
        Button("Save View", systemImage: "square.and.arrow.down") { Task { await save() } }
          .keyboardShortcut("s", modifiers: [.command])
          .accessibilityIdentifier("property-views-save")
      }
      .disabled(busy || root == nil)

      DisclosureGroup("View builder", isExpanded: $isBuilderExpanded) { builder.padding(.top, 8) }
        .disabled(busy || root == nil)
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("property-views-error") }
      ForEach(discoveryWarnings, id: \.self) { warning in Text(warning).foregroundStyle(.orange).font(.caption) }
      if let notice { Text(notice).foregroundStyle(.secondary).font(.caption) }
      if !canEditSource {
        Text("Save or cancel the open source edit before changing properties here.").foregroundStyle(.orange)
      }
      Divider()
      if let result {
        ForEach(result.diagnostics ?? [], id: \.file) { diagnostic in
          Text("Omitted \(diagnostic.file): \(diagnostic.message)").font(.caption).foregroundStyle(.orange)
        }
        HStack {
          Text("\(result.total) matches\(result.truncated ? " · showing first \(result.rows.count)" : "")")
          Spacer()
          if hasUnrunChanges { Text("Builder changed — Apply View to update results").foregroundStyle(.orange) }
        }.font(.caption)
        results(result)
          .disabled(busy || hasUnrunChanges)
      } else {
        ContentUnavailableView("Build a property view", systemImage: "tablecells", description: Text("Choose a saved view or set the fields and filters above, then Apply View."))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(20)
    .frame(minWidth: 840, idealWidth: 1080, minHeight: 620, idealHeight: 760)
    .task(id: root) { await loadInitial() }
    .sheet(item: $editingCell) { cell in
      PropertyViewCellEditor(cell: cell, root: root ?? "", canApply: canEditSource) {
        await query()
        await store.refreshCorpusFiles()
      }.environment(store)
    }
  }

  private var builder: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        TextField("View name", text: $draft.title).accessibilityLabel("View name")
        Picker("Layout", selection: $draft.layout) {
          Text("Table").tag("table"); Text("Cards").tag("cards")
        }.frame(width: 170)
        Picker("Rows", selection: $draft.scope.kind) {
          Text("Headings").tag("heading"); Text("Notes").tag("file"); Text("Both").tag("all")
        }.frame(width: 180)
      }
      HStack {
        TextField("Folder prefix (optional, e.g. notes/projects/)", text: Binding(get: { draft.scope.filePrefix ?? "" }, set: { draft.scope.filePrefix = $0.isEmpty ? nil : $0 }))
          .accessibilityLabel("Corpus-relative folder prefix")
        TextField("Columns separated by commas", text: Binding(get: { draft.columns.joined(separator: ", ") }, set: {
          draft.columns = $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        })).accessibilityLabel("Columns separated by commas")
      }
      HStack {
        Picker("Match", selection: $draft.match) { Text("All filters").tag("all"); Text("Any filter").tag("any") }.frame(width: 200)
        Button("Add Filter", systemImage: "line.3.horizontal.decrease.circle") { draft.filters.append(.init()) }
          .disabled(draft.filters.count >= 30)
        Spacer()
        Text("Fields: title, file, todo, tags, or a property name").font(.caption).foregroundStyle(.secondary)
      }
      ScrollView {
        VStack(spacing: 6) {
          ForEach(draft.filters.indices, id: \.self) { index in
            HStack {
              fieldInput("Property", text: $draft.filters[index].field)
              Picker("Condition", selection: $draft.filters[index].operator) {
                Text("equals").tag("is"); Text("does not equal").tag("isNot"); Text("contains").tag("contains")
                Text("is present").tag("exists"); Text("is missing").tag("missing")
                Text("greater than").tag("gt"); Text("less than").tag("lt")
              }.labelsHidden().frame(width: 175)
              TextField("Value", text: $draft.filters[index].value)
                .disabled(["exists", "missing"].contains(draft.filters[index].operator))
              Button("Remove Filter", systemImage: "minus.circle") { draft.filters.remove(at: index) }.labelStyle(.iconOnly)
            }
          }
        }
      }.frame(height: min(CGFloat(draft.filters.count) * 34, 112))
      HStack {
        Text("Sort")
        fieldInput("Sort field", text: Binding(get: { draft.sort.first?.field ?? "title" }, set: { draft.sort = [.init(field: $0, direction: draft.sort.first?.direction ?? "asc")] }))
        Picker("Direction", selection: Binding(get: { draft.sort.first?.direction ?? "asc" }, set: { draft.sort = [.init(field: draft.sort.first?.field ?? "title", direction: $0)] })) {
          Text("Ascending").tag("asc"); Text("Descending").tag("desc")
        }.labelsHidden().frame(width: 125)
        Text("Group")
        fieldInput("None", text: Binding(get: { draft.groupBy ?? "" }, set: { draft.groupBy = $0.isEmpty ? nil : $0 }))
        Spacer()
        Button("Apply View") { Task { await query() } }
          .buttonStyle(.borderedProminent).accessibilityIdentifier("property-views-apply")
      }
    }.textFieldStyle(.roundedBorder)
  }

  private func fieldInput(_ prompt: String, text: Binding<String>) -> some View {
    HStack(spacing: 2) {
      TextField(prompt, text: text).accessibilityLabel(prompt)
      if let fields = result?.fields {
        Menu { ForEach(fields, id: \.self) { field in Button(field) { text.wrappedValue = field } } } label: { Image(systemName: "chevron.down") }
          .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Choose \(prompt.lowercased())")
      }
    }.frame(maxWidth: 210)
  }

  @ViewBuilder private func results(_ result: PropertyViewResult) -> some View {
    if result.rows.isEmpty {
      ContentUnavailableView("No matching rows", systemImage: "line.3.horizontal.decrease.circle", description: Text("Adjust the scope or filters to include more notes or headings."))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView([.vertical, .horizontal]) {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(Array(result.groups.enumerated()), id: \.offset) { _, group in
            if result.definition.groupBy != nil {
              Text("\(group.name.isEmpty ? "No value" : group.name) · \(group.rows.count)").font(.headline)
            }
            if result.definition.layout == "cards" {
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 245, maximum: 350))], alignment: .leading, spacing: 12) {
                ForEach(group.rows) { row in card(row, result: result) }
              }.frame(minWidth: 780, maxWidth: 1020)
            } else {
              LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                  Text("Source").font(.caption.bold()).frame(width: 190, alignment: .leading)
                  ForEach(result.definition.columns, id: \.self) { field in
                    Text(field).font(.caption.bold()).frame(width: 155, alignment: .leading)
                  }
                }.padding(8).background(.quaternary)
                ForEach(group.rows) { row in
                  HStack(alignment: .top) {
                    sourceButton(row).frame(width: 190, alignment: .leading)
                    ForEach(result.definition.columns, id: \.self) { field in cell(row, field: field, result: result).frame(width: 155, alignment: .leading) }
                  }.padding(8)
                  Divider()
                }
              }
            }
          }
        }.padding(.bottom, 12)
      }.accessibilityIdentifier("property-views-results")
    }
  }
  private func card(_ row: PropertyViewResult.Row, result: PropertyViewResult) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(row.title).font(.headline).lineLimit(2)
      sourceButton(row)
      ForEach(result.definition.columns.filter { $0 != "title" }, id: \.self) { field in
        HStack(alignment: .top) { Text(field).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading); cell(row, field: field, result: result) }
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
  }
  private func sourceButton(_ row: PropertyViewResult.Row) -> some View {
    Button {
      guard let root else { return }
      dismiss()
      store.openChatFileReference(.init(path: URL(fileURLWithPath: root).appendingPathComponent(row.file).path, line: row.line))
    } label: {
      Label("\(row.file):\(row.line)", systemImage: row.kind == "file" ? "doc.text" : "number")
        .font(.caption).lineLimit(2)
    }.buttonStyle(.link).help("Open \(row.title) at its source")
  }
  @ViewBuilder private func cell(_ row: PropertyViewResult.Row, field: String, result: PropertyViewResult) -> some View {
    if row.editable && result.editableFields.contains(field) {
      Button { editingCell = .init(row: row, field: field) } label: {
        HStack(spacing: 4) {
          Text((row.values[field] ?? "").isEmpty ? "Set value…" : row.values[field]!).lineLimit(3)
          if row.inheritedProperties[field] != nil { Image(systemName: "arrow.down.right").font(.caption2) }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(!canEditSource)
        .help(row.inheritedProperties[field] == nil ? "Edit \(field) in source" : "Inherited value. Editing creates a local override.")
        .accessibilityIdentifier("property-view-cell-\(row.key)-\(field)")
    } else { Text(row.values[field] ?? "").lineLimit(3).textSelection(.enabled) }
  }

  private func selectSaved(_ id: String) {
    guard let view = saved.first(where: { $0.id == id }) else { return }
    draft = view.definition; revision = view.revision; result = nil; notice = nil
    Task { await query() }
  }
  private func loadInitial() async {
    guard !busy else { return }
    busy = true
    await loadSaved()
    if let first = saved.first { draft = first.definition; revision = first.revision }
    busy = false
    await query()
  }
  private func reload() async {
    guard !busy else { return }
    busy = true
    let currentID = revision == nil ? nil : draft.id
    await loadSaved()
    if let currentID, let view = saved.first(where: { $0.id == currentID }) {
      draft = view.definition; revision = view.revision
    }
    busy = false
    await query()
  }
  private func loadSaved() async {
    guard let root else { error = "Open a corpus to use property views."; return }
    do {
      let list: PropertyViewList = try await store.cli.runJSON(["property-view", "list", "--dir", root])
      guard self.root == root else { return }
      saved = list.views
      discoveryWarnings = list.diagnostics.map { "\($0.file): \($0.message)" }
    } catch { self.error = error.localizedDescription }
  }
  private func query() async {
    guard let root, !busy else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      let response: PropertyViewResult = try await store.cli.runJSON(["property-view", "query", "--dir", root, "--definition", try draft.json()])
      guard self.root == root else { return }
      result = response; draft = response.definition
    } catch { self.error = error.localizedDescription }
  }
  private func save() async {
    guard let root, !busy else { return }
    busy = true; error = nil
    do {
      var arguments = ["property-view", "save", "--dir", root, "--definition", try draft.json()]
      if let revision { arguments += ["--if-revision", revision] }
      let _: PropertyViewSaveResult = try await store.cli.runJSON(arguments)
      let response: PropertyViewSaveResult = try await store.cli.runJSON(arguments + ["--apply"])
      guard self.root == root else { busy = false; return }
      revision = response.revision; draft = response.definition
      notice = "Saved views/\(draft.id).org2-view.json. Copy this file to another corpus to reuse the view."
      await loadSaved()
    } catch { self.error = error.localizedDescription }
    busy = false
    await query()
  }
}

private struct PropertyViewCellEditor: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let cell: PropertyViewCellEdit
  let root: String
  let canApply: Bool
  let onApplied: () async -> Void
  @State private var value = ""
  @State private var preview: PropertyViewEditResult?
  @State private var error: String?
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Edit \(cell.field)").font(.title2.bold())
      Text("\(cell.row.title) · \(cell.row.file):\(cell.row.line)").foregroundStyle(.secondary).textSelection(.enabled)
      if let inherited = cell.row.inheritedProperties[cell.field] {
        Text("Inherited: \(inherited). This edit will create a property on this row; its parent stays unchanged.").font(.callout)
      }
      TextField("Value", text: $value).textFieldStyle(.roundedBorder).disabled(busy)
        .onChange(of: value) { _, _ in preview = nil }
        .accessibilityIdentifier("property-view-edit-value")
      if let preview {
        Text("\(preview.property): \(preview.oldValue ?? "(no local value)") → \(preview.value.isEmpty ? "(empty value)" : preview.value)")
          .textSelection(.enabled)
      }
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Preview Change") { Task { await previewChange() } }.disabled(busy || !canApply)
        Button("Apply to Source") { Task { await apply() } }
          .buttonStyle(.borderedProminent).disabled(busy || preview == nil || !canApply)
          .accessibilityIdentifier("property-view-edit-apply")
      }
    }.padding(24).frame(width: 540)
      .onAppear { value = cell.row.values[cell.field] ?? "" }
  }
  private func previewChange() async {
    busy = true; error = nil
    defer { busy = false }
    do { preview = try await store.cli.runJSON(PropertyViewCommands.edit(root: root, cell: cell, value: value)) }
    catch { self.error = error.localizedDescription; preview = nil }
  }
  private func apply() async {
    guard let preview, canApply, store.corpusRoot?.path == root, !store.hasActiveEdit, !store.liveFileEditorHasUnsavedChanges else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      let _: PropertyViewEditResult = try await store.cli.runJSON(PropertyViewCommands.edit(root: root, cell: cell, value: preview.value, revision: preview.revision, apply: true))
      await onApplied(); dismiss()
    } catch { self.error = error.localizedDescription; self.preview = nil }
  }
}
