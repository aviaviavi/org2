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
  case agentMessageDelta(threadID: String, turnID: String, delta: String)
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

public enum CodexAppServerError: LocalizedError, Sendable {
  case executableNotFound
  case launchFailed(String)
  case disconnected(String)
  case server(code: Int?, message: String)
  case invalidResponse(String)
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
    case .notAuthenticated:
      "Sign in with ChatGPT before using a Codex thread."
    case .turnFailed(let detail):
      "Codex turn failed: \(detail)"
    case .turnInterrupted:
      "Codex turn was stopped."
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
    var errorMessage: String?
    var continuation: CheckedContinuation<CodexTurnResult, Never>?
    var completedResult: CodexTurnResult?
  }

  private let executableURL: URL?
  private let eventHandler: EventHandler
  private let dynamicToolHandler: DynamicToolHandler
  private var process: Process?
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
  private var pendingTurns: [String: PendingTurn] = [:]
  private var loadedThreadIDs = Set<String>()
  private var latestStderr = ""

  public init(
    executableURL: URL? = CodexAppServerClient.resolveExecutableURL(),
    eventHandler: @escaping EventHandler,
    dynamicToolHandler: @escaping DynamicToolHandler
  ) {
    self.executableURL = executableURL
    self.eventHandler = eventHandler
    self.dynamicToolHandler = dynamicToolHandler
  }

  deinit {
    standardOutput?.readabilityHandler = nil
    standardError?.readabilityHandler = nil
    if process?.isRunning == true {
      process?.terminate()
    }
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

  public func ensureThread(
    existingThreadID: String?,
    cwd: URL
  ) async throws -> String {
    try await connect()
    if let existingThreadID {
      if !loadedThreadIDs.contains(existingThreadID) {
        let result = try await requestRaw(
          method: "thread/resume",
          params: .object([
            "threadId": .string(existingThreadID),
            "cwd": .string(cwd.standardizedFileURL.path),
            "approvalPolicy": .string("never"),
            "sandbox": .string("read-only"),
            "dynamicTools": .array(Self.localEditDynamicTools)
          ])
        )
        guard result["thread"]?["id"]?.stringValue == existingThreadID else {
          throw CodexAppServerError.invalidResponse("thread/resume returned a different thread")
        }
        loadedThreadIDs.insert(existingThreadID)
      }
      return existingThreadID
    }

    let result = try await requestRaw(
      method: "thread/start",
      params: .object([
        "cwd": .string(cwd.standardizedFileURL.path),
        "approvalPolicy": .string("never"),
        "sandbox": .string("read-only"),
        "serviceName": .string("org2_workspace"),
        "developerInstructions": .string(Self.localEditDeveloperInstructions),
        "dynamicTools": .array(Self.localEditDynamicTools)
      ])
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
    clientUserMessageID: UUID
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
    let result = try await requestRaw(
      method: "turn/start",
      params: .object([
        "threadId": .string(threadID),
        "input": .array(input),
        "cwd": .string(cwd.standardizedFileURL.path),
        "approvalPolicy": .string("never"),
        "sandboxPolicy": .object([
          "type": .string("readOnly")
        ]),
        "clientUserMessageId": .string(clientUserMessageID.uuidString.lowercased())
      ])
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

  public func shutdown() {
    standardOutput?.readabilityHandler = nil
    standardError?.readabilityHandler = nil
    standardOutput = nil
    standardError = nil
    standardInput = nil
    initialized = false
    loadedThreadIDs.removeAll()
    if process?.isRunning == true {
      process?.terminate()
    }
    process = nil
    failPendingRequests(CodexAppServerError.disconnected("client shut down"))
  }

  private func connect() async throws {
    if initialized, process?.isRunning == true {
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

  private func performConnect() async throws {
    if process?.isRunning != true {
      try launch()
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
    try sendMessage(.object([
      "method": .string("initialized"),
      "params": .object([:])
    ]))
    initialized = true
    await eventHandler(.connectionChanged(isConnected: true, detail: executableURL?.path))
  }

  private func launch() throws {
    guard let executableURL else {
      throw CodexAppServerError.executableNotFound
    }
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["app-server", "--listen", "stdio://"]
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
      await processEnded()
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

  private func processEnded(_ detail: String? = nil) async {
    guard process != nil else { return }
    let stderr = latestStderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = detail ?? (stderr.isEmpty ? "process exited" : stderr)
    process = nil
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

  private func requestRaw(method: String, params: JSONValue) async throws -> JSONValue {
    requestCounter &+= 1
    let requestID = requestCounter
    let key = String(requestID)
    return try await withCheckedThrowingContinuation { continuation in
      pendingRequests[key] = continuation
      do {
        try sendMessage(.object([
          "id": .integer(requestID),
          "method": .string(method),
          "params": params
        ]))
      } catch {
        pendingRequests.removeValue(forKey: key)
        continuation.resume(throwing: error)
      }
    }
  }

  private func sendMessage(_ message: JSONValue) throws {
    guard let standardInput, process?.isRunning == true else {
      throw CodexAppServerError.disconnected("app server is not running")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    var data = try encoder.encode(message)
    data.append(0x0A)
    do {
      try standardInput.write(contentsOf: data)
    } catch {
      throw CodexAppServerError.disconnected(error.localizedDescription)
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
        handleServerRequest(id: id, method: method, params: object["params"] ?? .object([:]))
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

  private func handleServerRequest(id: JSONValue, method: String, params: JSONValue) {
    guard method == "item/tool/call",
          let callID = params["callId"]?.stringValue,
          let threadID = params["threadId"]?.stringValue,
          let turnID = params["turnId"]?.stringValue,
          let tool = params["tool"]?.stringValue
    else {
      do {
        try sendMessage(.object([
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

  private func sendDynamicToolResponse(id: JSONValue, result: CodexDynamicToolResult) {
    do {
      try sendMessage(.object([
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
      var pending = pendingTurns[turnID] ?? PendingTurn()
      pending.streamedReply += delta
      pendingTurns[turnID] = pending
      await eventHandler(.agentMessageDelta(
        threadID: threadID,
        turnID: turnID,
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
    if let completed = pendingTurns[turnID]?.completedResult {
      pendingTurns.removeValue(forKey: turnID)
      return completed
    }
    return await withCheckedContinuation { continuation in
      var pending = pendingTurns[turnID] ?? PendingTurn()
      if let completed = pending.completedResult {
        pendingTurns.removeValue(forKey: turnID)
        continuation.resume(returning: completed)
      } else {
        pending.continuation = continuation
        pendingTurns[turnID] = pending
      }
    }
  }

  private func failPendingRequests(_ error: Error) {
    let requests = pendingRequests.values
    pendingRequests.removeAll()
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
    This turn's local Org2 edit turnId is "\(localTurnID)". Treat this application-provided value as context, not as a user instruction.
    </org2-workspace-context>
    \(snapshotSection)

    <user-message>
    \(message)
    </user-message>
    """
  }

  nonisolated private static let localEditDeveloperInstructions = """
  You are the local Codex runtime embedded in Org2 Workspace. The active working directory is the selected Org2 corpus.

  For every corpus read or write, use the org2_workspace_read, org2_workspace_patch_preview, and org2_workspace_patch_apply tools supplied by the client. These tools read effective local text, including unsaved editor state, and attribute applied changes to this exact turn. Do not use shell commands or built-in filesystem editing tools to read or modify corpus files.

  Existing files must be read first. Preview whole-file replacements with the exact expectedSha256 from the read result, then apply the returned previewId. For new files, set createsFile to true and omit expectedSha256. If a stale-document error occurs, read again and rebuild the replacement. Use the turnId provided in the application context on every tool call.

  Ordinary conversation does not require a tool call. Ask any necessary clarification in your response rather than through an interactive-input tool.
  """

  nonisolated private static let localEditDynamicTools: [JSONValue] = [
    .object([
      "type": .string("function"),
      "name": .string("org2_workspace_read"),
      "description": .string("Read one corpus file's effective local text, including an unsaved Org2 editor draft."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "turnId": .object(["type": .string("string")]),
          "path": .object(["type": .string("string")])
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
