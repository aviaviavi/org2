import CryptoKit
import Foundation

enum WorkspaceDocumentMutationError: LocalizedError, Equatable, Sendable {
  case fileChanged(file: String)
  case invalidUTF8(file: String)
  case outsideCorpus(file: String, root: String)
  case undeclaredResource(file: String)

  var errorDescription: String? {
    switch self {
    case .fileChanged(let file):
      "File changed on disk; reload \(file) before saving"
    case .invalidUTF8(let file):
      "The document is not valid UTF-8: \(file)"
    case .outsideCorpus(let file, let root):
      "Refusing to mutate \(file) outside the active corpus at \(root)"
    case .undeclaredResource(let file):
      "Refusing to access undeclared document resource \(file)"
    }
  }
}

struct WorkspaceDocumentFileIdentity: Equatable, Sendable {
  let fileSize: Int?
  let contentModificationDate: Date?
  let attributeModificationDate: Date?
  let fileResourceIdentifier: Data?
  let generationIdentifier: Data?
}

struct WorkspaceDocumentSnapshot: Equatable, Sendable {
  let url: URL
  let text: String
  let digest: Data
  let identity: WorkspaceDocumentFileIdentity?
  let existed: Bool

  static func read(at rawURL: URL, allowMissing: Bool = false) throws -> Self {
    let url = URL(fileURLWithPath: rawURL.standardizedFileURL.path)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else {
      if allowMissing {
        return WorkspaceDocumentSnapshot(
          url: url,
          text: "",
          digest: digest(Data()),
          identity: nil,
          existed: false
        )
      }
      throw CocoaError(.fileNoSuchFile)
    }

    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard let text = String(data: data, encoding: .utf8) else {
      throw WorkspaceDocumentMutationError.invalidUTF8(file: url.path)
    }
    return WorkspaceDocumentSnapshot(
      url: url,
      text: text,
      digest: digest(data),
      identity: fileIdentity(for: url),
      existed: true
    )
  }

  func stillMatchesDisk() throws -> Bool {
    let existsNow = FileManager.default.fileExists(atPath: url.path)
    guard existsNow == existed else { return false }
    guard existsNow else { return true }
    let currentData = try Data(contentsOf: url, options: .mappedIfSafe)
    return Self.digest(currentData) == digest
  }

  private static func digest(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }

  private static func fileIdentity(for url: URL) -> WorkspaceDocumentFileIdentity? {
    let keys: Set<URLResourceKey> = [
      .fileSizeKey,
      .contentModificationDateKey,
      .attributeModificationDateKey,
      .fileResourceIdentifierKey,
      .generationIdentifierKey,
    ]
    guard let values = try? URL(fileURLWithPath: url.standardizedFileURL.path)
      .resourceValues(forKeys: keys)
    else {
      return nil
    }
    let fileResourceIdentifier = (values.fileResourceIdentifier as? NSData).map {
      Data(referencing: $0)
    }
    let generationIdentifier = (values.generationIdentifier as? NSData).map {
      Data(referencing: $0)
    }
    return WorkspaceDocumentFileIdentity(
      fileSize: values.fileSize,
      contentModificationDate: values.contentModificationDate,
      attributeModificationDate: values.attributeModificationDate,
      fileResourceIdentifier: fileResourceIdentifier,
      generationIdentifier: generationIdentifier
    )
  }
}

enum WorkspaceDocumentMutationEvent: Equatable, Sendable {
  case admitted(id: UUID, rootPath: String, resourcePaths: [String])
  case started(id: UUID, rootPath: String, resourcePaths: [String])
  case readSnapshot(id: UUID, path: String, byteCount: Int)
  case willCommit(id: UUID, path: String, byteCount: Int)
  case didCommit(id: UUID, path: String, byteCount: Int)
  case finished(id: UUID, rootPath: String, succeeded: Bool)
}

struct WorkspaceDocumentRootMutationSnapshot: Equatable, Sendable {
  let rootPath: String
  let epoch: UInt64
  let pendingCount: Int
  let activeCount: Int

  var isQuiescent: Bool {
    pendingCount == 0 && activeCount == 0
  }
}

struct WorkspaceDocumentMutationExecution: Sendable {
  typealias SafeWriter = @Sendable (
    _ replacement: String,
    _ url: URL,
    _ previousText: String
  ) throws -> Void

  let id: UUID
  let rootPath: String
  let resourcePaths: [String]
  fileprivate let eventHook: (@Sendable (WorkspaceDocumentMutationEvent) async -> Void)?

  func readSnapshot(at url: URL, allowMissing: Bool = false) async throws -> WorkspaceDocumentSnapshot {
    let authorizedURL = try authorizedURL(for: url)
    let snapshot = try WorkspaceDocumentSnapshot.read(at: authorizedURL, allowMissing: allowMissing)
    await eventHook?(.readSnapshot(
      id: id,
      path: snapshot.url.path,
      byteCount: snapshot.text.utf8.count
    ))
    return snapshot
  }

  func commit(
    _ replacement: String,
    over snapshot: WorkspaceDocumentSnapshot,
    writer: SafeWriter
  ) async throws {
    _ = try authorizedURL(for: snapshot.url)
    await eventHook?(.willCommit(
      id: id,
      path: snapshot.url.path,
      byteCount: replacement.utf8.count
    ))
    _ = try authorizedURL(for: snapshot.url)
    guard try snapshot.stillMatchesDisk() else {
      throw WorkspaceDocumentMutationError.fileChanged(file: snapshot.url.path)
    }
    try writer(replacement, snapshot.url, snapshot.text)
    await eventHook?(.didCommit(
      id: id,
      path: snapshot.url.path,
      byteCount: replacement.utf8.count
    ))
  }

  func authorizeDescendant(_ rawURL: URL, ofDeclaredDirectory rawDirectoryURL: URL) throws -> URL {
    let directoryPath = WorkspaceDocumentMutationLane.canonicalPath(rawDirectoryURL.path)
    guard resourcePaths.contains(directoryPath) else {
      throw WorkspaceDocumentMutationError.undeclaredResource(file: directoryPath)
    }
    let directoryPrefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
    let path = WorkspaceDocumentMutationLane.canonicalPath(rawURL.path)
    guard path == directoryPath || path.hasPrefix(directoryPrefix) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(file: path, root: directoryPath)
    }
    let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard path == rootPath || path.hasPrefix(rootPrefix) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(file: path, root: rootPath)
    }
    return URL(fileURLWithPath: path)
  }

  private func authorizedURL(for rawURL: URL) throws -> URL {
    let path = WorkspaceDocumentMutationLane.canonicalPath(rawURL.path)
    let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard path == rootPath || path.hasPrefix(rootPrefix) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(file: path, root: rootPath)
    }
    guard resourcePaths.contains(path) else {
      throw WorkspaceDocumentMutationError.undeclaredResource(file: path)
    }
    return URL(fileURLWithPath: path)
  }
}

actor WorkspaceDocumentMutationLane {
  typealias EventHook = @Sendable (WorkspaceDocumentMutationEvent) async -> Void

  private struct Tail: Sendable {
    let id: UUID
    let task: Task<Void, Never>
  }

  private struct RootState: Sendable {
    var epoch: UInt64 = 0
    var pendingCount = 0
    var activeCount = 0
  }

  private var tailsByResourcePath: [String: Tail] = [:]
  private var rootStates: [String: RootState] = [:]
  private var eventHookForTesting: EventHook?

  func setEventHookForTesting(_ hook: EventHook?) {
    eventHookForTesting = hook
  }

  func rootMutationSnapshot(rootPath rawRootPath: String) -> WorkspaceDocumentRootMutationSnapshot {
    let rootPath = Self.canonicalPath(rawRootPath)
    let state = rootStates[rootPath] ?? RootState()
    return WorkspaceDocumentRootMutationSnapshot(
      rootPath: rootPath,
      epoch: state.epoch,
      pendingCount: state.pendingCount,
      activeCount: state.activeCount
    )
  }

  func isCurrentAndQuiescent(_ snapshot: WorkspaceDocumentRootMutationSnapshot) -> Bool {
    let state = rootStates[snapshot.rootPath] ?? RootState()
    return state.epoch == snapshot.epoch
      && state.pendingCount == 0
      && state.activeCount == 0
  }

  func perform<Value: Sendable>(
    rootPath rawRootPath: String,
    resourcePaths rawResourcePaths: [String],
    priority: TaskPriority = .userInitiated,
    operation: @escaping @Sendable (WorkspaceDocumentMutationExecution) async throws -> Value
  ) async throws -> Value {
    let task: Task<Value, Error> = try enqueue(
      rootPath: rawRootPath,
      resourcePaths: rawResourcePaths,
      priority: priority,
      operation: operation
    )
    return try await task.value
  }

  func enqueue<Value: Sendable>(
    rootPath rawRootPath: String,
    resourcePaths rawResourcePaths: [String],
    priority: TaskPriority = .userInitiated,
    operation: @escaping @Sendable (WorkspaceDocumentMutationExecution) async throws -> Value
  ) throws -> Task<Value, Error> {
    let rootPath = Self.canonicalPath(rawRootPath)
    let resourcePaths = Array(Set(rawResourcePaths.map(Self.canonicalPath))).sorted()
    for path in resourcePaths where !Self.isPath(path, containedBy: rootPath) {
      throw WorkspaceDocumentMutationError.outsideCorpus(file: path, root: rootPath)
    }

    let id = UUID()
    var predecessorIDs: Set<UUID> = []
    let predecessors = tailsByResourcePath.compactMap { path, tail -> Task<Void, Never>? in
      guard resourcePaths.contains(where: { Self.resourcesOverlap(path, $0) }),
            predecessorIDs.insert(tail.id).inserted
      else {
        return nil
      }
      return tail.task
    }
    let hook = eventHookForTesting
    var rootState = rootStates[rootPath] ?? RootState()
    rootState.epoch &+= 1
    rootState.pendingCount += 1
    rootStates[rootPath] = rootState

    let execution = WorkspaceDocumentMutationExecution(
      id: id,
      rootPath: rootPath,
      resourcePaths: resourcePaths,
      eventHook: hook
    )
    let task = Task.detached(priority: priority) { [self, predecessors, execution] in
      await hook?(.admitted(id: id, rootPath: rootPath, resourcePaths: resourcePaths))
      for predecessor in predecessors {
        await predecessor.value
      }
      await operationStarted(rootPath: rootPath)
      await hook?(.started(id: id, rootPath: rootPath, resourcePaths: resourcePaths))
      do {
        let value = try await operation(execution)
        await operationFinished(id: id, rootPath: rootPath, resourcePaths: resourcePaths)
        await hook?(.finished(id: id, rootPath: rootPath, succeeded: true))
        return value
      } catch {
        await operationFinished(id: id, rootPath: rootPath, resourcePaths: resourcePaths)
        await hook?(.finished(id: id, rootPath: rootPath, succeeded: false))
        throw error
      }
    }
    let barrier = Task.detached(priority: priority) {
      _ = await task.result
    }
    for path in resourcePaths {
      tailsByResourcePath[path] = Tail(id: id, task: barrier)
    }
    return task
  }

  private func operationStarted(rootPath: String) {
    var state = rootStates[rootPath] ?? RootState()
    state.pendingCount = max(0, state.pendingCount - 1)
    state.activeCount += 1
    rootStates[rootPath] = state
  }

  private func operationFinished(id: UUID, rootPath: String, resourcePaths: [String]) {
    var state = rootStates[rootPath] ?? RootState()
    state.activeCount = max(0, state.activeCount - 1)
    state.epoch &+= 1
    rootStates[rootPath] = state
    for path in resourcePaths where tailsByResourcePath[path]?.id == id {
      tailsByResourcePath.removeValue(forKey: path)
    }
  }

  nonisolated static func canonicalPath(_ rawPath: String) -> String {
    URL(fileURLWithPath: rawPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  nonisolated private static func isPath(_ path: String, containedBy rootPath: String) -> Bool {
    path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
  }

  nonisolated private static func resourcesOverlap(_ lhs: String, _ rhs: String) -> Bool {
    isPath(lhs, containedBy: rhs) || isPath(rhs, containedBy: lhs)
  }
}
