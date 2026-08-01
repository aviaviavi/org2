import SwiftUI
import VisionKit

struct MobileRemoteRootView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  @State private var path: [UUID] = []

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if remote.isPaired {
          threadList
        } else {
          MobileRemotePairingView()
        }
      }
      .navigationTitle("Remote")
      .navigationDestination(for: UUID.self) { threadID in
        MobileRemoteThreadView(threadID: threadID)
      }
      .toolbar {
        if remote.isPaired {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button {
                createThread(runtime: "codex")
              } label: {
                Label("New Codex Chat", systemImage: "plus.bubble")
              }
              Button {
                createThread(runtime: "openClaw")
              } label: {
                Label("New OpenClaw Chat", systemImage: "plus.bubble")
              }
              Divider()
              Button("Forget This Mac", role: .destructive) {
                path = []
                remote.disconnect()
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
          }
        }
      }
      .task {
        if remote.isPaired {
          await remote.refresh()
        }
      }
    }
    .alert("Mobile Remote", isPresented: Binding(
      get: { remote.errorMessage != nil },
      set: { if !$0 { remote.errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(remote.errorMessage ?? "")
    }
  }

  private var threadList: some View {
    List {
      Section {
        HStack(spacing: 12) {
          Image(systemName: "desktopcomputer")
            .font(.title3)
            .foregroundStyle(.blue)
          VStack(alignment: .leading, spacing: 2) {
            Text(remote.serverName)
              .font(.headline)
            Text(statusSubtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if remote.isRefreshing {
            ProgressView()
              .controlSize(.small)
          } else {
            Circle()
              .fill(remote.isConnected ? Color.green : Color.secondary)
              .frame(width: 8, height: 8)
              .accessibilityLabel(remote.isConnected ? "Connected" : "Mac unavailable")
          }
        }
        .padding(.vertical, 3)
      }

      if !activeThreads.isEmpty {
        Section("Chats") {
          ForEach(activeThreads) { thread in
            NavigationLink(value: thread.id) {
              MobileRemoteThreadRow(thread: thread)
            }
          }
        }
      }

      if !settledThreads.isEmpty {
        Section("Settled") {
          ForEach(settledThreads) { thread in
            NavigationLink(value: thread.id) {
              MobileRemoteThreadRow(thread: thread)
            }
          }
        }
      }
    }
    .overlay {
      if remote.threads.isEmpty && !remote.isRefreshing {
        ContentUnavailableView(
          "No Remote Chats",
          systemImage: "bubble.left.and.bubble.right",
          description: Text("Create a chat here or in Org2 on your Mac.")
        )
      }
    }
    .refreshable {
      await remote.refresh()
    }
  }

  private var activeThreads: [MobileRemoteThreadSummary] {
    remote.threads.filter { !$0.isSettled }
  }

  private var settledThreads: [MobileRemoteThreadSummary] {
    remote.threads.filter(\.isSettled)
  }

  private var statusSubtitle: String {
    guard remote.isConnected else { return "Waiting for Mac over Tailscale" }
    guard let status = remote.status else { return "Connected over Tailscale" }
    let corpus = status.corpusName.map { " • \($0)" } ?? ""
    let running = status.runningThreadCount == 1
      ? "1 chat running"
      : "\(status.runningThreadCount) chats running"
    return "\(running)\(corpus)"
  }

  private func createThread(runtime: String) {
    Task {
      if let id = await remote.createThread(runtime: runtime) {
        path = [id]
      }
    }
  }
}

private struct MobileRemotePairingView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  @State private var isScannerPresented = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 10) {
          Image(systemName: "desktopcomputer")
            .font(.system(size: 48))
            .foregroundStyle(.blue)
          Text("Your Mac, from your phone")
            .font(.title2.weight(.semibold))
          Text("Continue Org2 AI chats while you’re away from your desk. Your Mac stays the executor and source of context.")
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 12) {
          Label("On the Mac, open Org2 Settings → Mobile Remote.", systemImage: "1.circle.fill")
          Label("Turn it on and create a one-time pairing code.", systemImage: "2.circle.fill")
          Label("Scan the QR code below, or enter its details.", systemImage: "3.circle.fill")
        }
        .font(.callout)

        Button {
          isScannerPresented = true
        } label: {
          Label("Scan Pairing QR Code", systemImage: "qrcode.viewfinder")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!DataScannerViewController.isSupported || !DataScannerViewController.isAvailable)

        VStack(alignment: .leading, spacing: 12) {
          TextField("http://100.x.y.z:48922", text: $remote.endpointDraft)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
          TextField("6-digit code", text: $remote.codeDraft)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .textFieldStyle(.roundedBorder)

          Button {
            Task { await remote.pair() }
          } label: {
            HStack {
              if remote.isPairing {
                ProgressView()
              }
              Text(remote.isPairing ? "Pairing…" : "Pair with Mac")
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
          .disabled(remote.isPairing || remote.endpointDraft.isEmpty || remote.codeDraft.isEmpty)
        }

        Label(
          "Both devices must be signed into the same Tailscale network. The connection stays inside your tailnet, and the pairing credential is kept in Keychain.",
          systemImage: "lock.shield"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      .padding(24)
    }
    .sheet(isPresented: $isScannerPresented) {
      MobileRemoteScannerSheet { payload in
        if remote.applyPairingPayload(payload) {
          isScannerPresented = false
          Task { await remote.pair() }
        }
      }
    }
  }
}

private struct MobileRemoteThreadRow: View {
  let thread: MobileRemoteThreadSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 7) {
        if thread.isRunning {
          ProgressView()
            .controlSize(.mini)
        }
        Text(thread.title)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Spacer()
        Text(thread.runtime == "codex" ? "Codex" : "OpenClaw")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }
      if let preview = thread.preview, !preview.isEmpty {
        Text(preview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Text(thread.updatedAt, style: .relative)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 3)
  }
}

private struct MobileRemoteThreadView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  let threadID: UUID
  @State private var draft = ""
  @State private var isSending = false

  var body: some View {
    Group {
      if let detail = remote.threadDetail, detail.thread.id == threadID {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
              if let connectionError = remote.threadConnectionError {
                Label(connectionError, systemImage: "wifi.exclamationmark")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .padding(10)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
              }

              ForEach(detail.messages) { message in
                MobileRemoteMessageBubble(message: message)
                  .id(message.id)
              }

              if !detail.streamingReply.isEmpty {
                MobileRemoteStreamingBubble(content: detail.streamingReply)
                  .id("streaming")
              }

              if !detail.reasoning.isEmpty {
                DisclosureGroup("Reasoning") {
                  Text(detail.reasoning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
              }

              if !detail.activities.isEmpty {
                MobileRemoteActivityView(activities: detail.activities)
              }
            }
            .padding()
          }
          .onChange(of: detail.messages.count) { _, _ in
            scrollToBottom(detail: detail, proxy: proxy)
          }
          .onChange(of: detail.streamingReply) { _, _ in
            scrollToBottom(detail: detail, proxy: proxy)
          }
          .onAppear {
            scrollToBottom(detail: detail, proxy: proxy, animated: false)
          }
        }
      } else {
        if let message = remote.threadConnectionError {
          ContentUnavailableView(
            "Mac Unavailable",
            systemImage: "wifi.exclamationmark",
            description: Text(message)
          )
        } else {
          ProgressView("Loading chat…")
        }
      }
    }
    .navigationTitle(remote.threadDetail?.thread.id == threadID ? remote.threadDetail?.thread.title ?? "Chat" : "Chat")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if remote.threadDetail?.thread.id == threadID,
         remote.threadDetail?.thread.isRunning == true {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Stop", role: .destructive) {
            Task { await remote.stop(threadID: threadID) }
          }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      composer
    }
    .onAppear {
      remote.beginPolling(threadID: threadID)
    }
    .onDisappear {
      remote.endPolling(threadID: threadID)
    }
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField("Message your Mac", text: $draft, axis: .vertical)
        .lineLimit(1...6)
        .textFieldStyle(.roundedBorder)
        .disabled(remote.threadDetail?.thread.isSettled == true)

      Button {
        let message = draft
        isSending = true
        Task {
          if await remote.send(message, threadID: threadID) {
            draft = ""
          }
          isSending = false
        }
      } label: {
        if isSending {
          ProgressView()
            .frame(width: 28, height: 28)
        } else {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 30))
        }
      }
      .buttonStyle(.plain)
      .disabled(
        isSending ||
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        remote.threadDetail?.thread.isSettled == true
      )
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private func scrollToBottom(
    detail: MobileRemoteThreadDetail,
    proxy: ScrollViewProxy,
    animated: Bool = true
  ) {
    let target: AnyHashable? = detail.streamingReply.isEmpty
      ? detail.messages.last?.id
      : AnyHashable("streaming")
    guard let target else { return }
    if animated {
      withAnimation { proxy.scrollTo(target, anchor: .bottom) }
    } else {
      proxy.scrollTo(target, anchor: .bottom)
    }
  }
}

private struct MobileRemoteMessageBubble: View {
  let message: MobileRemoteChatMessage

  var body: some View {
    HStack {
      if message.role == "user" { Spacer(minLength: 44) }
      VStack(alignment: .leading, spacing: 5) {
        Text(message.content)
          .textSelection(.enabled)
        if !message.attachmentNames.isEmpty {
          Label(message.attachmentNames.joined(separator: ", "), systemImage: "paperclip")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let sendFailure = message.sendFailure {
          Text(sendFailure)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      .padding(.horizontal, 13)
      .padding(.vertical, 10)
      .foregroundStyle(message.role == "user" ? Color.white : Color.primary)
      .background(
        message.role == "user" ? Color.blue : Color(.secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: 15)
      )
      if message.role != "user" { Spacer(minLength: 44) }
    }
  }
}

private struct MobileRemoteStreamingBubble: View {
  let content: String

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      Text(content)
        .textSelection(.enabled)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
      ProgressView()
        .controlSize(.small)
      Spacer(minLength: 36)
    }
  }
}

private struct MobileRemoteActivityView: View {
  let activities: [MobileRemoteActivity]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Activity", systemImage: "waveform.path.ecg")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(activities.suffix(6)) { activity in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: activity.status == "completed" ? "checkmark.circle.fill" : "circle.dotted")
            .foregroundStyle(activity.status == "completed" ? .green : .secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(activity.title)
              .font(.caption)
            if let detail = activity.detail, !detail.isEmpty {
              Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
        }
      }
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct MobileRemoteScannerSheet: View {
  @Environment(\.dismiss) private var dismiss
  let onScan: (String) -> Void

  var body: some View {
    NavigationStack {
      MobileRemoteQRScanner(onScan: onScan)
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Scan Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
        }
    }
  }
}

private struct MobileRemoteQRScanner: UIViewControllerRepresentable {
  let onScan: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onScan: onScan)
  }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced,
      recognizesMultipleItems: false,
      isHighFrameRateTrackingEnabled: true,
      isPinchToZoomEnabled: true,
      isGuidanceEnabled: true,
      isHighlightingEnabled: true
    )
    scanner.delegate = context.coordinator
    DispatchQueue.main.async {
      try? scanner.startScanning()
    }
    return scanner
  }

  func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

  static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
    scanner.stopScanning()
  }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    private let onScan: (String) -> Void
    private var hasScanned = false

    init(onScan: @escaping (String) -> Void) {
      self.onScan = onScan
    }

    func dataScanner(
      _ dataScanner: DataScannerViewController,
      didAdd addedItems: [RecognizedItem],
      allItems: [RecognizedItem]
    ) {
      guard !hasScanned else { return }
      for item in addedItems {
        guard case .barcode(let barcode) = item,
              let payload = barcode.payloadStringValue
        else {
          continue
        }
        hasScanned = true
        dataScanner.stopScanning()
        onScan(payload)
        return
      }
    }
  }
}
