import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class CorpusFileCatalogTests: XCTestCase {
  func testIncrementalChangesInsertUpdateAndDeleteWithoutReorderingTheCorpus() {
    let root = "/tmp/corpus"
    let current = [
      file(root: root, relativePath: "daily/2026-08-30.org", bytes: 10),
      file(root: root, relativePath: "notes/alpha.org", bytes: 20),
      file(root: root, relativePath: "notes/zulu.org", bytes: 30),
    ]
    let deleted = "\(root)/notes/alpha.org"
    let updated = file(root: root, relativePath: "notes/zulu.org", bytes: 31)
    let inserted = file(root: root, relativePath: "notes/bravo.org", bytes: 40)

    let update = CorpusFileCatalog.applying(
      changedPaths: [deleted, updated.path, inserted.path],
      refreshedFiles: [updated, inserted],
      to: current
    )

    XCTAssertTrue(update.didChange)
    XCTAssertEqual(update.files.map(\.relativePath), [
      "daily/2026-08-30.org",
      "notes/bravo.org",
      "notes/zulu.org",
    ])
    XCTAssertEqual(update.files.last?.byteCount, 31)
  }

  func testNoOpEventPreservesAnEquivalentSnapshot() {
    let existing = file(root: "/tmp/corpus", relativePath: "notes/stable.org", bytes: 20)
    let update = CorpusFileCatalog.applying(
      changedPaths: [existing.path],
      refreshedFiles: [existing],
      to: [existing]
    )
    XCTAssertFalse(update.didChange)
    XCTAssertEqual(update.files, [existing])
  }

  func testCorpusScaleBatchProducesAUniqueSortedSnapshot() {
    let root = "/tmp/corpus"
    let current = (0..<22_500).map { index in
      file(root: root, relativePath: String(format: "notes/%05d.org", index), bytes: Int64(index))
    }
    let changedIndexes = stride(from: 0, to: 10_000, by: 100)
    let changedPaths = Set(changedIndexes.map { current[$0].path })
    let refreshed = changedIndexes.map { index in
      file(root: root, relativePath: current[index].relativePath, bytes: Int64(index + 1))
    }

    let update = CorpusFileCatalog.applying(
      changedPaths: changedPaths,
      refreshedFiles: refreshed,
      to: current
    )
    let result = update.files

    XCTAssertTrue(update.didChange)
    XCTAssertEqual(result.count, current.count)
    XCTAssertEqual(Set(result.map(\.path)).count, current.count)
    XCTAssertTrue(zip(result, result.dropFirst()).allSatisfy { pair in
      CorpusFileCatalog.areInDisplayOrder(pair.0, pair.1)
    })
    XCTAssertEqual(result[100].byteCount, 101)
  }

  func testProjectionBuildsPathAndNormalizedQuickOpenIndexesTogether() {
    let files = [
      file(root: "/tmp/corpus", relativePath: "Notes/Alpha Project.org", bytes: 10),
      file(root: "/tmp/corpus", relativePath: "daily/2026-08-31.org", bytes: 20),
    ]

    let projection = CorpusFileCatalog.projection(for: files)

    XCTAssertEqual(projection.filesByPath[files[0].path], files[0])
    XCTAssertEqual(projection.filesByPath[files[1].path], files[1])
    XCTAssertEqual(
      projection.indexedFiles.map(\.normalizedRelativePath),
      ["notes/alpha project.org", "daily/2026-08-31.org"]
    )
  }

  func testProjectionPreparationHasLinearMultiSizeSlopeBudget() {
    let sizes = [2_000, 8_000, 32_000]
    let measurements = sizes.map { size -> UInt64 in
      let files = (0..<size).map { index in
        file(
          root: "/tmp/corpus",
          relativePath: String(format: "notes/team-%03d/topic-%07d.org", index % 127, index),
          bytes: Int64(index)
        )
      }
      // Warm Foundation's case-mapping and Dictionary allocation paths before
      // collecting the median used by the slope budget.
      _ = CorpusFileCatalog.projection(for: Array(files.prefix(min(256, size))))
      var samples: [UInt64] = []
      for _ in 0..<3 {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let projection = CorpusFileCatalog.projection(for: files)
        samples.append(DispatchTime.now().uptimeNanoseconds - startedAt)
        XCTAssertEqual(projection.indexedFiles.count, size)
      }
      return samples.sorted()[1]
    }

    let perFile = zip(measurements, sizes).map { Double($0.0) / Double($0.1) }
    XCTAssertLessThan(
      perFile[1],
      (perFile[0] * 3.0) + 2_000,
      "8k projection preparation exceeded the per-file slope budget"
    )
    XCTAssertLessThan(
      perFile[2],
      (perFile[1] * 3.0) + 2_000,
      "32k projection preparation exceeded the per-file slope budget"
    )
    XCTAssertLessThan(
      measurements[2],
      2_000_000_000,
      "32k projection preparation exceeded the absolute debug-build safety budget"
    )
  }

  private func file(root: String, relativePath: String, bytes: Int64) -> CorpusFile {
    CorpusFile(
      path: "\(root)/\(relativePath)",
      relativePath: relativePath,
      modifiedAt: Date(timeIntervalSince1970: TimeInterval(bytes)),
      byteCount: bytes
    )
  }
}
