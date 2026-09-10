import Darwin
import Foundation
import OSLog

private struct Org2JSONDecodedValue<Value>: @unchecked Sendable {
  let value: Value
}

public enum Org2SlideExportFormat: String, CaseIterable, Identifiable, Sendable {
  case pdf
  case latex

  public var id: String { rawValue }

  public var fileExtension: String {
    switch self {
    case .pdf: "pdf"
    case .latex: "tex"
    }
  }

  public var title: String {
    switch self {
    case .pdf: "PDF"
    case .latex: "LaTeX"
    }
  }
}

public enum Org2CLIInvocationOutcome: String, Equatable, Sendable {
  case succeeded
  case failed
  case timedOut = "timed-out"
  case cancelled
  case missingExecutable = "missing-executable"
  case launchFailed = "launch-failed"
}

public struct Org2CLIInvocationMetric: Equatable, Sendable {
  public let command: String
  public let elapsedMilliseconds: Double
  public let outcome: Org2CLIInvocationOutcome
  public let standardInputBytes: Int
  public let standardOutputBytes: Int
  public let standardErrorBytes: Int
  public let exitStatus: Int32?

  public init(
    command: String,
    elapsedMilliseconds: Double,
    outcome: Org2CLIInvocationOutcome,
    standardInputBytes: Int,
    standardOutputBytes: Int,
    standardErrorBytes: Int,
    exitStatus: Int32?
  ) {
    self.command = command
    self.elapsedMilliseconds = elapsedMilliseconds
    self.outcome = outcome
    self.standardInputBytes = standardInputBytes
    self.standardOutputBytes = standardOutputBytes
    self.standardErrorBytes = standardErrorBytes
    self.exitStatus = exitStatus
  }
}

public struct Org2CLI: Sendable {
  private static let ignoreBrokenPipeSignal: Void = {
    _ = Darwin.signal(SIGPIPE, SIG_IGN)
  }()

  public let repoRoot: URL
  private let cliPath: URL
  private let nodePath: String?
  private let telemetryHandler: (@Sendable (Org2CLIInvocationMetric) -> Void)?
  private static let telemetryLogger = Logger(
    subsystem: "org.org2.workspace",
    category: "CLILatency"
  )
  private static let telemetryCommandRoots: Set<String> = [
    "agent", "agent-profile", "agenda", "ai", "approvals", "archive", "artifact",
    "backlinks", "brief", "capture", "clock", "compile", "context", "corpus",
    "crypt", "data", "doctor", "entity", "eval", "export", "fmt", "goal",
    "graph", "id", "index", "ledger", "lint", "lsp", "mcp", "plan", "plugin", "publish",
    "query", "query-data", "refile", "render-chart", "review", "roam", "run",
    "search", "skill", "source", "table", "todo", "version", "workflow", "workspace"
  ]
  private static let telemetryNestedCommands: Set<String> = [
    "agent.capabilities", "agent.context", "agent.search", "agent.fetch", "agent.bundle",
    "agent-profile.list", "agent-profile.show", "agent-profile.create", "agent-profile.update",
    "agent-profile.resolve", "ai.validate-job", "ai.run", "ai.suggest-links", "ai.review",
    "ai.promote", "artifact.graph", "artifact.rebuild", "brief.today", "brief.project",
    "brief.node", "compile.corpus", "corpus.show", "corpus.validate", "corpus.init",
    "data.refresh", "entity.show", "eval.run", "eval.fixture", "export.html",
    "export.beamer", "goal.list", "goal.show", "goal.create", "goal.update",
    "graph.audit", "id.get", "id.ensure", "ledger.list", "ledger.show", "ledger.create",
    "ledger.update", "ledger.event", "mcp.serve", "mcp.clients", "mcp.client-add",
    "mcp.discover", "mcp.snapshot", "review.list", "review.show", "run.create", "skill.install",
    "plugin.list", "plugin.init", "plugin.add", "plugin.remove", "plugin.update",
    "plugin.sync", "plugin.trust", "plugin.doctor", "plugin.exec", "plugin.template",
    "run.list", "run.show", "run.validate", "run.start", "run.resume", "run.retry",
    "run.cancel", "run.complete", "run.complete-external", "run.reopen-external",
    "run.fail", "run.block", "run.fork", "run.normalize", "run.assign", "run.comment",
    "run.outcome", "run.runtime", "run.step", "run.artifact", "run.artifact-review",
    "run.validation", "run.approval-request", "run.approval-decide", "source.list",
    "source.status", "source.doctor", "source.import", "source.sync", "table.recalculate", "todo.set",
    "todo.toggle", "todo.assign", "todo.approve", "workflow.list", "workflow.show",
    "workflow.validate", "workflow.save", "workflow.run", "workflow.triggers",
    "workflow.package", "workflow.corpus-template", "workflow.install-builtin",
    "workspace.agenda", "workspace.search", "workspace.agent-state"
  ]

  public init(
    repoRoot: URL,
    nodePath: String? = nil,
    telemetryHandler: (@Sendable (Org2CLIInvocationMetric) -> Void)? = nil
  ) {
    self.repoRoot = repoRoot
    self.cliPath = repoRoot.appendingPathComponent("dist/cli.js")
    let bundledNode = repoRoot.appendingPathComponent("bin/node")
    self.nodePath = nodePath
      ?? (FileManager.default.isExecutableFile(atPath: bundledNode.path) ? bundledNode.path : nil)
    self.telemetryHandler = telemetryHandler
  }

  public static func defaultRepoRoot(
    filePath: String = #filePath,
    bundleResourceURL: URL? = Bundle.main.resourceURL
  ) throws -> URL {
    if let override = ProcessInfo.processInfo.environment["ORG2_REPO_ROOT"], !override.isEmpty {
      return URL(fileURLWithPath: override).standardizedFileURL
    }

    if let bundledRoot = bundleResourceURL?.appendingPathComponent("Org2Runtime", isDirectory: true),
       FileManager.default.fileExists(atPath: bundledRoot.appendingPathComponent("dist/cli.js").path) {
      return bundledRoot.standardizedFileURL
    }

    var url = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    for _ in 0..<5 {
      url.deleteLastPathComponent()
    }
    return url.standardizedFileURL
  }

  public func runJSON<T: Decodable>(
    _ arguments: [String],
    environment: [String: String] = [:],
    as type: T.Type = T.self
  ) async throws -> T {
    let data = try await run(arguments, environment: environment)
    return try await decodeJSON(T.self, from: data)
  }

  public func runJSONSync<T: Decodable>(_ arguments: [String], as type: T.Type = T.self) throws -> T {
    let data = try runSync(arguments)
    return try JSONDecoder().decode(T.self, from: data)
  }

  public func parseFileJSON<T: Decodable>(_ file: URL, sourceRanges: Bool = false, as type: T.Type = T.self) async throws -> T {
    var arguments = [file.path]
    if sourceRanges {
      arguments.insert("--source-ranges", at: 0)
    }
    let operation = Task.detached(priority: .userInitiated) {
      try runProcess(scriptPath: repoRoot.appendingPathComponent("dist/parse.js"), arguments: arguments)
    }
    let data = try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
    return try await decodeJSON(T.self, from: data)
  }

  public func parseTextJSON<T: Decodable>(
    _ text: String,
    sourceRanges: Bool = false,
    sourceLineOffset: Int = 0,
    sourcePath: String? = nil,
    as type: T.Type = T.self
  ) async throws -> T {
    var arguments = ["-"]
    if let sourcePath { arguments.insert(contentsOf: ["--source-path", sourcePath], at: 0) }
    if sourceLineOffset > 0 {
      arguments.insert("\(sourceLineOffset)", at: 0)
      arguments.insert("--source-line-offset", at: 0)
    }
    if sourceRanges {
      arguments.insert("--source-ranges", at: 0)
    }
    let operation = Task.detached(priority: .userInitiated) {
      try runProcess(
        scriptPath: repoRoot.appendingPathComponent("dist/parse.js"),
        arguments: arguments,
        standardInput: Data(text.utf8)
      )
    }
    let data = try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
    return try await decodeJSON(T.self, from: data)
  }

  public func renderAppHTML(
    _ text: String,
    sourcePath: String,
    sourceLineOffset: Int = 0,
    stylesheetPath: String? = nil,
    timeout: TimeInterval = 8
  ) async throws -> String {
    var arguments = ["--source-path", sourcePath]
    if sourceLineOffset > 0 {
      arguments.append(contentsOf: ["--source-line-offset", "\(sourceLineOffset)"])
    }
    if let stylesheetPath, !stylesheetPath.isEmpty {
      arguments.append(contentsOf: ["--stylesheet", stylesheetPath])
    }
    let operation = Task.detached(priority: .userInitiated) {
      try runProcess(
        scriptPath: repoRoot.appendingPathComponent("dist/render-html.js"),
        arguments: arguments,
        standardInput: Data(text.utf8),
        timeout: timeout
      )
    }
    let data = try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
    return String(decoding: data, as: UTF8.self)
  }

  public func renderPresentationPDF(
    _ text: String,
    sourcePath: String,
    sourceLineOffset: Int = 0,
    passes: Int = 1,
    timeout: TimeInterval = 30
  ) async throws -> Data {
    var arguments = [
      "--source-path", sourcePath,
      "--passes", "\(max(1, min(4, passes)))",
    ]
    if sourceLineOffset > 0 {
      arguments.append(contentsOf: ["--source-line-offset", "\(sourceLineOffset)"])
    }
    let operation = Task.detached(priority: .userInitiated) {
      try runProcess(
        scriptPath: repoRoot.appendingPathComponent("dist/render-presentation-pdf.js"),
        arguments: arguments,
        standardInput: Data(text.utf8),
        timeout: timeout
      )
    }
    let data = try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
    guard data.starts(with: Data("%PDF".utf8)) else {
      throw Org2CLIError.commandFailed(
        status: 0,
        message: "The slide renderer completed without producing a PDF."
      )
    }
    return data
  }

  public func analyzeEditorText(
    _ text: String,
    sourceLineOffset: Int = 0,
    sourcePath: String? = nil,
    timeout: TimeInterval = 5
  ) async throws -> OrgSourceEditorSemanticSnapshot {
    var arguments: [String] = []
    if let sourcePath { arguments.append(contentsOf: ["--source-path", sourcePath]) }
    if sourceLineOffset > 0 {
      arguments.append(contentsOf: ["--source-line-offset", "\(sourceLineOffset)"])
    }
    let operation = Task.detached(priority: .utility) {
      try runProcess(
        scriptPath: repoRoot.appendingPathComponent("dist/editor-analysis.js"),
        arguments: arguments,
        standardInput: Data(text.utf8),
        timeout: timeout
      )
    }
    let data = try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
    let payload = try await decodeJSON(Org2EditorAnalysisPayload.self, from: data)
    return OrgSourceEditorSemanticSnapshot(payload: payload)
  }

  public func parseFileJSONSync<T: Decodable>(_ file: URL, sourceRanges: Bool = false, as type: T.Type = T.self) throws -> T {
    var arguments = [file.path]
    if sourceRanges {
      arguments.insert("--source-ranges", at: 0)
    }
    let data = try runProcess(scriptPath: repoRoot.appendingPathComponent("dist/parse.js"), arguments: arguments)
    return try JSONDecoder().decode(T.self, from: data)
  }

  public func run(_ arguments: [String], environment: [String: String] = [:]) async throws -> Data {
    let operation = Task.detached(priority: .userInitiated) {
      try runProcess(scriptPath: cliPath, arguments: arguments, environment: environment)
    }
    return try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
  }

  public func runSync(_ arguments: [String]) throws -> Data {
    try runProcess(scriptPath: cliPath, arguments: arguments)
  }

  public func formatOrgText(
    _ text: String,
    canonicalOrgSyntax: Bool = false,
    timeout: TimeInterval = 8
  ) async throws -> String {
    let operation = Task.detached(priority: .userInitiated) {
      try runProcess(
        scriptPath: cliPath,
        arguments: ["fmt", "--stdin"] + (canonicalOrgSyntax ? ["--canonical-org"] : []),
        standardInput: Data(text.utf8),
        timeout: timeout
      )
    }
    let data = try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
    return String(decoding: data, as: UTF8.self)
  }

  public func exportBeamer(
    file: URL,
    destination: URL,
    format: Org2SlideExportFormat
  ) async throws {
    var arguments = [
      "export", "beamer",
      "--file", file.standardizedFileURL.path,
      "--out", destination.standardizedFileURL.path,
    ]
    if format == .pdf {
      arguments.append("--pdf")
    }
    arguments.append(contentsOf: ["--format", "json", "--apply"])
    _ = try await run(arguments)
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) async throws -> T {
    let decoded = try await Task.detached(priority: .userInitiated) {
      Org2JSONDecodedValue(value: try JSONDecoder().decode(T.self, from: data))
    }.value
    return decoded.value
  }

  private func runProcess(
    scriptPath: URL,
    arguments: [String],
    standardInput: Data? = nil,
    timeout: TimeInterval? = nil,
    environment: [String: String] = [:]
  ) throws -> Data {
    _ = Self.ignoreBrokenPipeSignal

    let startedAt = DispatchTime.now().uptimeNanoseconds
    let command = Self.telemetryCommandIdentity(scriptPath: scriptPath, arguments: arguments)
    var outcome = Org2CLIInvocationOutcome.failed
    var standardOutputBytes = 0
    var standardErrorBytes = 0
    var exitStatus: Int32?
    defer {
      let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
      let metric = Org2CLIInvocationMetric(
        command: command,
        elapsedMilliseconds: Double(elapsedNanoseconds) / 1_000_000,
        outcome: outcome,
        standardInputBytes: standardInput?.count ?? 0,
        standardOutputBytes: standardOutputBytes,
        standardErrorBytes: standardErrorBytes,
        exitStatus: exitStatus
      )
      Self.recordTelemetry(metric)
      telemetryHandler?(metric)
    }

    guard FileManager.default.fileExists(atPath: scriptPath.path) else {
      outcome = .missingExecutable
      throw Org2CLIError.missingCLI(scriptPath.path)
    }

    let process = Process()
    // Homebrew replaces executables in place during upgrades. A Node path can
    // therefore disappear between resolution and launch. Foundation may turn
    // that invalid executable URL into an uncaught Objective-C exception
    // instead of a Swift error, terminating the whole app. Always launch the
    // stable system env binary and make Node its argument; a disappearing Node
    // then becomes an ordinary child-process failure (status 127).
    let candidateNode = nodePath ?? Self.resolveNodePath()
    let node = candidateNode.flatMap {
      Self.isLaunchableExecutable(atPath: $0) ? $0 : nil
    }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [node ?? "node", scriptPath.path] + arguments
    process.currentDirectoryURL = repoRoot
    process.environment = Self.processEnvironment().merging(environment) { _, override in override }

    let stdout = Pipe()
    let stderr = Pipe()
    let stdin = standardInput.map { _ in Pipe() }
    process.standardOutput = stdout
    process.standardError = stderr
    if let stdin {
      process.standardInput = stdin
    }

    let stdoutCollector = PipeOutputCollector()
    let stderrCollector = PipeOutputCollector()
    let readGroup = DispatchGroup()

    do {
      try process.run()
    } catch {
      outcome = .launchFailed
      throw error
    }

    // The child inherits its own copies. Keeping the parent's write ends open
    // can prevent readDataToEndOfFile() from ever observing EOF after the child
    // exits, leaving refresh tasks permanently stuck in readGroup.wait().
    try? stdout.fileHandleForWriting.close()
    try? stderr.fileHandleForWriting.close()
    if let stdin {
      // The child inherited the read end during launch. The parent never reads
      // from stdin, so retaining this handle leaks one descriptor per command.
      try? stdin.fileHandleForReading.close()
    }

    if let standardInput, let stdin {
      readGroup.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        defer {
          try? stdin.fileHandleForWriting.close()
          readGroup.leave()
        }
        try? stdin.fileHandleForWriting.write(contentsOf: standardInput)
      }
    }

    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer {
        try? stdout.fileHandleForReading.close()
        readGroup.leave()
      }
      stdoutCollector.drain(stdout.fileHandleForReading)
    }
    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer {
        try? stderr.fileHandleForReading.close()
        readGroup.leave()
      }
      stderrCollector.drain(stderr.fileHandleForReading)
    }

    let deadline = timeout.map {
      DispatchTime.now() + .milliseconds(Int((max(0.01, $0) * 1_000).rounded(.up)))
    }
    var didTimeOut = false
    var wasCancelled = false
    while process.isRunning {
      if Task.isCancelled {
        wasCancelled = true
        break
      }
      if let deadline, DispatchTime.now() >= deadline {
        didTimeOut = true
        break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }

    if process.isRunning && (didTimeOut || wasCancelled) {
      process.terminate()
      let terminationDeadline = DispatchTime.now() + .milliseconds(500)
      while process.isRunning && DispatchTime.now() < terminationDeadline {
        Thread.sleep(forTimeInterval: 0.01)
      }
      if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
      }
    }

    process.waitUntilExit()
    exitStatus = process.terminationStatus
    // A command (or a descendant it spawned) can keep a pipe descriptor open
    // after the direct child exits. Never let output draining turn that into an
    // unbounded application hang. Do not forcibly close a FileHandle while its
    // reader is active; Foundation can raise an Objective-C exception. The
    // reader owns the pipe and will unwind naturally when the descriptor closes.
    // Collectors publish each chunk as it arrives, so a descendant retaining the
    // pipe cannot make us discard output already written by the direct child.
    _ = readGroup.wait(timeout: .now() + 1)

    let outData = stdoutCollector.data
    let errData = stderrCollector.data
    standardOutputBytes = outData.count
    standardErrorBytes = errData.count

    if wasCancelled {
      outcome = .cancelled
      throw CancellationError()
    }

    if didTimeOut {
      outcome = .timedOut
      throw Org2CLIError.commandTimedOut(seconds: Int(timeout?.rounded(.up) ?? 0))
    }

    guard process.terminationStatus == 0 else {
      let stderrText = String(data: errData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let stdoutFailure = Self.commandFailureMessage(from: outData)
      throw Org2CLIError.commandFailed(
        status: Int(process.terminationStatus),
        message: stderrText?.isEmpty == false
          ? stderrText!
          : (stdoutFailure ?? "org2 exited with status \(process.terminationStatus)")
      )
    }

    outcome = .succeeded
    return outData
  }

  private static func recordTelemetry(_ metric: Org2CLIInvocationMetric) {
    let exitStatus = metric.exitStatus.map(String.init) ?? "none"
    telemetryLogger.info(
      "command=\(metric.command, privacy: .public) elapsed_ms=\(metric.elapsedMilliseconds, privacy: .public) outcome=\(metric.outcome.rawValue, privacy: .public) stdin_bytes=\(metric.standardInputBytes, privacy: .public) stdout_bytes=\(metric.standardOutputBytes, privacy: .public) stderr_bytes=\(metric.standardErrorBytes, privacy: .public) exit_status=\(exitStatus, privacy: .public)"
    )
  }

  static func telemetryCommandIdentity(scriptPath: URL, arguments: [String]) -> String {
    let script = scriptPath.deletingPathExtension().lastPathComponent
    guard script == "cli" else { return script }
    guard let root = arguments.first,
          telemetryCommandRoots.contains(root)
    else { return "cli.unknown" }

    if arguments.count > 1, arguments[1].utf8.count <= 48 {
      let nestedCommand = "\(root).\(arguments[1])"
      if telemetryNestedCommands.contains(nestedCommand) {
        return "cli.\(nestedCommand)"
      }
    }
    return "cli.\(root)"
  }

  private static func commandFailureMessage(from stdout: Data) -> String? {
    guard !stdout.isEmpty else { return nil }
    if let value = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] {
      var messages: [String] = []
      if let diagnostics = value["diagnostics"] as? [[String: Any]] {
        messages.append(contentsOf: diagnostics.compactMap { diagnostic in
          guard let message = diagnostic["message"] as? String,
                !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          else { return nil }
          return message
        })
      }
      if let results = value["results"] as? [[String: Any]] {
        for result in results {
          for key in ["error", "message"] {
            if let message = result[key] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              messages.append(message)
            }
          }
        }
      }
      for key in ["error", "message"] {
        if let message = value[key] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          messages.append(message)
        }
      }
      let unique = messages.reduce(into: [String]()) { result, message in
        if !result.contains(message) { result.append(message) }
      }
      if !unique.isEmpty {
        return unique.prefix(3).joined(separator: "\n")
      }
    }

    let text = String(data: stdout, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let text, !text.isEmpty else { return nil }
    return String(text.prefix(2_000))
  }

  var runtimeNodePath: String? { nodePath ?? Self.resolveNodePath() }

  private static func resolveNodePath() -> String? {
    let candidates = [
      "/opt/homebrew/bin/node",
      "/usr/local/bin/node",
      "/usr/bin/node"
    ]
    return candidates.first { isLaunchableExecutable(atPath: $0) }
  }

  private static func isLaunchableExecutable(atPath path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && !isDirectory.boolValue
      && FileManager.default.isExecutableFile(atPath: path)
  }

  static func processEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let defaultPath = "/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if let existing = environment["PATH"], !existing.isEmpty {
      environment["PATH"] = "\(defaultPath):\(existing)"
    } else {
      environment["PATH"] = defaultPath
    }
    return environment
  }
}

private final class PipeOutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  func drain(_ handle: FileHandle) {
    while true {
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      lock.lock()
      storage.append(chunk)
      lock.unlock()
    }
  }

  var data: Data {
    lock.lock()
    let data = storage
    lock.unlock()
    return data
  }
}

public enum Org2CLIError: LocalizedError, Equatable {
  case missingCLI(String)
  case commandFailed(status: Int, message: String)
  case commandTimedOut(seconds: Int)

  public var errorDescription: String? {
    switch self {
    case .missingCLI(let path):
      "Org2 CLI not found at \(path). Run npm run build in the org2 repo."
    case .commandFailed(_, let message):
      message
    case .commandTimedOut(let seconds):
      "Org2 rendering timed out after \(seconds) second\(seconds == 1 ? "" : "s")."
    }
  }
}
