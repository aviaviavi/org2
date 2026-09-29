import Foundation

/// Finds locally installed agent CLIs (Codex, Claude Code, OpenCode, Pi) for a
/// GUI app.
///
/// Apps launched from Finder, the Dock, or Launch Services inherit a minimal
/// `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`). CLIs installed through npm under
/// nvm/Volta/fnm, Bun, pnpm, mise, asdf, or a custom npm prefix are therefore
/// invisible to a plain `PATH` scan even though they work in Terminal. The
/// locator checks the conventional per-user install directories and the
/// user's login-shell `PATH`, and augments child-process environments so
/// `#!/usr/bin/env node` launchers can find their runtime.
public enum LocalAgentExecutableLocator {
  /// Returns the first executable regular file among the ordered candidates.
  ///
  /// Candidate order: `configuredKey` override, `leadingCandidates`, the
  /// login-shell `PATH`, conventional per-user install directories, Homebrew,
  /// then the process `PATH`.
  public static func resolve(
    executableName: String,
    configuredKey: String,
    leadingCandidates: [String] = [],
    environment: [String: String],
    fileManager: FileManager = .default,
    loginShellPATH: String? = LocalAgentExecutableLocator.cachedLoginShellPATH()
  ) -> URL? {
    var candidates: [String] = []
    if let configured = environment[configuredKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
       !configured.isEmpty {
      candidates.append(configured)
    }
    candidates.append(contentsOf: leadingCandidates)
    let directories = searchDirectories(
      environment: environment,
      fileManager: fileManager,
      loginShellPATH: loginShellPATH
    )
    candidates.append(contentsOf: directories.map {
      URL(fileURLWithPath: $0).appendingPathComponent(executableName).path
    })
    return candidates.lazy
      .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
      .first {
        fileManager.isExecutableFile(atPath: $0.path)
          && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != false
      }
  }

  /// Ordered, de-duplicated directories that may contain user-installed CLIs.
  static func searchDirectories(
    environment: [String: String],
    fileManager: FileManager = .default,
    loginShellPATH: String?
  ) -> [String] {
    let home = environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
    func inHome(_ relative: String) -> String {
      URL(fileURLWithPath: home).appendingPathComponent(relative).path
    }
    // The login-shell PATH mirrors Terminal, so it wins when available.
    var directories: [String] = loginShellPATH?.split(separator: ":").map(String.init) ?? []
    directories.append(contentsOf: [
      inHome(".local/bin"),
      inHome(".npm-global/bin"),
      inHome(".npm/bin"),
      inHome(".volta/bin"),
      inHome(".bun/bin"),
      inHome("Library/pnpm"),
      inHome(".local/share/pnpm"),
      inHome(".yarn/bin"),
      inHome(".local/share/mise/shims"),
      inHome(".asdf/shims"),
      inHome(".nodenv/shims"),
      inHome(".claude/local"),
      inHome(".opencode/bin")
    ])
    if let prefix = environment["NPM_CONFIG_PREFIX"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !prefix.isEmpty {
      directories.append(URL(fileURLWithPath: prefix).appendingPathComponent("bin").path)
    }
    directories.append(contentsOf: versionedNodeBinDirectories(
      root: inHome(".nvm/versions/node"),
      fileManager: fileManager
    ))
    directories.append(contentsOf: versionedNodeBinDirectories(
      root: inHome(".local/share/fnm/node-versions"),
      suffix: "installation/bin",
      fileManager: fileManager
    ))
    directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
    if let path = environment["PATH"] {
      directories.append(contentsOf: path.split(separator: ":").map(String.init))
    }
    var seen = Set<String>()
    return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// Returns `base` with a `PATH` that also includes the resolved
  /// executable's directories and the user's install directories, so script
  /// launchers such as npm's `#!/usr/bin/env node` shims can start.
  public static func processEnvironment(
    _ base: [String: String],
    executableURL: URL?,
    fileManager: FileManager = .default,
    loginShellPATH: String? = LocalAgentExecutableLocator.cachedLoginShellPATH()
  ) -> [String: String] {
    var environment = base
    var directories: [String] = []
    if let executableURL {
      directories.append(executableURL.deletingLastPathComponent().path)
    }
    directories.append(contentsOf: base["PATH"]?.split(separator: ":").map(String.init) ?? [])
    directories.append(contentsOf: searchDirectories(
      environment: base,
      fileManager: fileManager,
      loginShellPATH: loginShellPATH
    ))
    directories.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    var seen = Set<String>()
    let existing = directories.filter { directory in
      guard !directory.isEmpty, seen.insert(directory).inserted else { return false }
      var isDirectory: ObjCBool = false
      return fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    environment["PATH"] = existing.joined(separator: ":")
    return environment
  }

  private static func versionedNodeBinDirectories(
    root: String,
    suffix: String = "bin",
    fileManager: FileManager
  ) -> [String] {
    guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
    return versions
      .filter { !$0.hasPrefix(".") }
      .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
      .map { URL(fileURLWithPath: root).appendingPathComponent($0).appendingPathComponent(suffix).path }
  }

  // MARK: Login-shell PATH

  private static let loginShellPATHLock = NSLock()
  nonisolated(unsafe) private static var loginShellPATHState: LoginShellPATHState = .unknown

  private enum LoginShellPATHState {
    case unknown
    case loading
    case resolved(String?)
  }

  /// The user's login-shell `PATH`, probed at most once per process.
  ///
  /// The main thread never blocks on the probe: it starts a background probe
  /// and returns `nil` until the result is available. Background callers wait
  /// for the bounded probe.
  public static func cachedLoginShellPATH() -> String? {
    loginShellPATHLock.lock()
    switch loginShellPATHState {
    case .resolved(let path):
      loginShellPATHLock.unlock()
      return path
    case .loading:
      loginShellPATHLock.unlock()
      return nil
    case .unknown:
      loginShellPATHState = .loading
      loginShellPATHLock.unlock()
    }
    if Thread.isMainThread {
      DispatchQueue.global(qos: .utility).async {
        storeLoginShellPATH(probeLoginShellPATH())
      }
      return nil
    }
    let path = probeLoginShellPATH()
    storeLoginShellPATH(path)
    return path
  }

  /// Starts the one-time login-shell probe in the background.
  public static func warmUp() {
    DispatchQueue.global(qos: .utility).async {
      _ = cachedLoginShellPATH()
    }
  }

  private static func storeLoginShellPATH(_ path: String?) {
    loginShellPATHLock.lock()
    loginShellPATHState = .resolved(path)
    loginShellPATHLock.unlock()
  }

  static func probeLoginShellPATH(
    shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
    timeout: TimeInterval = 4
  ) -> String? {
    let shellPath = FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    let marker = "__OPENORG_PATH__"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shellPath)
    // An interactive login shell reads the same rc files as Terminal, where
    // version managers usually extend PATH. Markers isolate PATH from any
    // banner text the rc files print.
    process.arguments = ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = environment["TERM"] ?? "dumb"
    process.environment = environment
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
      try process.run()
    } catch {
      return nil
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return parseLoginShellPATH(String(decoding: data, as: UTF8.self), marker: marker)
  }

  static func parseLoginShellPATH(_ output: String, marker: String = "__OPENORG_PATH__") -> String? {
    let parts = output.components(separatedBy: marker)
    guard parts.count >= 3 else { return nil }
    let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }
}
