import Combine
import Darwin
import Foundation
import Org2WorkspaceCore
import Security

struct MobileRemotePairedDevice: Codable, Identifiable, Hashable {
  let id: UUID
  let name: String
  let pairedAt: Date
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

  private static let enabledKey = "Org2Workspace.mobileRemote.enabled.v1"
  private static let bindHostKey = "Org2Workspace.mobileRemote.bindHost.v1"
  private static let pairingLifetime: TimeInterval = 10 * 60

  private let defaults: UserDefaults
  private let credentialVault: MobileRemoteCredentialVault
  private weak var store: WorkspaceStore?
  private var server: MobileRemoteHTTPServer?
  private var failedPairingAttempts = 0
  private var serverGeneration = 0

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    credentialVault = MobileRemoteCredentialVault()
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    let savedHost = defaults.string(forKey: Self.bindHostKey) ?? ""
    bindHost = savedHost.isEmpty ? (Self.tailscaleIPv4Addresses().first ?? "") : savedHost
    pairedDevices = credentialVault.devices
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
        runningThreadCount: threads.filter { store.isAIChatThreadRunning($0.id) }.count
      ))
    }

    if request.method == "GET", path == "/v1/threads" {
      return .json(MobileRemoteThreadList(threads: store.openClawChatThreads.map {
        threadSummary($0, store: store)
      }))
    }

    if request.method == "POST", path == "/v1/threads" {
      guard let payload = try? request.decode(MobileRemoteCreateThreadRequest.self),
            let runtime = AIChatRuntime(rawValue: payload.runtime)
      else {
        return .error("Choose either the codex or openClaw runtime.", statusCode: 400)
      }
      let id = store.createAIChatRemoteThread(runtime: runtime)
      return .json(MobileRemoteMutationResponse(accepted: true, threadID: id), statusCode: 201)
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
    if request.method == "POST", components.count == 4, components[3] == "messages" {
      guard let payload = try? request.decode(MobileRemoteSendMessageRequest.self),
            store.sendAIChatRemoteMessage(payload.content, threadID: threadID)
      else {
        return .error("The message is empty or this thread is settled.", statusCode: 409)
      }
      return .json(MobileRemoteMutationResponse(accepted: true, threadID: threadID), statusCode: 202)
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

  private func threadSummary(_ thread: OpenClawChatThread, store: WorkspaceStore) -> MobileRemoteThreadSummary {
    let preview = thread.messages.last(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
      .content
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return MobileRemoteThreadSummary(
      id: thread.id,
      title: thread.title,
      runtime: thread.runtime.rawValue,
      model: thread.model,
      updatedAt: thread.updatedAt,
      isSettled: thread.isSettled,
      isPinned: thread.isPinned,
      isRunning: store.isAIChatThreadRunning(thread.id),
      unreadMessageCount: thread.unreadMessageCount,
      preview: preview.map { String($0.prefix(180)) }
    )
  }

  private func threadDetail(_ thread: OpenClawChatThread, store: WorkspaceStore) -> MobileRemoteThreadDetail {
    MobileRemoteThreadDetail(
      thread: threadSummary(thread, store: store),
      messages: thread.messages.map {
        MobileRemoteChatMessage(
          id: $0.id,
          role: $0.role.rawValue,
          content: $0.content,
          attachmentNames: $0.attachments.compactMap(\.fileName),
          createdAt: $0.createdAt,
          deliveryStatus: $0.deliveryStatus.rawValue,
          sendFailure: $0.sendFailure
        )
      },
      streamingReply: store.aiChatStreamingReply(for: thread.id),
      reasoning: store.aiChatReasoning(for: thread.id),
      activities: store.aiChatRunActivities(for: thread.id).map {
        MobileRemoteActivity(
          id: $0.id,
          title: $0.title,
          detail: $0.detail,
          status: $0.status.rawValue,
          updatedAt: $0.updatedAt
        )
      },
      connectionState: store.aiChatConnectionState(for: thread.id).rawValue,
      connectionDetail: store.aiChatConnectionDetail(for: thread.id)
    )
  }

  private static var serverName: String {
    Host.current().localizedName ?? "Org2 on Mac"
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

private final class MobileRemoteCredentialVault {
  private struct Record: Codable {
    let device: MobileRemotePairedDevice
    let token: String
  }

  private let service = (Bundle.main.bundleIdentifier ?? "org.org2.workspace") + ".mobile-remote"
  private let account = "paired-devices"
  private var records: [Record]

  init() {
    records = []
    records = load()
  }

  var devices: [MobileRemotePairedDevice] {
    records.map(\.device).sorted { $0.pairedAt > $1.pairedAt }
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
    records.append(Record(device: device, token: token))
    do {
      try save()
    } catch {
      records.removeAll { $0.device.id == device.id }
      throw error
    }
    return (device, token)
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

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      "Keychain error \(status)"
    }
  }
}
