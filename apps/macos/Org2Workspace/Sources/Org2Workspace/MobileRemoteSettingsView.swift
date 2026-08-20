import AppKit
import CoreImage
import Org2WorkspaceCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceSettingsView: View {
  var body: some View {
    TabView {
      AppearanceSettingsView()
        .tabItem {
          Label("Appearance", systemImage: "circle.lefthalf.filled")
        }

      DocumentSettingsView()
        .tabItem {
          Label("Documents", systemImage: "doc.richtext")
        }

      MeetingSettingsView()
        .tabItem {
          Label("Meetings", systemImage: "waveform")
        }

      AIChatSettingsView()
        .tabItem {
          Label("AI Chat", systemImage: "text.bubble")
        }

      MobileRemoteSettingsView()
        .tabItem {
          Label("Mobile Remote", systemImage: "iphone")
        }
    }
    .frame(width: 660, height: 620)
  }
}

private struct MeetingSettingsView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    Form {
      Section {
        MeetingTranscriptionSettingsView()
      } header: {
        Label("Meeting Transcription", systemImage: "waveform.badge.mic")
      } footer: {
        Text("These settings apply to recorded and imported meetings. Automatic prefers local Whisper and falls back to macOS Speech when necessary.")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 560)
    .frame(minHeight: 460)
  }
}

private struct AppearanceSettingsView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    Form {
      Section {
        Picker("Theme", selection: $store.appearanceMode) {
          ForEach(WorkspaceAppearanceMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        Text("System follows the appearance selected in macOS. Light and Dark keep Org2 in that theme regardless of the system setting.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("App Theme", systemImage: "paintbrush")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 560)
    .frame(minHeight: 460)
  }
}

private struct DocumentSettingsView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    Form {
      Section {
        Toggle(
          "Expand property drawers by default",
          isOn: $store.propertyDrawersExpandedByDefault
        )

        Text("Controls the initial presentation of property drawers in rendered documents. You can still expand or collapse individual drawers while reading.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Rendered Documents", systemImage: "doc.text.magnifyingglass")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 560)
    .frame(minHeight: 460)
  }
}

private struct MobileRemoteSettingsView: View {
  @EnvironmentObject private var remote: MobileRemoteCoordinator
  @State private var hostDraft = ""
  @State private var pushTeamIDDraft = ""
  @State private var pushKeyIDDraft = ""
  @State private var isImportingPushKey = false

  var body: some View {
    Form {
      Section {
        Toggle("Allow Org2 Mobile to connect", isOn: Binding(
          get: { remote.isEnabled },
          set: { remote.setEnabled($0) }
        ))

        HStack {
          TextField("100.x.y.z", text: $hostDraft)
            .textFieldStyle(.roundedBorder)
            .onSubmit { remote.setBindHost(hostDraft) }
          Button("Use Detected") {
            remote.useDetectedTailscaleAddress()
            hostDraft = remote.bindHost
          }
          Button("Apply") {
            remote.setBindHost(hostDraft)
          }
          .disabled(hostDraft.trimmingCharacters(in: .whitespacesAndNewlines) == remote.bindHost)
        }

        LabeledContent("Port", value: String(MobileRemoteProtocol.defaultPort))
        LabeledContent("Status", value: remote.statusText)

        Text("The listener binds only to this Mac’s Tailscale IPv4 address. Tailscale encrypts the connection; pairing credentials authorize the phone.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Tailscale Connection", systemImage: "network")
      }

      Section {
        Button("Create Pairing Code") {
          remote.generatePairingCode()
        }
        .disabled(!remote.isEnabled || !remote.isListening || remote.endpoint == nil)

        if let code = remote.pairingCode,
           let payload = remote.pairingPayload {
          HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
              Text(code)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
              if let expiration = remote.pairingExpirationText {
                Text("Expires at \(expiration) and works once.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Button("Copy Pairing Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(payload, forType: .string)
              }
            }
            Spacer(minLength: 0)
            if let image = pairingQRCode(payload) {
              Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 132, height: 132)
                .accessibilityLabel("Mobile Remote pairing QR code")
            }
          }
          .padding(.vertical, 6)
        } else {
          Text("Open Remote on the iPhone, then scan the one-time code created here.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } header: {
        Label("Pair iPhone", systemImage: "qrcode")
      }

      Section {
        TextField("Apple Team ID", text: $pushTeamIDDraft)
          .textFieldStyle(.roundedBorder)
          .onSubmit { remote.setPushTeamID(pushTeamIDDraft) }
        TextField("APNs Key ID", text: $pushKeyIDDraft)
          .textFieldStyle(.roundedBorder)
          .onSubmit { remote.setPushKeyID(pushKeyIDDraft) }

        HStack {
          Button("Apply IDs") {
            remote.setPushTeamID(pushTeamIDDraft)
            remote.setPushKeyID(pushKeyIDDraft)
          }
          Button("Import APNs Key…") {
            isImportingPushKey = true
          }
          if remote.pushProviderConfigured {
            Button("Remove Key", role: .destructive) {
              remote.clearPushPrivateKey()
            }
          }
        }

        LabeledContent("Status", value: remote.pushStatusText)
        Text("The APNs authentication key is stored only in this Mac’s Keychain. Org2 sends a quiet push directly to Apple when an AI reply completes; the key and device token are never written to the corpus.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Real-time Reply Notifications", systemImage: "bell.badge")
      }

      Section {
        if remote.pairedDevices.isEmpty {
          Text("No paired mobile devices")
            .foregroundStyle(.secondary)
        } else {
          ForEach(remote.pairedDevices) { device in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if let registeredAt = device.pushRegisteredAt {
                  Text("Push active · registered \(registeredAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.green)
                }
              }
              Spacer()
              Button("Revoke", role: .destructive) {
                remote.revoke(device)
              }
            }
          }
          Button("Revoke All Devices", role: .destructive) {
            remote.revokeAllDevices()
          }
        }
      } header: {
        Label("Paired Devices", systemImage: "lock.shield")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .onAppear {
      hostDraft = remote.bindHost
      pushTeamIDDraft = remote.pushTeamID
      pushKeyIDDraft = remote.pushKeyID
    }
    .onChange(of: remote.bindHost) { _, value in
      hostDraft = value
    }
    .onChange(of: remote.pushTeamID) { _, value in
      pushTeamIDDraft = value
    }
    .onChange(of: remote.pushKeyID) { _, value in
      pushKeyIDDraft = value
    }
    .fileImporter(
      isPresented: $isImportingPushKey,
      allowedContentTypes: [.data],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else { return }
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      guard let data = try? Data(contentsOf: url) else { return }
      remote.importPushPrivateKey(data)
    }
  }

  private func pairingQRCode(_ payload: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
      return nil
    }
    let representation = NSCIImageRep(ciImage: output)
    let image = NSImage(size: representation.size)
    image.addRepresentation(representation)
    return image
  }
}
