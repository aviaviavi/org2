import PhotosUI
import SwiftUI
import UIKit
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
            threadLink(thread)
          }
        }
      }

      if !settledThreads.isEmpty {
        Section("Settled") {
          ForEach(settledThreads) { thread in
            threadLink(thread)
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

  private func threadLink(_ thread: MobileRemoteThreadSummary) -> some View {
    NavigationLink(value: thread.id) {
      MobileRemoteThreadRow(thread: thread)
    }
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      Button {
        Task { await remote.setPinned(!thread.isPinned, threadID: thread.id) }
      } label: {
        Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin")
      }
      .tint(.orange)
      .disabled(remote.mutatingThreadIDs.contains(thread.id))
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button {
        Task { await remote.setSettled(!thread.isSettled, threadID: thread.id) }
      } label: {
        Label(
          thread.isSettled ? "Reopen" : "Settle",
          systemImage: thread.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle"
        )
      }
      .tint(thread.isSettled ? .blue : .green)
      .disabled(remote.mutatingThreadIDs.contains(thread.id))
    }
    .contextMenu {
      Button {
        Task { await remote.setPinned(!thread.isPinned, threadID: thread.id) }
      } label: {
        Label(thread.isPinned ? "Unpin Thread" : "Pin Thread", systemImage: thread.isPinned ? "pin.slash" : "pin")
      }
      Button {
        Task { await remote.setSettled(!thread.isSettled, threadID: thread.id) }
      } label: {
        Label(
          thread.isSettled ? "Reopen Thread" : "Settle Thread",
          systemImage: thread.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle"
        )
      }
    }
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
        if thread.isPinned {
          Image(systemName: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
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
  @Environment(\.colorScheme) private var colorScheme
  let threadID: UUID
  @StateObject private var voiceTranscriber = MobileVoiceTranscriber()
  @State private var draft = ""
  @State private var isSending = false
  @State private var isStopping = false
  @State private var dictationPrefix = ""
  @State private var selectedPhotoItems: [PhotosPickerItem] = []
  @State private var attachments: [MobileRemoteAttachment] = []
  @State private var selectedFileCitation: MobileRemoteFileCitation?
  @State private var isNearChatBottom = true
  @State private var hasPresentedInitialContent = false

  var body: some View {
    Group {
      if let detail = remote.threadDetail, detail.thread.id == threadID {
        if hasPresentedInitialContent {
          chatContent(detail: detail)
        } else {
          loadingView(detailIsAvailable: true)
            .task(id: detail.thread.id) {
              await Task.yield()
              try? await Task.sleep(for: .milliseconds(40))
              guard !Task.isCancelled,
                    remote.threadDetail?.thread.id == threadID
              else { return }
              hasPresentedInitialContent = true
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
          loadingView(detailIsAvailable: false)
        }
      }
    }
    .navigationTitle(remote.threadDetail?.thread.id == threadID ? remote.threadDetail?.thread.title ?? "Chat" : "Chat")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let thread = remote.threadDetail?.thread, thread.id == threadID {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button {
              Task { await remote.setPinned(!thread.isPinned, threadID: threadID) }
            } label: {
              Label(
                thread.isPinned ? "Unpin Thread" : "Pin Thread",
                systemImage: thread.isPinned ? "pin.slash" : "pin"
              )
            }
            Button {
              Task { await remote.setSettled(!thread.isSettled, threadID: threadID) }
            } label: {
              Label(
                thread.isSettled ? "Reopen Thread" : "Settle Thread",
                systemImage: thread.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle"
              )
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .disabled(remote.mutatingThreadIDs.contains(threadID))
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      if hasPresentedInitialContent,
         remote.threadDetail?.thread.id == threadID {
        composer
      }
    }
    .onAppear {
      hasPresentedInitialContent = false
      remote.beginPolling(threadID: threadID)
    }
    .onDisappear {
      voiceTranscriber.cancel()
      hasPresentedInitialContent = false
      remote.endPolling(threadID: threadID)
    }
    .onChange(of: voiceTranscriber.transcript) { _, transcript in
      draft = Self.appendingDictation(transcript, to: dictationPrefix)
    }
    .onChange(of: selectedPhotoItems) { _, items in
      guard !items.isEmpty else { return }
      loadPhotos(items)
    }
    .alert("Voice Transcription", isPresented: Binding(
      get: { voiceTranscriber.errorMessage != nil },
      set: { if !$0 { voiceTranscriber.errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(voiceTranscriber.errorMessage ?? "")
    }
    .sheet(item: $selectedFileCitation) { citation in
      MobileRemoteFilePreviewSheet(citation: citation)
        .environmentObject(remote)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
  }

  private func chatContent(detail: MobileRemoteThreadDetail) -> some View {
    ScrollViewReader { proxy in
      Group {
        if #available(iOS 18.0, *) {
          chatScrollView(detail: detail)
            .onScrollGeometryChange(for: Bool.self) { geometry in
              geometry.contentSize.height <= geometry.containerSize.height
                || geometry.visibleRect.maxY >= geometry.contentSize.height - 28
            } action: { _, nextValue in
              if isNearChatBottom != nextValue {
                isNearChatBottom = nextValue
              }
            }
        } else {
          chatScrollView(detail: detail)
        }
      }
      .onChange(of: detail.messages.count) { _, _ in
        scrollToBottomIfFollowing(proxy: proxy)
      }
      .onChange(of: detail.streamingReply) { _, _ in
        scrollToBottomIfFollowing(proxy: proxy)
      }
      .onChange(of: detail.reasoning) { _, _ in
        scrollToBottomIfFollowing(proxy: proxy)
      }
      .onChange(of: detail.activities.count) { _, _ in
        scrollToBottomIfFollowing(proxy: proxy)
      }
      .onChange(of: isSending) { _, sending in
        if sending {
          scrollToBottom(proxy: proxy)
        } else {
          scrollToBottomIfFollowing(proxy: proxy)
        }
      }
      .onAppear {
        isNearChatBottom = true
        scrollToBottom(proxy: proxy, animated: false)
      }
      .overlay(alignment: .bottomTrailing) {
        if !isNearChatBottom {
          Button {
            scrollToBottom(proxy: proxy)
          } label: {
            Image(systemName: "arrow.down")
              .font(.system(size: 14, weight: .semibold))
              .frame(width: 36, height: 36)
              .background(.regularMaterial, in: Circle())
              .overlay {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1)
              }
              .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
          }
          .buttonStyle(.plain)
          .padding(.trailing, 14)
          .padding(.bottom, 12)
          .accessibilityLabel("Jump to latest message")
          .transition(.scale.combined(with: .opacity))
        }
      }
      .animation(.easeInOut(duration: 0.16), value: isNearChatBottom)
    }
  }

  private func loadingView(detailIsAvailable: Bool) -> some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.large)
      Text(detailIsAvailable ? "Preparing conversation…" : "Loading chat…")
        .font(.headline)
      if let title = remote.threads.first(where: { $0.id == threadID })?.title {
        Text(title)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemGroupedBackground))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(detailIsAvailable ? "Preparing conversation" : "Loading chat")
  }

  private func chatScrollView(detail: MobileRemoteThreadDetail) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
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
            MobileRemoteMessageBubble(message: message) { citation in
              selectedFileCitation = citation
            }
              .id(message.id)
          }

          if isSending || detail.thread.isRunning || !detail.streamingReply.isEmpty {
            MobileRemoteInProgressBubble(
              detail: detail,
              isStarting: isSending
            )
            .id("in-progress")
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

        Color.clear
          .frame(height: 1)
          .id(bottomAnchorID)
          .accessibilityHidden(true)
      }
      .padding()
    }
  }

  private var composer: some View {
    VStack(spacing: 9) {
      if !attachments.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(attachments) { attachment in
              MobileRemotePhotoThumbnail(attachment: attachment) {
                attachments.removeAll { $0.id == attachment.id }
              }
            }
          }
          .padding(.horizontal, 2)
        }
      }

      HStack(alignment: .bottom, spacing: 10) {
        TextField("Talk to \(agentTitle)", text: $draft, axis: .vertical)
          .lineLimit(1...6)
          .textFieldStyle(.plain)
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .frame(minHeight: 44)
          .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .stroke(
                Color.primary.opacity(colorScheme == .light ? 0.11 : 0.09),
                lineWidth: 1
              )
          }
          .shadow(
            color: Color.black.opacity(colorScheme == .light ? 0.055 : 0.025),
            radius: 4,
            x: 0,
            y: 2
          )
          .disabled(isSettled)

        if isRunning || isStopping {
          Button {
            isStopping = true
            Task {
              await remote.stop(threadID: threadID)
              isStopping = false
            }
          } label: {
            if isStopping {
              ProgressView()
                .frame(width: 30, height: 30)
            } else {
              Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: Circle())
            }
          }
          .buttonStyle(.plain)
          .disabled(isStopping)
          .accessibilityLabel("Stop response")
        } else {
          Button {
            sendMessage()
          } label: {
            if isSending {
              ProgressView()
                .frame(width: 30, height: 30)
            } else {
              Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 30))
            }
          }
          .buttonStyle(.plain)
          .disabled(!canSend)
          .accessibilityLabel("Send message")
        }
      }

      HStack(spacing: 8) {
        modelPicker
        reasoningPicker
        Spacer(minLength: 4)
        PhotosPicker(
          selection: $selectedPhotoItems,
          maxSelectionCount: 4,
          matching: .images
        ) {
          Image(systemName: "photo.on.rectangle")
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(isSettled || isSending || attachments.count >= 4)
        .accessibilityLabel("Add photos")

        Button {
          if voiceTranscriber.isRecording {
            voiceTranscriber.stop()
          } else {
            dictationPrefix = draft
            Task { await voiceTranscriber.start() }
          }
        } label: {
          Image(systemName: voiceTranscriber.isRecording ? "stop.fill" : "mic.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(voiceTranscriber.isRecording ? .white : .primary)
            .frame(width: 28, height: 28)
            .background(
              voiceTranscriber.isRecording ? Color.red : Color(.tertiarySystemFill),
              in: Circle()
            )
        }
        .buttonStyle(.plain)
        .disabled(isSettled || isSending)
        .accessibilityLabel(voiceTranscriber.isRecording ? "Stop transcription" : "Transcribe voice")
      }
      .font(.callout)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private var modelPicker: some View {
    Menu {
      Button {
        Task { await remote.setModel(nil, threadID: threadID) }
      } label: {
        HStack {
          Text("Default model")
          if remote.threadConfiguration?.model == nil {
            Image(systemName: "checkmark")
          }
        }
      }

      if remote.isRefreshingConfiguration {
        Divider()
        Text("Loading models…")
      } else if let configuration = remote.threadConfiguration,
                !configuration.models.isEmpty {
        Divider()
        ForEach(configuration.models) { model in
          Button {
            Task { await remote.setModel(model.id, threadID: threadID) }
          } label: {
            HStack {
              Text(model.label)
              if configuration.model == model.id {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      } else {
        Divider()
        Text("Models unavailable")
      }
    } label: {
      HStack(spacing: 5) {
        if remote.isRefreshingConfiguration || remote.isUpdatingConfiguration {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: "cpu")
        }
        Text(modelLabel)
          .lineLimit(1)
          .frame(maxWidth: 104)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(Color(.tertiarySystemFill), in: Capsule())
    }
    .disabled(
      isSettled || isRunning || isSending ||
      remote.isRefreshingConfiguration || remote.isUpdatingConfiguration ||
      remote.threadConfiguration == nil
    )
    .accessibilityLabel("Choose model, currently \(modelLabel)")
  }

  private var modelLabel: String {
    guard let configuration = remote.threadConfiguration else {
      return remote.configurationError == nil ? "Model" : "Model unavailable"
    }
    if let model = configuration.model {
      return configuration.models.first(where: { $0.id == model })?.label ?? model
    }
    return configuration.models.first(where: \.isDefault)?.label ?? "Default"
  }

  private var reasoningPicker: some View {
    Menu {
      Button {
        Task { await remote.setReasoningEffort(nil, threadID: threadID) }
      } label: {
        HStack {
          Text(defaultReasoningLabel)
          if remote.threadConfiguration?.reasoningEffort == nil {
            Image(systemName: "checkmark")
          }
        }
      }

      if let configuration = remote.threadConfiguration,
         !configuration.reasoningOptions.isEmpty {
        Divider()
        ForEach(configuration.reasoningOptions) { option in
          Button {
            Task { await remote.setReasoningEffort(option.id, threadID: threadID) }
          } label: {
            HStack {
              Text(option.label)
              if configuration.reasoningEffort == option.id {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      } else {
        Divider()
        Text("No reasoning levels reported")
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "brain")
        Text(reasoningLabel)
          .lineLimit(1)
          .frame(maxWidth: 82)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(Color(.tertiarySystemFill), in: Capsule())
    }
    .disabled(
      isSettled || isRunning || isSending ||
      remote.isRefreshingConfiguration || remote.isUpdatingConfiguration ||
      !hasReasoningChoices
    )
    .accessibilityLabel("Choose reasoning, currently \(reasoningLabel)")
  }

  private var hasReasoningChoices: Bool {
    guard let configuration = remote.threadConfiguration else { return false }
    return !configuration.reasoningOptions.isEmpty || configuration.reasoningEffort != nil
  }

  private var reasoningLabel: String {
    guard let configuration = remote.threadConfiguration else { return "Reasoning" }
    let effort = configuration.reasoningEffort ?? configuration.defaultReasoningEffort
    guard let effort else { return "Reasoning" }
    return configuration.reasoningOptions.first(where: { $0.id == effort })?.label
      ?? effort.capitalized
  }

  private var defaultReasoningLabel: String {
    guard let configuration = remote.threadConfiguration,
          let effort = configuration.defaultReasoningEffort
    else {
      return "Default reasoning"
    }
    let label = configuration.reasoningOptions.first(where: { $0.id == effort })?.label
      ?? effort.capitalized
    return "Default reasoning (\(label))"
  }

  private var agentTitle: String {
    remote.threadDetail?.thread.runtime == "codex" ? "Codex" : "OpenClaw"
  }

  private var isRunning: Bool {
    remote.threadDetail?.thread.id == threadID && remote.threadDetail?.thread.isRunning == true
  }

  private var isSettled: Bool {
    remote.threadDetail?.thread.id == threadID && remote.threadDetail?.thread.isSettled == true
  }

  private var canSend: Bool {
    !isSending && !isSettled && (
      !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    )
  }

  private func sendMessage() {
    let message = draft
    let sentAttachments = attachments
    if voiceTranscriber.isRecording {
      voiceTranscriber.stop()
    }
    isSending = true
    Task {
      if await remote.send(message, attachments: sentAttachments, threadID: threadID) {
        draft = ""
        dictationPrefix = ""
        attachments = []
        selectedPhotoItems = []
        voiceTranscriber.cancel()
      }
      isSending = false
    }
  }

  private func loadPhotos(_ items: [PhotosPickerItem]) {
    selectedPhotoItems = []
    Task {
      do {
        var next = attachments
        let initialCount = next.count
        for (index, item) in items.prefix(4 - next.count).enumerated() {
          guard let data = try await item.loadTransferable(type: Data.self) else { continue }
          let attachment = try MobileRemotePhotoPreparation.attachment(
            from: data,
            sequence: initialCount + index + 1
          )
          if !next.contains(where: { $0.data == attachment.data }) {
            guard next.reduce(attachment.data.count, { $0 + $1.data.count }) <= 7_500_000 else {
              throw MobileRemotePhotoError.totalTooLarge
            }
            next.append(attachment)
          }
        }
        attachments = Array(next.prefix(4))
      } catch {
        remote.errorMessage = error.localizedDescription
      }
    }
  }

  private static func appendingDictation(_ transcript: String, to prefix: String) -> String {
    let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if prefix.isEmpty { return transcript }
    if transcript.isEmpty { return prefix }
    return "\(prefix) \(transcript)"
  }

  private var bottomAnchorID: String {
    "mobile-remote-thread-bottom-\(threadID.uuidString)"
  }

  private func scrollToBottomIfFollowing(proxy: ScrollViewProxy) {
    guard isNearChatBottom else { return }
    scrollToBottom(proxy: proxy)
  }

  private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
    let target = bottomAnchorID
    Task { @MainActor in
      await Task.yield()
      if animated {
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(target, anchor: .bottom)
        }
      } else {
        proxy.scrollTo(target, anchor: .bottom)
      }
    }
  }
}

private struct MobileRemoteMessageBubble: View {
  @Environment(\.colorScheme) private var colorScheme
  let message: MobileRemoteChatMessage
  let openFileCitation: (MobileRemoteFileCitation) -> Void
  @State private var didCopy = false

  var body: some View {
    HStack {
      if message.role == "user" { Spacer(minLength: 44) }
      VStack(alignment: .leading, spacing: 5) {
        Text(MobileRemoteMessageMarkup.attributedString(for: message.content))
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
      .padding(.trailing, 22)
      .foregroundStyle(message.role == "user" ? Color.white : Color.primary)
      .tint(message.role == "user" ? Color.white : Color.accentColor)
      .background(
        message.role == "user" ? Color.blue : Color(.secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: 15)
      )
      .overlay {
        if message.role != "user" {
          RoundedRectangle(cornerRadius: 15)
            .stroke(responseBorderColor, lineWidth: 1)
        }
      }
      .overlay(alignment: .topTrailing) {
        Button {
          UIPasteboard.general.string = clipboardText
          didCopy = true
        } label: {
          Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            .font(.caption2.weight(.semibold))
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(message.role == "user" ? Color.white.opacity(0.82) : Color.secondary)
        .accessibilityLabel(didCopy ? "Message copied" : "Copy message")
      }
      .contextMenu {
        Button {
          UIPasteboard.general.string = clipboardText
          didCopy = true
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
      }
      .sensoryFeedback(.success, trigger: didCopy)
      .environment(\.openURL, OpenURLAction { url in
        guard let citation = MobileRemoteMessageMarkup.fileCitation(from: url) else {
          return .systemAction
        }
        openFileCitation(citation)
        return .handled
      })
      if message.role != "user" { Spacer(minLength: 44) }
    }
  }

  private var clipboardText: String {
    let attachmentText = message.attachmentNames.map { "[Attachment: \($0)]" }
    return ([message.content].filter { !$0.isEmpty } + attachmentText).joined(separator: "\n")
  }

  private var responseBorderColor: Color {
    Color.primary.opacity(colorScheme == .light ? 0.14 : 0.10)
  }
}

private struct MobileRemoteFileCitation: Identifiable, Hashable {
  let path: String
  let line: Int?
  let label: String

  var id: String { "\(path)#\(line ?? 0)" }
}

private enum MobileRemoteMessageMarkup {
  private static let markdownLinkPattern = try! NSRegularExpression(
    pattern: #"\[([^\]\n]+)\]\(([^)\n]+)\)"#
  )
  private static let orgLinkPattern = try! NSRegularExpression(
    pattern: #"\[\[([^\]\n]+)\]\[([^\]\n]+)\]\]"#
  )
  private static let fileTargetPattern = try! NSRegularExpression(
    pattern: #"^(.+\.(?:org2|org))(?::([1-9][0-9]*))?$"#,
    options: [.caseInsensitive]
  )

  private struct RenderedLink {
    let range: NSRange
    let label: String
    let url: URL
  }

  static func attributedString(for content: String) -> AttributedString {
    let source = content as NSString
    let links = renderedLinks(in: content)
    guard !links.isEmpty else { return AttributedString(content) }
    var output = AttributedString()
    var cursor = 0
    for link in links where link.range.location >= cursor {
      let prefixRange = NSRange(location: cursor, length: link.range.location - cursor)
      output.append(AttributedString(source.substring(with: prefixRange)))
      var chunk = AttributedString(link.label)
      chunk.foregroundColor = .accentColor
      chunk.link = link.url
      output.append(chunk)
      cursor = link.range.location + link.range.length
    }
    if cursor < source.length {
      output.append(AttributedString(source.substring(from: cursor)))
    }
    return output
  }

  static func fileCitation(from url: URL) -> MobileRemoteFileCitation? {
    guard url.scheme == "org2-mobile-file",
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
          !path.isEmpty
    else { return nil }
    let line = components.queryItems?
      .first(where: { $0.name == "line" })?
      .value
      .flatMap(Int.init)
    let label = components.queryItems?
      .first(where: { $0.name == "label" })?
      .value ?? URL(fileURLWithPath: path).lastPathComponent
    return MobileRemoteFileCitation(path: path, line: line, label: label)
  }

  private static func renderedLinks(in content: String) -> [RenderedLink] {
    let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
    var links: [RenderedLink] = markdownLinkPattern.matches(in: content, range: fullRange).compactMap { match -> RenderedLink? in
      guard let labelRange = Range(match.range(at: 1), in: content),
            let targetRange = Range(match.range(at: 2), in: content),
            let rendered = renderedLink(
              range: match.range,
              target: String(content[targetRange]),
              label: String(content[labelRange])
            )
      else { return nil }
      return rendered
    }
    let orgLinks: [RenderedLink] = orgLinkPattern.matches(in: content, range: fullRange).compactMap { match -> RenderedLink? in
      guard let targetRange = Range(match.range(at: 1), in: content),
            let labelRange = Range(match.range(at: 2), in: content)
      else { return nil }
      return renderedLink(
        range: match.range,
        target: String(content[targetRange]),
        label: String(content[labelRange])
      )
    }
    links.append(contentsOf: orgLinks)
    return links.sorted { $0.range.location < $1.range.location }
  }

  private static func renderedLink(
    range: NSRange,
    target rawTarget: String,
    label: String
  ) -> RenderedLink? {
    if let citation = citation(target: rawTarget, label: label),
       let url = citationURL(citation) {
      let displayLabel = citation.line.map { "\(citation.label) · L\($0)" } ?? citation.label
      return RenderedLink(range: range, label: displayLabel, url: url)
    }
    var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    if target.hasPrefix("<"), target.hasSuffix(">") {
      target = String(target.dropFirst().dropLast())
    }
    guard let url = URL(string: target),
          ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    else { return nil }
    return RenderedLink(range: range, label: label, url: url)
  }

  private static func citation(target rawTarget: String, label: String) -> MobileRemoteFileCitation? {
    var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    if target.hasPrefix("<"), target.hasSuffix(">") {
      target = String(target.dropFirst().dropLast())
    }
    target = target.removingPercentEncoding ?? target
    let range = NSRange(target.startIndex..<target.endIndex, in: target)
    guard let match = fileTargetPattern.firstMatch(in: target, range: range),
          let pathRange = Range(match.range(at: 1), in: target)
    else { return nil }
    let line: Int?
    if match.range(at: 2).location != NSNotFound,
       let lineRange = Range(match.range(at: 2), in: target) {
      line = Int(target[lineRange])
    } else {
      line = nil
    }
    return MobileRemoteFileCitation(path: String(target[pathRange]), line: line, label: label)
  }

  private static func citationURL(_ citation: MobileRemoteFileCitation) -> URL? {
    var components = URLComponents()
    components.scheme = "org2-mobile-file"
    components.host = "preview"
    components.queryItems = [
      URLQueryItem(name: "path", value: citation.path),
      URLQueryItem(name: "label", value: citation.label)
    ]
    if let line = citation.line {
      components.queryItems?.append(URLQueryItem(name: "line", value: String(line)))
    }
    return components.url
  }
}

private struct MobileRemoteFilePreviewSheet: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  @Environment(\.dismiss) private var dismiss
  let citation: MobileRemoteFileCitation
  @State private var preview: MobileRemoteFilePreview?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Group {
        if let preview {
          previewContent(preview)
        } else if let errorMessage {
          ContentUnavailableView(
            "Preview Unavailable",
            systemImage: "doc.text.magnifyingglass",
            description: Text(errorMessage)
          )
        } else {
          ProgressView("Loading preview…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .navigationTitle(preview?.title ?? citation.label)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .task(id: citation.id) {
      do {
        preview = try await remote.filePreview(path: citation.path, line: citation.line)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func previewContent(_ preview: MobileRemoteFilePreview) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(preview.relativePath)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .padding(.horizontal)
        .padding(.vertical, 10)
      Divider()
      GeometryReader { geometry in
        ScrollView([.horizontal, .vertical]) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(previewLines(preview).enumerated()), id: \.offset) { offset, line in
              let lineNumber = preview.startLine + offset
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(String(lineNumber))
                  .foregroundStyle(.tertiary)
                  .frame(width: 34, alignment: .trailing)
                Text(verbatim: line.isEmpty ? " " : line)
                  .foregroundStyle(.primary)
                  .fixedSize(horizontal: true, vertical: false)
              }
              .font(.system(.caption, design: .monospaced))
              .padding(.horizontal, 12)
              .padding(.vertical, 3)
              .frame(minWidth: geometry.size.width, alignment: .leading)
              .background(
                lineNumber == preview.highlightedLine
                  ? Color.accentColor.opacity(0.13)
                  : Color.clear
              )
            }
          }
          .frame(minWidth: geometry.size.width, alignment: .topLeading)
          .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.topLeading)
        .scrollIndicators(.visible, axes: [.horizontal, .vertical])
        .textSelection(.enabled)
      }
    }
  }

  private func previewLines(_ preview: MobileRemoteFilePreview) -> [String] {
    let lines = preview.content
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    return lines.isEmpty ? [""] : lines
  }
}

private struct MobileRemotePhotoThumbnail: View {
  let attachment: MobileRemoteAttachment
  let remove: () -> Void

  var body: some View {
    ZStack(alignment: .topTrailing) {
      if let image = UIImage(data: attachment.data) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 58, height: 58)
          .clipShape(RoundedRectangle(cornerRadius: 10))
      }
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .black.opacity(0.7))
      }
      .buttonStyle(.plain)
      .offset(x: 5, y: -5)
      .accessibilityLabel("Remove \(attachment.fileName)")
    }
    .padding(.top, 5)
    .padding(.trailing, 5)
  }
}

private enum MobileRemotePhotoPreparation {
  static func attachment(from data: Data, sequence: Int) throws -> MobileRemoteAttachment {
    guard let image = UIImage(data: data) else {
      throw MobileRemotePhotoError.unreadable
    }
    let maxDimension: CGFloat = 2_048
    let longestSide = max(image.size.width, image.size.height)
    let scale = longestSide > maxDimension ? maxDimension / longestSide : 1
    let size = CGSize(
      width: max(1, floor(image.size.width * scale)),
      height: max(1, floor(image.size.height * scale))
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }

    var quality: CGFloat = 0.82
    guard var encoded = resized.jpegData(compressionQuality: quality) else {
      throw MobileRemotePhotoError.unreadable
    }
    while encoded.count > 1_500_000, quality > 0.34 {
      quality -= 0.12
      guard let next = resized.jpegData(compressionQuality: quality) else { break }
      encoded = next
    }
    guard encoded.count <= 5_000_000 else {
      throw MobileRemotePhotoError.tooLarge
    }
    return MobileRemoteAttachment(
      fileName: "mobile-photo-\(sequence).jpg",
      mimeType: "image/jpeg",
      data: encoded
    )
  }
}

private enum MobileRemotePhotoError: LocalizedError {
  case unreadable
  case tooLarge
  case totalTooLarge

  var errorDescription: String? {
    switch self {
    case .unreadable:
      "One of the selected photos could not be read."
    case .tooLarge:
      "One of the selected photos is too large to send."
    case .totalTooLarge:
      "The selected photos are too large to send together. Remove one and try again."
    }
  }
}

private struct MobileRemoteInProgressBubble: View {
  @Environment(\.colorScheme) private var colorScheme
  let detail: MobileRemoteThreadDetail
  let isStarting: Bool

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 9) {
        MobileRemoteShimmeringStatusText(
          statusTitle,
          animates: isStarting || detail.connectionState != "disconnected"
        )

        if !trimmedReply.isEmpty {
          Text(detail.streamingReply)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, 13)
      .padding(.vertical, 10)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
      .overlay {
        RoundedRectangle(cornerRadius: 15)
          .stroke(Color.primary.opacity(colorScheme == .light ? 0.14 : 0.10), lineWidth: 1)
      }
      .accessibilityElement(children: .combine)
      .accessibilityHint(detail.connectionDetail ?? "")
      Spacer(minLength: 36)
    }
  }

  private var runtimeTitle: String {
    detail.thread.runtime == "codex" ? "Codex" : "OpenClaw"
  }

  private var trimmedReply: String {
    detail.streamingReply.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var statusTitle: String {
    if isStarting {
      return "Connecting to \(runtimeTitle)"
    }

    switch detail.connectionState {
    case "connecting":
      return "Connecting to \(runtimeTitle)"
    case "reconnecting":
      return "Reconnecting to \(runtimeTitle)"
    case "fallbackHTTP":
      return "\(runtimeTitle) is working over HTTP"
    case "disconnected":
      return runtimeTitle == "Codex" ? "Codex connection interrupted" : "Connection interrupted"
    default:
      if let latest = detail.activities.last(where: { $0.status == "running" }),
         !latest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "Running \(latest.title.lowercased())"
      }
      if !detail.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "\(runtimeTitle) is thinking"
      }
      return "\(runtimeTitle) is working"
    }
  }
}

private struct MobileRemoteShimmeringStatusText: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let title: String
  let animates: Bool

  init(_ title: String, animates: Bool = true) {
    self.title = title
    self.animates = animates
  }

  var body: some View {
    Text(title)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .overlay {
        if animates && !reduceMotion {
          TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            GeometryReader { geometry in
              let width = geometry.size.width
              let bandWidth = min(90, max(40, width * 0.5))
              let progress = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 2.2) / 2.2

              LinearGradient(
                colors: [.clear, Color.primary.opacity(0.55), .clear],
                startPoint: .leading,
                endPoint: .trailing
              )
              .frame(width: bandWidth)
              .offset(x: -bandWidth + ((width + bandWidth) * progress))
            }
            .mask(alignment: .leading) {
              Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            }
          }
        }
      }
      .contentTransition(.opacity)
      .animation(.easeInOut(duration: 0.18), value: title)
  }
}

private struct MobileRemoteActivityView: View {
  let activities: [MobileRemoteActivity]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(activities.suffix(6)) { activity in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: statusSymbol(for: activity.status))
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor(for: activity.status))
            .frame(width: 14)
          VStack(alignment: .leading, spacing: 2) {
            Text(activity.title)
              .font(.caption.weight(.medium))
            if let detail = activity.detail,
               !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
        }
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Activity")
  }

  private func statusSymbol(for status: String) -> String {
    switch status {
    case "succeeded": "checkmark.circle.fill"
    case "failed": "exclamationmark.circle.fill"
    default: "circle.dotted"
    }
  }

  private func statusColor(for status: String) -> Color {
    switch status {
    case "failed": .orange
    case "succeeded": .secondary
    default: .secondary
    }
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
