import Org2WorkspaceCore
import SwiftUI

struct AIChatSettingsView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var editedDestination: AIChatDestinationConfiguration?
  @State private var meetingAutomationEnabled = false
  @State private var meetingAutomationDestinationID = AIChatDestinationConfiguration.openClawID
  @State private var meetingAutomationThreadMode = MeetingReadyAutomationThreadMode.newThread
  @State private var meetingAutomationThreadID: UUID?
  @State private var meetingAutomationPrompt = MeetingReadyAutomationSettings.defaultPrompt

  var body: some View {
    Form {
      Section {
        Picker("Corpus access", selection: $store.aiChatCorpusAccessScope) {
          Text("Current Corpus").tag(WorkspaceReadScope.activeCorpus)
          Text("All Loaded Corpora").tag(WorkspaceReadScope.allCorpora)
        }
        .pickerStyle(.radioGroup)

        Text(corpusAccessHelp)
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("AI Chat Context", systemImage: "text.bubble")
      }

      Section {
        ForEach(store.aiChatDestinations) { destination in
          HStack(spacing: 10) {
            Image(systemName: destination.systemImage)
              .frame(width: 22)
              .foregroundStyle(destination.isEnabled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(destination.title)
                .font(.body.weight(.medium))
              Text("@\(destination.mention) · \(destination.adapter.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enabled", isOn: destinationEnabledBinding(destination))
              .labelsHidden()
            Button("Edit") {
              editedDestination = destination
            }
          }
        }

        HStack {
          Button {
            let id = store.addAIChatDestination()
            editedDestination = store.aiChatDestination(id: id)
          } label: {
            Label("Add Destination", systemImage: "plus")
          }
          Spacer()
          Text("Use names such as @codex-local, @codex-remote, or @research-agent.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let error = store.aiChatDestinationSettingsError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
        }
      } header: {
        Label("AI Destinations", systemImage: "point.3.connected.trianglepath.dotted")
      }

      Section {
        Toggle("Process every completed meeting", isOn: $meetingAutomationEnabled)

        if meetingAutomationEnabled {
          Picker("Send to", selection: $meetingAutomationDestinationID) {
            ForEach(store.enabledAIChatDestinations) { destination in
              Text(destination.title).tag(destination.id)
            }
          }

          Picker("Thread", selection: $meetingAutomationThreadMode) {
            ForEach(MeetingReadyAutomationThreadMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }

          if meetingAutomationThreadMode == .existingThread {
            Picker("Target thread", selection: $meetingAutomationThreadID) {
              Text("Choose a thread").tag(UUID?.none)
              ForEach(store.meetingReadyAutomationThreads(destinationID: meetingAutomationDestinationID)) { thread in
                Text(thread.title + (thread.isSettled ? " (settled)" : ""))
                  .tag(Optional(thread.id))
              }
            }
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Processing prompt")
              .font(.callout.weight(.medium))
            TextEditor(text: $meetingAutomationPrompt)
              .font(.body)
              .frame(minHeight: 90)
              .overlay {
                RoundedRectangle(cornerRadius: 6)
                  .stroke(.separator, lineWidth: 1)
              }
          }
        }

        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(store.meetingReadyAutomationStatusText)
              .font(.callout)
              .foregroundStyle(meetingAutomationStatusColor)
            Text("Only successful transcriptions completed by this Mac after automation is enabled are queued. Opening, refreshing, or relaunching with existing meetings never triggers it.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 12)
          Button("Save Automation") {
            saveMeetingAutomation()
          }
          .buttonStyle(.borderedProminent)
          .disabled(store.corpusRoot == nil)
        }
      } header: {
        Label("Meeting Automation", systemImage: "calendar.badge.clock")
      }

      Section {
        Picker("Filesystem access", selection: $store.codexSandboxAccess) {
          ForEach(CodexSandboxAccess.allCases) { access in
            Text(access.title).tag(access)
          }
        }
        .pickerStyle(.radioGroup)

        Text(codexAccessHelp)
          .font(.callout)
          .foregroundStyle(store.codexSandboxAccess == .fullAccess ? Color.orange : Color.secondary)
      } header: {
        Label("Codex Permissions", systemImage: "lock.shield")
      }

      Section {
        HStack(spacing: 12) {
          Picker("Message sound", selection: $store.aiChatMessageSound) {
            ForEach(AIChatMessageSound.allCases) { sound in
              Text(sound.displayName).tag(sound)
            }
          }
          .onChange(of: store.aiChatMessageSound) {
            store.previewAIChatMessageSound()
          }

          Button {
            store.previewAIChatMessageSound()
          } label: {
            Label("Preview", systemImage: "speaker.wave.2")
          }
          .disabled(store.aiChatMessageSound == .off)
        }

        Text("Plays when an AI reply arrives, including for the thread currently open.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Notifications", systemImage: "bell")
      }

      Section {
        TextEditor(text: $store.aiChatCustomInstructions)
          .font(.body)
          .frame(minHeight: 150)
          .overlay {
            RoundedRectangle(cornerRadius: 6)
              .stroke(.separator, lineWidth: 1)
          }

        Text("These instructions are included with every new AI chat turn for both OpenClaw and Codex.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Custom Instructions", systemImage: "text.alignleft")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 620)
    .frame(minHeight: 560)
    .onAppear {
      loadMeetingAutomation()
    }
    .onChange(of: store.corpusRoot?.standardizedFileURL.path) {
      loadMeetingAutomation()
    }
    .onChange(of: meetingAutomationDestinationID) { _, destinationID in
      guard meetingAutomationThreadMode == .existingThread else { return }
      if !store.meetingReadyAutomationThreads(destinationID: destinationID)
        .contains(where: { $0.id == meetingAutomationThreadID }) {
        meetingAutomationThreadID = nil
      }
    }
    .sheet(item: $editedDestination) { destination in
      AIChatDestinationEditor(destination: destination)
        .environmentObject(store)
    }
  }

  private func destinationEnabledBinding(
    _ destination: AIChatDestinationConfiguration
  ) -> Binding<Bool> {
    Binding(
      get: {
        store.aiChatDestination(id: destination.id)?.isEnabled ?? destination.isEnabled
      },
      set: { enabled in
        var updated = store.aiChatDestination(id: destination.id) ?? destination
        updated.isEnabled = enabled
        store.updateAIChatDestination(updated)
      }
    )
  }

  private var corpusAccessHelp: String {
    switch store.aiChatCorpusAccessScope {
    case .activeCorpus:
      return "Chat can read only the current corpus. Writes remain scoped to that corpus."
    case .allCorpora:
      let count = max(store.mountedCorpora.count, store.corpusRoot == nil ? 0 : 1)
      return "Chat can read all \(count) loaded \(count == 1 ? "corpus" : "corpora"). Only the current corpus can be changed."
    }
  }

  private var codexAccessHelp: String {
    switch store.codexSandboxAccess {
    case .readOnly:
      return "Codex can inspect local files but must use Org2's reviewed edit tools for corpus changes."
    case .workspaceWrite:
      return "Codex can run commands and write inside the active corpus. Codex state such as ~/.codex lease files remains protected."
    case .fullAccess:
      return "Codex can write anywhere your Mac account can, including ~/.codex lease state and other repositories. Org2 does not show approval prompts in this mode; use it only for trusted threads. The change applies on the next turn, including in an existing thread."
    }
  }

  private var meetingAutomationStatusColor: Color {
    if store.meetingReadyAutomationStatusText.hasPrefix("Meeting delivery pending")
      || store.meetingReadyAutomationStatusText.hasPrefix("Meeting delivery needs attention") {
      return .orange
    }
    return .secondary
  }

  private func loadMeetingAutomation() {
    let settings = store.meetingReadyAutomationSettings
    meetingAutomationEnabled = settings.isEnabled
    meetingAutomationDestinationID = settings.destinationID
    meetingAutomationThreadMode = settings.threadMode
    meetingAutomationThreadID = settings.threadID
    meetingAutomationPrompt = settings.prompt
  }

  private func saveMeetingAutomation() {
    _ = store.saveMeetingReadyAutomationConfiguration(
      isEnabled: meetingAutomationEnabled,
      destinationID: meetingAutomationDestinationID,
      threadMode: meetingAutomationThreadMode,
      threadID: meetingAutomationThreadID,
      prompt: meetingAutomationPrompt
    )
  }
}

private struct AIChatDestinationEditor: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: WorkspaceStore
  @State private var destination: AIChatDestinationConfiguration
  @State private var token = ""
  @State private var clearsSavedToken = false

  init(destination: AIChatDestinationConfiguration) {
    _destination = State(initialValue: destination)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("AI Destination", systemImage: destination.systemImage)
          .font(.title3.weight(.semibold))
        Spacer()
        Toggle("Enabled", isOn: $destination.isEnabled)
      }

      Form {
        TextField("Name", text: $destination.name)
        TextField("Mention", text: $destination.mention, prompt: Text("codex-remote"))
          .textContentType(.username)

        Picker("Adapter", selection: $destination.adapter) {
          ForEach(AIChatDestinationAdapter.allCases) { adapter in
            Text(adapter.title).tag(adapter)
          }
        }
        .disabled(isBuiltIn)

        if destination.adapter == .codexRemote {
          TextField(
            "WebSocket endpoint",
            text: $destination.endpoint,
            prompt: Text("wss://codex-host.example/ws")
          )
          TextField(
            "Workspace on that machine",
            text: $destination.workspaceRoot,
            prompt: Text("~/dev/org2")
          )
        } else if destination.adapter == .openClaw && !isBuiltInOpenClaw {
          TextField(
            "Gateway endpoint",
            text: $destination.endpoint,
            prompt: Text("https://host/v1/chat/completions")
          )
          TextField("Agent ID", text: $destination.agentID, prompt: Text("main"))
        }

        if destination.acceptsBearerToken && !isBuiltInOpenClaw {
          SecureField(
            "Bearer token",
            text: $token,
            prompt: Text(hasSavedToken ? "Saved token unchanged" : "Optional")
          )
          if hasSavedToken {
            Toggle("Clear saved token", isOn: $clearsSavedToken)
          }
        }
      }
      .formStyle(.grouped)

      Text(helpText)
        .font(.callout)
        .foregroundStyle(.secondary)

      HStack {
        if !isBuiltIn {
          Button("Delete", role: .destructive) {
            store.removeAIChatDestination(destination.id)
            dismiss()
          }
        }
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          store.updateAIChatDestination(destination)
          if clearsSavedToken {
            store.saveAIChatDestinationToken("", destinationID: destination.id)
          } else if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.saveAIChatDestinationToken(token, destinationID: destination.id)
          }
          if store.aiChatDestinationSettingsError == nil {
            dismiss()
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 520)
  }

  private var isBuiltIn: Bool {
    destination.id == AIChatDestinationConfiguration.localCodexID
      || destination.id == AIChatDestinationConfiguration.openClawID
  }

  private var isBuiltInOpenClaw: Bool {
    destination.id == AIChatDestinationConfiguration.openClawID
  }

  private var hasSavedToken: Bool {
    store.aiChatDestinationHasToken(destination.id)
  }

  private var helpText: String {
    switch destination.adapter {
    case .codexLocal:
      return "Starts a local Codex App Server process on this Mac."
    case .codexRemote:
      return "Connects to a Codex App Server over WebSocket. Use TLS and a bearer token outside localhost; the workspace path is resolved on the remote machine."
    case .openClaw:
      return isBuiltInOpenClaw
        ? "This default destination uses the existing OpenClaw Gateway configuration."
        : "Routes turns to this OpenClaw gateway and agent ID with its own saved token."
    }
  }
}
