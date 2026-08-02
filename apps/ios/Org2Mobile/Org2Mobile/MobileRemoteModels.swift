import Foundation

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

struct MobileRemoteErrorEnvelope: Codable {
  let error: String
}
