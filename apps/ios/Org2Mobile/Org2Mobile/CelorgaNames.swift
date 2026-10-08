import Foundation

/// The subset of the macOS app's `CelorgaNames` that the mobile client needs.
///
/// Phase 1 of the rename (see docs/rename/celorga.org): readers accept both
/// spellings, preferring Celorga; writers keep the legacy `ORG2_`, `org2.json`
/// and `.org2/` names so devices still on 0.8.x keep working.
enum CelorgaNames {
  static let propertyPrefix = "CELORGA_"
  static let legacyPropertyPrefix = "ORG2_"
  static let configFileNames = ["celorga.json", "org2.json"]
  static let stateDirectoryName = ".celorga"
  static let legacyStateDirectoryName = ".org2"

  /// Both spellings of a property or environment name, Celorga first.
  static func aliases(_ name: String) -> [String] {
    if name.hasPrefix(legacyPropertyPrefix) {
      return [propertyPrefix + name.dropFirst(legacyPropertyPrefix.count), name]
    }
    if name.hasPrefix(propertyPrefix) {
      return [name, legacyPropertyPrefix + name.dropFirst(propertyPrefix.count)]
    }
    return [name]
  }

  /// Expands candidate names so each branded name is tried as `CELORGA_X`, then `ORG2_X`.
  static func withAliases(_ names: [String]) -> [String] {
    var result: [String] = []
    for name in names {
      for alias in aliases(name) where !result.contains(alias) {
        result.append(alias)
      }
    }
    return result
  }

  /// Reads a branded environment variable, preferring `CELORGA_X` over `ORG2_X`.
  static func environment(
    _ name: String,
    in environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    for alias in aliases(name) {
      if let value = environment[alias], !value.isEmpty { return value }
    }
    return nil
  }

  /// The workspace config file in a directory: `celorga.json` if present, else `org2.json` if present.
  static func configFile(in directory: URL, fileManager: FileManager = .default) -> URL? {
    for name in configFileNames {
      let candidate = directory.appendingPathComponent(name, isDirectory: false)
      if fileManager.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  /// The corpus state directory name: `.celorga` once it exists, otherwise `.org2`.
  static func stateDirectoryName(corpusRoot: URL, fileManager: FileManager = .default) -> String {
    var isDirectory: ObjCBool = false
    let modern = corpusRoot.appendingPathComponent(stateDirectoryName, isDirectory: true).path
    return fileManager.fileExists(atPath: modern, isDirectory: &isDirectory) && isDirectory.boolValue
      ? stateDirectoryName
      : legacyStateDirectoryName
  }
}
