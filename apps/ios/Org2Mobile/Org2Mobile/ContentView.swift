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
  @State private var approvingID: ApprovalEntry.ID?
  @State private var rejection: ApprovalEntry?

  var body: some View {
    NavigationStack {
      List(store.approvals) { item in
        Button {
          selected = item
        } label: {
          ApprovalRow(item: item, isApproving: approvingID == item.id)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
          Button {
            Task { await approve(item) }
          } label: {
            Label(approvingID == item.id ? "Approving" : "Approve", systemImage: approvingID == item.id ? "hourglass" : "checkmark")
          }
          .tint(.green)
          .disabled(approvingID != nil)

          Button(role: .destructive) {
            rejection = item
          } label: {
            Label("Reject", systemImage: "xmark")
          }
          .disabled(approvingID != nil)
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
        ApprovalDetailView(
          item: item,
          isApproving: approvingID == item.id,
          approve: { await approve(item) },
          onReject: { rejection = item }
        ) { text in
          shareText = text
        }
      }
      .sheet(item: $rejection) { item in
        RejectApprovalView(item: item)
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

  @MainActor
  private func approve(_ item: ApprovalEntry) async {
    guard approvingID == nil else { return }
    approvingID = item.id
    await store.approve(item)
    if approvingID == item.id {
      approvingID = nil
    }
  }
}

private struct ApprovalRow: View {
  let item: ApprovalEntry
  let isApproving: Bool

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

      if isApproving {
        HStack(spacing: 6) {
          MobileActivityIndicator(style: .approval, tint: .green, label: "Approving")
          Text("Approving...")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.green)
      }
    }
    .padding(.vertical, 6)
  }
}

private struct ApprovalDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: CorpusStore
  let item: ApprovalEntry
  let isApproving: Bool
  let approve: () async -> Void
  let onReject: () -> Void
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

        Section("Entry") {
          ForEach(metadataRows) { row in
            ApprovalMetadataRow(row: row)
          }
        }

        Section("Properties") {
          if sortedProperties.isEmpty {
            Text("No properties")
              .foregroundStyle(.secondary)
          } else {
            ForEach(sortedProperties, id: \.key) { property in
              ApprovalPropertyRow(key: property.key, value: property.value)
            }
          }
        }

        if !item.body.isEmpty {
          Section("Body") {
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
              await approve()
              dismiss()
            }
          } label: {
            if isApproving {
              HStack(spacing: 8) {
                MobileActivityIndicator(style: .approval, tint: .white, label: "Approving")
                Text("Approving...")
              }
              .frame(maxWidth: .infinity)
            } else {
              Label("Approve", systemImage: "checkmark.seal")
                .frame(maxWidth: .infinity)
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isApproving)

          Button(role: .destructive) {
            dismiss()
            onReject()
          } label: {
            Label("Reject", systemImage: "xmark.octagon")
              .frame(maxWidth: .infinity)
          }

          Button {
            openWhatsApp(text: item.whatsappText) {
              fallbackShare(item.whatsappText)
            }
          } label: {
            Label("WhatsApp", systemImage: "message")
              .frame(maxWidth: .infinity)
          }
          .disabled(isApproving)

          Button {
            Task {
              await store.sendToOpenClaw(.discuss, approval: item, message: message)
              dismiss()
            }
          } label: {
            Label("Discuss via OpenClaw", systemImage: "paperplane")
              .frame(maxWidth: .infinity)
          }
          .disabled(isApproving)
        }
      }
      .navigationTitle("Approval")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            dismiss()
          }
          .disabled(isApproving)
        }
      }
      .interactiveDismissDisabled(isApproving)
      .onAppear {
        if message.isEmpty {
          message = "I need to discuss this approval item before deciding."
        }
      }
    }
  }

  private var metadataRows: [ApprovalMetadataRow.Model] {
    [
      ApprovalMetadataRow.Model(label: "Status", value: item.status),
      ApprovalMetadataRow.Model(label: "TODO", value: item.todo),
      ApprovalMetadataRow.Model(label: "Level", value: item.level.map(String.init)),
      ApprovalMetadataRow.Model(label: "Source", value: item.sourceLabel, isMonospaced: true),
      ApprovalMetadataRow.Model(label: "ID", value: item.sourceID, isMonospaced: true),
      ApprovalMetadataRow.Model(label: "Tags", value: item.tags.isEmpty ? nil : item.tags.map { ":\($0):" }.joined(separator: " ")),
    ].compactMap { $0 }
  }

  private var sortedProperties: [(key: String, value: String)] {
    item.properties.sorted {
      $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
    }
  }
}

private struct RejectApprovalView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: CorpusStore
  let item: ApprovalEntry
  @State private var endStatus: OrgTodoStatus = .canceled
  @State private var reason = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(item.title.prettyPrintedOrgLinks())
            .font(.headline)
          Text(item.sourceLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Section("End Status") {
          Picker("End Status", selection: $endStatus) {
            Text("Canceled").tag(OrgTodoStatus.canceled)
            Text("Done").tag(OrgTodoStatus.done)
          }
          .pickerStyle(.segmented)
        }

        Section("Reason") {
          TextEditor(text: $reason)
            .frame(minHeight: 120)
        }

        Section {
          Button(role: .destructive) {
            Task {
              await store.reject(item, endStatus: endStatus, reason: reason)
              dismiss()
            }
          } label: {
            Label("Reject", systemImage: "xmark.octagon")
              .frame(maxWidth: .infinity)
          }
          .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .navigationTitle("Reject Approval")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
    }
  }
}

private struct ApprovalMetadataRow: View {
  struct Model: Identifiable {
    let label: String
    let value: String
    let isMonospaced: Bool

    var id: String { label }

    init?(label: String, value: String?, isMonospaced: Bool = false) {
      guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
      }
      self.label = label
      self.value = value
      self.isMonospaced = isMonospaced
    }
  }

  let row: Model

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(row.label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      if row.isMonospaced {
        Text(row.value.prettyPrintedOrgLinks())
          .font(.caption.monospaced())
          .textSelection(.enabled)
      } else {
        Text(row.value.prettyPrintedOrgLinks())
          .font(.body)
          .textSelection(.enabled)
      }
    }
    .padding(.vertical, 2)
  }
}

private struct ApprovalPropertyRow: View {
  let key: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(key)
        .font(.caption.weight(.semibold).monospaced())
        .foregroundStyle(.secondary)
      Text(value.prettyPrintedOrgLinks())
        .font(.body)
        .textSelection(.enabled)
    }
    .padding(.vertical, 3)
  }
}

private struct NewNoteView: View {
  @EnvironmentObject private var store: CorpusStore
  @State private var title = ""
  @State private var bodyText = ""
  @State private var schedule: MobileNoteSchedule = .none
  @State private var customScheduledDate = Date()
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
                MobileActivityIndicator(style: .sync, label: "Updating corpus")
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

          VStack(alignment: .leading, spacing: 10) {
            Text("Schedule TODO")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
              ForEach(MobileNoteSchedule.allCases) { option in
                Button {
                  schedule = option
                } label: {
                  Label(option.title, systemImage: option.systemImage)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(schedule == option ? .accentColor : .secondary)
              }
            }

            if schedule == .custom {
              DatePicker(
                "Date",
                selection: $customScheduledDate,
                displayedComponents: .date
              )
            } else if let date = scheduledDate {
              Label(MobileCaptureWriter.orgDayTimestamp(date), systemImage: "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)

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
              await store.saveMobileNote(
                title: title,
                body: bodyText,
                attachments: attachments,
                scheduledDate: scheduledDate
              )
              title = ""
              bodyText = ""
              schedule = .none
              customScheduledDate = Date()
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

          Text("Queues this note in mobile-inbox.org2 so desktop sync can merge it safely.")
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

  private var scheduledDate: Date? {
    schedule.scheduledDate(customDate: customScheduledDate)
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
        MobileActivityIndicator(style: .sync, label: "Refreshing")
      } else {
        Image(systemName: "arrow.clockwise")
      }
    }
    .disabled(store.isPreparingCorpus || store.isLoading)
  }
}

private struct LoadingCorpusView: View {
  var body: some View {
    VStack(spacing: 12) {
      MobileShimmerLines()
      Text("Loading corpus")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding()
  }
}

private enum MobileActivityStyle: Equatable {
  case sync
  case approval
}

private struct MobileActivityIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let style: MobileActivityStyle
  var tint: Color = .accentColor
  var label = "Loading"

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
      let phase = reduceMotion
        ? 0.2
        : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.15) / 1.15

      HStack(alignment: .center, spacing: style == .approval ? 2.5 : 2) {
        ForEach(0..<3, id: \.self) { index in
          let value = wave(phase, index: index)
          activityMark(value: value)
          .frame(
            width: style == .approval ? 3.5 : 2.5,
            height: style == .approval ? 3.5 : 4 + value * 8
          )
          .offset(y: style == .approval ? -value * 2.5 : 0)
        }
      }
    }
    .frame(width: 18, height: 14)
    .accessibilityLabel(label)
  }

  private func wave(_ phase: Double, index: Int) -> CGFloat {
    let angle = phase * 2 * Double.pi - Double(index) * 0.9
    return CGFloat((sin(angle) + 1) / 2)
  }

  @ViewBuilder
  private func activityMark(value: CGFloat) -> some View {
    if style == .approval {
      Circle().fill(tint.opacity(0.35 + Double(value) * 0.65))
    } else {
      Capsule().fill(tint.opacity(0.35 + Double(value) * 0.65))
    }
  }
}

private struct MobileShimmerLines: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
      let phase = reduceMotion
        ? 0.45
        : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.55) / 1.55

      VStack(alignment: .leading, spacing: 7) {
        line(width: 118, phase: phase)
        line(width: 88, phase: phase)
        line(width: 104, phase: phase)
      }
    }
    .accessibilityHidden(true)
  }

  private func line(width: CGFloat, phase: Double) -> some View {
    RoundedRectangle(cornerRadius: 4, style: .continuous)
      .fill(Color.secondary.opacity(0.12))
      .frame(width: width, height: 8)
      .overlay(alignment: .leading) {
        LinearGradient(
          colors: [.clear, Color.accentColor.opacity(0.28), .clear],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: 50)
        .offset(x: (width + 50) * CGFloat(phase) - 50)
      }
      .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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
