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
        if store.agenda.isEmpty && (store.isPreparingCorpus || store.isLoading) {
          LoadingCorpusView()
        } else if store.agenda.isEmpty {
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
      .onAppear {
        store.prepareCorpusViews()
      }
    }
  }
}

private struct AgendaSection: View {
  @EnvironmentObject private var store: CorpusStore
  let title: String
  let entries: [AgendaEntry]

  var body: some View {
    if !entries.isEmpty {
      Section(title) {
        ForEach(entries) { entry in
          AgendaRow(entry: entry)
            .swipeActions(edge: .leading) {
              Button {
                Task { await store.setTodoStatus(.done, for: entry) }
              } label: {
                Label("Done", systemImage: "checkmark")
              }
              .tint(.green)
            }
            .swipeActions(edge: .trailing) {
              Button {
                Task { await store.setTodoStatus(.wait, for: entry) }
              } label: {
                Label("Wait", systemImage: "pause")
              }
              .tint(.yellow)

              Button {
                Task { await store.setTodoStatus(.todo, for: entry) }
              } label: {
                Label("TODO", systemImage: "circle")
              }
              .tint(.blue)
            }
        }
      }
    }
  }
}

private struct AgendaRow: View {
  @EnvironmentObject private var store: CorpusStore
  let entry: AgendaEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Menu {
          ForEach(OrgTodoStatus.agendaChoices, id: \.rawValue) { status in
            Button {
              Task { await store.setTodoStatus(status, for: entry) }
            } label: {
              Label(status.rawValue, systemImage: status.rawValue == entry.todo ? "checkmark" : "circle")
            }
          }
        } label: {
          StatusPill(entry.todo)
        }
        .buttonStyle(.plain)

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
            Task { await store.approve(item) }
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
        if store.approvals.isEmpty && (store.isPreparingCorpus || store.isLoading) {
          LoadingCorpusView()
        } else if store.approvals.isEmpty {
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
      .onAppear {
        store.prepareCorpusViews()
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
              await store.approve(item)
              dismiss()
            }
          } label: {
            Label("Approve", systemImage: "checkmark.seal")
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
          message = "I need to discuss this approval item before deciding."
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
  @State private var isPhotoLibraryPresented = false
  @State private var isCameraPresented = false
  @FocusState private var focusedField: NewNoteFocusedField?

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
            HStack(spacing: 6) {
              if store.isPreparingCorpus || store.isLoading {
                ProgressView()
                  .controlSize(.small)
              }
              Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        Section("New Note") {
          TextField("Title", text: $title)
            .focused($focusedField, equals: .title)
          TextEditor(text: $bodyText)
            .frame(minHeight: 120)
            .focused($focusedField, equals: .body)

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
            Button {
              isPhotoLibraryPresented = true
            } label: {
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
              focusedField = nil
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
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") {
            focusedField = nil
          }
        }
      }
      .refreshable {
        await store.refresh()
      }
      .sheet(isPresented: $isCameraPresented) {
        ImagePicker(sourceType: .camera) { image in
          addImage(image)
        }
      }
      .sheet(isPresented: $isPhotoLibraryPresented) {
        ImagePicker(sourceType: .photoLibrary) { image in
          addImage(image)
        }
      }
    }
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

private enum NewNoteFocusedField: Hashable {
  case title
  case body
}

private struct RefreshButton: View {
  @EnvironmentObject private var store: CorpusStore

  var body: some View {
    Button {
      Task { await store.refresh() }
    } label: {
      if store.isPreparingCorpus || store.isLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: "arrow.clockwise")
      }
    }
    .disabled(store.isPreparingCorpus || store.isLoading)
  }
}

private struct LoadingCorpusView: View {
  var body: some View {
    VStack(spacing: 10) {
      ProgressView()
      Text("Loading corpus")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding()
  }
}

private struct StatusPill: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(displayText.uppercased())
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .foregroundStyle(color)
      .background(color.opacity(0.12), in: Capsule())
      .lineLimit(1)
      .minimumScaleFactor(0.75)
  }

  private var displayText: String {
    let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized == "review-required"
      || normalized == "requires-review"
      || normalized == "approval-required"
      || normalized == "needs-approval"
      || normalized == "pending-approval"
      || normalized == "approval"
      || normalized.contains("approval")
      || normalized.contains("review") {
      return "Needs Review"
    }
    return text
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
