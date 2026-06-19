import Combine
import Foundation

@MainActor
final class CorpusStore: ObservableObject {
  @Published private(set) var rootURL: URL?
  @Published private(set) var documents: [OrgDocument] = []
  @Published private(set) var agenda: [AgendaEntry] = []
  @Published private(set) var approvals: [ApprovalEntry] = []
  @Published var isLoading = false
  @Published private(set) var isPreparingCorpus = false
  @Published var errorMessage: String?
  @Published var statusMessage: String?
  @Published var isDocumentPickerPresented = false

  private let bookmarkKey = "org2.mobile.corpusBookmark"
  private let cachedRootPathKey = "org2.mobile.cachedRootPath"
  private let mobileInboxFilename = "mobile-inbox.org2"
  private let mobileInboxAssetsDirectory = "mobile-inbox-assets"
  private let mobileAttachmentDirectory = "mobile-attachments"
  private let cacheFilename = "org2-mobile-corpus-cache.json"
  private let headingTodoKeywords = Set(OrgTodoStatus.allCases.map(\.rawValue))
  private var cachedFileCount: Int?
  private var refreshGeneration = 0
  private var cacheHydrationGeneration = 0

  var corpusName: String {
    rootURL?.lastPathComponent ?? "No corpus"
  }

  private var hasDisplayedCorpus: Bool {
    !documents.isEmpty || !agenda.isEmpty || !approvals.isEmpty
  }

  private var cacheURL: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appending(path: cacheFilename)
  }

  func restoreCorpus() async {
    #if DEBUG
    if let debugCorpusPath = ProcessInfo.processInfo.environment["ORG2_DEBUG_CORPUS_PATH"],
       !debugCorpusPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let url = URL(fileURLWithPath: debugCorpusPath, isDirectory: true)
      setRootURL(url)
      startCacheHydration(matching: url)
      startBackgroundRefresh()
      return
    }
    #endif

    if let cachedRootPath = UserDefaults.standard.string(forKey: cachedRootPathKey),
       !cachedRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let url = URL(fileURLWithPath: cachedRootPath, isDirectory: true)
      rootURL = url
      statusMessage = "Loading cached corpus"
      startCacheHydration(matching: url)
    } else {
      startCacheHydration(matching: nil)
    }

    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
    restoreBookmarkedCorpus(data)
  }

  private func restoreBookmarkedCorpus(_ data: Data) {
    Task {
      await resolveSavedCorpusBookmark(data)
    }
  }

  private func resolveSavedCorpusBookmark(_ data: Data) async {
    do {
      let resolved = try await Task.detached(priority: .userInitiated) {
        let resolved = try Self.resolveCorpusBookmark(data)
        let refreshedBookmark = resolved.stale ? try? Self.bookmarkData(for: resolved.url) : nil
        return CorpusBookmarkResolution(url: resolved.url, stale: resolved.stale, refreshedBookmark: refreshedBookmark)
      }.value

      if let refreshedBookmark = resolved.refreshedBookmark {
        UserDefaults.standard.set(refreshedBookmark, forKey: bookmarkKey)
        UserDefaults.standard.synchronize()
      }

      setRootURL(resolved.url)
      if !hasDisplayedCorpus {
        startCacheHydration(matching: resolved.url)
      }
      startBackgroundRefresh()
    } catch {
      if !hasDisplayedCorpus {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        rootURL = nil
        clearCorpusViews()
      }
      errorMessage = "Could not reopen the corpus folder. Please select it again once to refresh Org2's saved access."
    }
  }

  func selectCorpus(_ url: URL) async {
    do {
      try saveBookmark(for: url)
      setRootURL(url)
      startCacheHydration(matching: url)
      await refresh()
    } catch {
      errorMessage = "Could not save access to the selected folder."
    }
  }

  func refresh(priority: TaskPriority = .utility) async {
    guard let rootURL else { return }
    refreshGeneration += 1
    let generation = refreshGeneration
    isLoading = true
    errorMessage = nil
    defer {
      if refreshGeneration == generation {
        isLoading = false
      }
    }

    do {
      let snapshot = try await Task.detached(priority: priority) {
        try Self.buildSnapshot(rootURL: rootURL)
      }.value

      guard self.rootURL == rootURL, refreshGeneration == generation else { return }

      if snapshot.discoveredFileCount == 0 && hasDisplayedCorpus {
        let cachedCount = cachedFileCount ?? documents.count
        let fileText = cachedCount == 1 ? "1 cached file" : "\(cachedCount) cached files"
        statusMessage = "Keeping \(fileText); corpus provider returned 0 files"
        return
      }

      documents = snapshot.documents
      agenda = snapshot.agenda
      approvals = snapshot.approvals
      cachedFileCount = snapshot.documents.count
      saveCachedCorpus(snapshot, for: rootURL)

      let fileStatus = snapshot.documents.count == 1 ? "1 file" : "\(snapshot.documents.count) files"
      statusMessage = snapshot.skipped.isEmpty ? fileStatus : "\(fileStatus), \(snapshot.skipped.count) skipped"
      if snapshot.documents.isEmpty && !snapshot.skipped.isEmpty {
        errorMessage = "No readable org files. First skipped file: \(snapshot.skipped[0])"
      }
    } catch {
      guard self.rootURL == rootURL, refreshGeneration == generation else { return }
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

  func approve(_ approval: ApprovalEntry) async {
    guard rootURL != nil else { return }
    do {
      let url = try approveInCorpus(approval)
      statusMessage = "Approved \(url.lastPathComponent)"
      await refresh()
    } catch {
      errorMessage = "Could not approve this item in the corpus. Re-select the synced corpus folder and try again."
    }
  }

  func setTodoStatus(_ status: OrgTodoStatus, for entry: AgendaEntry) async {
    guard rootURL != nil else { return }
    do {
      let url = try setTodoStatusInCorpus(status, for: entry)
      statusMessage = "Set \(entry.title.prettyPrintedOrgLinks()) to \(status.rawValue) in \(url.lastPathComponent)"
      await refresh()
    } catch {
      errorMessage = "Could not update this agenda item. Re-select the synced corpus folder and try again."
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

  private func startBackgroundRefresh() {
    Task(priority: .background) {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      await refresh(priority: .background)
    }
  }

  private func startCacheHydration(matching rootURL: URL?) {
    cacheHydrationGeneration += 1
    let generation = cacheHydrationGeneration
    isPreparingCorpus = true
    Task {
      await hydrateCachedCorpus(matching: rootURL, generation: generation)
    }
  }

  private func hydrateCachedCorpus(matching rootURL: URL?, generation: Int) async {
    let cacheURL = cacheURL
    defer {
      if cacheHydrationGeneration == generation {
        isPreparingCorpus = false
      }
    }

    guard let snapshot = await Task.detached(priority: .utility, operation: {
      Self.loadValidCachedCorpus(at: cacheURL)
    }).value else {
      return
    }

    guard cacheHydrationGeneration == generation else { return }

    if let rootURL, snapshot.rootPath != Self.cacheRootPath(for: rootURL) {
      return
    }

    if self.rootURL == nil {
      self.rootURL = URL(fileURLWithPath: snapshot.rootPath, isDirectory: true)
    }
    restoreCachedCorpus(snapshot)
    UserDefaults.standard.set(snapshot.rootPath, forKey: cachedRootPathKey)
  }

  private func restoreCachedCorpus(for rootURL: URL) {
    startCacheHydration(matching: rootURL)
  }

  private func restoreCachedCorpus(_ snapshot: CorpusCacheSnapshot) {
    documents = []
    agenda = snapshot.agenda
    approvals = snapshot.approvals
    cachedFileCount = snapshot.fileCount
    let fileText = snapshot.fileCount == 1 ? "1 cached file" : "\(snapshot.fileCount) cached files"
    statusMessage = "Loaded \(fileText)"
  }

  private func clearCorpusViews() {
    documents = []
    agenda = []
    approvals = []
    cachedFileCount = nil
    statusMessage = nil
  }

  nonisolated private static func loadCachedCorpus(at cacheURL: URL) -> CorpusCacheSnapshot? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    return try? JSONDecoder().decode(CorpusCacheSnapshot.self, from: data)
  }

  nonisolated private static func loadValidCachedCorpus(at cacheURL: URL) -> CorpusCacheSnapshot? {
    guard let snapshot = loadCachedCorpus(at: cacheURL),
          snapshot.version == CorpusCacheSnapshot.currentVersion
    else {
      return nil
    }
    return snapshot
  }

  private func saveCachedCorpus(_ refreshSnapshot: CorpusRefreshSnapshot, for rootURL: URL) {
    let cacheSnapshot = CorpusCacheSnapshot(
      version: CorpusCacheSnapshot.currentVersion,
      rootPath: Self.cacheRootPath(for: rootURL),
      cachedAt: Date(),
      fileCount: refreshSnapshot.documents.count,
      agenda: refreshSnapshot.agenda,
      approvals: refreshSnapshot.approvals
    )

    do {
      try FileManager.default.createDirectory(
        at: cacheURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try JSONEncoder().encode(cacheSnapshot)
      try data.write(to: cacheURL, options: .atomic)
      UserDefaults.standard.set(cacheSnapshot.rootPath, forKey: cachedRootPathKey)
    } catch {
      // Cache writes should never block the live corpus view.
    }
  }

  private func setRootURL(_ url: URL) {
    rootURL = url
    UserDefaults.standard.set(Self.cacheRootPath(for: url), forKey: cachedRootPathKey)
  }

  nonisolated private static func cacheRootPath(for rootURL: URL) -> String {
    rootURL.standardizedFileURL.path
  }

  nonisolated private static func buildSnapshot(rootURL: URL) throws -> CorpusRefreshSnapshot {
    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    let baseURL = try corpusBaseURL(for: rootURL)
    let urls = try corpusFileURLs(in: rootURL)
    var parsed: [OrgDocument] = []
    var skipped: [String] = []

    for url in urls {
      do {
        parsed.append(try OrgParser.parseDocument(at: url, rootURL: baseURL))
      } catch {
        skipped.append("\(url.lastPathComponent): \(error.localizedDescription)")
      }
    }

    return CorpusRefreshSnapshot(
      documents: parsed,
      agenda: OrgParser.agendaEntries(from: parsed),
      approvals: OrgParser.approvalEntries(from: parsed),
      skipped: skipped,
      discoveredFileCount: urls.count
    )
  }

  nonisolated private static func corpusFileURLs(in rootURL: URL) throws -> [URL] {
    if try isRegularFile(rootURL) {
      return OrgParser.isCorpusFile(rootURL) ? [rootURL] : []
    }

    let baseURL = try corpusBaseURL(for: rootURL)
    let config = mobileOrg2Config(in: baseURL)
    let configuredAgendaPatterns = config.map { $0.agendaFiles ?? ["*.org"] }
    let ignorePatterns = config?.ignorePatterns ?? []
    let recursive = config?.recursive ?? true

    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return []
    }

    var urls: [URL] = []
    for case let url as URL in enumerator {
      let relativePath = OrgParser.relativePath(for: url, rootURL: baseURL)
      if shouldSkipCorpusPath(relativePath, url: url, ignorePatterns: ignorePatterns) {
        enumerator.skipDescendants()
        continue
      }
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else { continue }
      if values.isDirectory == true, !recursive {
        enumerator.skipDescendants()
        continue
      }
      if values.isRegularFile == true {
        if let agendaPatterns = configuredAgendaPatterns {
          guard agendaPatterns.contains(where: { corpusPath(relativePath, matches: $0) }) else { continue }
        } else {
          guard isDefaultAgendaFile(url) else { continue }
        }
        urls.append(url)
      }
    }
    return urls.sorted { $0.path < $1.path }
  }

  nonisolated private static func mobileOrg2Config(in baseURL: URL) -> MobileOrg2Config? {
    let configURL = baseURL.appendingPathComponent("org2.json")
    guard let data = try? Data(contentsOf: configURL) else { return nil }
    return try? JSONDecoder().decode(MobileOrg2Config.self, from: data)
  }

  nonisolated private static func shouldSkipCorpusPath(_ relativePath: String, url: URL, ignorePatterns: [String]) -> Bool {
    let name = url.lastPathComponent
    if name == ".git" || name == "node_modules" || name.hasPrefix(".#") {
      return true
    }
    if name.hasPrefix(".syncthing.") || name.contains(".sync-conflict-") || name.hasSuffix(".tmp") {
      return true
    }
    return ignorePatterns.contains { corpusPath(relativePath, matches: $0) }
  }

  nonisolated private static func isDefaultAgendaFile(_ url: URL) -> Bool {
    let extensionName = url.pathExtension.lowercased()
    return extensionName == "org" || extensionName == "org2"
  }

  nonisolated private static func corpusPath(_ path: String, matches pattern: String) -> Bool {
    let normalizedPath = normalizedCorpusPath(path)
    let normalizedPattern = normalizedCorpusPath(pattern)
    if normalizedPattern.contains("*") {
      let pathSegments = normalizedPath.split(separator: "/").map(String.init)
      let patternSegments = normalizedPattern.split(separator: "/").map(String.init)
      return matchCorpusSegments(pathSegments, patternSegments)
    }
    return normalizedPath == normalizedPattern || normalizedPath.hasPrefix("\(normalizedPattern)/")
  }

  nonisolated private static func matchCorpusSegments(
    _ pathSegments: [String],
    _ patternSegments: [String],
    pathIndex: Int = 0,
    patternIndex: Int = 0
  ) -> Bool {
    guard patternIndex < patternSegments.count else {
      return pathIndex >= pathSegments.count
    }

    let pattern = patternSegments[patternIndex]
    if pattern == "**" {
      for nextPathIndex in pathIndex...pathSegments.count {
        if matchCorpusSegments(
          pathSegments,
          patternSegments,
          pathIndex: nextPathIndex,
          patternIndex: patternIndex + 1
        ) {
          return true
        }
      }
      return false
    }

    guard pathIndex < pathSegments.count else { return false }
    guard corpusSegment(pathSegments[pathIndex], matches: pattern) else { return false }
    return matchCorpusSegments(
      pathSegments,
      patternSegments,
      pathIndex: pathIndex + 1,
      patternIndex: patternIndex + 1
    )
  }

  nonisolated private static func corpusSegment(_ segment: String, matches pattern: String) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: pattern)
      .replacingOccurrences(of: "\\*", with: ".*")
    let regex = "^\(escaped)$"
    return segment.range(of: regex, options: .regularExpression) != nil
  }

  nonisolated private static func normalizedCorpusPath(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "/")
      .split(separator: "/", omittingEmptySubsequences: true)
      .joined(separator: "/")
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

  private func approveInCorpus(_ approval: ApprovalEntry) throws -> URL {
    guard let rootURL else {
      throw CocoaError(.fileNoSuchFile)
    }

    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    let url = try corpusFileURL(for: approval.file, rootURL: rootURL)
    let raw = try String(contentsOf: url, encoding: .utf8)
    var lines = raw.components(separatedBy: .newlines)
    guard let headingIndex = headingIndex(in: lines, matching: approval) else {
      throw CocoaError(.fileNoSuchFile)
    }

    lines[headingIndex] = headingLine(lines[headingIndex], settingTodo: OrgTodoStatus.done.rawValue)
    upsertApprovalProperties(in: &lines, headingIndex: headingIndex, approval: approval)

    var output = lines.joined(separator: "\n")
    if raw.hasSuffix("\n"), !output.hasSuffix("\n") {
      output += "\n"
    }
    try output.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func setTodoStatusInCorpus(_ status: OrgTodoStatus, for entry: AgendaEntry) throws -> URL {
    guard let rootURL else {
      throw CocoaError(.fileNoSuchFile)
    }

    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    let url = try corpusFileURL(for: entry.file, rootURL: rootURL)
    let raw = try String(contentsOf: url, encoding: .utf8)
    var lines = raw.components(separatedBy: .newlines)
    guard let headingIndex = headingIndex(in: lines, matching: entry) else {
      throw CocoaError(.fileNoSuchFile)
    }

    lines[headingIndex] = headingLine(lines[headingIndex], settingTodo: status.rawValue)

    var output = lines.joined(separator: "\n")
    if raw.hasSuffix("\n"), !output.hasSuffix("\n") {
      output += "\n"
    }
    try output.write(to: url, atomically: true, encoding: .utf8)
    return url
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

    let baseURL = try Self.corpusBaseURL(for: rootURL)
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

  nonisolated private static func corpusBaseURL(for rootURL: URL) throws -> URL {
    try isRegularFile(rootURL) ? rootURL.deletingLastPathComponent() : rootURL
  }

  private func preferredCorpusBaseURL(for rootURL: URL) throws -> URL {
    try Self.isRegularFile(rootURL) ? rootURL.deletingLastPathComponent() : rootURL
  }

  private func corpusFileURL(for relativePath: String, rootURL: URL) throws -> URL {
    if try Self.isRegularFile(rootURL) {
      return rootURL
    }
    return try Self.corpusBaseURL(for: rootURL).appending(path: relativePath)
  }

  nonisolated private static func isRegularFile(_ url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    return values.isRegularFile == true
  }

  private func saveBookmark(for url: URL) throws {
    let data = try Self.bookmarkData(for: url)
    UserDefaults.standard.set(data, forKey: bookmarkKey)
    UserDefaults.standard.synchronize()
  }

  nonisolated private static func bookmarkData(for url: URL) throws -> Data {
    let hasSecurityAccess = url.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  nonisolated private static func resolveCorpusBookmark(_ data: Data) throws -> CorpusBookmarkResolution {
    var stale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      return CorpusBookmarkResolution(url: url, stale: stale)
    } catch {
      stale = true
      let url = try URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      return CorpusBookmarkResolution(url: url, stale: stale)
    }
  }

  private func defaultMessage(for action: OpenClawAction, approval: ApprovalEntry) -> String {
    switch action {
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

  private func headingIndex(in lines: [String], matching approval: ApprovalEntry) -> Int? {
    if let line = approval.line {
      let index = line - 1
      if lines.indices.contains(index), isHeading(lines[index]), headingMatchesApproval(lines: lines, index: index, approval: approval) {
        return index
      }
    }

    if let sourceID = approval.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
      for index in lines.indices where isHeading(lines[index]) {
        let properties = propertyDrawerValues(in: lines, headingIndex: index)
        if properties["ID"] == sourceID {
          return index
        }
      }
    }

    let normalizedTitle = normalizedOrgTitle(approval.title)
    return lines.indices.first { index in
      isHeading(lines[index]) && normalizedOrgTitle(headingTitle(lines[index])) == normalizedTitle
    }
  }

  private func headingIndex(in lines: [String], matching entry: AgendaEntry) -> Int? {
    let index = entry.line - 1
    if lines.indices.contains(index),
       isHeading(lines[index]),
       headingMatchesAgendaEntry(lines[index], entry: entry) {
      return index
    }

    let normalizedTitle = normalizedOrgTitle(entry.title)
    return lines.indices.first { index in
      isHeading(lines[index]) && normalizedOrgTitle(headingTitle(lines[index])) == normalizedTitle
    }
  }

  private func headingMatchesAgendaEntry(_ line: String, entry: AgendaEntry) -> Bool {
    normalizedOrgTitle(headingTitle(line)) == normalizedOrgTitle(entry.title)
  }

  private func headingMatchesApproval(lines: [String], index: Int, approval: ApprovalEntry) -> Bool {
    if let sourceID = approval.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
      return propertyDrawerValues(in: lines, headingIndex: index)["ID"] == sourceID
    }
    return normalizedOrgTitle(headingTitle(lines[index])) == normalizedOrgTitle(approval.title)
  }

  private func upsertApprovalProperties(in lines: inout [String], headingIndex: Int, approval: ApprovalEntry) {
    var properties: [String: String] = [
      "STATUS": "approved",
      "APPROVED_AT": orgTimestamp(Date()),
    ]

    for key in [
      "ORG2_REVIEW_STATUS",
      "REVIEW_STATUS",
      "REVIEW",
      "FOLLOWUP_STATUS",
      "REPLY_STATUS",
      "ACCESS_POLICY",
      "REVIEW_POLICY",
    ] where approval.properties[key] != nil {
      properties[key] = "approved"
    }

    for key in [
      "WAITING_ON",
      "BLOCKED_BY",
      "ORG2_WAITING_ON",
      "NEXT_ACTION",
      "ACTION_REQUIRED",
      "ORG2_NEXT_ACTION",
      "HANDOFF_SUMMARY",
      "ORG2_HANDOFF_SUMMARY",
    ] {
      guard let value = approval.properties[key]?.lowercased() else { continue }
      if value.contains("approval") || value.contains("approve") || value.contains("review") || value.contains("avi") {
        properties[key] = "approved"
      }
    }

    upsertProperties(properties, in: &lines, headingIndex: headingIndex)
  }

  private func upsertProperties(_ properties: [String: String], in lines: inout [String], headingIndex: Int) {
    guard let drawer = propertyDrawerRange(in: lines, headingIndex: headingIndex) else {
      let inserted = [":PROPERTIES:"]
        + properties.sorted { $0.key < $1.key }.map { ":\($0.key): \($0.value)" }
        + [":END:"]
      lines.insert(contentsOf: inserted, at: min(headingIndex + 1, lines.count))
      return
    }

    var pending = properties
    var index = drawer.start + 1
    while index < drawer.end {
      let key = propertyKey(in: lines[index])
      if let key, let value = pending[key] {
        lines[index] = ":\(key): \(value)"
        pending.removeValue(forKey: key)
      }
      index += 1
    }

    if !pending.isEmpty {
      let inserted = pending.sorted { $0.key < $1.key }.map { ":\($0.key): \($0.value)" }
      lines.insert(contentsOf: inserted, at: drawer.end)
    }
  }

  private func propertyDrawerValues(in lines: [String], headingIndex: Int) -> [String: String] {
    guard let drawer = propertyDrawerRange(in: lines, headingIndex: headingIndex) else { return [:] }
    var properties: [String: String] = [:]
    for index in (drawer.start + 1)..<drawer.end {
      guard let key = propertyKey(in: lines[index]) else { continue }
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      guard let secondColon = trimmed.dropFirst().firstIndex(of: ":") else { continue }
      let valueStart = trimmed.index(after: secondColon)
      properties[key] = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
    }
    return properties
  }

  private func propertyDrawerRange(in lines: [String], headingIndex: Int) -> (start: Int, end: Int)? {
    var index = headingIndex + 1
    while index < lines.count {
      if isHeading(lines[index]) { return nil }
      if lines[index].trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:" {
        var end = index + 1
        while end < lines.count {
          if isHeading(lines[end]) { return nil }
          if lines[end].trimmingCharacters(in: .whitespaces).uppercased() == ":END:" {
            return (index, end)
          }
          end += 1
        }
        return nil
      }
      index += 1
    }
    return nil
  }

  private func propertyKey(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(":"),
          let secondColon = trimmed.dropFirst().firstIndex(of: ":")
    else {
      return nil
    }
    let keyStart = trimmed.index(after: trimmed.startIndex)
    let key = String(trimmed[keyStart..<secondColon]).uppercased()
    return key.isEmpty ? nil : key
  }

  private func headingLine(_ line: String, settingTodo todo: String) -> String {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return line }
    var rest = line.dropFirst(stars.count).trimmingCharacters(in: .whitespaces)
    if let first = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
       headingTodoKeywords.contains(String(first).uppercased()) {
      rest = rest.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
    }
    return "\(stars) \(todo) \(rest)"
  }

  private func isHeading(_ line: String) -> Bool {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return false }
    return line.dropFirst(stars.count).first?.isWhitespace == true
  }

  private func headingTitle(_ line: String) -> String {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return line }
    var rest = line.dropFirst(stars.count).trimmingCharacters(in: .whitespaces)
    if let first = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
       headingTodoKeywords.contains(String(first).uppercased()) {
      rest = rest.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
    }
    if rest.hasPrefix("[#"), let close = rest.firstIndex(of: "]") {
      rest = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%.-]+(?::[A-Za-z0-9_@#%.-]+)*:)\s*$"#, options: .regularExpression) {
      rest.removeSubrange(tagRange)
    }
    return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalizedOrgTitle(_ title: String) -> String {
    title.prettyPrintedOrgLinks()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .lowercased()
  }

  private func orgTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
    return "<\(formatter.string(from: date))>"
  }
}

private struct MobileOrg2Config: Decodable {
  let agendaFiles: [String]?
  let recursive: Bool?
  let ignorePatterns: [String]?
}

private struct CorpusRefreshSnapshot {
  let documents: [OrgDocument]
  let agenda: [AgendaEntry]
  let approvals: [ApprovalEntry]
  let skipped: [String]
  let discoveredFileCount: Int
}

private struct CorpusCacheSnapshot: Codable {
  static let currentVersion = 1

  let version: Int
  let rootPath: String
  let cachedAt: Date
  let fileCount: Int
  let agenda: [AgendaEntry]
  let approvals: [ApprovalEntry]
}

private struct CorpusBookmarkResolution: Sendable {
  let url: URL
  let stale: Bool
  var refreshedBookmark: Data?
}
