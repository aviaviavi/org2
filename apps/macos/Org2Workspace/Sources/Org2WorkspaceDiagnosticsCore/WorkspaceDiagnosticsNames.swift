import Foundation

/// The subset of `CelorgaNames` (Org2WorkspaceCore) the diagnostics tool needs.
/// Readers accept both spellings, preferring Celorga; see docs/rename/celorga.org.
public enum WorkspaceDiagnosticsNames {
  static let configFileNames = ["celorga.json", "org2.json"]

  /// `celorga.json` or `org2.json` if present, else `celorga.json`.
  public static func configFile(in directory: URL, fileManager: FileManager = .default) -> URL {
    for name in configFileNames {
      let candidate = directory.appendingPathComponent(name)
      if fileManager.fileExists(atPath: candidate.path) { return candidate }
    }
    return directory.appendingPathComponent("celorga.json")
  }

  /// `celorga:kind:vN` and `org2:kind:vN` are the same record type.
  public static func schemaMatches(_ value: String, _ id: String) -> Bool {
    var suffix = Substring(id)
    for namespace in ["celorga:", "org2:"] where id.hasPrefix(namespace) {
      suffix = id.dropFirst(namespace.count)
    }
    return value == "celorga:\(suffix)" || value == "org2:\(suffix)"
  }

  /// Reads `CELORGA_X`, then `ORG2_X`.
  public static func environment(
    _ name: String,
    in environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    let suffix = name.hasPrefix("ORG2_") ? String(name.dropFirst(5))
      : name.hasPrefix("CELORGA_") ? String(name.dropFirst(8)) : nil
    guard let suffix else { return environment[name] }
    for key in ["CELORGA_" + suffix, "ORG2_" + suffix] {
      if let value = environment[key], !value.isEmpty { return value }
    }
    return nil
  }

  /// Copies each `CELORGA_X` to `ORG2_X` when the legacy name is unset or empty.
  public static func mirrorCelorgaEnvironment() {
    let environment = ProcessInfo.processInfo.environment
    for (key, value) in environment where key.hasPrefix("CELORGA_") {
      let legacy = "ORG2_" + key.dropFirst(8)
      if (environment[legacy] ?? "").isEmpty { setenv(legacy, value, 1) }
    }
  }
}
