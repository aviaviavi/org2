import Foundation

public enum OpenCodeError: LocalizedError, Sendable {
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
      "OpenCode was not found. Install `@opencode/cli`, then connect a provider."
    case .invalidSSHHost:
      "Remote OpenCode needs a valid SSH host or ~/.ssh/config alias."
    case .missingRemoteWorkspace:
      "Remote OpenCode needs the Org2 corpus path on that machine."
    case .launchFailed(let detail):
      "Could not start OpenCode: \(detail)"
    case .invalidResponse(let detail):
      "OpenCode returned an invalid response: \(detail)"
    case .turnFailed(let detail):
      "OpenCode turn failed: \(detail)"
    case .interrupted:
      "OpenCode was stopped."
    }
  }
}

public enum OpenCodeTransport: Equatable, Sendable {
  case local
  case managedRemote(sshHost: String, workspacePath: String)
}

public enum OpenCodeEvent: Sendable {
  /// The OpenCode process launched; the first JSON event can take a few
  /// seconds while its private server loads config, providers, and MCP servers.
  case processStarted
  case sessionStarted(sessionID: String)
  case reasoning(id: String, text: String)
  case textDelta(String)
  case activity(id: String, title: String, status: OpenClawRunActivity.Status)
  case warning(String)
}

public struct OpenCodeTurnResult: Equatable, Sendable {
  public let sessionID: String
  public let reply: String

  public init(sessionID: String, reply: String) {
    self.sessionID = sessionID
    self.reply = reply
  }
}

struct OpenCodeStreamResult: Equatable, Sendable {
  var sessionID: String?
  var reply = ""
  var errors: [String] = []
  var succeeded = false
}

struct OpenCodeStreamDecoder: Sendable {
  private(set) var result = OpenCodeStreamResult()

  mutating func consume(
    _ line: String,
    eventHandler: @Sendable (OpenCodeEvent) async -> Void
  ) async {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = object["type"] as? String
    else { return }

    if let sessionID = object["sessionID"] as? String, !sessionID.isEmpty {
      if result.sessionID == nil {
        await eventHandler(.sessionStarted(sessionID: sessionID))
      }
      result.sessionID = sessionID
    }

    switch type {
    case "text":
      guard let part = object["part"] as? [String: Any],
            let text = part["text"] as? String,
            !text.isEmpty
      else { return }
      result.reply += text
      result.succeeded = true
      await eventHandler(.textDelta(text))
    case "reasoning":
      guard let part = object["part"] as? [String: Any],
            let text = (part["text"] as? String)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
      else { return }
      let id = (part["id"] as? String) ?? UUID().uuidString.lowercased()
      await eventHandler(.reasoning(id: id, text: text))
    case "tool_use":
      guard let part = object["part"] as? [String: Any] else { return }
      let id = (part["id"] as? String)
        ?? (part["partID"] as? String)
        ?? UUID().uuidString.lowercased()
      let tool = part["tool"] as? String ?? "tool"
      let state = part["state"] as? [String: Any]
      let status: OpenClawRunActivity.Status
      switch state?["status"] as? String {
      case "completed": status = .succeeded
      case "error", "failed": status = .failed
      default: status = .running
      }
      await eventHandler(.activity(id: id, title: Self.activityTitle(for: tool), status: status))
    case "step_finish":
      if let part = object["part"] as? [String: Any],
         let reason = part["reason"] as? String,
         reason == "error" {
        result.errors.append("OpenCode ended the step with an error.")
      }
    case "error":
      let nestedError = object["error"] as? [String: Any]
      let detail = (object["message"] as? String)
        ?? (nestedError?["message"] as? String)
        ?? (object["error"] as? String)
        ?? "OpenCode reported an error."
      result.errors.append(detail)
      await eventHandler(.warning(detail))
    default:
      break
    }
  }

  private nonisolated static func activityTitle(for tool: String) -> String {
    switch tool.lowercased() {
    case "read": "Reading"
    case "glob", "grep", "list", "ls": "Searching"
    case "edit", "write", "patch": "Editing"
    case "bash", "shell": "Running command"
    case "webfetch", "websearch": "Browsing"
    case "task", "subagent": "Delegating"
    default: "Using \(tool)"
    }
  }
}

public actor OpenCodeClient {
  public typealias EventHandler = @Sendable (UUID, OpenCodeEvent) async -> Void

  private let transport: OpenCodeTransport
  private let executableURL: URL?
  private let environment: [String: String]
  private let eventHandler: EventHandler
  private struct ActiveRun {
    let process: Process
    let serverProcess: Process?
    let serverURL: String
    let serverPassword: String
  }

  private var activeRuns: [UUID: ActiveRun] = [:]

  public init(
    transport: OpenCodeTransport = .local,
    executableURL: URL? = OpenCodeClient.resolveExecutableURL(),
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
    if let configured = environment["ORG2_OPENCODE_EXECUTABLE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
       !configured.isEmpty {
      candidates.append(configured)
    }
    let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    candidates.append(contentsOf: [
      URL(fileURLWithPath: home).appendingPathComponent(".local/bin/opencode").path,
      "/opt/homebrew/bin/opencode",
      "/usr/local/bin/opencode"
    ])
    if let path = environment["PATH"] {
      candidates.append(contentsOf: path.split(separator: ":").map {
        URL(fileURLWithPath: String($0)).appendingPathComponent("opencode").path
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
    attachmentPaths: [String],
    message: String
  ) -> [String] {
    var arguments = ["run", "--format", "json", "--thinking", "--agent", "openorg", "--auto"]
    if let sessionID = normalized(sessionID) {
      arguments.append(contentsOf: ["--session", sessionID])
    }
    if let model = normalized(model) {
      let effort = normalized(reasoningEffort)
      let selected = effort.map { model.contains("#") ? model : "\(model)#\($0)" } ?? model
      arguments.append(contentsOf: ["--model", selected])
    }
    for path in attachmentPaths {
      arguments.append(contentsOf: ["--file", path])
    }
    arguments.append(message)
    return arguments
  }

  nonisolated static func inlineConfiguration(
    systemPrompt: String,
    sandboxAccess: CodexSandboxAccess
  ) throws -> String {
    var permissions: [String: String] = [:]
    switch sandboxAccess {
    case .readOnly:
      permissions = [
        "edit": "deny",
        "bash": "deny",
        "external_directory": "deny"
      ]
    case .workspaceWrite:
      permissions = [
        "edit": "allow",
        "bash": "allow",
        "external_directory": "deny"
      ]
    case .fullAccess:
      permissions = [
        "edit": "allow",
        "bash": "allow",
        "external_directory": "allow"
      ]
    }
    let configuration: [String: Any] = [
      "$schema": "https://opencode.ai/config.json",
      "agent": [
        "openorg": [
          "description": "OpenOrg workspace agent",
          "mode": "primary",
          "prompt": systemPrompt,
          "permission": permissions
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: configuration, options: [])
    return String(decoding: data, as: UTF8.self)
  }

  nonisolated static func validatedSSHHost(_ rawSSHHost: String) throws -> String {
    let sshHost = rawSSHHost.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_@:%[]+"))
    guard !sshHost.isEmpty,
          !sshHost.hasPrefix("-"),
          sshHost.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else { throw OpenCodeError.invalidSSHHost }
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

  nonisolated static func managedRemoteModelSSHArguments(sshHost: String) throws -> [String] {
    [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=15",
      try validatedSSHHost(sshHost),
      managedRemoteModelCommand()
    ]
  }

  nonisolated static func managedRemoteSteerSSHArguments(sshHost: String) throws -> [String] {
    [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=15",
      try validatedSSHHost(sshHost),
      managedRemoteSteerCommand()
    ]
  }

  private nonisolated static func managedRemoteCommand() -> String {
    let script = Data(managedRemotePythonBootstrap.utf8).base64EncodedString()
    return #"exec /bin/sh -lc 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; command -v python3 >/dev/null 2>&1 || { echo "Remote OpenCode requires python3." >&2; exit 127; }; exec python3 -c "import base64;exec(compile(base64.b64decode(\"\#(script)\"),\"<openorg-opencode-adapter>\",\"exec\"))"'"#
  }

  private nonisolated static func managedRemoteModelCommand() -> String {
    let script = Data(managedRemoteModelPythonBootstrap.utf8).base64EncodedString()
    return #"exec /bin/sh -lc 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; command -v python3 >/dev/null 2>&1 || { echo "Remote OpenCode requires python3." >&2; exit 127; }; exec python3 -c "import base64;exec(compile(base64.b64decode(\"\#(script)\"),\"<openorg-opencode-models>\",\"exec\"))"'"#
  }

  private nonisolated static func managedRemoteSteerCommand() -> String {
    let script = Data(managedRemoteSteerPythonBootstrap.utf8).base64EncodedString()
    return #"exec /bin/sh -lc 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; command -v python3 >/dev/null 2>&1 || { echo "Remote OpenCode requires python3." >&2; exit 127; }; exec python3 -c "import base64;exec(compile(base64.b64decode(\"\#(script)\"),\"<openorg-opencode-steer>\",\"exec\"))"'"#
  }

  nonisolated static let managedRemoteModelPythonBootstrap = #"""
import json
import os
import shutil
import subprocess
import sys

payload = json.load(sys.stdin)
workspace = os.path.expanduser(payload["workspacePath"])
if not os.path.isabs(workspace) or not os.path.isdir(workspace):
    sys.stderr.write("Remote OpenCode workspace does not exist: %s\n" % workspace)
    sys.exit(66)

opencode = shutil.which("opencode")
if not opencode:
    sys.stderr.write("OpenCode was not found on the remote PATH.\n")
    sys.exit(127)

def models():
    return subprocess.run([opencode, "models"], cwd=workspace, capture_output=True, text=True)

result = models()
if result.returncode == 0 and not result.stdout.strip():
    subprocess.run([opencode, "reload"], cwd=workspace, capture_output=True, text=True)
    result = models()

sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
"""#

  nonisolated static let managedRemotePythonBootstrap = #"""
import base64
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading

payload = json.load(sys.stdin)
workspace = os.path.expanduser(payload["workspacePath"])
if not os.path.isabs(workspace) or not os.path.isdir(workspace):
    sys.stderr.write("Remote OpenCode workspace does not exist: %s\n" % workspace)
    sys.exit(66)

opencode = shutil.which("opencode")
if not opencode:
    sys.stderr.write("OpenCode was not found on the remote PATH.\n")
    sys.exit(127)

temporary_root = tempfile.mkdtemp(prefix="openorg-opencode-")
try:
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

    arguments = list(payload["arguments"])
    for path in attachment_paths:
        arguments.extend(["--file", path])
    arguments.append(payload["message"])
    environment = os.environ.copy()
    environment["OPENCODE_CONFIG_CONTENT"] = payload["configuration"]
    environment["OPENCODE_SERVER_PASSWORD"] = payload["serverPassword"]

    server = subprocess.Popen(
        [opencode, "serve", "--hostname", "127.0.0.1", "--port", "0"],
        cwd=workspace,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    server_line = server.stdout.readline().strip()
    server_prefix = "server listening on "
    if not server_line.startswith(server_prefix):
        detail = server.stderr.readline().strip()
        raise RuntimeError(detail or server_line or "OpenCode private server did not start")
    server_url = server_line[len(server_prefix):]
    threading.Thread(target=server.stderr.read, daemon=True).start()
    sys.stdout.write(json.dumps({"type": "openorg_server", "url": server_url}) + "\n")
    sys.stdout.flush()

    arguments[1:1] = ["--server", server_url]
    process = subprocess.Popen([opencode] + arguments, cwd=workspace, env=environment)
    def forward(signum, _frame):
        if process.poll() is None:
            process.send_signal(signum)
    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    sys.exit(process.wait())
finally:
    if "server" in locals() and server.poll() is None:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
    shutil.rmtree(temporary_root, ignore_errors=True)
"""#

  nonisolated static let managedRemoteSteerPythonBootstrap = #"""
import json
import os
import shutil
import subprocess
import sys

payload = json.load(sys.stdin)
opencode = shutil.which("opencode")
if not opencode:
    sys.stderr.write("OpenCode was not found on the remote PATH.\n")
    sys.exit(127)

environment = os.environ.copy()
environment["OPENCODE_SERVER_PASSWORD"] = payload["serverPassword"]
result = subprocess.run(
    [
        opencode,
        "api",
        "--server",
        payload["serverURL"],
        "session.prompt",
        "--param",
        "sessionID=" + payload["sessionID"],
        "--data",
        payload["requestData"],
    ],
    capture_output=True,
    env=environment,
    text=True,
)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
"""#

  public func listModels(
    cwd: URL,
    configuredModel: String? = nil
  ) async throws -> [AIChatModelOption] {
    let output: String
    switch transport {
    case .local:
      guard let executableURL else { throw OpenCodeError.executableNotFound }
      var result = try await Self.runCommand(
        executableURL: executableURL,
        arguments: ["models"],
        cwd: cwd.standardizedFileURL,
        environment: environment
      )
      if Self.modelIDs(from: result.output).isEmpty {
        _ = try? await Self.runCommand(
          executableURL: executableURL,
          arguments: ["reload"],
          cwd: cwd.standardizedFileURL,
          environment: environment
        )
        result = try await Self.runCommand(
          executableURL: executableURL,
          arguments: ["models"],
          cwd: cwd.standardizedFileURL,
          environment: environment
        )
      }
      output = result.output
    case .managedRemote(let sshHost, let workspacePath):
      let workspacePath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !workspacePath.isEmpty else { throw OpenCodeError.missingRemoteWorkspace }
      let input = try JSONEncoder().encode(OpenCodeRemoteModelPayload(workspacePath: workspacePath))
      let result = try await Self.runCommand(
        executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
        arguments: try Self.managedRemoteModelSSHArguments(sshHost: sshHost),
        cwd: nil,
        environment: environment,
        input: input
      )
      output = result.output
    }

    var ids = Self.modelIDs(from: output)
    if let configuredModel = Self.normalized(configuredModel), !ids.contains(configuredModel) {
      ids.append(configuredModel)
      ids.sort()
    }
    return ids.map { id in
      AIChatModelOption(
        id: id,
        label: id,
        supportsReasoning: true,
        isDefault: id == Self.normalized(configuredModel)
      )
    }
  }

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
  ) async throws -> OpenCodeTurnResult {
    if let existing = activeRuns[openOrgThreadID]?.process, existing.isRunning {
      throw OpenCodeError.launchFailed("another turn is already running in this chat")
    }

    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let temporaryRoot: URL?
    var inputData: Data?
    var serverProcess: Process?
    var serverOutputDrain: Task<Void, Never>?
    var serverURL: String?
    let serverPassword = UUID().uuidString.lowercased()
    let configuration = try Self.inlineConfiguration(
      systemPrompt: systemPrompt,
      sandboxAccess: sandboxAccess
    )

    switch transport {
    case .local:
      guard let executableURL else { throw OpenCodeError.executableNotFound }
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("openorg-opencode-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      temporaryRoot = root
      let attachmentURLs = try Self.materializeAttachments(attachments, under: root)
      let processEnvironment = Self.privateServerEnvironment(
        environment,
        serverPassword: serverPassword,
        configuration: configuration
      )
      let server = try await Self.startServer(
        executableURL: executableURL,
        cwd: cwd.standardizedFileURL,
        environment: processEnvironment
      )
      serverProcess = server.process
      serverOutputDrain = server.outputDrain
      serverURL = server.url
      process.executableURL = executableURL
      var arguments = Self.arguments(
        sessionID: existingSessionID,
        model: model,
        reasoningEffort: reasoningEffort,
        attachmentPaths: attachmentURLs.map(\.path),
        message: message
      )
      arguments.insert(contentsOf: ["--server", server.url], at: 1)
      process.arguments = arguments
      process.currentDirectoryURL = cwd.standardizedFileURL
      process.environment = processEnvironment
      inputData = nil
    case .managedRemote(let sshHost, let workspacePath):
      temporaryRoot = nil
      let workspacePath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !workspacePath.isEmpty else { throw OpenCodeError.missingRemoteWorkspace }
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
      process.arguments = try Self.managedRemoteSSHArguments(sshHost: sshHost)
      let remoteArguments = Self.arguments(
        sessionID: existingSessionID,
        model: model,
        reasoningEffort: reasoningEffort,
        attachmentPaths: [],
        message: ""
      )
      let payload = OpenCodeRemotePayload(
        workspacePath: workspacePath,
        arguments: Array(remoteArguments.dropLast()),
        message: message,
        configuration: configuration,
        serverPassword: serverPassword,
        attachments: try attachments.map {
          OpenCodeRemoteAttachment(
            fileName: $0.fileName,
            data: try $0.loadData().base64EncodedString()
          )
        }
      )
      inputData = try JSONEncoder().encode(payload)
      process.environment = environment
    }

    defer {
      serverOutputDrain?.cancel()
      if let serverProcess, serverProcess.isRunning { serverProcess.terminate() }
      if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = standardError

    do {
      try process.run()
      await eventHandler(openOrgThreadID, .processStarted)
      if let inputData { try standardInput.fileHandleForWriting.write(contentsOf: inputData) }
      try standardInput.fileHandleForWriting.close()
      if serverURL == nil {
        serverURL = try await Self.readRemoteServerURL(from: standardOutput.fileHandleForReading)
      }
      guard let serverURL else {
        throw OpenCodeError.invalidResponse("the private server did not report its endpoint")
      }
      activeRuns[openOrgThreadID] = ActiveRun(
        process: process,
        serverProcess: serverProcess,
        serverURL: serverURL,
        serverPassword: serverPassword
      )
    } catch {
      if process.isRunning { process.terminate() }
      activeRuns.removeValue(forKey: openOrgThreadID)
      throw OpenCodeError.launchFailed(error.localizedDescription)
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
    let decoded: OpenCodeStreamResult
    do {
      decoded = try await outputTask.value
    } catch {
      activeRuns.removeValue(forKey: openOrgThreadID)
      throw OpenCodeError.invalidResponse(error.localizedDescription)
    }
    let stderr = (try? await errorTask.value)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    activeRuns.removeValue(forKey: openOrgThreadID)

    if Task.isCancelled || process.terminationReason == .uncaughtSignal {
      throw OpenCodeError.interrupted
    }
    guard status == 0, decoded.succeeded, decoded.errors.isEmpty else {
      let detail = decoded.errors.joined(separator: "\n")
      throw OpenCodeError.turnFailed(
        [detail, stderr].first(where: { !$0.isEmpty }) ?? "OpenCode exited with status \(status)."
      )
    }
    guard let sessionID = decoded.sessionID, !sessionID.isEmpty else {
      throw OpenCodeError.invalidResponse("the response did not include a session ID")
    }
    return OpenCodeTurnResult(sessionID: sessionID, reply: decoded.reply)
  }

  public func interrupt(openOrgThreadID: UUID) {
    guard let process = activeRuns[openOrgThreadID]?.process, process.isRunning else { return }
    process.interrupt()
  }

  public func steer(
    openOrgThreadID: UUID,
    sessionID: String,
    message: String,
    attachments: [OpenClawChatAttachment]
  ) async throws {
    guard let active = activeRuns[openOrgThreadID], active.process.isRunning else {
      throw OpenCodeError.invalidResponse("there is no active OpenCode turn to steer")
    }
    let data = try Self.steerRequestData(
      message: message,
      attachments: attachments
    )
    switch transport {
    case .local:
      guard let executableURL else { throw OpenCodeError.executableNotFound }
      _ = try await Self.runCommand(
        executableURL: executableURL,
        arguments: Self.steerArguments(
          serverURL: active.serverURL,
          sessionID: sessionID,
          data: data
        ),
        cwd: nil,
        environment: Self.privateServerEnvironment(
          environment,
          serverPassword: active.serverPassword
        )
      )
    case .managedRemote(let sshHost, _):
      let input = try JSONEncoder().encode(OpenCodeRemoteSteerPayload(
        serverURL: active.serverURL,
        sessionID: sessionID,
        requestData: data,
        serverPassword: active.serverPassword
      ))
      _ = try await Self.runCommand(
        executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
        arguments: try Self.managedRemoteSteerSSHArguments(sshHost: sshHost),
        cwd: nil,
        environment: environment,
        input: input
      )
    }
  }

  public func shutdown() {
    for run in activeRuns.values {
      if run.process.isRunning { run.process.terminate() }
      if let serverProcess = run.serverProcess, serverProcess.isRunning {
        serverProcess.terminate()
      }
    }
    activeRuns.removeAll()
  }

  nonisolated static func steerArguments(
    serverURL: String,
    sessionID: String,
    data: String
  ) -> [String] {
    [
      "api", "--server", serverURL,
      "session.prompt",
      "--param", "sessionID=\(sessionID)",
      "--data", data
    ]
  }

  nonisolated static func steerRequestData(
    message: String,
    attachments: [OpenClawChatAttachment]
  ) throws -> String {
    var request: [String: Any] = [
      "text": message,
      "delivery": "steer"
    ]
    if !attachments.isEmpty {
      request["files"] = try attachments.map { attachment in
        [
          "uri": "data:\(attachment.mimeType);base64,\(try attachment.loadData().base64EncodedString())",
          "name": attachment.fileName
        ]
      }
    }
    let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  nonisolated static func privateServerEnvironment(
    _ environment: [String: String],
    serverPassword: String,
    configuration: String? = nil
  ) -> [String: String] {
    var result = environment
    result["OPENCODE_SERVER_PASSWORD"] = serverPassword
    if let configuration { result["OPENCODE_CONFIG_CONTENT"] = configuration }
    return result
  }

  private nonisolated static func startServer(
    executableURL: URL,
    cwd: URL,
    environment: [String: String]
  ) async throws -> (process: Process, url: String, outputDrain: Task<Void, Never>) {
    let process = Process()
    let output = Pipe()
    process.executableURL = executableURL
    process.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "0"]
    process.currentDirectoryURL = cwd
    process.environment = environment
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
      let line = try await readLine(from: output.fileHandleForReading)
      let prefix = "server listening on "
      guard line.hasPrefix(prefix) else {
        if process.isRunning { process.terminate() }
        throw OpenCodeError.launchFailed(
          line.isEmpty ? "the private server did not report its endpoint" : line
        )
      }
      let url = String(line.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard isLoopbackServerURL(url) else {
        if process.isRunning { process.terminate() }
        throw OpenCodeError.invalidResponse("the private server reported an invalid endpoint")
      }
      let outputDrain = Task.detached(priority: .utility) {
        _ = try? output.fileHandleForReading.readToEnd()
      }
      return (process, url, outputDrain)
    } catch {
      if process.isRunning { process.terminate() }
      throw error
    }
  }

  private nonisolated static func readRemoteServerURL(from handle: FileHandle) async throws -> String {
    let line = try await readLine(from: handle)
    guard let data = line.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["type"] as? String == "openorg_server",
          let url = object["url"] as? String,
          isLoopbackServerURL(url)
    else {
      throw OpenCodeError.invalidResponse("the remote private server did not report its endpoint")
    }
    return url
  }

  private nonisolated static func readLine(from handle: FileHandle) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      var data = Data()
      while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
        if byte[byte.startIndex] == 0x0A { break }
        data.append(byte)
        if data.count > 16_384 {
          throw OpenCodeError.invalidResponse("the private server response was too large")
        }
      }
      return String(decoding: data, as: UTF8.self)
    }.value
  }

  private nonisolated static func isLoopbackServerURL(_ value: String) -> Bool {
    guard let components = URLComponents(string: value),
          components.scheme == "http",
          components.host == "127.0.0.1",
          components.port != nil
    else { return false }
    return true
  }

  private nonisolated static func consumeOutput(
    _ handle: FileHandle,
    openOrgThreadID: UUID,
    eventHandler: @escaping EventHandler
  ) async throws -> OpenCodeStreamResult {
    var decoder = OpenCodeStreamDecoder()
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

  nonisolated static func modelIDs(from output: String) -> [String] {
    Array(Set(output.split(whereSeparator: \.isNewline).compactMap { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty,
            !line.contains(where: \.isWhitespace),
            let slash = line.firstIndex(of: "/"),
            slash != line.startIndex,
            line.index(after: slash) != line.endIndex
      else { return nil }
      return line
    })).sorted()
  }

  private nonisolated static func runCommand(
    executableURL: URL,
    arguments: [String],
    cwd: URL?,
    environment: [String: String],
    input: Data? = nil
  ) async throws -> (output: String, error: String) {
    try await Task.detached(priority: .utility) {
      let process = Process()
      let standardInput = Pipe()
      let standardOutput = Pipe()
      let standardError = Pipe()
      process.executableURL = executableURL
      process.arguments = arguments
      process.currentDirectoryURL = cwd
      process.environment = environment
      process.standardInput = standardInput
      process.standardOutput = standardOutput
      process.standardError = standardError
      do {
        try process.run()
        if let input { try standardInput.fileHandleForWriting.write(contentsOf: input) }
        try standardInput.fileHandleForWriting.close()
      } catch {
        if process.isRunning { process.terminate() }
        throw OpenCodeError.launchFailed(error.localizedDescription)
      }
      let output = String(
        decoding: try standardOutput.fileHandleForReading.readToEnd() ?? Data(),
        as: UTF8.self
      )
      let error = String(
        decoding: try standardError.fileHandleForReading.readToEnd() ?? Data(),
        as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw OpenCodeError.launchFailed(
          error.isEmpty ? "OpenCode exited with status \(process.terminationStatus)." : error
        )
      }
      return (output, error)
    }.value
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

private struct OpenCodeRemotePayload: Encodable {
  let workspacePath: String
  let arguments: [String]
  let message: String
  let configuration: String
  let serverPassword: String
  let attachments: [OpenCodeRemoteAttachment]
}

private struct OpenCodeRemoteModelPayload: Encodable {
  let workspacePath: String
}

private struct OpenCodeRemoteSteerPayload: Encodable {
  let serverURL: String
  let sessionID: String
  let requestData: String
  let serverPassword: String
}

private struct OpenCodeRemoteAttachment: Encodable {
  let fileName: String
  let data: String
}
