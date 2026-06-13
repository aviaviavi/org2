import Foundation
import Security

public struct OpenClawGatewaySettings: Sendable {
  public let endpoint: URL
  public let bearerToken: String?
  public let chatCompletionsEnabled: Bool?

  public init(endpoint: URL, bearerToken: String?, chatCompletionsEnabled: Bool?) {
    self.endpoint = endpoint
    self.bearerToken = bearerToken
    self.chatCompletionsEnabled = chatCompletionsEnabled
  }

  public static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    configURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".clawdbot/clawdbot.json"),
    userEndpoint: String? = nil,
    userBearerToken: String? = nil
  ) -> OpenClawGatewaySettings {
    let config = ClawdbotConfig.load(from: configURL)
    let endpoint = endpointURL(environment: environment, config: config, userEndpoint: userEndpoint)
    let bearerToken = clean(userBearerToken)
      ?? explicitBearerToken(environment: environment)
      ?? config?.gateway?.auth?.preferredBearerToken

    return OpenClawGatewaySettings(
      endpoint: endpoint,
      bearerToken: bearerToken?.isEmpty == false ? bearerToken : nil,
      chatCompletionsEnabled: config?.gateway?.http?.endpoints?.chatCompletions?.enabled
    )
  }

  public static func normalizedEndpointString(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
    return chatCompletionsEndpoint(from: url).absoluteString
  }

  private static func endpointURL(environment: [String: String], config: ClawdbotConfig?, userEndpoint: String?) -> URL {
    if let raw = clean(userEndpoint), let url = URL(string: raw) {
      return chatCompletionsEndpoint(from: url)
    }

    if let raw = environment["ORG2_WORKSPACE_OPENCLAW_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !raw.isEmpty,
       let url = URL(string: raw) {
      return chatCompletionsEndpoint(from: url)
    }

    let rawPort = environment["CLAWDBOT_GATEWAY_PORT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let port = rawPort.flatMap(Int.init) ?? config?.gateway?.port ?? 18789
    return URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
  }

  private static func chatCompletionsEndpoint(from url: URL) -> URL {
    if url.path.hasSuffix("/v1/chat/completions") {
      return url
    }
    return url
      .appendingPathComponent("v1")
      .appendingPathComponent("chat")
      .appendingPathComponent("completions")
  }

  private static func explicitBearerToken(environment: [String: String]) -> String? {
    for key in ["ORG2_WORKSPACE_OPENCLAW_TOKEN", "CLAWDBOT_GATEWAY_PASSWORD", "CLAWDBOT_GATEWAY_TOKEN"] {
      let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      if value?.isEmpty == false {
        return value
      }
    }
    return nil
  }

  private static func clean(_ raw: String?) -> String? {
    let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }
}

public struct OpenClawChatClient: Sendable {
  public let settings: OpenClawGatewaySettings
  private let session: URLSession

  public init(settings: OpenClawGatewaySettings = .resolve()) {
    self.settings = settings
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 600
    configuration.timeoutIntervalForResource = 600
    self.session = URLSession(configuration: configuration)
  }

  public func send(
    messages: [OpenClawChatMessage],
    agentID: String,
    sessionKey: String,
    workspaceContext: OpenClawWorkspaceContext? = nil
  ) async throws -> String {
    let agentHeaderValue = Self.openClawAgentHeaderValue(for: agentID)
    let requestBody = OpenAIChatCompletionRequest(
      model: Self.openClawModelName(for: agentID),
      user: sessionKey,
      messages: requestMessages(from: messages, workspaceContext: workspaceContext)
    )

    var request = URLRequest(url: settings.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(agentHeaderValue, forHTTPHeaderField: "x-clawdbot-agent-id")
    request.setValue(sessionKey, forHTTPHeaderField: "x-clawdbot-session-key")
    if let bearerToken = settings.bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONEncoder().encode(requestBody)

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw OpenClawChatError.invalidResponse
      }
      guard (200..<300).contains(http.statusCode) else {
        throw OpenClawChatError.httpStatus(http.statusCode, message: decodeErrorMessage(from: data))
      }

      let payload = try JSONDecoder().decode(OpenClawChatCompletionPayload.self, from: data)
      let text = payload.assistantText
      guard !text.isEmpty else {
        throw OpenClawChatError.emptyResponse
      }
      return text
    } catch let error as OpenClawChatError {
      throw error
    } catch {
      throw OpenClawChatError.transport(error.localizedDescription)
    }
  }

  static func openClawModelName(for agentID: String) -> String {
    let agentID = normalizedOpenClawAgentID(agentID)
    guard !agentID.isEmpty else { return "openclaw" }
    return "openclaw/\(agentID)"
  }

  static func openClawAgentHeaderValue(for agentID: String) -> String {
    let agentID = normalizedOpenClawAgentID(agentID)
    return agentID.isEmpty ? "main" : agentID
  }

  private static func normalizedOpenClawAgentID(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value == "openclaw" || value == "clawdbot" {
      return ""
    }
    if value.hasPrefix("openclaw/") {
      value.removeFirst("openclaw/".count)
    } else if value.hasPrefix("clawdbot:") {
      value.removeFirst("clawdbot:".count)
    } else if value.hasPrefix("clawdbot/") {
      value.removeFirst("clawdbot/".count)
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func requestMessages(
    from messages: [OpenClawChatMessage],
    workspaceContext: OpenClawWorkspaceContext?
  ) -> [OpenAIChatMessage] {
    var output = [
      OpenAIChatMessage(
        role: "system",
        content: "You are OpenClaw working with the user's org2 workspace. Use the provided org2 workspace context, configured remote paths, and existing org2 tooling. Keep answers grounded in the corpus and cite source files/lines when acting on workspace facts."
      )
    ]

    if let workspaceContext {
      output.append(OpenAIChatMessage(role: "system", content: workspaceContext.systemPrompt()))
    }

    output += messages.suffix(16).map { message in
      OpenAIChatMessage(role: message.role.rawValue, content: message.content)
    }
    return output
  }

  private func decodeErrorMessage(from data: Data) -> String? {
    guard let payload = try? JSONDecoder().decode(OpenAIErrorPayload.self, from: data) else {
      return nil
    }
    return payload.error.message
  }
}

public struct OpenClawWorkspaceContext: Sendable {
  public let localCorpusRoot: String?
  public let remoteCorpusRoot: String?
  public let selectedSurface: String
  public let selectedLocation: WorkspaceLocation?
  public let selectedEntrySource: EntrySource?
  public let backlinks: BacklinksPayload?
  public let agenda: AgendaPayload?
  public let searchQuery: String
  public let searchResults: [SearchResult]

  public init(
    localCorpusRoot: String?,
    remoteCorpusRoot: String?,
    selectedSurface: String,
    selectedLocation: WorkspaceLocation?,
    selectedEntrySource: EntrySource?,
    backlinks: BacklinksPayload?,
    agenda: AgendaPayload?,
    searchQuery: String,
    searchResults: [SearchResult]
  ) {
    self.localCorpusRoot = Self.cleanRoot(localCorpusRoot)
    self.remoteCorpusRoot = Self.cleanRoot(remoteCorpusRoot)
    self.selectedSurface = selectedSurface
    self.selectedLocation = selectedLocation
    self.selectedEntrySource = selectedEntrySource
    self.backlinks = backlinks
    self.agenda = agenda
    self.searchQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    self.searchResults = searchResults
  }

  public func systemPrompt() -> String {
    var sections: [String] = []
    sections.append("""
    Org2 workspace operating context

    Remote org2 root for OpenClaw: \(remoteCorpusRoot ?? "NOT CONFIGURED")
    Local app corpus root: \(localCorpusRoot ?? "not selected")

    If a remote org2 root is configured, use that path for shell/filesystem work. If it is not configured and you need to read or edit files, ask the user to configure the remote org2 root before making filesystem assumptions.
    """)

    sections.append("""
    Org2 working rules

    Org2 is a plain-text, org-mode-inspired knowledge workspace. Files are usually .org2 or .org. Headings use leading stars; TODO state, priority, and tags live on headings. Planning metadata uses SCHEDULED, DEADLINE, and CLOSED lines. Stable node identity lives in :PROPERTIES: drawers using :ID:. Links commonly use [[id:<uuid>][label]].

    Use existing org2 tooling when available instead of inventing a parser:
    - org2 agenda --dir <root> --recursive --from <date> --to <date> --format json --workload
    - org2 search <query> --dir <root> --limit 50 --context 1 --format json
    - org2 backlinks --id <uuid> --dir <root> --recursive --format json
    - org2 roam, org2 query, org2 todo, org2 capture for graph, lookup, mutation, and capture workflows

    Do not write generated Backlinks sections into note files. Treat backlinks as computed views. Preserve the org2 plaintext format and cite file paths plus line numbers for concrete claims.
    """)

    if let selectedLocation {
      sections.append(formatSelectedLocation(selectedLocation))
    }

    if let selectedEntrySource {
      sections.append(formatSelectedSource(selectedEntrySource))
    }

    if let backlinks, !backlinks.backlinks.isEmpty {
      sections.append(formatBacklinks(backlinks))
    }

    if let agenda {
      sections.append(formatAgenda(agenda))
    }

    if !searchResults.isEmpty {
      sections.append(formatSearchResults())
    }

    return sections.joined(separator: "\n\n---\n\n")
  }

  private func formatSelectedLocation(_ location: WorkspaceLocation) -> String {
    var lines = [
      "Current UI selection",
      "- Surface: \(selectedSurface)",
      "- Title: \(location.title)",
      "- Detail: \(location.subtitle)",
      "- Source: \(mappedPath(location.file)):\(location.lineForEditor)"
    ]
    if let id = location.idValue, !id.isEmpty {
      lines.append("- ID: \(id)")
    }
    return lines.joined(separator: "\n")
  }

  private func formatSelectedSource(_ source: EntrySource) -> String {
    let kind = source.isSubtree ? "entry subtree" : "page/range"
    let text = Self.limited(source.text, maxCharacters: 12_000)
    return """
    Selected org2 \(kind)
    Source: \(mappedPath(source.file)):\(source.displayRange)

    ~~~org
    \(text)
    ~~~
    """
  }

  private func formatBacklinks(_ payload: BacklinksPayload) -> String {
    let rows = payload.backlinks.prefix(16).map { backlink in
      let context = Org2Display.cleanInline(backlink.context)
      return "- \(Org2Display.cleanInline(backlink.srcTitle)) — \(mappedPath(backlink.file)):\(backlink.lineForEditor)\n  Context: \(context)"
    }
    let suffix = payload.backlinks.count > rows.count ? "\n- ... \(payload.backlinks.count - rows.count) more backlinks not included in this prompt" : ""
    return "Computed backlinks for selected node\n" + rows.joined(separator: "\n") + suffix
  }

  private func formatAgenda(_ agenda: AgendaPayload) -> String {
    let overdue = agenda.overdue.flatMap(\.items).prefix(8).map { formatAgendaItem($0) }
    let today = agenda.days.first(where: { $0.date == agenda.range.start })?.items.prefix(12).map { formatAgendaItem($0) } ?? []
    let upcoming = agenda.days
      .filter { $0.date != agenda.range.start }
      .flatMap(\.items)
      .prefix(12)
      .map { formatAgendaItem($0) }

    var lines = [
      "Agenda snapshot",
      "Range: \(agenda.range.start) to \(agenda.range.end)",
      "Counts: total \(agenda.totalItemCount), today \(agenda.todayItemCount), upcoming \(agenda.upcomingItemCount)"
    ]
    if !overdue.isEmpty {
      lines.append("\nOverdue:\n" + overdue.joined(separator: "\n"))
    }
    if !today.isEmpty {
      lines.append("\nToday:\n" + today.joined(separator: "\n"))
    }
    if !upcoming.isEmpty {
      lines.append("\nUpcoming:\n" + upcoming.joined(separator: "\n"))
    }
    return lines.joined(separator: "\n")
  }

  private func formatAgendaItem(_ item: AgendaItem) -> String {
    let status = item.todo ?? "TASK"
    let title = Org2Display.cleanInline(item.headline)
    let timing = [item.kind, item.time].compactMap { $0 }.joined(separator: " ")
    let id = item.idValue.map { " id:\(Org2Display.shortID($0))" } ?? ""
    return "- [\(status)] \(title) — \(timing) — \(mappedPath(item.file)):\(item.lineForEditor)\(id)"
  }

  private func formatSearchResults() -> String {
    let query = searchQuery.isEmpty ? "recent search" : searchQuery
    let rows = searchResults.prefix(12).map { result in
      "- \(Org2Display.cleanInline(result.title)) — \(mappedPath(result.file)):\(result.lineForEditor)\n  Snippet: \(Org2Display.cleanInline(result.snippet))"
    }
    let suffix = searchResults.count > rows.count ? "\n- ... \(searchResults.count - rows.count) more search results not included in this prompt" : ""
    return "Search context: \(query)\n" + rows.joined(separator: "\n") + suffix
  }

  private func mappedPath(_ path: String) -> String {
    guard let localCorpusRoot, let remoteCorpusRoot else { return path }
    if path == localCorpusRoot {
      return remoteCorpusRoot
    }
    if path.hasPrefix(localCorpusRoot + "/") {
      let relative = String(path.dropFirst(localCorpusRoot.count + 1))
      return remoteCorpusRoot + "/" + relative
    }
    return path
  }

  private static func cleanRoot(_ raw: String?) -> String? {
    let root = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var root, !root.isEmpty else { return nil }
    while root.count > 1 && root.hasSuffix("/") {
      root.removeLast()
    }
    return root
  }

  private static func limited(_ raw: String, maxCharacters: Int) -> String {
    guard raw.count > maxCharacters else { return raw }
    let index = raw.index(raw.startIndex, offsetBy: maxCharacters)
    return String(raw[..<index]) + "\n...[truncated]"
  }
}

public enum OpenClawChatError: LocalizedError, Equatable {
  case invalidResponse
  case httpStatus(Int, message: String?)
  case emptyResponse
  case transport(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "OpenClaw returned an invalid response."
    case .httpStatus(401, _):
      return "OpenClaw gateway rejected the request. Check gateway auth for the local Clawdbot gateway."
    case .httpStatus(404, _):
      return "OpenClaw chat endpoint is not enabled on the local gateway. Enable gateway.http.endpoints.chatCompletions.enabled in Clawdbot config and restart the gateway."
    case .httpStatus(let status, let message):
      if let message, !message.isEmpty {
        return "OpenClaw gateway returned HTTP \(status): \(message)"
      }
      return "OpenClaw gateway returned HTTP \(status)."
    case .emptyResponse:
      return "OpenClaw returned an empty response."
    case .transport(let message):
      return "Could not reach OpenClaw gateway: \(message)"
    }
  }
}

private struct OpenAIChatCompletionRequest: Encodable {
  let model: String
  let user: String
  let messages: [OpenAIChatMessage]
}

private struct OpenAIChatMessage: Encodable {
  let role: String
  let content: String
}

private struct OpenAIErrorPayload: Decodable {
  let error: ErrorBody

  struct ErrorBody: Decodable {
    let message: String
  }
}

private struct ClawdbotConfig: Decodable {
  let gateway: Gateway?

  static func load(from url: URL) -> ClawdbotConfig? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(ClawdbotConfig.self, from: data)
  }

  struct Gateway: Decodable {
    let port: Int?
    let auth: Auth?
    let http: HTTP?
  }

  struct Auth: Decodable {
    let mode: String?
    let token: String?
    let password: String?

    var preferredBearerToken: String? {
      if mode == "password", password?.isEmpty == false {
        return password
      }
      if token?.isEmpty == false {
        return token
      }
      return password?.isEmpty == false ? password : nil
    }
  }

  struct HTTP: Decodable {
    let endpoints: Endpoints?
  }

  struct Endpoints: Decodable {
    let chatCompletions: ChatCompletions?
  }

  struct ChatCompletions: Decodable {
    let enabled: Bool?
  }
}

public enum OpenClawKeychain {
  public static let service = "Org2Workspace.OpenClawGateway"
  public static let account = "bearerToken"

  public static func containsToken() -> Bool {
    var query: [String: Any] = baseQuery
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status == errSecSuccess
  }

  public static func readToken() -> String? {
    var query: [String: Any] = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let token = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return token.isEmpty ? nil : token
  }

  public static func saveToken(_ token: String) throws {
    let data = Data(token.utf8)
    var query = baseQuery
    query[kSecValueData as String] = data
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard updateStatus == errSecSuccess else { throw OpenClawKeychainError.status(updateStatus) }
      return
    }
    guard status == errSecSuccess else { throw OpenClawKeychainError.status(status) }
  }

  public static func deleteToken() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw OpenClawKeychainError.status(status)
    }
  }

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }
}

public enum OpenClawKeychainError: LocalizedError, Equatable {
  case status(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .status(let status):
      return "Keychain operation failed with status \(status)."
    }
  }
}
