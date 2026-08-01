import AppKit
import CoreImage
import Org2WorkspaceCore
import SwiftUI

struct WorkspaceSettingsView: View {
  var body: some View {
    TabView {
      AIChatSettingsView()
        .tabItem {
          Label("AI Chat", systemImage: "text.bubble")
        }

      MobileRemoteSettingsView()
        .tabItem {
          Label("Mobile Remote", systemImage: "iphone")
        }
    }
    .frame(width: 600, height: 520)
  }
}

private struct MobileRemoteSettingsView: View {
  @EnvironmentObject private var remote: MobileRemoteCoordinator
  @State private var hostDraft = ""

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
    }
    .onChange(of: remote.bindHost) { _, value in
      hostDraft = value
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
