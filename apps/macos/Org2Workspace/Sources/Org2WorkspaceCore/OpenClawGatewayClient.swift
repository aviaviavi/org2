import CryptoKit
import Foundation
import Security

public enum OpenClawGatewayConnectionState: String, Sendable {
  case disconnected
  case connecting
  case connected
  case reconnecting
  case fallbackHTTP

  public var label: String {
    switch self {
    case .disconnected: return "Disconnected"
    case .connecting: return "Connecting"
    case .connected: return "Live"
    case .reconnecting: return "Reconnecting"
    case .fallbackHTTP: return "HTTP compatibility"
    }
  }
}

public struct OpenClawRunActivity: Identifiable, Hashable, Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case lifecycle
    case tool
    case reasoning
  }

  public enum Status: String, Codable, Sendable {
    case running
    case succeeded
    case failed
  }

  public let id: String
  public let runID: String
  public let kind: Kind
  public let title: String
  public let detail: String?
  public let status: Status
  public let updatedAt: Date

  public init(
    id: String,
    runID: String,
    kind: Kind,
    title: String,
    detail: String? = nil,
    status: Status,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.runID = runID
    self.kind = kind
    self.title = title
    self.detail = detail
    self.status = status
    self.updatedAt = updatedAt
  }
}

struct OpenClawActivityFeedItem: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let detail: String?
  let status: OpenClawRunActivity.Status
  let count: Int
}

enum OpenClawActivityFeed {
  static func items(from activities: [OpenClawRunActivity]) -> [OpenClawActivityFeedItem] {
    var grouped: [(key: String, activities: [OpenClawRunActivity])] = []

    for activity in activities {
      if activity.kind == .lifecycle {
        guard activity.status == .failed || meaningfulDetail(activity.detail, status: activity.status) != nil else {
          continue
        }
        let key = "lifecycle:\(activity.id)"
        grouped.append((key, [activity]))
        continue
      }

      let key = "\(activity.kind.rawValue):\(normalizedToolName(activity.title))"
      if grouped.last?.key == key {
        grouped[grouped.count - 1].activities.append(activity)
      } else {
        grouped.append((key, [activity]))
      }
    }

    return grouped.enumerated().compactMap { index, entry in
      let group = entry.activities
      guard let first = group.first else { return nil }
      let failures = group.filter { $0.status == .failed }.count
      let running = group.filter { $0.status == .running }.count
      let succeeded = group.count - failures - running
      let status: OpenClawRunActivity.Status = failures > 0 ? .failed : (running > 0 ? .running : .succeeded)
      let detail: String?
      if group.count == 1 {
        detail = meaningfulDetail(first.detail, status: first.status)
      } else {
        var parts: [String] = []
        if succeeded > 0 { parts.append("\(succeeded) completed") }
        if running > 0 { parts.append("\(running) running") }
        if failures > 0 { parts.append("\(failures) failed") }
        detail = parts.joined(separator: " · ")
      }
      return OpenClawActivityFeedItem(
        id: "\(entry.key):\(index)",
        title: displayTitle(for: first.title, count: group.count),
        detail: detail,
        status: status,
        count: group.count
      )
    }
  }

  static func merging(_ previous: OpenClawRunActivity, with update: OpenClawRunActivity) -> OpenClawRunActivity {
    let updateDetail = meaningfulDetail(update.detail, status: update.status)
    let previousDetail = meaningfulDetail(previous.detail, status: previous.status)
    return OpenClawRunActivity(
      id: update.id,
      runID: update.runID,
      kind: update.kind,
      title: update.title,
      detail: updateDetail ?? previousDetail,
      status: update.status,
      updatedAt: update.updatedAt
    )
  }

  static func meaningfulDetail(
    _ detail: String?,
    status: OpenClawRunActivity.Status
  ) -> String? {
    guard let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else {
      return nil
    }
    guard let data = detail.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any]
    else {
      return detail
    }

    let lowSignalKeys = Set(["durationMs", "exitCode", "status"])
    if Set(dictionary.keys).isSubset(of: lowSignalKeys) {
      if status == .failed, let exitCode = dictionary["exitCode"] as? Int {
        return "Exited with code \(exitCode)"
      }
      return nil
    }
    for key in ["cmd", "command", "path", "file", "query", "url"] {
      if let value = dictionary[key] as? String,
         !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    // Tool result envelopes can contain an entire fetched document or another
    // encoded response. They are useful in logs, but not as transcript chrome.
    if detail.count > 280 {
      return status == .failed ? "Tool call failed" : nil
    }
    return detail
  }

  private static func normalizedToolName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func displayTitle(for raw: String, count: Int) -> String {
    let singular: String
    let plural: String
    switch normalizedToolName(raw) {
    case "bash", "shell", "exec", "exec_command", "run_command":
      singular = "Shell command"
      plural = "Shell commands"
    case "read", "read_file":
      singular = "File read"
      plural = "Files read"
    case "write", "write_file":
      singular = "File written"
      plural = "Files written"
    case "edit", "apply_patch":
      singular = "File edit"
      plural = "File edits"
    case "search", "grep", "rg":
      singular = "Search"
      plural = "Searches"
    default:
      singular = humanized(raw)
      plural = "\(singular) calls"
    }
    return count == 1 ? singular : "\(count) \(plural.lowercased())"
  }

  private static func humanized(_ raw: String) -> String {
    let spaced = raw
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = spaced.first else { return "Tool" }
    return String(first).uppercased() + spaced.dropFirst()
  }
}

public enum OpenClawGatewayRunEvent: Sendable {
  case connection(OpenClawGatewayConnectionState, String?)
  case accepted(runID: String)
  case text(String, replace: Bool)
  case reasoning(String, replace: Bool)
  case activity(OpenClawRunActivity)
}

public struct OpenClawPreparedWorkflowRun: Sendable {
  public let runID: String
  public let prompt: String

  public init(runID: String, prompt: String) {
    self.runID = runID
    self.prompt = prompt
  }
}

public struct OpenClawWorkflowContinuation: Sendable {
  public let runID: String
  public let sessionKey: String
  public let prompt: String

  public init(runID: String, sessionKey: String, prompt: String) {
    self.runID = runID
    self.sessionKey = sessionKey
    self.prompt = prompt
  }
}

public struct OpenClawExecApprovalDetails: Equatable, Sendable {
  public let id: String
  public let commandText: String
  public let commandPreview: String?
  public let allowedDecisions: [String]
  public let host: String?
  public let nodeID: String?
  public let agentID: String?
  public let expiresAtMilliseconds: Double?

  public init(
    id: String,
    commandText: String,
    commandPreview: String? = nil,
    allowedDecisions: [String] = [],
    host: String? = nil,
    nodeID: String? = nil,
    agentID: String? = nil,
    expiresAtMilliseconds: Double? = nil
  ) {
    self.id = id
    self.commandText = commandText
    self.commandPreview = commandPreview
    self.allowedDecisions = allowedDecisions
    self.host = host
    self.nodeID = nodeID
    self.agentID = agentID
    self.expiresAtMilliseconds = expiresAtMilliseconds
  }

  public var reviewText: String {
    let preview = commandPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return preview.isEmpty ? commandText : preview
  }
}

public enum OpenClawGatewayError: LocalizedError, Sendable {
  case invalidEndpoint
  case connection(String)
  case protocolFailure(String)
  case gateway(code: String?, message: String)
  case emptyResponse
  case aborted(String?)

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return "The configured OpenClaw endpoint cannot be converted to a Gateway WebSocket URL."
    case .connection(let message):
      return "Could not connect to the OpenClaw Gateway: \(message)"
    case .protocolFailure(let message):
      return "The OpenClaw Gateway protocol failed: \(message)"
    case .gateway(_, let message):
      return message
    case .emptyResponse:
      return "OpenClaw finished without a response."
    case .aborted(let message):
      return message?.isEmpty == false ? "OpenClaw run stopped: \(message!)" : "OpenClaw run stopped."
    }
  }

  public var permitsHTTPFallback: Bool {
    switch self {
    case .invalidEndpoint, .connection, .protocolFailure:
      return true
    case .gateway(let code, let message):
      return code == "NOT_PAIRED"
        || (code == "INVALID_REQUEST" && message.localizedCaseInsensitiveContains("missing scope"))
    case .emptyResponse, .aborted:
      return false
    }
  }
}

enum OpenClawGatewayIdentityStorage {
  static let service = "Org2Workspace.OpenClawGateway"
  static let legacyAccount = "gatewayDevicePrivateKey"

  static func account(bundleIdentifier: String?) -> String {
    let bundleIdentifier = bundleIdentifier?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedBundleIdentifier = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
      ?? "org.org2.workspace"
    return "gatewayDevicePrivateKey.\(resolvedBundleIdentifier)"
  }
}

private struct OpenClawDeviceIdentity: Sendable {
  private static var account: String {
    OpenClawGatewayIdentityStorage.account(bundleIdentifier: Bundle.main.bundleIdentifier)
  }

  let privateKey: Curve25519.Signing.PrivateKey

  var publicKeyBase64URL: String {
    Self.base64URL(privateKey.publicKey.rawRepresentation)
  }

  var deviceID: String {
    SHA256.hash(data: privateKey.publicKey.rawRepresentation)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  static func loadOrCreate() throws -> OpenClawDeviceIdentity {
    if let data = try readPrivateKey(account: account),
       let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
      return OpenClawDeviceIdentity(privateKey: key)
    }
    // Keep the already-approved identity when upgrading from the original
    // shared account, then isolate future writes by bundle identifier so the
    // daily and Codex builds cannot rotate each other's device key.
    if let data = try readPrivateKey(account: OpenClawGatewayIdentityStorage.legacyAccount),
       let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
      try savePrivateKey(data, account: account)
      return OpenClawDeviceIdentity(privateKey: key)
    }
    let identity = OpenClawDeviceIdentity(privateKey: Curve25519.Signing.PrivateKey())
    try savePrivateKey(identity.privateKey.rawRepresentation, account: account)
    return identity
  }

  func signature(for payload: String) throws -> String {
    Self.base64URL(try privateKey.signature(for: Data(payload.utf8)))
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func readPrivateKey(account: String) throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: OpenClawGatewayIdentityStorage.service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw OpenClawKeychainError.status(status) }
    return result as? Data
  }

  private static func savePrivateKey(_ data: Data, account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: OpenClawGatewayIdentityStorage.service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: data
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let match: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: OpenClawGatewayIdentityStorage.service,
        kSecAttrAccount as String: account
      ]
      let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard update == errSecSuccess else { throw OpenClawKeychainError.status(update) }
      return
    }
    guard status == errSecSuccess else { throw OpenClawKeychainError.status(status) }
  }
}

private final class OpenClawWebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
  struct CloseInfo: Sendable {
    let code: URLSessionWebSocketTask.CloseCode
    let reason: Data?
  }

  private let lock = NSLock()
  private var closeInfoByTaskID: [Int: CloseInfo] = [:]

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {}

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    lock.withLock {
      closeInfoByTaskID[webSocketTask.taskIdentifier] = CloseInfo(code: closeCode, reason: reason)
    }
  }

  func closeInfo(for task: URLSessionWebSocketTask) -> CloseInfo? {
    lock.withLock { closeInfoByTaskID[task.taskIdentifier] }
  }
}

/// A small native client for OpenClaw Gateway protocol v4. A client represents one
/// in-flight Org2 turn, while the Gateway remains the authority for run state.
public actor OpenClawGatewayClient {
  public typealias EventHandler = @Sendable (OpenClawGatewayRunEvent) async -> Void

  private let settings: OpenClawGatewaySettings
  private let sessionDelegate: OpenClawWebSocketSessionDelegate
  private let session: URLSession
  private var socket: URLSessionWebSocketTask?
  private var sessionKey: String?
  private var agentID: String?
  private var runID: String?
  private var deviceID: String?
  private var awaitingHello = false
  private var stopRequested = false

  public init(settings: OpenClawGatewaySettings) {
    self.settings = settings
    let sessionDelegate = OpenClawWebSocketSessionDelegate()
    self.sessionDelegate = sessionDelegate
    self.session = URLSession(
      configuration: OpenClawChatClient.sessionConfiguration(),
      delegate: sessionDelegate,
      delegateQueue: nil
    )
  }

  public func prepare() async throws {
    let socket = try makeSocket()
    self.socket = socket
    socket.resume()
    do {
      let nonce = try await awaitChallenge(on: socket)
      try await connect(on: socket, nonce: nonce)
      socket.cancel(with: .normalClosure, reason: nil)
    } catch let error as OpenClawGatewayError {
      socket.cancel(with: .goingAway, reason: nil)
      throw error
    } catch {
      socket.cancel(with: .goingAway, reason: nil)
      throw OpenClawGatewayError.connection(error.localizedDescription)
    }
  }

  public func listCommands(agentID: String) async throws -> [OpenClawSlashCommand] {
    let socket = try makeSocket()
    self.socket = socket
    socket.resume()
    do {
      let nonce = try await awaitChallenge(on: socket)
      try await connect(on: socket, nonce: nonce)
      let requestID = UUID().uuidString.lowercased()
      try await sendRequest(
        id: requestID,
        method: "commands.list",
        params: [
          "agentId": agentID,
          "scope": "text",
          "includeArgs": true
        ],
        on: socket
      )
      while true {
        let frame = try await receiveObject(on: socket)
        guard Self.string(frame["type"]) == "res", Self.string(frame["id"]) == requestID else {
          continue
        }
        guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
        let payload = Self.dictionary(frame["payload"]) ?? [:]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let commands = try OpenClawGatewayCommandCatalog.decode(data)
        socket.cancel(with: .normalClosure, reason: nil)
        return commands
      }
    } catch let error as OpenClawGatewayError {
      socket.cancel(with: .goingAway, reason: nil)
      throw error
    } catch {
      socket.cancel(with: .goingAway, reason: nil)
      throw OpenClawGatewayError.connection(error.localizedDescription)
    }
  }

  public func prepareWorkflowRun(
    workflowID: String,
    inputs: [String: String],
    corpusID: String?
  ) async throws -> OpenClawPreparedWorkflowRun {
    var params: [String: Any] = ["workflowId": workflowID, "inputs": inputs]
    if let corpusID, !corpusID.isEmpty { params["corpusId"] = corpusID }
    let payload = try await requestPayload(
      method: "org2.workflow.prepareRun",
      params: params
    )
    guard let run = Self.dictionary(payload["run"]),
          let runID = Self.string(run["id"]), !runID.isEmpty,
          let prompt = Self.string(payload["prompt"]), !prompt.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("org2.workflow.prepareRun returned an invalid payload")
    }
    return OpenClawPreparedWorkflowRun(runID: runID, prompt: prompt)
  }

  public func resumeWorkflowRun(runID: String, corpusID: String?) async throws -> OpenClawWorkflowContinuation {
    var params: [String: Any] = ["runId": runID]
    if let corpusID, !corpusID.isEmpty { params["corpusId"] = corpusID }
    let payload = try await requestPayload(method: "org2.workflow.resume", params: params)
    guard let run = Self.dictionary(payload["run"]),
          let returnedRunID = Self.string(run["id"]), !returnedRunID.isEmpty,
          let sessionKey = Self.string(payload["sessionKey"]), !sessionKey.isEmpty,
          let prompt = Self.string(payload["prompt"]), !prompt.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("org2.workflow.resume returned an invalid payload")
    }
    return OpenClawWorkflowContinuation(runID: returnedRunID, sessionKey: sessionKey, prompt: prompt)
  }

  public func syncWorkflows(corpusID: String?) async throws {
    var params: [String: Any] = [:]
    if let corpusID, !corpusID.isEmpty { params["corpusId"] = corpusID }
    _ = try await requestPayload(method: "org2.workflow.sync", params: params)
  }

  public func execApprovalDetails(id: String) async throws -> OpenClawExecApprovalDetails {
    let payload = try await requestPayload(
      method: "exec.approval.get",
      params: ["id": id],
      scopes: ["operator.read", "operator.approvals"]
    )
    return try Self.execApprovalDetails(from: payload)
  }

  static func execApprovalDetails(from payload: [String: Any]) throws -> OpenClawExecApprovalDetails {
    guard let id = string(payload["id"]), !id.isEmpty,
          let commandText = string(payload["commandText"]), !commandText.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("exec.approval.get returned an invalid payload")
    }
    return OpenClawExecApprovalDetails(
      id: id,
      commandText: commandText,
      commandPreview: string(payload["commandPreview"]),
      allowedDecisions: payload["allowedDecisions"] as? [String] ?? [],
      host: string(payload["host"]),
      nodeID: string(payload["nodeId"]),
      agentID: string(payload["agentId"]),
      expiresAtMilliseconds: (payload["expiresAtMs"] as? NSNumber)?.doubleValue
    )
  }

  deinit {
    socket?.cancel(with: .goingAway, reason: nil)
  }

  public func send(
    message: String,
    attachments: [OpenClawChatAttachment],
    agentID: String,
    sessionKey: String,
    onEvent: @escaping EventHandler
  ) async throws -> String {
    stopRequested = false
    runID = nil
    self.sessionKey = sessionKey
    self.agentID = agentID
    await onEvent(.connection(.connecting, nil))

    let socket = try makeSocket()
    self.socket = socket
    socket.resume()

    do {
      let nonce = try await awaitChallenge(on: socket)
      try await connect(on: socket, nonce: nonce)
      await onEvent(.connection(.connected, nil))

      let proposedRunID = UUID().uuidString.lowercased()
      let sendID = UUID().uuidString.lowercased()
      var params: [String: Any] = [
        "sessionKey": sessionKey,
        "agentId": agentID,
        "message": message,
        "deliver": false,
        "thinking": "medium",
        "timeoutMs": Int(OpenClawChatClient.requestTimeout * 1_000),
        "idempotencyKey": proposedRunID
      ]
      if !attachments.isEmpty {
        params["attachments"] = attachments.map {
          [
            "type": "image",
            "fileName": $0.fileName,
            "mimeType": $0.mimeType,
            "content": $0.data.base64EncodedString()
          ]
        }
      }
      try await sendRequest(id: sendID, method: "chat.send", params: params, on: socket)
      // Once bytes for chat.send have left the process, retrying through HTTP could
      // duplicate side effects. Reconcile this idempotency key instead.
      runID = proposedRunID

      var assembledText = ""
      var accepted = false
      while true {
        let frame = try await receiveObject(on: socket)
        if Self.string(frame["type"]) == "res", Self.string(frame["id"]) == sendID {
          guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
          let payload = Self.dictionary(frame["payload"])
          let acceptedRunID = Self.string(payload?["runId"]) ?? proposedRunID
          runID = acceptedRunID
          accepted = true
          await onEvent(.accepted(runID: acceptedRunID))
          continue
        }
        guard Self.string(frame["type"]) == "event" else { continue }
        let eventName = Self.string(frame["event"]) ?? ""
        let payload = Self.dictionary(frame["payload"]) ?? [:]

        if eventName == "chat" {
          let eventRunID = Self.string(payload["runId"]) ?? ""
          guard eventRunID == (runID ?? proposedRunID) else { continue }
          let state = Self.string(payload["state"]) ?? ""
          if state == "delta" {
            let delta = Self.string(payload["deltaText"]) ?? ""
            let replace = Self.bool(payload["replace"]) ?? false
            if replace { assembledText = delta } else { assembledText += delta }
            if !delta.isEmpty { await onEvent(.text(delta, replace: replace)) }
          } else if state == "final" {
            let final = Self.messageText(payload["message"], includeThinking: false)
            if !final.isEmpty {
              assembledText = final
              await onEvent(.text(final, replace: true))
            }
            socket.cancel(with: .normalClosure, reason: nil)
            let output = assembledText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw OpenClawGatewayError.emptyResponse }
            return output
          } else if state == "aborted" {
            throw OpenClawGatewayError.aborted(Self.string(payload["errorMessage"]))
          } else if state == "error" {
            throw OpenClawGatewayError.gateway(
              code: Self.string(payload["errorKind"]),
              message: Self.string(payload["errorMessage"]) ?? "OpenClaw run failed."
            )
          }
          continue
        }

        if eventName == "agent" {
          let eventRunID = Self.string(payload["runId"]) ?? ""
          guard eventRunID == (runID ?? proposedRunID) else { continue }
          if !accepted {
            runID = eventRunID
            accepted = true
            await onEvent(.accepted(runID: eventRunID))
          }
          if let event = Self.activity(from: payload) {
            await onEvent(.activity(event))
          }
          if let reasoning = Self.reasoning(from: payload), !reasoning.text.isEmpty {
            await onEvent(.reasoning(reasoning.text, replace: reasoning.replace))
          }
        }
      }
    } catch let error as OpenClawGatewayError {
      socket.cancel(with: .goingAway, reason: nil)
      if stopRequested {
        throw OpenClawGatewayError.aborted(nil)
      }
      if let runID, error.permitsHTTPFallback {
        return try await recoverAcceptedRun(
          runID: runID,
          sessionKey: sessionKey,
          agentID: agentID,
          onEvent: onEvent
        )
      }
      throw error
    } catch {
      socket.cancel(with: .goingAway, reason: nil)
      if stopRequested {
        throw OpenClawGatewayError.aborted(nil)
      }
      if let runID {
        return try await recoverAcceptedRun(
          runID: runID,
          sessionKey: sessionKey,
          agentID: agentID,
          onEvent: onEvent
        )
      }
      throw OpenClawGatewayError.connection(error.localizedDescription)
    }
  }

  public func abort() async throws {
    guard let socket, let sessionKey else { return }
    stopRequested = true
    defer { socket.cancel(with: .goingAway, reason: nil) }
    try await sendRequest(
      id: UUID().uuidString.lowercased(),
      method: "chat.abort",
      params: Self.abortRequestParams(sessionKey: sessionKey, agentID: agentID),
      on: socket
    )
    // The live receive loop owns response consumption for this socket. Give the
    // Gateway a brief chance to emit its aborted event, then close locally so a
    // reconnected or orphaned run can never leave the UI stuck in Sending.
    try? await Task.sleep(for: .milliseconds(250))
  }

  nonisolated static func abortRequestParams(
    sessionKey: String,
    agentID: String?
  ) -> [String: Any] {
    var params: [String: Any] = ["sessionKey": sessionKey, "preserveSideRuns": true]
    if let agentID { params["agentId"] = agentID }
    return params
  }

  private func requestPayload(
    method: String,
    params: [String: Any],
    scopes: [String] = ["operator.read", "operator.write"]
  ) async throws -> [String: Any] {
    let socket = try makeSocket()
    self.socket = socket
    socket.resume()
    do {
      let nonce = try await awaitChallenge(on: socket)
      try await connect(on: socket, nonce: nonce, scopes: scopes)
      let requestID = UUID().uuidString.lowercased()
      try await sendRequest(id: requestID, method: method, params: params, on: socket)
      while true {
        let frame = try await receiveObject(on: socket)
        guard Self.string(frame["type"]) == "res", Self.string(frame["id"]) == requestID else { continue }
        guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
        let payload = Self.dictionary(frame["payload"]) ?? [:]
        socket.cancel(with: .normalClosure, reason: nil)
        return payload
      }
    } catch let error as OpenClawGatewayError {
      socket.cancel(with: .goingAway, reason: nil)
      throw error
    } catch {
      socket.cancel(with: .goingAway, reason: nil)
      throw OpenClawGatewayError.connection(error.localizedDescription)
    }
  }

  private func makeSocket() throws -> URLSessionWebSocketTask {
    guard var components = URLComponents(url: settings.endpoint, resolvingAgainstBaseURL: false) else {
      throw OpenClawGatewayError.invalidEndpoint
    }
    switch components.scheme?.lowercased() {
    case "https": components.scheme = "wss"
    case "http": components.scheme = "ws"
    case "wss", "ws": break
    default: throw OpenClawGatewayError.invalidEndpoint
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw OpenClawGatewayError.invalidEndpoint }
    return session.webSocketTask(with: url)
  }

  private func awaitChallenge(on socket: URLSessionWebSocketTask) async throws -> String {
    let frame = try await receiveObject(on: socket)
    guard Self.string(frame["type"]) == "event",
          Self.string(frame["event"]) == "connect.challenge",
          let nonce = Self.string(Self.dictionary(frame["payload"])?["nonce"]),
          !nonce.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("expected connect.challenge")
    }
    return nonce
  }

  private func connect(
    on socket: URLSessionWebSocketTask,
    nonce: String,
    scopes: [String] = ["operator.read", "operator.write"]
  ) async throws {
    let requestID = UUID().uuidString.lowercased()
    let identity = try OpenClawDeviceIdentity.loadOrCreate()
    deviceID = identity.deviceID
    let signedAt = Int(Date().timeIntervalSince1970 * 1_000)
    let signatureToken = settings.bearerToken ?? ""
    let signaturePayload = [
      "v3",
      identity.deviceID,
      "openclaw-macos",
      "ui",
      "operator",
      scopes.joined(separator: ","),
      String(signedAt),
      signatureToken,
      nonce,
      "darwin",
      "mac"
    ].joined(separator: "|")
    var params: [String: Any] = [
      "minProtocol": 4,
      "maxProtocol": 4,
      "client": [
        "id": "openclaw-macos",
        "displayName": "Org2 Workspace",
        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        "platform": "darwin",
        "deviceFamily": "Mac",
        "mode": "ui"
      ],
      "caps": ["tool-events"],
      "role": "operator",
      "scopes": scopes,
      "locale": Locale.current.identifier,
      "device": [
        "id": identity.deviceID,
        "publicKey": identity.publicKeyBase64URL,
        "signature": try identity.signature(for: signaturePayload),
        "signedAt": signedAt,
        "nonce": nonce
      ]
    ]
    if let token = settings.bearerToken { params["auth"] = ["token": token] }
    awaitingHello = true
    defer { awaitingHello = false }
    try await sendRequest(id: requestID, method: "connect", params: params, on: socket)
    while true {
      let frame = try await receiveObject(on: socket)
      guard Self.string(frame["type"]) == "res", Self.string(frame["id"]) == requestID else { continue }
      guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
      let payload = Self.dictionary(frame["payload"])
      guard Self.string(payload?["type"]) == "hello-ok" else {
        throw OpenClawGatewayError.protocolFailure("connect did not return hello-ok")
      }
      return
    }
  }

  private func recoverAcceptedRun(
    runID: String,
    sessionKey: String,
    agentID: String,
    onEvent: @escaping EventHandler
  ) async throws -> String {
    await onEvent(.connection(.reconnecting, "The run was already accepted; reconnecting without resending it."))
    var lastError: Error?
    for attempt in 1...5 {
      do {
        if attempt > 1 {
          try await Task.sleep(for: .seconds(min(attempt * 2, 8)))
        }
        let nextSocket = try makeSocket()
        socket = nextSocket
        nextSocket.resume()
        let nonce = try await awaitChallenge(on: nextSocket)
        try await connect(on: nextSocket, nonce: nonce)
        await onEvent(.connection(.connected, "Reconnected to accepted run \(String(runID.prefix(8)))."))
        return try await waitAndReconcile(
          runID: runID,
          sessionKey: sessionKey,
          agentID: agentID,
          onEvent: onEvent,
          on: nextSocket
        )
      } catch {
        lastError = error
        socket?.cancel(with: .goingAway, reason: nil)
        await onEvent(.connection(.reconnecting, "Reconnect attempt \(attempt) failed."))
      }
    }
    await onEvent(.connection(.disconnected, "The accepted run may still be working on the Gateway."))
    throw OpenClawGatewayError.connection(
      "lost contact after the run was accepted; OpenClaw may still be working (\(lastError?.localizedDescription ?? "reconnect failed"))"
    )
  }

  private func waitAndReconcile(
    runID: String,
    sessionKey: String,
    agentID: String,
    onEvent: @escaping EventHandler,
    on socket: URLSessionWebSocketTask
  ) async throws -> String {
    let deadline = Date().addingTimeInterval(OpenClawChatClient.requestTimeout)
    while Date() < deadline {
      let waitID = UUID().uuidString.lowercased()
      try await sendRequest(
        id: waitID,
        method: "agent.wait",
        params: ["runId": runID, "timeoutMs": 30_000],
        on: socket
      )
      while true {
        let frame = try await receiveObject(on: socket)
        if Self.string(frame["type"]) == "event",
           Self.string(frame["event"]) == "agent",
           let activity = Self.activity(from: Self.dictionary(frame["payload"]) ?? [:]),
           activity.runID == runID {
          await onEvent(.activity(activity))
          continue
        }
        guard Self.string(frame["type"]) == "res", Self.string(frame["id"]) == waitID else { continue }
        guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
        let payload = Self.dictionary(frame["payload"]) ?? [:]
        let status = Self.string(payload["status"]) ?? "timeout"
        if status == "timeout" { break }
        if status == "error" {
          throw OpenClawGatewayError.gateway(
            code: nil,
            message: Self.string(payload["error"]) ?? "OpenClaw run failed after reconnecting."
          )
        }
        return try await loadLatestAssistantMessage(
          sessionKey: sessionKey,
          agentID: agentID,
          on: socket
        )
      }
    }
    throw OpenClawGatewayError.gateway(code: "timeout", message: "OpenClaw run timed out.")
  }

  private func loadLatestAssistantMessage(
    sessionKey: String,
    agentID: String,
    on socket: URLSessionWebSocketTask
  ) async throws -> String {
    let historyID = UUID().uuidString.lowercased()
    try await sendRequest(
      id: historyID,
      method: "chat.history",
      params: ["sessionKey": sessionKey, "agentId": agentID, "limit": 12, "maxChars": 100_000],
      on: socket
    )
    while true {
      let frame = try await receiveObject(on: socket)
      guard Self.string(frame["type"]) == "res", Self.string(frame["id"]) == historyID else { continue }
      guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
      let payload = Self.dictionary(frame["payload"]) ?? [:]
      let messages = payload["messages"] as? [Any] ?? []
      for message in messages.reversed() {
        guard let object = Self.dictionary(message), Self.string(object["role"]) == "assistant" else { continue }
        let text = Self.messageText(object, includeThinking: false)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
      }
      throw OpenClawGatewayError.emptyResponse
    }
  }

  private func sendRequest(
    id: String,
    method: String,
    params: [String: Any],
    on socket: URLSessionWebSocketTask
  ) async throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "type": "req",
      "id": id,
      "method": method,
      "params": params
    ])
    guard let text = String(data: data, encoding: .utf8) else {
      throw OpenClawGatewayError.protocolFailure("could not encode request")
    }
    try await socket.send(.string(text))
  }

  private func receiveObject(on socket: URLSessionWebSocketTask) async throws -> [String: Any] {
    let message: URLSessionWebSocketTask.Message
    do {
      message = try await socket.receive()
    } catch {
      // OpenClaw replies with a structured pairing error and immediately closes
      // the socket. URLSession can report the close before delivering that last
      // response frame, but it preserves the useful reason on the task.
      var delegateCloseInfo: OpenClawWebSocketSessionDelegate.CloseInfo?
      for _ in 0..<5 where delegateCloseInfo == nil {
        delegateCloseInfo = sessionDelegate.closeInfo(for: socket)
        if delegateCloseInfo == nil { try? await Task.sleep(for: .milliseconds(50)) }
      }
      if let reasonData = socket.closeReason ?? delegateCloseInfo?.reason,
         let reason = String(data: reasonData, encoding: .utf8),
         !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw Self.gatewayError(fromCloseReason: reason, deviceID: deviceID)
      }
      if awaitingHello, let deviceID {
        throw Self.gatewayHandshakeClosedError(deviceID: deviceID)
      }
      throw OpenClawGatewayError.connection(error.localizedDescription)
    }
    let data: Data
    switch message {
    case .string(let text): data = Data(text.utf8)
    case .data(let value): data = value
    @unknown default: throw OpenClawGatewayError.protocolFailure("unsupported WebSocket frame")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OpenClawGatewayError.protocolFailure("invalid JSON frame")
    }
    return object
  }

  private static func gatewayError(from frame: [String: Any]) -> OpenClawGatewayError {
    let error = dictionary(frame["error"])
    let code = string(error?["code"])
    let details = dictionary(error?["details"])
    let requestID = string(details?["requestId"])
    var message = string(error?["message"]) ?? "The OpenClaw Gateway rejected the request."
    if code == "NOT_PAIRED", let requestID {
      message += " Approve Org2 Workspace device request \(requestID) on the Gateway, then send again."
    }
    return .gateway(
      code: code,
      message: message
    )
  }

  static func gatewayError(fromCloseReason reason: String, deviceID: String? = nil) -> OpenClawGatewayError {
    let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.localizedCaseInsensitiveContains("pairing required")
      || normalized.localizedCaseInsensitiveContains("upgrade pending approval") {
      let requestID = firstMatch(in: normalized, pattern: #"\(requestId:\s*([^\s\)]+)\)"#)
      var message = normalized
      if let requestID {
        message += " Approve Org2 Workspace request \(requestID) on the Gateway"
      } else {
        message += " Approve the pending Org2 Workspace device request on the Gateway"
      }
      if let deviceID, !deviceID.isEmpty {
        message += " (device \(deviceID.prefix(12)))"
      }
      message += ", then click Save & Request Pairing again."
      return .gateway(code: "NOT_PAIRED", message: message)
    }
    return .connection(normalized)
  }

  static func gatewayHandshakeClosedError(deviceID: String) -> OpenClawGatewayError {
    .gateway(
      code: "NOT_PAIRED",
      message: "OpenClaw closed the signed device handshake before macOS delivered its final reason. "
        + "Approve the pending Org2 Workspace request for device \(deviceID.prefix(12)) on the Gateway, "
        + "then click Save & Request Pairing again."
    )
  }

  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
          ),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }

  private static func activity(from payload: [String: Any]) -> OpenClawRunActivity? {
    let runID = string(payload["runId"]) ?? ""
    let stream = string(payload["stream"]) ?? ""
    let data = dictionary(payload["data"]) ?? [:]
    if stream == "tool" {
      let callID = string(data["toolCallId"]) ?? UUID().uuidString
      let name = string(data["name"]) ?? "Tool"
      let phase = string(data["phase"]) ?? "start"
      let status: OpenClawRunActivity.Status = phase == "result"
        ? ((bool(data["isError"]) ?? false) ? .failed : .succeeded)
        : .running
      let detailValue = phase == "start" ? data["args"] : (data["partialResult"] ?? data["result"])
      return OpenClawRunActivity(
        id: "tool:\(callID)", runID: runID, kind: .tool, title: name,
        detail: compactDescription(detailValue), status: status
      )
    }
    if stream == "lifecycle" {
      let phase = string(data["phase"]) ?? "running"
      let status: OpenClawRunActivity.Status = phase == "error" ? .failed : (phase == "end" ? .succeeded : .running)
      let title = phase == "finishing" ? "Finishing context" : (phase == "start" ? "Agent started" : "Agent \(phase)")
      return OpenClawRunActivity(
        id: "lifecycle:\(runID)", runID: runID, kind: .lifecycle, title: title,
        detail: string(data["error"]) ?? string(data["errorMessage"]), status: status
      )
    }
    return nil
  }

  private static func reasoning(from payload: [String: Any]) -> (text: String, replace: Bool)? {
    let stream = string(payload["stream"]) ?? ""
    guard stream == "thinking" || stream == "reasoning" else { return nil }
    let data = dictionary(payload["data"]) ?? [:]
    let text = string(data["delta"]) ?? string(data["text"]) ?? ""
    return (text, bool(data["replace"]) ?? false)
  }

  static func messageText(_ value: Any?, includeThinking: Bool) -> String {
    guard let value else { return "" }
    if let text = value as? String { return text }
    guard let message = dictionary(value) else { return "" }
    if let content = message["content"] as? String { return content }
    guard let blocks = message["content"] as? [Any] else {
      return string(message["text"]) ?? ""
    }
    return blocks.compactMap { block -> String? in
      guard let block = dictionary(block) else { return nil }
      let type = string(block["type"]) ?? "text"
      guard type == "text" || (includeThinking && (type == "thinking" || type == "reasoning")) else { return nil }
      return string(block["text"]) ?? string(block["thinking"])
    }.joined(separator: "\n")
  }

  private static func compactDescription(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let string = value as? String { return String(string.prefix(2_000)) }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return String(describing: value) }
    return String(text.prefix(2_000))
  }

  private static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
  private static func string(_ value: Any?) -> String? { value as? String }
  private static func bool(_ value: Any?) -> Bool? { value as? Bool }
}
