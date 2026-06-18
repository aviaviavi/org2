import Combine
import Foundation

@MainActor
final class CorpusStore: ObservableObject {
  @Published private(set) var rootURL: URL?
  @Published private(set) var documents: [OrgDocument] = []
  @Published private(set) var agenda: [AgendaEntry] = []
  @Published private(set) var approvals: [ApprovalEntry] = []
  @Published private(set) var outbox: [OutboxEntry] = []
  @Published var isLoading = false
  @Published var errorMessage: String?
  @Published var statusMessage: String?
  @Published var isDocumentPickerPresented = false

  private let bookmarkKey = "org2.mobile.corpusBookmark"
  private let mobileInboxFilename = "mobile-inbox.org2"
  private let mobileInboxAssetsDirectory = "mobile-inbox-assets"

  var corpusName: String {
    rootURL?.lastPathComponent ?? "No corpus"
  }

  func restoreCorpus() async {
    #if DEBUG
    if let debugCorpusPath = ProcessInfo.processInfo.environment["ORG2_DEBUG_CORPUS_PATH"],
       !debugCorpusPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      rootURL = URL(fileURLWithPath: debugCorpusPath, isDirectory: true)
      await refresh()
      return
    }
    #endif

    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      if stale {
        try saveBookmark(for: url)
      }
      rootURL = url
      await refresh()
    } catch {
      errorMessage = "Could not reopen the corpus folder."
    }
  }

  func selectCorpus(_ url: URL) async {
    do {
      try saveBookmark(for: url)
      rootURL = url
      await refresh()
    } catch {
      errorMessage = "Could not save access to the selected folder."
    }
  }

  func refresh() async {
    guard let rootURL else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    do {
      let baseURL = try corpusBaseURL(for: rootURL)
      let urls = try corpusFileURLs(in: rootURL)
      var parsed: [OrgDocument] = []
      var skipped: [String] = []

      if urls.isEmpty && !documents.isEmpty {
        outbox = outboxEntries(for: rootURL)
        statusMessage = "Keeping \(documents.count) cached files; corpus provider returned 0 files"
        return
      }

      for url in urls {
        do {
          parsed.append(try OrgParser.parseDocument(at: url, rootURL: baseURL))
        } catch {
          skipped.append("\(url.lastPathComponent): \(error.localizedDescription)")
        }
      }

      documents = parsed
      agenda = OrgParser.agendaEntries(from: parsed)
      approvals = OrgParser.approvalEntries(from: parsed)
      outbox = outboxEntries(for: rootURL)
      let fileStatus = parsed.count == 1 ? "1 file" : "\(parsed.count) files"
      statusMessage = skipped.isEmpty ? fileStatus : "\(fileStatus), \(skipped.count) skipped"
      if parsed.isEmpty && !skipped.isEmpty {
        errorMessage = "No readable org files. First skipped file: \(skipped[0])"
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func queue(_ action: MobileQueueAction, approval: ApprovalEntry, message: String? = nil) async {
    guard let rootURL else { return }
    do {
      let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
      let prompt = text?.isEmpty == false ? text! : defaultMessage(for: action, approval: approval)
      try writeOutboxNote(action: action, title: approval.title, sourceFile: approval.file, sourceLine: approval.line, body: prompt)
      outbox = outboxEntries(for: rootURL)
      statusMessage = "Appended \(action.title.lowercased()) to corpus mobile-inbox.org2"
    } catch {
      errorMessage = "Could not write to corpus mobile-inbox.org2. Re-select the synced corpus folder and try again."
    }
  }

  func queueMessage(title: String, body: String, attachments: [NoteAttachment] = []) async {
    guard let rootURL else { return }
    do {
      try writeOutboxNote(action: .message, title: title, sourceFile: "", sourceLine: nil, body: body, attachments: attachments)
      outbox = outboxEntries(for: rootURL)
      statusMessage = "Appended note to corpus mobile-inbox.org2"
    } catch {
      errorMessage = "Could not write to corpus mobile-inbox.org2. Re-select the synced corpus folder and try again."
    }
  }

  private func corpusFileURLs(in rootURL: URL) throws -> [URL] {
    if try isRegularFile(rootURL) {
      return OrgParser.isCorpusFile(rootURL) ? [rootURL] : []
    }

    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return []
    }

    var urls: [URL] = []
    for case let url as URL in enumerator {
      if url.pathComponents.contains(".git") || url.pathComponents.contains("node_modules") {
        enumerator.skipDescendants()
        continue
      }
      guard OrgParser.isCorpusFile(url) else { continue }
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { continue }
      if values.isRegularFile == true {
        urls.append(url)
      }
    }
    return urls.sorted { $0.path < $1.path }
  }

  private func writeOutboxNote(
    action: MobileQueueAction,
    title: String,
    sourceFile: String,
    sourceLine: Int?,
    body: String,
    attachments: [NoteAttachment] = []
  ) throws {
    guard let rootURL else {
      throw CocoaError(.fileNoSuchFile)
    }

    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    let createdAt = ISO8601DateFormatter().string(from: Date())
    let fileStamp = createdAt
      .replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: ".", with: "")
    let entryID = "\(fileStamp)-\(action.rawValue)-\(UUID().uuidString.prefix(8))"
    let sourceLineText = sourceLine.map(String.init) ?? ""
    let safeTitle = sanitizeProperty(title)
    let attachmentLinks = attachments
      .map { "- [[file:\(mobileInboxAssetsDirectory)/\(entryID)/\($0.filename)][\($0.filename)]]" }
      .joined(separator: "\n")
    let attachmentsSection = attachmentLinks.isEmpty ? "" : """

    Attachments:
    \(attachmentLinks)
    """

    let content = """

    * TODO Mobile \(action.title): \(safeTitle)
    :PROPERTIES:
    :ID: mobile-\(entryID)
    :KIND: mobile-openclaw-request
    :STATUS: queued
    :ACTION: \(action.rawValue)
    :CREATED_AT: \(createdAt)
    :SOURCE_FILE: \(sanitizeProperty(sourceFile))
    :SOURCE_LINE: \(sourceLineText)
    :END:

    Request:
    \(indentForOrgBody(body.trimmingCharacters(in: .whitespacesAndNewlines)))
    \(attachmentsSection)

    Source:
    - File: \(sourceFile.isEmpty ? "none" : sourceFile)
    - Line: \(sourceLineText.isEmpty ? "none" : sourceLineText)
    """

    try appendMobileInbox(content, attachments: attachments, entryID: entryID, baseURL: try preferredOutboxBaseURL(for: rootURL))
  }

  private func outboxEntries(for rootURL: URL) -> [OutboxEntry] {
    guard let baseURL = try? preferredOutboxBaseURL(for: rootURL) else { return [] }
    return mobileInboxEntries(in: baseURL)
  }

  private func appendMobileInbox(
    _ content: String,
    attachments: [NoteAttachment],
    entryID: String,
    baseURL: URL
  ) throws {
    let inboxURL = baseURL.appending(path: mobileInboxFilename)
    if !attachments.isEmpty {
      let assetsURL = baseURL.appending(path: "\(mobileInboxAssetsDirectory)/\(entryID)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
      for attachment in attachments {
        try attachment.data.write(to: assetsURL.appending(path: attachment.filename), options: .atomic)
      }
    }

    if !FileManager.default.fileExists(atPath: inboxURL.path) {
      let header = """
      #+TITLE: Org2 Mobile Inbox

      """
      try header.write(to: inboxURL, atomically: true, encoding: .utf8)
    }

    let handle = try FileHandle(forWritingTo: inboxURL)
    defer {
      try? handle.close()
    }
    try handle.seekToEnd()
    if let data = content.data(using: .utf8) {
      try handle.write(contentsOf: data)
    }
  }

  private func mobileInboxEntries(in baseURL: URL) -> [OutboxEntry] {
    let inboxURL = baseURL.appending(path: mobileInboxFilename)
    guard let document = try? OrgParser.parseDocument(at: inboxURL, rootURL: baseURL) else {
      return []
    }

    return document.nodes
      .filter {
        $0.properties["KIND"] == "mobile-openclaw-request"
          && ($0.properties["STATUS"] ?? "").lowercased() == "queued"
      }
      .map { node in
        OutboxEntry(
          id: node.properties["ID"] ?? "\(mobileInboxFilename):\(node.line)",
          url: inboxURL,
          title: node.title,
          createdAt: node.properties["CREATED_AT"] ?? "",
          action: node.properties["ACTION"] ?? "",
          source: node.properties["SOURCE_FILE"] ?? ""
        )
      }
      .sorted { lhs, rhs in lhs.createdAt > rhs.createdAt }
  }

  private func corpusBaseURL(for rootURL: URL) throws -> URL {
    try isRegularFile(rootURL) ? rootURL.deletingLastPathComponent() : rootURL
  }

  private func preferredOutboxBaseURL(for rootURL: URL) throws -> URL {
    try isRegularFile(rootURL) ? rootURL.deletingLastPathComponent() : rootURL
  }

  private func isRegularFile(_ url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    return values.isRegularFile == true
  }

  private func saveBookmark(for url: URL) throws {
    let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    UserDefaults.standard.set(data, forKey: bookmarkKey)
  }

  private func defaultMessage(for action: MobileQueueAction, approval: ApprovalEntry) -> String {
    switch action {
    case .approve:
      """
      I approve this item. Please mark the source as reviewed and continue with the next appropriate step.

      \(approval.whatsappText)
      """
    case .discuss:
      """
      I need to discuss this approval item before deciding.

      \(approval.whatsappText)
      """
    case .message:
      approval.whatsappText
    }
  }

  private func sanitizeProperty(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func indentForOrgBody(_ value: String) -> String {
    value
      .components(separatedBy: .newlines)
      .map { $0.isEmpty ? "" : "  \($0)" }
      .joined(separator: "\n")
  }
}
