import CryptoKit
import Foundation

/// A value that can be written into one usage-log event. Only structural
/// values belong here: counts, durations, enum-like labels, and salted hashes.
/// Never record note text, chat text, titles, queries, or raw file paths.
public enum OpenOrgUsageValue: Sendable, Equatable, Encodable,
  ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)

  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode((value * 10).rounded() / 10)
    case .bool(let value): try container.encode(value)
    }
  }
}

/// Event names are a public, documented contract for the local log so a user
/// can inspect exactly what is captured before sharing the file.
public enum OpenOrgUsageEvent: String, Sendable, CaseIterable {
  case sessionStart = "session_start"
  case documentOpen = "document_open"
  case documentReady = "document_ready"
  case quickOpenPresent = "quick_open_present"
  case quickOpenSelect = "quick_open_select"
  case quickOpenDismiss = "quick_open_dismiss"
  case navigateHistory = "navigate_history"
  case linkPreview = "link_preview"
  case linkOpenInNewTab = "link_open_new_tab"
  case surfaceOpen = "surface_open"
  case startWork = "start_work"
  case chatTurnStart = "chat_turn_start"
  case chatTurnFinish = "chat_turn_finish"
  case activityOpen = "activity_open"
  case activityMapNavigate = "activity_map_navigate"
}

/// Opt-in, local-only usage log. Events are appended as JSON Lines to a file
/// in Application Support that the user can open, clear, and choose to share.
/// Nothing is uploaded. Disabled by default.
@MainActor
public final class OpenOrgUsageLog {
  public static let enabledKey = "OpenOrg.usageLog.enabled.v1"
  public static let saltKey = "OpenOrg.usageLog.salt.v1"
  public static let schemaVersion = 1
  /// Rotate once the active file grows past this size; one previous file is kept.
  public static let rotationByteLimit = 5 * 1024 * 1024

  public var isEnabled: Bool {
    didSet {
      guard isEnabled != oldValue else { return }
      defaults.set(isEnabled, forKey: Self.enabledKey)
      if isEnabled { record(.sessionStart, ["reason": "enabled"]) }
    }
  }

  public let fileURL: URL
  private let defaults: UserDefaults
  private let sessionID = String(UUID().uuidString.prefix(8)).lowercased()
  private let now: () -> Date
  private let writer: OpenOrgUsageLogWriter
  private lazy var salt: String = {
    if let existing = defaults.string(forKey: Self.saltKey), !existing.isEmpty { return existing }
    let created = UUID().uuidString
    defaults.set(created, forKey: Self.saltKey)
    return created
  }()

  public init(
    defaults: UserDefaults = .standard,
    fileURL: URL? = nil,
    now: @escaping () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.fileURL = fileURL ?? Self.defaultFileURL()
    self.now = now
    self.writer = OpenOrgUsageLogWriter(fileURL: self.fileURL, rotationByteLimit: Self.rotationByteLimit)
    isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
  }

  public static func defaultFileURL(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let folder = bundleIdentifier == "org.org2.workspace" ? "OpenOrg" : "OpenOrg Preview"
    return base
      .appendingPathComponent(folder, isDirectory: true)
      .appendingPathComponent("usage-events.jsonl")
  }

  public func record(_ event: OpenOrgUsageEvent, _ fields: [String: OpenOrgUsageValue] = [:]) {
    guard isEnabled else { return }
    guard let line = encodedLine(event, fields) else { return }
    writer.append(line)
  }

  /// A stable, salted, non-reversible identifier for a corpus-relative path so
  /// revisits are measurable without the log revealing file names.
  public func pathToken(_ relativePath: String) -> OpenOrgUsageValue {
    .string(Self.token(relativePath, salt: salt))
  }

  nonisolated static func token(_ value: String, salt: String) -> String {
    let digest = SHA256.hash(data: Data((salt + "\u{0}" + value).utf8))
    return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  func encodedLine(_ event: OpenOrgUsageEvent, _ fields: [String: OpenOrgUsageValue]) -> Data? {
    var payload = fields
    payload["event"] = .string(event.rawValue)
    payload["ts"] = .string(Self.timestampFormatter.string(from: now()))
    payload["session"] = .string(sessionID)
    payload["v"] = .int(Self.schemaVersion)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard var data = try? encoder.encode(payload) else { return nil }
    data.append(0x0A)
    return data
  }

  /// Waits for queued writes; used by tests and before revealing the file.
  public func flush() { writer.flush() }

  public func clear() {
    writer.clear()
  }

  private static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}

/// Serial file appender so logging never blocks the main actor on disk I/O.
final class OpenOrgUsageLogWriter: @unchecked Sendable {
  private let fileURL: URL
  private let rotationByteLimit: Int
  private let queue = DispatchQueue(label: "org.org2.workspace.usage-log", qos: .utility)

  init(fileURL: URL, rotationByteLimit: Int) {
    self.fileURL = fileURL
    self.rotationByteLimit = rotationByteLimit
  }

  func append(_ data: Data) {
    queue.async { [fileURL, rotationByteLimit] in
      let manager = FileManager.default
      try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let size = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue,
         size + data.count > rotationByteLimit {
        let previous = fileURL.appendingPathExtension("1")
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: fileURL, to: previous)
      }
      if !manager.fileExists(atPath: fileURL.path) {
        manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    }
  }

  func flush() { queue.sync {} }

  func clear() {
    queue.sync { [fileURL] in
      try? FileManager.default.removeItem(at: fileURL)
      try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("1"))
    }
  }
}

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI

/// Settings section for the opt-in local usage log.
public struct OpenOrgUsageLogSettingsSection: View {
  private let log: OpenOrgUsageLog
  @State private var isEnabled: Bool
  @State private var fileExists = false

  public init(log: OpenOrgUsageLog) {
    self.log = log
    _isEnabled = State(initialValue: log.isEnabled)
  }

  public var body: some View {
    Section {
      Toggle("Keep a local usage log", isOn: $isEnabled)
        .onChange(of: isEnabled) { _, enabled in
          log.isEnabled = enabled
          refreshFileState()
        }
      HStack {
        Button("Show Log in Finder") {
          log.flush()
          refreshFileState()
          if fileExists {
            NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
          } else {
            NSWorkspace.shared.open(log.fileURL.deletingLastPathComponent())
          }
        }
        .disabled(!fileExists && !isEnabled)
        Button("Clear Log", role: .destructive) {
          log.clear()
          refreshFileState()
        }
        .disabled(!fileExists)
      }
    } header: {
      Label("Usage Log", systemImage: "list.bullet.rectangle")
    } footer: {
      Text("Off by default. When on, Celorga appends interaction events to usage-events.jsonl on this Mac: how documents are opened (Quick Open, links, sidebar, history), how long they take to appear, Start Work and chat turn timing, and Activity view use. It records counts, durations, and salted file hashes, never note text, chat text, titles, search queries, or file names. Nothing is uploaded; share the file only if you choose to.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear(perform: refreshFileState)
  }

  private func refreshFileState() {
    log.flush()
    fileExists = FileManager.default.fileExists(atPath: log.fileURL.path)
  }
}
#endif
