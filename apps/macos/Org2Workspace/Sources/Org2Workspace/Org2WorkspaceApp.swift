import AppKit
import Carbon
import Org2WorkspaceCore
import SwiftUI

@main
struct Org2WorkspaceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = WorkspaceStore()
  private let globalCaptureHotKey = GlobalCaptureHotKey()

  init() {
    AppIconInstaller.install()

    if CommandLine.arguments.contains("--smoke-test") {
      SmokeTest.run()
    }

    if CommandLine.arguments.contains("--quit-after-launch") {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
        exit(0)
      }
    }
  }

  var body: some Scene {
    WindowGroup("Org2 Workspace") {
      ContentView()
        .environmentObject(store)
        .frame(minWidth: 1080, minHeight: 680)
        .onAppear {
          NSApplication.shared.setActivationPolicy(.regular)
          NSApplication.shared.activate(ignoringOtherApps: true)
          AppIconInstaller.install()
          let status = globalCaptureHotKey.register {
            NSApplication.shared.activate(ignoringOtherApps: true)
            store.presentCapturePanel()
          }
          if status != noErr {
            store.statusText = "Global capture shortcut unavailable (\(status))"
          }
        }
        .task {
          await store.bootstrap()
        }
    }
    .commands {
      CommandGroup(replacing: .undoRedo) {
        Button("Undo") {
          store.performUndoCommand()
        }
        .keyboardShortcut("z", modifiers: [.command])

        Button("Redo") {
          store.performRedoCommand()
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
      }

      CommandGroup(after: .newItem) {
        Button("Open Corpus...") {
          store.chooseCorpus()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Button("Refresh") {
          Task { await store.refreshWorkspace() }
        }
        .keyboardShortcut("r", modifiers: [.command])

        Button("Quick Open...") {
          store.presentQuickOpen()
        }
        .keyboardShortcut("p", modifiers: [.command])

        Button("Capture...") {
          store.presentCapturePanel()
        }
        .keyboardShortcut(.return, modifiers: [.command, .control])
        .disabled(store.corpusRoot == nil)

        Button(store.isRecordingMeeting ? "Stop Meeting Recording" : "Record Meeting") {
          if store.isRecordingMeeting {
            Task { await store.stopMeetingRecording() }
          } else {
            store.promptAndStartMeetingRecording()
          }
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(store.corpusRoot == nil || store.isProcessingMeeting)

        Button("Import Meeting Audio...") {
          store.promptAndImportMeetingAudio()
        }
        .disabled(store.corpusRoot == nil || store.isRecordingMeeting || store.isProcessingMeeting)

        Button("Save") {
          Task { await store.saveActiveEdit() }
        }
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(!store.canSaveCurrentFile)
      }

      CommandMenu("Pane") {
        Button("Make Current Pane Primary") {
          store.makeSelectedSurfacePrimary()
        }
        .keyboardShortcut("p", modifiers: [.command, .option])

        Button(store.expandedWorkspaceSurface == store.selectedSurface ? "Restore Current Pane" : "Expand Current Pane") {
          store.toggleSelectedSurfaceExpansion()
        }
        .keyboardShortcut("f", modifiers: [.command, .option])

        Button("Close Current Pane") {
          store.closeSelectedSurfacePane()
        }
        .keyboardShortcut("w", modifiers: [.command, .option])
      }

      CommandMenu("Block") {
        Button("Select Previous Block") {
          store.selectAdjacentBlock(.up)
        }
        .disabled(!store.canSelectAdjacentBlock(.up))

        Button("Select Next Block") {
          store.selectAdjacentBlock(.down)
        }
        .disabled(!store.canSelectAdjacentBlock(.down))

        Divider()

        Button("Edit Selected Block") {
          store.beginEditingSelectedBlock()
        }
        .disabled(!store.hasSelectedBlock)

        Divider()

        Button("Insert Text After") {
          Task { await store.insertBlockAfterSelected(.paragraph) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Heading After") {
          Task { await store.insertBlockAfterSelected(.heading) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert TODO After") {
          Task { await store.insertBlockAfterSelected(.todo) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Table After") {
          Task { await store.insertBlockAfterSelected(.table) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Image After") {
          Task { await store.insertBlockAfterSelected(.image) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Video After") {
          Task { await store.insertBlockAfterSelected(.video) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Properties After") {
          Task { await store.insertBlockAfterSelected(.properties) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Quote After") {
          Task { await store.insertBlockAfterSelected(.quote) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Source After") {
          Task { await store.insertBlockAfterSelected(.source) }
        }
        .disabled(!store.hasSelectedBlock)

        Divider()

        Button("Move Block Up") {
          Task { await store.moveSelectedBlock(.up) }
        }
        .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
        .disabled(!store.canMoveSelectedBlock(.up))

        Button("Move Block Down") {
          Task { await store.moveSelectedBlock(.down) }
        }
        .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
        .disabled(!store.canMoveSelectedBlock(.down))

        Divider()

        Button("Duplicate Block") {
          Task { await store.duplicateSelectedBlock() }
        }
        .keyboardShortcut("d", modifiers: [.command])
        .disabled(!store.hasSelectedBlock)

        Button("Delete Block") {
          Task { await store.deleteSelectedBlock() }
        }
        .disabled(!store.hasSelectedBlock)
      }

      CommandMenu("Encryption") {
        Button("Decrypt Subtree") {
          Task { await store.runOrgCrypt(.decrypt) }
        }
        .disabled(store.selectedLocation == nil)

        Button("Encrypt Subtree") {
          Task { await store.runOrgCrypt(.encrypt) }
        }
        .disabled(store.selectedLocation == nil)

        Button("Re-encrypt Subtree") {
          Task { await store.runOrgCrypt(.reencrypt) }
        }
        .disabled(store.selectedLocation == nil)

        Divider()

        Button("Encryption Settings...") {
          store.presentOrgCryptConfiguration()
        }
      }
    }
  }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    AppIconInstaller.install()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    AppIconInstaller.install()
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard !flag else { return true }
    sender.setActivationPolicy(.regular)
    sender.activate(ignoringOtherApps: true)
    if !sender.sendAction(Selector(("newWindow:")), to: nil, from: nil) {
      sender.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
    }
    return true
  }
}

private enum AppIconInstaller {
  @MainActor
  static func install() {
    let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png")
      ?? Bundle.main.url(forResource: "AppIcon", withExtension: "png")
    guard let url,
          let image = NSImage(contentsOf: url)
    else {
      return
    }

    image.isTemplate = false
    NSApplication.shared.applicationIconImage = image
    NSApplication.shared.dockTile.display()
  }
}

private enum SmokeTest {
  static func run() -> Never {
    do {
      let repoRoot = try Org2CLI.defaultRepoRoot()
      let cli = Org2CLI(repoRoot: repoRoot)
      let fixture = try makeFixture()

      let agenda: AgendaPayload = try cli.runJSONSync([
        "agenda",
        "--dir", fixture.path,
        "--recursive",
        "--from", "2026-06-12",
        "--to", "2026-06-18",
        "--format", "json"
      ])

      let search: SearchPayload = try cli.runJSONSync([
        "search", "workspace",
        "--dir", fixture.path,
        "--recursive",
        "--limit", "5",
        "--format", "json"
      ])

      let backlinks: BacklinksPayload = try cli.runJSONSync([
        "backlinks",
        "--id", "11111111-1111-4111-8111-111111111111",
        "--dir", fixture.path,
        "--recursive",
        "--format", "json"
      ])

      let todo: TodoMutationPayload = try cli.runJSONSync([
        "todo", "set",
        "--file", fixture.appendingPathComponent("project.org2").path,
        "--line", "7",
        "--status", "in_progress",
        "--format", "json",
        "--apply"
      ])

      let plan: PlanMutationPayload = try cli.runJSONSync([
        "plan", "set",
        "--file", fixture.appendingPathComponent("project.org2").path,
        "--line", "7",
        "--kind", "deadline",
        "--date", "2026-06-15",
        "--format", "json",
        "--apply"
      ])

      guard agenda.totalItemCount > 0 else { throw SmokeFailure("agenda returned no items") }
      guard !search.results.isEmpty else { throw SmokeFailure("search returned no results") }
      guard !backlinks.backlinks.isEmpty else { throw SmokeFailure("backlinks returned no results") }
      guard todo.newStatus == "in_progress" else { throw SmokeFailure("todo mutation did not apply") }
      guard plan.kind == "DEADLINE" && plan.date == "2026-06-15" else { throw SmokeFailure("plan mutation did not apply") }

      FileHandle.standardOutput.write(Data("Org2Workspace smoke test passed\n".utf8))
      exit(0)
    } catch {
      FileHandle.standardError.write(Data("Org2Workspace smoke test failed: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  private static func makeFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let project = """
    #+TITLE: Workspace Fixture

    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :END:

    * TODO Review workspace cockpit
    :PROPERTIES:
    :ID: 22222222-2222-4222-8222-222222222222
    :END:
    SCHEDULED: <2026-06-12 Fri 09:00>
    Keep this safe fixture small.
    """

    let thread = """
    #+TITLE: Thread Fixture

    * TODO Follow up from command center
    SCHEDULED: <2026-06-13 Sat>
    Links to [[id:11111111-1111-4111-8111-111111111111][Workspace Fixture]].
    """

    try project.write(to: root.appendingPathComponent("project.org2"), atomically: true, encoding: .utf8)
    try thread.write(to: root.appendingPathComponent("thread.org2"), atomically: true, encoding: .utf8)
    return root
  }

  private struct SmokeFailure: LocalizedError {
    let message: String

    init(_ message: String) {
      self.message = message
    }

    var errorDescription: String? { message }
  }
}
