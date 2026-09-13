import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserClipImportResult: Decodable, Sendable {
  struct Clip: Decodable, Sendable {
    let title: String
    let url: String
    let author: String?
    let capturedAt: String
    let mode: String
    let template: String
    let content: String
  }
  let clip: Clip
  let file: String
  let revision: String
  let clipRevision: String
  let duplicate: Bool
  let entryText: String
  let headingLine: Int
}

struct BrowserClipImportView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var clipURL: URL?
  @State private var preview: BrowserClipImportResult?
  @State private var template = "note"
  @State private var error: String?
  @State private var busy = false
  @State private var previewRoot: URL?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Import Browser Clip", systemImage: "globe")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("Choose Clip…", action: chooseClip).disabled(busy)
      }
      Text("Choose an .org2clip file saved by the OpenOrg Web Clipper.")
        .foregroundStyle(.secondary)
      if let preview {
        Text(preview.clip.title).font(.title3.weight(.semibold))
        Text(preview.clip.url).font(.caption).textSelection(.enabled)
        Text("\(preview.clip.author ?? "Unknown author") · \(preview.clip.mode.capitalized) · \(preview.clip.capturedAt)")
          .font(.caption).foregroundStyle(.secondary)
        Picker("Template", selection: $template) {
          Text("Reading note").tag("note")
          Text("Read later task").tag("task")
        }.disabled(busy).onChange(of: template) { _, _ in Task { await loadPreview() } }
        ScrollView {
          Text(preview.clip.content).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        Text(preview.duplicate ? "This clip is already imported." : "Saves to views/browser-clips.org with an immutable source copy in raw/browser.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        ContentUnavailableView("Bring a page into your workspace", systemImage: "doc.badge.arrow.up", description: Text("In your browser, capture an article or selection and save the clip. Its source and capture time travel with it."))
      }
      if store.hasActiveEdit || store.liveFileEditorHasUnsavedChanges {
        Text("Save or cancel the open source edit before importing.").foregroundStyle(.orange)
      }
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        if busy { ProgressView().controlSize(.small) }
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Import") { Task { await importClip() } }
          .buttonStyle(.borderedProminent)
          .disabled(preview == nil || preview?.duplicate == true || busy || store.hasActiveEdit || store.liveFileEditorHasUnsavedChanges)
      }
    }.padding(24).frame(width: 660, height: 620)
  }

  private func chooseClip() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [UTType(filenameExtension: "org2clip") ?? .data, .json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    clipURL = url
    Task { await loadPreview(useClipTemplate: true) }
  }

  private func loadPreview(useClipTemplate: Bool = false) async {
    guard let clipURL, let root = store.corpusRoot else { return }
    busy = true
    error = nil
    preview = nil
    defer { busy = false }
    do {
      let arguments = ["browser-clip", "import", "--file", clipURL.path, "--dir", root.path, "--json"]
        + (useClipTemplate ? [] : ["--template", template])
      let result: BrowserClipImportResult = try await store.cli.runJSON(arguments)
      if useClipTemplate { template = result.clip.template }
      previewRoot = root
      preview = result
    } catch { self.error = error.localizedDescription }
  }

  private func importClip() async {
    guard let clipURL, let preview, let root = previewRoot, root == store.corpusRoot else {
      error = "The active corpus changed. Choose the clip again."
      return
    }
    guard !store.hasActiveEdit && !store.liveFileEditorHasUnsavedChanges else {
      error = "Save or cancel the open source edit before importing."
      return
    }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let result: BrowserClipImportResult = try await store.cli.runJSON([
        "browser-clip", "import", "--file", clipURL.path, "--dir", root.path,
        "--template", template, "--if-revision", preview.revision, "--if-clip-revision", preview.clipRevision, "--apply", "--json"
      ])
      guard root == store.corpusRoot else { return }
      await store.refreshCorpusFiles()
      store.openChatFileReference(.init(path: result.file, line: result.headingLine))
      store.isCapturePanelPresented = false
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
