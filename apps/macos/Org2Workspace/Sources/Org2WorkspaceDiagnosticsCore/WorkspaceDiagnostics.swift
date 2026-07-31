import AppKit
import Darwin
import Foundation

public enum WorkspaceDiagnosticsHeartbeat {
  public static let ping = Notification.Name("org.org2.workspace.diagnostics.ping.v1")
  public static let acknowledgement = Notification.Name("org.org2.workspace.diagnostics.ack.v1")
  public static let targetPIDKey = "targetPID"
  public static let nonceKey = "nonce"
  public static let responderPIDKey = "responderPID"
}

/// Responds only when the external diagnostics helper is running. There is no
/// app-side timer or resource polling cost while diagnostics are idle.
public final class WorkspaceDiagnosticsHeartbeatResponder: NSObject, @unchecked Sendable {
  private let center: DistributedNotificationCenter
  private var isStarted = false

  public init(center: DistributedNotificationCenter = .default()) {
    self.center = center
    super.init()
  }

  public func start() {
    guard !isStarted else { return }
    isStarted = true
    center.addObserver(
      self,
      selector: #selector(receivePing(_:)),
      name: WorkspaceDiagnosticsHeartbeat.ping,
      object: nil
    )
  }

  public func stop() {
    guard isStarted else { return }
    center.removeObserver(
      self,
      name: WorkspaceDiagnosticsHeartbeat.ping,
      object: nil
    )
    isStarted = false
  }

  deinit {
    stop()
  }

  @objc private func receivePing(_ notification: Notification) {
    guard let targetPID = (notification.userInfo?[WorkspaceDiagnosticsHeartbeat.targetPIDKey] as? NSNumber)?.int32Value,
          targetPID == ProcessInfo.processInfo.processIdentifier,
          let nonce = notification.userInfo?[WorkspaceDiagnosticsHeartbeat.nonceKey] as? String,
          !nonce.isEmpty
    else {
      return
    }
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.sendAcknowledgement(targetPID: targetPID, nonce: nonce)
      }
      return
    }
    sendAcknowledgement(targetPID: targetPID, nonce: nonce)
  }

  private func sendAcknowledgement(targetPID: pid_t, nonce: String) {
    center.postNotificationName(
      WorkspaceDiagnosticsHeartbeat.acknowledgement,
      object: nil,
      userInfo: [
        WorkspaceDiagnosticsHeartbeat.nonceKey: nonce,
        WorkspaceDiagnosticsHeartbeat.responderPIDKey: NSNumber(value: targetPID),
      ],
      deliverImmediately: true
    )
  }
}

public struct WorkspaceDiagnosticsOptions: Equatable, Sendable {
  public var corpusPath: String?
  public var bundleIdentifier = "org.org2.workspace"
  public var targetPID: pid_t?
  public var pollIntervalSeconds = 1.0
  public var hangThresholdSeconds = 5.0
  public var cpuThresholdPercent = 95.0
  public var cpuThresholdDurationSeconds = 15.0
  public var memoryThresholdMegabytes = 1_536.0
  public var sampleDurationSeconds = 5
  public var cooldownSeconds = 600.0

  public init() {}

  public static func parse(_ arguments: [String]) throws -> WorkspaceDiagnosticsOptions {
    var options = WorkspaceDiagnosticsOptions()
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      func value() throws -> String {
        guard index + 1 < arguments.count else {
          throw WorkspaceDiagnosticsError.invalidArguments("Missing value for \(argument)")
        }
        index += 1
        return arguments[index]
      }

      switch argument {
      case "--corpus":
        options.corpusPath = try value()
      case "--bundle-id":
        options.bundleIdentifier = try value()
      case "--pid":
        let raw = try value()
        guard let parsed = pid_t(raw), parsed > 0 else {
          throw WorkspaceDiagnosticsError.invalidArguments("Invalid process ID: \(raw)")
        }
        options.targetPID = parsed
      case "--poll-seconds":
        options.pollIntervalSeconds = try positiveDouble(value(), flag: argument)
      case "--hang-seconds":
        options.hangThresholdSeconds = try nonnegativeDouble(value(), flag: argument)
      case "--cpu-percent":
        options.cpuThresholdPercent = try nonnegativeDouble(value(), flag: argument)
      case "--cpu-seconds":
        options.cpuThresholdDurationSeconds = try positiveDouble(value(), flag: argument)
      case "--memory-mb":
        options.memoryThresholdMegabytes = try nonnegativeDouble(value(), flag: argument)
      case "--sample-seconds":
        let raw = try value()
        guard let parsed = Int(raw), (1...30).contains(parsed) else {
          throw WorkspaceDiagnosticsError.invalidArguments("--sample-seconds must be between 1 and 30")
        }
        options.sampleDurationSeconds = parsed
      case "--cooldown-seconds":
        options.cooldownSeconds = try nonnegativeDouble(value(), flag: argument)
      case "--help", "-h":
        throw WorkspaceDiagnosticsError.helpRequested
      default:
        throw WorkspaceDiagnosticsError.invalidArguments("Unknown argument: \(argument)")
      }
      index += 1
    }
    guard !options.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkspaceDiagnosticsError.invalidArguments("--bundle-id cannot be empty")
    }
    return options
  }

  private static func positiveDouble(_ raw: String, flag: String) throws -> Double {
    guard let value = Double(raw), value > 0, value.isFinite else {
      throw WorkspaceDiagnosticsError.invalidArguments("\(flag) must be a positive number")
    }
    return value
  }

  private static func nonnegativeDouble(_ raw: String, flag: String) throws -> Double {
    guard let value = Double(raw), value >= 0, value.isFinite else {
      throw WorkspaceDiagnosticsError.invalidArguments("\(flag) must be zero or a positive number")
    }
    return value
  }

  public static let usage = """
  Usage:
    npm run diagnostics:macos -- [options]

  Options:
    --corpus PATH         Corpus receiving raw/diagnostics evidence.
                          Defaults to the target app's remembered corpus.
    --bundle-id ID        Target bundle identifier (default: org.org2.workspace).
    --pid PID             Monitor one process instead of following app launches.
    --poll-seconds N      Poll interval (default: 1).
    --hang-seconds N      Responsive-heartbeat threshold; 0 disables (default: 5).
    --cpu-percent N       Sustained process CPU threshold; 0 disables (default: 95).
    --cpu-seconds N       Required high-CPU duration (default: 15).
    --memory-mb N         Resident-memory threshold; 0 disables (default: 1536).
    --sample-seconds N    Stack sample duration, 1-30 seconds (default: 5).
    --cooldown-seconds N  Minimum delay between incidents (default: 600).
    --help                Show this help.
  """
}

public enum WorkspaceDiagnosticsError: LocalizedError, Equatable {
  case helpRequested
  case invalidArguments(String)
  case invalidCorpus(String)
  case fileSystem(String)

  public var errorDescription: String? {
    switch self {
    case .helpRequested:
      return nil
    case .invalidArguments(let message),
         .invalidCorpus(let message),
         .fileSystem(let message):
      return message
    }
  }
}

public struct WorkspaceDiagnosticsCorpus: Equatable, Sendable {
  public let root: URL
  public let id: String
  public let name: String

  public static func load(at root: URL) throws -> WorkspaceDiagnosticsCorpus {
    let standardized = root.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
      throw WorkspaceDiagnosticsError.invalidCorpus("Diagnostics corpus is not an existing directory: \(standardized.path)")
    }

    let configURL = standardized.appendingPathComponent("org2.json")
    let data: Data
    do {
      data = try Data(contentsOf: configURL)
    } catch {
      throw WorkspaceDiagnosticsError.invalidCorpus("A portable corpus identity is required in \(configURL.path)")
    }
    let config: Config
    do {
      config = try JSONDecoder().decode(Config.self, from: data)
    } catch {
      throw WorkspaceDiagnosticsError.invalidCorpus("Could not read corpus identity from \(configURL.path): \(error.localizedDescription)")
    }
    guard config.corpus.schema == "org2:corpus:v1",
          config.corpus.id.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$"#, options: .regularExpression) != nil,
          !config.corpus.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          ["personal", "shared", "project"].contains(config.corpus.kind)
    else {
      throw WorkspaceDiagnosticsError.invalidCorpus("The corpus identity in \(configURL.path) is incomplete or invalid")
    }
    return WorkspaceDiagnosticsCorpus(
      root: standardized,
      id: config.corpus.id,
      name: config.corpus.name
    )
  }

  private struct Config: Decodable {
    let corpus: Identity
  }

  private struct Identity: Decodable {
    let schema: String
    let id: String
    let name: String
    let kind: String
  }
}

public enum WorkspaceDiagnosticsTriggerKind: String, Codable, Sendable {
  case unresponsive
  case sustainedCPU = "sustained-cpu"
  case memoryThreshold = "memory-threshold"
}

public struct WorkspaceDiagnosticsTrigger: Equatable, Codable, Sendable {
  public let kind: WorkspaceDiagnosticsTriggerKind
  public let detail: String
}

public struct WorkspaceDiagnosticsResourceSample: Equatable, Codable, Sendable {
  public let capturedAt: Date
  public let cpuPercent: Double?
  public let residentBytes: UInt64
  public let heartbeatGapSeconds: Double?

  public init(
    capturedAt: Date,
    cpuPercent: Double?,
    residentBytes: UInt64,
    heartbeatGapSeconds: Double?
  ) {
    self.capturedAt = capturedAt
    self.cpuPercent = cpuPercent
    self.residentBytes = residentBytes
    self.heartbeatGapSeconds = heartbeatGapSeconds
  }
}

struct WorkspaceDiagnosticsPollObservation: Equatable, Sendable {
  let heartbeatGapSeconds: Double?
  let resumedAfterInterruption: Bool
}

struct WorkspaceDiagnosticsPollContinuity: Sendable {
  let expectedIntervalSeconds: Double
  private var lastPollAt: Date?

  init(expectedIntervalSeconds: Double) {
    self.expectedIntervalSeconds = expectedIntervalSeconds
  }

  mutating func observe(
    at date: Date,
    lastAcknowledgementAt: Date?,
    hasReceivedHeartbeat: Bool
  ) -> WorkspaceDiagnosticsPollObservation {
    let resumedAfterInterruption = lastPollAt.map {
      date.timeIntervalSince($0) > interruptionThresholdSeconds
    } ?? false
    lastPollAt = date
    let heartbeatGap = hasReceivedHeartbeat
      ? lastAcknowledgementAt.map {
        resumedAfterInterruption ? 0 : max(0, date.timeIntervalSince($0))
      }
      : nil
    return WorkspaceDiagnosticsPollObservation(
      heartbeatGapSeconds: heartbeatGap,
      resumedAfterInterruption: resumedAfterInterruption
    )
  }

  mutating func reset() {
    lastPollAt = nil
  }

  private var interruptionThresholdSeconds: Double {
    max(expectedIntervalSeconds * 3, expectedIntervalSeconds + 2)
  }
}

public struct WorkspaceDiagnosticsTriggerEvaluator: Sendable {
  public var hangThresholdSeconds: Double
  public var cpuThresholdPercent: Double
  public var cpuThresholdDurationSeconds: Double
  public var memoryThresholdBytes: UInt64
  public var cooldownSeconds: Double

  private var highCPUStartedAt: Date?
  private var lastIncidentAt: Date?

  public init(
    hangThresholdSeconds: Double,
    cpuThresholdPercent: Double,
    cpuThresholdDurationSeconds: Double,
    memoryThresholdBytes: UInt64,
    cooldownSeconds: Double
  ) {
    self.hangThresholdSeconds = hangThresholdSeconds
    self.cpuThresholdPercent = cpuThresholdPercent
    self.cpuThresholdDurationSeconds = cpuThresholdDurationSeconds
    self.memoryThresholdBytes = memoryThresholdBytes
    self.cooldownSeconds = cooldownSeconds
  }

  public mutating func evaluate(_ sample: WorkspaceDiagnosticsResourceSample) -> WorkspaceDiagnosticsTrigger? {
    if let cpuPercent = sample.cpuPercent,
       cpuThresholdPercent > 0,
       cpuPercent >= cpuThresholdPercent {
      highCPUStartedAt = highCPUStartedAt ?? sample.capturedAt
    } else {
      highCPUStartedAt = nil
    }

    if let lastIncidentAt,
       sample.capturedAt.timeIntervalSince(lastIncidentAt) < cooldownSeconds {
      return nil
    }

    if hangThresholdSeconds > 0,
       let gap = sample.heartbeatGapSeconds,
       gap >= hangThresholdSeconds {
      return WorkspaceDiagnosticsTrigger(
        kind: .unresponsive,
        detail: String(format: "Main-thread heartbeat missing for %.1f seconds", gap)
      )
    }

    if memoryThresholdBytes > 0,
       sample.residentBytes >= memoryThresholdBytes {
      return WorkspaceDiagnosticsTrigger(
        kind: .memoryThreshold,
        detail: "Resident memory reached \(sample.residentBytes / 1_048_576) MB"
      )
    }

    if let highCPUStartedAt,
       sample.capturedAt.timeIntervalSince(highCPUStartedAt) >= cpuThresholdDurationSeconds,
       let cpuPercent = sample.cpuPercent {
      return WorkspaceDiagnosticsTrigger(
        kind: .sustainedCPU,
        detail: String(format: "Process CPU remained at or above %.0f%% (latest %.1f%%)", cpuThresholdPercent, cpuPercent)
      )
    }

    return nil
  }

  public mutating func recordIncident(at date: Date) {
    lastIncidentAt = date
    highCPUStartedAt = nil
  }

  public mutating func resetTarget() {
    highCPUStartedAt = nil
  }
}

public struct WorkspaceDiagnosticsStackSample: Equatable, Sendable {
  public let exitStatus: Int32
  public let error: String?

  public init(exitStatus: Int32, error: String?) {
    self.exitStatus = exitStatus
    self.error = error
  }
}

public protocol WorkspaceDiagnosticsStackSampling {
  func capture(pid: pid_t, durationSeconds: Int, outputURL: URL) -> WorkspaceDiagnosticsStackSample
}

public struct SystemWorkspaceDiagnosticsStackSampler: WorkspaceDiagnosticsStackSampling {
  public init() {}

  public func capture(pid: pid_t, durationSeconds: Int, outputURL: URL) -> WorkspaceDiagnosticsStackSample {
    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    process.arguments = [
      String(pid),
      String(durationSeconds),
      "10",
      "-mayDie",
      "-file", outputURL.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = standardError
    do {
      try process.run()
      process.waitUntilExit()
      let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
      let errorText = String(data: errorData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return WorkspaceDiagnosticsStackSample(
        exitStatus: process.terminationStatus,
        error: errorText?.isEmpty == false ? errorText : nil
      )
    } catch {
      let message = "Could not run /usr/bin/sample: \(error.localizedDescription)"
      try? Data((message + "\n").utf8).write(to: outputURL, options: .atomic)
      return WorkspaceDiagnosticsStackSample(exitStatus: -1, error: message)
    }
  }
}

public struct WorkspaceDiagnosticsTargetMetadata: Equatable, Codable, Sendable {
  public let pid: Int32
  public let bundleIdentifier: String
  public let applicationName: String
  public let applicationVersion: String?
  public let applicationBuild: String?
  public let executableName: String?
}

public struct WorkspaceDiagnosticsIncident: Equatable, Codable, Sendable {
  public static let schema = "org2:workspace-diagnostic:v1"

  public let schema: String
  public let id: String
  public let capturedAt: Date
  public let trigger: WorkspaceDiagnosticsTrigger
  public let target: WorkspaceDiagnosticsTargetMetadata
  public let corpusID: String
  public let operatingSystemVersion: String
  public let pollIntervalSeconds: Double
  public let sampleDurationSeconds: Int
  public let stackSampleExitStatus: Int32
  public let stackSampleError: String?
  public let hotPathFingerprint: String?
  public let hotPathFrames: [String]
  public let resourceSamples: [WorkspaceDiagnosticsResourceSample]
}

public struct WorkspaceDiagnosticsIncidentWriter {
  public let corpus: WorkspaceDiagnosticsCorpus
  public let stackSampler: any WorkspaceDiagnosticsStackSampling

  public init(
    corpus: WorkspaceDiagnosticsCorpus,
    stackSampler: any WorkspaceDiagnosticsStackSampling = SystemWorkspaceDiagnosticsStackSampler()
  ) {
    self.corpus = corpus
    self.stackSampler = stackSampler
  }

  public func capture(
    trigger: WorkspaceDiagnosticsTrigger,
    target: WorkspaceDiagnosticsTargetMetadata,
    samples: [WorkspaceDiagnosticsResourceSample],
    pollIntervalSeconds: Double,
    sampleDurationSeconds: Int,
    at capturedAt: Date = Date()
  ) throws -> URL {
    let identifier = UUID().uuidString.lowercased()
    let timestamp = Self.pathTimestamp(capturedAt)
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: capturedAt)
    let parent = corpus.root
      .appendingPathComponent("raw/diagnostics/org2-workspace", isDirectory: true)
      .appendingPathComponent(String(format: "%04d", components.year ?? 0), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.month ?? 0), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.day ?? 0), isDirectory: true)
    let finalName = "\(timestamp)-\(trigger.kind.rawValue)-\(target.pid)-\(identifier.prefix(8))"
    let finalURL = parent.appendingPathComponent(finalName, isDirectory: true)
    let pendingURL = parent.appendingPathComponent(".pending-\(identifier)", isDirectory: true)

    do {
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: false)
      let stackURL = pendingURL.appendingPathComponent("stacks.sample.txt")
      let stackResult = stackSampler.capture(
        pid: target.pid,
        durationSeconds: sampleDurationSeconds,
        outputURL: stackURL
      )
      let stackText = (try? String(contentsOf: stackURL, encoding: .utf8)) ?? ""
      let hotPathFrames = Self.hotPathFrames(in: stackText)
      let incident = WorkspaceDiagnosticsIncident(
        schema: WorkspaceDiagnosticsIncident.schema,
        id: identifier,
        capturedAt: capturedAt,
        trigger: trigger,
        target: target,
        corpusID: corpus.id,
        operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        pollIntervalSeconds: pollIntervalSeconds,
        sampleDurationSeconds: sampleDurationSeconds,
        stackSampleExitStatus: stackResult.exitStatus,
        stackSampleError: stackResult.error,
        hotPathFingerprint: hotPathFrames.isEmpty ? nil : Self.stableFingerprint(hotPathFrames),
        hotPathFrames: hotPathFrames,
        resourceSamples: Array(samples.suffix(120))
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      var data = try encoder.encode(incident)
      data.append(0x0A)
      try data.write(to: pendingURL.appendingPathComponent("incident.json"), options: .atomic)
      try FileManager.default.moveItem(at: pendingURL, to: finalURL)
      return finalURL
    } catch {
      try? FileManager.default.removeItem(at: pendingURL)
      throw WorkspaceDiagnosticsError.fileSystem("Could not write diagnostic incident: \(error.localizedDescription)")
    }
  }

  public static func hotPathFrames(in sample: String) -> [String] {
    var frames: [String] = []
    var seen = Set<String>()
    for line in sample.split(separator: "\n", omittingEmptySubsequences: false) {
      guard line.contains("(in Org2Workspace)") else { continue }
      var normalized = line
        .replacingOccurrences(of: #"\s*\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let sourceRange = normalized.range(of: #"\s{2,}/"#, options: .regularExpression) {
        normalized = String(normalized[..<sourceRange.lowerBound])
      }
      guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
      frames.append(normalized)
      if frames.count == 24 { break }
    }
    return frames
  }

  public static func stableFingerprint(_ frames: [String]) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in frames.joined(separator: "\n").utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(format: "fnv1a64:%016llx", hash)
  }

  private static func pathTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }
}

public final class WorkspaceDiagnosticsMonitor: NSObject, @unchecked Sendable {
  private let options: WorkspaceDiagnosticsOptions
  private let corpus: WorkspaceDiagnosticsCorpus
  private let center: DistributedNotificationCenter
  private var evaluator: WorkspaceDiagnosticsTriggerEvaluator
  private var pollContinuity: WorkspaceDiagnosticsPollContinuity
  private var targetApplication: NSRunningApplication?
  private var targetPID: pid_t?
  private var lastAcknowledgementAt: Date?
  private var hasReceivedHeartbeat = false
  private var didReportMissingHeartbeatSupport = false
  private var pendingHeartbeatNonces: [String] = []
  private var previousCPUReading: (date: Date, nanoseconds: UInt64)?
  private var resourceSamples: [WorkspaceDiagnosticsResourceSample] = []
  private var timer: Timer?
  private var isCapturing = false

  public init(
    options: WorkspaceDiagnosticsOptions,
    corpus: WorkspaceDiagnosticsCorpus,
    center: DistributedNotificationCenter = .default()
  ) {
    self.options = options
    self.corpus = corpus
    self.center = center
    self.evaluator = WorkspaceDiagnosticsTriggerEvaluator(
      hangThresholdSeconds: options.hangThresholdSeconds,
      cpuThresholdPercent: options.cpuThresholdPercent,
      cpuThresholdDurationSeconds: options.cpuThresholdDurationSeconds,
      memoryThresholdBytes: UInt64(options.memoryThresholdMegabytes * 1_048_576),
      cooldownSeconds: options.cooldownSeconds
    )
    self.pollContinuity = WorkspaceDiagnosticsPollContinuity(
      expectedIntervalSeconds: options.pollIntervalSeconds
    )
    super.init()
  }

  public func run() {
    print("Watching \(options.bundleIdentifier) every \(String(format: "%.1f", options.pollIntervalSeconds)) seconds. Press Control-C to stop.")
    center.addObserver(
      self,
      selector: #selector(receiveAcknowledgement(_:)),
      name: WorkspaceDiagnosticsHeartbeat.acknowledgement,
      object: nil
    )
    let timer = Timer(
      timeInterval: options.pollIntervalSeconds,
      target: self,
      selector: #selector(tick),
      userInfo: nil,
      repeats: true
    )
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    tick()
    RunLoop.main.run()
  }

  public func stop() {
    timer?.invalidate()
    timer = nil
    center.removeObserver(self)
    CFRunLoopStop(CFRunLoopGetMain())
  }

  @objc private func tick() {
    guard !isCapturing else { return }
    guard let application = resolveTargetApplication() else {
      clearTargetIfNeeded()
      return
    }
    let pid = application.processIdentifier
    if targetPID != pid {
      beginMonitoring(application)
    }

    let now = Date()
    let pollObservation = pollContinuity.observe(
      at: now,
      lastAcknowledgementAt: lastAcknowledgementAt,
      hasReceivedHeartbeat: hasReceivedHeartbeat
    )
    if pollObservation.resumedAfterInterruption {
      // The helper cannot observe target responsiveness while its own timer is
      // suspended, including during system sleep. Start a fresh sample window.
      lastAcknowledgementAt = now
      pendingHeartbeatNonces = []
      previousCPUReading = nil
      resourceSamples = []
      evaluator.resetTarget()
    }
    sendHeartbeatPing(to: pid)
    guard let processReading = Self.readProcess(pid: pid, at: now) else {
      clearTargetIfNeeded()
      return
    }
    let cpuPercent = cpuPercent(for: processReading)
    let heartbeatGap = pollObservation.heartbeatGapSeconds
    if !hasReceivedHeartbeat,
       !didReportMissingHeartbeatSupport,
       let startedAt = lastAcknowledgementAt,
       now.timeIntervalSince(startedAt) >= max(5, options.hangThresholdSeconds) {
      didReportMissingHeartbeatSupport = true
      print("Heartbeat responder not detected in PID \(pid); continuing with CPU and memory monitoring.")
    }

    let sample = WorkspaceDiagnosticsResourceSample(
      capturedAt: now,
      cpuPercent: cpuPercent,
      residentBytes: processReading.residentBytes,
      heartbeatGapSeconds: heartbeatGap
    )
    resourceSamples.append(sample)
    if resourceSamples.count > 180 {
      resourceSamples.removeFirst(resourceSamples.count - 180)
    }
    guard let trigger = evaluator.evaluate(sample) else { return }
    captureIncident(trigger: trigger, application: application, at: now)
  }

  @objc private func receiveAcknowledgement(_ notification: Notification) {
    guard let pid = (notification.userInfo?[WorkspaceDiagnosticsHeartbeat.responderPIDKey] as? NSNumber)?.int32Value,
          pid == targetPID,
          let nonce = notification.userInfo?[WorkspaceDiagnosticsHeartbeat.nonceKey] as? String,
          pendingHeartbeatNonces.contains(nonce)
    else {
      return
    }
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.recordAcknowledgement(nonce: nonce)
      }
      return
    }
    recordAcknowledgement(nonce: nonce)
  }

  private func recordAcknowledgement(nonce: String) {
    pendingHeartbeatNonces.removeAll { $0 == nonce }
    hasReceivedHeartbeat = true
    lastAcknowledgementAt = Date()
  }

  private func resolveTargetApplication() -> NSRunningApplication? {
    if let requestedPID = options.targetPID {
      return NSRunningApplication(processIdentifier: requestedPID)
    }
    return NSRunningApplication
      .runningApplications(withBundleIdentifier: options.bundleIdentifier)
      .first(where: { !$0.isTerminated })
  }

  private func beginMonitoring(_ application: NSRunningApplication) {
    targetApplication = application
    targetPID = application.processIdentifier
    lastAcknowledgementAt = Date()
    hasReceivedHeartbeat = false
    didReportMissingHeartbeatSupport = false
    pendingHeartbeatNonces = []
    previousCPUReading = nil
    resourceSamples = []
    pollContinuity.reset()
    evaluator.resetTarget()
    print("Monitoring \(application.localizedName ?? options.bundleIdentifier) (PID \(application.processIdentifier)); incidents → raw/diagnostics/org2-workspace in corpus \(corpus.id)")
  }

  private func clearTargetIfNeeded() {
    guard targetPID != nil else { return }
    print("Target app exited; waiting for the next launch.")
    targetApplication = nil
    targetPID = nil
    lastAcknowledgementAt = nil
    hasReceivedHeartbeat = false
    didReportMissingHeartbeatSupport = false
    pendingHeartbeatNonces = []
    previousCPUReading = nil
    resourceSamples = []
    pollContinuity.reset()
    evaluator.resetTarget()
  }

  private func sendHeartbeatPing(to pid: pid_t) {
    let nonce = UUID().uuidString
    pendingHeartbeatNonces.append(nonce)
    if pendingHeartbeatNonces.count > 16 {
      pendingHeartbeatNonces.removeFirst(pendingHeartbeatNonces.count - 16)
    }
    center.postNotificationName(
      WorkspaceDiagnosticsHeartbeat.ping,
      object: nil,
      userInfo: [
        WorkspaceDiagnosticsHeartbeat.targetPIDKey: NSNumber(value: pid),
        WorkspaceDiagnosticsHeartbeat.nonceKey: nonce,
      ],
      deliverImmediately: true
    )
  }

  private func cpuPercent(for reading: ProcessReading) -> Double? {
    defer {
      previousCPUReading = (reading.capturedAt, reading.cpuNanoseconds)
    }
    guard let previousCPUReading,
          reading.cpuNanoseconds >= previousCPUReading.nanoseconds
    else {
      return nil
    }
    let elapsed = reading.capturedAt.timeIntervalSince(previousCPUReading.date)
    guard elapsed > 0 else { return nil }
    let cpuSeconds = Double(reading.cpuNanoseconds - previousCPUReading.nanoseconds) / 1_000_000_000
    return max(0, cpuSeconds / elapsed * 100)
  }

  private func captureIncident(
    trigger: WorkspaceDiagnosticsTrigger,
    application: NSRunningApplication,
    at date: Date
  ) {
    isCapturing = true
    defer { isCapturing = false }
    print("Capturing \(trigger.kind.rawValue): \(trigger.detail)")
    let executableName = application.executableURL?.lastPathComponent
    let appBundleURL = application.bundleURL
    let bundle = appBundleURL.flatMap(Bundle.init(url:))
    let metadata = WorkspaceDiagnosticsTargetMetadata(
      pid: application.processIdentifier,
      bundleIdentifier: application.bundleIdentifier ?? options.bundleIdentifier,
      applicationName: application.localizedName ?? "Org2Workspace",
      applicationVersion: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      applicationBuild: bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      executableName: executableName
    )
    do {
      let output = try WorkspaceDiagnosticsIncidentWriter(corpus: corpus).capture(
        trigger: trigger,
        target: metadata,
        samples: resourceSamples,
        pollIntervalSeconds: options.pollIntervalSeconds,
        sampleDurationSeconds: options.sampleDurationSeconds,
        at: date
      )
      evaluator.recordIncident(at: date)
      print("Wrote diagnostic incident: \(output.path)")
    } catch {
      evaluator.recordIncident(at: date)
      FileHandle.standardError.write(Data("Diagnostic capture failed: \(error.localizedDescription)\n".utf8))
    }
  }

  private struct ProcessReading {
    let capturedAt: Date
    let cpuNanoseconds: UInt64
    let residentBytes: UInt64
  }

  private static func readProcess(pid: pid_t, at date: Date) -> ProcessReading? {
    var info = proc_taskinfo()
    let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
    let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expectedSize)
    guard result == expectedSize else { return nil }
    return ProcessReading(
      capturedAt: date,
      cpuNanoseconds: info.pti_total_user + info.pti_total_system,
      residentBytes: info.pti_resident_size
    )
  }
}
