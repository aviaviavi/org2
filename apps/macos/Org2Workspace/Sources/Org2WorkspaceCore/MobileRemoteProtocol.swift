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

  public init(
    protocolVersion: Int = MobileRemoteProtocol.version,
    serverName: String,
    corpusName: String?,
    threadCount: Int,
    runningThreadCount: Int
  ) {
    self.protocolVersion = protocolVersion
    self.serverName = serverName
    self.corpusName = corpusName
    self.threadCount = threadCount
    self.runningThreadCount = runningThreadCount
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

  public init(runtime: String) {
    self.runtime = runtime
  }
}

public struct MobileRemoteSendMessageRequest: Codable, Hashable, Sendable {
  public let content: String
  public let attachments: [MobileRemoteAttachment]

  public init(content: String, attachments: [MobileRemoteAttachment] = []) {
    self.content = content
    self.attachments = attachments
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
  public let model: String?
  public let updatedAt: Date
  public let isSettled: Bool
  public let isPinned: Bool
  public let isRunning: Bool
  public let unreadMessageCount: Int
  public let preview: String?

  public init(
    id: UUID,
    title: String,
    runtime: String,
    model: String?,
    updatedAt: Date,
    isSettled: Bool,
    isPinned: Bool,
    isRunning: Bool,
    unreadMessageCount: Int,
    preview: String?
  ) {
    self.id = id
    self.title = title
    self.runtime = runtime
    self.model = model
    self.updatedAt = updatedAt
    self.isSettled = isSettled
    self.isPinned = isPinned
    self.isRunning = isRunning
    self.unreadMessageCount = unreadMessageCount
    self.preview = preview
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
  public let sendFailure: String?

  public init(
    id: UUID,
    role: String,
    content: String,
    attachmentNames: [String],
    createdAt: Date,
    deliveryStatus: String,
    sendFailure: String?
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.attachmentNames = attachmentNames
    self.createdAt = createdAt
    self.deliveryStatus = deliveryStatus
    self.sendFailure = sendFailure
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

public struct MobileRemoteMutationResponse: Codable, Hashable, Sendable {
  public let accepted: Bool
  public let threadID: UUID?

  public init(accepted: Bool, threadID: UUID? = nil) {
    self.accepted = accepted
    self.threadID = threadID
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
