import Combine
import Sparkle
import SwiftUI

@MainActor
final class SoftwareUpdateController: ObservableObject {
  let updaterController: SPUStandardUpdaterController

  @Published private(set) var isAvailable: Bool
  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var automaticallyChecksForUpdates = false
  @Published private(set) var automaticallyDownloadsUpdates = false
  @Published private(set) var lastUpdateCheckDate: Date?

  private var performedLaunchCheck = false

  init() {
    let bundle = Bundle.main
    let configured = bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
      && bundle.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    let controller = SPUStandardUpdaterController(
      startingUpdater: configured,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    updaterController = controller
    isAvailable = configured

    let updater = controller.updater
    updater.publisher(for: \.canCheckForUpdates)
      .receive(on: RunLoop.main)
      .assign(to: &$canCheckForUpdates)
    updater.publisher(for: \.automaticallyChecksForUpdates)
      .receive(on: RunLoop.main)
      .assign(to: &$automaticallyChecksForUpdates)
    updater.publisher(for: \.automaticallyDownloadsUpdates)
      .receive(on: RunLoop.main)
      .assign(to: &$automaticallyDownloadsUpdates)
    updater.publisher(for: \.lastUpdateCheckDate)
      .receive(on: RunLoop.main)
      .assign(to: &$lastUpdateCheckDate)
  }

  func checkAtLaunchIfEnabled() {
    guard !performedLaunchCheck else { return }
    performedLaunchCheck = true
    guard isAvailable, updaterController.updater.automaticallyChecksForUpdates else { return }
    updaterController.updater.checkForUpdatesInBackground()
  }

  func checkForUpdates() {
    updaterController.updater.checkForUpdates()
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    updaterController.updater.automaticallyChecksForUpdates = enabled
  }

  func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
    updaterController.updater.automaticallyDownloadsUpdates = enabled
  }
}

struct CheckForUpdatesCommand: View {
  @ObservedObject var softwareUpdates: SoftwareUpdateController

  var body: some View {
    Button("Check for Updates…") {
      softwareUpdates.checkForUpdates()
    }
    .disabled(!softwareUpdates.isAvailable || !softwareUpdates.canCheckForUpdates)
  }
}

struct SoftwareUpdateSettingsView: View {
  @ObservedObject var softwareUpdates: SoftwareUpdateController

  private var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("Installed version", value: currentVersion)

        Toggle(
          "Automatically check for updates",
          isOn: Binding(
            get: { softwareUpdates.automaticallyChecksForUpdates },
            set: { softwareUpdates.setAutomaticallyChecksForUpdates($0) }
          )
        )
        .disabled(!softwareUpdates.isAvailable)

        Toggle(
          "Download updates automatically and install on quit",
          isOn: Binding(
            get: { softwareUpdates.automaticallyDownloadsUpdates },
            set: { softwareUpdates.setAutomaticallyDownloadsUpdates($0) }
          )
        )
        .disabled(!softwareUpdates.isAvailable || !softwareUpdates.automaticallyChecksForUpdates)

        Text(softwareUpdates.isAvailable
          ? "When enabled, OpenOrg checks quietly at launch and every two hours. You can install immediately, install a downloaded update when you quit, be reminded later, or skip a version."
          : "Automatic updates are available in signed OpenOrg releases.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Software Updates", systemImage: "arrow.triangle.2.circlepath")
      }

      Section {
        HStack {
          if let lastCheck = softwareUpdates.lastUpdateCheckDate {
            Text("Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
              .foregroundStyle(.secondary)
          } else {
            Text("No update check has completed yet")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Check Now") {
            softwareUpdates.checkForUpdates()
          }
          .disabled(!softwareUpdates.isAvailable || !softwareUpdates.canCheckForUpdates)
        }
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 560)
    .frame(minHeight: 460)
  }
}
