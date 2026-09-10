import Foundation

@main
struct SearchRegression {
  static func check(_ condition: Bool, _ message: String = "Search assertion failed", line: Int = #line) {
    if !condition {
      FileHandle.standardError.write(Data("\(message) at line \(line)\n".utf8))
      exit(1)
    }
  }
  static func main() throws {
    let entries = [
      MobileSearchEntry(path: "notes/recipes.org2", title: "Recipes", parent: "", line: 0, nodeID: "", body: ""),
      MobileSearchEntry(path: "notes/recipes.org2", title: "Breakfast", parent: "Recipes", line: 2, nodeID: "", body: "We discussed pour over yesterday."),
      MobileSearchEntry(path: "notes/recipes.org2", title: "Pour over", parent: "Recipes", line: 4, nodeID: "coffee", body: "Coffee: 14 g\nWater: 225 g"),
      MobileSearchEntry(path: "notes/cafe.org", title: "Café", parent: "", line: 1, nodeID: "", body: "")
    ]
    let index = MobileCorpusSearchIndex(entries: entries)
    for query in ["pour over", "pourover", "por over", "POUR-OVER", "coffee"] {
      check(index.search(query).first?.nodeID == "coffee", "Failed query: \(query)")
    }
    check(index.search("pour water").first?.nodeID == "coffee")
    check(index.search("cafe notes").first?.title == "Café")
    check(index.search("cafe").first?.title == "Café")
    check(index.search("xyzzy").isEmpty)
    check(index.search("  ").isEmpty)
    check(index.search("recipes", limit: 1).count == 1)
    check(index.search("pour over").count == 2)
    let restored = MobileCorpusSearchIndex(entries: try JSONDecoder().decode([MobileSearchEntry].self, from: JSONEncoder().encode(entries)))
    check(restored.search("coffee") == index.search("coffee"))
    let updated = MobileCorpusSearchIndex(entries: entries.filter { $0.nodeID != "coffee" })
    check(updated.search("coffee").isEmpty)
    let large = MobileCorpusSearchIndex(entries: (0..<20_000).map { n in
      MobileSearchEntry(path: "notes/\(n).org", title: "Example \(n)", parent: "", line: 1, nodeID: "", body: String(repeating: "A reasonably long paragraph of source text. ", count: 20))
    } + entries)
    let start = Date()
    for _ in 0..<5 { check(large.search("por over").first?.nodeID == "coffee") }
    let elapsed = Date().timeIntervalSince(start)
    check(elapsed < 3, "Five 20k-entry searches exceeded 3s: \(elapsed)")
    print("iOS fuzzy search regression passed; five 20k-entry queries: \(elapsed)s")
  }
}
