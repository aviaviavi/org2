import Foundation
import LocalAuthentication
import Security

public enum OrgCryptAction: String, CaseIterable, Sendable {
  case decrypt
  case encrypt
  case reencrypt

  public var title: String {
    switch self {
    case .decrypt: "Decrypt"
    case .encrypt: "Encrypt"
    case .reencrypt: "Re-encrypt"
    }
  }
}

public struct OrgCryptRunResult: Equatable, Sendable {
  public let succeeded: Bool
  public let changed: Bool
  public let headingLine: Int?
  public let message: String

  public static func success(changed: Bool, headingLine: Int?, message: String) -> OrgCryptRunResult {
    OrgCryptRunResult(succeeded: true, changed: changed, headingLine: headingLine, message: message)
  }

  public static func failure(message: String, headingLine: Int? = nil) -> OrgCryptRunResult {
    OrgCryptRunResult(succeeded: false, changed: false, headingLine: headingLine, message: message)
  }
}

public struct OrgCryptSettings: Equatable, Sendable {
  public var encryptOnSave: Bool
  public var recipients: [String]
  public var recipientFiles: [String]
  public var gpgProgram: String
  public var passphrase: String?
  public var gpgTimeout: TimeInterval
  public var useDefaultGpgKey: Bool

  public init(
    encryptOnSave: Bool = true,
    recipients: [String] = [],
    recipientFiles: [String] = [],
    gpgProgram: String = "gpg",
    passphrase: String? = nil,
    gpgTimeout: TimeInterval = 30,
    useDefaultGpgKey: Bool = true
  ) {
    self.encryptOnSave = encryptOnSave
    self.recipients = recipients
    self.recipientFiles = recipientFiles
    self.gpgProgram = gpgProgram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpg" : gpgProgram
    self.passphrase = passphrase?.isEmpty == false ? passphrase : nil
    self.gpgTimeout = max(0.1, gpgTimeout)
    self.useDefaultGpgKey = useDefaultGpgKey
  }

  public var canEncryptWithoutSubtreeProperties: Bool {
    passphrase != nil || useDefaultGpgKey || !recipients.isEmpty || !recipientFiles.isEmpty
  }

  public static func splitListText(_ raw: String) -> [String] {
    raw
      .split { character in
        character == "," || character == "\n"
      }
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  public static func listText(_ values: [String]) -> String {
    values.joined(separator: "\n")
  }
}

public enum OrgCrypt {
  public struct PlaintextTarget: Equatable, Sendable {
    public let headingLine: Int
    public let bodyStartLine: Int
    public let endLine: Int
    public let recipients: [String]
    public let recipientFiles: [String]
  }

  public struct PGPArmorSummary: Equatable, Sendable {
    public let lineCount: Int
    public let payloadLineCount: Int
    public let byteCount: Int
  }

  public struct EncryptionResult: Equatable, Sendable {
    public let text: String
    public let encryptedCount: Int
  }

  public static func findPlaintextCryptSubtrees(in text: String, file: String? = nil) -> [PlaintextTarget] {
    let lines = normalizedLines(text)
    var targets: [PlaintextTarget] = []

    var index = 0
    while index < lines.count {
      guard headingHasCryptTag(lines[index]) else {
        index += 1
        continue
      }

      let endLine = subtreeEndLine(lines: lines, headingLine: index)
      let bodyStart = encryptedBodyStartLine(lines: lines, headingLine: index, endLine: endLine)
      defer {
        index = max(index + 1, endLine)
      }

      guard !subtreeContainsPGPBlock(lines: lines, startLine: bodyStart, endLine: endLine) else {
        continue
      }

      let plainBody = lines[bodyStart..<endLine].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !plainBody.isEmpty else { continue }

      let properties = cryptProperties(lines: lines, headingLine: index, endLine: endLine, file: file)
      targets.append(PlaintextTarget(
        headingLine: index + 1,
        bodyStartLine: bodyStart,
        endLine: endLine,
        recipients: properties.recipients,
        recipientFiles: properties.recipientFiles
      ))
    }

    return targets
  }

  public static func hasUnclosedPGPBlock(_ text: String) -> Bool {
    var inBlock = false
    for line in normalizedLines(text) {
      if isPGPBegin(line) { inBlock = true }
      if isPGPEnd(line) { inBlock = false }
    }
    return inBlock
  }

  public static func armorSummary(_ raw: String) -> PGPArmorSummary? {
    let lines = normalizedLines(raw).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard let first = lines.first,
          let last = lines.last,
          isPGPBegin(first),
          isPGPEnd(last)
    else {
      return nil
    }

    return PGPArmorSummary(
      lineCount: lines.count,
      payloadLineCount: max(0, lines.count - 2),
      byteCount: Data(raw.utf8).count
    )
  }

  public static func encryptPlaintextCryptSubtrees(
    in text: String,
    file: String,
    settings: OrgCryptSettings
  ) throws -> EncryptionResult {
    guard settings.encryptOnSave else {
      return EncryptionResult(text: text, encryptedCount: 0)
    }
    guard !hasUnclosedPGPBlock(text) else {
      return EncryptionResult(text: text, encryptedCount: 0)
    }

    let targets = findPlaintextCryptSubtrees(in: text, file: file)
    guard !targets.isEmpty else {
      return EncryptionResult(text: text, encryptedCount: 0)
    }

    var replacements: [LineReplacement] = []
    let lines = normalizedLines(text)
    let cwd = URL(fileURLWithPath: file).deletingLastPathComponent()

    for target in targets {
      let recipients = unique(settings.recipients + target.recipients)
      let recipientFiles = unique(settings.recipientFiles + target.recipientFiles)
      let targetSettings = OrgCryptSettings(
        encryptOnSave: settings.encryptOnSave,
        recipients: recipients,
        recipientFiles: recipientFiles,
        gpgProgram: settings.gpgProgram,
        passphrase: settings.passphrase,
        gpgTimeout: settings.gpgTimeout,
        useDefaultGpgKey: settings.useDefaultGpgKey
      )
      guard targetSettings.canEncryptWithoutSubtreeProperties else {
        throw OrgCryptError.missingEncryptionConfiguration
      }

      let plainBody = lines[target.bodyStartLine..<target.endLine].joined(separator: "\n") + "\n"
      let encrypted = try runGPGEncrypt(plainBody, cwd: cwd, settings: targetSettings)
      replacements.append(LineReplacement(startLine: target.bodyStartLine, endLine: target.endLine, text: encrypted))
    }

    return EncryptionResult(text: replaceLineRanges(in: text, replacements: replacements), encryptedCount: replacements.count)
  }

  private struct LineReplacement {
    let startLine: Int
    let endLine: Int
    let text: String
  }

  private static func runGPGEncrypt(_ input: String, cwd: URL, settings: OrgCryptSettings) throws -> String {
    let fileManager = FileManager.default
    let tempDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("org2-crypt-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDirectory) }

    let inputURL = tempDirectory.appendingPathComponent("input.txt")
    let outputURL = tempDirectory.appendingPathComponent("output.asc")
    let errorURL = tempDirectory.appendingPathComponent("stderr.txt")
    try Data(input.utf8).write(to: inputURL)
    try Data().write(to: outputURL)
    try Data().write(to: errorURL)

    let stdin = try FileHandle(forReadingFrom: inputURL)
    let stdout = try FileHandle(forWritingTo: outputURL)
    let stderr = try FileHandle(forWritingTo: errorURL)
    defer {
      stdin.closeFile()
      stdout.closeFile()
      stderr.closeFile()
    }

    let process = Process()
    process.currentDirectoryURL = cwd
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

    let defaultRecipient = settings.useDefaultGpgKey ? resolveDefaultGPGRecipient(gpgProgram: settings.gpgProgram) : nil
    if settings.useDefaultGpgKey, defaultRecipient == nil {
      throw OrgCryptError.gpgFailed("GPG default key is not configured as an encryption recipient.")
    }

    var arguments = [settings.gpgProgram, "--batch", "--yes", "--pinentry-mode", "loopback", "--trust-model", "always"]
    if let passphrase = settings.passphrase {
      arguments += ["--passphrase", passphrase]
    }

    if defaultRecipient != nil || !settings.recipients.isEmpty || !settings.recipientFiles.isEmpty {
      arguments += ["--armor", "--encrypt"]
      if let defaultRecipient {
        arguments += ["--recipient", defaultRecipient]
      }
      for recipient in settings.recipients {
        arguments += ["--recipient", recipient]
      }
      for recipientFile in settings.recipientFiles {
        arguments += ["--recipient-file", recipientFile]
      }
    } else {
      arguments += ["--armor", "--symmetric", "--cipher-algo", "AES256"]
    }
    process.arguments = arguments

    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      process.waitUntilExit()
      semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + .milliseconds(Int(settings.gpgTimeout * 1000))) == .timedOut {
      if process.isRunning {
        process.terminate()
      }
      _ = semaphore.wait(timeout: .now() + .seconds(2))
      throw OrgCryptError.gpgTimedOut(settings.gpgTimeout, readTrimmedFile(errorURL))
    }

    guard process.terminationStatus == 0 else {
      let message = readTrimmedFile(errorURL)
      throw OrgCryptError.gpgFailed(message?.isEmpty == false ? message! : "gpg exited with status \(process.terminationStatus)")
    }

    return (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
  }

  private static func resolveDefaultGPGRecipient(gpgProgram: String) -> String? {
    for candidate in gpgConfCandidates(gpgProgram: gpgProgram) {
      guard let output = runGPGConf(candidate) else { continue }
      for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
        guard line.hasPrefix("default-key:") else { continue }
        let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count > 9 else { continue }
        let value = fields[9]
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
        if !value.isEmpty {
          return value
        }
      }
    }
    return nil
  }

  private static func gpgConfCandidates(gpgProgram: String) -> [String] {
    var candidates: [String] = []
    let trimmed = gpgProgram.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, trimmed.contains("/") {
      let url = URL(fileURLWithPath: trimmed)
      candidates.append(url.deletingLastPathComponent().appendingPathComponent("gpgconf").path)
    }
    candidates.append(contentsOf: [
      "/opt/homebrew/bin/gpgconf",
      "/usr/local/bin/gpgconf",
      "/usr/local/MacGPG2/bin/gpgconf",
      "gpgconf"
    ])
    return unique(candidates)
  }

  private static func runGPGConf(_ candidate: String) -> String? {
    let output = Pipe()
    let error = Pipe()
    let process = Process()
    if candidate.contains("/") {
      process.executableURL = URL(fileURLWithPath: candidate)
      process.arguments = ["--list-options", "gpg"]
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [candidate, "--list-options", "gpg"]
    }
    process.standardOutput = output
    process.standardError = error

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }

    guard process.terminationStatus == 0 else { return nil }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
  }

  private static func readTrimmedFile(_ url: URL) -> String? {
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func replaceLineRanges(in text: String, replacements: [LineReplacement]) -> String {
    let hadTrailingNewline = text.hasSuffix("\n")
    var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if hadTrailingNewline && lines.last == "" {
      lines.removeLast()
    }

    for replacement in replacements.sorted(by: { $0.startLine > $1.startLine }) {
      var newLines = replacement.text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingTrailingNewline()
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      if newLines == [""] {
        newLines = []
      }
      lines.replaceSubrange(replacement.startLine..<replacement.endLine, with: newLines)
    }

    return lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
  }

  private static func cryptProperties(
    lines: [String],
    headingLine: Int,
    endLine: Int,
    file: String?
  ) -> (recipients: [String], recipientFiles: [String]) {
    var recipients: [String] = []
    var recipientFiles: [String] = []
    var inDrawer = false
    for index in (headingLine + 1)..<endLine {
      let line = lines[index]
      if !inDrawer {
        if line.range(of: #"^\s*:PROPERTIES:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
          inDrawer = true
        } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          break
        }
        continue
      }
      if line.range(of: #"^\s*:END:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
        break
      }
      guard let match = line.firstMatch(of: /^\s*:([^:]+):\s*(.*?)\s*$/) else { continue }
      let key = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: "-", with: "_")
      let values = OrgCryptSettings.splitListText(String(match.2))
      if key == "CRYPT_RECIPIENT" || key == "CRYPT_RECIPIENTS" {
        recipients.append(contentsOf: values)
      } else if key == "CRYPT_RECIPIENT_FILE" || key == "CRYPT_RECIPIENT_FILES" {
        recipientFiles.append(contentsOf: values.map { value in
          guard let file, !NSString(string: value).isAbsolutePath else { return value }
          return URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent(value).standardizedFileURL.path
        })
      }
    }
    return (unique(recipients), unique(recipientFiles))
  }

  private static func headingHasCryptTag(_ line: String) -> Bool {
    guard let match = line.firstMatch(of: /^(\*+)\s+(.*)$/) else { return false }
    return String(match.2).range(of: #"(?:^|:)crypt(?::|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
  }

  private static func lineIsHeading(_ line: String) -> Bool {
    line.firstMatch(of: /^(\*+)\s+/) != nil
  }

  private static func headingLevel(_ line: String) -> Int {
    guard let match = line.firstMatch(of: /^(\*+)\s+/) else { return 0 }
    return match.1.count
  }

  private static func subtreeEndLine(lines: [String], headingLine: Int) -> Int {
    let level = headingLevel(lines[headingLine])
    guard level > 0 else { return headingLine + 1 }
    for index in (headingLine + 1)..<lines.count {
      if lineIsHeading(lines[index]) && headingLevel(lines[index]) <= level {
        return index
      }
    }
    return lines.count
  }

  private static func encryptedBodyStartLine(lines: [String], headingLine: Int, endLine: Int) -> Int {
    let bodyStart = headingLine + 1
    guard bodyStart < endLine else { return bodyStart }
    if lines[bodyStart].range(of: #"^\s*:PROPERTIES:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
      for index in (bodyStart + 1)..<endLine {
        if lines[index].range(of: #"^\s*:END:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
          return index + 1
        }
      }
    }
    return bodyStart
  }

  private static func subtreeContainsPGPBlock(lines: [String], startLine: Int, endLine: Int) -> Bool {
    guard startLine < endLine else { return false }
    for index in startLine..<endLine where isPGPBegin(lines[index]) {
      return true
    }
    return false
  }

  private static func isPGPBegin(_ line: String) -> Bool {
    line.range(of: #"^\s*-----BEGIN PGP MESSAGE-----\s*$"#, options: .regularExpression) != nil
  }

  private static func isPGPEnd(_ line: String) -> Bool {
    line.range(of: #"^\s*-----END PGP MESSAGE-----\s*$"#, options: .regularExpression) != nil
  }

  private static func normalizedLines(_ text: String) -> [String] {
    text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var output: [String] = []
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
      seen.insert(trimmed)
      output.append(trimmed)
    }
    return output
  }
}

public enum OrgCryptError: LocalizedError, Equatable {
  case missingEncryptionConfiguration
  case gpgFailed(String)
  case gpgTimedOut(TimeInterval, String?)

  public var errorDescription: String? {
    switch self {
    case .missingEncryptionConfiguration:
      "Org crypt needs a passphrase, the default GPG key option, configured recipients, recipient files, or CRYPT_RECIPIENT properties."
    case .gpgFailed(let message):
      "Org crypt encryption failed: \(message)"
    case .gpgTimedOut(let timeout, let message):
      if let message, !message.isEmpty {
        "Org crypt encryption timed out after \(Int(timeout)) seconds: \(message)"
      } else {
        "Org crypt encryption timed out after \(Int(timeout)) seconds."
      }
    }
  }
}

public enum OrgCryptKeychain {
  public static let service = "Org2Workspace.OrgCrypt"
  public static let account = "passphrase"

  public static func containsPassphrase() -> Bool {
    var query: [String: Any] = baseQuery
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()

    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status == errSecSuccess
  }

  public static func readPassphrase(allowUserInteraction: Bool = false) -> String? {
    var query: [String: Any] = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    if !allowUserInteraction {
      query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
    }

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let passphrase = String(data: data, encoding: .utf8),
          !passphrase.isEmpty
    else {
      return nil
    }
    return passphrase
  }

  public static func savePassphrase(_ passphrase: String) throws {
    let data = Data(passphrase.utf8)
    var query = baseQuery
    query[kSecValueData as String] = data
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecDuplicateItem {
      var updateQuery = baseQuery
      updateQuery[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
      let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard updateStatus == errSecSuccess else { throw OrgCryptKeychainError.status(updateStatus) }
      return
    }
    guard status == errSecSuccess else { throw OrgCryptKeychainError.status(status) }
  }

  public static func deletePassphrase() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw OrgCryptKeychainError.status(status)
    }
  }

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }

  private static func noninteractiveAuthenticationContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
  }
}

public enum OrgCryptKeychainError: LocalizedError, Equatable {
  case status(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .status(let status):
      "Org crypt keychain operation failed with status \(status)."
    }
  }
}

private extension String {
  func trimmingTrailingNewline() -> String {
    if hasSuffix("\n") {
      return String(dropLast())
    }
    return self
  }
}
