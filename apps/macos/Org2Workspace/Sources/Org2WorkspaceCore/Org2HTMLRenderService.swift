import Darwin
import Foundation

private struct Org2HTMLRenderServiceRequest: Encodable, Sendable {
  let id: String
  let text: String
  let sourcePath: String
  let sourceLineOffset: Int
  let stylesheetPath: String?
  let corpusRoot: String?
  let referenceEmbeds: Bool
}

private struct Org2HTMLRenderServiceResponse: Decodable, Sendable {
  let id: String
  let html: String?
  let error: String?
}

private final class Org2HTMLRenderProcessReference: @unchecked Sendable {
  let process: Process

  init(_ process: Process) {
    self.process = process
  }
}

actor Org2HTMLRenderServicePool {
  static let shared = Org2HTMLRenderServicePool()

  private struct Key: Hashable {
    let repoRoot: String
    let nodePath: String
  }

  private var workers: [Key: Org2HTMLRenderServiceWorker] = [:]

  func render(
    text: String,
    sourcePath: String,
    sourceLineOffset: Int,
    stylesheetPath: String?,
    corpusRootPath: String?,
    resolveEmbeds: Bool,
    repoRoot: URL,
    nodePath: String?,
    timeout: TimeInterval
  ) async throws -> String {
    let resolvedNodePath = nodePath ?? "node"
    let key = Key(
      repoRoot: repoRoot.standardizedFileURL.path,
      nodePath: resolvedNodePath
    )
    let worker: Org2HTMLRenderServiceWorker
    if let existing = workers[key] {
      worker = existing
    } else {
      worker = Org2HTMLRenderServiceWorker(
        repoRoot: repoRoot,
        nodePath: resolvedNodePath
      )
      workers[key] = worker
    }

    return try await worker.render(
      Org2HTMLRenderServiceRequest(
        id: UUID().uuidString.lowercased(),
        text: text,
        sourcePath: sourcePath,
        sourceLineOffset: sourceLineOffset,
        stylesheetPath: stylesheetPath,
        corpusRoot: corpusRootPath,
        referenceEmbeds: !resolveEmbeds
      ),
      timeout: timeout
    )
  }
}

private final class Org2HTMLRenderOperation: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?
  private var result: Result<String, Error>?

  var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return result != nil
  }

  func install(_ continuation: CheckedContinuation<String, Error>) {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(with: result)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  @discardableResult
  func finish(_ result: Result<String, Error>) -> Bool {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return false
    }
    self.result = result
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
    return true
  }
}

private final class Org2HTMLRenderServiceWorker: @unchecked Sendable {
  private let repoRoot: URL
  private let nodePath: String
  private let queue = DispatchQueue(
    label: "org.openorg.html-render-service",
    qos: .userInitiated
  )
  private let stateLock = NSLock()
  private var process: Process?
  private var inputHandle: FileHandle?
  private var outputHandle: FileHandle?
  private var outputBuffer = Data()
  private var activeRequestID: String?

  init(repoRoot: URL, nodePath: String) {
    self.repoRoot = repoRoot.standardizedFileURL
    self.nodePath = nodePath
  }

  func render(
    _ request: Org2HTMLRenderServiceRequest,
    timeout: TimeInterval
  ) async throws -> String {
    let operation = Org2HTMLRenderOperation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        operation.install(continuation)
        queue.async { [weak self] in
          self?.execute(request, timeout: timeout, operation: operation)
        }
      }
    } onCancel: { [weak self] in
      if operation.finish(.failure(CancellationError())) {
        self?.terminateAfterCancellationGrace(requestID: request.id)
      }
    }
  }

  private func terminateAfterCancellationGrace(requestID: String) {
    // SwiftUI can retire one transcript while its final tiny render is only a
    // few milliseconds from completion. Give that request a short grace
    // period so rapid thread switches do not repeatedly throw away the warm
    // parser process. Truly stuck or large abandoned work is still killed.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.terminate(requestID: requestID)
    }
  }

  private func execute(
    _ request: Org2HTMLRenderServiceRequest,
    timeout: TimeInterval,
    operation: Org2HTMLRenderOperation
  ) {
    guard !operation.isFinished else { return }
    let timeoutWork = DispatchWorkItem { [weak self, weak operation] in
      guard let operation,
            operation.finish(.failure(Org2CLIError.commandTimedOut(
              seconds: Int(max(0.01, timeout).rounded(.up))
            )))
      else { return }
      self?.terminate(requestID: request.id)
    }

    do {
      try ensureProcess()
      stateLock.lock()
      activeRequestID = request.id
      let inputHandle = self.inputHandle
      stateLock.unlock()

      guard let inputHandle else {
        throw Org2CLIError.commandFailed(
          status: -1,
          message: "The local Org renderer did not open its input stream."
        )
      }
      var payload = try JSONEncoder().encode(request)
      payload.append(0x0A)
      DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + max(0.01, timeout),
        execute: timeoutWork
      )
      try inputHandle.write(contentsOf: payload)
      let line = try readResponseLine()
      timeoutWork.cancel()
      clearActiveRequest(request.id)

      guard !operation.isFinished else { return }
      let response = try JSONDecoder().decode(
        Org2HTMLRenderServiceResponse.self,
        from: line
      )
      guard response.id == request.id else {
        throw Org2CLIError.commandFailed(
          status: -1,
          message: "The local Org renderer returned an out-of-order response."
        )
      }
      if let error = response.error, !error.isEmpty {
        throw Org2CLIError.commandFailed(status: 1, message: error)
      }
      guard let html = response.html else {
        throw Org2CLIError.commandFailed(
          status: 1,
          message: "The local Org renderer returned no HTML."
        )
      }
      operation.finish(.success(html))
    } catch {
      timeoutWork.cancel()
      clearActiveRequest(request.id)
      resetProcess()
      operation.finish(.failure(error))
    }
  }

  private func ensureProcess() throws {
    if let process, process.isRunning,
       inputHandle != nil, outputHandle != nil {
      return
    }
    resetProcess()
    _ = Darwin.signal(SIGPIPE, SIG_IGN)

    let servicePath = repoRoot.appendingPathComponent("dist/render-html-service.js")
    guard FileManager.default.fileExists(atPath: servicePath.path) else {
      throw Org2CLIError.missingCLI(servicePath.path)
    }

    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [nodePath, servicePath.path]
    process.currentDirectoryURL = repoRoot
    process.environment = Org2CLI.processEnvironment()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()

    try? stdin.fileHandleForReading.close()
    try? stdout.fileHandleForWriting.close()
    try? stderr.fileHandleForWriting.close()
    DispatchQueue.global(qos: .utility).async {
      while !stderr.fileHandleForReading.availableData.isEmpty {}
      try? stderr.fileHandleForReading.close()
    }

    stateLock.lock()
    self.process = process
    inputHandle = stdin.fileHandleForWriting
    outputHandle = stdout.fileHandleForReading
    outputBuffer.removeAll(keepingCapacity: true)
    stateLock.unlock()
  }

  private func readResponseLine() throws -> Data {
    while true {
      if let newline = outputBuffer.firstIndex(of: 0x0A) {
        let line = outputBuffer[..<newline]
        outputBuffer.removeSubrange(...newline)
        return Data(line)
      }
      stateLock.lock()
      let outputHandle = self.outputHandle
      stateLock.unlock()
      guard let outputHandle else {
        throw Org2CLIError.commandFailed(
          status: processExitStatus(),
          message: "The local Org renderer exited before returning HTML."
        )
      }
      let chunk = outputHandle.availableData
      guard !chunk.isEmpty
      else {
        throw Org2CLIError.commandFailed(
          status: processExitStatus(),
          message: "The local Org renderer exited before returning HTML."
        )
      }
      outputBuffer.append(chunk)
    }
  }

  private func processExitStatus() -> Int {
    stateLock.lock()
    let process = self.process
    stateLock.unlock()
    // Foundation raises NSInvalidArgumentException if terminationStatus is
    // queried during the small interval after a pipe closes but before the
    // child has completed termination.
    guard let process, !process.isRunning else { return -1 }
    return Int(process.terminationStatus)
  }

  private func clearActiveRequest(_ id: String) {
    stateLock.lock()
    if activeRequestID == id { activeRequestID = nil }
    stateLock.unlock()
  }

  private func terminate(requestID: String) {
    stateLock.lock()
    let process = activeRequestID == requestID ? self.process : nil
    stateLock.unlock()
    guard let process, process.isRunning else { return }
    stop(process)
  }

  private func resetProcess() {
    stateLock.lock()
    let process = self.process
    self.process = nil
    activeRequestID = nil
    let inputHandle = self.inputHandle
    self.inputHandle = nil
    let outputHandle = self.outputHandle
    self.outputHandle = nil
    outputBuffer.removeAll(keepingCapacity: true)
    stateLock.unlock()

    if let process, process.isRunning { stop(process) }
    try? inputHandle?.close()
    try? outputHandle?.close()
  }

  private func stop(_ process: Process) {
    guard process.isRunning else { return }
    let identifier = process.processIdentifier
    let reference = Org2HTMLRenderProcessReference(process)
    process.terminate()
    // A cancelled view must not leave the serial renderer lane blocked behind
    // a child that ignores SIGTERM. Escalation is bounded and process-scoped.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
      if reference.process.isRunning {
        _ = Darwin.kill(identifier, SIGKILL)
      }
    }
  }
}
