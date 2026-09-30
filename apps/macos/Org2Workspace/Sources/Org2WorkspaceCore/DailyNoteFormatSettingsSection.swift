import AppKit
import SwiftUI

/// Settings for where Today, Yesterday, Tomorrow, and Home find daily notes.
///
/// The user points at one existing daily note; `org2 daily-config infer`
/// turns its path into a format such as `ops/{YYYY}/{MM}{DD}-startup.md`,
/// which is saved to org2.json as `roam.dailyFileTemplate`.
public struct DailyNoteFormatSettingsSection: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var savedTemplate: String?
  @State private var draft = ""
  @State private var candidates: [DailyNoteTemplateInference.Candidate] = []
  @State private var example: String?
  @State private var revision: String?
  @State private var isEditing = false
  @State private var isBusy = false
  @State private var error: String?
  @State private var saved = false
  private let onSaved: (() -> Void)?

  public init(onSaved: (() -> Void)? = nil) {
    self.onSaved = onSaved
  }

  public var body: some View {
    Section {
      if isEditing {
        editor
      } else {
        summary
      }
      if let error {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    } header: {
      Label("Daily Note Format", systemImage: "calendar.badge.clock")
    } footer: {
      SettingsFooterText("Today, Yesterday, Tomorrow, Home, and ⌘7–⌘9 open the file this format names. Choose one of your existing daily notes and OpenOrg works out the pattern. The format is stored in org2.json as roam.dailyFileTemplate and is shared with this corpus.")
    }
    .disabled(isBusy)
    .task(id: store.corpusRoot?.path) { await load() }
  }

  @ViewBuilder private var summary: some View {
    LabeledContent("Daily notes") {
      Text(savedTemplate ?? "Default: daily/YYYY-MM-DD.org")
        .font(savedTemplate == nil ? .body : .body.monospaced())
        .foregroundStyle(savedTemplate == nil ? .secondary : .primary)
        .textSelection(.enabled)
    }
    HStack {
      Button("Choose Example Note…") { chooseExample() }
      Button("Edit Format…") {
        draft = savedTemplate ?? ""
        candidates = []
        example = nil
        isEditing = true
        saved = false
      }
      if savedTemplate != nil {
        Button("Use Default") { Task { await save(nil) } }
      }
      Spacer()
      if isBusy { ProgressView().controlSize(.small) }
      if saved { Label("Saved", systemImage: "checkmark").foregroundStyle(.secondary) }
    }
  }

  @ViewBuilder private var editor: some View {
    if let example {
      LabeledContent("Example") {
        Text(example).font(.callout.monospaced()).textSelection(.enabled)
      }
    }
    if candidates.count > 1 {
      Picker("Pattern", selection: $draft) {
        ForEach(candidates, id: \.template) { candidate in
          Text("\(candidate.template)  (\(candidate.date))")
            .font(.callout.monospaced())
            .tag(candidate.template)
        }
        if !candidates.contains(where: { $0.template == draft }) {
          Text("Custom").tag(draft)
        }
      }
      .pickerStyle(.radioGroup)
    }
    TextField("Format", text: $draft, prompt: Text("journal/{YYYY}/{MM}/{YYYY}-{MM}-{DD}.md"))
      .font(.body.monospaced())
      .accessibilityLabel("Daily note format")
    if let problem = DailyNoteTemplate.problem(draft) {
      Text(problem).font(.callout).foregroundStyle(.secondary)
    } else if let template = DailyNoteTemplate(draft), let root = store.corpusRoot {
      DailyNoteFormatPreview(template: template, corpusRoot: root)
      if !template.template.contains("{YYYY}") && !template.template.contains("{YY}") {
        Text("This format has no year, so the same file is used for a given day every year.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    Text("Tokens: {YYYY} {YY} {MM} {M} {DD} {D} {MMM} {MMMM} {ddd} {dddd}")
      .font(.caption.monospaced())
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
    HStack {
      Button("Choose Another Example…") { chooseExample() }
      Spacer()
      if isBusy { ProgressView().controlSize(.small) }
      Button("Cancel") {
        isEditing = false
        error = nil
      }
      Button("Save Format") { Task { await save(draft) } }
        .buttonStyle(.borderedProminent)
        .disabled(revision == nil || DailyNoteTemplate(draft) == nil)
    }
  }

  @MainActor private func load() async {
    guard let root = store.corpusRoot else {
      revision = nil
      savedTemplate = nil
      return
    }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      let config: DailyNoteConfiguration = try await store.cli.runJSON(
        ["daily-config", "show", "--dir", root.path]
      )
      guard store.corpusRoot == root, !Task.isCancelled else { return }
      revision = config.revision
      savedTemplate = config.template
      if let problem = config.problem {
        error = "The saved format is not used: \(problem)"
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  @MainActor private func chooseExample() {
    guard let root = store.corpusRoot else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose a Daily Note"
    panel.message = "Choose one of your existing daily notes. OpenOrg uses its name and folder to find the others."
    panel.prompt = "Use This Note"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = root
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await infer(from: url, root: root) }
  }

  @MainActor private func infer(from url: URL, root: URL) async {
    isBusy = true
    error = nil
    saved = false
    defer { isBusy = false }
    do {
      let inference: DailyNoteTemplateInference = try await store.cli.runJSON(
        ["daily-config", "infer", "--dir", root.path, "--file", url.standardizedFileURL.path]
      )
      guard store.corpusRoot == root else { return }
      revision = inference.revision
      example = inference.example
      candidates = inference.candidates
      draft = inference.candidates.first?.template ?? inference.example
      isEditing = true
      if inference.candidates.isEmpty {
        error = "OpenOrg could not find a date in \(inference.example). Edit the format and add date tokens where the date appears."
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  @MainActor private func save(_ template: String?) async {
    guard let root = store.corpusRoot, let revision else { return }
    isBusy = true
    error = nil
    saved = false
    defer { isBusy = false }
    do {
      var arguments = ["daily-config", "set", "--dir", root.path, "--if-revision", revision]
      if let template {
        arguments += ["--template", template.trimmingCharacters(in: .whitespacesAndNewlines)]
      } else {
        arguments.append("--clear")
      }
      let result: DailyNoteConfiguration = try await store.cli.runJSON(arguments + ["--apply"])
      guard store.corpusRoot == root else { return }
      self.revision = result.revision
      savedTemplate = result.template
      isEditing = false
      saved = true
      store.reloadDailyNoteConfiguration()
      onSaved?()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// Resolved yesterday/today/tomorrow paths for a draft format, checked
/// against the corpus so the user can see whether the pattern finds files.
struct DailyNoteFormatPreview: View {
  let template: DailyNoteTemplate
  let corpusRoot: URL
  @State private var rows: [Row] = []

  struct Row: Hashable {
    let label: String
    let relativePath: String
    let exists: Bool
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(rows, id: \.label) { row in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: row.exists ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(row.exists ? Color.green : Color.secondary)
            .accessibilityLabel(row.exists ? "Exists" : "Not created yet")
          Text(row.label).frame(width: 80, alignment: .leading)
          Text(row.relativePath)
            .font(.callout.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
    }
    .task(id: template) {
      let template = template
      let root = corpusRoot
      rows = await Task.detached(priority: .userInitiated) {
        Self.rows(template: template, corpusRoot: root)
      }.value
    }
  }

  nonisolated static func rows(template: DailyNoteTemplate, corpusRoot: URL, now: Date = Date()) -> [Row] {
    let calendar = Calendar(identifier: .gregorian)
    return [("Yesterday", -1), ("Today", 0), ("Tomorrow", 1)].map { label, offset in
      let date = calendar.date(byAdding: .day, value: offset, to: now) ?? now
      let url = template.url(for: date, corpusRoot: corpusRoot)
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
      return Row(label: label, relativePath: template.relativePath(for: date), exists: exists)
    }
  }
}

/// Sheet form of the format settings, offered where a daily note is missing.
struct DailyNoteFormatSheet: View {
  @Binding var isPresented: Bool
  let onSaved: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Daily Note Format")
        .font(.title2.weight(.semibold))
      Text("Point OpenOrg at one of your existing daily notes so Today, Yesterday, and Tomorrow open your own files.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Form {
        DailyNoteFormatSettingsSection {
          isPresented = false
          onSaved()
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Done") { isPresented = false }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 620, height: 520)
  }
}
