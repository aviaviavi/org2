import CryptoKit
import Foundation

public struct OpenClawLocalEditWorkspaceContext: Equatable, Sendable {
  public let nodeDisplayName: String
  public let turnID: String

  public init(nodeDisplayName: String, turnID: String) {
    self.nodeDisplayName = nodeDisplayName
    self.turnID = turnID
  }

  public func systemPrompt() -> String {
    """
    Local Org2 edit node

    This chat turn can read and edit the active Mac app corpus through the paired node named "\(nodeDisplayName)". Its turnId is "\(turnID)".

    For corpus reads and writes, use the OpenClaw `nodes` tool with action `invoke`, node `\(nodeDisplayName)`, and one of these typed commands. Do not edit corpus files with Gateway filesystem or shell tools during this turn.

    1. Read effective local text, including any unsaved editor draft:
       invokeCommand: \(OpenClawLocalEditBroker.readCommand)
       invokeParamsJson: {"turnId":"\(turnID)","path":"relative/path.org2"}
    2. Preview one or more whole-file replacements. Existing files require the exact sha256 returned by read:
       invokeCommand: \(OpenClawLocalEditBroker.previewCommand)
       invokeParamsJson: {"turnId":"\(turnID)","edits":[{"path":"relative/path.org2","expectedSha256":"<read sha256>","replacementText":"<complete replacement text>"}]}
       To create a file, omit expectedSha256 and set "createsFile":true.
    3. Apply the exact preview only after preview succeeds:
       invokeCommand: \(OpenClawLocalEditBroker.applyCommand)
       invokeParamsJson: {"turnId":"\(turnID)","previewId":"<previewId>"}

    Always read before replacing an existing file. Preserve the complete effective document, including unsaved user text. If a stale-document error occurs, read again and rebuild the replacement. The apply result is the authoritative change set for this response.
    """
  }
}

public enum OpenClawLocalEditDocumentOrigin: String, Codable, Sendable {
  case disk
  case editor
  case missing
}

public struct OpenClawLocalEditDocument: Equatable, Sendable {
  public let relativePath: String
  public let text: String
  public let origin: OpenClawLocalEditDocumentOrigin

  public init(
    relativePath: String,
    text: String,
    origin: OpenClawLocalEditDocumentOrigin
  ) {
    self.relativePath = relativePath
    self.text = text
    self.origin = origin
  }

  public var sha256: String {
    OpenClawLocalEditBroker.sha256(text)
  }
}

public struct OpenClawLocalEditReplacement: Equatable, Sendable {
  public let relativePath: String
  public let expectedSHA256: String?
  public let replacementText: String
  public let createsFile: Bool

  public init(
    relativePath: String,
    expectedSHA256: String?,
    replacementText: String,
    createsFile: Bool
  ) {
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
    self.replacementText = replacementText
    self.createsFile = createsFile
  }
}

public struct OpenClawLocalEditApplyResult: Equatable, Sendable {
  public let summary: OpenClawCorpusChangeSummary

  public init(summary: OpenClawCorpusChangeSummary) {
    self.summary = summary
  }
}

public struct OpenClawLocalEditCommandResult: Equatable, Sendable {
  public let ok: Bool
  public let payloadJSON: String?
  public let errorCode: String?
  public let errorMessage: String?

  public init(
    ok: Bool,
    payloadJSON: String? = nil,
    errorCode: String? = nil,
    errorMessage: String? = nil
  ) {
    self.ok = ok
    self.payloadJSON = payloadJSON
    self.errorCode = errorCode
    self.errorMessage = errorMessage
  }
}

public enum OpenClawLocalEditError: LocalizedError, Equatable, Sendable {
  case invalidRequest(String)
  case inactiveTurn
  case unsupportedCommand(String)
  case staleDocument(String)
  case missingDocument(String)
  case existingDocument(String)
  case expiredPreview
  case oversizedRequest

  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let detail):
      return "Invalid local edit request: \(detail)"
    case .inactiveTurn:
      return "This local edit turn is no longer active."
    case .unsupportedCommand(let command):
      return "Unsupported local edit command: \(command)"
    case .staleDocument(let path):
      return "\(path) changed after it was read. Read it again before previewing or applying an edit."
    case .missingDocument(let path):
      return "\(path) does not exist. Set createsFile to true to preview creating it."
    case .existingDocument(let path):
      return "\(path) already exists and cannot be created as a new file."
    case .expiredPreview:
      return "The local edit preview expired. Preview the edit again before applying it."
    case .oversizedRequest:
      return "The local edit request is too large."
    }
  }
}

/// Owns the preview/apply transaction boundary for edits executed by the Mac app.
///
/// The broker deliberately uses whole-file replacements. The agent must read the
/// effective local document first, including an unsaved editor draft when one is
/// active, and then preview a replacement against that exact SHA-256. Applying a
/// preview rechecks every document before any writes begin.
public actor OpenClawLocalEditBroker {
  public static let readCommand = "org2.workspace.read"
  public static let previewCommand = "org2.workspace.patch.preview"
  public static let applyCommand = "org2.workspace.patch.apply"
  public static let commands = [readCommand, previewCommand, applyCommand]

  public typealias DocumentReader =
    @MainActor @Sendable (String, String) throws -> OpenClawLocalEditDocument
  public typealias ReplacementApplier =
    @MainActor @Sendable (
      String,
      [OpenClawLocalEditReplacement]
    ) async throws -> OpenClawLocalEditApplyResult

  private struct ReadRequest: Decodable {
    let turnID: String
    let path: String

    enum CodingKeys: String, CodingKey {
      case turnID = "turnId"
      case path
    }
  }

  private struct PreviewRequest: Decodable {
    let turnID: String
    let edits: [Edit]

    struct Edit: Decodable {
      let path: String
      let expectedSHA256: String?
      let replacementText: String
      let createsFile: Bool

      enum CodingKeys: String, CodingKey {
        case path
        case expectedSHA256 = "expectedSha256"
        case replacementText
        case createsFile
      }

      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        expectedSHA256 = try container.decodeIfPresent(String.self, forKey: .expectedSHA256)
        replacementText = try container.decode(String.self, forKey: .replacementText)
        createsFile = try container.decodeIfPresent(Bool.self, forKey: .createsFile) ?? false
      }
    }

    enum CodingKeys: String, CodingKey {
      case turnID = "turnId"
      case edits
    }
  }

  private struct ApplyRequest: Decodable {
    let turnID: String
    let previewID: String

    enum CodingKeys: String, CodingKey {
      case turnID = "turnId"
      case previewID = "previewId"
    }
  }

  private struct Preview {
    let id: String
    let turnID: String
    let createdAt: Date
    let replacements: [OpenClawLocalEditReplacement]
    let documentsByPath: [String: OpenClawLocalEditDocument]
    let summary: OpenClawCorpusChangeSummary
  }

  private struct AppliedDocumentState {
    let originalText: String?
    var finalText: String?
  }

  private let documentReader: DocumentReader
  private let replacementApplier: ReplacementApplier
  private var activeTurnIDs = Set<String>()
  private var previews: [String: Preview] = [:]
  private var appliedDocumentsByTurnID: [String: [String: AppliedDocumentState]] = [:]

  private static let maximumEditCount = 8
  private static let maximumDocumentBytes = 2_000_000
  private static let maximumTotalReplacementBytes = 4_000_000
  private static let previewLifetime: TimeInterval = 30 * 60

  public init(
    documentReader: @escaping DocumentReader,
    replacementApplier: @escaping ReplacementApplier
  ) {
    self.documentReader = documentReader
    self.replacementApplier = replacementApplier
  }

  public func beginTurn(_ turnID: String) {
    let normalized = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    activeTurnIDs.insert(normalized)
    removeExpiredPreviews()
  }

  public func endTurn(_ turnID: String) {
    activeTurnIDs.remove(turnID)
    previews = previews.filter { $0.value.turnID != turnID }
    appliedDocumentsByTurnID.removeValue(forKey: turnID)
  }

  public func consumeChangeSummary(for turnID: String) -> OpenClawCorpusChangeSummary? {
    guard let documents = appliedDocumentsByTurnID.removeValue(forKey: turnID)
    else {
      return nil
    }

    let changes = documents.compactMap { path, document in
      Self.fileChange(
        path: path,
        before: document.originalText,
        after: document.finalText
      )
    }.sorted {
      $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }
    guard !changes.isEmpty else {
      return nil
    }
    return OpenClawCorpusChangeSummary(files: changes)
  }

  private func recordAppliedDocuments(from preview: Preview) {
    var appliedDocuments = appliedDocumentsByTurnID[preview.turnID] ?? [:]
    for replacement in preview.replacements {
      if var existing = appliedDocuments[replacement.relativePath] {
        existing.finalText = replacement.replacementText
        appliedDocuments[replacement.relativePath] = existing
      } else if let document = preview.documentsByPath[replacement.relativePath] {
        appliedDocuments[replacement.relativePath] = AppliedDocumentState(
          originalText: document.origin == .missing ? nil : document.text,
          finalText: replacement.replacementText
        )
      }
    }
    appliedDocumentsByTurnID[preview.turnID] = appliedDocuments
  }

  public func handle(command: String, paramsJSON: String?) async -> OpenClawLocalEditCommandResult {
    do {
      switch command {
      case Self.readCommand:
        return try await handleRead(paramsJSON)
      case Self.previewCommand:
        return try await handlePreview(paramsJSON)
      case Self.applyCommand:
        return try await handleApply(paramsJSON)
      default:
        throw OpenClawLocalEditError.unsupportedCommand(command)
      }
    } catch let error as OpenClawLocalEditError {
      return OpenClawLocalEditCommandResult(
        ok: false,
        errorCode: Self.errorCode(error),
        errorMessage: error.localizedDescription
      )
    } catch {
      return OpenClawLocalEditCommandResult(
        ok: false,
        errorCode: "LOCAL_EDIT_FAILED",
        errorMessage: error.localizedDescription
      )
    }
  }

  private func handleRead(_ paramsJSON: String?) async throws -> OpenClawLocalEditCommandResult {
    let request: ReadRequest = try decode(paramsJSON)
    try requireActiveTurn(request.turnID)
    let document = try await documentReader(request.turnID, request.path)
    guard document.text.utf8.count <= Self.maximumDocumentBytes else {
      throw OpenClawLocalEditError.oversizedRequest
    }
    return try successJSON([
      "path": document.relativePath,
      "text": document.text,
      "sha256": document.sha256,
      "origin": document.origin.rawValue,
      "exists": document.origin != .missing
    ])
  }

  private func handlePreview(_ paramsJSON: String?) async throws -> OpenClawLocalEditCommandResult {
    let request: PreviewRequest = try decode(paramsJSON)
    try requireActiveTurn(request.turnID)
    guard !request.edits.isEmpty,
          request.edits.count <= Self.maximumEditCount,
          request.edits.reduce(0, { $0 + $1.replacementText.utf8.count }) <= Self.maximumTotalReplacementBytes
    else {
      throw OpenClawLocalEditError.oversizedRequest
    }

    var replacements: [OpenClawLocalEditReplacement] = []
    var changes: [OpenClawCorpusFileChange] = []
    var documentsByPath: [String: OpenClawLocalEditDocument] = [:]
    var seenPaths = Set<String>()

    for edit in request.edits {
      let document = try await documentReader(request.turnID, edit.path)
      guard seenPaths.insert(document.relativePath).inserted else {
        throw OpenClawLocalEditError.invalidRequest("duplicate path \(document.relativePath)")
      }
      guard edit.replacementText.utf8.count <= Self.maximumDocumentBytes else {
        throw OpenClawLocalEditError.oversizedRequest
      }

      if edit.createsFile {
        guard document.origin == .missing else {
          throw OpenClawLocalEditError.existingDocument(document.relativePath)
        }
      } else {
        guard document.origin != .missing else {
          throw OpenClawLocalEditError.missingDocument(document.relativePath)
        }
        guard let expectedSHA256 = edit.expectedSHA256?
          .trimmingCharacters(in: .whitespacesAndNewlines),
          !expectedSHA256.isEmpty
        else {
          throw OpenClawLocalEditError.invalidRequest(
            "expectedSha256 is required for \(document.relativePath)"
          )
        }
        guard expectedSHA256 == document.sha256 else {
          throw OpenClawLocalEditError.staleDocument(document.relativePath)
        }
      }

      documentsByPath[document.relativePath] = document
      let replacement = OpenClawLocalEditReplacement(
        relativePath: document.relativePath,
        expectedSHA256: edit.createsFile ? nil : document.sha256,
        replacementText: edit.replacementText,
        createsFile: edit.createsFile
      )
      replacements.append(replacement)
      if let change = Self.fileChange(
        path: document.relativePath,
        before: edit.createsFile ? nil : document.text,
        after: edit.replacementText
      ) {
        changes.append(change)
      }
    }

    let summary = OpenClawCorpusChangeSummary(files: changes)
    let preview = Preview(
      id: UUID().uuidString.lowercased(),
      turnID: request.turnID,
      createdAt: Date(),
      replacements: replacements,
      documentsByPath: documentsByPath,
      summary: summary
    )
    previews[preview.id] = preview
    trimPreviews()

    return try successJSON([
      "previewId": preview.id,
      "turnId": preview.turnID,
      "title": preview.summary.title,
      "changes": preview.summary.files.map(Self.changeDictionary)
    ])
  }

  private func handleApply(_ paramsJSON: String?) async throws -> OpenClawLocalEditCommandResult {
    let request: ApplyRequest = try decode(paramsJSON)
    try requireActiveTurn(request.turnID)
    removeExpiredPreviews()
    guard let preview = previews[request.previewID],
          preview.turnID == request.turnID
    else {
      throw OpenClawLocalEditError.expiredPreview
    }

    for replacement in preview.replacements {
      let document = try await documentReader(request.turnID, replacement.relativePath)
      if replacement.createsFile {
        guard document.origin == .missing else {
          throw OpenClawLocalEditError.staleDocument(replacement.relativePath)
        }
      } else {
        guard document.origin != .missing,
              document.sha256 == replacement.expectedSHA256
        else {
          throw OpenClawLocalEditError.staleDocument(replacement.relativePath)
        }
      }
    }

    let result = try await replacementApplier(request.turnID, preview.replacements)
    previews.removeValue(forKey: preview.id)
    recordAppliedDocuments(from: preview)
    return try successJSON([
      "applied": true,
      "turnId": request.turnID,
      "title": result.summary.title,
      "changes": result.summary.files.map(Self.changeDictionary)
    ])
  }

  private func requireActiveTurn(_ turnID: String) throws {
    guard activeTurnIDs.contains(turnID) else {
      throw OpenClawLocalEditError.inactiveTurn
    }
  }

  private func decode<T: Decodable>(_ paramsJSON: String?) throws -> T {
    guard let paramsJSON,
          let data = paramsJSON.data(using: .utf8)
    else {
      throw OpenClawLocalEditError.invalidRequest("paramsJSON is required")
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw OpenClawLocalEditError.invalidRequest(error.localizedDescription)
    }
  }

  private func successJSON(_ value: [String: Any]) throws -> OpenClawLocalEditCommandResult {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard let json = String(data: data, encoding: .utf8) else {
      throw OpenClawLocalEditError.invalidRequest("could not encode result")
    }
    return OpenClawLocalEditCommandResult(ok: true, payloadJSON: json)
  }

  private func removeExpiredPreviews(now: Date = Date()) {
    previews = previews.filter {
      now.timeIntervalSince($0.value.createdAt) <= Self.previewLifetime
        && activeTurnIDs.contains($0.value.turnID)
    }
  }

  private func trimPreviews() {
    guard previews.count > 32 else { return }
    let retainedIDs = previews.values
      .sorted { $0.createdAt > $1.createdAt }
      .prefix(32)
      .map(\.id)
    previews = previews.filter { Set(retainedIDs).contains($0.key) }
  }

  private static func errorCode(_ error: OpenClawLocalEditError) -> String {
    switch error {
    case .invalidRequest: "INVALID_REQUEST"
    case .inactiveTurn: "INACTIVE_TURN"
    case .unsupportedCommand: "UNSUPPORTED_COMMAND"
    case .staleDocument: "STALE_DOCUMENT"
    case .missingDocument: "MISSING_DOCUMENT"
    case .existingDocument: "EXISTING_DOCUMENT"
    case .expiredPreview: "EXPIRED_PREVIEW"
    case .oversizedRequest: "REQUEST_TOO_LARGE"
    }
  }

  nonisolated static func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  nonisolated private static func changeDictionary(
    _ change: OpenClawCorpusFileChange
  ) -> [String: Any] {
    [
      "path": change.relativePath,
      "status": change.status.rawValue,
      "insertions": change.insertions,
      "deletions": change.deletions
    ]
  }

  nonisolated static func fileChange(
    path: String,
    before: String?,
    after: String?
  ) -> OpenClawCorpusFileChange? {
    switch (before, after) {
    case let (before?, after?):
      guard before != after else { return nil }
      let counts = lineChangeCounts(before: before, after: after)
      return OpenClawCorpusFileChange(
        relativePath: path,
        status: .modified,
        insertions: counts.insertions,
        deletions: counts.deletions
      )
    case let (nil, after?):
      return OpenClawCorpusFileChange(
        relativePath: path,
        status: .created,
        insertions: textLines(after).count,
        deletions: 0
      )
    case let (before?, nil):
      return OpenClawCorpusFileChange(
        relativePath: path,
        status: .deleted,
        insertions: 0,
        deletions: textLines(before).count
      )
    case (nil, nil):
      return nil
    }
  }

  nonisolated private static func lineChangeCounts(
    before oldText: String,
    after newText: String
  ) -> (insertions: Int, deletions: Int) {
    let oldLines = textLines(oldText)
    let newLines = textLines(newText)
    guard !oldLines.isEmpty || !newLines.isEmpty else { return (0, 0) }
    let canRunExactDiff = oldLines.count <= 1_000_000 / max(1, newLines.count)
    let commonLineCount = canRunExactDiff
      ? longestCommonSubsequenceCount(oldLines, newLines)
      : prefixSuffixCommonLineCount(oldLines, newLines)
    return (
      insertions: max(0, newLines.count - commonLineCount),
      deletions: max(0, oldLines.count - commonLineCount)
    )
  }

  nonisolated private static func textLines(_ text: String) -> [String] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    guard !normalized.isEmpty else { return [] }
    var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if normalized.hasSuffix("\n") { lines.removeLast() }
    return lines
  }

  nonisolated private static func longestCommonSubsequenceCount(
    _ oldLines: [String],
    _ newLines: [String]
  ) -> Int {
    guard !oldLines.isEmpty, !newLines.isEmpty else { return 0 }
    var previous = Array(repeating: 0, count: newLines.count + 1)
    var current = previous
    for oldLine in oldLines {
      current[0] = 0
      for index in newLines.indices {
        current[index + 1] = oldLine == newLines[index]
          ? previous[index] + 1
          : max(previous[index + 1], current[index])
      }
      swap(&previous, &current)
    }
    return previous[newLines.count]
  }

  nonisolated private static func prefixSuffixCommonLineCount(
    _ oldLines: [String],
    _ newLines: [String]
  ) -> Int {
    let sharedLimit = min(oldLines.count, newLines.count)
    var prefixCount = 0
    while prefixCount < sharedLimit, oldLines[prefixCount] == newLines[prefixCount] {
      prefixCount += 1
    }
    var suffixCount = 0
    while suffixCount < sharedLimit - prefixCount,
          oldLines[oldLines.count - 1 - suffixCount] == newLines[newLines.count - 1 - suffixCount] {
      suffixCount += 1
    }
    return prefixCount + suffixCount
  }
}
