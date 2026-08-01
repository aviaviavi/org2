import Foundation

enum MobileRemoteWire {
  static let version = 1
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
