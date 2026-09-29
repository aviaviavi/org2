import XCTest
@testable import Org2WorkspaceCore

final class LocalAgentExecutableLocatorTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-locator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  private func makeExecutable(_ relativePath: String) throws -> URL {
    let url = home.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "#!/usr/bin/env node\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  /// A Finder-launched app sees PATH=/usr/bin:/bin:/usr/sbin:/sbin, so an
  /// npm install under nvm must be found without relying on PATH.
  func testFindsCodexInstalledUnderNVMWithMinimalGUIPath() throws {
    _ = try makeExecutable(".nvm/versions/node/v18.20.0/bin/codex")
    let newest = try makeExecutable(".nvm/versions/node/v22.11.0/bin/codex")

    let resolved = LocalAgentExecutableLocator.resolve(
      executableName: "codex",
      configuredKey: "ORG2_CODEX_EXECUTABLE",
      environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
      loginShellPATH: nil
    )

    XCTAssertEqual(resolved, newest.standardizedFileURL.resolvingSymlinksInPath())
  }

  func testFindsExecutablesInCommonUserInstallDirectories() throws {
    for relative in [".npm-global/bin", ".volta/bin", ".bun/bin", "Library/pnpm", ".local/share/mise/shims"] {
      let executable = try makeExecutable("\(relative)/codex")
      XCTAssertEqual(
        LocalAgentExecutableLocator.resolve(
          executableName: "codex",
          configuredKey: "ORG2_CODEX_EXECUTABLE",
          environment: ["HOME": home.path, "PATH": ""],
          loginShellPATH: nil
        ),
        executable.standardizedFileURL.resolvingSymlinksInPath(),
        relative
      )
      try FileManager.default.removeItem(at: executable)
    }
  }

  func testFallsBackToLoginShellPath() throws {
    let executable = try makeExecutable("custom/tools/bin/codex")

    XCTAssertEqual(
      LocalAgentExecutableLocator.resolve(
        executableName: "codex",
        configuredKey: "ORG2_CODEX_EXECUTABLE",
        environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
        loginShellPATH: "/usr/bin:\(executable.deletingLastPathComponent().path)"
      ),
      executable.standardizedFileURL.resolvingSymlinksInPath()
    )
    XCTAssertNil(
      LocalAgentExecutableLocator.resolve(
        executableName: "codex",
        configuredKey: "ORG2_CODEX_EXECUTABLE",
        environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
        loginShellPATH: nil
      ).flatMap { $0.path.hasPrefix(home.path) ? $0 : nil }
    )
  }

  func testConfiguredExecutableWins() throws {
    _ = try makeExecutable(".local/bin/codex")
    let configured = try makeExecutable("pinned/codex")

    XCTAssertEqual(
      LocalAgentExecutableLocator.resolve(
        executableName: "codex",
        configuredKey: "ORG2_CODEX_EXECUTABLE",
        environment: ["HOME": home.path, "PATH": "", "ORG2_CODEX_EXECUTABLE": configured.path],
        loginShellPATH: nil
      ),
      configured.standardizedFileURL.resolvingSymlinksInPath()
    )
  }

  /// npm shims are `#!/usr/bin/env node` scripts; the node binary sits beside
  /// them, so the child PATH must include the launcher's directory.
  func testProcessEnvironmentIncludesLauncherAndUserDirectories() throws {
    let executable = try makeExecutable(".nvm/versions/node/v22.11.0/bin/codex")
    let loginDirectory = home.appendingPathComponent("login/bin")
    try FileManager.default.createDirectory(at: loginDirectory, withIntermediateDirectories: true)

    let environment = LocalAgentExecutableLocator.processEnvironment(
      ["HOME": home.path, "PATH": "/usr/bin:/bin", "KEEP": "1"],
      executableURL: executable,
      loginShellPATH: "\(loginDirectory.path):/does/not/exist"
    )
    let path = try XCTUnwrap(environment["PATH"]).split(separator: ":").map(String.init)

    XCTAssertEqual(environment["KEEP"], "1")
    XCTAssertEqual(path.first, executable.deletingLastPathComponent().path)
    XCTAssertTrue(path.contains("/usr/bin"))
    XCTAssertTrue(path.contains(loginDirectory.path))
    XCTAssertFalse(path.contains("/does/not/exist"))
    XCTAssertEqual(path.count, Set(path).count)
  }

  func testParsesLoginShellPathBetweenMarkers() {
    XCTAssertEqual(
      LocalAgentExecutableLocator.parseLoginShellPATH(
        "Welcome banner\n__OPENORG_PATH__/a/bin:/usr/bin__OPENORG_PATH__"
      ),
      "/a/bin:/usr/bin"
    )
    XCTAssertNil(LocalAgentExecutableLocator.parseLoginShellPATH("no markers"))
    XCTAssertNil(LocalAgentExecutableLocator.parseLoginShellPATH("__OPENORG_PATH____OPENORG_PATH__"))
  }
}
