import Foundation

/// Applies filesystem deltas to the already-sorted corpus projection without
/// rebuilding a dictionary and sorting the entire corpus on the main actor.
///
/// The caller can run this value-only work on a detached task, then publish the
/// resulting snapshot once. `changedPaths` must include deleted paths as well
/// as paths represented by `refreshedFiles`.
enum CorpusFileCatalog {
  /// Immutable, corpus-scale state consumed by WorkspaceStore. Building this
  /// projection performs all hashing and quick-open normalization away from
  /// the main actor; publishing it is a handful of copy-on-write assignments.
  struct Projection: Sendable {
    let filesByPath: [String: CorpusFile]
    let filesByRelativePath: [String: CorpusFile]
    let indexedFiles: [QuickOpenIndexedFile]

    static let empty = Projection(
      filesByPath: [:],
      filesByRelativePath: [:],
      indexedFiles: []
    )
  }

  struct Update: Equatable, Sendable {
    let files: [CorpusFile]
    let didChange: Bool
  }

  static func projection(for files: [CorpusFile]) -> Projection {
    var filesByPath: [String: CorpusFile] = [:]
    filesByPath.reserveCapacity(files.count)
    var filesByRelativePath: [String: CorpusFile] = [:]
    filesByRelativePath.reserveCapacity(files.count)
    var indexedFiles: [QuickOpenIndexedFile] = []
    indexedFiles.reserveCapacity(files.count)

    for file in files {
      filesByPath[file.path] = file
      filesByRelativePath[file.relativePath] = file
      indexedFiles.append(
        QuickOpenIndexedFile(
          file: file,
          normalizedRelativePath: file.relativePath.lowercased()
        )
      )
    }

    return Projection(
      filesByPath: filesByPath,
      filesByRelativePath: filesByRelativePath,
      indexedFiles: indexedFiles
    )
  }

  static func applying(
    changedPaths: Set<String>,
    refreshedFiles: [CorpusFile],
    to currentFiles: [CorpusFile]
  ) -> Update {
    guard !changedPaths.isEmpty else {
      return Update(files: currentFiles, didChange: false)
    }

    let retained = currentFiles.filter { !changedPaths.contains($0.path) }
    var refreshedByPath: [String: CorpusFile] = [:]
    refreshedByPath.reserveCapacity(refreshedFiles.count)
    for file in refreshedFiles where changedPaths.contains(file.path) {
      refreshedByPath[file.path] = file
    }
    let additions = refreshedByPath.values.sorted(by: areInDisplayOrder)
    let merged = mergeSorted(retained, additions)
    let didChange = merged != currentFiles
    return Update(
      files: didChange ? merged : currentFiles,
      didChange: didChange
    )
  }

  static func areInDisplayOrder(_ left: CorpusFile, _ right: CorpusFile) -> Bool {
    let relativeComparison = left.relativePath.localizedStandardCompare(right.relativePath)
    if relativeComparison != .orderedSame {
      return relativeComparison == .orderedAscending
    }
    return left.path < right.path
  }

  private static func mergeSorted(_ left: [CorpusFile], _ right: [CorpusFile]) -> [CorpusFile] {
    var result: [CorpusFile] = []
    result.reserveCapacity(left.count + right.count)
    var leftIndex = 0
    var rightIndex = 0

    while leftIndex < left.count, rightIndex < right.count {
      if areInDisplayOrder(right[rightIndex], left[leftIndex]) {
        result.append(right[rightIndex])
        rightIndex += 1
      } else {
        result.append(left[leftIndex])
        leftIndex += 1
      }
    }
    if leftIndex < left.count {
      result.append(contentsOf: left[leftIndex...])
    }
    if rightIndex < right.count {
      result.append(contentsOf: right[rightIndex...])
    }
    return result
  }
}
