import AVFoundation
import Foundation

public enum MeetingTranscriptionStatus: String, Sendable {
  case complete
  case unavailable
  case failed

  public var label: String {
    switch self {
    case .complete: "complete"
    case .unavailable: "local transcriber unavailable"
    case .failed: "failed"
    }
  }
}

public struct MeetingArtifactPaths: Sendable {
  public let meetingID: String
  public let title: String
  public let recordedAt: Date
  public let baseName: String
  public let noteURL: URL
  public let audioURL: URL
  public let transcriptURL: URL
}

public struct MeetingTranscriptResult: Sendable {
  public let text: String
  public let status: MeetingTranscriptionStatus
  public let engine: String
  public let errorMessage: String?

  public init(
    text: String,
    status: MeetingTranscriptionStatus,
    engine: String,
    errorMessage: String? = nil
  ) {
    self.text = text
    self.status = status
    self.engine = engine
    self.errorMessage = errorMessage
  }
}

public struct MeetingArtifactBundle: Sendable {
  public let item: MeetingWorkspaceItem
  public let noteURL: URL
  public let audioURL: URL
  public let transcriptURL: URL
}

public enum MeetingArtifactWriter {
  public static func preparePaths(
    corpusRoot: URL,
    title rawTitle: String,
    recordedAt: Date,
    audioExtension: String = "wav"
  ) throws -> MeetingArtifactPaths {
    let fileManager = FileManager.default
    let title = normalizedTitle(rawTitle)
    let baseDirectory = corpusRoot
      .appendingPathComponent("meetings", isDirectory: true)
    try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

    let basePrefix = "\(timestampSlug(recordedAt))-\(slug(title))"
    var baseName = basePrefix
    var suffix = 2
    while fileManager.fileExists(atPath: baseDirectory.appendingPathComponent("\(baseName).org2").path)
      || fileManager.fileExists(atPath: baseDirectory.appendingPathComponent("\(baseName).transcript.org2").path)
      || fileManager.fileExists(atPath: baseDirectory.appendingPathComponent("\(baseName).\(audioExtension)").path) {
      baseName = "\(basePrefix)-\(suffix)"
      suffix += 1
    }

    return MeetingArtifactPaths(
      meetingID: UUID().uuidString.lowercased(),
      title: title,
      recordedAt: recordedAt,
      baseName: baseName,
      noteURL: baseDirectory.appendingPathComponent("\(baseName).org2"),
      audioURL: baseDirectory.appendingPathComponent("\(baseName).\(audioExtension)"),
      transcriptURL: baseDirectory.appendingPathComponent("\(baseName).transcript.org2")
    )
  }

  public static func writeArtifacts(
    paths: MeetingArtifactPaths,
    corpusRoot: URL,
    duration: TimeInterval?,
    transcript: MeetingTranscriptResult
  ) throws -> MeetingArtifactBundle {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: paths.noteURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let transcriptText = buildTranscriptArtifact(
      paths: paths,
      corpusRoot: corpusRoot,
      duration: duration,
      transcript: transcript
    )
    try transcriptText.write(to: paths.transcriptURL, atomically: true, encoding: .utf8)

    let noteText = buildMeetingNote(
      paths: paths,
      corpusRoot: corpusRoot,
      duration: duration,
      transcript: transcript
    )
    try noteText.write(to: paths.noteURL, atomically: true, encoding: .utf8)

    let item = MeetingWorkspaceItem(
      title: paths.title,
      file: paths.noteURL.path,
      line: 1,
      recordedAt: isoTimestamp(paths.recordedAt),
      modifiedAt: Date(),
      audioArtifact: relativePath(from: corpusRoot, to: paths.audioURL),
      transcriptArtifact: relativePath(from: corpusRoot, to: paths.transcriptURL),
      transcriptionStatus: transcript.status.rawValue,
      idValue: paths.meetingID
    )
    return MeetingArtifactBundle(
      item: item,
      noteURL: paths.noteURL,
      audioURL: paths.audioURL,
      transcriptURL: paths.transcriptURL
    )
  }

  public static func buildMeetingNote(
    paths: MeetingArtifactPaths,
    corpusRoot: URL,
    duration: TimeInterval?,
    transcript: MeetingTranscriptResult
  ) -> String {
    let audioPath = relativePath(from: corpusRoot, to: paths.audioURL)
    let transcriptPath = relativePath(from: corpusRoot, to: paths.transcriptURL)
    let durationLine = duration.map { ":duration_seconds: \(String(format: "%.1f", $0))\n" } ?? ""
    let errorLine = transcript.errorMessage.map { ":transcription_error: \(propertyValue($0))\n" } ?? ""
    let preview = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let previewBlock = preview.isEmpty
      ? "- Transcript text is pending. See the transcript artifact for status.\n"
      : transcriptPreview(preview)

    return """
    #+TITLE: Meeting: \(paths.title)
    #+ORG2_KIND: meeting

    * Meeting: \(paths.title)
    :PROPERTIES:
    :ID: \(paths.meetingID)
    :kind: meeting
    :recorded_at: \(isoTimestamp(paths.recordedAt))
    \(durationLine):audio_artifact: \(audioPath)
    :transcript_artifact: \(transcriptPath)
    :transcription_engine: \(transcript.engine)
    :transcription_status: \(transcript.status.rawValue)
    \(errorLine):source: org2-workspace
    :END:

    ** Summary
    - Pending OpenClaw processing.

    ** Decisions
    - [ ] Review transcript and extract decisions.

    ** TODOs
    - [ ] Review this meeting transcript.

    ** Transcript
    [[file:\(transcriptPath)][Open transcript artifact]]

    \(previewBlock)
    """
  }

  public static func buildTranscriptArtifact(
    paths: MeetingArtifactPaths,
    corpusRoot: URL,
    duration: TimeInterval?,
    transcript: MeetingTranscriptResult
  ) -> String {
    let audioPath = relativePath(from: corpusRoot, to: paths.audioURL)
    let durationLine = duration.map { ":duration_seconds: \(String(format: "%.1f", $0))\n" } ?? ""
    let errorLine = transcript.errorMessage.map { ":transcription_error: \(propertyValue($0))\n" } ?? ""
    let body = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let transcriptBody = body.isEmpty
      ? "Local transcription did not produce text. \(transcript.errorMessage ?? "Install whisper.cpp or OpenAI Whisper locally and retranscribe the audio artifact.")"
      : body

    return """
    #+TITLE: Transcript: \(paths.title)
    #+ORG2_KIND: meeting-transcript

    * Transcript: \(paths.title)
    :PROPERTIES:
    :ID: \(UUID().uuidString.lowercased())
    :kind: meeting_transcript
    :meeting_id: \(paths.meetingID)
    :recorded_at: \(isoTimestamp(paths.recordedAt))
    \(durationLine):audio_artifact: \(audioPath)
    :transcription_engine: \(transcript.engine)
    :transcription_status: \(transcript.status.rawValue)
    \(errorLine):source: org2-workspace
    :END:

    \(transcriptBody)
    """
  }

  public static func normalizedTitle(_ raw: String) -> String {
    let title = raw
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Untitled Meeting" : title
  }

  public static func slug(_ raw: String) -> String {
    let lowercased = raw.lowercased()
    let scalars = lowercased.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) {
        return Character(scalar)
      }
      return "-"
    }
    let collapsed = String(scalars)
      .split(separator: "-", omittingEmptySubsequences: true)
      .joined(separator: "-")
    return collapsed.isEmpty ? "meeting" : String(collapsed.prefix(64))
  }

  public static func relativePath(from root: URL, to url: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == rootPath { return "." }
    if path.hasPrefix(rootPath + "/") {
      return String(path.dropFirst(rootPath.count + 1))
    }
    return path
  }

  public static func isoTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func timestampSlug(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: date)
  }

  private static func transcriptPreview(_ text: String) -> String {
    let limit = 4_000
    if text.count <= limit {
      return """
      #+begin_quote
      \(text)
      #+end_quote
      """
    }
    let index = text.index(text.startIndex, offsetBy: limit)
    return """
    #+begin_quote
    \(String(text[..<index]))
    ...[transcript truncated in meeting note; see artifact]
    #+end_quote
    """
  }

  private static func propertyValue(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public struct LocalWhisperConfiguration: Sendable {
  public let environment: [String: String]

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  public var requestedModel: String? {
    environment["ORG2_WORKSPACE_WHISPER_MODEL"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
  }

  public var overrideCommand: String? {
    environment["ORG2_WORKSPACE_WHISPER_COMMAND"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
  }
}

public struct LocalWhisperTranscriber: Sendable {
  public let configuration: LocalWhisperConfiguration

  public init(configuration: LocalWhisperConfiguration = LocalWhisperConfiguration()) {
    self.configuration = configuration
  }

  public func transcribe(audioURL: URL) async throws -> MeetingTranscriptResult {
    let configuration = configuration
    return try await Task.detached(priority: .userInitiated) {
      try Self.transcribeSync(audioURL: audioURL, configuration: configuration)
    }.value
  }

  public static func resolvedBackendDescription(
    configuration: LocalWhisperConfiguration = LocalWhisperConfiguration()
  ) -> String {
    if let command = configuration.overrideCommand {
      return "custom local command: \(command)"
    }
    if resolveExecutable(named: "whisper-cli", environment: configuration.environment) != nil,
       resolveWhisperCppModel(configuration: configuration) != nil {
      return "whisper.cpp"
    }
    if resolveExecutable(named: "whisper-cpp", environment: configuration.environment) != nil,
       resolveWhisperCppModel(configuration: configuration) != nil {
      return "whisper.cpp"
    }
    if resolveExecutable(named: "whisper", environment: configuration.environment) != nil {
      return "OpenAI Whisper CLI"
    }
    return "local Whisper CLI not found"
  }

  private static func transcribeSync(
    audioURL: URL,
    configuration: LocalWhisperConfiguration
  ) throws -> MeetingTranscriptResult {
    if let command = configuration.overrideCommand {
      let result = try runShellTranscriber(command: command, audioURL: audioURL)
      return MeetingTranscriptResult(text: result, status: .complete, engine: "local-whisper:custom")
    }

    if let whisperCpp = resolveExecutable(named: "whisper-cli", environment: configuration.environment)
      ?? resolveExecutable(named: "whisper-cpp", environment: configuration.environment),
      let model = resolveWhisperCppModel(configuration: configuration) {
      let result = try runWhisperCpp(executable: whisperCpp, model: model, audioURL: audioURL)
      return MeetingTranscriptResult(text: result, status: .complete, engine: "whisper.cpp")
    }

    if let whisper = resolveExecutable(named: "whisper", environment: configuration.environment) {
      let result = try runOpenAIWhisper(executable: whisper, audioURL: audioURL, model: configuration.requestedModel)
      return MeetingTranscriptResult(text: result, status: .complete, engine: "openai-whisper")
    }

    throw LocalWhisperError.notConfigured
  }

  private static func runShellTranscriber(command: String, audioURL: URL) throws -> String {
    let quotedAudio = shellQuote(audioURL.path)
    let resolvedCommand = command.contains("{audio}")
      ? command.replacingOccurrences(of: "{audio}", with: quotedAudio)
      : "\(command) \(quotedAudio)"
    let result = try runProcess(
      executableURL: URL(fileURLWithPath: "/bin/zsh"),
      arguments: ["-lc", resolvedCommand],
      currentDirectoryURL: audioURL.deletingLastPathComponent()
    )
    return try transcriptText(stdout: result.stdout, stderr: result.stderr)
  }

  private static func runWhisperCpp(executable: URL, model: String, audioURL: URL) throws -> String {
    let outputPrefix = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-whisper-\(UUID().uuidString)")
    let result = try runProcess(
      executableURL: executable,
      arguments: [
        "-m", model,
        "-f", audioURL.path,
        "-otxt",
        "-of", outputPrefix.path
      ],
      currentDirectoryURL: audioURL.deletingLastPathComponent()
    )
    let transcriptURL = URL(fileURLWithPath: outputPrefix.path + ".txt")
    if let text = try? String(contentsOf: transcriptURL, encoding: .utf8),
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try? FileManager.default.removeItem(at: transcriptURL)
      return text
    }
    return try transcriptText(stdout: result.stdout, stderr: result.stderr)
  }

  private static func runOpenAIWhisper(executable: URL, audioURL: URL, model: String?) throws -> String {
    let outputDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openai-whisper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var arguments = [audioURL.path, "--output_format", "txt", "--output_dir", outputDirectory.path]
    if let model {
      arguments += ["--model", model]
    }
    let result = try runProcess(
      executableURL: executable,
      arguments: arguments,
      currentDirectoryURL: audioURL.deletingLastPathComponent()
    )
    let transcriptURL = outputDirectory.appendingPathComponent(audioURL.deletingPathExtension().lastPathComponent + ".txt")
    if let text = try? String(contentsOf: transcriptURL, encoding: .utf8),
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try? FileManager.default.removeItem(at: outputDirectory)
      return text
    }
    return try transcriptText(stdout: result.stdout, stderr: result.stderr)
  }

  private static func resolveWhisperCppModel(configuration: LocalWhisperConfiguration) -> String? {
    if let requested = configuration.requestedModel {
      return requested
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "\(home)/Library/Application Support/org2/whisper/ggml-base.en.bin",
      "\(home)/.cache/whisper/ggml-base.en.bin",
      "\(home)/.cache/whisper.cpp/ggml-base.en.bin",
      "\(home)/dev/whisper.cpp/models/ggml-base.en.bin",
      "\(home)/openclaw/models/ggml-base.en.bin",
      "/opt/homebrew/share/whisper-cpp/models/ggml-base.en.bin",
      "/usr/local/share/whisper-cpp/models/ggml-base.en.bin"
    ]

    return candidates.first { FileManager.default.fileExists(atPath: $0) }
  }

  private static func resolveExecutable(named name: String, environment: [String: String]) -> URL? {
    if name.hasPrefix("/") {
      return FileManager.default.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil
    }
    let path = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for directory in path.split(separator: ":").map(String.init) {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private static func transcriptText(stdout: String, stderr: String) throws -> String {
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    throw LocalWhisperError.emptyTranscript(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func runProcess(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL
  ) throws -> ProcessTextResult {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL

    var environment = ProcessInfo.processInfo.environment
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if let existing = environment["PATH"], !existing.isEmpty {
      environment["PATH"] = "\(defaultPath):\(existing)"
    } else {
      environment["PATH"] = defaultPath
    }
    process.environment = environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let stdoutCollector = TextPipeCollector()
    let stderrCollector = TextPipeCollector()
    let readGroup = DispatchGroup()

    try process.run()

    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      stdoutCollector.set(stdout.fileHandleForReading.readDataToEndOfFile())
      readGroup.leave()
    }
    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      stderrCollector.set(stderr.fileHandleForReading.readDataToEndOfFile())
      readGroup.leave()
    }

    process.waitUntilExit()
    readGroup.wait()

    let output = ProcessTextResult(
      stdout: String(data: stdoutCollector.data, encoding: .utf8) ?? "",
      stderr: String(data: stderrCollector.data, encoding: .utf8) ?? ""
    )

    guard process.terminationStatus == 0 else {
      throw LocalWhisperError.commandFailed(
        executableURL.lastPathComponent,
        Int(process.terminationStatus),
        output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }

    return output
  }

  private static func shellQuote(_ raw: String) -> String {
    "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

@MainActor
public final class MeetingAudioRecorder {
  private var recorder: AVAudioRecorder?
  private var startedAt: Date?

  public init() {}

  public func startRecording(to audioURL: URL) async throws {
    guard recorder == nil else { throw MeetingRecorderError.alreadyRecording }
    try await requestMicrophonePermission()
    try FileManager.default.createDirectory(
      at: audioURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false
    ]
    let recorder = try AVAudioRecorder(url: audioURL, settings: settings)
    recorder.isMeteringEnabled = true
    recorder.prepareToRecord()
    guard recorder.record() else {
      throw MeetingRecorderError.startFailed
    }
    self.recorder = recorder
    self.startedAt = Date()
  }

  public func stopRecording() throws -> TimeInterval {
    guard let recorder else { throw MeetingRecorderError.notRecording }
    let duration = recorder.currentTime
    recorder.stop()
    self.recorder = nil
    self.startedAt = nil
    return duration
  }

  private func requestMicrophonePermission() async throws {
    switch Self.microphoneAuthorizationStatus() {
    case .authorized:
      return
    case .notDetermined:
      let granted = await Self.requestMicrophoneAccess()
      if granted { return }
      throw MeetingRecorderError.microphoneDenied
    case .denied, .restricted:
      throw MeetingRecorderError.microphoneDenied
    @unknown default:
      throw MeetingRecorderError.microphoneDenied
    }
  }

  nonisolated private static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  nonisolated private static func requestMicrophoneAccess() async -> Bool {
    await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
  }
}

public enum LocalWhisperError: LocalizedError, Equatable {
  case notConfigured
  case commandFailed(String, Int, String)
  case emptyTranscript(String)

  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      "No local Whisper transcriber found. Install whisper.cpp (`whisper-cli`) with a local ggml model, install the OpenAI Whisper CLI (`whisper`), or set ORG2_WORKSPACE_WHISPER_COMMAND."
    case .commandFailed(let command, let status, let stderr):
      "\(command) exited with status \(status)\(stderr.isEmpty ? "" : ": \(stderr)")"
    case .emptyTranscript(let stderr):
      stderr.isEmpty ? "Local Whisper did not return a transcript." : "Local Whisper did not return a transcript: \(stderr)"
    }
  }
}

public enum MeetingRecorderError: LocalizedError, Equatable {
  case alreadyRecording
  case notRecording
  case microphoneDenied
  case startFailed

  public var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      "A meeting recording is already active."
    case .notRecording:
      "No meeting recording is active."
    case .microphoneDenied:
      "Microphone access is required to record meetings."
    case .startFailed:
      "Could not start the meeting recorder."
    }
  }
}

private struct ProcessTextResult {
  let stdout: String
  let stderr: String
}

private final class TextPipeCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  func set(_ data: Data) {
    lock.lock()
    storage = data
    lock.unlock()
  }

  var data: Data {
    lock.lock()
    let data = storage
    lock.unlock()
    return data
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
