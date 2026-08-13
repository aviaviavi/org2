import Foundation

public enum ExternalThreadHarness: String, Codable, CaseIterable, Identifiable, Sendable {
  case codex

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .codex: "Codex"
    }
  }

  public var systemImage: String {
    switch self {
    case .codex: "chevron.left.forwardslash.chevron.right"
    }
  }
}

public struct ExternalThreadSummary: Codable, Hashable, Identifiable, Sendable {
  public let harness: ExternalThreadHarness
  public let externalID: String
  public let title: String
  public let preview: String?
  public let workspacePath: String?
  public let source: String?
  public let modelProvider: String?
  public let createdAt: Date
  public let updatedAt: Date
  public let status: String
  public let isPinned: Bool

  public var id: String { "\(harness.rawValue):\(externalID)" }

  public init(
    harness: ExternalThreadHarness,
    externalID: String,
    title: String,
    preview: String?,
    workspacePath: String?,
    source: String?,
    modelProvider: String?,
    createdAt: Date,
    updatedAt: Date,
    status: String,
    isPinned: Bool
  ) {
    self.harness = harness
    self.externalID = externalID
    self.title = title
    self.preview = preview
    self.workspacePath = workspacePath
    self.source = source
    self.modelProvider = modelProvider
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.status = status
    self.isPinned = isPinned
  }
}

public struct ExternalThreadMessage: Codable, Hashable, Identifiable, Sendable {
  public enum Role: String, Codable, Sendable {
    case user
    case assistant
  }

  public let id: String
  public let role: Role
  public let content: String
  public let createdAt: Date

  public init(id: String, role: Role, content: String, createdAt: Date) {
    self.id = id
    self.role = role
    self.content = content
    self.createdAt = createdAt
  }
}

public struct ExternalThreadDetail: Codable, Hashable, Sendable {
  public let thread: ExternalThreadSummary
  public let messages: [ExternalThreadMessage]

  public init(thread: ExternalThreadSummary, messages: [ExternalThreadMessage]) {
    self.thread = thread
    self.messages = messages
  }
}

public struct ExternalThreadList: Codable, Hashable, Sendable {
  public let threads: [ExternalThreadSummary]

  public init(threads: [ExternalThreadSummary]) {
    self.threads = threads
  }
}
