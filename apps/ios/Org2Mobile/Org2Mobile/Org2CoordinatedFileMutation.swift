import Darwin
import CoreFoundation
import Foundation

enum Org2CoordinatedFileMutation {
  private struct MutationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  enum LockPhase: String {
    case choosing
    case ticket
  }

  private struct LockOwner {
    let raw: Data
    let host: String
    let pid: pid_t
    let token: String
    let phase: LockPhase
    let ticket: UInt64?
  }

  private struct LockParticipant {
    let url: URL
    let owner: LockOwner
  }

  private struct HeldMutationLock {
    let ticketURL: URL
    let owner: Data
  }

  static let lockOwnerSchema = "org2:mutation-lock-owner:v2"
  static let maximumSafeTicket: UInt64 = 9_007_199_254_740_991
  private static let ticketFilenameWidth = 16

  static func mutationLockURL(for fileURL: URL) -> URL {
    fileURL
      .deletingLastPathComponent()
      .appendingPathComponent(".\(fileURL.lastPathComponent).org2-mutation.lock")
  }

  static func mutateTextAtomically<Result>(
    at fileURL: URL,
    expectedText: String? = nil,
    createIfMissing: Bool = false,
    _ mutation: (String) throws -> (text: String, result: Result)
  ) throws -> Result {
    try withMutationLock(for: fileURL) {
      let existed = FileManager.default.fileExists(atPath: fileURL.path)
      guard existed || createIfMissing else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: fileURL.path])
      }
      let current = existed ? try String(contentsOf: fileURL, encoding: .utf8) : ""
      if let expectedText, current != expectedText {
        throw MutationError(message: "The file changed since it was reviewed. Refresh and try again.")
      }

      let mutationResult = try mutation(current)
      if mutationResult.text != current {
        if existed {
          let latest = try String(contentsOf: fileURL, encoding: .utf8)
          guard latest == current else {
            throw MutationError(message: "A competing writer changed the file during the Org2 mutation. Refresh and try again.")
          }
          try replaceAtomically(fileURL: fileURL, text: mutationResult.text)
        } else {
          try createAtomicallyIfMissing(fileURL: fileURL, text: mutationResult.text)
        }
      }
      return mutationResult.result
    }
  }

  private static func withMutationLock<Result>(
    for fileURL: URL,
    _ operation: () throws -> Result
  ) throws -> Result {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let lockURL = mutationLockURL(for: fileURL)
    let heldLock = try acquireMutationLock(lockURL)

    do {
      let result = try operation()
      guard try removeParticipantIfOwned(heldLock.ticketURL, owner: heldLock.owner) else {
        throw MutationError(message: "The Org2 mutation lock ticket changed before it could be released.")
      }
      return result
    } catch {
      _ = try? removeParticipantIfOwned(heldLock.ticketURL, owner: heldLock.owner)
      throw error
    }
  }

  private static func acquireMutationLock(_ lockURL: URL) throws -> HeldMutationLock {
    try ensureLockDirectory(lockURL)
    let token = UUID().uuidString.lowercased()
    let host = ProcessInfo.processInfo.hostName
    let pid = ProcessInfo.processInfo.processIdentifier
    let createdAt = ISO8601DateFormatter().string(from: Date())
    let choosingURL = lockURL.appendingPathComponent(choosingFilename(token: token))
    let choosingOwner = try lockOwnerData(
      host: host,
      pid: pid,
      token: token,
      phase: .choosing,
      ticket: nil,
      createdAt: createdAt
    )
    var choosingPublished = false
    var ticketURL: URL?
    var ticketOwner: Data?

    do {
      try publishImmutable(choosingOwner, to: choosingURL)
      choosingPublished = true

      let observed = try activeParticipants(in: lockURL, currentHost: host)
      let maximumTicket = observed.compactMap(\.owner.ticket).max() ?? 0
      guard maximumTicket < maximumSafeTicket else {
        throw MutationError(message: "The Org2 mutation lock ticket counter reached its maximum safe value.")
      }
      let ticket = maximumTicket + 1
      let nextTicketURL = lockURL.appendingPathComponent(ticketFilename(ticket: ticket, token: token))
      let nextTicketOwner = try lockOwnerData(
        host: host,
        pid: pid,
        token: token,
        phase: .ticket,
        ticket: ticket,
        createdAt: createdAt
      )
      try publishImmutable(nextTicketOwner, to: nextTicketURL)
      ticketURL = nextTicketURL
      ticketOwner = nextTicketOwner

      guard try removeParticipantIfOwned(choosingURL, owner: choosingOwner) else {
        throw MutationError(message: "The Org2 mutation choosing marker changed before ticket publication completed.")
      }
      choosingPublished = false

      let contenders = try activeParticipants(in: lockURL, currentHost: host)
      if contenders.contains(where: { $0.owner.phase == .choosing && $0.owner.token != token }) {
        throw MutationError(message: "Another Org2 process is already choosing a mutation lock ticket.")
      }
      let tickets = contenders
        .filter { $0.owner.phase == .ticket }
        .sorted(by: participantPrecedes)
      guard let winner = tickets.first,
            winner.owner.token == token,
            winner.owner.ticket == ticket,
            winner.owner.raw == nextTicketOwner else {
        throw MutationError(message: "Another Org2 process is already updating \(lockURL.lastPathComponent).")
      }

      return HeldMutationLock(ticketURL: nextTicketURL, owner: nextTicketOwner)
    } catch {
      if let ticketURL, let ticketOwner {
        _ = try? removeParticipantIfOwned(ticketURL, owner: ticketOwner)
      }
      if choosingPublished {
        _ = try? removeParticipantIfOwned(choosingURL, owner: choosingOwner)
      }
      throw error
    }
  }

  private static func ensureLockDirectory(_ lockURL: URL) throws {
    if Darwin.mkdir(lockURL.path, mode_t(S_IRWXU)) == 0 {
      return
    }
    let createError = errno
    guard createError == EEXIST else {
      throw posixError(operation: "create mutation lock directory", path: lockURL.path, code: createError)
    }

    var status = stat()
    guard Darwin.lstat(lockURL.path, &status) == 0,
          status.st_mode & S_IFMT == S_IFDIR else {
      throw MutationError(
        message: "A legacy or unsupported Org2 mutation lock exists at \(lockURL.lastPathComponent); refusing to replace it automatically."
      )
    }
  }

  static func choosingFilename(token: String) -> String {
    "choosing.\(token).json"
  }

  static func ticketFilename(ticket: UInt64, token: String) -> String {
    "ticket.\(String(format: "%0\(ticketFilenameWidth)llu", ticket)).\(token).json"
  }

  static func lockOwnerData(
    host: String,
    pid: pid_t,
    token: String,
    phase: LockPhase,
    ticket: UInt64?,
    createdAt: String
  ) throws -> Data {
    var object: [String: Any] = [
      "schema": lockOwnerSchema,
      "host": host,
      "pid": Int(pid),
      "token": token,
      "phase": phase.rawValue,
      "createdAt": createdAt,
    ]
    if let ticket {
      object["ticket"] = ticket
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      + Data("\n".utf8)
  }

  private static func publishImmutable(_ data: Data, to participantURL: URL) throws {
    let candidateURL = participantURL
      .deletingLastPathComponent()
      .appendingPathComponent(".candidate.\(UUID().uuidString.lowercased()).tmp")
    try createLockCandidate(candidateURL, owner: data)
    defer { _ = Darwin.unlink(candidateURL.path) }
    if Darwin.link(candidateURL.path, participantURL.path) != 0 {
      throw posixError(operation: "publish mutation lock participant", path: participantURL.path)
    }
  }

  private static func createLockCandidate(_ candidateURL: URL, owner: Data) throws {
    let descriptor = Darwin.open(
      candidateURL.path,
      O_WRONLY | O_CREAT | O_EXCL,
      mode_t(S_IRUSR | S_IWUSR)
    )
    guard descriptor >= 0 else {
      throw posixError(operation: "create mutation lock candidate", path: candidateURL.path)
    }

    var descriptorIsOpen = true
    do {
      try writeAll(owner, to: descriptor, path: candidateURL.path)
      if Darwin.fsync(descriptor) != 0 {
        throw posixError(operation: "flush mutation lock candidate", path: candidateURL.path)
      }
      let closeResult = Darwin.close(descriptor)
      descriptorIsOpen = false
      if closeResult != 0 {
        throw posixError(operation: "close mutation lock candidate", path: candidateURL.path)
      }
    } catch {
      if descriptorIsOpen {
        _ = Darwin.close(descriptor)
      }
      _ = Darwin.unlink(candidateURL.path)
      throw error
    }
  }

  private static func activeParticipants(
    in lockURL: URL,
    currentHost: String
  ) throws -> [LockParticipant] {
    let urls = try FileManager.default.contentsOfDirectory(
      at: lockURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    var participants: [LockParticipant] = []
    for url in urls.sorted(by: { utf8Precedes($0.lastPathComponent, $1.lastPathComponent) }) {
      let name = url.lastPathComponent
      if name.hasPrefix(".candidate.") {
        continue
      }
      guard let identity = participantIdentity(filename: name) else {
        throw MutationError(message: "Unsupported entry \(name) exists in the Org2 mutation lock directory.")
      }
      guard let data = try? Data(contentsOf: url) else {
        if !FileManager.default.fileExists(atPath: url.path) { continue }
        throw MutationError(message: "Could not read Org2 mutation lock participant \(name).")
      }
      guard let owner = lockOwner(data: data),
            owner.token == identity.token,
            owner.phase == identity.phase,
            owner.ticket == identity.ticket else {
        throw MutationError(message: "Malformed Org2 mutation lock participant \(name).")
      }

      if owner.host == currentHost, !processIsAlive(owner.pid) {
        _ = try removeParticipantIfOwned(url, owner: owner.raw)
        continue
      }
      participants.append(LockParticipant(url: url, owner: owner))
    }
    return participants
  }

  private static func participantIdentity(
    filename: String
  ) -> (phase: LockPhase, ticket: UInt64?, token: String)? {
    let parts = filename.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    if parts.count == 3,
       parts[0] == LockPhase.choosing.rawValue,
       parts[2] == "json",
       isValidToken(parts[1]) {
      return (.choosing, nil, parts[1])
    }
    if parts.count == 4,
       parts[0] == LockPhase.ticket.rawValue,
       parts[3] == "json",
       parts[1].count == ticketFilenameWidth,
       parts[1].allSatisfy(\.isNumber),
       let ticket = UInt64(parts[1]),
       ticket > 0,
       ticket <= maximumSafeTicket,
       parts[1] == String(format: "%0\(ticketFilenameWidth)llu", ticket),
       isValidToken(parts[2]) {
      return (.ticket, ticket, parts[2])
    }
    return nil
  }

  private static func lockOwner(data: Data) -> LockOwner? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys).isSubset(of: ["schema", "host", "pid", "token", "phase", "ticket", "createdAt"]),
          object["schema"] as? String == lockOwnerSchema,
          let host = object["host"] as? String,
          !host.isEmpty,
          let pidNumber = object["pid"] as? NSNumber,
          CFGetTypeID(pidNumber) != CFBooleanGetTypeID(),
          pidNumber.doubleValue.isFinite,
          pidNumber.doubleValue == Double(pidNumber.int64Value),
          pidNumber.int64Value > 0,
          pidNumber.int64Value <= Int64(Int32.max),
          let token = object["token"] as? String,
          isValidToken(token),
          let rawPhase = object["phase"] as? String,
          let phase = LockPhase(rawValue: rawPhase),
          let createdAt = object["createdAt"] as? String,
          !createdAt.isEmpty else {
      return nil
    }
    let ticket: UInt64?
    if let ticketNumber = object["ticket"] as? NSNumber {
      guard CFGetTypeID(ticketNumber) != CFBooleanGetTypeID() else {
        return nil
      }
      let value = ticketNumber.uint64Value
      guard value > 0,
            value <= maximumSafeTicket,
            ticketNumber.doubleValue == Double(value) else {
        return nil
      }
      ticket = value
    } else {
      ticket = nil
    }
    guard (phase == .choosing && ticket == nil)
            || (phase == .ticket && ticket != nil) else {
      return nil
    }
    return LockOwner(
      raw: data,
      host: host,
      pid: pid_t(pidNumber.int32Value),
      token: token,
      phase: phase,
      ticket: ticket
    )
  }

  private static func isValidToken(_ token: String) -> Bool {
    guard token.count == 36 else { return false }
    let scalars = Array(token.unicodeScalars)
    for (index, scalar) in scalars.enumerated() {
      if [8, 13, 18, 23].contains(index) {
        if scalar != "-" { return false }
      } else if !(("0"..."9").contains(Character(String(scalar)))
                    || ("a"..."f").contains(Character(String(scalar)))) {
        return false
      }
    }
    return true
  }

  private static func participantPrecedes(
    _ lhs: LockParticipant,
    _ rhs: LockParticipant
  ) -> Bool {
    let leftTicket = lhs.owner.ticket ?? maximumSafeTicket
    let rightTicket = rhs.owner.ticket ?? maximumSafeTicket
    if leftTicket != rightTicket {
      return leftTicket < rightTicket
    }
    return utf8Precedes(lhs.owner.token, rhs.owner.token)
  }

  private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }

  private static func processIsAlive(_ pid: pid_t) -> Bool {
    if Darwin.kill(pid, 0) == 0 {
      return true
    }
    return errno != ESRCH
  }

  @discardableResult
  private static func removeParticipantIfOwned(_ url: URL, owner: Data) throws -> Bool {
    guard let current = try? Data(contentsOf: url), current == owner else { return false }
    if Darwin.unlink(url.path) != 0 {
      if errno == ENOENT { return false }
      throw posixError(operation: "remove mutation lock participant", path: url.path)
    }
    return true
  }

  private static func createAtomicallyIfMissing(fileURL: URL, text: String) throws {
    let temporaryURL = fileURL
      .deletingLastPathComponent()
      .appendingPathComponent(
        ".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
      )
    let descriptor = Darwin.open(
      temporaryURL.path,
      O_WRONLY | O_CREAT | O_EXCL,
      mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    )
    guard descriptor >= 0 else {
      throw posixError(operation: "create temporary Org2 file", path: temporaryURL.path)
    }

    var descriptorIsOpen = true
    do {
      try writeAll(Data(text.utf8), to: descriptor, path: temporaryURL.path)
      if Darwin.fsync(descriptor) != 0 {
        throw posixError(operation: "flush temporary Org2 file", path: temporaryURL.path)
      }
      let closeResult = Darwin.close(descriptor)
      descriptorIsOpen = false
      if closeResult != 0 {
        throw posixError(operation: "close temporary Org2 file", path: temporaryURL.path)
      }
      if Darwin.link(temporaryURL.path, fileURL.path) != 0 {
        if errno == EEXIST {
          throw MutationError(message: "A competing writer created the file during the Org2 mutation. Refresh and try again.")
        }
        throw posixError(operation: "publish new Org2 file", path: fileURL.path)
      }
      _ = Darwin.unlink(temporaryURL.path)
    } catch {
      if descriptorIsOpen {
        _ = Darwin.close(descriptor)
      }
      _ = Darwin.unlink(temporaryURL.path)
      throw error
    }
  }

  private static func replaceAtomically(fileURL: URL, text: String) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
    let temporaryURL = fileURL
      .deletingLastPathComponent()
      .appendingPathComponent(
        ".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
      )
    let descriptor = Darwin.open(
      temporaryURL.path,
      O_WRONLY | O_CREAT | O_EXCL,
      mode_t(permissions)
    )
    guard descriptor >= 0 else {
      throw posixError(operation: "create temporary mutation file", path: temporaryURL.path)
    }

    var descriptorIsOpen = true
    do {
      try writeAll(Data(text.utf8), to: descriptor, path: temporaryURL.path)
      if Darwin.fsync(descriptor) != 0 {
        throw posixError(operation: "flush temporary mutation file", path: temporaryURL.path)
      }
      let closeResult = Darwin.close(descriptor)
      descriptorIsOpen = false
      if closeResult != 0 {
        throw posixError(operation: "close temporary mutation file", path: temporaryURL.path)
      }
      if Darwin.rename(temporaryURL.path, fileURL.path) != 0 {
        throw posixError(operation: "replace Org2 file", path: fileURL.path)
      }
    } catch {
      if descriptorIsOpen {
        _ = Darwin.close(descriptor)
      }
      _ = Darwin.unlink(temporaryURL.path)
      throw error
    }
  }

  private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0 {
          if errno == EINTR { continue }
          throw posixError(operation: "write", path: path)
        }
        offset += count
      }
    }
  }

  private static func posixError(
    operation: String,
    path: String,
    code: Int32 = errno
  ) -> MutationError {
    MutationError(
      message: "\(operation) failed for \(URL(fileURLWithPath: path).lastPathComponent): \(String(cString: strerror(code)))"
    )
  }
}
