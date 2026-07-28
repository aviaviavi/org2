import Foundation
import XCTest

final class WorkspaceListSelectionTests: XCTestCase {
  func testMainWorkspaceAvoidsUnreadableNativeListSelection() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcesRoot = packageRoot.appendingPathComponent("Sources", isDirectory: true)
    let nativeSelection = try NSRegularExpression(
      pattern: #"\bList\s*\(\s*selection\s*:"#,
      options: []
    )
    let sourceFiles = try XCTUnwrap(
      FileManager.default.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: nil
      )?.allObjects as? [URL]
    )
    var offenders: [String] = []
    for sourceFile in sourceFiles where sourceFile.pathExtension == "swift" {
      let source = try String(contentsOf: sourceFile, encoding: .utf8)
      if nativeSelection.firstMatch(
        in: source,
        options: [],
        range: NSRange(source.startIndex..., in: source)
      ) != nil {
        offenders.append(sourceFile.path.replacingOccurrences(of: packageRoot.path + "/", with: ""))
      }
    }

    XCTAssertTrue(
      offenders.isEmpty,
      "Use readable explicit selection instead of native List selection highlighting: \(offenders.joined(separator: ", "))"
    )
  }
}
