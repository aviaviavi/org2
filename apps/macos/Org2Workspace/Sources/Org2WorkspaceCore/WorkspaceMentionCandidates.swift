import Foundation

/// Corpus file candidates for an `@` mention. AI chat and the document
/// editors share this so that typing `@` finds the same files in both.
enum WorkspaceMentionCandidates {
  /// Total suggestions shown for one `@` mention.
  static let defaultLimit = 10

  /// Whether `query` (the text after `@`) can name a corpus file: letters,
  /// digits, `-`, and `_`, as in an AI chat `@mention`. Spaces end the file
  /// query so prose after an `@word` does not keep a file list open.
  static func isFileQuery(_ query: String) -> Bool {
    query.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
  }

  /// Files for `query`, ranked by the workspace fuzzy file search. An empty
  /// query lists files in corpus order. Paths in `excludingPaths`, such as
  /// daily notes already offered for a date, are skipped before the limit.
  static func corpusFiles(
    matching query: String,
    in files: [CorpusFile],
    excludingPaths: Set<String> = [],
    limit: Int
  ) -> [CorpusFile] {
    guard limit > 0, isFileQuery(query) else { return [] }
    let candidates = excludingPaths.isEmpty ? files : files.filter { !excludingPaths.contains($0.path) }
    if query.isEmpty {
      return Array(candidates.prefix(limit))
    }
    return WorkspaceStore.searchCorpusFilesForWorkspace(candidates, query: query, limit: limit)
  }
}
