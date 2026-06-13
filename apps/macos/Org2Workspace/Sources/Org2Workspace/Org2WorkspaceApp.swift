import AppKit
import Org2WorkspaceCore
import SwiftUI

@main
struct Org2WorkspaceApp: App {
  @StateObject private var store = WorkspaceStore()

  init() {
    Self.installApplicationIcon()

    if CommandLine.arguments.contains("--smoke-test") {
      SmokeTest.run()
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
        }
        .task {
          await store.bootstrap()
          if CommandLine.arguments.contains("--quit-after-launch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
              NSApplication.shared.terminate(nil)
            }
          }
        }
    }
    .commands {
      CommandGroup(after: .newItem) {
        Button("Open Corpus...") {
          store.chooseCorpus()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Button("Refresh") {
          Task { await store.refreshWorkspace() }
        }
        .keyboardShortcut("r", modifiers: [.command])

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

        Button("Save Entry") {
          Task { await store.saveEditedEntry() }
        }
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(!store.isEditingEntry || store.isSavingEntry)
      }
    }
  }

  private static func installApplicationIcon() {
    guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
          let image = NSImage(contentsOf: url)
    else {
      return
    }

    image.isTemplate = false
    NSApplication.shared.applicationIconImage = image
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
