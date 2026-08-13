import Foundation

enum MobileRemoteNotification {
  static let replyCategory = "org2.thread.reply"
  static let pendingReplyThreadIDKey = "Org2Mobile.remote.pendingReplyThreadID.v1"
}

enum MobileRemoteWire {
  static let version = 2
  static let defaultPort: UInt16 = 48_922

  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

struct MobileRemoteServerStatus: Codable, Hashable {
  let protocolVersion: Int
  let serverName: String
  let corpusName: String?
  let threadCount: Int
  let runningThreadCount: Int
}

struct MobileRemotePairRequest: Codable {
  let code: String
  let deviceName: String
}

struct MobileRemotePairResponse: Codable {
  let protocolVersion: Int
  let serverName: String
  let deviceID: UUID
  let accessToken: String
}

struct MobileRemoteCreateThreadRequest: Codable {
  let runtime: String
}

struct MobileRemoteSendMessageRequest: Codable {
  let content: String
  let attachments: [MobileRemoteAttachment]
  let delivery: String?
}

struct MobileRemoteAttachment: Codable, Hashable, Identifiable {
  let id = UUID()
  let fileName: String
  let mimeType: String
  let data: Data

  init(fileName: String, mimeType: String, data: Data) {
    self.fileName = fileName
    self.mimeType = mimeType
    self.data = data
  }

  enum CodingKeys: String, CodingKey {
    case fileName
    case mimeType
    case data
  }
}

struct MobileRemoteFilePreviewRequest: Codable, Hashable {
  let path: String
  let line: Int?
}

struct MobileRemoteFilePreview: Codable, Hashable {
  let title: String
  let relativePath: String
  let startLine: Int
  let highlightedLine: Int?
  let content: String
}

struct MobileRemoteModelOption: Codable, Hashable, Identifiable {
  let id: String
  let label: String
  let detail: String?
  let isDefault: Bool
}

struct MobileRemoteThreadConfiguration: Codable, Hashable {
  let threadID: UUID
  let model: String?
  let models: [MobileRemoteModelOption]
  let reasoningEffort: String?
  let reasoningOptions: [MobileRemoteReasoningOption]
  let defaultReasoningEffort: String?
}

struct MobileRemoteUpdateThreadConfigurationRequest: Codable {
  let setting: String
  let value: String?

  init(model: String?) {
    setting = "model"
    value = model
  }

  init(reasoningEffort: String?) {
    setting = "reasoning"
    value = reasoningEffort
  }
}

struct MobileRemoteReasoningOption: Codable, Hashable, Identifiable {
  let id: String
  let label: String
  let detail: String?
}

struct MobileRemoteUpdateThreadStateRequest: Codable {
  let isPinned: Bool?
  let isSettled: Bool?
}

struct MobileRemoteThreadList: Codable {
  let threads: [MobileRemoteThreadSummary]
}

struct MobileRemoteThreadSummary: Codable, Hashable, Identifiable {
  let id: UUID
  let title: String
  let runtime: String
  let model: String?
  let updatedAt: Date
  let isSettled: Bool
  let isPinned: Bool
  let isRunning: Bool
  let unreadMessageCount: Int
  let preview: String?
  let latestAssistantMessageID: UUID?
  let latestAssistantPreview: String?
}

struct MobileRemoteThreadDetail: Codable, Hashable {
  let thread: MobileRemoteThreadSummary
  let messages: [MobileRemoteChatMessage]
  let streamingReply: String
  let reasoning: String
  let activities: [MobileRemoteActivity]
  let connectionState: String
  let connectionDetail: String?
}

struct MobileRemoteChatMessage: Codable, Hashable, Identifiable {
  let id: UUID
  let role: String
  let content: String
  let attachmentNames: [String]
  let createdAt: Date
  let deliveryStatus: String
  let deliveryKind: String?
  let sendFailure: String?
}

struct MobileRemoteActivity: Codable, Hashable, Identifiable {
  let id: String
  let title: String
  let detail: String?
  let status: String
  let updatedAt: Date
}

struct MobileRemoteMutationResponse: Codable {
  let accepted: Bool
  let threadID: UUID?
}

struct MobileRemoteWorkspaceSnapshot: Codable, Hashable {
  let updatedAt: Date
  let agenda: [MobileRemoteAgendaItem]
  let approvals: [MobileRemoteApprovalItem]
  let workflows: [MobileRemoteWorkflowItem]
}

struct MobileRemoteAgendaItem: Codable, Hashable, Identifiable {
  let id: String
  let title: String
  let todo: String
  let file: String
  let line: Int
  let date: String
  let kind: String
  let tags: [String]
  let body: String
  let priority: String?
  let time: String?
  let effort: String?

  var localEntry: AgendaEntry {
    let normalizedKind: OrgPlanningKind
    switch kind.lowercased() {
    case let value where value.contains("deadline"):
      normalizedKind = .deadline
    case let value where value.contains("timestamp"):
      normalizedKind = .timestamp
    default:
      normalizedKind = .scheduled
    }
    return AgendaEntry(
      id: id,
      title: title,
      todo: todo,
      file: file,
      line: line,
      date: date,
      kind: normalizedKind,
      tags: tags,
      body: body
    )
  }
}

struct MobileRemoteApprovalItem: Codable, Hashable, Identifiable {
  let id: String
  let title: String
  let status: String
  let todo: String?
  let level: Int?
  let file: String
  let line: Int
  let sourceID: String?
  let properties: [String: String]
  let body: String
  let tags: [String]
  let kind: String?
  let runID: String?
  let approvalID: String?
  let fingerprint: String?
  let action: String?
  let riskClass: String?
  let requestedRole: String?
  let requestedFrom: String?
  let requestedAt: String?
  let runGoal: String?
  let runStatus: String?
  let runDecisionEffect: String?

  var localEntry: ApprovalEntry {
    ApprovalEntry(
      id: id,
      title: title,
      status: status,
      todo: todo,
      level: level,
      file: file,
      line: line,
      sourceID: sourceID,
      properties: properties,
      body: body,
      tags: tags,
      kind: kind,
      runID: runID,
      approvalID: approvalID,
      fingerprint: fingerprint,
      action: action,
      riskClass: riskClass
    )
  }
}

struct MobileRemoteWorkflowInput: Codable, Hashable, Identifiable {
  let id: String
  let description: String
  let required: Bool
  let defaultValue: String?
}

struct MobileRemoteWorkflowItem: Codable, Hashable, Identifiable {
  let id: String
  let title: String
  let description: String
  let state: String
  let riskClass: String
  let scheduleSummary: String
  let file: String
  let agentRef: String?
  let goalRef: String?
  let inputs: [MobileRemoteWorkflowInput]
}

struct MobileRemoteAgendaStatusRequest: Codable {
  let status: String
}

struct MobileRemoteApprovalDecisionRequest: Codable {
  let decision: String
  let note: String?
  let endStatus: String?
}

struct MobileRemoteWorkflowStateRequest: Codable {
  let state: String
}

struct MobileRemoteWorkflowRunRequest: Codable {
  let inputs: [String: String]
}

enum MobileExternalThreadHarness: String, Codable, CaseIterable, Identifiable {
  case codex

  var id: String { rawValue }

  var title: String {
    switch self {
    case .codex: "Codex"
    }
  }

  var systemImage: String {
    switch self {
    case .codex: "chevron.left.forwardslash.chevron.right"
    }
  }
}

struct MobileExternalThreadSummary: Codable, Hashable, Identifiable {
  let harness: MobileExternalThreadHarness
  let externalID: String
  let title: String
  let preview: String?
  let workspacePath: String?
  let source: String?
  let modelProvider: String?
  let createdAt: Date
  let updatedAt: Date
  let status: String
  let isPinned: Bool

  var id: String { "\(harness.rawValue):\(externalID)" }
}

struct MobileExternalThreadMessage: Codable, Hashable, Identifiable {
  enum Role: String, Codable {
    case user
    case assistant
  }

  let id: String
  let role: Role
  let content: String
  let createdAt: Date
}

struct MobileExternalThreadDetail: Codable, Hashable {
  let thread: MobileExternalThreadSummary
  let messages: [MobileExternalThreadMessage]
}

struct MobileExternalThreadList: Codable, Hashable {
  let threads: [MobileExternalThreadSummary]
}

struct MobileRemoteErrorEnvelope: Codable {
  let error: String
}
