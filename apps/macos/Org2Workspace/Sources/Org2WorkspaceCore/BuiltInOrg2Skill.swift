import Foundation

enum BuiltInOrg2Skill {
  static let relativePath = "skills/org2/SKILL.md"
  static let corpusRelativePath = ".agents/skills/org2/SKILL.md"

  nonisolated static func sourceURL(
    filePath: String = #filePath,
    bundleResourceURL: URL? = Bundle.main.resourceURL
  ) throws -> URL {
    let repoRoot = try Org2CLI.defaultRepoRoot(
      filePath: filePath,
      bundleResourceURL: bundleResourceURL
    )
    let source = repoRoot.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
    }
    return source
  }

  nonisolated static func availableSourceURL() -> URL? {
    try? sourceURL()
  }

  @discardableResult
  nonisolated static func installIfAbsent(
    in corpusRoot: URL,
    sourceURL: URL? = nil
  ) throws -> URL {
    let source = try sourceURL ?? self.sourceURL()
    let destination = corpusRoot.appendingPathComponent(corpusRelativePath)
    if FileManager.default.fileExists(atPath: destination.path) {
      return destination
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    do {
      try FileManager.default.copyItem(at: source, to: destination)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      // A concurrently created or user-managed copy always wins.
    }
    return destination
  }
}
