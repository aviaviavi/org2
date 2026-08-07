import AppKit
import Foundation

enum WorkspaceSound {
  nonisolated static var isPlaybackSuppressed: Bool {
    NSClassFromString("XCTestCase") != nil
  }

  @MainActor
  static func play(named name: NSSound.Name) {
    guard !isPlaybackSuppressed else { return }
    NSSound(named: name)?.play()
  }

  @MainActor
  static func beep() {
    guard !isPlaybackSuppressed else { return }
    NSSound.beep()
  }
}
