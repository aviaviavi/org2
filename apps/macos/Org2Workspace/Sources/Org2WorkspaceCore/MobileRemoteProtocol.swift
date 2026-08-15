import Foundation

public enum MobileRemoteProtocol {
  public static let version = 2
  public static let defaultPort: UInt16 = 48_922

  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

public struct MobileRemoteServerStatus: Codable, Hashable, Sendable {
  public let protocolVersion: Int
  public let serverName: String
  public let corpusName: String?
  public let threadCount: Int
  public let runningThreadCount: Int
  public let aiChatDestinations: [MobileRemoteAIDestination]?

  public init(
    protocolVersion: Int = MobileRemoteProtocol.version,
    serverName: String,
    corpusName: String?,
    threadCount: Int,
    runningThreadCount: Int,
    aiChatDestinations: [MobileRemoteAIDestination]? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.serverName = serverName
    self.corpusName = corpusName
    self.threadCount = threadCount
    self.runningThreadCount = runningThreadCount
    self.aiChatDestinations = aiChatDestinations
  }
}

public struct MobileRemoteAIDestination: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let mention: String
  public let runtime: String

  public init(id: String, name: String, mention: String, runtime: String) {
    self.id = id
    self.name = name
    self.mention = mention
    self.runtime = runtime
  }
}

public struct MobileRemotePairRequest: Codable, Hashable, Sendable {
  public let code: String
  public let deviceName: String

  public init(code: String, deviceName: String) {
    self.code = code
    self.deviceName = deviceName
  }
}

public struct MobileRemotePairResponse: Codable, Hashable, Sendable {
  public let protocolVersion: Int
  public let serverName: String
  public let deviceID: UUID
  public let accessToken: String

  public init(
    protocolVersion: Int = MobileRemoteProtocol.version,
    serverName: String,
    deviceID: UUID,
    accessToken: String
  ) {
    self.protocolVersion = protocolVersion
    self.serverName = serverName
    self.deviceID = deviceID
    self.accessToken = accessToken
  }
}

public struct MobileRemoteCreateThreadRequest: Codable, Hashable, Sendable {
  public let runtime: String
  public let destinationID: String?

  public init(runtime: String, destinationID: String? = nil) {
    self.runtime = runtime
    self.destinationID = destinationID
  }
}

public struct MobileRemoteSendMessageRequest: Codable, Hashable, Sendable {
  public let content: String
  public let attachments: [MobileRemoteAttachment]
  public let delivery: String?

  public init(
    content: String,
    attachments: [MobileRemoteAttachment] = [],
    delivery: String? = nil
  ) {
    self.content = content
    self.attachments = attachments
    self.delivery = delivery
  }
}

public struct MobileRemoteAttachment: Codable, Hashable, Sendable {
  public let fileName: String
  public let mimeType: String
  public let data: Data

  public init(fileName: String, mimeType: String, data: Data) {
    self.fileName = fileName
    self.mimeType = mimeType
    self.data = data
  }
}

public struct MobileRemoteFilePreviewRequest: Codable, Hashable, Sendable {
  public let path: String
  public let line: Int?

  public init(path: String, line: Int? = nil) {
    self.path = path
    self.line = line
  }
}

public struct MobileRemoteFilePreview: Codable, Hashable, Sendable {
  public let title: String
  public let relativePath: String
  public let startLine: Int
  public let highlightedLine: Int?
  public let content: String

  public init(
    title: String,
    relativePath: String,
    startLine: Int,
    highlightedLine: Int?,
    content: String
  ) {
    self.title = title
    self.relativePath = relativePath
    self.startLine = startLine
    self.highlightedLine = highlightedLine
    self.content = content
  }
}

public struct MobileRemoteModelOption: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let detail: String?
  public let isDefault: Bool

  public init(id: String, label: String, detail: String?, isDefault: Bool) {
    self.id = id
    self.label = label
    self.detail = detail
    self.isDefault = isDefault
  }
}

public struct MobileRemoteThreadConfiguration: Codable, Hashable, Sendable {
  public let threadID: UUID
  public let model: String?
  public let models: [MobileRemoteModelOption]
  public let reasoningEffort: String?
  public let reasoningOptions: [MobileRemoteReasoningOption]
  public let defaultReasoningEffort: String?

  public init(
    threadID: UUID,
    model: String?,
    models: [MobileRemoteModelOption],
    reasoningEffort: String?,
    reasoningOptions: [MobileRemoteReasoningOption],
    defaultReasoningEffort: String?
  ) {
    self.threadID = threadID
    self.model = model
    self.models = models
    self.reasoningEffort = reasoningEffort
    self.reasoningOptions = reasoningOptions
    self.defaultReasoningEffort = defaultReasoningEffort
  }
}

public struct MobileRemoteUpdateThreadConfigurationRequest: Codable, Hashable, Sendable {
  public let setting: String
  public let value: String?

  public init(model: String?) {
    setting = "model"
    value = model
  }

  public init(reasoningEffort: String?) {
    setting = "reasoning"
    value = reasoningEffort
  }
}

public struct MobileRemoteReasoningOption: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let detail: String?

  public init(id: String, label: String, detail: String?) {
    self.id = id
    self.label = label
    self.detail = detail
  }
}

public struct MobileRemoteUpdateThreadStateRequest: Codable, Hashable, Sendable {
  public let isPinned: Bool?
  public let isSettled: Bool?

  public init(isPinned: Bool? = nil, isSettled: Bool? = nil) {
    self.isPinned = isPinned
    self.isSettled = isSettled
  }
}

public struct MobileRemoteThreadList: Codable, Hashable, Sendable {
  public let threads: [MobileRemoteThreadSummary]

  public init(threads: [MobileRemoteThreadSummary]) {
    self.threads = threads
  }
}

public struct MobileRemoteThreadSummary: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let runtime: String
  public let destinationID: String?
  public let destinationName: String?
  public let isSharedRoom: Bool
  public let model: String?
  public let updatedAt: Date
  public let isSettled: Bool
  public let isPinned: Bool
  public let isRunning: Bool
  public let unreadMessageCount: Int
  public let preview: String?
  public let latestAssistantMessageID: UUID?
  public let latestAssistantPreview: String?

  public init(
    id: UUID,
    title: String,
    runtime: String,
    destinationID: String? = nil,
    destinationName: String? = nil,
    isSharedRoom: Bool = false,
    model: String?,
    updatedAt: Date,
    isSettled: Bool,
    isPinned: Bool,
    isRunning: Bool,
    unreadMessageCount: Int,
    preview: String?,
    latestAssistantMessageID: UUID? = nil,
    latestAssistantPreview: String? = nil
  ) {
    self.id = id
    self.title = title
    self.runtime = runtime
    self.destinationID = destinationID
    self.destinationName = destinationName
    self.isSharedRoom = isSharedRoom
    self.model = model
    self.updatedAt = updatedAt
    self.isSettled = isSettled
    self.isPinned = isPinned
    self.isRunning = isRunning
    self.unreadMessageCount = unreadMessageCount
    self.preview = preview
    self.latestAssistantMessageID = latestAssistantMessageID
    self.latestAssistantPreview = latestAssistantPreview
  }
}

public struct MobileRemoteThreadDetail: Codable, Hashable, Sendable {
  public let thread: MobileRemoteThreadSummary
  public let messages: [MobileRemoteChatMessage]
  public let streamingReply: String
  public let reasoning: String
  public let activities: [MobileRemoteActivity]
  public let connectionState: String
  public let connectionDetail: String?

  public init(
    thread: MobileRemoteThreadSummary,
    messages: [MobileRemoteChatMessage],
    streamingReply: String,
    reasoning: String,
    activities: [MobileRemoteActivity],
    connectionState: String,
    connectionDetail: String?
  ) {
    self.thread = thread
    self.messages = messages
    self.streamingReply = streamingReply
    self.reasoning = reasoning
    self.activities = activities
    self.connectionState = connectionState
    self.connectionDetail = connectionDetail
  }
}

public struct MobileRemoteChatMessage: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let role: String
  public let content: String
  public let attachmentNames: [String]
  public let createdAt: Date
  public let deliveryStatus: String
  public let deliveryKind: String?
  public let sendFailure: String?
  public let authorRuntime: String?
  public let authorDestinationID: String?
  public let authorDestinationName: String?
  public let audience: String?
  public let audienceDestinationNames: [String]?
  public let isRoomDispatchCopy: Bool
  public let roomRoundID: UUID?

  public init(
    id: UUID,
    role: String,
    content: String,
    attachmentNames: [String],
    createdAt: Date,
    deliveryStatus: String,
    deliveryKind: String? = nil,
    sendFailure: String?,
    authorRuntime: String? = nil,
    authorDestinationID: String? = nil,
    authorDestinationName: String? = nil,
    audience: String? = nil,
    audienceDestinationNames: [String]? = nil,
    isRoomDispatchCopy: Bool = false,
    roomRoundID: UUID? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.attachmentNames = attachmentNames
    self.createdAt = createdAt
    self.deliveryStatus = deliveryStatus
    self.deliveryKind = deliveryKind
    self.sendFailure = sendFailure
    self.authorRuntime = authorRuntime
    self.authorDestinationID = authorDestinationID
    self.authorDestinationName = authorDestinationName
    self.audience = audience
    self.audienceDestinationNames = audienceDestinationNames
    self.isRoomDispatchCopy = isRoomDispatchCopy
    self.roomRoundID = roomRoundID
  }
}

public struct MobileRemoteActivity: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let detail: String?
  public let status: String
  public let updatedAt: Date

  public init(id: String, title: String, detail: String?, status: String, updatedAt: Date) {
    self.id = id
    self.title = title
    self.detail = detail
    self.status = status
    self.updatedAt = updatedAt
  }
}

public enum MobileRemoteActivityPresentation {
  public static func items(from activities: [OpenClawRunActivity]) -> [MobileRemoteActivity] {
    OpenClawActivityFeed.items(from: activities).map { item in
      MobileRemoteActivity(
        id: item.id,
        title: item.title,
        detail: item.detail,
        status: item.status.rawValue,
        updatedAt: item.updatedAt
      )
    }
  }
}

public struct MobileRemoteMutationResponse: Codable, Hashable, Sendable {
  public let accepted: Bool
  public let threadID: UUID?

  public init(accepted: Bool, threadID: UUID? = nil) {
    self.accepted = accepted
    self.threadID = threadID
  }
}

public struct MobileRemoteWorkspaceSnapshot: Codable, Hashable, Sendable {
  public let updatedAt: Date
  public let agenda: [MobileRemoteAgendaItem]
  public let approvals: [MobileRemoteApprovalItem]
  public let workflows: [MobileRemoteWorkflowItem]

  public init(
    updatedAt: Date = Date(),
    agenda: [MobileRemoteAgendaItem],
    approvals: [MobileRemoteApprovalItem],
    workflows: [MobileRemoteWorkflowItem]
  ) {
    self.updatedAt = updatedAt
    self.agenda = agenda
    self.approvals = approvals
    self.workflows = workflows
  }
}

public struct MobileRemoteAgendaItem: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let todo: String
  public let file: String
  public let line: Int
  public let date: String
  public let kind: String
  public let tags: [String]
  public let body: String
  public let priority: String?
  public let time: String?
  public let effort: String?

  public init(
    id: String,
    title: String,
    todo: String,
    file: String,
    line: Int,
    date: String,
    kind: String,
    tags: [String],
    body: String,
    priority: String?,
    time: String?,
    effort: String?
  ) {
    self.id = id
    self.title = title
    self.todo = todo
    self.file = file
    self.line = line
    self.date = date
    self.kind = kind
    self.tags = tags
    self.body = body
    self.priority = priority
    self.time = time
    self.effort = effort
  }
}

public struct MobileRemoteApprovalItem: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let status: String
  public let todo: String?
  public let level: Int?
  public let file: String
  public let line: Int
  public let sourceID: String?
  public let properties: [String: String]
  public let body: String
  public let tags: [String]
  public let kind: String?
  public let runID: String?
  public let approvalID: String?
  public let fingerprint: String?
  public let action: String?
  public let riskClass: String?
  public let requestedRole: String?
  public let requestedFrom: String?
  public let requestedAt: String?
  public let runGoal: String?
  public let runStatus: String?
  public let runDecisionEffect: String?

  public init(
    id: String,
    title: String,
    status: String,
    todo: String?,
    level: Int?,
    file: String,
    line: Int,
    sourceID: String?,
    properties: [String: String],
    body: String,
    tags: [String],
    kind: String?,
    runID: String?,
    approvalID: String?,
    fingerprint: String?,
    action: String?,
    riskClass: String?,
    requestedRole: String?,
    requestedFrom: String?,
    requestedAt: String?,
    runGoal: String?,
    runStatus: String?,
    runDecisionEffect: String?
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.todo = todo
    self.level = level
    self.file = file
    self.line = line
    self.sourceID = sourceID
    self.properties = properties
    self.body = body
    self.tags = tags
    self.kind = kind
    self.runID = runID
    self.approvalID = approvalID
    self.fingerprint = fingerprint
    self.action = action
    self.riskClass = riskClass
    self.requestedRole = requestedRole
    self.requestedFrom = requestedFrom
    self.requestedAt = requestedAt
    self.runGoal = runGoal
    self.runStatus = runStatus
    self.runDecisionEffect = runDecisionEffect
  }
}

public struct MobileRemoteWorkflowInput: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let description: String
  public let required: Bool
  public let defaultValue: String?

  public init(id: String, description: String, required: Bool, defaultValue: String?) {
    self.id = id
    self.description = description
    self.required = required
    self.defaultValue = defaultValue
  }
}

public struct MobileRemoteWorkflowItem: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let description: String
  public let state: String
  public let riskClass: String
  public let scheduleSummary: String
  public let file: String
  public let agentRef: String?
  public let goalRef: String?
  public let inputs: [MobileRemoteWorkflowInput]

  public init(
    id: String,
    title: String,
    description: String,
    state: String,
    riskClass: String,
    scheduleSummary: String,
    file: String,
    agentRef: String?,
    goalRef: String?,
    inputs: [MobileRemoteWorkflowInput]
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.state = state
    self.riskClass = riskClass
    self.scheduleSummary = scheduleSummary
    self.file = file
    self.agentRef = agentRef
    self.goalRef = goalRef
    self.inputs = inputs
  }
}

public struct MobileRemoteAgendaStatusRequest: Codable, Hashable, Sendable {
  public let status: String

  public init(status: String) {
    self.status = status
  }
}

public struct MobileRemoteApprovalDecisionRequest: Codable, Hashable, Sendable {
  public let decision: String
  public let note: String?
  public let endStatus: String?

  public init(decision: String, note: String? = nil, endStatus: String? = nil) {
    self.decision = decision
    self.note = note
    self.endStatus = endStatus
  }
}

public struct MobileRemoteWorkflowStateRequest: Codable, Hashable, Sendable {
  public let state: String

  public init(state: String) {
    self.state = state
  }
}

public struct MobileRemoteWorkflowRunRequest: Codable, Hashable, Sendable {
  public let inputs: [String: String]

  public init(inputs: [String: String]) {
    self.inputs = inputs
  }
}

public struct MobileRemoteErrorEnvelope: Codable, Hashable, Sendable {
  public let error: String

  public init(error: String) {
    self.error = error
  }
}

public struct MobileRemoteHTTPRequest: Hashable, Sendable {
  public let method: String
  public let path: String
  public let headers: [String: String]
  public let body: Data

  public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
    self.method = method.uppercased()
    self.path = path
    self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    self.body = body
  }

  public var bearerToken: String? {
    guard let value = headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          value.lowercased().hasPrefix("bearer ")
    else {
      return nil
    }
    return String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try MobileRemoteProtocol.decoder().decode(type, from: body)
  }
}

public struct MobileRemoteHTTPResponse: Hashable, Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }

  public static func json<T: Encodable>(_ value: T, statusCode: Int = 200) -> MobileRemoteHTTPResponse {
    do {
      return MobileRemoteHTTPResponse(
        statusCode: statusCode,
        headers: ["Content-Type": "application/json; charset=utf-8"],
        body: try MobileRemoteProtocol.encoder().encode(value)
      )
    } catch {
      return .error("Could not encode the response.", statusCode: 500)
    }
  }

  public static func error(_ message: String, statusCode: Int) -> MobileRemoteHTTPResponse {
    .json(MobileRemoteErrorEnvelope(error: message), statusCode: statusCode)
  }
}
