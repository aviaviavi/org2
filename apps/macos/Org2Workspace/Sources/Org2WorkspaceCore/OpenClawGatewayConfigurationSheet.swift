import SwiftUI

public struct OpenClawGatewayConfigurationSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var endpoint = ""
  @State private var agent = ""
  @State private var handoffAssignee = ""
  @State private var personalAssigneeNames = ""
  @State private var remoteCorpusPath = ""
  @State private var localEditsEnabled = false
  @State private var token = ""
  @State private var clearToken = false
  @State private var isRequestingPairing = false

  public init() {}

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("OpenClaw Gateway")
            .font(.headline.weight(.semibold))
          Text("Configure the gateway used by the built-in OpenClaw destination.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
          GridRow {
            Text("Endpoint")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            TextField("http://127.0.0.1:18789/v1/chat/completions", text: $endpoint)
              .textFieldStyle(.roundedBorder)
              .frame(width: 430)
          }

          GridRow {
            Text("Chat Agent")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            TextField("main", text: $agent)
              .textFieldStyle(.roundedBorder)
              .frame(width: 220)
          }

          GridRow {
            Text("Handoff Assignee")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            TextField("OpenClaw", text: $handoffAssignee)
              .textFieldStyle(.roundedBorder)
              .frame(width: 220)
          }

          GridRow {
            Text("My Assignee Names")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
              TextField("Avi, avi@example.com", text: $personalAssigneeNames)
                .textFieldStyle(.roundedBorder)
                .frame(width: 430)
              Text("Blank ASSIGNEE always counts as you. Separate aliases with commas, semicolons, or new lines.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }

          GridRow {
            Text("Remote Org2 Root")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            TextField("/path/openclaw/can/read", text: $remoteCorpusPath)
              .textFieldStyle(.roundedBorder)
              .frame(width: 430)
          }

          GridRow {
            Text("Local Edits")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
              Toggle("Read and apply Org2 edits on this Mac", isOn: $localEditsEnabled)
              Text("Uses a paired, typed Org2 node with read → preview → apply. It does not expose a shell.")
                .font(.caption2)
                .foregroundStyle(.secondary)
              if localEditsEnabled || store.openClawLocalEditsEnabled {
                Text(
                  "\(store.openClawLocalEditNodeState.label)"
                    + (store.openClawLocalEditNodeDetail.isEmpty ? "" : " — \(store.openClawLocalEditNodeDetail)")
                )
                .font(.caption2)
                .foregroundStyle(
                  store.openClawLocalEditNodeState == .connected ? Color.green : Color.secondary
                )
                .lineLimit(3)
              }
            }
            .frame(width: 430, alignment: .leading)
          }

          GridRow {
            Text("Token")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            SecureField(store.openClawHasStoredToken ? "Saved token unchanged" : "Bearer token or password", text: $token)
              .textFieldStyle(.roundedBorder)
              .frame(width: 430)
          }
        }

        Toggle("Clear saved token", isOn: $clearToken)
          .disabled(!store.openClawHasStoredToken)

        if !store.openClawStatusText.isEmpty {
          Text(store.openClawStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }

        HStack {
          Button {
            guard saveConfiguration() else { return }
            isRequestingPairing = true
            Task {
              await store.requestOpenClawGatewayPairing()
              isRequestingPairing = false
            }
          } label: {
            if isRequestingPairing {
              HStack(spacing: 6) {
                WorkspaceActivityIndicator(size: .small, style: .signal)
                Text("Requesting Pairing")
              }
            } else {
              Label("Save & Request Pairing", systemImage: "lock.open")
            }
          }
          .disabled(isRequestingPairing)
          .help("Create a stable OpenOrg device identity and request Gateway operator access")
          Spacer()
          Button("Cancel") {
            dismiss()
          }
          Button("Save") {
            if saveConfiguration() { dismiss() }
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(22)
    }
    .frame(width: 680)
    .frame(maxHeight: 780)
    .onAppear {
      endpoint = store.openClawEndpointText
      agent = store.openClawAgentID
      handoffAssignee = store.agentHandoffAssignee
      personalAssigneeNames = store.personalAssigneeNamesText
      remoteCorpusPath = store.openClawRemoteCorpusPath
      localEditsEnabled = store.openClawLocalEditsEnabled
      token = ""
      clearToken = false
    }
  }

  private func saveConfiguration() -> Bool {
    return store.saveOpenClawConfiguration(
      endpoint: endpoint,
      agent: agent,
      handoffAssignee: handoffAssignee,
      personalAssigneeNames: personalAssigneeNames,
      remoteCorpusPath: remoteCorpusPath,
      localEditsEnabled: localEditsEnabled,
      token: token,
      clearToken: clearToken
    )
  }
}

