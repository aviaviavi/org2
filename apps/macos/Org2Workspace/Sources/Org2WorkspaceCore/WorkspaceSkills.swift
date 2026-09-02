import Foundation

public struct WorkspaceSkillItem: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let description: String
  public let sourcePath: String
  public let isUserInvocable: Bool
  public let validationMessage: String?

  public var invocation: String? {
    isUserInvocable ? "/\(name)" : nil
  }
}

enum WorkspaceSkillCatalog {
  /// Returns only procedures authored for the workspace. The reserved Org2
  /// operating skill is installed for external agents, while OpenOrg supplies
  /// its equivalent guidance as ambient chat context.
  nonisolated static func discover(in corpusRoot: URL) -> [WorkspaceSkillItem] {
    let skillsRoot = corpusRoot
      .appendingPathComponent(".agents", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
    let directories = (try? FileManager.default.contentsOfDirectory(
      at: skillsRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []

    return directories
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
      .compactMap { directory -> WorkspaceSkillItem? in
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
          return nil
        }
        guard let item = item(
          at: directory.appendingPathComponent("SKILL.md"),
          fallbackName: directory.lastPathComponent
        ), item.name != "org2" else { return nil }
        return item
      }
  }

  private nonisolated static func item(
    at url: URL,
    fallbackName: String
  ) -> WorkspaceSkillItem? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
      return WorkspaceSkillItem(
        id: url.standardizedFileURL.path,
        name: fallbackName,
        description: "This skill could not be read.",
        sourcePath: url.standardizedFileURL.path,
        isUserInvocable: false,
        validationMessage: "SKILL.md is not readable"
      )
    }
    guard let frontMatter = CorpusAgentSkillCatalog.frontMatter(from: source) else {
      return WorkspaceSkillItem(
        id: url.standardizedFileURL.path,
        name: fallbackName,
        description: "This skill does not have valid front matter.",
        sourcePath: url.standardizedFileURL.path,
        isUserInvocable: false,
        validationMessage: "Missing or invalid YAML front matter"
      )
    }
    let name = CorpusAgentSkillCatalog.normalizedCommandName(
      frontMatter["name"] ?? fallbackName
    )
    guard !name.isEmpty else {
      return WorkspaceSkillItem(
        id: url.standardizedFileURL.path,
        name: fallbackName,
        description: "This skill has an invalid name.",
        sourcePath: url.standardizedFileURL.path,
        isUserInvocable: false,
        validationMessage: "Skill names may contain lowercase letters, digits, and hyphens"
      )
    }
    let declaredDescription = frontMatter["description"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return WorkspaceSkillItem(
      id: url.standardizedFileURL.path,
      name: name,
      description: declaredDescription?.isEmpty == false
        ? declaredDescription ?? ""
        : "Use the \(name) workspace skill.",
      sourcePath: url.standardizedFileURL.path,
      isUserInvocable: frontMatter["user-invocable"]?.lowercased() != "false",
      validationMessage: nil
    )
  }

  nonisolated static func normalizedSkillName(_ rawValue: String) -> String {
    CorpusAgentSkillCatalog.normalizedCommandName(rawValue)
  }

  nonisolated static func newSkillSource(name: String, description: String) -> String {
    let summary = description.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
    ---
    name: \(name)
    description: \(summary)
    user-invocable: true
    ---

    # \(name)

    Describe when this skill applies and the procedure an agent should follow.
    """ + "\n"
  }
}
