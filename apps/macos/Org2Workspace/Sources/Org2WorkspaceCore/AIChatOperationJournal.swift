import CryptoKit
import Darwin
import Foundation

/// A metadata operation queued by the Org2 CLI for OpenOrg to apply to the
/// authoritative AI chat transcript.
public enum AIChatOperation: Sendable, Equatable {
  case settleThread(threadID: String, settledAt: Date)
  case reopenThread(threadID: String)
  case configureAutoSettle(afterSeconds: Double?)
  case autoSettle(evaluatedAt: Date)
}

/// A validated operation and the exact immutable journal file that contained it.
///
/// Instances can only be produced by ``AIChatOperationJournal/load(corpusRoot:)``.
/// This lets the journal verify that a caller removes the same file it loaded,
/// after the caller has committed the corresponding transcript state.
public struct AIChatOperationJournalEntry: Sendable {
  public let id: String
  public let createdAt: Date
  public let operation: AIChatOperation
  public let fileURL: URL

  fileprivate let operationsDirectoryURL: URL
  fileprivate let fingerprint: AIChatOperationFileFingerprint
}

/// A rejected journal file. Rejected files are never removed by the loader.
public struct AIChatOperationJournalIssue: Sendable, Equatable {
  public let fileURL: URL
  public let message: String
}

/// One deterministic snapshot of the operation journal.
public struct AIChatOperationJournalScan: Sendable {
  public let entries: [AIChatOperationJournalEntry]
  public let issues: [AIChatOperationJournalIssue]
}

public enum AIChatOperationJournalError: Error, LocalizedError, Sendable, Equatable {
  case unsafeOperationsDirectory(String)
  case operationFileChanged(String)
  case operationFileMissing(String)
  case operationFileRemovalFailed(String)

  public var errorDescription: String? {
    switch self {
    case .unsafeOperationsDirectory(let path):
      return "Unsafe AI chat operation directory: \(path)"
    case .operationFileChanged(let path):
      return "AI chat operation changed after it was loaded: \(path)"
    case .operationFileMissing(let path):
      return "AI chat operation no longer exists: \(path)"
    case .operationFileRemovalFailed(let path):
      return "Could not remove committed AI chat operation: \(path)"
    }
  }
}

/// Safe, off-main-actor access to the `org2:ai-chat-operation:v1` journal.
public enum AIChatOperationJournal {
  public static let schema = "org2:ai-chat-operation:v1"
  public static let maximumEnvelopeBytes = 512_000

  /// Returns the operation journal directory for a corpus without touching disk.
  public static func operationsDirectory(corpusRoot: URL) -> URL {
    corpusRoot.standardizedFileURL
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("ai-chat-inbox", isDirectory: true)
      .appendingPathComponent("operations", isDirectory: true)
  }

  /// Loads and validates journal entries on a utility task.
  ///
  /// An absent operation directory is an empty journal. An existing directory
  /// must itself be a real directory, not a symbolic link. Invalid individual
  /// `.json` files are reported in ``AIChatOperationJournalScan/issues`` and are
  /// deliberately retained for inspection or retry.
  public static func load(corpusRoot: URL) async throws -> AIChatOperationJournalScan {
    try await Task.detached(priority: .utility) {
      try loadSynchronously(corpusRoot: corpusRoot)
    }.value
  }

  /// Removes the exact file represented by `entry` on a utility task.
  ///
  /// Call this only after the operation's resulting transcript state has reached
  /// its durability barrier. If the file was replaced or edited after loading,
  /// it is retained and this method throws.
  public static func removeCommitted(_ entry: AIChatOperationJournalEntry) async throws {
    try await Task.detached(priority: .utility) {
      try removeCommittedSynchronously(entry)
    }.value
  }

  nonisolated private static func loadSynchronously(
    corpusRoot: URL
  ) throws -> AIChatOperationJournalScan {
    let directory = operationsDirectory(corpusRoot: corpusRoot)
    switch try fileStatus(at: directory) {
    case .missing:
      return AIChatOperationJournalScan(entries: [], issues: [])
    case .present(let status):
      guard status.isDirectory, !status.isSymbolicLink else {
        throw AIChatOperationJournalError.unsafeOperationsDirectory(directory.path)
      }
    }

    let files: [URL]
    do {
      files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      )
      .filter { $0.lastPathComponent.hasSuffix(".json") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
      throw AIChatOperationJournalError.unsafeOperationsDirectory(directory.path)
    }

    var entries: [AIChatOperationJournalEntry] = []
    var issues: [AIChatOperationJournalIssue] = []
    entries.reserveCapacity(files.count)

    for file in files {
      do {
        entries.append(try loadFile(file, in: directory))
      } catch {
        issues.append(AIChatOperationJournalIssue(
          fileURL: file,
          message: error.localizedDescription
        ))
      }
    }

    entries.sort {
      if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
      return $0.id < $1.id
    }
    return AIChatOperationJournalScan(entries: entries, issues: issues)
  }

  nonisolated private static func loadFile(
    _ file: URL,
    in directory: URL
  ) throws -> AIChatOperationJournalEntry {
    guard file.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL else {
      throw JournalFileError.invalid("Operation file is outside the operation directory.")
    }
    let loaded = try readRegularFile(file)
    let decoded = try decodeOperation(loaded.data, file: file)
    return AIChatOperationJournalEntry(
      id: decoded.id,
      createdAt: decoded.createdAt,
      operation: decoded.operation,
      fileURL: file,
      operationsDirectoryURL: directory,
      fingerprint: loaded.fingerprint
    )
  }

  nonisolated static func removeCommittedSynchronously(
    _ entry: AIChatOperationJournalEntry
  ) throws {
    let directory = entry.operationsDirectoryURL.standardizedFileURL
    let file = entry.fileURL.standardizedFileURL
    guard file.deletingLastPathComponent() == directory else {
      throw AIChatOperationJournalError.operationFileChanged(file.path)
    }
    guard case .present(let directoryStatus) = try fileStatus(at: directory),
          directoryStatus.isDirectory,
          !directoryStatus.isSymbolicLink
    else {
      throw AIChatOperationJournalError.unsafeOperationsDirectory(directory.path)
    }

    let current: LoadedRegularFile
    do {
      current = try readRegularFile(file)
    } catch JournalFileError.missing {
      throw AIChatOperationJournalError.operationFileMissing(file.path)
    } catch {
      throw AIChatOperationJournalError.operationFileChanged(file.path)
    }
    guard current.fingerprint == entry.fingerprint else {
      throw AIChatOperationJournalError.operationFileChanged(file.path)
    }

    // Re-check identity immediately before unlinking. The immutable publisher
    // and this check prevent normal writers from replacing a loaded operation.
    guard case .present(let finalStatus) = try fileStatus(at: file),
          finalStatus.fingerprintWithoutDigest == entry.fingerprint.withoutDigest
    else {
      throw AIChatOperationJournalError.operationFileChanged(file.path)
    }
    guard Darwin.unlink(file.path) == 0 else {
      if errno == ENOENT {
        throw AIChatOperationJournalError.operationFileMissing(file.path)
      }
      throw AIChatOperationJournalError.operationFileRemovalFailed(file.path)
    }

    // Best effort: deletion correctness does not depend on filesystems that
    // reject directory fsync, but supporting filesystems get a durable dequeue.
    let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if descriptor >= 0 {
      _ = Darwin.fsync(descriptor)
      _ = Darwin.close(descriptor)
    }
  }

  nonisolated private static func readRegularFile(_ file: URL) throws -> LoadedRegularFile {
    let status: AIChatOperationFileStatus
    switch try fileStatus(at: file) {
    case .missing:
      throw JournalFileError.missing
    case .present(let value):
      status = value
    }
    guard status.isRegularFile, !status.isSymbolicLink else {
      throw JournalFileError.invalid("Operation envelope is not a regular non-symbolic-link file.")
    }
    guard status.size >= 0, status.size <= Int64(maximumEnvelopeBytes) else {
      throw JournalFileError.invalid(
        "Operation envelope exceeds \(maximumEnvelopeBytes) bytes."
      )
    }

    let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { throw JournalFileError.missing }
      throw JournalFileError.invalid("Operation envelope could not be opened safely.")
    }
    defer { _ = Darwin.close(descriptor) }

    var opened = stat()
    guard Darwin.fstat(descriptor, &opened) == 0,
          (opened.st_mode & S_IFMT) == S_IFREG,
          opened.st_size >= 0,
          opened.st_size <= off_t(maximumEnvelopeBytes)
    else {
      throw JournalFileError.invalid("Operation envelope changed or is unsafe.")
    }
    let openedStatus = AIChatOperationFileStatus(opened)
    guard openedStatus.fingerprintWithoutDigest == status.fingerprintWithoutDigest else {
      throw JournalFileError.invalid("Operation envelope changed while it was opened.")
    }

    var data = Data()
    data.reserveCapacity(Int(opened.st_size))
    var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumEnvelopeBytes + 1))
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw JournalFileError.invalid("Operation envelope could not be read safely.")
      }
      data.append(buffer, count: count)
      guard data.count <= maximumEnvelopeBytes else {
        throw JournalFileError.invalid(
          "Operation envelope exceeds \(maximumEnvelopeBytes) bytes."
        )
      }
    }

    var final = stat()
    guard Darwin.fstat(descriptor, &final) == 0 else {
      throw JournalFileError.invalid("Operation envelope changed while it was read.")
    }
    let finalStatus = AIChatOperationFileStatus(final)
    guard finalStatus.fingerprintWithoutDigest == openedStatus.fingerprintWithoutDigest,
          Int64(data.count) == finalStatus.size
    else {
      throw JournalFileError.invalid("Operation envelope changed while it was read.")
    }

    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return LoadedRegularFile(
      data: data,
      fingerprint: AIChatOperationFileFingerprint(
        device: finalStatus.device,
        inode: finalStatus.inode,
        size: finalStatus.size,
        digest: digest
      )
    )
  }

  nonisolated private static func decodeOperation(
    _ data: Data,
    file: URL
  ) throws -> DecodedOperation {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw JournalFileError.invalid("Invalid JSON in \(file.lastPathComponent).")
    }
    guard let fields = object as? [String: Any],
          fields["schema"] as? String == schema,
          let id = fields["id"] as? String,
          isValidUUID(id),
          let createdAtText = fields["createdAt"] as? String,
          let createdAt = parseDate(createdAtText),
          let kind = fields["kind"] as? String
    else {
      throw JournalFileError.invalid("Invalid AI chat operation envelope in \(file.lastPathComponent).")
    }

    let operation: AIChatOperation
    switch kind {
    case "settle-thread":
      guard let threadID = fields["threadID"] as? String,
            isValidIdentifier(threadID),
            let settledAtText = fields["settledAt"] as? String,
            let settledAt = parseDate(settledAtText)
      else {
        throw JournalFileError.invalid("Invalid settle-thread operation in \(file.lastPathComponent).")
      }
      operation = .settleThread(threadID: threadID, settledAt: settledAt)
    case "reopen-thread":
      guard let threadID = fields["threadID"] as? String, isValidIdentifier(threadID) else {
        throw JournalFileError.invalid("Invalid reopen-thread operation in \(file.lastPathComponent).")
      }
      operation = .reopenThread(threadID: threadID)
    case "configure-auto-settle":
      guard fields.keys.contains("autoSettleAfterSeconds") else {
        throw JournalFileError.invalid(
          "Invalid configure-auto-settle operation in \(file.lastPathComponent)."
        )
      }
      if fields["autoSettleAfterSeconds"] is NSNull {
        operation = .configureAutoSettle(afterSeconds: nil)
      } else if let number = fields["autoSettleAfterSeconds"] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite,
                number.doubleValue > 0 {
        operation = .configureAutoSettle(afterSeconds: number.doubleValue)
      } else {
        throw JournalFileError.invalid(
          "Invalid configure-auto-settle operation in \(file.lastPathComponent)."
        )
      }
    case "auto-settle":
      guard let evaluatedAtText = fields["evaluatedAt"] as? String,
            let evaluatedAt = parseDate(evaluatedAtText)
      else {
        throw JournalFileError.invalid("Invalid auto-settle operation in \(file.lastPathComponent).")
      }
      operation = .autoSettle(evaluatedAt: evaluatedAt)
    default:
      throw JournalFileError.invalid("Unsupported AI chat operation in \(file.lastPathComponent).")
    }
    return DecodedOperation(id: id, createdAt: createdAt, operation: operation)
  }

  nonisolated private static func isValidIdentifier(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && value.utf16.count <= 1_000
  }

  nonisolated private static func isValidUUID(_ value: String) -> Bool {
    let characters = Array(value.utf8)
    guard characters.count == 36 else { return false }
    let hyphens = Set([8, 13, 18, 23])
    for (index, character) in characters.enumerated() {
      if hyphens.contains(index) {
        guard character == 45 else { return false }
      } else {
        let isDigit = character >= 48 && character <= 57
        let isLowerHex = character >= 97 && character <= 102
        let isUpperHex = character >= 65 && character <= 70
        guard isDigit || isLowerHex || isUpperHex else { return false }
      }
    }
    guard characters[14] >= 49, characters[14] <= 56 else { return false }
    return [56, 57, 65, 66, 97, 98].contains(characters[19])
  }

  nonisolated private static func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value), date.timeIntervalSinceReferenceDate.isFinite {
      return date
    }
    let wholeSeconds = ISO8601DateFormatter()
    wholeSeconds.formatOptions = [.withInternetDateTime]
    guard let date = wholeSeconds.date(from: value), date.timeIntervalSinceReferenceDate.isFinite else {
      return nil
    }
    return date
  }

  nonisolated private static func fileStatus(at url: URL) throws -> FileStatusResult {
    var value = stat()
    if Darwin.lstat(url.path, &value) == 0 {
      return .present(AIChatOperationFileStatus(value))
    }
    if errno == ENOENT { return .missing }
    throw JournalFileError.invalid("Could not inspect \(url.lastPathComponent).")
  }
}

private struct DecodedOperation {
  let id: String
  let createdAt: Date
  let operation: AIChatOperation
}

private struct LoadedRegularFile {
  let data: Data
  let fingerprint: AIChatOperationFileFingerprint
}

private struct AIChatOperationFileFingerprint: Sendable, Equatable {
  let device: UInt64
  let inode: UInt64
  let size: Int64
  let digest: String

  var withoutDigest: AIChatOperationFileIdentity {
    AIChatOperationFileIdentity(device: device, inode: inode, size: size)
  }
}

private struct AIChatOperationFileIdentity: Sendable, Equatable {
  let device: UInt64
  let inode: UInt64
  let size: Int64
}

private struct AIChatOperationFileStatus {
  let mode: mode_t
  let device: UInt64
  let inode: UInt64
  let size: Int64

  init(_ value: stat) {
    mode = value.st_mode
    device = UInt64(value.st_dev)
    inode = UInt64(value.st_ino)
    size = Int64(value.st_size)
  }

  var isDirectory: Bool { (mode & S_IFMT) == S_IFDIR }
  var isRegularFile: Bool { (mode & S_IFMT) == S_IFREG }
  var isSymbolicLink: Bool { (mode & S_IFMT) == S_IFLNK }
  var fingerprintWithoutDigest: AIChatOperationFileIdentity {
    AIChatOperationFileIdentity(device: device, inode: inode, size: size)
  }
}

private enum FileStatusResult {
  case missing
  case present(AIChatOperationFileStatus)
}

private enum JournalFileError: Error, LocalizedError {
  case missing
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .missing:
      return "Operation envelope no longer exists."
    case .invalid(let message):
      return message
    }
  }
}
