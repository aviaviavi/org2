import Combine
import Darwin
import Foundation
import Org2WorkspaceCore
import Security

struct MobileRemotePairedDevice: Codable, Identifiable, Hashable {
  let id: UUID
  let name: String
  let pairedAt: Date
  let pushRegisteredAt: Date?

  init(id: UUID, name: String, pairedAt: Date, pushRegisteredAt: Date? = nil) {
    self.id = id
    self.name = name
    self.pairedAt = pairedAt
    self.pushRegisteredAt = pushRegisteredAt
  }
}

@MainActor
final class MobileRemoteCoordinator: ObservableObject {
  @Published private(set) var isEnabled: Bool
  @Published private(set) var bindHost: String
  @Published private(set) var isListening = false
  @Published private(set) var statusText = "Off"
  @Published private(set) var pairingCode: String?
  @Published private(set) var pairingExpiresAt: Date?
  @Published private(set) var pairedDevices: [MobileRemotePairedDevice]
  @Published private(set) var pushTeamID: String
  @Published private(set) var pushKeyID: String
  @Published private(set) var pushProviderConfigured: Bool
  @Published private(set) var pushStatusText: String

  private static let enabledKey = "Org2Workspace.mobileRemote.enabled.v1"
  private static let bindHostKey = "Org2Workspace.mobileRemote.bindHost.v1"
  private static let pairingLifetime: TimeInterval = 10 * 60

  private let defaults: UserDefaults
  private let credentialVault: MobileRemoteCredentialVault
  private let pushCredentialStore: MobileRemotePushCredentialStore
  private let pushSender: MobileRemotePushSender
  private weak var store: WorkspaceStore?
  private var server: MobileRemoteHTTPServer?
  private var failedPairingAttempts = 0
  private var serverGeneration = 0

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    pushCredentialStore = MobileRemotePushCredentialStore(defaults: defaults)
    pushSender = MobileRemotePushSender()
    credentialVault = MobileRemoteCredentialVault()
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    let savedHost = defaults.string(forKey: Self.bindHostKey) ?? ""
    bindHost = savedHost.isEmpty ? (Self.tailscaleIPv4Addresses().first ?? "") : savedHost
    pairedDevices = credentialVault.devices
    pushTeamID = pushCredentialStore.teamID
    pushKeyID = pushCredentialStore.keyID
    pushProviderConfigured = pushCredentialStore.isConfigured
    pushStatusText = pushCredentialStore.isConfigured
      ? "Ready for real-time iPhone alerts"
      : "Import an APNs authentication key to enable real-time alerts"
  }

  var endpoint: String? {
    guard Self.isTailscaleIPv4(bindHost) else { return nil }
    return "http://\(bindHost):\(MobileRemoteProtocol.defaultPort)"
  }

  var pairingPayload: String? {
    guard let endpoint, let pairingCode else { return nil }
    var components = URLComponents()
    components.scheme = "org2-remote"
    components.host = "pair"
    components.queryItems = [
      URLQueryItem(name: "endpoint", value: endpoint),
      URLQueryItem(name: "code", value: pairingCode),
      URLQueryItem(name: "name", value: Self.serverName)
    ]
    return components.string
  }

  var pairingExpirationText: String? {
    guard let pairingExpiresAt else { return nil }
    return pairingExpiresAt.formatted(date: .omitted, time: .shortened)
  }

  func attach(to store: WorkspaceStore) {
    self.store = store
    store.openClawIncomingMessageHandler = { [weak self] thread, messages in
      self?.enqueuePushNotifications(for: thread, messages: messages)
    }
  }

  func setPushTeamID(_ value: String) {
    pushCredentialStore.setTeamID(value)
    refreshPushProviderState()
  }

  func setPushKeyID(_ value: String) {
    pushCredentialStore.setKeyID(value)
    refreshPushProviderState()
  }

  func importPushPrivateKey(_ data: Data) {
    do {
      try pushCredentialStore.importPrivateKey(data)
      refreshPushProviderState()
      pushStatusText = "APNs key saved securely in Keychain"
    } catch {
      pushStatusText = error.localizedDescription
    }
  }

  func clearPushPrivateKey() {
    do {
      try pushCredentialStore.clearPrivateKey()
      refreshPushProviderState()
      pushStatusText = "APNs key removed"
    } catch {
      pushStatusText = error.localizedDescription
    }
  }

  func startIfConfigured() {
    guard isEnabled, server == nil else { return }
    start()
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
    if enabled {
      start()
    } else {
      stop()
    }
  }

  func setBindHost(_ host: String) {
    let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard bindHost != normalized else { return }
    bindHost = normalized
    defaults.set(normalized, forKey: Self.bindHostKey)
    if isEnabled {
      start()
    }
  }

  func useDetectedTailscaleAddress() {
    guard let address = Self.tailscaleIPv4Addresses().first else { return }
    setBindHost(address)
  }

  func generatePairingCode() {
    guard isEnabled, isListening, endpoint != nil else {
      statusText = "Turn on Mobile Remote with a valid Tailscale address first."
      return
    }
    var random: UInt32 = 0
    let result = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &random)
    guard result == errSecSuccess else {
      statusText = "Could not create a secure pairing code."
      return
    }
    pairingCode = String(format: "%06u", random % 1_000_000)
    pairingExpiresAt = Date().addingTimeInterval(Self.pairingLifetime)
    failedPairingAttempts = 0
  }

  func revoke(_ device: MobileRemotePairedDevice) {
    do {
      try credentialVault.revoke(device.id)
      pairedDevices = credentialVault.devices
      statusText = "Revoked \(device.name)"
    } catch {
      statusText = "Could not revoke \(device.name): \(error.localizedDescription)"
    }
  }

  func revokeAllDevices() {
    do {
      try credentialVault.revokeAll()
      pairedDevices = []
      statusText = "Revoked all mobile devices"
    } catch {
      statusText = "Could not revoke mobile devices: \(error.localizedDescription)"
    }
  }

  private func start() {
    guard store != nil else {
      statusText = "Waiting for the workspace"
      return
    }
    guard Self.isTailscaleIPv4(bindHost) else {
      stopServer()
      statusText = "Enter this Mac’s Tailscale IPv4 address"
      return
    }

    serverGeneration &+= 1
    let generation = serverGeneration
    server?.stop()
    server = nil
    isListening = false
    let server = MobileRemoteHTTPServer(
      handler: { [weak self] request in
        guard let self else {
          return .error("The Org2 workspace is unavailable.", statusCode: 503)
        }
        return await self.handle(request)
      },
      stateHandler: { [weak self] state in
        Task { @MainActor in
          guard self?.serverGeneration == generation else { return }
          self?.statusText = state
          self?.isListening = state.hasPrefix("Listening on ")
        }
      }
    )
    do {
      try server.start(host: bindHost, port: MobileRemoteProtocol.defaultPort)
      self.server = server
    } catch {
      self.server = nil
      statusText = error.localizedDescription
    }
  }

  private func stop() {
    stopServer()
    pairingCode = nil
    pairingExpiresAt = nil
    failedPairingAttempts = 0
    statusText = "Off"
  }

  private func stopServer() {
    serverGeneration &+= 1
    server?.stop()
    server = nil
    isListening = false
  }

  private func handle(_ request: MobileRemoteHTTPRequest) async -> MobileRemoteHTTPResponse {
    let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
    if request.method == "POST", path == "/v1/pair" {
      return handlePair(request)
    }

    guard let token = request.bearerToken, credentialVault.contains(token: token) else {
      return .error("Pair this device with the Mac again.", statusCode: 401)
    }
    guard let store else {
      return .error("The Org2 workspace is unavailable.", statusCode: 503)
    }

    if request.method == "GET", path == "/v1/status" {
      let threads = store.openClawChatThreads
      return .json(MobileRemoteServerStatus(
        serverName: Self.serverName,
        corpusName: store.corpusRoot?.lastPathComponent,
        threadCount: threads.count,
        runningThreadCount: threads.filter { store.isAIChatThreadRunning($0.id) }.count,
        aiChatDestinations: store.enabledAIChatDestinations.map {
          MobileRemoteAIDestination(
            id: $0.id,
            name: $0.name,
            mention: $0.mention,
            runtime: $0.runtime.rawValue
          )
        },
        pushNotificationsSupported: true,
        pushNotificationsConfigured: pushProviderConfigured
      ))
    }

    if request.method == "POST", path == "/v1/push-registration" {
      guard let payload = try? request.decode(MobileRemotePushRegistrationRequest.self) else {
        return .error("The push registration could not be read.", statusCode: 400)
      }
      do {
        let enabled = try credentialVault.setPushRegistration(payload, forAccessToken: token)
        pairedDevices = credentialVault.devices
        return .json(MobileRemotePushRegistrationResponse(
          enabled: enabled,
          providerConfigured: pushProviderConfigured
        ))
      } catch {
        return .error(error.localizedDescription, statusCode: 400)
      }
    }

    if request.method == "POST", path == "/v1/push-test" {
      guard pushProviderConfigured else {
        return .error("Finish push notification setup in the Mac app.", statusCode: 503)
      }
      guard let registration = credentialVault.pushRegistration(forAccessToken: token) else {
        return .error("This iPhone has not registered for push notifications.", statusCode: 409)
      }
      let threadID = store.openClawChatThreads.first?.id ?? UUID()
      do {
        try await deliverPush(
          MobileRemotePushEnvelope(
            messageID: UUID(),
            threadID: threadID,
            title: "Org2 reply notifications",
            body: "Real-time notifications are working on this iPhone."
          ),
          to: registration.registration
        )
        return .json(MobileRemoteMutationResponse(accepted: true, threadID: threadID), statusCode: 202)
      } catch {
        pushStatusText = error.localizedDescription
        return .error(error.localizedDescription, statusCode: 502)
      }
    }

    if request.method == "GET", path == "/v1/threads" {
      return .json(MobileRemoteThreadList(threads: store.openClawChatThreads.map {
        threadSummary($0, store: store)
      }))
    }

    if request.method == "POST", path == "/v1/threads" {
      guard let payload = try? request.decode(MobileRemoteCreateThreadRequest.self) else {
        return .error("Choose a configured AI destination.", statusCode: 400)
      }
      let id: UUID
      if let destinationID = payload.destinationID {
        guard store.enabledAIChatDestinations.contains(where: { $0.id == destinationID }) else {
          return .error("That AI destination is unavailable on the Mac.", statusCode: 400)
        }
        id = store.createAIChatRemoteThread(destinationID: destinationID)
      } else {
        guard let runtime = AIChatRuntime(rawValue: payload.runtime) else {
          return .error("Choose either the codex or openClaw runtime.", statusCode: 400)
        }
        id = store.createAIChatRemoteThread(runtime: runtime)
      }
      return .json(MobileRemoteMutationResponse(accepted: true, threadID: id), statusCode: 201)
    }

    if request.method == "GET", path == "/v1/workspace" {
      return .json(await store.mobileRemoteWorkspaceSnapshot())
    }

    let workspaceComponents = path.split(separator: "/").map(String.init)
    if workspaceComponents.count >= 5,
       workspaceComponents[0] == "v1",
       workspaceComponents[1] == "workspace",
       let itemID = workspaceComponents[3].removingPercentEncoding {
      do {
        if request.method == "POST",
           workspaceComponents[2] == "agenda",
           workspaceComponents[4] == "status",
           let payload = try? request.decode(MobileRemoteAgendaStatusRequest.self) {
          return .json(try await store.setMobileRemoteAgendaStatus(
            itemID: itemID,
            status: payload.status
          ))
        }
        if request.method == "POST",
           workspaceComponents[2] == "approvals",
           workspaceComponents[4] == "decision",
           let payload = try? request.decode(MobileRemoteApprovalDecisionRequest.self) {
          return .json(try await store.decideMobileRemoteApproval(
            itemID: itemID,
            decision: payload.decision,
            note: payload.note,
            endStatus: payload.endStatus
          ))
        }
        if request.method == "POST",
           workspaceComponents[2] == "workflows",
           workspaceComponents[4] == "state",
           let payload = try? request.decode(MobileRemoteWorkflowStateRequest.self) {
          return .json(try await store.setMobileRemoteWorkflowState(
            workflowID: itemID,
            state: payload.state
          ))
        }
        if request.method == "POST",
           workspaceComponents[2] == "workflows",
           workspaceComponents[4] == "run",
           let payload = try? request.decode(MobileRemoteWorkflowRunRequest.self) {
          let threadID = try await store.runMobileRemoteWorkflow(
            workflowID: itemID,
            inputs: payload.inputs
          )
          return .json(
            MobileRemoteMutationResponse(accepted: true, threadID: threadID),
            statusCode: 202
          )
        }
      } catch {
        return .error(error.localizedDescription, statusCode: 409)
      }
      return .error("Workspace action not found.", statusCode: 404)
    }

    if request.method == "POST", path == "/v1/files/preview" {
      guard let payload = try? request.decode(MobileRemoteFilePreviewRequest.self) else {
        return .error("The cited file reference could not be read.", statusCode: 400)
      }
      do {
        return .json(try store.mobileRemoteFilePreview(path: payload.path, line: payload.line))
      } catch {
        return .error(error.localizedDescription, statusCode: 404)
      }
    }

    if request.method == "GET", path == "/v1/external-threads" {
      do {
        return .json(ExternalThreadList(threads: try await store.externalThreadSummaries()))
      } catch {
        return .error(error.localizedDescription, statusCode: 503)
      }
    }

    let externalComponents = path.split(separator: "/").map(String.init)
    if externalComponents.count >= 4,
       externalComponents[0] == "v1",
       externalComponents[1] == "external-threads",
       let harness = ExternalThreadHarness(rawValue: externalComponents[2]),
       let externalID = externalComponents[3].removingPercentEncoding {
      do {
        let detail = try await store.externalThreadDetail(
          harness: harness,
          externalID: externalID
        )
        if request.method == "GET", externalComponents.count == 4 {
          return .json(detail)
        }
        if request.method == "POST",
           externalComponents.count == 5,
           externalComponents[4] == "continue" {
          let threadID = try await store.continueExternalThreadInOrg2(
            detail,
            selectsThread: false
          )
          return .json(
            MobileRemoteMutationResponse(accepted: true, threadID: threadID),
            statusCode: 201
          )
        }
      } catch {
        return .error(error.localizedDescription, statusCode: 503)
      }
      return .error("External thread action not found.", statusCode: 404)
    }

    let components = path.split(separator: "/").map(String.init)
    guard components.count >= 3,
          components[0] == "v1",
          components[1] == "threads",
          let threadID = UUID(uuidString: components[2]),
          let thread = store.openClawChatThreads.first(where: { $0.id == threadID })
    else {
      return .error("Thread not found.", statusCode: 404)
    }

    if request.method == "GET", components.count == 3 {
      return .json(threadDetail(thread, store: store))
    }
    if request.method == "GET", components.count == 4, components[3] == "configuration" {
      do {
        let configuration = try await store.aiChatRemoteConfiguration(for: threadID)
        let current = store.openClawChatThreads.first(where: { $0.id == threadID }) ?? thread
        return .json(threadConfiguration(configuration, thread: current))
      } catch {
        return .error(error.localizedDescription, statusCode: 503)
      }
    }
    if request.method == "POST", components.count == 4, components[3] == "configuration" {
      guard let payload = try? request.decode(MobileRemoteUpdateThreadConfigurationRequest.self) else {
        return .error("Choose a valid chat configuration.", statusCode: 400)
      }
      do {
        switch payload.setting {
        case "model":
          _ = try await store.setAIChatRemoteModel(payload.value, threadID: threadID)
        case "reasoning":
          try await store.setAIChatRemoteReasoningEffort(payload.value, threadID: threadID)
        default:
          return .error("Choose either model or reasoning to update.", statusCode: 400)
        }
        let configuration = try await store.aiChatRemoteConfiguration(for: threadID)
        let current = store.openClawChatThreads.first(where: { $0.id == threadID }) ?? thread
        return .json(threadConfiguration(configuration, thread: current))
      } catch {
        return .error(error.localizedDescription, statusCode: 409)
      }
    }
    if request.method == "POST", components.count == 4, components[3] == "state" {
      guard let payload = try? request.decode(MobileRemoteUpdateThreadStateRequest.self),
            payload.isPinned != nil || payload.isSettled != nil
      else {
        return .error("Choose a pin or settlement state to update.", statusCode: 400)
      }
      guard store.updateAIChatRemoteThreadState(
        threadID: threadID,
        isPinned: payload.isPinned,
        isSettled: payload.isSettled
      ), let updated = store.openClawChatThreads.first(where: { $0.id == threadID }) else {
        return .error("Thread not found.", statusCode: 404)
      }
      return .json(threadSummary(updated, store: store))
    }
    if request.method == "POST", components.count == 4, components[3] == "fork" {
      guard let forkedThreadID = store.forkAIChatThread(threadID, selectsThread: false) else {
        return .error("This thread could not be forked.", statusCode: 409)
      }
      return .json(
        MobileRemoteMutationResponse(accepted: true, threadID: forkedThreadID),
        statusCode: 201
      )
    }
    if request.method == "POST", components.count == 4, components[3] == "messages" {
      guard let payload = try? request.decode(MobileRemoteSendMessageRequest.self) else {
        return .error("The message could not be read.", statusCode: 400)
      }
      let attachments: [OpenClawChatAttachment]
      do {
        attachments = try Self.chatAttachments(from: payload.attachments)
      } catch {
        return .error(error.localizedDescription, statusCode: 400)
      }
      guard let destinationThreadID = store.sendAIChatRemoteMessageDestination(
        payload.content,
        attachments: attachments,
        threadID: threadID,
        delivery: payload.delivery.flatMap(AIChatMessageDeliveryPreference.init(rawValue:))
          ?? .automatic
      ) else {
        return .error("The message is empty or this thread is settled.", statusCode: 409)
      }
      return .json(
        MobileRemoteMutationResponse(accepted: true, threadID: destinationThreadID),
        statusCode: 202
      )
    }
    if request.method == "POST", components.count == 4, components[3] == "stop" {
      let stopped = await store.stopAIChatRemoteRun(threadID: threadID)
      return stopped
        ? .json(MobileRemoteMutationResponse(accepted: true, threadID: threadID), statusCode: 202)
        : .error("There is no live turn to stop.", statusCode: 409)
    }
    return .error("Remote action not found.", statusCode: 404)
  }

  private func handlePair(_ request: MobileRemoteHTTPRequest) -> MobileRemoteHTTPResponse {
    guard let payload = try? request.decode(MobileRemotePairRequest.self) else {
      return .error("Invalid pairing request.", statusCode: 400)
    }
    guard let pairingCode,
          let pairingExpiresAt,
          pairingExpiresAt > Date(),
          pairingCode == payload.code
    else {
      failedPairingAttempts += 1
      if failedPairingAttempts >= 10 {
        self.pairingCode = nil
        self.pairingExpiresAt = nil
        failedPairingAttempts = 0
      }
      return .error("The pairing code is invalid or expired.", statusCode: 401)
    }

    do {
      let paired = try credentialVault.pair(deviceName: payload.deviceName)
      pairedDevices = credentialVault.devices
      self.pairingCode = nil
      self.pairingExpiresAt = nil
      failedPairingAttempts = 0
      statusText = "Paired \(paired.device.name)"
      return .json(MobileRemotePairResponse(
        serverName: Self.serverName,
        deviceID: paired.device.id,
        accessToken: paired.token
      ), statusCode: 201)
    } catch {
      return .error("Could not save the paired device.", statusCode: 500)
    }
  }

  private func refreshPushProviderState() {
    pushTeamID = pushCredentialStore.teamID
    pushKeyID = pushCredentialStore.keyID
    pushProviderConfigured = pushCredentialStore.isConfigured
    if pushProviderConfigured {
      pushStatusText = "Ready for real-time iPhone alerts"
    } else if pushTeamID.isEmpty || pushKeyID.isEmpty {
      pushStatusText = "Enter the Apple Team ID and APNs Key ID"
    } else {
      pushStatusText = "Import the APNs authentication key"
    }
  }

  private func enqueuePushNotifications(
    for thread: OpenClawChatThread,
    messages: [OpenClawChatMessage]
  ) {
    guard pushProviderConfigured, !messages.isEmpty else { return }
    let registrations = credentialVault.pushRegistrations
    guard !registrations.isEmpty else { return }
    for message in messages {
      let visibleText = WorkspaceStore.visibleAIChatMessageText(message)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let envelope = MobileRemotePushEnvelope(
        messageID: message.id,
        threadID: thread.id,
        title: thread.title,
        body: visibleText.isEmpty
          ? "An AI agent replied."
          : String(visibleText.prefix(220))
      )
      for registration in registrations {
        Task { [weak self] in
          guard let self else { return }
          do {
            try await self.deliverPush(envelope, to: registration.registration)
            self.pushStatusText = "Last push delivered at \(Date().formatted(date: .omitted, time: .shortened))"
          } catch let error as MobileRemotePushError {
            self.pushStatusText = error.localizedDescription
            if error.invalidatesDeviceToken {
              try? self.credentialVault.clearPushRegistration(deviceID: registration.deviceID)
              self.pairedDevices = self.credentialVault.devices
            }
          } catch {
            self.pushStatusText = error.localizedDescription
          }
        }
      }
    }
  }

  private func deliverPush(
    _ envelope: MobileRemotePushEnvelope,
    to registration: MobileRemoteStoredPushRegistration
  ) async throws {
    let credentialStore = pushCredentialStore
    let credentials = await Task.detached(priority: .userInitiated) {
      credentialStore.credentials
    }.value
    guard let credentials else {
      throw MobileRemotePushError.deliveryFailed("APNs credentials are not configured.")
    }
    try await pushSender.send(envelope, to: registration, credentials: credentials)
  }

  private func threadSummary(_ thread: OpenClawChatThread, store: WorkspaceStore) -> MobileRemoteThreadSummary {
    let destination = store.aiChatDestination(id: thread.destinationID)
    let preview = thread.messages
      .last(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      .map(WorkspaceStore.visibleAIChatMessageText)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let latestAssistantMessage = thread.messages.last(where: {
      $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })
    return MobileRemoteThreadSummary(
      id: thread.id,
      title: thread.title,
      runtime: thread.runtime.rawValue,
      destinationID: thread.destinationID,
      destinationName: thread.isSharedRoom ? "Shared AI Room" : destination?.name,
      isSharedRoom: thread.isSharedRoom,
      model: thread.model,
      updatedAt: thread.updatedAt,
      isSettled: thread.isSettled,
      isPinned: thread.isPinned,
      isRunning: store.isAIChatThreadRunning(thread.id),
      unreadMessageCount: thread.unreadMessageCount,
      preview: preview.map { String($0.prefix(180)) },
      latestAssistantMessageID: latestAssistantMessage?.id,
      latestAssistantPreview: latestAssistantMessage.map {
        String($0.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
      }
    )
  }

  private func threadDetail(_ thread: OpenClawChatThread, store: WorkspaceStore) -> MobileRemoteThreadDetail {
    let activeDestinationName = store.aiChatActiveDestinationID(for: thread.id)
      .map(store.aiChatDestinationTitle)
    return MobileRemoteThreadDetail(
      thread: threadSummary(thread, store: store),
      messages: thread.messages.map {
        let authorDestination = $0.authorDestinationID.flatMap(store.aiChatDestination(id:))
        let audienceDestinationIDs = $0.audienceDestinationIDs.isEmpty
          ? [$0.targetDestinationID].compactMap { $0 }
          : $0.audienceDestinationIDs
        return MobileRemoteChatMessage(
          id: $0.id,
          role: $0.role.rawValue,
          content: $0.content,
          attachmentNames: $0.attachments.compactMap(\.fileName),
          createdAt: $0.createdAt,
          deliveryStatus: $0.deliveryStatus.rawValue,
          deliveryKind: $0.deliveryKind.rawValue,
          sendFailure: $0.sendFailure,
          authorRuntime: $0.authorRuntime?.rawValue,
          authorDestinationID: $0.authorDestinationID,
          authorDestinationName: authorDestination?.name,
          audience: $0.audience?.rawValue,
          audienceDestinationNames: audienceDestinationIDs.compactMap {
            store.aiChatDestination(id: $0)?.name
          },
          isRoomDispatchCopy: $0.isRoomDispatchCopy,
          roomRoundID: $0.roomRoundID
        )
      },
      activeDestinationName: activeDestinationName,
      streamingReply: store.aiChatStreamingReply(for: thread.id),
      reasoning: store.aiChatReasoning(for: thread.id),
      activities: MobileRemoteActivityPresentation.items(
        from: store.aiChatRunActivities(for: thread.id)
      ),
      connectionState: store.aiChatConnectionState(for: thread.id).rawValue,
      connectionDetail: store.aiChatConnectionDetail(for: thread.id)
    )
  }

  private static var serverName: String {
    Host.current().localizedName ?? "Org2 on Mac"
  }

  private func threadConfiguration(
    _ configuration: AIChatRemoteConfiguration,
    thread: OpenClawChatThread
  ) -> MobileRemoteThreadConfiguration {
    MobileRemoteThreadConfiguration(
      threadID: thread.id,
      model: thread.model,
      models: configuration.models.map {
        MobileRemoteModelOption(
          id: $0.id,
          label: $0.label,
          detail: $0.detail,
          isDefault: $0.isDefault
        )
      },
      reasoningEffort: thread.reasoningEffort,
      reasoningOptions: configuration.reasoningOptions.map {
        MobileRemoteReasoningOption(id: $0.id, label: $0.label, detail: $0.detail)
      },
      defaultReasoningEffort: configuration.defaultReasoningEffort
    )
  }

  private static func chatAttachments(
    from payloads: [MobileRemoteAttachment]
  ) throws -> [OpenClawChatAttachment] {
    guard payloads.count <= 4 else {
      throw MobileRemoteRequestError.tooManyPhotos
    }
    var totalBytes = 0
    return try payloads.map { payload in
      let mimeType = payload.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard mimeType.hasPrefix("image/") else {
        throw MobileRemoteRequestError.unsupportedAttachment(payload.fileName)
      }
      guard !payload.data.isEmpty, payload.data.count <= 5_000_000 else {
        throw MobileRemoteRequestError.photoTooLarge(payload.fileName)
      }
      totalBytes += payload.data.count
      guard totalBytes <= 8_000_000 else {
        throw MobileRemoteRequestError.photosTooLarge
      }
      let fileName = URL(fileURLWithPath: payload.fileName).lastPathComponent
      guard !fileName.isEmpty else {
        throw MobileRemoteRequestError.unsupportedAttachment("Photo")
      }
      return OpenClawChatAttachment(
        fileName: fileName,
        mimeType: mimeType,
        data: payload.data
      )
    }
  }

  static func isTailscaleIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { return false }
    return parts[0] == 100 && (64...127).contains(parts[1])
  }

  static func tailscaleIPv4Addresses() -> [String] {
    var firstAddress: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
    defer { freeifaddrs(firstAddress) }

    var results: [String] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }
      guard let address = current.pointee.ifa_addr,
            address.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let length = socklen_t(address.pointee.sa_len)
      guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
        continue
      }
      let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      let value = String(decoding: bytes, as: UTF8.self)
      if isTailscaleIPv4(value), !results.contains(value) {
        results.append(value)
      }
    }
    return results.sorted()
  }
}

private enum MobileRemoteRequestError: LocalizedError {
  case tooManyPhotos
  case photoTooLarge(String)
  case photosTooLarge
  case unsupportedAttachment(String)

  var errorDescription: String? {
    switch self {
    case .tooManyPhotos:
      "Attach no more than four photos at a time."
    case .photoTooLarge(let name):
      "\(name) is too large to send from Mobile Remote."
    case .photosTooLarge:
      "The selected photos are too large to send together."
    case .unsupportedAttachment(let name):
      "\(name) is not a supported photo attachment."
    }
  }
}

private final class MobileRemoteCredentialVault {
  struct PushTarget: Sendable {
    let deviceID: UUID
    let registration: MobileRemoteStoredPushRegistration
  }

  private struct Record: Codable {
    let device: MobileRemotePairedDevice
    let token: String
    var pushRegistration: MobileRemoteStoredPushRegistration?
  }

  private let service = (Bundle.main.bundleIdentifier ?? "org.org2.workspace") + ".mobile-remote"
  private let account = "paired-devices"
  private var records: [Record]

  init() {
    records = []
    records = load()
  }

  var devices: [MobileRemotePairedDevice] {
    records.map { record in
      MobileRemotePairedDevice(
        id: record.device.id,
        name: record.device.name,
        pairedAt: record.device.pairedAt,
        pushRegisteredAt: record.pushRegistration?.registeredAt
      )
    }.sorted { $0.pairedAt > $1.pairedAt }
  }

  var pushRegistrations: [PushTarget] {
    records.compactMap { record in
      record.pushRegistration.map {
        PushTarget(deviceID: record.device.id, registration: $0)
      }
    }
  }

  func contains(token: String) -> Bool {
    records.contains { Self.securelyEqual($0.token, token) }
  }

  func pair(deviceName rawName: String) throws -> (device: MobileRemotePairedDevice, token: String) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let device = MobileRemotePairedDevice(
      id: UUID(),
      name: String((name.isEmpty ? "iPhone" : name).prefix(80)),
      pairedAt: Date()
    )
    let token = try Self.randomToken()
    records.append(Record(device: device, token: token, pushRegistration: nil))
    do {
      try save()
    } catch {
      records.removeAll { $0.device.id == device.id }
      throw error
    }
    return (device, token)
  }

  func setPushRegistration(
    _ request: MobileRemotePushRegistrationRequest,
    forAccessToken accessToken: String
  ) throws -> Bool {
    guard let index = records.firstIndex(where: { Self.securelyEqual($0.token, accessToken) }) else {
      throw MobileRemoteCredentialError.unknownDevice
    }
    let previous = records[index].pushRegistration
    if request.enabled {
      guard let deviceToken = request.deviceToken?.lowercased(),
            !deviceToken.isEmpty,
            deviceToken.count <= 512,
            deviceToken.allSatisfy(\.isHexDigit),
            let environment = request.environment,
            environment == "production" || environment == "sandbox"
      else {
        throw MobileRemoteCredentialError.invalidPushRegistration
      }
      records[index].pushRegistration = MobileRemoteStoredPushRegistration(
        deviceToken: deviceToken,
        environment: environment
      )
    } else {
      records[index].pushRegistration = nil
    }
    do {
      try save()
    } catch {
      records[index].pushRegistration = previous
      throw error
    }
    return records[index].pushRegistration != nil
  }

  func pushRegistration(forAccessToken accessToken: String) -> PushTarget? {
    records.first(where: { Self.securelyEqual($0.token, accessToken) }).flatMap { record in
      record.pushRegistration.map {
        PushTarget(deviceID: record.device.id, registration: $0)
      }
    }
  }

  func clearPushRegistration(deviceID: UUID) throws {
    guard let index = records.firstIndex(where: { $0.device.id == deviceID }) else { return }
    let previous = records[index].pushRegistration
    records[index].pushRegistration = nil
    do {
      try save()
    } catch {
      records[index].pushRegistration = previous
      throw error
    }
  }

  func revoke(_ id: UUID) throws {
    let previous = records
    records.removeAll { $0.device.id == id }
    do {
      try save()
    } catch {
      records = previous
      throw error
    }
  }

  func revokeAll() throws {
    let previous = records
    records = []
    do {
      try save()
    } catch {
      records = previous
      throw error
    }
  }

  private func load() -> [Record] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else {
      return []
    }
    return (try? MobileRemoteProtocol.decoder().decode([Record].self, from: data)) ?? []
  }

  private func save() throws {
    let data = try MobileRemoteProtocol.encoder().encode(records)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var addition = query
      attributes.forEach { addition[$0.key] = $0.value }
      let added = SecItemAdd(addition as CFDictionary, nil)
      guard added == errSecSuccess else { throw MobileRemoteCredentialError.keychain(added) }
    } else if status != errSecSuccess {
      throw MobileRemoteCredentialError.keychain(status)
    }
  }

  private static func randomToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = bytes.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else { throw MobileRemoteCredentialError.keychain(status) }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func securelyEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}

private enum MobileRemoteCredentialError: LocalizedError {
  case keychain(OSStatus)
  case invalidPushRegistration
  case unknownDevice

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      "Keychain error \(status)"
    case .invalidPushRegistration:
      "The iPhone supplied an invalid push registration."
    case .unknownDevice:
      "Pair this device with the Mac again."
    }
  }
}
