import Foundation

/// An extensible identifier for a source connector. Known kinds are conveniences rather than
/// an exhaustive enum so newer connector implementations can be persisted by older app builds.
public struct WorkspaceSourceKind: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let slack = WorkspaceSourceKind(rawValue: "slack")
  public static let notion = WorkspaceSourceKind(rawValue: "notion")
}

public enum WorkspaceSourceConnectionState: String, Codable, Sendable {
  case enabled
  case paused
}

/// Metadata used to locate credentials in a secure store. Secret material must never be placed
/// in a source connection record or its UserDefaults persistence envelope.
public struct WorkspaceCredentialReference: Codable, Equatable, Sendable {
  public var store: String
  public var service: String
  public var account: String

  public init(store: String = "keychain", service: String, account: String) {
    self.store = store
    self.service = service
    self.account = account
  }
}

public struct WorkspaceSourceActionableError: Codable, Equatable, Sendable {
  public var code: String
  public var message: String
  public var recoverySuggestion: String
  public var occurredAt: Date

  public init(code: String, message: String, recoverySuggestion: String, occurredAt: Date) {
    self.code = code
    self.message = message
    self.recoverySuggestion = recoverySuggestion
    self.occurredAt = occurredAt
  }
}

public struct WorkspaceSourceSyncStatus: Codable, Equatable, Sendable {
  public var lastCursor: String?
  public var lastSuccessAt: Date?
  public var nextRunAt: Date?
  public var bytesFetched: UInt64
  public var bytesStored: UInt64
  public var actionableError: WorkspaceSourceActionableError?

  public init(
    lastCursor: String? = nil,
    lastSuccessAt: Date? = nil,
    nextRunAt: Date? = nil,
    bytesFetched: UInt64 = 0,
    bytesStored: UInt64 = 0,
    actionableError: WorkspaceSourceActionableError? = nil
  ) {
    self.lastCursor = lastCursor
    self.lastSuccessAt = lastSuccessAt
    self.nextRunAt = nextRunAt
    self.bytesFetched = bytesFetched
    self.bytesStored = bytesStored
    self.actionableError = actionableError
  }
}

public struct WorkspaceSourceConnection: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var kind: WorkspaceSourceKind
  public var displayName: String
  public var state: WorkspaceSourceConnectionState
  public var scopes: [String]
  public var credentialReference: WorkspaceCredentialReference?
  public var syncStatus: WorkspaceSourceSyncStatus

  public init(
    id: UUID = UUID(),
    kind: WorkspaceSourceKind,
    displayName: String,
    state: WorkspaceSourceConnectionState = .enabled,
    scopes: [String] = [],
    credentialReference: WorkspaceCredentialReference? = nil,
    syncStatus: WorkspaceSourceSyncStatus = WorkspaceSourceSyncStatus()
  ) {
    self.id = id
    self.kind = kind
    self.displayName = displayName
    self.state = state
    self.scopes = scopes
    self.credentialReference = credentialReference
    self.syncStatus = syncStatus
  }
}

public enum WorkspaceExternalStorageAvailability: String, Codable, Sendable {
  case available
  case missingVolume
}

/// Persisted information for resolving a user-selected security-scoped directory. The bookmark
/// is intentionally opaque; resolving it and starting security-scoped access belongs to a later
/// app integration slice.
public struct WorkspaceExternalStorageRoot: Codable, Equatable, Sendable {
  public var bookmarkData: Data
  public var lastKnownPath: String
  public var volumeIdentifier: String?
  public var availability: WorkspaceExternalStorageAvailability

  public init(
    bookmarkData: Data,
    lastKnownPath: String,
    volumeIdentifier: String? = nil,
    availability: WorkspaceExternalStorageAvailability = .available
  ) {
    self.bookmarkData = bookmarkData
    self.lastKnownPath = lastKnownPath
    self.volumeIdentifier = volumeIdentifier
    self.availability = availability
  }
}

public enum WorkspaceSourceStorageRoot: Codable, Equatable, Sendable {
  case internalDefault
  case external(WorkspaceExternalStorageRoot)

  private enum CodingKeys: String, CodingKey { case kind, external }
  private enum Kind: String, Codable { case internalDefault, external }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .internalDefault:
      self = .internalDefault
    case .external:
      self = .external(try container.decode(WorkspaceExternalStorageRoot.self, forKey: .external))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .internalDefault:
      try container.encode(Kind.internalDefault, forKey: .kind)
    case .external(let root):
      try container.encode(Kind.external, forKey: .kind)
      try container.encode(root, forKey: .external)
    }
  }
}

public enum WorkspaceSourceRegistryError: Error, Equatable {
  case encodingFailed
}

/// Small durable registry for connector configuration and sync bookkeeping. It deliberately has
/// no scheduling, authentication, networking, bookmark resolution, or ingestion behavior.
public final class WorkspaceSourceConnectionRegistry {
  public static let defaultPersistenceKey = "org2.workspace.source-connections.v1"

  public private(set) var connections: [WorkspaceSourceConnection]
  public private(set) var storageRoot: WorkspaceSourceStorageRoot

  private let defaults: UserDefaults
  private let persistenceKey: String

  public init(
    defaults: UserDefaults = .standard,
    persistenceKey: String = WorkspaceSourceConnectionRegistry.defaultPersistenceKey
  ) {
    self.defaults = defaults
    self.persistenceKey = persistenceKey

    guard let data = defaults.data(forKey: persistenceKey),
          let envelope = try? JSONDecoder().decode(PersistenceEnvelope.self, from: data),
          envelope.schemaVersion == 1
    else {
      connections = []
      storageRoot = .internalDefault
      return
    }
    connections = envelope.connections
    storageRoot = envelope.storageRoot
  }

  public func upsert(_ connection: WorkspaceSourceConnection) throws {
    var updated = connections
    if let index = updated.firstIndex(where: { $0.id == connection.id }) {
      updated[index] = connection
    } else {
      updated.append(connection)
    }
    try persist(connections: updated, storageRoot: storageRoot)
    connections = updated
  }

  public func remove(id: UUID) throws {
    let updated = connections.filter { $0.id != id }
    try persist(connections: updated, storageRoot: storageRoot)
    connections = updated
  }

  public func setStorageRoot(_ root: WorkspaceSourceStorageRoot) throws {
    try persist(connections: connections, storageRoot: root)
    storageRoot = root
  }

  private func persist(
    connections: [WorkspaceSourceConnection],
    storageRoot: WorkspaceSourceStorageRoot
  ) throws {
    let envelope = PersistenceEnvelope(
      schemaVersion: 1,
      connections: connections,
      storageRoot: storageRoot
    )
    guard let data = try? JSONEncoder().encode(envelope) else {
      throw WorkspaceSourceRegistryError.encodingFailed
    }
    defaults.set(data, forKey: persistenceKey)
  }
}

private struct PersistenceEnvelope: Codable {
  var schemaVersion: Int
  var connections: [WorkspaceSourceConnection]
  var storageRoot: WorkspaceSourceStorageRoot
}
