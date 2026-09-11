import Foundation

// Serialized saves prevent an older refresh from replacing a newer disk cache.
// All JSON encoding and filesystem work happens outside the UI actor.
actor MobileCorpusCacheWriter {
  private var latestGeneration = -1

  func save<Value: Encodable & Sendable>(_ snapshot: Value, to url: URL, generation: Int) {
    guard generation >= latestGeneration else { return }
    latestGeneration = generation
    do {
      let data = try JSONEncoder().encode(snapshot)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    } catch {
      // A disposable cache failing to save must not interrupt the live corpus.
    }
  }
}
