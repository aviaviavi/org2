import Foundation

public enum PiAgentError: LocalizedError, Sendable {
  case executableNotFound
  case invalidSSHHost
  case missingRemoteWorkspace
  case launchFailed(String)
  case invalidResponse(String)
  case turnFailed(String)
  case interrupted

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      "Pi was not found. Install `@earendil-works/pi-coding-agent`, then sign in with `/login`."
    case .invalidSSHHost:
      "Remote Pi needs a valid SSH host or ~/.ssh/config alias."
    case .missingRemoteWorkspace:
      "Remote Pi needs the Org2 corpus path on that machine."
    case .launchFailed(let detail):
      "Could not start Pi: \(detail)"
    case .invalidResponse(let detail):
      "Pi returned an invalid response: \(detail)"
    case .turnFailed(let detail):
      "Pi turn failed: \(detail)"
    case .interrupted:
      "Pi was stopped."
    }
  }
}

public enum PiAgentTransport: Equatable, Sendable {
  case local
  case managedRemote(sshHost: String, workspacePath: String)
}

public enum PiAgentEvent: Sendable {
  case sessionStarted(sessionID: String)
  case textDelta(String)
  case activity(id: String, title: String, status: OpenClawRunActivity.Status)
  case warning(String)
}

public struct PiAgentTurnResult: Equatable, Sendable {
  public let sessionID: String
  public let reply: String

  public init(sessionID: String, reply: String) {
    self.sessionID = sessionID
    self.reply = reply
  }
}

struct PiAgentStreamResult: Equatable, Sendable {
  var sessionID: String?
  var reply = ""
  var errors: [String] = []
  var succeeded = false
}

struct PiAgentStreamDecoder: Sendable {
  private(set) var result = PiAgentStreamResult()

  mutating func consume(
    _ line: String,
    eventHandler: @Sendable (PiAgentEvent) async -> Void
  ) async {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = object["type"] as? String
    else { return }

    if type == "session",
       let sessionID = object["id"] as? String,
       !sessionID.isEmpty {
      if result.sessionID == nil {
        await eventHandler(.sessionStarted(sessionID: sessionID))
      }
      result.sessionID = sessionID
      return
    }

    switch type {
    case "message_update":
      guard let event = object["assistantMessageEvent"] as? [String: Any],
            event["type"] as? String == "text_delta",
            let delta = event["delta"] as? String,
            !delta.isEmpty
      else { return }
      await eventHandler(.textDelta(delta))
    case "message_end":
      guard let message = object["message"] as? [String: Any],
            message["role"] as? String == "assistant"
      else { return }
      let text = Self.textContent(message["content"])
      if !text.isEmpty { result.reply = text }
      let stopReason = message["stopReason"] as? String
      if stopReason == "error" || stopReason == "aborted" {
        let detail = (message["errorMessage"] as? String)
          ?? (message["error"] as? String)
          ?? "Pi ended the response with \(stopReason ?? "an error")."
        result.errors.append(detail)
      } else {
        result.succeeded = true
      }
    case "tool_execution_start":
      let id = object["toolCallId"] as? String ?? UUID().uuidString.lowercased()
      let tool = object["toolName"] as? String ?? "tool"
      await eventHandler(.activity(
        id: id,
        title: Self.activityTitle(for: tool),
        status: .running
      ))
    case "tool_execution_end":
      let id = object["toolCallId"] as? String ?? UUID().uuidString.lowercased()
      let tool = object["toolName"] as? String ?? "tool"
      let status: OpenClawRunActivity.Status = object["isError"] as? Bool == true
        ? .failed : .succeeded
      await eventHandler(.activity(id: id, title: Self.activityTitle(for: tool), status: status))
    case "auto_retry_start":
      if let message = object["errorMessage"] as? String, !message.isEmpty {
        await eventHandler(.warning("Pi is retrying: \(message)"))
      }
    case "auto_retry_end":
      if object["success"] as? Bool == false,
         let message = object["finalError"] as? String,
         !message.isEmpty {
        result.errors.append(message)
      }
    case "agent_settled":
      if result.errors.isEmpty { result.succeeded = true }
    default:
      break
    }
  }

  private nonisolated static func textContent(_ value: Any?) -> String {
    if let text = value as? String { return text }
    guard let blocks = value as? [[String: Any]] else { return "" }
    return blocks.compactMap { block -> String? in
      guard block["type"] as? String == "text" else { return nil }
      return block["text"] as? String
    }.joined()
  }

  private nonisolated static func activityTitle(for tool: String) -> String {
    switch tool.lowercased() {
    case "read": "Reading"
    case "grep", "find", "ls": "Searching"
    case "edit", "write": "Editing"
    case "bash": "Running command"
    default: "Using \(tool)"
    }
  }
}

public actor PiAgentClient {
  public typealias EventHandler = @Sendable (UUID, PiAgentEvent) async -> Void

  private let transport: PiAgentTransport
  private let executableURL: URL?
  private let environment: [String: String]
  private let eventHandler: EventHandler
  private var activeProcesses: [UUID: Process] = [:]

  public init(
    transport: PiAgentTransport = .local,
    executableURL: URL? = PiAgentClient.resolveExecutableURL(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    eventHandler: @escaping EventHandler
  ) {
    self.transport = transport
    self.executableURL = executableURL
    self.environment = environment
    self.eventHandler = eventHandler
  }

  nonisolated public static func resolveExecutableURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    var candidates: [String] = []
    if let configured = environment["ORG2_PI_EXECUTABLE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
       !configured.isEmpty {
      candidates.append(configured)
    }
    let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    candidates.append(contentsOf: [
      URL(fileURLWithPath: home).appendingPathComponent(".local/bin/pi").path,
      "/opt/homebrew/bin/pi",
      "/usr/local/bin/pi"
    ])
    if let path = environment["PATH"] {
      candidates.append(contentsOf: path.split(separator: ":").map {
        URL(fileURLWithPath: String($0)).appendingPathComponent("pi").path
      })
    }
    return candidates.lazy
      .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
      .first {
        fileManager.isExecutableFile(atPath: $0.path)
          && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != false
      }
  }

  nonisolated static func arguments(
    sessionID: String?,
    model: String?,
    reasoningEffort: String?,
    sandboxAccess: CodexSandboxAccess,
    systemPromptPath: String,
    attachmentPaths: [String],
    message: String
  ) -> [String] {
    var arguments = [
      "--mode", "json",
      "--append-system-prompt", systemPromptPath,
      "--tools", tools(for: sandboxAccess)
    ]
    if let sessionID = normalized(sessionID) {
      arguments.append(contentsOf: ["--session", sessionID])
    }
    if let model = normalized(model) {
      arguments.append(contentsOf: ["--model", model])
    }
    if let reasoningEffort = normalized(reasoningEffort),
       ["off", "minimal", "low", "medium", "high", "xhigh"].contains(reasoningEffort) {
      arguments.append(contentsOf: ["--thinking", reasoningEffort])
    }
    arguments.append(contentsOf: attachmentPaths.map { "@\($0)" })
    arguments.append(message)
    return arguments
  }

  nonisolated static func tools(for sandboxAccess: CodexSandboxAccess) -> String {
    switch sandboxAccess {
    case .readOnly:
      "read,grep,find,ls"
    case .workspaceWrite, .fullAccess:
      "read,bash,edit,write,grep,find,ls"
    }
  }

  nonisolated static func validatedSSHHost(_ rawSSHHost: String) throws -> String {
    let sshHost = rawSSHHost.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_@:%[]+"))
    guard !sshHost.isEmpty,
          !sshHost.hasPrefix("-"),
          sshHost.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else { throw PiAgentError.invalidSSHHost }
    return sshHost
  }

  nonisolated static func managedRemoteSSHArguments(sshHost: String) throws -> [String] {
    [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=15",
      "-o", "ServerAliveInterval=15",
      "-o", "ServerAliveCountMax=12",
      try validatedSSHHost(sshHost),
      managedRemoteCommand()
    ]
  }

  private nonisolated static func managedRemoteCommand() -> String {
    let script = Data(managedRemotePythonBootstrap.utf8).base64EncodedString()
    return #"exec /bin/sh -lc 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; command -v python3 >/dev/null 2>&1 || { echo "Remote Pi requires python3." >&2; exit 127; }; exec python3 -c "import base64;exec(compile(base64.b64decode(\"\#(script)\"),\"<openorg-pi-adapter>\",\"exec\"))"'"#
  }

  nonisolated static let managedRemotePythonBootstrap = #"""
import base64
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile

payload = json.load(sys.stdin)
workspace = os.path.expanduser(payload["workspacePath"])
if not os.path.isabs(workspace) or not os.path.isdir(workspace):
    sys.stderr.write("Remote Pi workspace does not exist: %s\n" % workspace)
    sys.exit(66)

pi = shutil.which("pi")
if not pi:
    sys.stderr.write("Pi was not found on the remote PATH.\n")
    sys.exit(127)

temporary_root = tempfile.mkdtemp(prefix="openorg-pi-")
try:
    system_prompt_path = os.path.join(temporary_root, "openorg-context.txt")
    with open(system_prompt_path, "w", encoding="utf-8") as handle:
        handle.write(payload["systemPrompt"])
    os.chmod(system_prompt_path, 0o600)

    attachment_paths = []
    for index, attachment in enumerate(payload.get("attachments", [])):
        raw_name = os.path.basename(attachment.get("fileName") or ("attachment-%d" % (index + 1)))
        safe_name = raw_name.replace("/", "-")
        if safe_name in ("", ".", ".."):
            safe_name = "attachment-%d" % (index + 1)
        path = os.path.join(temporary_root, safe_name)
        with open(path, "wb") as handle:
            handle.write(base64.b64decode(attachment["data"]))
        os.chmod(path, 0o600)
        attachment_paths.append(path)

    arguments = []
    for value in payload["arguments"]:
        if value == "__OPENORG_SYSTEM_PROMPT__":
            arguments.append(system_prompt_path)
        else:
            arguments.append(value)
    arguments.extend("@" + path for path in attachment_paths)
    arguments.append(payload["message"])

    process = subprocess.Popen([pi] + arguments, cwd=workspace)
    def forward(signum, _frame):
        if process.poll() is None:
            process.send_signal(signum)
    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    sys.exit(process.wait())
finally:
    shutil.rmtree(temporary_root, ignore_errors=True)
"""#

  public func runTurn(
    openOrgThreadID: UUID,
    existingSessionID: String?,
    message: String,
    systemPrompt: String,
    attachments: [OpenClawChatAttachment],
    cwd: URL,
    model: String?,
    reasoningEffort: String?,
    sandboxAccess: CodexSandboxAccess
  ) async throws -> PiAgentTurnResult {
    if let existing = activeProcesses[openOrgThreadID], existing.isRunning {
      throw PiAgentError.launchFailed("another turn is already running in this chat")
    }

    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let temporaryRoot: URL?
    var inputData: Data?

    switch transport {
    case .local:
      guard let executableURL else { throw PiAgentError.executableNotFound }
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("openorg-pi-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      temporaryRoot = root
      let systemPromptURL = root.appendingPathComponent("openorg-context.txt")
      try systemPrompt.write(to: systemPromptURL, atomically: true, encoding: .utf8)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: systemPromptURL.path)
      let attachmentURLs = try Self.materializeAttachments(attachments, under: root)
      process.executableURL = executableURL
      process.arguments = Self.arguments(
        sessionID: existingSessionID,
        model: model,
        reasoningEffort: reasoningEffort,
        sandboxAccess: sandboxAccess,
        systemPromptPath: systemPromptURL.path,
        attachmentPaths: attachmentURLs.map(\.path),
        message: message
      )
      process.currentDirectoryURL = cwd.standardizedFileURL
      process.environment = environment
      inputData = nil
    case .managedRemote(let sshHost, let workspacePath):
      temporaryRoot = nil
      let workspacePath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !workspacePath.isEmpty else { throw PiAgentError.missingRemoteWorkspace }
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
      process.arguments = try Self.managedRemoteSSHArguments(sshHost: sshHost)
      let remoteArguments = Self.arguments(
        sessionID: existingSessionID,
        model: model,
        reasoningEffort: reasoningEffort,
        sandboxAccess: sandboxAccess,
        systemPromptPath: "__OPENORG_SYSTEM_PROMPT__",
        attachmentPaths: [],
        message: ""
      )
      let payload = PiRemotePayload(
        workspacePath: workspacePath,
        arguments: Array(remoteArguments.dropLast()),
        message: message,
        systemPrompt: systemPrompt,
        attachments: try attachments.map {
          PiRemoteAttachment(fileName: $0.fileName, data: try $0.loadData().base64EncodedString())
        }
      )
      inputData = try JSONEncoder().encode(payload)
      process.environment = environment
    }

    defer {
      if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.standardInput = standardInput

    do {
      try process.run()
      activeProcesses[openOrgThreadID] = process
      if let inputData {
        try standardInput.fileHandleForWriting.write(contentsOf: inputData)
      }
      try standardInput.fileHandleForWriting.close()
    } catch {
      if process.isRunning { process.terminate() }
      activeProcesses.removeValue(forKey: openOrgThreadID)
      throw PiAgentError.launchFailed(error.localizedDescription)
    }

    let handler = eventHandler
    let outputTask = Task.detached(priority: .userInitiated) {
      try await Self.consumeOutput(
        standardOutput.fileHandleForReading,
        openOrgThreadID: openOrgThreadID,
        eventHandler: handler
      )
    }
    let errorTask = Task.detached(priority: .utility) {
      String(decoding: try standardError.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
    }
    let status: Int32 = await withTaskCancellationHandler {
      await Task.detached(priority: .userInitiated) {
        process.waitUntilExit()
        return process.terminationStatus
      }.value
    } onCancel: {
      Task { await self.interrupt(openOrgThreadID: openOrgThreadID) }
    }
    let decoded: PiAgentStreamResult
    do {
      decoded = try await outputTask.value
    } catch {
      activeProcesses.removeValue(forKey: openOrgThreadID)
      throw PiAgentError.invalidResponse(error.localizedDescription)
    }
    let stderr = (try? await errorTask.value)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    activeProcesses.removeValue(forKey: openOrgThreadID)

    if Task.isCancelled || process.terminationReason == .uncaughtSignal {
      throw PiAgentError.interrupted
    }
    guard status == 0, decoded.succeeded, decoded.errors.isEmpty else {
      let detail = decoded.errors.joined(separator: "\n")
      throw PiAgentError.turnFailed(
        [detail, stderr].first(where: { !$0.isEmpty }) ?? "Pi exited with status \(status)."
      )
    }
    guard let sessionID = decoded.sessionID, !sessionID.isEmpty else {
      throw PiAgentError.invalidResponse("the response did not include a session ID")
    }
    return PiAgentTurnResult(sessionID: sessionID, reply: decoded.reply)
  }

  public func interrupt(openOrgThreadID: UUID) {
    guard let process = activeProcesses[openOrgThreadID], process.isRunning else { return }
    process.interrupt()
  }

  public func shutdown() {
    for process in activeProcesses.values where process.isRunning { process.terminate() }
    activeProcesses.removeAll()
  }

  private nonisolated static func consumeOutput(
    _ handle: FileHandle,
    openOrgThreadID: UUID,
    eventHandler: @escaping EventHandler
  ) async throws -> PiAgentStreamResult {
    var decoder = PiAgentStreamDecoder()
    var buffer = Data()
    while let chunk = try handle.read(upToCount: 16_384), !chunk.isEmpty {
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer[..<newline]
        buffer.removeSubrange(...newline)
        await decoder.consume(String(decoding: lineData, as: UTF8.self)) { event in
          await eventHandler(openOrgThreadID, event)
        }
      }
    }
    if !buffer.isEmpty {
      await decoder.consume(String(decoding: buffer, as: UTF8.self)) { event in
        await eventHandler(openOrgThreadID, event)
      }
    }
    return decoder.result
  }

  private nonisolated static func materializeAttachments(
    _ attachments: [OpenClawChatAttachment],
    under temporaryRoot: URL
  ) throws -> [URL] {
    var usedNames = Set<String>()
    return try attachments.enumerated().map { index, attachment in
      let rawName = attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
      let safeName = URL(fileURLWithPath: rawName.isEmpty ? "attachment-\(index + 1)" : rawName)
        .lastPathComponent
      var uniqueName = ["", ".", ".."].contains(safeName)
        ? "attachment-\(index + 1)"
        : safeName
      var suffix = 2
      while usedNames.contains(uniqueName.lowercased()) {
        let base = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        uniqueName = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
        suffix += 1
      }
      usedNames.insert(uniqueName.lowercased())
      let url = temporaryRoot.appendingPathComponent(uniqueName)
      try attachment.loadData().write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return url
    }
  }

  private nonisolated static func normalized(_ value: String?) -> String? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }
}

private struct PiRemotePayload: Encodable {
  let workspacePath: String
  let arguments: [String]
  let message: String
  let systemPrompt: String
  let attachments: [PiRemoteAttachment]
}

private struct PiRemoteAttachment: Encodable {
  let fileName: String
  let data: String
}
