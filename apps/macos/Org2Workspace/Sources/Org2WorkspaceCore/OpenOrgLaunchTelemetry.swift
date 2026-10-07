import Combine
import Foundation

/// One best-effort event per production app process. No corpus or installation identity is read.
@MainActor
public final class OpenOrgLaunchTelemetry: ObservableObject {
  public static let enabledKey = "OpenOrg.launchTelemetry.enabled.v1"
  public static let endpoint = URL(string: "https://org2.gateway.scarf.sh/telemetry/celorga/launch")!

  @Published public var enabled: Bool {
    didSet {
      defaults.set(enabled, forKey: Self.enabledKey)
      if !enabled { submission?.cancel() }
    }
  }

  private let defaults: UserDefaults
  private let send: @Sendable (URLRequest) async throws -> Void
  private var attemptedLaunch = false
  private var submission: Task<Void, Never>?

  public init(
    defaults: UserDefaults = .standard,
    send: @escaping @Sendable (URLRequest) async throws -> Void = OpenOrgLaunchTelemetry.submit
  ) {
    self.defaults = defaults
    self.send = send
    enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
  }

  public func recordLaunch(
    bundleIdentifier: String?,
    version: String?,
    osVersion: String,
    architecture: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments
  ) {
    guard !attemptedLaunch else { return }
    attemptedLaunch = true
    guard enabled,
          bundleIdentifier == "org.org2.workspace",
          let version, !version.isEmpty,
          environment["DO_NOT_TRACK"] != "1",
          environment["SCARF_ANALYTICS"]?.lowercased() != "false",
          !arguments.contains("--smoke-test"),
          !arguments.contains("--quit-after-launch") else { return }
    let request = Self.request(version: version, osVersion: osVersion, architecture: architecture)
    let send = self.send
    submission = Task {
      guard !Task.isCancelled else { return }
      // A telemetry failure must never interrupt startup or trigger a duplicate event.
      try? await send(request)
    }
  }

  public static func request(version: String, osVersion: String, architecture: String) -> URLRequest {
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Celorga/\(version)", forHTTPHeaderField: "User-Agent")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "event": "app_launch",
      "version": version,
      "platform": "macos",
      "os_version": osVersion,
      "architecture": architecture,
      "schema_version": "1",
    ])
    return request
  }

  public nonisolated static func submit(_ request: URLRequest) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    _ = try await session.data(for: request)
  }
}
