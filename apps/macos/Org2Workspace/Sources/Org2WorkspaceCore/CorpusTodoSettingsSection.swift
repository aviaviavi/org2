import SwiftUI

public struct CorpusTodoConfiguration: Decodable, Sendable {
  public let revision: String
  public let sequences: [String]
  public let effectiveSequences: [Org2TodoSequence]
  public let sequenceFields: [Fields]
  public struct Fields: Decodable, Sendable {
    public let active: String
    public let terminal: String
  }
}

public struct CorpusTodoSettingsSection: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var rows: [WorkflowRow] = []
  @State private var revision: String?
  @State private var isBusy = false
  @State private var error: String?
  @State private var saved = false

  private struct WorkflowRow: Identifiable {
    let id = UUID()
    var active: String
    var terminal: String
    var definition: String { "\(active.trimmingCharacters(in: .whitespacesAndNewlines)) | \(terminal.trimmingCharacters(in: .whitespacesAndNewlines))" }
  }

  public init() {}

  public var body: some View {
    Section {
      ForEach($rows) { $row in
        VStack(alignment: .leading, spacing: 8) {
          TextField("Active states", text: $row.active)
          HStack {
            TextField("Terminal states", text: $row.terminal)
            Button {
              rows.removeAll { $0.id == row.id }
              saved = false
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Remove this sequence")
            .accessibilityLabel("Remove TODO sequence")
          }
        }
      }
      if rows.isEmpty {
        Text("Using built-in states: TODO, IN_PROGRESS, DONE, CANCELED, CANCELLED.")
          .font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        Button("Add Sequence") {
          rows.append(WorkflowRow(active: rows.isEmpty ? "TODO IN_PROGRESS" : "", terminal: rows.isEmpty ? "DONE CANCELED CANCELLED" : ""))
          saved = false
        }
        Button("Use Built-in States") { rows = []; saved = false }
        Spacer()
        if isBusy { ProgressView().controlSize(.small) }
        if saved { Label("Saved", systemImage: "checkmark").foregroundStyle(.secondary) }
        Button("Save TODO States") { Task { await save() } }
          .buttonStyle(.borderedProminent)
          .disabled(revision == nil)
      }
      if let error {
        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        Button("Reload Settings") { Task { await load() } }
      }
    } header: {
      Label("TODO States", systemImage: "checklist")
    } footer: {
      Text("Separate state names with spaces, in cycling order. Terminal states are finished outcomes, such as DONE, MISSED, or CANCELED. These defaults are shared with this corpus through org2.json. A file’s own TODO declaration takes precedence.")
    }
    .disabled(isBusy)
    .task(id: store.corpusRoot?.path) { await load() }
    .onChange(of: rows.map(\.definition)) { saved = false }
  }

  @MainActor private func load() async {
    guard let root = store.corpusRoot else { revision = nil; rows = []; return }
    isBusy = true
    error = nil
    saved = false
    revision = nil
    defer { isBusy = false }
    do {
      let config: CorpusTodoConfiguration = try await store.cli.runJSON(["todo-config", "show", "--dir", root.path])
      guard store.corpusRoot == root, !Task.isCancelled else { return }
      revision = config.revision
      rows = config.sequenceFields.map { fields in
        WorkflowRow(active: fields.active, terminal: fields.terminal)
      }
    } catch { self.error = error.localizedDescription }
  }

  @MainActor private func save() async {
    guard let root = store.corpusRoot, let revision else { return }
    isBusy = true
    error = nil
    saved = false
    defer { isBusy = false }
    do {
      let data = try JSONEncoder().encode(rows.map(\.definition))
      let arguments = ["todo-config", "set", "--dir", root.path, "--sequences-json", String(decoding: data, as: UTF8.self), "--if-revision", revision]
      let _: CorpusTodoConfiguration = try await store.cli.runJSON(arguments)
      guard store.corpusRoot == root, !Task.isCancelled else { return }
      let result: CorpusTodoConfiguration = try await store.cli.runJSON(arguments + ["--apply"])
      guard store.corpusRoot == root else { return }
      self.revision = result.revision
      saved = true
      await store.reloadCorpusTodoConfiguration()
    } catch { self.error = error.localizedDescription }
  }
}
