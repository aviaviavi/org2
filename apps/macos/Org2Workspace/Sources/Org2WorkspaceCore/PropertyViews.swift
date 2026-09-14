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
  var title = "Untitled view"
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
struct PropertyViewSuggestion: Decodable, Sendable {
  let prompt: String
  let summary: String
  let definition: PropertyViewDefinition
  let result: PropertyViewResult?
}
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

struct SavedViewsView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var saved: [SavedPropertyView] = []
  @State private var draft = PropertyViewDefinition()
  @State private var selectedID: String?
  @State private var revision: String?
  @State private var result: PropertyViewResult?
  @State private var busy = false
  @State private var error: String?
  @State private var notice: String?
  @State private var discoveryWarnings: [String] = []
  @State private var editingCell: PropertyViewCellEdit?
  @State private var isBuilderPresented = false
  @State private var prompt = ""
  @State private var suggestionSummary: String?

  private var root: String? { store.corpusRoot?.path }
  private var canEditSource: Bool { !store.hasActiveEdit && !store.liveFileEditorHasUnsavedChanges }
  private var hasUnrunChanges: Bool { result?.definition != draft }

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        pageHeader
        Divider()
        if proxy.size.width >= 720 {
          HStack(spacing: 0) {
            savedViewList
              .frame(width: 230)
            Divider()
            activeContent
          }
        } else {
          compactViewPicker
          Divider()
          activeContent
        }
      }
    }
    .task(id: root) { await loadInitial() }
    .sheet(item: $editingCell) { cell in
      PropertyViewCellEditor(cell: cell, root: root ?? "", canApply: canEditSource) {
        await query()
        await store.refreshCorpusFiles()
      }.environment(store)
    }
    .sheet(isPresented: $isBuilderPresented) {
      advancedBuilder
    }
  }

  @ViewBuilder private var activeContent: some View {
    Group {
      if selectedID == nil && result == nil {
        createLanding
      } else {
        viewDetail
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var compactViewPicker: some View {
    HStack(spacing: 8) {
      if saved.isEmpty {
        Text("No saved views yet").foregroundStyle(.secondary)
      } else {
        Picker("View", selection: Binding(
          get: { selectedID ?? "" },
          set: { value in
            if value.isEmpty { beginCreating() }
            else { selectSaved(value) }
          }
        )) {
          Text("Create a view").tag("")
          ForEach(saved) { view in Text(view.definition.title).tag(view.id) }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
      }
      Button { beginCreating() } label: { Label("New View", systemImage: "plus") }
        .labelStyle(.iconOnly)
        .help("Create a view")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var pageHeader: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Saved Views").font(.title2.weight(.semibold))
        Text("Live tables and boards made from your notes")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if busy { ProgressView().controlSize(.small) }
      Button { Task { await reload() } } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .labelStyle(.iconOnly)
      .help("Reload saved views")
      .disabled(busy || root == nil)
      Button { beginCreating() } label: {
        Label("New View", systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
      .disabled(busy || root == nil)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
  }

  private var savedViewList: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("YOUR VIEWS")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 14)
      if saved.isEmpty {
        Text("No saved views yet")
          .font(.callout)
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
      } else {
        ScrollView {
          LazyVStack(spacing: 3) {
            ForEach(saved) { view in
              Button { selectSaved(view.id) } label: {
                HStack(spacing: 8) {
                  Image(systemName: view.definition.layout == "cards" ? "rectangle.grid.2x2" : "tablecells")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                  Text(view.definition.title)
                    .lineLimit(2)
                  Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(
                  selectedID == view.id ? Color.accentColor.opacity(0.12) : Color.clear,
                  in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("saved-view-\(view.id)")
            }
          }
          .padding(.horizontal, 6)
        }
      }
      Spacer(minLength: 0)
      Divider()
      Button { beginCreating() } label: {
        Label("Create a view", systemImage: "plus.circle")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .padding(14)
    }
    .background(Color.primary.opacity(0.018))
  }

  private var createLanding: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 8) {
          Image(systemName: "tablecells")
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(Color.accentColor)
          Text("See your notes as a useful view")
            .font(.title.weight(.semibold))
          Text("Describe what you want to see. OpenOrg will turn the properties already in your notes into a live table or board. Your Org files stay the source of truth.")
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 10) {
          Text("What would you like to see?").font(.headline)
          TextField("For example: Show my unfinished project tasks grouped by project", text: $prompt, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
            .onSubmit { Task { await suggestAndQuery() } }
            .accessibilityIdentifier("saved-views-prompt")
          HStack {
            Spacer()
            Button("Make View") { Task { await suggestAndQuery() } }
              .buttonStyle(.borderedProminent)
              .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
              .accessibilityIdentifier("saved-views-create")
          }
        }
        VStack(alignment: .leading, spacing: 10) {
          Text("Try an example").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), alignment: .leading)], alignment: .leading, spacing: 8) {
            exampleButton("Open project actions").frame(maxWidth: .infinity, alignment: .leading)
            exampleButton("Open work by assignee").frame(maxWidth: .infinity, alignment: .leading)
            exampleButton("Project notes as cards").frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          Label("What makes this different from Search?", systemImage: "lightbulb")
            .font(.headline)
          Text("A saved view stays organized as your notes change. You can group, sort, and update editable properties without opening every source file.")
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(22)
    }
  }

  private func exampleButton(_ text: String) -> some View {
    Button(text) {
      prompt = text
      Task { await suggestAndQuery() }
    }
    .buttonStyle(.bordered)
  }

  private var viewDetail: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(draft.title).font(.title2.weight(.semibold))
          Text(suggestionSummary ?? scopeSummary)
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        if revision == nil {
          Button("Save View", systemImage: "square.and.arrow.down") { Task { await save() } }
            .buttonStyle(.borderedProminent)
            .disabled(busy || result == nil || hasUnrunChanges)
            .accessibilityIdentifier("property-views-save")
        } else if saved.first(where: { $0.id == selectedID })?.definition != draft {
          Button("Save Changes") { Task { await save() } }
            .buttonStyle(.borderedProminent)
            .disabled(busy || hasUnrunChanges)
        }
        Button("Edit View", systemImage: "slider.horizontal.3") { isBuilderPresented = true }
          .disabled(busy)
        Menu {
          Button("Duplicate") { duplicateCurrent() }
          Button("Start a New View") { beginCreating() }
        } label: {
          Label("More", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      .padding(18)
      Divider()
      if let error {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
          .padding(18).accessibilityIdentifier("property-views-error")
      } else if busy && result == nil {
        VStack(spacing: 12) {
          ProgressView()
          Text("Building this view…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let result {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("\(result.total) item\(result.total == 1 ? "" : "s")\(result.truncated ? " · showing \(result.rows.count)" : "")")
            Spacer()
            if hasUnrunChanges { Text("Apply the edited view to update these results").foregroundStyle(.orange) }
          }
          .font(.caption)
          ForEach(result.diagnostics ?? [], id: \.file) { diagnostic in
            Text("Skipped \(diagnostic.file): \(diagnostic.message)").font(.caption).foregroundStyle(.orange)
          }
          results(result).disabled(busy || hasUnrunChanges)
        }
        .padding(18)
      } else {
        ContentUnavailableView("View unavailable", systemImage: "tablecells", description: Text("Refresh this saved view to load its current rows."))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 10) }
      ForEach(discoveryWarnings, id: \.self) { warning in Text(warning).foregroundStyle(.orange).font(.caption).padding(.horizontal, 18) }
    }
  }

  private var scopeSummary: String {
    let noun = draft.scope.kind == "heading" ? "headings" : draft.scope.kind == "file" ? "notes" : "notes and headings"
    if let prefix = draft.scope.filePrefix { return "Live \(noun) from \(prefix)" }
    return "Live \(noun) from this corpus"
  }

  private var advancedBuilder: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Edit View").font(.title2.weight(.semibold))
          Text("Advanced query details").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { isBuilderPresented = false }.keyboardShortcut(.cancelAction)
      }
      builder
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      Text("Changes are previewed in the results before you save them.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(22)
    .frame(minWidth: 820, idealWidth: 940)
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
                Text("is unfinished TODO").tag("active"); Text("is finished TODO").tag("terminal")
              }.labelsHidden().frame(width: 175)
              TextField("Value", text: $draft.filters[index].value)
                .disabled(["exists", "missing", "active", "terminal"].contains(draft.filters[index].operator))
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
          ForEach(Array(displayGroups(result).enumerated()), id: \.offset) { _, group in
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
                  Text("Item").font(.caption.bold()).frame(width: 250, alignment: .leading)
                  ForEach(displayedColumns(result), id: \.self) { field in
                    Text(field).font(.caption.bold()).frame(width: 155, alignment: .leading)
                  }
                }.padding(8).background(.quaternary)
                ForEach(group.rows) { row in
                  HStack(alignment: .top) {
                    sourceButton(row).frame(width: 250, alignment: .leading)
                    ForEach(displayedColumns(result), id: \.self) { field in cell(row, field: field, result: result).frame(width: 155, alignment: .leading) }
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
      sourceButton(row)
      ForEach(displayedColumns(result), id: \.self) { field in
        HStack(alignment: .top) { Text(field).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading); cell(row, field: field, result: result) }
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
  }
  private func sourceButton(_ row: PropertyViewResult.Row) -> some View {
    Button {
      guard let root else { return }
      store.openChatFileReference(.init(path: URL(fileURLWithPath: root).appendingPathComponent(row.file).path, line: row.line))
    } label: {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: row.kind == "file" ? "doc.text" : "number")
          .foregroundStyle(Color.accentColor)
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 2) {
          OrgInlineText(row.title, font: .callout.weight(.medium), managesTextSelection: false).lineLimit(2)
          Text("\(row.file):\(row.line)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }.buttonStyle(.plain).help("Open \(row.title) at its source")
  }

  private func displayedColumns(_ result: PropertyViewResult) -> [String] {
    result.definition.columns.filter { !["title", "document", "file"].contains($0) }
  }

  private func displayGroups(_ result: PropertyViewResult) -> [(name: String, rows: [PropertyViewResult.Row])] {
    result.groups.enumerated().sorted { left, right in
      if left.element.name.isEmpty != right.element.name.isEmpty { return !left.element.name.isEmpty }
      return left.offset < right.offset
    }.map(\.element)
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
    selectedID = id; prompt = ""; suggestionSummary = nil
    draft = view.definition; revision = view.revision; result = nil; notice = nil; error = nil
    Task { await query() }
  }
  private func loadInitial() async {
    guard !busy else { return }
    busy = true
    await loadSaved()
    busy = false
    selectedID = nil
    revision = nil
    result = nil
  }
  private func reload() async {
    guard !busy else { return }
    busy = true
    let currentID = selectedID
    await loadSaved()
    if let currentID, let view = saved.first(where: { $0.id == currentID }) {
      draft = view.definition; revision = view.revision
    }
    busy = false
    if currentID != nil { await query() }
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
      selectedID = draft.id
      notice = "Saved. This view will stay current as your notes change."
      await loadSaved()
    } catch { self.error = error.localizedDescription }
    busy = false
    await query()
  }

  private func beginCreating() {
    selectedID = nil
    revision = nil
    result = nil
    error = nil
    notice = nil
    prompt = ""
    suggestionSummary = nil
  }

  private func duplicateCurrent() {
    draft.id = "view-\(UUID().uuidString.lowercased())"
    draft.title += " copy"
    selectedID = nil
    revision = nil
    suggestionSummary = "A copy of \(draft.title.replacingOccurrences(of: " copy", with: "")), ready to adjust and save."
  }

  private func suggestAndQuery() async {
    let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let root, !request.isEmpty, !busy else { return }
    busy = true; error = nil; notice = nil; result = nil
    do {
      let suggestion: PropertyViewSuggestion = try await store.cli.runJSON([
        "property-view", "suggest", "--prompt", request, "--dir", root,
      ])
      guard !Task.isCancelled else { busy = false; return }
      draft = suggestion.definition
      selectedID = nil
      revision = nil
      suggestionSummary = suggestion.summary
      if let response = suggestion.result {
        result = response
        draft = response.definition
        busy = false
      } else {
        busy = false
        await query()
      }
    } catch {
      self.error = error.localizedDescription
      busy = false
    }
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
