import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
  @EnvironmentObject private var store: CorpusStore

  var body: some View {
    Group {
      if store.rootURL == nil {
        EmptyCorpusView()
      } else {
        WorkspaceTabs()
      }
    }
    .sheet(isPresented: $store.isDocumentPickerPresented) {
      CorpusFolderPicker { url in
        Task { await store.selectCorpus(url) }
      }
    }
    .alert("Org2", isPresented: Binding(get: { store.errorMessage != nil }, set: { _ in store.errorMessage = nil })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(store.errorMessage ?? "")
    }
  }
}

private struct EmptyCorpusView: View {
  @EnvironmentObject private var store: CorpusStore

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Image(systemName: "tray.full")
          .font(.system(size: 56))
          .foregroundStyle(.secondary)

        VStack(spacing: 8) {
          Text("Org2")
            .font(.largeTitle.weight(.semibold))
          Text("Select a synced corpus folder from Files.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        Button {
          store.isDocumentPickerPresented = true
        } label: {
          Label("Select Corpus", systemImage: "folder")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
      .padding(24)
      .navigationTitle("Org2")
    }
  }
}

private struct WorkspaceTabs: View {
  @State private var selection: WorkspaceTab = .initialSelection

  var body: some View {
    TabView(selection: $selection) {
      NewNoteView()
        .tabItem { Label("New Note", systemImage: "square.and.pencil") }
        .tag(WorkspaceTab.newNote)

      AgendaView()
        .tabItem { Label("Agenda", systemImage: "calendar") }
        .tag(WorkspaceTab.agenda)

      ApprovalsView()
        .tabItem { Label("Approvals", systemImage: "checkmark.seal") }
        .tag(WorkspaceTab.approvals)
    }
  }
}

private enum WorkspaceTab: Hashable {
  case newNote
  case agenda
  case approvals

  static var initialSelection: WorkspaceTab {
    #if DEBUG
    switch ProcessInfo.processInfo.environment["ORG2_DEBUG_INITIAL_TAB"]?.lowercased() {
    case "agenda":
      return .agenda
    case "approvals":
      return .approvals
    default:
      return .newNote
    }
    #else
    return .newNote
    #endif
  }
}

private struct AgendaView: View {
  @EnvironmentObject private var store: CorpusStore

  private var overdue: [AgendaEntry] {
    store.agenda.filter(\.isOverdue)
  }

  private var today: [AgendaEntry] {
    store.agenda.filter { $0.date == Date.org2TodayString }
  }

  private var upcoming: [AgendaEntry] {
    store.agenda.filter { !$0.isOverdue && $0.date != Date.org2TodayString }
  }

  var body: some View {
    NavigationStack {
      List {
        AgendaSection(title: "Today", entries: today)
        AgendaSection(title: "Overdue", entries: overdue)
        AgendaSection(title: "Upcoming", entries: upcoming)
      }
      .overlay {
        if store.agenda.isEmpty && !store.isLoading {
          ContentUnavailableView("No Agenda Items", systemImage: "calendar")
        }
      }
      .navigationTitle("Agenda")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          RefreshButton()
        }
      }
      .refreshable {
        await store.refresh()
      }
    }
  }
}

private struct AgendaSection: View {
  let title: String
  let entries: [AgendaEntry]

  var body: some View {
    if !entries.isEmpty {
      Section(title) {
        ForEach(entries) { entry in
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              StatusPill(entry.todo)
              Text(entry.title.prettyPrintedOrgLinks())
                .font(.body.weight(.medium))
                .lineLimit(2)
            }
            HStack(spacing: 8) {
              Label(entry.date, systemImage: entry.kind == .deadline ? "flag" : "calendar")
              Text(entry.file)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }
      }
    }
  }
}

private struct ApprovalsView: View {
  @EnvironmentObject private var store: CorpusStore
  @State private var selected: ApprovalEntry?
  @State private var shareText: String?

  var body: some View {
    NavigationStack {
      List(store.approvals) { item in
        Button {
          selected = item
        } label: {
          ApprovalRow(item: item)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
          Button {
            Task { await store.sendToOpenClaw(.approve, approval: item) }
          } label: {
            Label("Approve", systemImage: "checkmark")
          }
          .tint(.green)
        }
        .swipeActions(edge: .trailing) {
          Button {
            openWhatsApp(text: item.whatsappText) {
              shareText = item.whatsappText
            }
          } label: {
            Label("WhatsApp", systemImage: "message")
          }
          .tint(.teal)

          Button {
            Task { await store.sendToOpenClaw(.discuss, approval: item) }
          } label: {
            Label("Discuss", systemImage: "paperplane")
          }
          .tint(.blue)
        }
      }
      .overlay {
        if store.approvals.isEmpty && !store.isLoading {
          ContentUnavailableView("No Approvals", systemImage: "checkmark.seal")
        }
      }
      .navigationTitle("Approvals")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          RefreshButton()
        }
      }
      .refreshable {
        await store.refresh()
      }
      .sheet(item: $selected) { item in
        ApprovalDetailView(item: item) { text in
          shareText = text
        }
      }
      .sheet(item: Binding(
        get: { shareText.map(SharePayload.init(text:)) },
        set: { _ in shareText = nil }
      )) { payload in
        ActivitySheet(items: [payload.text])
      }
    }
  }
}

private struct ApprovalRow: View {
  let item: ApprovalEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        StatusPill(item.status)
        Text(item.title.prettyPrintedOrgLinks())
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)
      }

      if !item.body.isEmpty {
        Text(item.body.trimmedForDisplay(maxCharacters: 180))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      Text(item.sourceLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.vertical, 6)
  }
}

private struct ApprovalDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: CorpusStore
  let item: ApprovalEntry
  let fallbackShare: (String) -> Void
  @State private var message: String = ""

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            StatusPill(item.status)
            Text(item.title.prettyPrintedOrgLinks())
              .font(.title3.weight(.semibold))
            Text(item.sourceLabel)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .padding(.vertical, 4)
        }

        if !item.body.isEmpty {
          Section("Draft") {
            Text(item.body.prettyPrintedOrgLinks())
              .font(.body)
              .textSelection(.enabled)
          }
        }

        Section("Message to OpenClaw") {
          TextEditor(text: $message)
            .frame(minHeight: 96)
        }

        Section {
          Button {
            Task {
              await store.sendToOpenClaw(.approve, approval: item, message: message)
              dismiss()
            }
          } label: {
            Label("Approve via OpenClaw", systemImage: "checkmark.seal")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)

          Button {
            openWhatsApp(text: item.whatsappText) {
              fallbackShare(item.whatsappText)
            }
          } label: {
            Label("WhatsApp", systemImage: "message")
              .frame(maxWidth: .infinity)
          }

          Button {
            Task {
              await store.sendToOpenClaw(.discuss, approval: item, message: message)
              dismiss()
            }
          } label: {
            Label("Discuss via OpenClaw", systemImage: "paperplane")
              .frame(maxWidth: .infinity)
          }
        }
      }
      .navigationTitle("Approval")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .onAppear {
        if message.isEmpty {
          message = "Please review this approval item with me before taking action."
        }
      }
    }
  }
}

private struct NewNoteView: View {
  @EnvironmentObject private var store: CorpusStore
  @State private var title = ""
  @State private var bodyText = ""
  @State private var attachments: [NoteAttachment] = []
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var isCameraPresented = false

  var body: some View {
    NavigationStack {
      List {
        Section("Corpus") {
          HStack {
            Label(store.corpusName, systemImage: "folder")
            Spacer()
            Button("Change") {
              store.isDocumentPickerPresented = true
            }
          }

          if let status = store.statusMessage {
            Text(status)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Section("New Note") {
          TextField("Title", text: $title)
          TextEditor(text: $bodyText)
            .frame(minHeight: 120)

          if !attachments.isEmpty {
            ForEach(attachments) { attachment in
              HStack {
                Label(attachment.filename, systemImage: "photo")
                  .lineLimit(1)
                  .truncationMode(.middle)
                Spacer()
                Button {
                  attachments.removeAll { $0.id == attachment.id }
                } label: {
                  Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
              }
            }
          }

          HStack {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
              Label("Photo", systemImage: "photo")
            }

            Spacer()

            Button {
              isCameraPresented = true
            } label: {
              Label("Camera", systemImage: "camera")
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
          }

          Button {
            Task {
              await store.saveDailyNote(title: title, body: bodyText, attachments: attachments)
              title = ""
              bodyText = ""
              attachments = []
            }
          } label: {
            Label("Save Note", systemImage: "square.and.arrow.down")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && attachments.isEmpty
          )

          Text("Appends this note directly to today's daily note in the selected corpus.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("New Note")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          RefreshButton()
        }
      }
      .refreshable {
        await store.refresh()
      }
      .sheet(isPresented: $isCameraPresented) {
        CameraPicker { image in
          addImage(image)
        }
      }
      .onChange(of: selectedPhotoItem) { _, item in
        Task { await addPhoto(item) }
      }
    }
  }

  @MainActor
  private func addPhoto(_ item: PhotosPickerItem?) async {
    guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
    addImageData(data)
    selectedPhotoItem = nil
  }

  private func addImage(_ image: UIImage) {
    guard let data = image.jpegData(compressionQuality: 0.86) else { return }
    addImageData(data)
  }

  private func addImageData(_ data: Data) {
    let imageData = UIImage(data: data)?.jpegData(compressionQuality: 0.86) ?? data
    let filename = "photo-\(UUID().uuidString.prefix(8)).jpg"
    attachments.append(NoteAttachment(filename: filename, data: imageData))
  }
}

private struct RefreshButton: View {
  @EnvironmentObject private var store: CorpusStore

  var body: some View {
    Button {
      Task { await store.refresh() }
    } label: {
      Image(systemName: "arrow.clockwise")
    }
    .disabled(store.isLoading)
  }
}

private struct StatusPill: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text.uppercased())
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .foregroundStyle(color)
      .background(color.opacity(0.12), in: Capsule())
      .lineLimit(1)
      .minimumScaleFactor(0.75)
  }

  private var color: Color {
    let normalized = text.lowercased()
    if normalized.contains("review") || normalized.contains("approval") { return .orange }
    if normalized == "approve" || normalized == "approved" { return .green }
    if normalized == "wait" || normalized == "hold" || normalized == "paused" { return .yellow }
    if normalized == "deadline" { return .red }
    return .accentColor
  }
}

private struct SharePayload: Identifiable {
  let text: String
  var id: String { text }
}

@MainActor
private func openWhatsApp(text: String, fallback: @escaping () -> Void) {
  guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
        let url = URL(string: "whatsapp://send?text=\(encoded)") else {
    fallback()
    return
  }

  UIApplication.shared.open(url, options: [:]) { opened in
    if !opened {
      fallback()
    }
  }
}
