import Darwin
import Foundation

public enum JSONValue: Hashable, Codable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .integer(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  public var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }
}

public enum CodexAccountState: Equatable, Sendable {
  case unknown
  case unavailable(String)
  case signedOut
  case chatGPT(email: String?, plan: String?)
  case apiKey
  case other(String)

  public var isReady: Bool {
    switch self {
    case .chatGPT:
      true
    case .unknown, .unavailable, .signedOut, .apiKey, .other:
      false
    }
  }

  public var label: String {
    switch self {
    case .unknown:
      return "Not checked"
    case .unavailable(let detail):
      return detail
    case .signedOut:
      return "Not signed in"
    case .chatGPT(let email, let plan):
      let details = [email, plan.map { "\($0) plan" }]
        .compactMap { $0 }
        .joined(separator: " · ")
      return details.isEmpty ? "Signed in with ChatGPT" : details
    case .apiKey:
      return "API key (separate API billing)"
    case .other(let type):
      return type
    }
  }
}

public enum CodexSandboxAccess: String, CaseIterable, Identifiable, Sendable {
  case readOnly
  case workspaceWrite
  case fullAccess

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .readOnly: "Read Only"
    case .workspaceWrite: "Workspace Write"
    case .fullAccess: "Full Access"
    }
  }

  var threadSandboxValue: String {
    switch self {
    case .readOnly: "read-only"
    case .workspaceWrite: "workspace-write"
    case .fullAccess: "danger-full-access"
    }
  }

  func turnSandboxPolicy(cwd: URL) -> JSONValue {
    switch self {
    case .readOnly:
      .object(["type": .string("readOnly")])
    case .workspaceWrite:
      .object([
        "type": .string("workspaceWrite"),
        "writableRoots": .array([.string(cwd.standardizedFileURL.path)]),
        "networkAccess": .bool(false)
      ])
    case .fullAccess:
      .object(["type": .string("dangerFullAccess")])
    }
  }
}

public struct CodexLoginStart: Equatable, Sendable {
  public let loginID: String
  public let authURL: URL

  public init(loginID: String, authURL: URL) {
    self.loginID = loginID
    self.authURL = authURL
  }
}

public struct CodexDynamicToolCall: Sendable {
  public let callID: String
  public let threadID: String
  public let turnID: String
  public let tool: String
  public let arguments: JSONValue
}

public struct CodexDynamicToolResult: Sendable {
  public let success: Bool
  public let text: String

  public init(success: Bool, text: String) {
    self.success = success
    self.text = text
  }
}

public struct CodexTurnResult: Sendable {
  public enum Status: String, Sendable {
    case completed
    case interrupted
    case failed
  }

  public let threadID: String
  public let turnID: String
  public let status: Status
  public let reply: String
  public let errorMessage: String?
}

public enum CodexAppServerEvent: Sendable {
  case connectionChanged(isConnected: Bool, detail: String?)
  case accountUpdated(authMode: String?, plan: String?)
  case loginCompleted(loginID: String?, success: Bool, error: String?)
  case turnStarted(threadID: String, turnID: String)
  case agentMessageDelta(threadID: String, turnID: String, itemID: String, delta: String)
  case reasoningDelta(threadID: String, turnID: String, delta: String)
  case activity(
    threadID: String,
    turnID: String,
    itemID: String,
    title: String,
    detail: String?,
    status: OpenClawRunActivity.Status
  )
  case warning(threadID: String?, message: String)
}

enum CodexStreamingText {
  static func appending(
    _ delta: String,
    itemID: String,
    after previousItemID: String?,
    to existing: String
  ) -> String {
    guard let previousItemID,
          previousItemID != itemID,
          !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return existing + delta }
    return existing + "\n\n" + delta
  }
}

public enum CodexAppServerError: LocalizedError, Sendable {
  case executableNotFound
  case launchFailed(String)
  case disconnected(String)
  case server(code: Int?, message: String)
  case invalidResponse(String)
  case requestTimedOut(String)
  case notAuthenticated
  case turnFailed(String)
  case turnInterrupted

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      "Codex was not found. Install the Codex CLI or the ChatGPT Mac app."
    case .launchFailed(let detail):
      "Could not start Codex: \(detail)"
    case .disconnected(let detail):
      "Codex disconnected\(detail.isEmpty ? "." : ": \(detail)")"
    case .server(_, let message):
      "Codex: \(message)"
    case .invalidResponse(let detail):
      "Codex returned an invalid response: \(detail)"
    case .requestTimedOut(let method):
      if method == "thread/resume" {
        "Codex took too long to reopen this task. Its connection was reset; retry once to reconnect."
      } else {
        "Codex did not respond to \(method) before the request timed out."
      }
    case .notAuthenticated:
      "Sign in with ChatGPT before using a Codex thread."
    case .turnFailed(let detail):
      "Codex turn failed: \(detail)"
    case .turnInterrupted:
      "Codex turn was stopped."
    }
  }
}

public enum CodexAppServerTransport: Sendable, Equatable {
  case local
  case remote(endpoint: URL, bearerToken: String?)
  case managedRemote(sshHost: String)

  var connectionDescription: String {
    switch self {
    case .local: "Local Codex App Server"
    case .remote(let endpoint, _): endpoint.absoluteString
    case .managedRemote(let sshHost): "Managed remote Codex via \(sshHost)"
    }
  }
}

public actor CodexAppServerClient {
  public typealias EventHandler = @Sendable (CodexAppServerEvent) async -> Void
  public typealias DynamicToolHandler =
    @Sendable (CodexDynamicToolCall) async -> CodexDynamicToolResult

  private struct PendingTurn {
    var finalReply = ""
    var streamedReply = ""
    var streamedItemID: String?
    var errorMessage: String?
    var continuation: CheckedContinuation<CodexTurnResult, Never>?
    var completedResult: CodexTurnResult?
  }

  private let executableURL: URL?
  private let sshExecutableURL: URL
  private let transport: CodexAppServerTransport
  private let eventHandler: EventHandler
  private let dynamicToolHandler: DynamicToolHandler
  private let requestTimeoutNanoseconds: UInt64
  private let threadResumeRequestTimeoutNanoseconds: UInt64
  private var process: Process?
  private var webSocketTask: URLSessionWebSocketTask?
  private var webSocketReceiveTask: Task<Void, Never>?
  private var standardInput: FileHandle?
  private var standardOutput: FileHandle?
  private var standardError: FileHandle?
  private var outputBuffer = Data()
  private var startupTask: Task<Void, Error>?
  private var initialized = false
  private var requestCounter: Int64 = 0
  private var pendingRequests: [
    String: CheckedContinuation<JSONValue, Error>
  ] = [:]
  private var pendingRequestTimeoutTasks: [String: Task<Void, Never>] = [:]
  private var cancelledRequestKeys = Set<String>()
  private var pendingTurns: [String: PendingTurn] = [:]
  private var cancelledTurnIDs = Set<String>()
  private var ignoredCompletedTurnIDs = Set<String>()
  private var loadedThreadIDs = Set<String>()
  private var latestStderr = ""

  public init(
    executableURL: URL? = CodexAppServerClient.resolveExecutableURL(),
    sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
    transport: CodexAppServerTransport = .local,
    requestTimeoutNanoseconds: UInt64 = 30_000_000_000,
    threadResumeRequestTimeoutNanoseconds: UInt64 = 120_000_000_000,
    eventHandler: @escaping EventHandler,
    dynamicToolHandler: @escaping DynamicToolHandler
  ) {
    self.executableURL = executableURL
    self.sshExecutableURL = sshExecutableURL
    self.transport = transport
    self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
    self.threadResumeRequestTimeoutNanoseconds = threadResumeRequestTimeoutNanoseconds
    self.eventHandler = eventHandler
    self.dynamicToolHandler = dynamicToolHandler
  }

  deinit {
    standardOutput?.readabilityHandler = nil
    standardError?.readabilityHandler = nil
    if process?.isRunning == true {
      process?.terminate()
    }
    webSocketReceiveTask?.cancel()
    webSocketTask?.cancel(with: .goingAway, reason: nil)
  }

  nonisolated public static func resolveExecutableURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    var candidates: [String] = []
    if let configured = environment["ORG2_CODEX_EXECUTABLE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
       !configured.isEmpty {
      candidates.append(configured)
    }
    if let bundled = Bundle.main.url(forResource: "codex", withExtension: nil)?.path {
      candidates.append(bundled)
    }
    candidates.append(contentsOf: [
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex"
    ])
    if let path = environment["PATH"] {
      candidates.append(contentsOf: path.split(separator: ":").map {
        URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path
      })
    }
    return candidates.lazy
      .map { URL(fileURLWithPath: $0).standardizedFileURL }
      .first {
        fileManager.isExecutableFile(atPath: $0.path)
          && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != false
      }
  }

  nonisolated static func managedRemoteSSHArguments(sshHost rawSSHHost: String) throws -> [String] {
    let sshHost = rawSSHHost.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: ".-_@:%[]+")
    )
    guard !sshHost.isEmpty,
          !sshHost.hasPrefix("-"),
          sshHost.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else {
      throw CodexAppServerError.invalidResponse(
        "managed remote Codex needs a valid SSH host or ~/.ssh/config alias"
      )
    }
    return [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=15",
      "-o", "ServerAliveInterval=15",
      "-o", "ServerAliveCountMax=12",
      sshHost,
      Self.managedRemoteCommand
    ]
  }

  private nonisolated static let managedRemoteCommand =
    #"exec /bin/sh -lc 'PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; exec codex app-server proxy'"#

  public func accountState() async throws -> CodexAccountState {
    let result = try await request(
      method: "account/read",
      params: .object(["refreshToken": .bool(false)])
    )
    guard let object = result.objectValue else {
      throw CodexAppServerError.invalidResponse("account/read had no result object")
    }
    guard let account = object["account"], account != .null else {
      return .signedOut
    }
    guard let type = account["type"]?.stringValue else {
      return .other("Unknown Codex account")
    }
    switch type {
    case "chatgpt":
      return .chatGPT(
        email: account["email"]?.stringValue,
        plan: account["planType"]?.stringValue
      )
    case "apiKey":
      return .apiKey
    default:
      return .other(type)
    }
  }

  public func beginChatGPTLogin() async throws -> CodexLoginStart {
    let result = try await request(
      method: "account/login/start",
      params: .object([
        "type": .string("chatgpt"),
        "useHostedLoginSuccessPage": .bool(true),
        "appBrand": .string("chatgpt")
      ])
    )
    guard let loginID = result["loginId"]?.stringValue,
          let rawURL = result["authUrl"]?.stringValue,
          let authURL = URL(string: rawURL)
    else {
      throw CodexAppServerError.invalidResponse("login response omitted its browser URL")
    }
    return CodexLoginStart(loginID: loginID, authURL: authURL)
  }

  public func listModels() async throws -> [AIChatModelOption] {
    var models: [AIChatModelOption] = []
    var cursor: String?
    repeat {
      var params: [String: JSONValue] = [
        "limit": .integer(100),
        "includeHidden": .bool(false)
      ]
      if let cursor {
        params["cursor"] = .string(cursor)
      }
      let result = try await request(
        method: "model/list",
        params: .object(params)
      )
      guard let rows = result["data"]?.arrayValue else {
        throw CodexAppServerError.invalidResponse("model/list omitted its model catalog")
      }
      models.append(contentsOf: rows.compactMap(Self.modelOption))
      cursor = result["nextCursor"]?.stringValue
    } while cursor != nil
    return models
  }

  public func listExternalThreads(limit: Int = 100) async throws -> [ExternalThreadSummary] {
    let requestedLimit = max(1, min(limit, 2_000))
    var summaries: [ExternalThreadSummary] = []
    var cursor: String?
    repeat {
      var params: [String: JSONValue] = [
        "limit": .integer(Int64(min(200, requestedLimit - summaries.count))),
        "sortKey": .string("recency_at"),
        "sortDirection": .string("desc"),
        "useStateDbOnly": .bool(true),
        "sourceKinds": .array([
          .string("cli"),
          .string("vscode"),
          .string("appServer"),
          .string("exec"),
          .string("unknown")
        ])
      ]
      if let cursor {
        params["cursor"] = .string(cursor)
      }
      let result = try await request(method: "thread/list", params: .object(params))
      guard let rows = result["data"]?.arrayValue else {
        throw CodexAppServerError.invalidResponse("thread/list omitted its thread catalog")
      }
      summaries.append(contentsOf: rows.compactMap { Self.externalThreadSummary($0) })
      let nextCursor = result["nextCursor"]?.stringValue
      guard nextCursor != cursor else { break }
      cursor = nextCursor
    } while cursor != nil && summaries.count < requestedLimit
    return Array(summaries.prefix(requestedLimit))
  }

  public func searchExternalThreads(
    _ searchTerm: String,
    limit: Int = 100
  ) async throws -> [ExternalThreadSummary] {
    let normalizedSearchTerm = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedSearchTerm.isEmpty else {
      return try await listExternalThreads(limit: limit)
    }
    let requestedLimit = max(1, min(limit, 2_000))
    var summaries: [ExternalThreadSummary] = []
    var cursor: String?
    repeat {
      var params: [String: JSONValue] = [
        "searchTerm": .string(normalizedSearchTerm),
        "limit": .integer(Int64(min(200, requestedLimit - summaries.count))),
        "sortKey": .string("recency_at"),
        "sortDirection": .string("desc"),
        "sourceKinds": .array([
          .string("cli"),
          .string("vscode"),
          .string("appServer"),
          .string("exec"),
          .string("unknown")
        ])
      ]
      if let cursor {
        params["cursor"] = .string(cursor)
      }
      let result = try await request(method: "thread/search", params: .object(params))
      guard let rows = result["data"]?.arrayValue else {
        throw CodexAppServerError.invalidResponse("thread/search omitted its thread catalog")
      }
      summaries.append(contentsOf: rows.compactMap(Self.externalThreadSearchSummary))
      let nextCursor = result["nextCursor"]?.stringValue
      guard nextCursor != cursor else { break }
      cursor = nextCursor
    } while cursor != nil && summaries.count < requestedLimit
    return Array(summaries.prefix(requestedLimit))
  }

  public func readExternalThread(_ externalID: String) async throws -> ExternalThreadDetail {
    let result = try await request(
      method: "thread/read",
      params: .object([
        "threadId": .string(externalID),
        "includeTurns": .bool(false)
      ])
    )
    guard let rawThread = result["thread"],
          let summary = Self.externalThreadSummary(rawThread)
    else {
      throw CodexAppServerError.invalidResponse("thread/read omitted its thread")
    }
    guard let transcriptPath = rawThread["path"]?.stringValue,
          !transcriptPath.isEmpty
    else {
      throw CodexRolloutTranscriptError.pathUnavailable
    }
    let transcriptURL = URL(fileURLWithPath: transcriptPath).standardizedFileURL
    guard FileManager.default.isReadableFile(atPath: transcriptURL.path) else {
      throw CodexRolloutTranscriptError.pathUnavailable
    }
    return ExternalThreadDetail(
      thread: summary,
      messages: try await CodexRolloutTranscriptReader.messages(at: transcriptURL)
    )
  }

  public func ensureThread(
    existingThreadID: String?,
    cwd: URL,
    model: String? = nil,
    sandboxAccess: CodexSandboxAccess = .workspaceWrite
  ) async throws -> String {
    try await connect()
    if let existingThreadID {
      if !loadedThreadIDs.contains(existingThreadID) {
        var params: [String: JSONValue] = [
          "threadId": .string(existingThreadID),
          "cwd": .string(cwd.standardizedFileURL.path),
          "approvalPolicy": .string("never"),
          "sandbox": .string(sandboxAccess.threadSandboxValue),
          "dynamicTools": .array(Self.localEditDynamicTools)
        ]
        if let model {
          params["model"] = .string(model)
        }
        let result: JSONValue
        do {
          result = try await requestRaw(
            method: "thread/resume",
            params: .object(params),
            timeoutNanoseconds: threadResumeRequestTimeoutNanoseconds
          )
        } catch let error as CodexAppServerError {
          if case .requestTimedOut("thread/resume") = error {
            // A large rollout can finish loading after the caller's deadline.
            // If that late response is ignored while this process keeps its
            // writer lock, every later retry attempts to resume an already
            // resumed thread and can never recover. Tear down the transport so
            // the next Retry starts from a clean app-server process.
            shutdown()
          }
          throw error
        }
        guard result["thread"]?["id"]?.stringValue == existingThreadID else {
          throw CodexAppServerError.invalidResponse("thread/resume returned a different thread")
        }
        loadedThreadIDs.insert(existingThreadID)
      }
      return existingThreadID
    }

    var params: [String: JSONValue] = [
      "cwd": .string(cwd.standardizedFileURL.path),
      "approvalPolicy": .string("never"),
      "sandbox": .string(sandboxAccess.threadSandboxValue),
      "serviceName": .string("org2_workspace"),
      "developerInstructions": .string(Self.localEditDeveloperInstructions),
      "dynamicTools": .array(Self.localEditDynamicTools)
    ]
    if let model {
      params["model"] = .string(model)
    }
    let result = try await requestRaw(
      method: "thread/start",
      params: .object(params)
    )
    guard let threadID = result["thread"]?["id"]?.stringValue else {
      throw CodexAppServerError.invalidResponse("thread/start omitted the thread id")
    }
    loadedThreadIDs.insert(threadID)
    return threadID
  }

  public func runTurn(
    threadID: String,
    turnID localTurnID: String,
    message: String,
    workspaceContext: String? = nil,
    attachments: [OpenClawChatAttachment],
    cwd: URL,
    clientUserMessageID: UUID,
    model: String? = nil,
    reasoningEffort: String? = nil,
    sandboxAccess: CodexSandboxAccess = .workspaceWrite
  ) async throws -> CodexTurnResult {
    try await connect()
    var input: [JSONValue] = [
      .object([
        "type": .string("text"),
        "text": .string(
          Self.wrappedUserMessage(
            message,
            localTurnID: localTurnID,
            workspaceContext: workspaceContext
          )
        )
      ])
    ]
    input.append(contentsOf: attachments.map {
      .object([
        "type": .string("image"),
        "url": .string($0.dataURLString)
      ])
    })
    var params: [String: JSONValue] = [
      "threadId": .string(threadID),
      "input": .array(input),
      "cwd": .string(cwd.standardizedFileURL.path),
      "approvalPolicy": .string("never"),
      "sandboxPolicy": sandboxAccess.turnSandboxPolicy(cwd: cwd),
      "clientUserMessageId": .string(clientUserMessageID.uuidString.lowercased())
    ]
    params["model"] = model.map(JSONValue.string) ?? .null
    params["effort"] = reasoningEffort.map(JSONValue.string) ?? .null
    let result = try await requestRaw(
      method: "turn/start",
      params: .object(params)
    )
    guard let turnID = result["turn"]?["id"]?.stringValue else {
      throw CodexAppServerError.invalidResponse("turn/start omitted the turn id")
    }
    let turnResult = await waitForTurn(threadID: threadID, turnID: turnID)
    switch turnResult.status {
    case .completed:
      return turnResult
    case .interrupted:
      throw CodexAppServerError.turnInterrupted
    case .failed:
      throw CodexAppServerError.turnFailed(turnResult.errorMessage ?? "unknown failure")
    }
  }

  public func interrupt(threadID: String, turnID: String) async throws {
    _ = try await request(
      method: "turn/interrupt",
      params: .object([
        "threadId": .string(threadID),
        "turnId": .string(turnID)
      ])
    )
  }

  public func steer(
    threadID: String,
    expectedTurnID: String,
    message: String,
    attachments: [OpenClawChatAttachment] = []
  ) async throws {
    try await connect()
    var input: [JSONValue] = [
      .object([
        "type": .string("text"),
        "text": .string(message)
      ])
    ]
    input.append(contentsOf: attachments.map {
      .object([
        "type": .string("image"),
        "url": .string($0.dataURLString)
      ])
    })
    let result = try await requestRaw(
      method: "turn/steer",
      params: .object([
        "threadId": .string(threadID),
        "input": .array(input),
        "expectedTurnId": .string(expectedTurnID)
      ])
    )
    guard result["turnId"]?.stringValue == expectedTurnID else {
      throw CodexAppServerError.invalidResponse("turn/steer returned a different turn id")
    }
  }

  public func shutdown() {
    let processToStop = process
    process = nil
    standardOutput?.readabilityHandler = nil
    standardError?.readabilityHandler = nil
    standardOutput = nil
    standardError = nil
    standardInput = nil
    initialized = false
    startupTask = nil
    outputBuffer = Data()
    loadedThreadIDs.removeAll()
    if let processToStop, processToStop.isRunning {
      processToStop.terminate()
      // A wedged app-server can ignore SIGTERM while retaining Codex's
      // advisory task-writer lock. This client has already discarded its
      // transport, so leaving that orphan alive only makes every later Retry
      // fail. Force the abandoned child down before another connection starts.
      if processToStop.isRunning {
        _ = Darwin.kill(processToStop.processIdentifier, SIGKILL)
      }
    }
    webSocketReceiveTask?.cancel()
    webSocketReceiveTask = nil
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    failPendingRequests(CodexAppServerError.disconnected("client shut down"))
  }

  private func connect() async throws {
    if initialized, transportIsConnected {
      return
    }
    if let startupTask {
      return try await startupTask.value
    }
    let task = Task { [weak self] in
      guard let self else {
        throw CodexAppServerError.disconnected("client was released")
      }
      try await self.performConnect()
    }
    startupTask = task
    do {
      try await task.value
      startupTask = nil
    } catch {
      startupTask = nil
      throw error
    }
  }

  private var transportIsConnected: Bool {
    switch transport {
    case .local, .managedRemote: process?.isRunning == true
    case .remote: webSocketTask != nil
    }
  }

  nonisolated private static func modelOption(_ value: JSONValue) -> AIChatModelOption? {
    guard let id = value["id"]?.stringValue,
          !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    let reasoningOptions = value["supportedReasoningEfforts"]?.arrayValue?
      .compactMap { option -> AIChatReasoningOption? in
        guard let effort = option["reasoningEffort"]?.stringValue else { return nil }
        return AIChatReasoningOption(
          id: effort,
          label: Self.reasoningLabel(effort),
          detail: option["description"]?.stringValue
        )
      } ?? []
    return AIChatModelOption(
      id: id,
      label: value["displayName"]?.stringValue ?? id,
      detail: value["description"]?.stringValue,
      supportsReasoning: !reasoningOptions.isEmpty,
      reasoningOptions: reasoningOptions,
      defaultReasoningEffort: value["defaultReasoningEffort"]?.stringValue,
      isDefault: value["isDefault"]?.boolValue ?? false
    )
  }

  nonisolated static func externalThreadSummary(
    _ value: JSONValue,
    previewOverride: String? = nil
  ) -> ExternalThreadSummary? {
    guard let externalID = value["id"]?.stringValue else { return nil }
    let preview = normalizedExternalText(previewOverride)
      ?? normalizedExternalText(value["preview"]?.stringValue)
    let name = normalizedExternalText(value["name"]?.stringValue)
    let fallbackTitle = preview?
      .split(separator: "\n", omittingEmptySubsequences: true)
      .first
      .map(String.init)
    let title = String((name ?? fallbackTitle ?? "Untitled Codex task").prefix(180))
    let createdAt = Date(timeIntervalSince1970: externalTimestamp(value["createdAt"]) ?? 0)
    let updatedAt = Date(timeIntervalSince1970: externalTimestamp(value["updatedAt"]) ?? createdAt.timeIntervalSince1970)
    return ExternalThreadSummary(
      harness: .codex,
      externalID: externalID,
      title: title,
      preview: preview.map { String($0.prefix(500)) },
      workspacePath: normalizedExternalText(value["cwd"]?.stringValue),
      source: normalizedExternalText(value["source"]?.stringValue),
      modelProvider: normalizedExternalText(value["modelProvider"]?.stringValue),
      createdAt: createdAt,
      updatedAt: updatedAt,
      status: value["status"]?["type"]?.stringValue ?? "unknown",
      isPinned: value["isPinned"]?.boolValue ?? false
    )
  }

  nonisolated static func externalThreadSearchSummary(_ value: JSONValue) -> ExternalThreadSummary? {
    guard let thread = value["thread"] else { return nil }
    return externalThreadSummary(thread, previewOverride: value["snippet"]?.stringValue)
  }

  nonisolated static func externalThreadMessages(_ thread: JSONValue) -> [ExternalThreadMessage] {
    guard let turns = thread["turns"]?.arrayValue else { return [] }
    return turns.enumerated().flatMap { turnIndex, turn in
      let timestamp = Date(timeIntervalSince1970: externalTimestamp(turn["startedAt"]) ?? 0)
      return (turn["items"]?.arrayValue ?? []).enumerated().compactMap { itemIndex, item -> ExternalThreadMessage? in
        guard let type = item["type"]?.stringValue else { return nil }
        let role: ExternalThreadMessage.Role
        let content: String?
        switch type {
        case "userMessage":
          role = .user
          content = item["content"]?.arrayValue?
            .compactMap { part in
              guard part["type"]?.stringValue == "text" else { return nil }
              return part["text"]?.stringValue
            }
            .joined(separator: "\n")
        case "agentMessage":
          role = .assistant
          content = item["text"]?.stringValue
        default:
          return nil
        }
        guard let normalized = normalizedExternalText(content) else { return nil }
        let id = item["id"]?.stringValue ?? "turn-\(turnIndex)-item-\(itemIndex)"
        return ExternalThreadMessage(id: id, role: role, content: normalized, createdAt: timestamp)
      }
    }
  }

  nonisolated private static func normalizedExternalText(_ value: String?) -> String? {
    guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !normalized.isEmpty
    else { return nil }
    return normalized
  }

  nonisolated private static func externalTimestamp(_ value: JSONValue?) -> TimeInterval? {
    switch value {
    case .integer(let seconds): Double(seconds)
    case .number(let seconds): seconds
    default: nil
    }
  }

  nonisolated private static func reasoningLabel(_ value: String) -> String {
    switch value.lowercased() {
    case "off", "none": return "Off"
    case "minimal": return "Minimal"
    case "low": return "Low"
    case "medium": return "Medium"
    case "high": return "High"
    case "xhigh": return "Extra high"
    case "max": return "Maximum"
    case "ultra": return "Ultra"
    case "adaptive": return "Adaptive"
    default:
      return value
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .capitalized
    }
  }

  private func performConnect() async throws {
    if !transportIsConnected {
      switch transport {
      case .local, .managedRemote:
        try launch()
      case .remote(let endpoint, let bearerToken):
        try connectRemote(endpoint: endpoint, bearerToken: bearerToken)
      }
    }
    _ = try await requestRaw(
      method: "initialize",
      params: .object([
        "clientInfo": .object([
          "name": .string("org2_workspace"),
          "title": .string("Org2 Workspace"),
          "version": .string(Self.clientVersion)
        ]),
        "capabilities": .object([
          "experimentalApi": .bool(true)
        ])
      ])
    )
    try await sendMessage(.object([
      "method": .string("initialized"),
      "params": .object([:])
    ]))
    initialized = true
    await eventHandler(.connectionChanged(
      isConnected: true,
      detail: transport == .local ? executableURL?.path : transport.connectionDescription
    ))
  }

  private func connectRemote(endpoint: URL, bearerToken: String?) throws {
    guard endpoint.scheme?.lowercased() == "ws" || endpoint.scheme?.lowercased() == "wss" else {
      throw CodexAppServerError.invalidResponse("remote Codex endpoint must use ws:// or wss://")
    }
    var request = URLRequest(url: endpoint)
    if let bearerToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
       !bearerToken.isEmpty {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    let socket = URLSession.shared.webSocketTask(with: request)
    webSocketTask = socket
    socket.resume()
    webSocketReceiveTask = Task { [weak self] in
      do {
        while !Task.isCancelled {
          let message = try await socket.receive()
          await self?.receiveWebSocketMessage(message)
        }
      } catch {
        guard !Task.isCancelled else { return }
        await self?.transportEnded(error.localizedDescription)
      }
    }
  }

  private func launch() throws {
    let launchURL: URL
    let arguments: [String]
    switch transport {
    case .local:
      guard let executableURL else {
        throw CodexAppServerError.executableNotFound
      }
      launchURL = executableURL
      arguments = ["app-server", "--listen", "stdio://"]
    case .managedRemote(let sshHost):
      launchURL = sshExecutableURL
      arguments = try Self.managedRemoteSSHArguments(sshHost: sshHost)
    case .remote:
      throw CodexAppServerError.invalidResponse(
        "WebSocket Codex destinations cannot launch a subprocess transport"
      )
    }
    let process = Process()
    process.executableURL = launchURL
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    process.environment = ProcessInfo.processInfo.environment

    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    do {
      try process.run()
    } catch {
      throw CodexAppServerError.launchFailed(error.localizedDescription)
    }
    self.process = process
    standardInput = input.fileHandleForWriting
    latestStderr = ""
    startReaders(
      stdout: output.fileHandleForReading,
      stderr: error.fileHandleForReading
    )
  }

  private func receiveWebSocketMessage(_ message: URLSessionWebSocketTask.Message) async {
    switch message {
    case .string(let text):
      await receiveLine(Data(text.utf8))
    case .data(let data):
      await receiveLine(data)
    @unknown default:
      await eventHandler(.warning(threadID: nil, message: "Ignored an unknown Codex WebSocket frame."))
    }
  }

  private func startReaders(stdout: FileHandle, stderr: FileHandle) {
    standardOutput = stdout
    standardError = stderr
    outputBuffer = Data()
    stdout.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      Task {
        await self?.receiveOutput(data)
      }
    }
    stderr.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task {
        await self?.recordStderr(data)
      }
    }
  }

  private func receiveOutput(_ data: Data) async {
    guard !data.isEmpty else {
      if !outputBuffer.isEmpty {
        let finalLine = outputBuffer
        outputBuffer = Data()
        await receiveLine(finalLine)
      }
      await transportEnded()
      return
    }
    outputBuffer.append(data)
    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      let line = Data(outputBuffer[..<newline])
      outputBuffer.removeSubrange(...newline)
      if !line.isEmpty {
        await receiveLine(line)
      }
    }
  }

  private func recordStderr(_ data: Data) {
    let text = String(decoding: data, as: UTF8.self)
    latestStderr = String((latestStderr + text).suffix(4_000))
  }

  private func transportEnded(_ detail: String? = nil) async {
    guard process != nil || webSocketTask != nil else { return }
    let stderr = latestStderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = detail ?? (stderr.isEmpty ? "connection closed" : stderr)
    process = nil
    webSocketReceiveTask?.cancel()
    webSocketReceiveTask = nil
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    standardInput = nil
    standardOutput?.readabilityHandler = nil
    standardError?.readabilityHandler = nil
    standardOutput = nil
    standardError = nil
    outputBuffer = Data()
    initialized = false
    startupTask = nil
    loadedThreadIDs.removeAll()
    failPendingRequests(CodexAppServerError.disconnected(message))
    for turnID in Array(pendingTurns.keys) {
      guard var pending = pendingTurns[turnID] else { continue }
      guard pending.completedResult == nil else { continue }
      let result = CodexTurnResult(
        threadID: "",
        turnID: turnID,
        status: .failed,
        reply: pending.finalReply.isEmpty ? pending.streamedReply : pending.finalReply,
        errorMessage: message
      )
      if let continuation = pending.continuation {
        continuation.resume(returning: result)
      } else {
        pending.completedResult = result
        pendingTurns[turnID] = pending
      }
    }
    await eventHandler(.connectionChanged(isConnected: false, detail: message))
  }

  private func request(method: String, params: JSONValue) async throws -> JSONValue {
    try await connect()
    return try await requestRaw(method: method, params: params)
  }

  private func requestRaw(
    method: String,
    params: JSONValue,
    timeoutNanoseconds: UInt64? = nil
  ) async throws -> JSONValue {
    requestCounter &+= 1
    let requestID = requestCounter
    let key = String(requestID)
    let effectiveTimeoutNanoseconds = timeoutNanoseconds ?? requestTimeoutNanoseconds
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        if cancelledRequestKeys.remove(key) != nil || Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        pendingRequests[key] = continuation
        pendingRequestTimeoutTasks[key] = Task { [weak self] in
          do {
            try await Task.sleep(nanoseconds: effectiveTimeoutNanoseconds)
          } catch {
            return
          }
          await self?.failPendingRequest(
            key: key,
            error: CodexAppServerError.requestTimedOut(method)
          )
        }
        Task { [weak self] in
          guard let self else { return }
          do {
            try await self.sendMessage(.object([
              "id": .integer(requestID),
              "method": .string(method),
              "params": params
            ]))
          } catch {
            await self.failPendingRequest(key: key, error: error)
          }
        }
      }
    } onCancel: {
      Task { [weak self] in
        await self?.cancelPendingRequest(key: key)
      }
    }
  }

  private func failPendingRequest(key: String, error: Error) {
    pendingRequestTimeoutTasks.removeValue(forKey: key)?.cancel()
    pendingRequests.removeValue(forKey: key)?.resume(throwing: error)
  }

  private func cancelPendingRequest(key: String) {
    if pendingRequests[key] == nil {
      cancelledRequestKeys.insert(key)
      return
    }
    failPendingRequest(key: key, error: CancellationError())
  }

  private func sendMessage(_ message: JSONValue) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try encoder.encode(message)
    switch transport {
    case .local, .managedRemote:
      guard let standardInput, process?.isRunning == true else {
        throw CodexAppServerError.disconnected("app server is not running")
      }
      var line = data
      line.append(0x0A)
      do {
        try standardInput.write(contentsOf: line)
      } catch {
        throw CodexAppServerError.disconnected(error.localizedDescription)
      }
    case .remote:
      guard let webSocketTask else {
        throw CodexAppServerError.disconnected("remote app server is not connected")
      }
      try await webSocketTask.send(.string(String(decoding: data, as: UTF8.self)))
    }
  }

  private func receiveLine(_ data: Data) async {
    let message: JSONValue
    do {
      message = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      await eventHandler(.warning(
        threadID: nil,
        message: "Ignored an invalid Codex protocol message."
      ))
      return
    }
    guard let object = message.objectValue else { return }
    if let method = object["method"]?.stringValue {
      if let id = object["id"] {
        await handleServerRequest(id: id, method: method, params: object["params"] ?? .object([:]))
      } else {
        await handleNotification(method: method, params: object["params"] ?? .object([:]))
      }
      return
    }
    guard let id = object["id"], let key = Self.requestKey(id),
          let continuation = pendingRequests.removeValue(forKey: key)
    else {
      return
    }
    pendingRequestTimeoutTasks.removeValue(forKey: key)?.cancel()
    if let error = object["error"], error != .null {
      continuation.resume(throwing: CodexAppServerError.server(
        code: error["code"].flatMap(Self.integer),
        message: error["message"]?.stringValue ?? "unknown app-server error"
      ))
    } else if let result = object["result"] {
      continuation.resume(returning: result)
    } else {
      continuation.resume(throwing: CodexAppServerError.invalidResponse("missing result"))
    }
  }

  private func handleServerRequest(id: JSONValue, method: String, params: JSONValue) async {
    guard method == "item/tool/call",
          let callID = params["callId"]?.stringValue,
          let threadID = params["threadId"]?.stringValue,
          let turnID = params["turnId"]?.stringValue,
          let tool = params["tool"]?.stringValue
    else {
      do {
        try await sendMessage(.object([
          "id": id,
          "error": .object([
            "code": .integer(-32601),
            "message": .string("Org2 Workspace does not support \(method)")
          ])
        ]))
      } catch {
        // The process-exit path will surface a transport failure.
      }
      return
    }
    let call = CodexDynamicToolCall(
      callID: callID,
      threadID: threadID,
      turnID: turnID,
      tool: tool,
      arguments: params["arguments"] ?? .object([:])
    )
    Task { [weak self, dynamicToolHandler] in
      let result = await dynamicToolHandler(call)
      await self?.sendDynamicToolResponse(id: id, result: result)
    }
  }

  private func sendDynamicToolResponse(id: JSONValue, result: CodexDynamicToolResult) async {
    do {
      try await sendMessage(.object([
        "id": id,
        "result": .object([
          "contentItems": .array([
            .object([
              "type": .string("inputText"),
              "text": .string(result.text)
            ])
          ]),
          "success": .bool(result.success)
        ])
      ]))
    } catch {
      // The process-exit path will surface a transport failure.
    }
  }

  private func handleNotification(method: String, params: JSONValue) async {
    switch method {
    case "account/updated":
      await eventHandler(.accountUpdated(
        authMode: params["authMode"]?.stringValue,
        plan: params["planType"]?.stringValue
      ))
    case "account/login/completed":
      await eventHandler(.loginCompleted(
        loginID: params["loginId"]?.stringValue,
        success: params["success"]?.boolValue ?? false,
        error: params["error"]?.stringValue
      ))
    case "turn/started":
      if let threadID = params["threadId"]?.stringValue,
         let turnID = params["turn"]?["id"]?.stringValue {
        pendingTurns[turnID] = pendingTurns[turnID] ?? PendingTurn()
        await eventHandler(.turnStarted(threadID: threadID, turnID: turnID))
      }
    case "item/agentMessage/delta":
      guard let threadID = params["threadId"]?.stringValue,
            let turnID = params["turnId"]?.stringValue,
            let delta = params["delta"]?.stringValue
      else { return }
      let itemID = params["itemId"]?.stringValue ?? "\(turnID):legacy-agent-message"
      var pending = pendingTurns[turnID] ?? PendingTurn()
      pending.streamedReply = CodexStreamingText.appending(
        delta,
        itemID: itemID,
        after: pending.streamedItemID,
        to: pending.streamedReply
      )
      pending.streamedItemID = itemID
      pendingTurns[turnID] = pending
      await eventHandler(.agentMessageDelta(
        threadID: threadID,
        turnID: turnID,
        itemID: itemID,
        delta: delta
      ))
    case "item/reasoning/summaryTextDelta":
      guard let threadID = params["threadId"]?.stringValue,
            let turnID = params["turnId"]?.stringValue,
            let delta = params["delta"]?.stringValue
      else { return }
      await eventHandler(.reasoningDelta(
        threadID: threadID,
        turnID: turnID,
        delta: delta
      ))
    case "item/started", "item/completed":
      await handleItemNotification(
        params,
        completed: method == "item/completed"
      )
    case "error":
      let turnID = params["turnId"]?.stringValue
      let message = params["error"]?["message"]?.stringValue ?? "Codex turn error"
      if let turnID {
        var pending = pendingTurns[turnID] ?? PendingTurn()
        pending.errorMessage = message
        pendingTurns[turnID] = pending
      }
      await eventHandler(.warning(
        threadID: params["threadId"]?.stringValue,
        message: message
      ))
    case "warning":
      await eventHandler(.warning(
        threadID: params["threadId"]?.stringValue,
        message: params["message"]?.stringValue ?? "Codex warning"
      ))
    case "turn/completed":
      completeTurn(params)
    default:
      break
    }
  }

  private func handleItemNotification(
    _ params: JSONValue,
    completed: Bool
  ) async {
    guard let threadID = params["threadId"]?.stringValue,
          let turnID = params["turnId"]?.stringValue,
          let item = params["item"],
          let itemID = item["id"]?.stringValue,
          let type = item["type"]?.stringValue
    else {
      return
    }
    if completed, type == "agentMessage",
       let text = item["text"]?.stringValue {
      let phase = item["phase"]?.stringValue
      if phase == nil || phase == "final_answer" {
        var pending = pendingTurns[turnID] ?? PendingTurn()
        pending.finalReply = text
        pendingTurns[turnID] = pending
      }
      return
    }
    guard let activity = Self.activityDescription(item: item, type: type) else {
      return
    }
    await eventHandler(.activity(
      threadID: threadID,
      turnID: turnID,
      itemID: itemID,
      title: activity.title,
      detail: activity.detail,
      status: completed ? activity.completedStatus : .running
    ))
  }

  private func completeTurn(_ params: JSONValue) {
    guard let threadID = params["threadId"]?.stringValue,
          let turn = params["turn"],
          let turnID = turn["id"]?.stringValue
    else {
      return
    }
    if ignoredCompletedTurnIDs.remove(turnID) != nil {
      pendingTurns.removeValue(forKey: turnID)
      return
    }
    var pending = pendingTurns[turnID] ?? PendingTurn()
    let status = CodexTurnResult.Status(rawValue: turn["status"]?.stringValue ?? "")
      ?? .failed
    let errorMessage = turn["error"]?["message"]?.stringValue ?? pending.errorMessage
    let result = CodexTurnResult(
      threadID: threadID,
      turnID: turnID,
      status: status,
      reply: pending.finalReply.isEmpty ? pending.streamedReply : pending.finalReply,
      errorMessage: errorMessage
    )
    if let continuation = pending.continuation {
      pendingTurns.removeValue(forKey: turnID)
      continuation.resume(returning: result)
    } else {
      pending.completedResult = result
      pendingTurns[turnID] = pending
    }
  }

  private func waitForTurn(threadID: String, turnID: String) async -> CodexTurnResult {
    if Task.isCancelled {
      return CodexTurnResult(
        threadID: threadID,
        turnID: turnID,
        status: .interrupted,
        reply: "",
        errorMessage: nil
      )
    }
    if let completed = pendingTurns[turnID]?.completedResult {
      pendingTurns.removeValue(forKey: turnID)
      return completed
    }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if cancelledTurnIDs.remove(turnID) != nil || Task.isCancelled {
          continuation.resume(returning: CodexTurnResult(
            threadID: threadID,
            turnID: turnID,
            status: .interrupted,
            reply: "",
            errorMessage: nil
          ))
          return
        }
        var pending = pendingTurns[turnID] ?? PendingTurn()
        if let completed = pending.completedResult {
          pendingTurns.removeValue(forKey: turnID)
          continuation.resume(returning: completed)
        } else {
          pending.continuation = continuation
          pendingTurns[turnID] = pending
        }
      }
    } onCancel: {
      Task { [weak self] in
        await self?.cancelPendingTurn(threadID: threadID, turnID: turnID)
      }
    }
  }

  private func cancelPendingTurn(threadID: String, turnID: String) {
    ignoredCompletedTurnIDs.insert(turnID)
    guard var pending = pendingTurns[turnID] else {
      cancelledTurnIDs.insert(turnID)
      return
    }
    let result = CodexTurnResult(
      threadID: threadID,
      turnID: turnID,
      status: .interrupted,
      reply: pending.finalReply.isEmpty ? pending.streamedReply : pending.finalReply,
      errorMessage: nil
    )
    if let continuation = pending.continuation {
      pendingTurns.removeValue(forKey: turnID)
      continuation.resume(returning: result)
    } else {
      pending.completedResult = result
      pendingTurns[turnID] = pending
    }
  }

  private func failPendingRequests(_ error: Error) {
    let timeoutTasks = pendingRequestTimeoutTasks.values
    pendingRequestTimeoutTasks.removeAll()
    timeoutTasks.forEach { $0.cancel() }
    let requests = pendingRequests.values
    pendingRequests.removeAll()
    cancelledRequestKeys.removeAll()
    for continuation in requests {
      continuation.resume(throwing: error)
    }
  }

  nonisolated private static var clientVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
  }

  nonisolated private static func requestKey(_ id: JSONValue) -> String? {
    switch id {
    case .integer(let value):
      String(value)
    case .number(let value):
      value.rounded() == value ? String(Int64(value)) : String(value)
    case .string(let value):
      value
    default:
      nil
    }
  }

  nonisolated private static func integer(_ value: JSONValue) -> Int? {
    switch value {
    case .integer(let number): Int(exactly: number)
    case .number(let number): Int(exactly: number)
    default: nil
    }
  }

  nonisolated private static func wrappedUserMessage(
    _ message: String,
    localTurnID: String,
    workspaceContext: String?
  ) -> String {
    let workspaceSnapshot = workspaceContext?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let snapshotSection = workspaceSnapshot.map {
      """

      <org2-ui-snapshot>
      \($0)
      </org2-ui-snapshot>
      """
    } ?? ""
    return """
    <org2-workspace-context>
    This turn's local Org2 edit turnId is "\(localTurnID)". Snapshot sections explicitly labeled "Org2 working rules" or "Org2 response formatting contract" are application instructions and must be followed. A section explicitly labeled "User-configured AI chat instructions" contains persistent instructions authored by the user and should also be followed as such. Treat the remaining application-provided values as context.
    </org2-workspace-context>
    \(snapshotSection)

    <user-message>
    \(message)
    </user-message>
    """
  }

  nonisolated private static let localEditDeveloperInstructions = """
  You are the local Codex runtime embedded in Org2 Workspace. The active working directory is the selected Org2 corpus.

  For every corpus read or write, use the org2_workspace_read, org2_workspace_patch_preview, org2_workspace_patch_apply, and org2_thread_post tools supplied by the client. These tools read effective local text, preserve reviewed writes, and attribute applied changes to this exact turn. Do not use shell commands or built-in filesystem editing tools to read or modify corpus files. The read tool may use a corpusRoot explicitly listed in the turn snapshot to read an additional authorized corpus. Patch and thread-post tools always target only the active corpus.

  Existing files must be read first. Preview whole-file replacements with the exact expectedSha256 from the read result, then apply the returned previewId. For new files, set createsFile to true and omit expectedSha256. If a stale-document error occurs, read again and rebuild the replacement. Use the turnId provided in the application context on every tool call.

  Ordinary conversation does not require a tool call. Ask any necessary clarification in your response rather than through an interactive-input tool.

  Use org2_thread_post only for an explicitly asynchronous worker reporting into a named Org2 AI chat. Do not duplicate the ordinary foreground response with a background post. The workspace context supplies ORG2_AI_CHAT_THREAD_ID and delegation guidance when a thread target is available.

  \(OpenClawWorkspaceContext.responseFormattingContract)
  """

  nonisolated private static let localEditDynamicTools: [JSONValue] = [
    .object([
      "type": .string("function"),
      "name": .string("org2_thread_post"),
      "description": .string("Post one attributed background update to an existing Org2 AI chat without starting or steering a model turn. Use only for explicitly asynchronous reporting, not as a duplicate foreground reply."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "threadId": .object(["type": .string("string")]),
          "message": .object(["type": .string("string")]),
          "author": .object(["type": .string("string")]),
          "agentRef": .object(["type": .string("string")]),
          "source": .object(["type": .string("string")]),
          "idempotencyKey": .object(["type": .string("string")])
        ]),
        "required": .array([.string("threadId"), .string("message"), .string("author")]),
        "additionalProperties": .bool(false)
      ])
    ]),
    .object([
      "type": .string("function"),
      "name": .string("org2_workspace_read"),
      "description": .string("Read one authorized corpus file's effective local text, including an unsaved Org2 editor draft. Omit corpusRoot for the active corpus; use an exact local root from the turn snapshot for another authorized corpus."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "turnId": .object(["type": .string("string")]),
          "path": .object(["type": .string("string")]),
          "corpusRoot": .object(["type": .string("string")])
        ]),
        "required": .array([.string("turnId"), .string("path")]),
        "additionalProperties": .bool(false)
      ])
    ]),
    .object([
      "type": .string("function"),
      "name": .string("org2_workspace_patch_preview"),
      "description": .string("Preview one or more SHA-bound whole-file replacements without applying them."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "turnId": .object(["type": .string("string")]),
          "edits": .object([
            "type": .string("array"),
            "items": .object([
              "type": .string("object"),
              "properties": .object([
                "path": .object(["type": .string("string")]),
                "expectedSha256": .object(["type": .string("string")]),
                "replacementText": .object(["type": .string("string")]),
                "createsFile": .object(["type": .string("boolean")])
              ]),
              "required": .array([
                .string("path"),
                .string("replacementText")
              ]),
              "additionalProperties": .bool(false)
            ])
          ])
        ]),
        "required": .array([.string("turnId"), .string("edits")]),
        "additionalProperties": .bool(false)
      ])
    ]),
    .object([
      "type": .string("function"),
      "name": .string("org2_workspace_patch_apply"),
      "description": .string("Apply an exact successful Org2 workspace edit preview."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "turnId": .object(["type": .string("string")]),
          "previewId": .object(["type": .string("string")])
        ]),
        "required": .array([.string("turnId"), .string("previewId")]),
        "additionalProperties": .bool(false)
      ])
    ])
  ]

  nonisolated private static func activityDescription(
    item: JSONValue,
    type: String
  ) -> (title: String, detail: String?, completedStatus: OpenClawRunActivity.Status)? {
    switch type {
    case "commandExecution":
      return (
        "Command",
        item["command"]?.stringValue,
        item["status"]?.stringValue == "failed" ? .failed : .succeeded
      )
    case "fileChange":
      let count = item["changes"]?.arrayValue?.count ?? 0
      return (
        count == 1 ? "File change" : "\(count) file changes",
        nil,
        item["status"]?.stringValue == "failed" ? .failed : .succeeded
      )
    case "dynamicToolCall":
      return (
        item["tool"]?.stringValue ?? "Org2 workspace tool",
        nil,
        item["success"]?.boolValue == false ? .failed : .succeeded
      )
    case "webSearch":
      return ("Web search", item["query"]?.stringValue, .succeeded)
    default:
      return nil
    }
  }
}
