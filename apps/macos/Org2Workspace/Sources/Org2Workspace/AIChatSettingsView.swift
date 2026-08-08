import Org2WorkspaceCore
import SwiftUI

struct AIChatSettingsView: View {
  @EnvironmentObject private var store: WorkspaceStore

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
    .frame(width: 560)
    .frame(minHeight: 460)
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
}
