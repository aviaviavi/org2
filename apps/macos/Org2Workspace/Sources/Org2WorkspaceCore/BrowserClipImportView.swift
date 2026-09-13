import AppKit
import Observation
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

struct BrowserClipImportContext: Equatable, Sendable {
  let root: URL
  let corpusGeneration: UInt64
  let capturePresentationID: UUID
}

@MainActor @Observable
final class BrowserClipImportSession {
  private(set) var preview: BrowserClipImportResult?
  private(set) var template = "note"
  private(set) var error: String?
  private(set) var busy = false
  private(set) var isImporting = false
  private(set) var imported = false
  private var clipURL: URL?
  private var previewContext: BrowserClipImportContext?
  private var generation: UInt64 = 0
  private var isOpen = true
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored var commandForTesting: (@MainActor ([String]) async throws -> BrowserClipImportResult)?
  var operationForTesting: Task<Void, Never>? { operation }

  func chooseClip(_ url: URL, store: WorkspaceStore) {
    guard isOpen, !isImporting else { return }
    clipURL = url
    loadPreview(store: store, useClipTemplate: true)
  }

  func selectTemplate(_ value: String, store: WorkspaceStore) {
    guard isOpen, !busy, template != value else { return }
    template = value
    loadPreview(store: store, useClipTemplate: false)
  }

  func close() {
    isOpen = false
    generation &+= 1
    operation?.cancel()
    operation = nil
    busy = false
    isImporting = false
  }

  private func isCurrent(_ request: UInt64, context: BrowserClipImportContext, store: WorkspaceStore) -> Bool {
    isOpen && !Task.isCancelled && generation == request && store.browserClipImportContext == context
  }

  private func finish(_ request: UInt64) {
    guard generation == request else { return }
    busy = false
    isImporting = false
    operation = nil
  }

  private func run(_ arguments: [String], store: WorkspaceStore) async throws -> BrowserClipImportResult {
    if let commandForTesting { return try await commandForTesting(arguments) }
    return try await store.cli.runJSON(arguments)
  }

  private func loadPreview(store: WorkspaceStore, useClipTemplate: Bool) {
    guard let clipURL, let context = store.browserClipImportContext else { return }
    operation?.cancel()
    generation &+= 1
    let request = generation
    busy = true
    imported = false
    error = nil
    preview = nil
    previewContext = nil
    let arguments = ["browser-clip", "import", "--file", clipURL.path, "--dir", context.root.path, "--json"]
      + (useClipTemplate ? [] : ["--template", template])
    operation = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.finish(request) }
      do {
        let result = try await self.run(arguments, store: store)
        guard self.isCurrent(request, context: context, store: store) else { return }
        self.template = result.clip.template
        self.previewContext = context
        self.preview = result
      } catch {
        guard self.isCurrent(request, context: context, store: store) else { return }
        self.error = error.localizedDescription
      }
    }
  }

  func importClip(store: WorkspaceStore, onImported: @escaping @MainActor (BrowserClipImportResult) -> Void) {
    guard isOpen, !busy, !imported else { return }
    guard let clipURL, let preview, !preview.duplicate,
          let context = previewContext, context == store.browserClipImportContext
    else {
      error = "The active corpus or Capture window changed. Choose the clip again."
      return
    }
    guard !store.hasActiveEdit && !store.liveFileEditorHasUnsavedChanges else {
      error = "Save or cancel the open source edit before importing."
      return
    }
    generation &+= 1
    let request = generation
    busy = true
    isImporting = true
    error = nil
    // Apply exactly the template and revisions returned by the reviewed preview.
    let arguments = [
      "browser-clip", "import", "--file", clipURL.path, "--dir", context.root.path,
      "--template", preview.clip.template, "--if-revision", preview.revision,
      "--if-clip-revision", preview.clipRevision, "--apply", "--json"
    ]
    operation = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.finish(request) }
      guard self.isCurrent(request, context: context, store: store) else { return }
      guard !store.hasActiveEdit && !store.liveFileEditorHasUnsavedChanges else {
        self.error = "Save or cancel the open source edit before importing."
        return
      }
      do {
        let result = try await self.run(arguments, store: store)
        guard self.isCurrent(request, context: context, store: store) else { return }
        self.imported = true
        await store.refreshCorpusFiles()
        guard self.isCurrent(request, context: context, store: store) else { return }
        guard !store.hasActiveEdit && !store.liveFileEditorHasUnsavedChanges else {
          self.error = "Clip imported to views/browser-clips.org. Finish the current source edit before opening it."
          return
        }
        store.openChatFileReference(.init(path: result.file, line: result.headingLine))
        onImported(result)
      } catch {
        guard self.isCurrent(request, context: context, store: store) else { return }
        self.error = error.localizedDescription
      }
    }
  }

  func waitForOperationForTesting() async {
    await operation?.value
  }
}

struct BrowserClipImportView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var session = BrowserClipImportSession()
  var onImported: @MainActor (BrowserClipImportResult) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Import Browser Clip", systemImage: "globe")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("Choose Clip…", action: chooseClip).disabled(session.busy)
      }
      Text("Choose an .org2clip file saved by the OpenOrg Web Clipper.")
        .foregroundStyle(.secondary)
      if let preview = session.preview {
        Text(preview.clip.title).font(.title3.weight(.semibold))
        Text(preview.clip.url).font(.caption).textSelection(.enabled)
        Text("\(preview.clip.author ?? "Unknown author") · \(preview.clip.mode.capitalized) · \(preview.clip.capturedAt)")
          .font(.caption).foregroundStyle(.secondary)
        Picker("Template", selection: Binding(
          get: { session.template },
          set: { session.selectTemplate($0, store: store) }
        )) {
          Text("Reading note").tag("note")
          Text("Read later task").tag("task")
        }.disabled(session.busy || session.imported)
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
      if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        if session.busy { ProgressView().controlSize(.small) }
        Spacer()
        Button("Cancel") { session.close(); dismiss() }
          .keyboardShortcut(.cancelAction).disabled(session.isImporting)
        Button("Import") {
          session.importClip(store: store) { result in
            onImported(result)
            dismiss()
          }
        }
          .buttonStyle(.borderedProminent)
          .disabled(session.preview == nil || session.preview?.duplicate == true || session.busy || session.imported || store.hasActiveEdit || store.liveFileEditorHasUnsavedChanges)
      }
    }.padding(24).frame(width: 660, height: 620)
      .interactiveDismissDisabled(session.isImporting)
      .onDisappear { session.close() }
  }

  private func chooseClip() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [UTType(filenameExtension: "org2clip") ?? .data, .json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    session.chooseClip(url, store: store)
  }
}
