import Foundation

public struct AIChatTokenUsage: Hashable, Codable, Sendable {
  public let inputTokens: Int
  public let cachedInputTokens: Int
  public let outputTokens: Int
  public let totalTokens: Int

  public init(
    inputTokens: Int = 0,
    cachedInputTokens: Int = 0,
    outputTokens: Int = 0,
    totalTokens: Int? = nil
  ) {
    self.inputTokens = max(0, inputTokens)
    self.cachedInputTokens = max(0, cachedInputTokens)
    self.outputTokens = max(0, outputTokens)
    self.totalTokens = max(
      0,
      totalTokens ?? (inputTokens + outputTokens)
    )
  }
}

public struct OpenOrgContextTelemetry: Hashable, Codable, Sendable {
  public enum Mode: String, Codable, Sendable {
    case recovery
    case delta
    case stateless
  }

  public let mode: Mode
  public let staticTokens: Int
  public let projectTokens: Int
  public let transcriptTokens: Int
  public let roomTokens: Int
  public let attachmentTokens: Int

  public init(
    mode: Mode,
    staticTokens: Int = 0,
    projectTokens: Int = 0,
    transcriptTokens: Int = 0,
    roomTokens: Int = 0,
    attachmentTokens: Int = 0
  ) {
    self.mode = mode
    self.staticTokens = max(0, staticTokens)
    self.projectTokens = max(0, projectTokens)
    self.transcriptTokens = max(0, transcriptTokens)
    self.roomTokens = max(0, roomTokens)
    self.attachmentTokens = max(0, attachmentTokens)
  }

  public var totalTokens: Int {
    staticTokens + projectTokens + transcriptTokens + roomTokens + attachmentTokens
  }
}

struct AIChatPersistentContextEnvelope: Sendable {
  let prompt: String?
  let sectionSnapshot: [String: String]
  let telemetry: OpenOrgContextTelemetry
}

enum AIChatContextBudget {
  static let statelessHistoryTokenBudget = 12_000
  static let sharedRoomSummaryTokenBudget = 1_000
  static let sharedRoomUnseenTokenBudget = 3_000
  static let recoveryTranscriptTokenBudget = 6_000

  static func estimatedTokens(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
  }

  static func estimatedAttachmentTokens(_ attachments: [OpenClawChatAttachment]) -> Int {
    attachments.reduce(0) { total, attachment in
      // Base64 provider payloads are roughly four bytes for every three source
      // bytes. The normal text estimator then maps those bytes to tokens.
      total + Int(ceil(Double(attachment.byteCount) / 3.0))
    }
  }

  static func boundedHistory(
    _ messages: [OpenClawChatMessage],
    tokenBudget: Int = statelessHistoryTokenBudget
  ) -> [OpenClawChatMessage] {
    let budget = max(1, tokenBudget)
    var selected: [OpenClawChatMessage] = []
    var used = 0
    for message in messages.reversed() {
      let messageTokens = estimatedTokens(message.content)
        + estimatedAttachmentTokens(message.attachments)
        + 8
      if selected.isEmpty, messageTokens > budget {
        let attachmentTokens = estimatedAttachmentTokens(message.attachments) + 8
        let contentBudget = max(1, budget - attachmentTokens)
        selected.append(replacingContent(
          in: message,
          with: boundedSuffix(message.content, tokenBudget: contentBudget)
        ))
        used = attachmentTokens + contentBudget
        break
      }
      guard used + messageTokens <= budget else { break }
      selected.append(message)
      used += messageTokens
      guard used < budget else { break }
    }
    return selected.reversed()
  }

  static func boundedSuffix(_ text: String, tokenBudget: Int) -> String {
    let byteBudget = max(4, tokenBudget * 4)
    guard text.utf8.count > byteBudget else { return text }
    let marker = "[Earlier content omitted]\n\n"
    let suffixBudget = max(1, byteBudget - marker.utf8.count)
    var suffix = String(text.suffix(suffixBudget))
    while suffix.utf8.count > suffixBudget, !suffix.isEmpty {
      suffix.removeFirst()
    }
    return marker + suffix
  }

  static func persistentEnvelope(
    fullPrompt: String,
    previousSections: [String: String]?,
    forceRecovery: Bool,
    includesTranscript: Bool,
    roomPrompt: String = "",
    attachments: [OpenClawChatAttachment] = []
  ) -> AIChatPersistentContextEnvelope {
    let sections = promptSections(fullPrompt)
    let snapshot = Dictionary(uniqueKeysWithValues: sections.map { ($0.key, $0.text) })
    let isRecovery = forceRecovery || previousSections == nil
    let included: [(key: String, text: String)]
    if isRecovery {
      included = sections.compactMap { section in
        guard includesTranscript || !isTranscriptSection(section.key) else { return nil }
        if isTranscriptSection(section.key) {
          return (
            section.key,
            boundedSuffix(section.text, tokenBudget: recoveryTranscriptTokenBudget)
          )
        }
        return section
      }
    } else {
      included = sections.filter { section in
        !isTranscriptSection(section.key) && previousSections?[section.key] != section.text
      }
    }

    let body = included.map(\.text).joined(separator: "\n\n---\n\n")
    let prompt: String?
    if body.isEmpty {
      prompt = nil
    } else if isRecovery {
      prompt = body
    } else {
      prompt = """
      OpenOrg workspace context delta

      Only the application-provided sections below changed since the previous successful turn in this runtime session. Keep all other previously supplied OpenOrg instructions and context.

      \(body)
      """
    }

    let telemetry = telemetry(
      mode: isRecovery ? .recovery : .delta,
      sections: included,
      roomPrompt: roomPrompt,
      attachments: attachments
    )
    return AIChatPersistentContextEnvelope(
      prompt: prompt,
      sectionSnapshot: snapshot,
      telemetry: telemetry
    )
  }

  static func statelessTelemetry(
    systemPrompt: String,
    history: [OpenClawChatMessage],
    roomPrompt: String = ""
  ) -> OpenOrgContextTelemetry {
    let sections = promptSections(systemPrompt)
    let historyTokens = history.reduce(0) { total, message in
      let contentTokens = message.content == roomPrompt ? 0 : estimatedTokens(message.content)
      return total + contentTokens + 8
    }
    let sectionTelemetry = telemetry(
      mode: .stateless,
      sections: sections,
      roomPrompt: roomPrompt,
      attachments: history.flatMap(\.attachments)
    )
    return OpenOrgContextTelemetry(
      mode: .stateless,
      staticTokens: sectionTelemetry.staticTokens,
      projectTokens: sectionTelemetry.projectTokens,
      transcriptTokens: historyTokens,
      roomTokens: sectionTelemetry.roomTokens,
      attachmentTokens: sectionTelemetry.attachmentTokens
    )
  }

  private static func promptSections(_ prompt: String) -> [(key: String, text: String)] {
    var occurrences: [String: Int] = [:]
    return prompt.components(separatedBy: "\n\n---\n\n").compactMap { raw in
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      let title = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "Context"
      let occurrence = occurrences[title, default: 0]
      occurrences[title] = occurrence + 1
      return ("\(title)#\(occurrence)", text)
    }
  }

  private static func isTranscriptSection(_ key: String) -> Bool {
    key.hasPrefix("Selected AI chat thread continuation#")
  }

  private static func isProjectSection(_ key: String) -> Bool {
    key.hasPrefix("Project context#")
      || key.hasPrefix("User-selected chat agent#")
      || key.hasPrefix("Current UI selection#")
      || key.hasPrefix("Selected org2 ")
      || key.hasPrefix("Computed backlinks#")
      || key.hasPrefix("Agenda snapshot#")
      || key.hasPrefix("Search context:#")
  }

  private static func telemetry(
    mode: OpenOrgContextTelemetry.Mode,
    sections: [(key: String, text: String)],
    roomPrompt: String,
    attachments: [OpenClawChatAttachment]
  ) -> OpenOrgContextTelemetry {
    var staticTokens = 0
    var projectTokens = 0
    var transcriptTokens = 0
    for section in sections {
      let tokens = estimatedTokens(section.text)
      if isTranscriptSection(section.key) {
        transcriptTokens += tokens
      } else if isProjectSection(section.key) {
        projectTokens += tokens
      } else {
        staticTokens += tokens
      }
    }
    return OpenOrgContextTelemetry(
      mode: mode,
      staticTokens: staticTokens,
      projectTokens: projectTokens,
      transcriptTokens: transcriptTokens,
      roomTokens: estimatedTokens(roomPrompt),
      attachmentTokens: estimatedAttachmentTokens(attachments)
    )
  }

  private static func replacingContent(
    in message: OpenClawChatMessage,
    with content: String
  ) -> OpenClawChatMessage {
    OpenClawChatMessage(
      id: message.id,
      role: message.role,
      content: content,
      attachments: message.attachments,
      createdAt: message.createdAt,
      changeSummary: message.changeSummary,
      responseTrace: message.responseTrace,
      sendFailure: message.sendFailure,
      deliveryStatus: message.deliveryStatus,
      deliveryKind: message.deliveryKind,
      authorRuntime: message.authorRuntime,
      authorLabel: message.authorLabel,
      authorAgentRef: message.authorAgentRef,
      source: message.source,
      audience: message.audience,
      targetRuntime: message.targetRuntime,
      authorDestinationID: message.authorDestinationID,
      audienceDestinationIDs: message.audienceDestinationIDs,
      targetDestinationID: message.targetDestinationID,
      isRoomDispatchCopy: message.isRoomDispatchCopy,
      roomRoundID: message.roomRoundID
    )
  }
}
