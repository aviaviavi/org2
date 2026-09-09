import Foundation

public struct BundledAgentError: LocalizedError, Sendable {
  public let message: String
  public var errorDescription: String? { message }
}

/// One disposable child per foreground turn. The app retains conversation and
/// edit state; credentials travel only over the child's private stdin pipe.
public struct BundledAgentClient: Sendable {
  let cli: Org2CLI

  public init(cli: Org2CLI) { self.cli = cli }

  public func send(
    settings: AIProviderChatSettings,
    model: String,
    messages: [OpenClawChatMessage],
    system: String,
    tools: [JSONValue],
    onEvent: @escaping @Sendable (JSONValue) async -> Void,
    execute: @escaping @Sendable (String, JSONValue) async throws -> CodexDynamicToolResult
  ) async throws -> String {
    guard messages.allSatisfy({ $0.attachments.isEmpty }) else {
      throw BundledAgentError(message: "The bundled agent prototype supports text only. Disable workspace tools to discuss attachments.")
    }
    guard let node = cli.runtimeNodePath else {
      throw BundledAgentError(message: "The bundled Node runtime could not be found.")
    }
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = [cli.repoRoot.appendingPathComponent("dist/bundled-agent.js").path]
    process.currentDirectoryURL = cli.repoRoot
    // Do not inherit API keys, Node injection options, or unrelated app secrets.
    process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let history: [JSONValue] = messages.suffix(30).map { message in
      let content = message.role == .assistant && message.authorLabel != nil
        ? "[\(message.authorLabel!)]\n\(message.content)" : message.content
      return .object([
        "role": .string(message.role == .assistant ? "assistant" : "user"),
        "content": .string(content)
      ])
    }
    let request: JSONValue = .object([
      "type": .string("start"),
      "protocol": .string("openorg:bundled-agent:v1"),
      "request": .object([
        "adapter": .string(settings.adapter.rawValue),
        "endpoint": .string(settings.baseURL.absoluteString),
        "apiKey": settings.apiKey.map(JSONValue.string) ?? .null,
        "model": .string(model),
        "system": .string(system),
        "messages": .array(history),
        "tools": .array(tools)
      ])
    ])
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      try process.run()
      defer {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
      }
      try Self.write(request, to: input.fileHandleForWriting)
      var buffer = Data()
      var reply: String?
      while true {
        try Task.checkCancellation()
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        guard buffer.count <= 8 * 1024 * 1024 else {
          throw BundledAgentError(message: "Bundled agent output exceeded its limit.")
        }
        while let newline = buffer.firstIndex(of: 10) {
          let line = Data(buffer[..<newline])
          buffer.removeSubrange(...newline)
          let event = try JSONDecoder().decode(JSONValue.self, from: line)
          try Task.checkCancellation()
          switch event["type"]?.stringValue {
          case "tool":
            guard let id = event["id"]?.stringValue,
                  let name = event["name"]?.stringValue,
                  let arguments = event["arguments"], arguments.objectValue != nil else {
              throw BundledAgentError(message: "Invalid bundled agent tool request.")
            }
            await onEvent(event)
            let result = try await execute(name, arguments)
            try Task.checkCancellation()
            try Self.write(.object([
              "type": .string("toolResult"), "id": .string(id),
              "result": .object(["success": .bool(result.success), "text": .string(result.text)])
            ]), to: input.fileHandleForWriting)
          case "status", "text":
            await onEvent(event)
          case "done":
            reply = event["reply"]?.stringValue
          case "error":
            throw BundledAgentError(message: event["message"]?.stringValue ?? "The bundled agent failed.")
          default:
            throw BundledAgentError(message: "Unexpected bundled agent event.")
          }
        }
      }
      process.waitUntilExit()
      try Task.checkCancellation()
      guard process.terminationStatus == 0, buffer.isEmpty, let reply, !reply.isEmpty else {
        throw BundledAgentError(message: "The bundled agent stopped before completing its reply.")
      }
      return reply
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
      if process.isRunning { process.terminate() }
    }
  }

  private static func write(_ frame: JSONValue, to handle: FileHandle) throws {
    var data = try JSONEncoder().encode(frame)
    guard data.count <= 8 * 1024 * 1024 else {
      throw BundledAgentError(message: "Bundled agent input exceeded its limit.")
    }
    data.append(10)
    try handle.write(contentsOf: data)
  }
}
