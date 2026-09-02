import Foundation
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceSkillsTests: XCTestCase {
  func testCreateSkillWritesAnEditableWorkspaceSkillWithoutOverwriting() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-create-workspace-skill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "openorg-workspace-skills-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    store.setCorpusRoot(root, persistsDefault: false)

    XCTAssertTrue(store.createWorkspaceSkill(
      name: "weekly-review",
      description: "Prepare the weekly workspace review."
    ))
    await store.waitForCorpusAgentSkillRefreshForTesting()

    let destination = root.appendingPathComponent(".agents/skills/weekly-review/SKILL.md")
    let source = try String(contentsOf: destination, encoding: .utf8)
    XCTAssertTrue(source.contains("name: weekly-review"))
    XCTAssertTrue(source.contains("description: Prepare the weekly workspace review."))
    XCTAssertTrue(store.workspaceSkills.contains(where: { $0.name == "weekly-review" }))
    XCTAssertFalse(store.createWorkspaceSkill(
      name: "weekly-review",
      description: "Replacement instructions."
    ))
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), source)
    XCTAssertFalse(store.createWorkspaceSkill(
      name: "org2",
      description: "Replace the built-in operating guidance."
    ))
    XCTAssertEqual(store.statusText, "Reserved skill name")
  }

  func testCatalogShowsOnlyAuthoredWorkspaceSkills() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-workspace-skills-\(UUID().uuidString)", isDirectory: true)
    let workspaceSkill = root.appendingPathComponent(".agents/skills/review/SKILL.md")
    try FileManager.default.createDirectory(
      at: workspaceSkill.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    try """
    ---
    name: review
    description: Review a change carefully.
    user-invocable: false
    ---
    """.write(to: workspaceSkill, atomically: true, encoding: .utf8)
    let skills = WorkspaceSkillCatalog.discover(in: root)

    XCTAssertEqual(skills.map(\.name), ["review"])
    XCTAssertEqual(skills.first?.isUserInvocable, false)
  }

  func testCatalogHidesReservedOrg2InfrastructureSkill() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-workspace-skill-shadow-\(UUID().uuidString)", isDirectory: true)
    let workspaceSkill = root.appendingPathComponent(".agents/skills/org2/SKILL.md")
    try FileManager.default.createDirectory(
      at: workspaceSkill.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let source = """
    ---
    name: org2
    description: Org2 procedure.
    ---
    """
    try source.write(to: workspaceSkill, atomically: true, encoding: .utf8)

    let skills = WorkspaceSkillCatalog.discover(in: root)

    XCTAssertTrue(skills.isEmpty)
  }

  func testCatalogKeepsInvalidSkillVisibleForRepair() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-invalid-workspace-skill-\(UUID().uuidString)", isDirectory: true)
    let skill = root.appendingPathComponent(".agents/skills/broken/SKILL.md")
    try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "No front matter\n".write(to: skill, atomically: true, encoding: .utf8)

    let skills = WorkspaceSkillCatalog.discover(in: root)

    XCTAssertEqual(skills.count, 1)
    XCTAssertEqual(skills[0].name, "broken")
    XCTAssertNotNil(skills[0].validationMessage)
  }
}
