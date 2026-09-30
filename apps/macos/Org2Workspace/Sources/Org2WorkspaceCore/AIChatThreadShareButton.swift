import AppKit
import SwiftUI

/// Header control that shares the selected AI chat thread as a live,
/// read-only local link, mirroring Publish → Local Link for documents.
struct AIChatThreadShareButton: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var isPresented = false

  var body: some View {
    let threadID = store.selectedOpenClawChatThreadID
    let isShared = threadID.flatMap(store.chatThreadPublication(for:)) != nil
    Button {
      isPresented.toggle()
    } label: {
      Label(isShared ? "Shared" : "Share", systemImage: isShared ? "link.circle.fill" : "square.and.arrow.up")
    }
    .help(isShared ? "This thread has a live local link" : "Share this thread as a live local link")
    .disabled(threadID == nil || store.openClawMessages.isEmpty && !isShared)
    .accessibilityIdentifier("ai-chat-share-thread")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      if let threadID {
        AIChatThreadSharePopover(threadID: threadID)
      }
    }
  }
}

struct AIChatThreadSharePopover: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var errorText: String?
  @State private var copied = false
  let threadID: UUID

  var body: some View {
    let publication = store.chatThreadPublication(for: threadID)
    let isBusy = store.isPublishingChatThread(threadID)
    VStack(alignment: .leading, spacing: 12) {
      Label("Share Thread", systemImage: "link")
        .font(.headline)

      if let publication {
        Text("Anyone with this link on your network can read this thread. New messages appear automatically.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Text(publication.url.absoluteString)
          .font(.callout.monospaced())
          .lineLimit(2)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

        HStack {
          Button(role: .destructive) {
            store.stopSharingChatThread(threadID)
          } label: {
            Text("Stop Sharing")
          }
          Spacer()
          Button("Open") {
            NSWorkspace.shared.open(publication.openURL)
          }
          Button {
            OpenClawMessageClipboard.write(publication.url.absoluteString)
            copied = true
          } label: {
            Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        }
      } else {
        Text("Create a read-only link that anyone on your local network can open in a browser. It uses your OpenOrg theme and shows new messages as they arrive.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Text("Attached context, reasoning, and tool activity are not included.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Spacer()
          Button {
            Task { await share() }
          } label: {
            if isBusy {
              HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Creating Link")
              }
            } else {
              Text("Create Link")
            }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(isBusy)
        }
      }

      if let errorText {
        Text(errorText)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      Label("Local links use unencrypted HTTP. Share them only on a trusted network.", systemImage: "lock.open")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(width: 360)
  }

  private func share() async {
    errorText = nil
    do {
      let publication = try await store.publishChatThread(threadID)
      OpenClawMessageClipboard.write(publication.url.absoluteString)
      copied = true
    } catch {
      errorText = error.localizedDescription
    }
  }
}
