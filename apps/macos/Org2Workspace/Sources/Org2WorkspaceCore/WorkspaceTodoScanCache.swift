import Darwin
import Foundation

/// Disposable, per-store native scan fragments shared by assigned-work and
/// similar-TODO views. Source files remain authoritative on every query.
actor WorkspaceTodoScanCache {
  private struct Entry {
    let signature: [Int64]
    let headings: [SimilarTodoCandidate]
  }
  private var entries: [String: Entry] = [:]
  private(set) var lastParsedFileCount = 0

  func clear() { entries.removeAll() }

  func scan(files: [CorpusFile]) throws -> [SimilarTodoCandidate] {
    let paths = Set(files.map(\.path))
    entries = entries.filter { paths.contains($0.key) }
    lastParsedFileCount = 0
    var result: [SimilarTodoCandidate] = []
    for file in files {
      try Task.checkCancellation()
      guard ["org", "org2"].contains(URL(fileURLWithPath: file.path).pathExtension.lowercased()) else { continue }
      guard let before = signature(file.path) else {
        entries.removeValue(forKey: file.path)
        continue
      }
      if let entry = entries[file.path], entry.signature == before {
        result.append(contentsOf: entry.headings)
        continue
      }
      let headings = try WorkspaceStore.scanTodoHeadings(files: [file])
      lastParsedFileCount += 1
      // Do not cache a read that raced an external edit or atomic replacement.
      if signature(file.path) == before {
        entries[file.path] = Entry(signature: before, headings: headings)
      } else {
        entries.removeValue(forKey: file.path)
      }
      result.append(contentsOf: headings)
    }
    return result
  }

  private func signature(_ path: String) -> [Int64]? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    // ctime and inode also catch same-size edits with restored mtime and
    // atomic replacements; the displayed file catalog's timestamp is not used.
    return [Int64(info.st_dev), Int64(bitPattern: info.st_ino), info.st_size,
      Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
      Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
  }
}
