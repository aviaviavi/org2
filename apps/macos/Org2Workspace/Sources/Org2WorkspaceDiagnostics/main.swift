import Foundation
import Org2WorkspaceDiagnosticsCore

@main
struct Org2WorkspaceDiagnosticsMain {
  static func main() {
    do {
      let options = try WorkspaceDiagnosticsOptions.parse(Array(CommandLine.arguments.dropFirst()))
      let corpusPath = try resolveCorpusPath(options: options)
      let corpus = try WorkspaceDiagnosticsCorpus.load(at: URL(fileURLWithPath: corpusPath))
      let monitor = WorkspaceDiagnosticsMonitor(options: options, corpus: corpus)
      monitor.run()
    } catch WorkspaceDiagnosticsError.helpRequested {
      print(WorkspaceDiagnosticsOptions.usage)
    } catch {
      FileHandle.standardError.write(Data("Org2WorkspaceDiagnostics: \(error.localizedDescription)\n\n\(WorkspaceDiagnosticsOptions.usage)\n".utf8))
      exit(2)
    }
  }

  private static func resolveCorpusPath(options: WorkspaceDiagnosticsOptions) throws -> String {
    if let explicit = options.corpusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
       !explicit.isEmpty {
      return NSString(string: explicit).expandingTildeInPath
    }
    if let environmentPath = ProcessInfo.processInfo.environment["ORG2_WORKSPACE_DIAGNOSTICS_CORPUS"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
       !environmentPath.isEmpty {
      return NSString(string: environmentPath).expandingTildeInPath
    }
    if let defaults = UserDefaults(suiteName: options.bundleIdentifier),
       let remembered = defaults.string(forKey: "Org2Workspace.corpusRoot")?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !remembered.isEmpty {
      return NSString(string: remembered).expandingTildeInPath
    }
    throw WorkspaceDiagnosticsError.invalidCorpus(
      "No corpus was supplied and \(options.bundleIdentifier) has no remembered corpus. Pass --corpus PATH."
    )
  }
}
