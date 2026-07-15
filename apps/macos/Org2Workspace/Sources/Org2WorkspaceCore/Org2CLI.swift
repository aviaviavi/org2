import Darwin
import Foundation

public struct Org2CLI: Sendable {
  private static let ignoreBrokenPipeSignal: Void = {
    _ = Darwin.signal(SIGPIPE, SIG_IGN)
  }()

  public let repoRoot: URL
  private let cliPath: URL
  private let nodePath: String?

  public init(repoRoot: URL, nodePath: String? = nil) {
    self.repoRoot = repoRoot
    self.cliPath = repoRoot.appendingPathComponent("dist/cli.js")
    self.nodePath = nodePath
  }

  public static func defaultRepoRoot(filePath: String = #filePath) throws -> URL {
    if let override = ProcessInfo.processInfo.environment["ORG2_REPO_ROOT"], !override.isEmpty {
      return URL(fileURLWithPath: override).standardizedFileURL
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
    return try JSONDecoder().decode(T.self, from: data)
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
    let data = try await Task.detached(priority: .userInitiated) {
      try runProcess(scriptPath: repoRoot.appendingPathComponent("dist/parse.js"), arguments: arguments)
    }.value
    return try JSONDecoder().decode(T.self, from: data)
  }

  public func parseTextJSON<T: Decodable>(
    _ text: String,
    sourceRanges: Bool = false,
    sourceLineOffset: Int = 0,
    as type: T.Type = T.self
  ) async throws -> T {
    var arguments = ["-"]
    if sourceLineOffset > 0 {
      arguments.insert("\(sourceLineOffset)", at: 0)
      arguments.insert("--source-line-offset", at: 0)
    }
    if sourceRanges {
      arguments.insert("--source-ranges", at: 0)
    }
    let data = try await Task.detached(priority: .userInitiated) {
      try runProcess(
        scriptPath: repoRoot.appendingPathComponent("dist/parse.js"),
        arguments: arguments,
        standardInput: Data(text.utf8)
      )
    }.value
    return try JSONDecoder().decode(T.self, from: data)
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
    let data = try await Task.detached(priority: .userInitiated) {
      try runProcess(
        scriptPath: repoRoot.appendingPathComponent("dist/render-html.js"),
        arguments: arguments,
        standardInput: Data(text.utf8),
        timeout: timeout
      )
    }.value
    return String(decoding: data, as: UTF8.self)
  }

  public func analyzeEditorText(
    _ text: String,
    sourceLineOffset: Int = 0,
    timeout: TimeInterval = 5
  ) async throws -> OrgSourceEditorSemanticSnapshot {
    var arguments: [String] = []
    if sourceLineOffset > 0 {
      arguments.append(contentsOf: ["--source-line-offset", "\(sourceLineOffset)"])
    }
    let data = try await Task.detached(priority: .utility) {
      try runProcess(
        scriptPath: repoRoot.appendingPathComponent("dist/editor-analysis.js"),
        arguments: arguments,
        standardInput: Data(text.utf8),
        timeout: timeout
      )
    }.value
    let payload = try JSONDecoder().decode(Org2EditorAnalysisPayload.self, from: data)
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
    try await Task.detached(priority: .userInitiated) {
      try runProcess(scriptPath: cliPath, arguments: arguments, environment: environment)
    }.value
  }

  public func runSync(_ arguments: [String]) throws -> Data {
    try runProcess(scriptPath: cliPath, arguments: arguments)
  }

  private func runProcess(
    scriptPath: URL,
    arguments: [String],
    standardInput: Data? = nil,
    timeout: TimeInterval? = nil,
    environment: [String: String] = [:]
  ) throws -> Data {
    _ = Self.ignoreBrokenPipeSignal

    guard FileManager.default.fileExists(atPath: scriptPath.path) else {
      throw Org2CLIError.missingCLI(scriptPath.path)
    }

    let process = Process()
    let node = nodePath ?? Self.resolveNodePath()
    if let node {
      process.executableURL = URL(fileURLWithPath: node)
      process.arguments = [scriptPath.path] + arguments
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["node", scriptPath.path] + arguments
    }
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

    try process.run()

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
      stdoutCollector.set(stdout.fileHandleForReading.readDataToEndOfFile())
      readGroup.leave()
    }
    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      stderrCollector.set(stderr.fileHandleForReading.readDataToEndOfFile())
      readGroup.leave()
    }

    let didTimeOut: Bool
    if let timeout {
      let deadline = Date().addingTimeInterval(max(0.01, timeout))
      while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
      }
      didTimeOut = process.isRunning
      if didTimeOut {
        process.terminate()
        let terminationDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < terminationDeadline {
          Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
          Darwin.kill(process.processIdentifier, SIGKILL)
        }
      }
    } else {
      didTimeOut = false
    }

    process.waitUntilExit()
    readGroup.wait()

    if didTimeOut {
      throw Org2CLIError.commandTimedOut(seconds: Int(timeout?.rounded(.up) ?? 0))
    }

    let outData = stdoutCollector.data
    let errData = stderrCollector.data

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

    return outData
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

  private static func resolveNodePath() -> String? {
    let candidates = [
      "/opt/homebrew/bin/node",
      "/usr/local/bin/node",
      "/usr/bin/node"
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  private static func processEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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

  func set(_ data: Data) {
    lock.lock()
    storage = data
    lock.unlock()
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
