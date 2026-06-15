import SwiftUI

public struct GlobalCaptureView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: FocusedField?

  private enum FocusedField {
    case title
    case body
  }

  public init() {}

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Type")
            .foregroundStyle(.secondary)
          Picker("Type", selection: $store.captureDraft.kind) {
            ForEach(WorkspaceCaptureKind.allCases) { kind in
              Text(kind.title).tag(kind)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }

        if store.captureDraft.kind == .task {
          GridRow {
            Text("Status")
              .foregroundStyle(.secondary)
            Picker("Status", selection: $store.captureDraft.todoStatus) {
              ForEach(Self.todoStatuses, id: \.self) { status in
                Text(status.label).tag(status)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
          }
        }

        GridRow {
          Text("Title")
            .foregroundStyle(.secondary)
          TextField("Follow up", text: $store.captureDraft.title)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .title)
        }

        GridRow {
          Text("Priority")
            .foregroundStyle(.secondary)
          HStack(spacing: 10) {
            Picker("Priority", selection: $store.captureDraft.priority) {
              Text("None").tag("")
              Text("A").tag("A")
              Text("B").tag("B")
              Text("C").tag("C")
            }
            .labelsHidden()
            .frame(width: 112)

            TextField("tags", text: $store.captureDraft.tagsText)
              .textFieldStyle(.roundedBorder)
          }
        }

        GridRow {
          Text("Dates")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
              Toggle("Scheduled", isOn: $store.captureDraft.includeScheduled)
              DatePicker(
                "Scheduled date",
                selection: $store.captureDraft.scheduledDate,
                displayedComponents: .date
              )
              .labelsHidden()
              .disabled(!store.captureDraft.includeScheduled)
            }

            HStack(spacing: 10) {
              Toggle("Deadline", isOn: $store.captureDraft.includeDeadline)
              DatePicker(
                "Deadline date",
                selection: $store.captureDraft.deadlineDate,
                displayedComponents: .date
              )
              .labelsHidden()
              .disabled(!store.captureDraft.includeDeadline)
            }
          }
        }

        GridRow {
          Text("Agent")
            .foregroundStyle(.secondary)
          Toggle("Ready for agent", isOn: $store.captureDraft.assignToAgent)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Body")
          .foregroundStyle(.secondary)

        TextEditor(text: $store.captureDraft.body)
          .font(.body)
          .focused($focusedField, equals: .body)
          .frame(minHeight: 120)
          .scrollContentBackground(.hidden)
          .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }

      if !store.captureDraft.attachments.isEmpty {
        attachmentList
      }

      HStack {
        if let root = store.corpusRoot {
          Text(store.relativePath(root.path))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Button("Cancel") {
          store.isCapturePanelPresented = false
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button {
          Task { await store.submitCaptureDraft() }
        } label: {
          Label("Capture", systemImage: "square.and.pencil")
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(store.captureDraft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 660)
    .frame(minHeight: 540)
    .onAppear {
      focusedField = .title
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "square.and.pencil")
        .font(.title2)
        .foregroundStyle(.tint)
      Text("Capture")
        .font(.title3.weight(.semibold))
      Spacer()
      Button {
        store.importPasteboardIntoCaptureDraft()
      } label: {
        Label("Import Clipboard", systemImage: "doc.on.clipboard")
      }
    }
  }

  private var attachmentList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Attachments")
        .foregroundStyle(.secondary)
      VStack(spacing: 0) {
        ForEach(store.captureDraft.attachments) { attachment in
          HStack(spacing: 10) {
            Image(systemName: Self.iconName(for: attachment.kind))
              .foregroundStyle(.secondary)
              .frame(width: 20)
            Text(attachment.name)
              .lineLimit(1)
            Spacer()
            Button {
              store.captureDraft.attachments.removeAll { $0.id == attachment.id }
            } label: {
              Label("Remove", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
          }
          .padding(.vertical, 6)
          if attachment.id != store.captureDraft.attachments.last?.id {
            Divider()
          }
        }
      }
      .padding(.horizontal, 8)
      .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
  }

  private static let todoStatuses: [TodoEditStatus] = [.todo, .inProgress, .done, .canceled]

  private static func iconName(for kind: WorkspaceCaptureAttachmentKind) -> String {
    switch kind {
    case .file:
      return "doc"
    case .image:
      return "photo"
    case .video:
      return "film"
    case .link:
      return "link"
    }
  }
}
