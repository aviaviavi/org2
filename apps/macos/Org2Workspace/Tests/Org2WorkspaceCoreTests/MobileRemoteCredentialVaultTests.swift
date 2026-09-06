import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class MobileRemoteCredentialVaultTests: XCTestCase {
  @MainActor
  func testHeadlessOpenClawUsesConfiguredDestinationInsteadOfDesktopSettings() throws {
    let suite = "HeadlessDestinationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("http://old-host.invalid:18789", forKey: "Org2Workspace.openClawEndpoint")
    defaults.set("old-agent", forKey: "Org2Workspace.openClawAgent")
    let destination = AIChatDestinationConfiguration(
      id: AIChatDestinationConfiguration.openClawID,
      name: "OpenClaw", mention: "openclaw", adapter: .openClaw,
      endpoint: "http://127.0.0.1:19876/v1/chat/completions", agentID: "openclaw/workspace"
    )
    defaults.set(try JSONEncoder().encode([destination]), forKey: "Org2Workspace.aiChat.destinations.v1")
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: URL(fileURLWithPath: "/tmp"), nodePath: "/usr/bin/false"),
      defaults: defaults, legacyDefaultsDomains: []
    )
    XCTAssertEqual(store.aiChatDestination(id: destination.id)?.agentID, "",
                   "Desktop restores keep inheriting the global agent setting")
    store.configureHeadlessDestinations([destination])
    XCTAssertEqual(store.openClawEndpointText, destination.endpoint)
    XCTAssertEqual(store.openClawAgentID, destination.agentID)
    XCTAssertEqual(defaults.string(forKey: "Org2Workspace.openClawAgent"), "old-agent",
                   "Applying headless configuration must not rewrite desktop preferences")
  }

  func testHeadlessPairingPersistsOnlyHashAndRevokesAcrossRestart() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("devices.json")
    let vault = MobileRemoteCredentialVault(credentialFile: file)
    let paired = try vault.pair(deviceName: "Test phone")
    XCTAssertTrue(vault.contains(token: paired.token))
    XCTAssertFalse(vault.contains(token: "incorrect"))
    let raw = try String(contentsOf: file, encoding: .utf8)
    XCTAssertFalse(raw.contains(paired.token), "The headless server must not persist bearer credentials")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let restored = MobileRemoteCredentialVault(credentialFile: file)
    XCTAssertTrue(restored.contains(token: paired.token))
    XCTAssertEqual(restored.devices.map(\.id), [paired.device.id])
    try restored.revoke(paired.device.id)
    XCTAssertFalse(MobileRemoteCredentialVault(credentialFile: file).contains(token: paired.token))
  }

  func testHeadlessRuntimeDiscoveryFollowsPackageManagerSymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("runtime")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let link = directory.appendingPathComponent("linked-runtime")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
    XCTAssertEqual(CodexAppServerClient.resolveExecutableURL(environment: ["ORG2_CODEX_EXECUTABLE": link.path]), executable.resolvingSymlinksInPath())
    XCTAssertEqual(ClaudeCodeClient.resolveExecutableURL(environment: ["ORG2_CLAUDE_EXECUTABLE": link.path]), executable.resolvingSymlinksInPath())
  }

  func testCorruptHeadlessCredentialsFailClosed() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("devices.json")
    try Data("invalid".utf8).write(to: file)
    let vault = MobileRemoteCredentialVault(credentialFile: file)
    XCTAssertThrowsError(try vault.pair(deviceName: "Test phone"))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "invalid")
    XCTAssertTrue(vault.devices.isEmpty)
  }
}
