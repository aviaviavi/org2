@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
@preconcurrency import Speech

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
  public let systemAudioURL: URL
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

  public static func combined(
    microphone: MeetingTranscriptResult,
    systemAudio: MeetingTranscriptResult?,
    systemAudioCaptureError: String? = nil
  ) -> MeetingTranscriptResult {
    guard systemAudio != nil || systemAudioCaptureError != nil else {
      return microphone
    }

    var sections = [
      transcriptSection(title: "Microphone", transcript: microphone)
    ]
    if let systemAudio {
      sections.append(transcriptSection(title: "System Audio", transcript: systemAudio))
    } else if let systemAudioCaptureError {
      sections.append("""
      ** System Audio

      System audio was not captured: \(systemAudioCaptureError)
      """)
    }

    let status: MeetingTranscriptionStatus
    if microphone.status == .complete || systemAudio?.status == .complete {
      status = .complete
    } else if microphone.status == .unavailable && (systemAudio?.status == .unavailable || systemAudio == nil) {
      status = .unavailable
    } else {
      status = .failed
    }

    let engine = [
      "microphone: \(microphone.engine)",
      systemAudio.map { "system: \($0.engine)" }
    ].compactMap { $0 }.joined(separator: "; ")
    let errorMessage = [
      microphone.errorMessage.map { "microphone: \($0)" },
      systemAudio?.errorMessage.map { "system: \($0)" },
      systemAudioCaptureError.map { "system capture: \($0)" }
    ].compactMap { $0 }.joined(separator: "; ").nilIfEmpty

    return MeetingTranscriptResult(
      text: sections.joined(separator: "\n\n"),
      status: status,
      engine: engine,
      errorMessage: errorMessage
    )
  }

  private static func transcriptSection(title: String, transcript: MeetingTranscriptResult) -> String {
    let body = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = body.isEmpty
      ? "Transcription \(transcript.status.label). \(transcript.errorMessage ?? "")"
        .trimmingCharacters(in: .whitespacesAndNewlines)
      : body
    return """
    ** \(title)

    \(text)
    """
  }
}

public struct MeetingArtifactBundle: Sendable {
  public let item: MeetingWorkspaceItem
  public let noteURL: URL
  public let audioURL: URL
  public let systemAudioURL: URL?
  public let transcriptURL: URL
}

public struct MeetingInputMeterSnapshot: Equatable, Sendable {
  public let averageLevel: Double
  public let peakLevel: Double
  public let averagePowerDecibels: Float
  public let peakPowerDecibels: Float

  public static let silent = MeetingInputMeterSnapshot(
    averageLevel: 0,
    peakLevel: 0,
    averagePowerDecibels: -160,
    peakPowerDecibels: -160
  )
}

public enum MeetingArtifactWriter {
  public static func preparePaths(
    corpusRoot: URL,
    title rawTitle: String,
    recordedAt: Date,
    audioExtension: String = "wav",
    systemAudioExtension: String = "m4a"
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
      || fileManager.fileExists(atPath: baseDirectory.appendingPathComponent("\(baseName).\(audioExtension)").path)
      || fileManager.fileExists(atPath: baseDirectory.appendingPathComponent("\(baseName).system.\(systemAudioExtension)").path) {
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
      systemAudioURL: baseDirectory.appendingPathComponent("\(baseName).system.\(systemAudioExtension)"),
      transcriptURL: baseDirectory.appendingPathComponent("\(baseName).transcript.org2")
    )
  }

  public static func writeArtifacts(
    paths: MeetingArtifactPaths,
    corpusRoot: URL,
    duration: TimeInterval?,
    transcript: MeetingTranscriptResult,
    systemAudioURL: URL? = nil,
    captureSources: String? = nil
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
      transcript: transcript,
      systemAudioURL: systemAudioURL,
      captureSources: captureSources ?? defaultCaptureSources(systemAudioURL: systemAudioURL)
    )
    try transcriptText.write(to: paths.transcriptURL, atomically: true, encoding: .utf8)

    let noteText = buildMeetingNote(
      paths: paths,
      corpusRoot: corpusRoot,
      duration: duration,
      transcript: transcript,
      systemAudioURL: systemAudioURL,
      captureSources: captureSources ?? defaultCaptureSources(systemAudioURL: systemAudioURL)
    )
    try noteText.write(to: paths.noteURL, atomically: true, encoding: .utf8)

    let item = MeetingWorkspaceItem(
      title: paths.title,
      file: paths.noteURL.path,
      line: 1,
      recordedAt: isoTimestamp(paths.recordedAt),
      modifiedAt: Date(),
      audioArtifact: relativePath(from: corpusRoot, to: paths.audioURL),
      systemAudioArtifact: systemAudioURL.map { relativePath(from: corpusRoot, to: $0) },
      transcriptArtifact: relativePath(from: corpusRoot, to: paths.transcriptURL),
      transcriptionStatus: transcript.status.rawValue,
      idValue: paths.meetingID
    )
    return MeetingArtifactBundle(
      item: item,
      noteURL: paths.noteURL,
      audioURL: paths.audioURL,
      systemAudioURL: systemAudioURL,
      transcriptURL: paths.transcriptURL
    )
  }

  public static func buildMeetingNote(
    paths: MeetingArtifactPaths,
    corpusRoot: URL,
    duration: TimeInterval?,
    transcript: MeetingTranscriptResult,
    systemAudioURL: URL? = nil,
    captureSources: String? = nil
  ) -> String {
    let audioPath = relativePath(from: corpusRoot, to: paths.audioURL)
    let systemAudioLine = systemAudioURL.map {
      ":system_audio_artifact: \(relativePath(from: corpusRoot, to: $0))\n"
    } ?? ""
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
    \(systemAudioLine):capture_sources: \(captureSources ?? defaultCaptureSources(systemAudioURL: systemAudioURL))
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
    transcript: MeetingTranscriptResult,
    systemAudioURL: URL? = nil,
    captureSources: String? = nil
  ) -> String {
    let audioPath = relativePath(from: corpusRoot, to: paths.audioURL)
    let systemAudioLine = systemAudioURL.map {
      ":system_audio_artifact: \(relativePath(from: corpusRoot, to: $0))\n"
    } ?? ""
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
    \(systemAudioLine):capture_sources: \(captureSources ?? defaultCaptureSources(systemAudioURL: systemAudioURL))
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

  public static func audioDuration(at url: URL) -> TimeInterval? {
    guard let audioFile = try? AVAudioFile(forReading: url),
          audioFile.processingFormat.sampleRate > 0
    else {
      return nil
    }
    let seconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
    guard seconds.isFinite, seconds > 0 else { return nil }
    return seconds
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

  private static func defaultCaptureSources(systemAudioURL: URL?) -> String {
    systemAudioURL == nil ? "microphone" : "microphone, system_audio"
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
  public let bundleResourceURL: URL?

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundleResourceURL: URL? = Bundle.main.resourceURL
  ) {
    self.environment = environment
    self.bundleResourceURL = bundleResourceURL
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

  public var requestedLanguage: String {
    environment["ORG2_WORKSPACE_WHISPER_LANGUAGE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty ?? "en"
  }

  public var requestedThreadCount: Int {
    if let raw = environment["ORG2_WORKSPACE_WHISPER_THREADS"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      let parsed = Int(raw),
      parsed > 0 {
      return parsed
    }
    return max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
  }
}

public struct LocalWhisperInstallationStatus: Equatable, Sendable {
  public let backendDescription: String
  public let whisperCppExecutablePath: String?
  public let whisperCppModelPath: String?
  public let openAIWhisperExecutablePath: String?
  public let overrideCommand: String?

  public var isWhisperCppReady: Bool {
    whisperCppExecutablePath != nil && whisperCppModelPath != nil
  }

  public var isAnyLocalTranscriberAvailable: Bool {
    true
  }

  public var statusLabel: String {
    if isWhisperCppReady { return "Fast local transcription ready" }
    if overrideCommand != nil { return "Custom transcriber configured" }
    if openAIWhisperExecutablePath != nil { return "Python Whisper available; whisper.cpp recommended" }
    if whisperCppExecutablePath != nil { return "whisper.cpp installed; model missing" }
    return "Built-in macOS transcription ready"
  }

  public var detailText: String {
    if isWhisperCppReady {
      return "Using whisper.cpp with \(whisperCppModelPath ?? "a GGML model")."
    }
    if whisperCppExecutablePath != nil {
      return "Install a GGML model to enable the fast whisper.cpp path."
    }
    if openAIWhisperExecutablePath != nil {
      return "Using Python Whisper. Install whisper.cpp for faster local transcription."
    }
    if let overrideCommand {
      return "Using custom command: \(overrideCommand)"
    }
    return "Uses macOS Speech out of the box. whisper.cpp remains an optional faster local backend."
  }
}

public enum NativeSpeechTranscriberError: LocalizedError {
  case authorizationDenied
  case recognizerUnavailable
  case emptyTranscript

  public var errorDescription: String? {
    switch self {
    case .authorizationDenied:
      "Speech recognition permission is required for dictation. Allow Org2 Workspace under System Settings → Privacy & Security → Speech Recognition."
    case .recognizerUnavailable:
      "macOS Speech recognition is temporarily unavailable."
    case .emptyTranscript:
      "macOS Speech recognition completed without producing text."
    }
  }
}

private final class NativeSpeechRecognitionCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?

  init(_ continuation: CheckedContinuation<String, Error>) {
    self.continuation = continuation
  }

  func finish(_ result: Result<String, Error>) {
    let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
      defer { continuation = nil }
      return continuation
    }
    pending?.resume(with: result)
  }
}

public struct NativeSpeechTranscriber: Sendable {
  public init() {}

  public func transcribe(audioURL: URL) async throws -> MeetingTranscriptResult {
    let authorization = await authorizationStatus()
    guard authorization == .authorized else {
      throw NativeSpeechTranscriberError.authorizationDenied
    }
    guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
      throw NativeSpeechTranscriberError.recognizerUnavailable
    }

    let request = SFSpeechURLRecognitionRequest(url: audioURL)
    request.shouldReportPartialResults = false
    request.addsPunctuation = true
    let text = try await withCheckedThrowingContinuation { continuation in
      let completion = NativeSpeechRecognitionCompletion(continuation)
      recognizer.recognitionTask(with: request) { result, error in
        if let error {
          completion.finish(.failure(error))
          return
        }
        guard let result, result.isFinal else { return }
        let transcript = result.bestTranscription.formattedString
          .trimmingCharacters(in: .whitespacesAndNewlines)
        completion.finish(transcript.isEmpty
          ? .failure(NativeSpeechTranscriberError.emptyTranscript)
          : .success(transcript))
      }
    }
    return MeetingTranscriptResult(text: text, status: .complete, engine: "macOS Speech")
  }

  private func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
    let current = SFSpeechRecognizer.authorizationStatus()
    guard current == .notDetermined else { return current }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }
}

public struct LocalWhisperTranscriber: Sendable {
  public let configuration: LocalWhisperConfiguration
  public static let defaultWhisperCppModelDownloadURL = URL(
    string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
  )!

  public static var defaultWhisperCppModelURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/org2/whisper", isDirectory: true)
      .appendingPathComponent("ggml-base.en.bin")
  }

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
    if resolveWhisperCppExecutable(configuration: configuration) != nil,
       resolveWhisperCppModel(configuration: configuration) != nil {
      return "whisper.cpp"
    }
    if resolveExecutable(named: "whisper", environment: configuration.environment) != nil {
      return "OpenAI Whisper CLI"
    }
    return "macOS Speech"
  }

  public static func installationStatus(
    configuration: LocalWhisperConfiguration = LocalWhisperConfiguration()
  ) -> LocalWhisperInstallationStatus {
    let whisperCpp = resolveWhisperCppExecutable(configuration: configuration)
    let model = resolveWhisperCppModel(configuration: configuration)
    let openAIWhisper = resolveExecutable(named: "whisper", environment: configuration.environment)
    return LocalWhisperInstallationStatus(
      backendDescription: resolvedBackendDescription(configuration: configuration),
      whisperCppExecutablePath: whisperCpp?.path,
      whisperCppModelPath: model,
      openAIWhisperExecutablePath: openAIWhisper?.path,
      overrideCommand: configuration.overrideCommand
    )
  }

  private static func transcribeSync(
    audioURL: URL,
    configuration: LocalWhisperConfiguration
  ) throws -> MeetingTranscriptResult {
    if let command = configuration.overrideCommand {
      let result = try runShellTranscriber(command: command, audioURL: audioURL)
      return MeetingTranscriptResult(text: result, status: .complete, engine: "local-whisper:custom")
    }

    if let whisperCpp = resolveWhisperCppExecutable(configuration: configuration),
      let model = resolveWhisperCppModel(configuration: configuration) {
      let result = try runWhisperCpp(
        executable: whisperCpp,
        model: model,
        audioURL: audioURL,
        language: configuration.requestedLanguage,
        threadCount: configuration.requestedThreadCount
      )
      return MeetingTranscriptResult(text: result, status: .complete, engine: "whisper.cpp")
    }

    if let whisper = resolveExecutable(named: "whisper", environment: configuration.environment) {
      let result = try runOpenAIWhisper(
        executable: whisper,
        audioURL: audioURL,
        model: configuration.requestedModel,
        language: configuration.requestedLanguage
      )
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

  private static func runWhisperCpp(
    executable: URL,
    model: String,
    audioURL: URL,
    language: String,
    threadCount: Int
  ) throws -> String {
    let whisperAudioURL = try whisperCppCompatibleAudioURL(for: audioURL)
    defer {
      if whisperAudioURL.standardizedFileURL.path != audioURL.standardizedFileURL.path {
        try? FileManager.default.removeItem(at: whisperAudioURL)
      }
    }
    let outputPrefix = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-whisper-\(UUID().uuidString)")
    let result = try runProcess(
      executableURL: executable,
      arguments: [
        "-m", model,
        "-f", whisperAudioURL.path,
        "-l", language,
        "-t", "\(threadCount)",
        "-nt",
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

  private static func whisperCppCompatibleAudioURL(for audioURL: URL) throws -> URL {
    guard audioURL.pathExtension.lowercased() != "wav" else { return audioURL }
    let convertedURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-whisper-input-\(UUID().uuidString).wav")
    do {
      try convertAudioToWhisperWAV(sourceURL: audioURL, outputURL: convertedURL)
      return convertedURL
    } catch {
      try? FileManager.default.removeItem(at: convertedURL)
      throw LocalWhisperError.audioConversionFailed(audioURL.lastPathComponent, error.localizedDescription)
    }
  }

  private static func convertAudioToWhisperWAV(sourceURL: URL, outputURL: URL) throws {
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    let converterURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    guard FileManager.default.isExecutableFile(atPath: converterURL.path) else {
      throw LocalWhisperError.audioConversionFailed(sourceURL.lastPathComponent, "afconvert is not available.")
    }
    let result = try runProcess(
      executableURL: converterURL,
      arguments: [
        "-f", "WAVE",
        "-d", "LEI16@16000",
        "-c", "1",
        sourceURL.path,
        outputURL.path
      ],
      currentDirectoryURL: sourceURL.deletingLastPathComponent()
    )
    guard FileManager.default.fileExists(atPath: outputURL.path) else {
      throw LocalWhisperError.audioConversionFailed(
        sourceURL.lastPathComponent,
        result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }

  private static func runOpenAIWhisper(
    executable: URL,
    audioURL: URL,
    model: String?,
    language: String
  ) throws -> String {
    let outputDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openai-whisper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var arguments = [
      audioURL.path,
      "--language", language,
      "--task", "transcribe",
      "--output_format", "txt",
      "--output_dir", outputDirectory.path
    ]
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
      return FileManager.default.fileExists(atPath: requested) ? requested : nil
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var candidates: [String] = []
    if let bundledModel = configuration.bundleResourceURL?
      .appendingPathComponent("Whisper/models/ggml-base.en.bin")
      .path {
      candidates.append(bundledModel)
    }
    candidates += [
      "\(home)/Library/Application Support/org2/whisper/ggml-tiny.en.bin",
      "\(home)/Library/Application Support/org2/whisper/ggml-base.en.bin",
      "\(home)/.cache/whisper/ggml-tiny.en.bin",
      "\(home)/.cache/whisper/ggml-base.en.bin",
      "\(home)/.cache/whisper.cpp/ggml-tiny.en.bin",
      "\(home)/.cache/whisper.cpp/ggml-base.en.bin",
      "\(home)/dev/whisper.cpp/models/ggml-tiny.en.bin",
      "\(home)/dev/whisper.cpp/models/ggml-base.en.bin",
      "\(home)/openclaw/models/ggml-tiny.en.bin",
      "\(home)/openclaw/models/ggml-base.en.bin",
      "/opt/homebrew/share/whisper-cpp/models/ggml-tiny.en.bin",
      "/opt/homebrew/share/whisper-cpp/models/ggml-base.en.bin",
      "/usr/local/share/whisper-cpp/models/ggml-tiny.en.bin",
      "/usr/local/share/whisper-cpp/models/ggml-base.en.bin"
    ]

    return candidates.first { FileManager.default.fileExists(atPath: $0) }
  }

  private static func resolveWhisperCppExecutable(configuration: LocalWhisperConfiguration) -> URL? {
    if let bundledExecutable = configuration.bundleResourceURL?
      .appendingPathComponent("Whisper/bin/whisper-cli"),
      FileManager.default.isExecutableFile(atPath: bundledExecutable.path) {
      return bundledExecutable
    }
    return resolveExecutable(named: "whisper-cli", environment: configuration.environment)
      ?? resolveExecutable(named: "whisper-cpp", environment: configuration.environment)
  }

  private static func resolveExecutable(named name: String, environment: [String: String]) -> URL? {
    if name.hasPrefix("/") {
      return FileManager.default.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil
    }
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    let path = environment["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      .map { "\($0):\(defaultPath)" } ?? defaultPath
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

public final class MeetingSystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private let sampleQueue = DispatchQueue(label: "org2.workspace.meeting.system-audio.samples")
  private let stateLock = NSLock()
  private var stream: SCStream?
  private var writer: AVAssetWriter?
  private var writerInput: AVAssetWriterInput?
  private var firstPresentationTime: CMTime?
  private var lastPresentationTime: CMTime?
  private var lastMeterSnapshotTime: CMTime?
  private var sampleCount = 0
  private var latestSnapshot = MeetingInputMeterSnapshot.silent
  private var isCaptureRunning = false

  private static let meterSnapshotIntervalSeconds = 0.25

  public override init() {}

  public var inputMeterSnapshot: MeetingInputMeterSnapshot {
    stateLock.withLock { latestSnapshot }
  }

  public func startRecording(to audioURL: URL) async throws {
    let alreadyRecording = stateLock.withLock { self.stream != nil }
    guard !alreadyRecording else { throw MeetingSystemAudioRecorderError.alreadyRecording }

    try FileManager.default.createDirectory(
      at: audioURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: audioURL.path) {
      try FileManager.default.removeItem(at: audioURL)
    }

    let writer = try AVAssetWriter(outputURL: audioURL, fileType: .m4a)
    let writerInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000
      ]
    )
    writerInput.expectsMediaDataInRealTime = true
    guard writer.canAdd(writerInput) else {
      throw MeetingSystemAudioRecorderError.writerSetupFailed("Cannot add audio writer input.")
    }
    writer.add(writerInput)

    let content = try await SCShareableContent.current
    guard let display = content.displays.first else {
      throw MeetingSystemAudioRecorderError.noDisplayAvailable
    }

    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 3
    configuration.showsCursor = false
    configuration.capturesAudio = true
    configuration.sampleRate = 48_000
    configuration.channelCount = 2
    configuration.excludesCurrentProcessAudio = true

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

    stateLock.withLock {
      self.stream = stream
      self.writer = writer
      self.writerInput = writerInput
      firstPresentationTime = nil
      lastPresentationTime = nil
      lastMeterSnapshotTime = nil
      sampleCount = 0
      latestSnapshot = .silent
      isCaptureRunning = false
    }

    do {
      try await startCapture(stream)
      stateLock.withLock {
        isCaptureRunning = true
      }
    } catch {
      resetState(cancelWriter: true)
      throw error
    }
  }

  public func stopRecording() async throws -> TimeInterval? {
    let state = stateLock.withLock {
      (stream: stream, writer: writer, writerInput: writerInput, isCaptureRunning: isCaptureRunning)
    }

    guard let stream = state.stream,
          let writer = state.writer,
          let writerInput = state.writerInput
    else {
      throw MeetingSystemAudioRecorderError.notRecording
    }

    if state.isCaptureRunning {
      try await stopCapture(stream)
      stateLock.withLock {
        isCaptureRunning = false
      }
    }
    return try await finishWriting(writer: writer, writerInput: writerInput)
  }

  public func pauseRecording() async throws {
    let state = stateLock.withLock {
      (stream: stream, isCaptureRunning: isCaptureRunning)
    }
    guard let stream = state.stream else { throw MeetingSystemAudioRecorderError.notRecording }
    guard state.isCaptureRunning else { return }
    try await stopCapture(stream)
    stateLock.withLock {
      isCaptureRunning = false
      latestSnapshot = .silent
    }
  }

  public func resumeRecording() async throws {
    let state = stateLock.withLock {
      (stream: stream, isCaptureRunning: isCaptureRunning)
    }
    guard let stream = state.stream else { throw MeetingSystemAudioRecorderError.notRecording }
    guard !state.isCaptureRunning else { return }
    try await startCapture(stream)
    stateLock.withLock {
      isCaptureRunning = true
    }
  }

  public nonisolated func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio,
          sampleBuffer.isValid,
          CMSampleBufferDataIsReady(sampleBuffer)
    else {
      return
    }

    stateLock.withLock {
      guard let writer, let writerInput else {
        return
      }

      if writer.status == .unknown {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard writer.startWriting() else {
          return
        }
        writer.startSession(atSourceTime: presentationTime)
        firstPresentationTime = presentationTime
      }

      if writer.status == .writing, writerInput.isReadyForMoreMediaData {
        if writerInput.append(sampleBuffer) {
          let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          sampleCount += 1
          lastPresentationTime = presentationTime
          if shouldUpdateMeterSnapshot(at: presentationTime),
             let snapshot = Self.meterSnapshot(from: sampleBuffer) {
            lastMeterSnapshotTime = presentationTime
            latestSnapshot = snapshot
          }
        }
      }
    }
  }

  private func shouldUpdateMeterSnapshot(at presentationTime: CMTime) -> Bool {
    guard presentationTime.isValid, presentationTime.isNumeric else {
      return true
    }
    guard let lastMeterSnapshotTime,
          lastMeterSnapshotTime.isValid,
          lastMeterSnapshotTime.isNumeric
    else {
      return true
    }
    return CMTimeGetSeconds(presentationTime - lastMeterSnapshotTime) >= Self.meterSnapshotIntervalSeconds
  }

  public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    stateLock.withLock {
      latestSnapshot = .silent
    }
  }

  private func startCapture(_ stream: SCStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stream.startCapture { error in
        if let error {
          continuation.resume(throwing: MeetingSystemAudioRecorderError.startFailed(error.localizedDescription))
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func stopCapture(_ stream: SCStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stream.stopCapture { error in
        if let error {
          continuation.resume(throwing: MeetingSystemAudioRecorderError.stopFailed(error.localizedDescription))
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func finishWriting(
    writer: AVAssetWriter,
    writerInput: AVAssetWriterInput
  ) async throws -> TimeInterval? {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TimeInterval?, Error>) in
      sampleQueue.async {
        let state = self.stateLock.withLock {
          let state = (
            firstPresentationTime: self.firstPresentationTime,
            lastPresentationTime: self.lastPresentationTime,
            sampleCount: self.sampleCount
          )
          self.stream = nil
          self.writer = nil
          self.writerInput = nil
          self.firstPresentationTime = nil
          self.lastPresentationTime = nil
          self.lastMeterSnapshotTime = nil
          self.sampleCount = 0
          self.latestSnapshot = .silent
          self.isCaptureRunning = false
          return state
        }

        guard state.sampleCount > 0, writer.status != .unknown else {
          writer.cancelWriting()
          continuation.resume(returning: nil)
          return
        }

        writerInput.markAsFinished()
        writer.finishWriting {
          if let error = writer.error {
            continuation.resume(throwing: MeetingSystemAudioRecorderError.writerSetupFailed(error.localizedDescription))
            return
          }
          if let firstPresentationTime = state.firstPresentationTime,
             let lastPresentationTime = state.lastPresentationTime {
            continuation.resume(returning: max(0, CMTimeGetSeconds(lastPresentationTime - firstPresentationTime)))
          } else {
            continuation.resume(returning: nil)
          }
        }
      }
    }
  }

  private func resetState(cancelWriter: Bool) {
    let writer = stateLock.withLock {
      let writer = self.writer
      stream = nil
      self.writer = nil
      writerInput = nil
      firstPresentationTime = nil
      lastPresentationTime = nil
      lastMeterSnapshotTime = nil
      sampleCount = 0
      latestSnapshot = .silent
      isCaptureRunning = false
      return writer
    }

    if cancelWriter {
      writer?.cancelWriting()
    }
  }

  private static func meterSnapshot(from sampleBuffer: CMSampleBuffer) -> MeetingInputMeterSnapshot? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
    else {
      return nil
    }

    var audioBufferListSize = 0
    var blockBuffer: CMBlockBuffer?
    var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &audioBufferListSize,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == noErr || audioBufferListSize > 0 else { return nil }

    let rawAudioBufferList = UnsafeMutableRawPointer.allocate(
      byteCount: audioBufferListSize,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawAudioBufferList.deallocate() }

    let audioBufferList = rawAudioBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &audioBufferListSize,
      bufferListOut: audioBufferList,
      bufferListSize: audioBufferListSize,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == noErr else { return nil }

    return meterSnapshot(from: UnsafeMutableAudioBufferListPointer(audioBufferList), format: streamDescription.pointee)
  }

  private static func meterSnapshot(
    from audioBuffers: UnsafeMutableAudioBufferListPointer,
    format: AudioStreamBasicDescription
  ) -> MeetingInputMeterSnapshot? {
    let bytesPerSample = max(1, Int(format.mBitsPerChannel / 8))
    let formatFlags = format.mFormatFlags
    let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (formatFlags & kAudioFormatFlagIsSignedInteger) != 0

    var sumSquares = 0.0
    var peak = 0.0
    var sampleCount = 0

    for audioBuffer in audioBuffers {
      guard let data = audioBuffer.mData else { continue }
      let byteCount = Int(audioBuffer.mDataByteSize)
      if isFloat && bytesPerSample == MemoryLayout<Float>.size {
        let values = data.bindMemory(to: Float.self, capacity: byteCount / MemoryLayout<Float>.size)
        for index in 0..<(byteCount / MemoryLayout<Float>.size) {
          let value = min(1, max(-1, Double(values[index])))
          let magnitude = abs(value)
          sumSquares += value * value
          peak = max(peak, magnitude)
          sampleCount += 1
        }
      } else if isSignedInteger && bytesPerSample == MemoryLayout<Int16>.size {
        let values = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.size)
        for index in 0..<(byteCount / MemoryLayout<Int16>.size) {
          let value = Double(values[index]) / Double(Int16.max)
          let magnitude = abs(value)
          sumSquares += value * value
          peak = max(peak, magnitude)
          sampleCount += 1
        }
      } else if isSignedInteger && bytesPerSample == MemoryLayout<Int32>.size {
        let values = data.bindMemory(to: Int32.self, capacity: byteCount / MemoryLayout<Int32>.size)
        for index in 0..<(byteCount / MemoryLayout<Int32>.size) {
          let value = Double(values[index]) / Double(Int32.max)
          let magnitude = abs(value)
          sumSquares += value * value
          peak = max(peak, magnitude)
          sampleCount += 1
        }
      }
    }

    guard sampleCount > 0 else { return nil }
    let rms = sqrt(sumSquares / Double(sampleCount))
    let averageDecibels = Float(20 * log10(max(rms, 0.000_001)))
    let peakDecibels = Float(20 * log10(max(peak, 0.000_001)))
    return MeetingInputMeterSnapshot(
      averageLevel: MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: averageDecibels),
      peakLevel: MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: peakDecibels),
      averagePowerDecibels: averageDecibels,
      peakPowerDecibels: peakDecibels
    )
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

  public var inputMeterSnapshot: MeetingInputMeterSnapshot {
    guard let recorder else { return .silent }
    recorder.updateMeters()
    let averagePower = recorder.averagePower(forChannel: 0)
    let peakPower = recorder.peakPower(forChannel: 0)
    return MeetingInputMeterSnapshot(
      averageLevel: Self.normalizedMeterLevel(fromDecibels: averagePower),
      peakLevel: Self.normalizedMeterLevel(fromDecibels: peakPower),
      averagePowerDecibels: averagePower,
      peakPowerDecibels: peakPower
    )
  }

  nonisolated public static func normalizedMeterLevel(fromDecibels decibels: Float) -> Double {
    guard decibels.isFinite else { return 0 }
    let floor: Double = -60
    let ceiling: Double = 0
    let clamped = min(ceiling, max(floor, Double(decibels)))
    return (clamped - floor) / (ceiling - floor)
  }

  public func stopRecording() throws -> TimeInterval {
    guard let recorder else { throw MeetingRecorderError.notRecording }
    let duration = recorder.currentTime
    recorder.stop()
    self.recorder = nil
    self.startedAt = nil
    return duration
  }

  public func pauseRecording() throws {
    guard let recorder else { throw MeetingRecorderError.notRecording }
    recorder.pause()
  }

  public func resumeRecording() throws {
    guard let recorder else { throw MeetingRecorderError.notRecording }
    guard recorder.record() else {
      throw MeetingRecorderError.startFailed
    }
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
  case audioConversionFailed(String, String)

  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      "No local Whisper transcriber found. Install whisper.cpp (`whisper-cli`) with a local ggml model, install the OpenAI Whisper CLI (`whisper`), or set ORG2_WORKSPACE_WHISPER_COMMAND."
    case .commandFailed(let command, let status, let stderr):
      "\(command) exited with status \(status)\(stderr.isEmpty ? "" : ": \(stderr)")"
    case .emptyTranscript(let stderr):
      stderr.isEmpty ? "Local Whisper did not return a transcript." : "Local Whisper did not return a transcript: \(stderr)"
    case .audioConversionFailed(let file, let message):
      "Could not convert \(file) to WAV for whisper.cpp\(message.isEmpty ? "" : ": \(message)")"
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

public enum MeetingSystemAudioRecorderError: LocalizedError, Equatable {
  case alreadyRecording
  case notRecording
  case noDisplayAvailable
  case writerSetupFailed(String)
  case startFailed(String)
  case stopFailed(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      "System audio recording is already active."
    case .notRecording:
      "No system audio recording is active."
    case .noDisplayAvailable:
      "No display is available for system audio capture."
    case .writerSetupFailed(let message):
      "Could not prepare the system audio recorder: \(message)"
    case .startFailed(let message):
      "Could not start system audio capture: \(message)"
    case .stopFailed(let message):
      "Could not stop system audio capture: \(message)"
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
