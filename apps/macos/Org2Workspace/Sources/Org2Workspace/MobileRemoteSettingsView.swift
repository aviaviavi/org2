import AppKit
import CoreImage
import Org2WorkspaceCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceSettingsView: View {
  @ObservedObject var softwareUpdates: SoftwareUpdateController

  var body: some View {
    TabView {
      CorpusSettingsView()
        .tabItem {
          Label("Workspace", systemImage: "folder")
        }

      AppearanceSettingsView()
        .tabItem {
          Label("Appearance", systemImage: "circle.lefthalf.filled")
        }

      DocumentSettingsView()
        .tabItem {
          Label("Documents", systemImage: "doc.richtext")
        }

      SharingSettingsView()
        .tabItem {
          Label("Sharing", systemImage: "network")
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

      SoftwareUpdateSettingsView(softwareUpdates: softwareUpdates)
        .tabItem {
          Label("Updates", systemImage: "arrow.triangle.2.circlepath")
        }
    }
    .frame(width: 660, height: 620)
  }
}

private struct CorpusSettingsView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var corpusName = ""
  @State private var corpusKind = "personal"
  @State private var isSaving = false

  var body: some View {
    Form {
      Section {
        if let root = store.corpusRoot {
          TextField("Name", text: $corpusName)

          Picker("Kind", selection: $corpusKind) {
            Text("Personal").tag("personal")
            Text("Project").tag("project")
            Text("Shared").tag("shared")
          }

          LabeledContent("Location") {
            Text(root.path)
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }

          HStack {
            Button("Reveal in Finder") {
              store.launchGuideRevealWorkspace()
            }
            Button("Open Another Corpus…") {
              store.chooseCorpus()
            }
            Spacer()
            Button {
              isSaving = true
              Task {
                _ = await store.updateActiveCorpusIdentity(
                  name: corpusName,
                  kind: corpusKind
                )
                isSaving = false
              }
            } label: {
              if isSaving {
                HStack(spacing: 6) {
                  ProgressView().controlSize(.small)
                  Text("Saving")
                }
              } else {
                Text("Save Corpus Info")
              }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || corpusName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        } else {
          ContentUnavailableView(
            "No Workspace Open",
            systemImage: "folder.badge.questionmark",
            description: Text("Open a corpus to edit its name, kind, or location.")
          )
          Button("Open Corpus…") { store.chooseCorpus() }
        }
      } header: {
        Label("Corpus", systemImage: "folder")
      } footer: {
        Text("The corpus remains an ordinary folder. Move or rename it in Finder, then open its new location here. Its portable name and kind are stored in org2.json.")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 620)
    .frame(minHeight: 460)
    .onAppear(perform: loadCorpusInfo)
    .onChange(of: store.corpusRoot?.standardizedFileURL.path) {
      loadCorpusInfo()
    }
    .onChange(of: store.activeCorpusIdentity) {
      loadCorpusInfo()
    }
  }

  private func loadCorpusInfo() {
    corpusName = store.activeCorpusIdentity?.name
      ?? store.corpusRoot?.lastPathComponent
      ?? ""
    corpusKind = store.activeCorpusIdentity?.kind ?? "personal"
  }
}

private struct MeetingSettingsView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var meetingAutomationEnabled = false
  @State private var meetingAutomationDestinationID = AIChatDestinationConfiguration.openClawID
  @State private var meetingAutomationThreadMode = MeetingReadyAutomationThreadMode.newThread
  @State private var meetingAutomationThreadID: UUID?
  @State private var meetingAutomationPrompt = MeetingReadyAutomationSettings.defaultPrompt

  var body: some View {
    Form {
      Section {
        MeetingTranscriptionSettingsView()
      } header: {
        Label("Meeting Transcription", systemImage: "waveform.badge.mic")
      } footer: {
        Text("These settings apply to recorded and imported meetings. Automatic prefers local Whisper and falls back to macOS Speech when necessary.")
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
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 620)
    .frame(minHeight: 460)
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

        Text("System follows the appearance selected in macOS. Light and Dark keep OpenOrg in that theme regardless of the system setting.")
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

      Section {
        Toggle("Format Org files on save", isOn: $store.formatOrgFilesOnSave)

        Text("Runs the shared Org2 formatter before saving a full .org or .org2 page. Turn this off to preserve layout as typed; .org typing conveniences such as code fences are still saved as standard Org syntax.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Source Editing", systemImage: "text.cursor")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 560)
    .frame(minHeight: 460)
  }
}

private struct SharingSettingsView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var isConfirmingStopAll = false

  var body: some View {
    Form {
      Section {
        if store.localDocumentPublications.isEmpty {
          ContentUnavailableView(
            "No Active Local Links",
            systemImage: "network.slash",
            description: Text("Publish a document to Local Link and it will appear here while OpenOrg is hosting it.")
          )
          .frame(maxWidth: .infinity, minHeight: 180)
        } else {
          ForEach(store.localDocumentPublications) { publication in
            publicationRow(publication)
          }
        }
      } header: {
        Label("Active Local Links", systemImage: "network")
      } footer: {
        Text("These links serve sealed exports, not source files or corpus access. They stop working when OpenOrg quits or when you stop hosting them here.")
      }

      if !store.localDocumentPublications.isEmpty {
        Section {
          Button("Stop Hosting All", role: .destructive) {
            isConfirmingStopAll = true
          }
        }
      }

      Section {
        Label("Local links use unencrypted HTTP and an unguessable bearer URL. Share them only over a trusted local or private network.", systemImage: "lock.open.trianglebadge.exclamationmark")
          .foregroundStyle(.orange)
      } header: {
        Label("Local Link Security", systemImage: "lock.shield")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 620)
    .frame(minHeight: 460)
    .confirmationDialog(
      "Stop hosting every local publication?",
      isPresented: $isConfirmingStopAll
    ) {
      Button("Stop Hosting All", role: .destructive) {
        store.revokeAllLocalDocumentPublications()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every active link will stop working immediately. You can publish the files again later with new links.")
    }
  }

  private func publicationRow(_ publication: LocalDocumentPublication) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: publication.format?.systemImage ?? "doc")
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(publication.title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Text(publication.format?.title ?? publication.mediaType)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }

        if let sourcePath = publication.sourcePath {
          Text(abbreviatedPath(sourcePath))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
        }

        Text(publication.url.absoluteString)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .textSelection(.enabled)

        Text("Hosted \(publication.createdAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      Spacer(minLength: 8)

      HStack(spacing: 8) {
        Button {
          NSWorkspace.shared.open(publication.openURL)
        } label: {
          Image(systemName: "arrow.up.right.square")
        }
        .buttonStyle(.borderless)
        .help("Open shareable link")

        Button {
          copyToPasteboard(publication.url.absoluteString)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy link")

        Button(role: .destructive) {
          store.revokeLocalDocumentPublication(publication.id)
        } label: {
          Image(systemName: "stop.circle")
        }
        .buttonStyle(.borderless)
        .help("Stop hosting")
      }
    }
    .padding(.vertical, 5)
  }

  private func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
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
        Toggle("Allow OpenOrg for iOS to connect", isOn: Binding(
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
        Text("The APNs authentication key is stored only in this Mac’s Keychain. OpenOrg sends a real-time push directly to Apple when an AI reply completes; the key and device token are never written to the corpus.")
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
