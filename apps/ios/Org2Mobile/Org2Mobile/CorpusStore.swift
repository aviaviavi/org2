import Combine
import Foundation

@MainActor
final class CorpusStore: ObservableObject {
  @Published private(set) var rootURL: URL?
  @Published private(set) var documents: [OrgDocument] = []
  @Published private(set) var agenda: [AgendaEntry] = []
  @Published private(set) var approvals: [ApprovalEntry] = []
  @Published var isLoading = false
  @Published var errorMessage: String?
  @Published var statusMessage: String?
  @Published var isDocumentPickerPresented = false

  private let bookmarkKey = "org2.mobile.corpusBookmark"
  private let mobileInboxFilename = "mobile-inbox.org2"
  private let mobileInboxAssetsDirectory = "mobile-inbox-assets"
  private let mobileAttachmentDirectory = "mobile-attachments"

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
      let fileStatus = parsed.count == 1 ? "1 file" : "\(parsed.count) files"
      statusMessage = skipped.isEmpty ? fileStatus : "\(fileStatus), \(skipped.count) skipped"
      if parsed.isEmpty && !skipped.isEmpty {
        errorMessage = "No readable org files. First skipped file: \(skipped[0])"
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func sendToOpenClaw(_ action: OpenClawAction, approval: ApprovalEntry, message: String? = nil) async {
    guard rootURL != nil else { return }
    do {
      let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
      let prompt = text?.isEmpty == false ? text! : defaultMessage(for: action, approval: approval)
      try appendOpenClawRequest(action: action, title: approval.title, sourceFile: approval.file, sourceLine: approval.line, body: prompt)
      statusMessage = "Added \(action.title.lowercased()) request to corpus mobile-inbox.org2"
    } catch {
      errorMessage = "Could not write to corpus mobile-inbox.org2. Re-select the synced corpus folder and try again."
    }
  }

  func saveDailyNote(title: String, body: String, attachments: [NoteAttachment] = []) async {
    guard rootURL != nil else { return }
    do {
      let dailyNoteURL = try appendDailyNote(title: title, body: body, attachments: attachments)
      statusMessage = "Saved note to \(dailyNoteURL.lastPathComponent)"
    } catch {
      errorMessage = "Could not write to today's daily note. Re-select the synced corpus folder and try again."
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

  private func appendOpenClawRequest(
    action: OpenClawAction,
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
    :STATUS: pending
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

    try appendMobileInbox(content, attachments: attachments, entryID: entryID, baseURL: try preferredCorpusBaseURL(for: rootURL))
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

  private func appendDailyNote(title: String, body: String, attachments: [NoteAttachment]) throws -> URL {
    guard let rootURL else {
      throw CocoaError(.fileNoSuchFile)
    }

    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    let baseURL = try corpusBaseURL(for: rootURL)
    let today = Date.org2TodayString
    let dailyNoteURL = dailyNoteURL(for: today, baseURL: baseURL)
    let createdAt = ISO8601DateFormatter().string(from: Date())
    let fileStamp = createdAt
      .replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: ".", with: "")
    let entryID = "\(fileStamp)-note-\(UUID().uuidString.prefix(8))"
    let sanitizedTitle = sanitizeProperty(title)
    let noteTitle = sanitizedTitle.isEmpty ? "Phone note" : sanitizedTitle
    let bodyText = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachmentLinks = try writeDailyNoteAttachments(attachments, entryID: entryID, baseURL: baseURL)
    let bodySection = bodyText.isEmpty ? "" : """

    \(bodyText)
    """
    let attachmentsSection = attachmentLinks.isEmpty ? "" : """

    Attachments:
    \(attachmentLinks.joined(separator: "\n"))
    """

    let entry = """

    * \(noteTitle)
    :PROPERTIES:
    :ID: mobile-\(entryID)
    :CREATED_AT: \(createdAt)
    :SOURCE: org2-mobile
    :END:
    \(bodySection)\(attachmentsSection)
    """

    if !FileManager.default.fileExists(atPath: dailyNoteURL.path) {
      let header = """
      #+TITLE: \(today)

      """
      try header.write(to: dailyNoteURL, atomically: true, encoding: .utf8)
    }

    try append(entry, to: dailyNoteURL)
    return dailyNoteURL
  }

  private func writeDailyNoteAttachments(_ attachments: [NoteAttachment], entryID: String, baseURL: URL) throws -> [String] {
    guard !attachments.isEmpty else { return [] }

    let assetsURL = baseURL.appending(path: "\(mobileAttachmentDirectory)/\(entryID)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    return try attachments.map { attachment in
      try attachment.data.write(to: assetsURL.appending(path: attachment.filename), options: .atomic)
      return "- [[file:\(mobileAttachmentDirectory)/\(entryID)/\(attachment.filename)][\(attachment.filename)]]"
    }
  }

  private func dailyNoteURL(for today: String, baseURL: URL) -> URL {
    let org2URL = baseURL.appending(path: "\(today).org2")
    if FileManager.default.fileExists(atPath: org2URL.path) {
      return org2URL
    }

    let orgURL = baseURL.appending(path: "\(today).org")
    if FileManager.default.fileExists(atPath: orgURL.path) {
      return orgURL
    }

    return org2URL
  }

  private func append(_ content: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer {
      try? handle.close()
    }
    try handle.seekToEnd()
    if let data = content.data(using: .utf8) {
      try handle.write(contentsOf: data)
    }
  }

  private func corpusBaseURL(for rootURL: URL) throws -> URL {
    try isRegularFile(rootURL) ? rootURL.deletingLastPathComponent() : rootURL
  }

  private func preferredCorpusBaseURL(for rootURL: URL) throws -> URL {
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

  private func defaultMessage(for action: OpenClawAction, approval: ApprovalEntry) -> String {
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
