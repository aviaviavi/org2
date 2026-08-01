import Foundation
import Security
import UIKit

@MainActor
final class MobileRemoteStore: ObservableObject {
  @Published private(set) var isPaired = false
  @Published private(set) var isConnected = false
  @Published private(set) var serverName = "Org2 on Mac"
  @Published private(set) var status: MobileRemoteServerStatus?
  @Published private(set) var threads: [MobileRemoteThreadSummary] = []
  @Published private(set) var threadDetail: MobileRemoteThreadDetail?
  @Published private(set) var threadConnectionError: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var isPairing = false
  @Published var endpointDraft = ""
  @Published var codeDraft = ""
  @Published var errorMessage: String?

  private static let endpointKey = "Org2Mobile.remote.endpoint.v1"
  private static let serverNameKey = "Org2Mobile.remote.serverName.v1"
  private static let deviceIDKey = "Org2Mobile.remote.deviceID.v1"
  private static let tokenService = "org.org2.mobile.remote"
  private static let tokenAccount = "mac-access-token"

  private let defaults: UserDefaults
  private var accessToken: String?
  private var pollingTask: Task<Void, Never>?
  private var pollingThreadID: UUID?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    endpointDraft = defaults.string(forKey: Self.endpointKey) ?? ""
    serverName = defaults.string(forKey: Self.serverNameKey) ?? "Org2 on Mac"
    accessToken = Self.loadToken()
    isPaired = !endpointDraft.isEmpty && accessToken != nil
  }

  deinit {
    pollingTask?.cancel()
  }

  func applyPairingPayload(_ payload: String) -> Bool {
    guard let components = URLComponents(string: payload),
          components.scheme == "org2-remote",
          components.host == "pair",
          let endpoint = components.queryItems?.first(where: { $0.name == "endpoint" })?.value,
          let code = components.queryItems?.first(where: { $0.name == "code" })?.value
    else {
      errorMessage = "That QR code is not an Org2 Mobile Remote pairing code."
      return false
    }
    endpointDraft = endpoint
    codeDraft = code
    if let name = components.queryItems?.first(where: { $0.name == "name" })?.value {
      serverName = name
    }
    return true
  }

  func pair() async {
    guard !isPairing else { return }
    isPairing = true
    defer { isPairing = false }
    do {
      let client = try MobileRemoteClient(endpoint: endpointDraft, accessToken: nil)
      let response: MobileRemotePairResponse = try await client.post(
        "/v1/pair",
        payload: MobileRemotePairRequest(
          code: codeDraft.trimmingCharacters(in: .whitespacesAndNewlines),
          deviceName: UIDevice.current.name
        ),
        as: MobileRemotePairResponse.self
      )
      guard response.protocolVersion == MobileRemoteWire.version else {
        throw MobileRemoteClientError.incompatibleProtocol
      }
      try Self.saveToken(response.accessToken)
      accessToken = response.accessToken
      serverName = response.serverName
      codeDraft = ""
      defaults.set(endpointDraft, forKey: Self.endpointKey)
      defaults.set(serverName, forKey: Self.serverNameKey)
      defaults.set(response.deviceID.uuidString, forKey: Self.deviceIDKey)
      isPaired = true
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func disconnect() {
    pollingTask?.cancel()
    pollingTask = nil
    pollingThreadID = nil
    Self.deleteToken()
    accessToken = nil
    isPaired = false
    isConnected = false
    status = nil
    threads = []
    threadDetail = nil
    threadConnectionError = nil
    defaults.removeObject(forKey: Self.endpointKey)
    defaults.removeObject(forKey: Self.serverNameKey)
    defaults.removeObject(forKey: Self.deviceIDKey)
  }

  func refresh() async {
    guard isPaired, !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let client = try pairedClient()
      async let statusRequest = client.get("/v1/status", as: MobileRemoteServerStatus.self)
      async let threadsRequest = client.get("/v1/threads", as: MobileRemoteThreadList.self)
      let (nextStatus, nextThreads) = try await (statusRequest, threadsRequest)
      guard nextStatus.protocolVersion == MobileRemoteWire.version else {
        throw MobileRemoteClientError.incompatibleProtocol
      }
      status = nextStatus
      isConnected = true
      serverName = nextStatus.serverName
      threads = nextThreads.threads
      defaults.set(serverName, forKey: Self.serverNameKey)
    } catch {
      isConnected = false
      errorMessage = error.localizedDescription
    }
  }

  func createThread(runtime: String) async -> UUID? {
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads",
        payload: MobileRemoteCreateThreadRequest(runtime: runtime),
        as: MobileRemoteMutationResponse.self
      )
      await refresh()
      return response.threadID
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func beginPolling(threadID: UUID) {
    pollingTask?.cancel()
    if pollingThreadID != threadID {
      threadDetail = nil
      threadConnectionError = nil
    }
    pollingThreadID = threadID
    pollingTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        await self.refreshThread(threadID)
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func endPolling(threadID: UUID) {
    guard pollingThreadID == threadID else { return }
    pollingTask?.cancel()
    pollingTask = nil
    pollingThreadID = nil
    if threadDetail?.thread.id == threadID {
      threadDetail = nil
    }
  }

  func send(_ rawMessage: String, threadID: UUID) async -> Bool {
    let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return false }
    do {
      let _: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/messages",
        payload: MobileRemoteSendMessageRequest(content: message),
        as: MobileRemoteMutationResponse.self
      )
      await refreshThread(threadID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func stop(threadID: UUID) async {
    do {
      let _: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/stop",
        payload: EmptyPayload(),
        as: MobileRemoteMutationResponse.self
      )
      await refreshThread(threadID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func refreshThread(_ threadID: UUID) async {
    do {
      let detail = try await pairedClient().get(
        "/v1/threads/\(threadID.uuidString)",
        as: MobileRemoteThreadDetail.self
      )
      guard pollingThreadID == threadID else { return }
      threadDetail = detail
      isConnected = true
      threadConnectionError = nil
      if let index = threads.firstIndex(where: { $0.id == threadID }) {
        threads[index] = detail.thread
      }
    } catch {
      if !Task.isCancelled, pollingThreadID == threadID {
        isConnected = false
        threadConnectionError = error.localizedDescription
      }
    }
  }

  private func pairedClient() throws -> MobileRemoteClient {
    guard let accessToken else { throw MobileRemoteClientError.server("Pair this phone with the Mac again.") }
    return try MobileRemoteClient(endpoint: endpointDraft, accessToken: accessToken)
  }

  private static func saveToken(_ token: String) throws {
    let data = Data(token.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: tokenService,
      kSecAttrAccount as String: tokenAccount
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
      guard added == errSecSuccess else { throw MobileRemoteKeychainError.status(added) }
    } else if status != errSecSuccess {
      throw MobileRemoteKeychainError.status(status)
    }
  }

  private static func loadToken() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: tokenService,
      kSecAttrAccount as String: tokenAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private static func deleteToken() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: tokenService,
      kSecAttrAccount as String: tokenAccount
    ]
    SecItemDelete(query as CFDictionary)
  }
}

private struct EmptyPayload: Encodable {}

private enum MobileRemoteKeychainError: LocalizedError {
  case status(OSStatus)

  var errorDescription: String? {
    switch self {
    case .status(let status):
      "Could not store the pairing credential in Keychain (\(status))."
    }
  }
}
