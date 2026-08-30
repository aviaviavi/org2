import Org2WorkspaceCore
import SwiftUI

struct AIChatSettingsView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var editedDestination: AIChatDestinationConfiguration?

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
          Menu {
            ForEach(addableDestinationAdapters) { adapter in
              Button {
                let id = store.addAIChatDestination(adapter: adapter)
                editedDestination = store.aiChatDestination(id: id)
              } label: {
                Label(adapter.title, systemImage: adapter.systemImage)
              }
            }
          } label: {
            Label("Add Destination", systemImage: "plus")
          }
          Spacer()
          Text("Use names such as @claude, @codex-remote, or @research-agent.")
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
        Picker("Filesystem access", selection: $store.codexSandboxAccess) {
          ForEach(CodexSandboxAccess.allCases) { access in
            Text(access.title).tag(access)
          }
        }
        .pickerStyle(.radioGroup)

        Text(localAgentAccessHelp)
          .font(.callout)
          .foregroundStyle(store.codexSandboxAccess == .fullAccess ? Color.orange : Color.secondary)
      } header: {
        Label("Local Agent Permissions", systemImage: "lock.shield")
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

        Text("These instructions are included with every new AI chat turn for OpenClaw, Codex, and Claude Code.")
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

  private var addableDestinationAdapters: [AIChatDestinationAdapter] {
    AIChatDestinationAdapter.allCases.filter { $0 != .codexLocal && $0 != .claudeLocal }
  }

  private var localAgentAccessHelp: String {
    switch store.codexSandboxAccess {
    case .readOnly:
      return "Codex and Claude Code can inspect local files. Claude Code runs in Plan mode; Codex must use OpenOrg's reviewed edit tools for corpus changes."
    case .workspaceWrite:
      return "Codex and Claude Code can edit inside the active corpus. Their protected settings and repository metadata remain guarded by each runtime."
    case .fullAccess:
      return "Codex and Claude Code can write anywhere your Mac account can. OpenOrg does not show approval prompts in this mode; use it only for trusted threads. The change applies on the next turn, including in an existing thread."
    }
  }

}

private struct AIChatDestinationEditor: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: WorkspaceStore
  @State private var destination: AIChatDestinationConfiguration
  @State private var token = ""
  @State private var clearsSavedToken = false
  @State private var isTestingConnection = false
  @State private var connectionStatus: String?

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
        .onChange(of: destination.adapter) { oldAdapter, newAdapter in
          if destination.endpoint.isEmpty || destination.endpoint == oldAdapter.defaultEndpoint {
            destination.endpoint = newAdapter.defaultEndpoint
          }
          destination.model = nil
          connectionStatus = nil
        }

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
        } else if destination.adapter == .codexManagedRemote {
          TextField(
            "Codex SSH host",
            text: $destination.endpoint,
            prompt: Text("scarfs-macbook-air")
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
        } else if destination.adapter.isDirectProvider {
          TextField(
            "API base URL",
            text: $destination.endpoint,
            prompt: Text(destination.adapter.defaultEndpoint)
          )
          TextField(
            "Model",
            text: Binding(
              get: { destination.model ?? "" },
              set: { destination.model = $0 }
            ),
            prompt: Text("Provider model ID")
          )
        }

        if destination.acceptsBearerToken && !isBuiltInOpenClaw {
          SecureField(
            credentialLabel,
            text: $token,
            prompt: Text(credentialPrompt)
          )
          if hasSavedToken {
            Toggle("Clear saved token", isOn: $clearsSavedToken)
          }
        }

        if destination.adapter.isDirectProvider {
          HStack(spacing: 10) {
            Button("Test Connection") {
              testConnection()
            }
            .disabled(isTestingConnection || missingRequiredCredential)
            if isTestingConnection {
              ProgressView()
                .controlSize(.small)
            }
            if let connectionStatus {
              Text(connectionStatus)
                .font(.caption)
                .foregroundStyle(connectionStatus.hasPrefix("Connected") ? Color.secondary : Color.red)
            }
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
        .disabled(saveIsDisabled)
      }
    }
    .padding(20)
    .frame(width: 520)
  }

  private var isBuiltIn: Bool {
    destination.id == AIChatDestinationConfiguration.localCodexID
      || destination.id == AIChatDestinationConfiguration.localClaudeID
      || destination.id == AIChatDestinationConfiguration.openClawID
  }

  private var isBuiltInOpenClaw: Bool {
    destination.id == AIChatDestinationConfiguration.openClawID
  }

  private var hasSavedToken: Bool {
    store.aiChatDestinationHasToken(destination.id)
  }

  private var missingRequiredCredential: Bool {
    destination.adapter.requiresAPIKey
      && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (!hasSavedToken || clearsSavedToken)
  }

  private var saveIsDisabled: Bool {
    if destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return true
    }
    if destination.isEnabled,
       destination.adapter.isDirectProvider,
       destination.model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
      return true
    }
    return destination.isEnabled && missingRequiredCredential
  }

  private var credentialLabel: String {
    destination.adapter.isDirectProvider ? "API key" : "Bearer token"
  }

  private var credentialPrompt: String {
    if hasSavedToken && !clearsSavedToken { return "Saved credential unchanged" }
    return destination.adapter.requiresAPIKey ? "Required" : "Optional"
  }

  private func testConnection() {
    isTestingConnection = true
    connectionStatus = nil
    let enteredToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    let apiKey = enteredToken.isEmpty
      ? AIChatDestinationCredentials.readToken(
          destinationID: destination.id,
          allowUserInteraction: true
        )
      : enteredToken
    Task {
      do {
        let settings = try AIProviderChatSettings(
          adapter: destination.adapter,
          endpoint: destination.endpoint,
          apiKey: apiKey
        )
        let models = try await AIProviderChatClient(settings: settings).listModels()
        connectionStatus = models.isEmpty
          ? "Connected · no models reported"
          : "Connected · \(models.count) \(models.count == 1 ? "model" : "models")"
      } catch {
        connectionStatus = error.localizedDescription
      }
      isTestingConnection = false
    }
  }

  private var helpText: String {
    switch destination.adapter {
    case .codexLocal:
      return "Starts a local Codex App Server process on this Mac."
    case .claudeLocal:
      return "Starts the locally installed Claude Code CLI and uses its existing Anthropic sign-in. Conversations resume through Claude Code's local session history."
    case .codexRemote:
      return "Connects to a Codex App Server over WebSocket. Use TLS and a bearer token outside localhost; the workspace path is resolved on the remote machine."
    case .codexManagedRemote:
      return "Attaches through SSH to Codex's managed App Server daemon. Use a host already configured in Codex or ~/.ssh/config; no WebSocket, tunnel, or bearer token is required."
    case .openClaw:
      return isBuiltInOpenClaw
        ? "This default destination uses the existing OpenClaw Gateway configuration."
        : "Routes turns to this OpenClaw gateway and agent ID with its own saved token."
    case .openAI:
      return "Connects directly to OpenAI with your API key. Direct model destinations can discuss Org2 context and images, but they do not receive filesystem or tool access."
    case .anthropic:
      return "Connects directly to Anthropic with your API key. Direct model destinations can discuss Org2 context and images, but they do not receive filesystem or tool access."
    case .openRouter:
      return "Connects directly to any OpenRouter model available to your API key. Enter the exact OpenRouter model ID."
    case .ollama:
      return "Connects to a local or network Ollama server. The default local endpoint needs no API key; enter the model already installed in Ollama."
    }
  }
}
