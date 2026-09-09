import AppKit
import Darwin
import Foundation
import Security
import Org2WorkspaceCore

private struct ServerConfiguration: Decodable {
  let schema: String
  let hostRef: String
  let name: String
  let corpusRoot: String
  let bindHost: String
  let port: UInt16
  let repoRoot: String
  let nodePath: String
  let destinations: [AIChatDestinationConfiguration]
  let schedulesEnabled: Bool
}

/// The CLI owns process supervision and the private control socket. This worker
/// owns the same chat/relay implementation as the desktop, without any windows.
@main
struct OpenOrgServer {
  @MainActor
  static func main() async {
    do {
      // A LaunchAgent cannot answer Keychain dialogs. Blocking reads can
      // exhaust Swift's cooperative executor and freeze the entire relay.
      // Keep this policy process-local; the desktop retains interactive access.
      SecKeychainSetUserInteractionAllowed(false)
      guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--config" else {
        throw CocoaError(.fileReadInvalidFileName)
      }
      let configURL = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
      let stateDirectory = configURL.deletingLastPathComponent()
      let attributes = try FileManager.default.attributesOfItem(atPath: stateDirectory.path)
      guard let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else {
        throw CocoaError(.fileReadNoPermission)
      }
      let data = try Data(contentsOf: configURL)
      let config = try JSONDecoder().decode(ServerConfiguration.self, from: data)
      guard config.schema == "org2:server-config:v1",
            !config.hostRef.isEmpty,
            MobileRemoteCoordinator.isTailscaleIPv4(config.bindHost),
            config.port > 0,
            FileManager.default.fileExists(atPath: config.corpusRoot + "/org2.json") else {
        throw CocoaError(.fileReadCorruptFile)
      }
      // The inode is kept across crashes; the OS releases this advisory lock.
      // This also protects against two configurations selecting the same corpus.
      let lockPath = config.corpusRoot + "/.org2/openorg-server.lock"
      try FileManager.default.createDirectory(atPath: config.corpusRoot + "/.org2", withIntermediateDirectories: true)
      let lock = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
      guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        throw NSError(domain: "OpenOrgServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "A server already owns this corpus"])
      }
      defer { Darwin.close(lock) }
      let activity = ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .userInitiated],
        reason: "OpenOrg is hosting chat and scheduled automations"
      )
      defer { ProcessInfo.processInfo.endActivity(activity) }
      NSApplication.shared.setActivationPolicy(.prohibited)
      let namespace = "org.org2.server.\(config.hostRef)"
      guard let defaults = UserDefaults(suiteName: namespace) else {
        throw CocoaError(.fileWriteUnknown)
      }
      defaults.set(try JSONEncoder().encode(config.destinations), forKey: "Org2Workspace.aiChat.destinations.v1")
      defaults.set("off", forKey: "Org2Workspace.aiChat.messageSound.v1")
      defaults.set(false, forKey: "Org2Workspace.openClawLocalEditsEnabled.v1")
      let cli = Org2CLI(repoRoot: URL(fileURLWithPath: config.repoRoot), nodePath: config.nodePath)
      let store = WorkspaceStore(cli: cli, defaults: defaults, legacyDefaultsDomains: [])
      // Explicitly disable built-ins that were not selected in the server config.
      let enabledIDs = Set(config.destinations.filter(\.isEnabled).map(\.id))
      for var destination in store.aiChatDestinations where !enabledIDs.contains(destination.id) {
        destination.isEnabled = false
        store.updateAIChatDestination(destination)
      }
      await store.bootstrapHeadless(
        corpusRoot: URL(fileURLWithPath: config.corpusRoot),
        hostRef: config.hostRef,
        destinations: config.destinations
      )
      let remote = MobileRemoteCoordinator(
        defaults: defaults, credentialNamespace: namespace,
        credentialFile: stateDirectory.appendingPathComponent("paired-devices-\(config.hostRef).json"), serverName: config.name,
        hostRef: config.hostRef, port: config.port
      )
      remote.attach(to: store)
      remote.setBindHost(config.bindHost)
      remote.setEnabled(true)
      for _ in 0..<100 where !remote.isListening {
        try await Task.sleep(for: .milliseconds(100))
      }
      guard remote.isListening else {
        throw NSError(domain: "OpenOrgServer", code: 1, userInfo: [NSLocalizedDescriptionKey: remote.statusText])
      }
      store.setAutomationSchedulerActive(config.schedulesEnabled)
      emit(["event": "ready", "hostRef": config.hostRef, "endpoint": remote.endpoint ?? ""])

      for try await line in HeadlessControlInput.lines(descriptor: STDIN_FILENO) {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? String,
              let command = request["command"] as? String else { continue }
        var result: [String: Any]
        switch command {
        case "status":
          result = ["hostRef": config.hostRef, "name": config.name, "endpoint": remote.endpoint ?? "",
                    "listening": remote.isListening, "corpusRoot": config.corpusRoot,
                    "scheduler": store.automationSchedulerStatusText,
                    "schedulerError": store.automationSchedulerErrorText ?? "",
                    "threads": store.openClawChatThreads.count,
                    "runningThreads": store.openClawChatThreads.filter { store.isAIChatThreadRunning($0.id) }.count,
                    "pushConfigured": remote.pushProviderConfigured,
                    "devices": remote.pairedDevices.map { ["id": $0.id.uuidString, "name": $0.name] }]
        case "pair":
          remote.generatePairingCode()
          result = ["endpoint": remote.endpoint ?? "", "code": remote.pairingCode ?? "",
                    "pairingURL": remote.pairingPayload ?? "", "expiresInSeconds": 600]
        case "revoke":
          if let deviceID = request["deviceID"] as? String,
             let device = remote.pairedDevices.first(where: { $0.id.uuidString.lowercased() == deviceID.lowercased() }) {
            remote.revoke(device)
            result = ["revoked": !remote.pairedDevices.contains(where: { $0.id == device.id })]
          } else { result = ["error": "Paired device not found"] }
        case "push-config":
          if let teamID = request["teamID"] as? String, let keyID = request["keyID"] as? String,
             let privateKey = request["privateKey"] as? String {
            if remote.importPushPrivateKey(Data(privateKey.utf8)) {
              remote.setPushTeamID(teamID)
              remote.setPushKeyID(keyID)
              result = remote.pushProviderConfigured ? ["configured": true] : ["error": remote.pushStatusText]
            } else { result = ["error": remote.pushStatusText] }
          } else { result = ["error": "Missing APNs configuration"] }
        case "stop":
          store.setAutomationSchedulerActive(false)
          remote.setEnabled(false)
          store.setWorkspaceRealtimeRefreshActive(false)
          let saved = await store.prepareForTermination()
          emit(["id": id, "result": ["stopped": saved]])
          Foundation.exit(saved ? 0 : 1)
        default:
          result = ["error": "Unknown server control command"]
        }
        emit(["id": id, "result": result])
      }
      // Losing the supervisor closes stdin. Persist interruption state before exit.
      store.setAutomationSchedulerActive(false)
      remote.setEnabled(false)
      _ = await store.prepareForTermination()
    } catch {
      FileHandle.standardError.write(Data("OpenOrg server: \(error.localizedDescription)\n".utf8))
      Foundation.exit(1)
    }
  }

  private static func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data + Data([10]))
  }
}
