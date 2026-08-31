import Foundation

enum MobileNoteSchedule: String, CaseIterable, Identifiable {
  case none
  case today
  case tomorrow
  case nextWeek
  case nextMonth
  case custom

  var id: String { rawValue }

  var title: String {
    switch self {
    case .none: "No Schedule"
    case .today: "Today"
    case .tomorrow: "Tomorrow"
    case .nextWeek: "Next Week"
    case .nextMonth: "Next Month"
    case .custom: "Pick Date"
    }
  }

  var systemImage: String {
    switch self {
    case .none: "calendar.badge.minus"
    case .today: "calendar"
    case .tomorrow: "calendar.badge.clock"
    case .nextWeek: "calendar.badge.plus"
    case .nextMonth: "calendar.circle"
    case .custom: "calendar.badge.plus"
    }
  }

  func scheduledDate(customDate: Date, calendar: Calendar = .current) -> Date? {
    let today = calendar.startOfDay(for: Date())
    switch self {
    case .none:
      return nil
    case .today:
      return today
    case .tomorrow:
      return calendar.date(byAdding: .day, value: 1, to: today)
    case .nextWeek:
      return calendar.date(byAdding: .weekOfYear, value: 1, to: today)
    case .nextMonth:
      return calendar.date(byAdding: .month, value: 1, to: today)
    case .custom:
      return calendar.startOfDay(for: customDate)
    }
  }
}

struct NoteAttachment: Identifiable, Hashable {
  let id = UUID()
  let filename: String
  let data: Data
}

enum MobileCaptureWriter {
  static let appGroupID = "group.org.org2.mobile"
  static let bookmarkKey = "org2.mobile.corpusBookmark"
  static let cachedRootPathKey = "org2.mobile.cachedRootPath"
  static let mobileInboxFilename = "mobile-inbox.org"
  static let legacyMobileInboxFilename = "mobile-inbox.org2"
  static let mobileInboxAssetsDirectory = "mobile-inbox-assets"

  static var sharedDefaults: UserDefaults {
    UserDefaults(suiteName: appGroupID) ?? .standard
  }

  static func mobileInboxURL(baseURL: URL, fileManager: FileManager = .default) -> URL {
    let preferred = baseURL.appendingPathComponent(mobileInboxFilename)
    if fileManager.fileExists(atPath: preferred.path) {
      return preferred
    }
    let legacy = baseURL.appendingPathComponent(legacyMobileInboxFilename)
    return fileManager.fileExists(atPath: legacy.path) ? legacy : preferred
  }

  static func saveSharedCorpusAccess(bookmark: Data, rootURL: URL) {
    sharedDefaults.set(bookmark, forKey: bookmarkKey)
    sharedDefaults.set(cacheRootPath(for: rootURL), forKey: cachedRootPathKey)
    sharedDefaults.synchronize()
  }

  static func resolveSharedCorpusRoot() throws -> URL? {
    guard let data = sharedDefaults.data(forKey: bookmarkKey) else { return nil }
    var stale = false
    do {
      return try URL(
        resolvingBookmarkData: data,
        options: [.withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
    } catch {
      stale = true
      return try URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
    }
  }

  static func appendMobileNote(
    rootURL: URL,
    title: String,
    body: String,
    attachments: [NoteAttachment] = [],
    scheduledDate: Date? = nil
  ) throws -> URL {
    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    let baseURL = try preferredCorpusBaseURL(for: rootURL)
    let createdAt = ISO8601DateFormatter().string(from: Date())
    let fileStamp = createdAt
      .replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: ".", with: "")
    let entryID = "\(fileStamp)-note-\(UUID().uuidString.prefix(8))"
    let sanitizedTitle = sanitizeProperty(title)
    let noteTitle = sanitizedTitle.isEmpty ? "Phone note" : sanitizedTitle
    let bodyText = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachmentLinks = attachments
      .map { "- [[file:\(mobileInboxAssetsDirectory)/\(entryID)/\($0.filename)][\($0.filename)]]" }
      .joined(separator: "\n")
    let planningLine = scheduledDate.map { "SCHEDULED: \(orgDayTimestamp($0))\n" } ?? ""
    let headingPrefix = scheduledDate == nil ? "*" : "* TODO"
    let bodySection = bodyText.isEmpty ? "" : """

    \(bodyText)
    """
    let attachmentsSection = attachmentLinks.isEmpty ? "" : """

    Attachments:
    \(attachmentLinks)
    """

    let content = """

    \(headingPrefix) \(noteTitle)
    \(planningLine):PROPERTIES:
    :ID: mobile-\(entryID)
    :KIND: mobile-note
    :STATUS: pending
    :DAILY_DATE: \(orgDayString(Date()))
    :CREATED_AT: \(createdAt)
    :SOURCE: org2-mobile
    :END:
    \(bodySection)\(attachmentsSection)
    """

    return try appendMobileInbox(content, attachments: attachments, entryID: entryID, baseURL: baseURL)
  }

  static func appendMobileInbox(
    _ content: String,
    attachments: [NoteAttachment],
    entryID: String,
    baseURL: URL
  ) throws -> URL {
    let inboxURL = mobileInboxURL(baseURL: baseURL)
    if !attachments.isEmpty {
      let assetsURL = baseURL
        .appendingPathComponent(mobileInboxAssetsDirectory, isDirectory: true)
        .appendingPathComponent(entryID, isDirectory: true)
      try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
      for attachment in attachments {
        try attachment.data.write(to: assetsURL.appendingPathComponent(attachment.filename), options: .atomic)
      }
    }

    if !FileManager.default.fileExists(atPath: inboxURL.path) {
      let header = """
      #+TITLE: OpenOrg Mobile Inbox

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
    return inboxURL
  }

  static func orgDayString(_ date: Date) -> String {
    orgDayFormatter.string(from: date)
  }

  static func orgDayTimestamp(_ date: Date) -> String {
    "<\(orgPlanningDayFormatter.string(from: date))>"
  }

  private static func preferredCorpusBaseURL(for rootURL: URL) throws -> URL {
    try isRegularFile(rootURL) ? rootURL.deletingLastPathComponent() : rootURL
  }

  private static func isRegularFile(_ url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    return values.isRegularFile == true
  }

  private static func cacheRootPath(for rootURL: URL) -> String {
    rootURL.standardizedFileURL.path
  }

  private static func sanitizeProperty(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let orgDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let orgPlanningDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd EEE"
    return formatter
  }()
}
