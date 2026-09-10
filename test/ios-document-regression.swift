import Foundation

@main
struct DocumentRegression {
  static func check(_ condition: Bool, _ message: String) {
    guard condition else {
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      exit(1)
    }
  }

  static func main() throws {
    let runtime = try MobileDocumentRuntime()
    let source = """
      #+TITLE: Recipes
      * Breakfast
      Toast.
      * Pour over
      :PROPERTIES:
      :ID: coffee
      :END:
      - Coffee: 14 g
      - Water: 225 g
      ** Grind
      Fine, setting 15.
      * Tea
      Steep 3 minutes.
      """
    let entries = try runtime.index(source: source, path: "notes/recipes.org", sequences: [])
    let coffee = entries.first { $0.nodeID == "coffee" }!
    check(coffee.line == 4, "The native bridge must preserve source lines")
    let rendered = try runtime.render(source: "\n" + source, path: coffee.path, entry: coffee, sequences: [])
    check(rendered.html.contains("225 g") && rendered.html.contains("setting 15"), "Entry rendering lost recipe content")
    check(!rendered.html.contains("Steep 3 minutes"), "Entry rendering included a sibling")
    let full = try runtime.render(source: source, path: coffee.path, entry: nil, sequences: [])
    check(full.html.contains("Steep 3 minutes"), "Full-note rendering lost a sibling")
    do {
      _ = try runtime.render(source: "* Removed", path: coffee.path, entry: coffee, sequences: [])
      check(false, "A removed entry must fail visibly")
    } catch { }
    check(try runtime.index(source: "* READY Coffee", path: "test.org", sequences: ["READY | FINISHED"])[1].title == "Coffee", "Corpus TODO definitions were lost")
    let start = Date()
    for n in 0..<300 {
      _ = try runtime.index(source: source, path: "notes/\(n).org", sequences: [])
    }
    let elapsed = Date().timeIntervalSince(start)
    check(elapsed < 10, "Native indexing of 300 small documents exceeded 10s: \(elapsed)")
    print("iOS JavaScriptCore bridge passed; indexed 300 recipe documents in \(elapsed)s")
  }
}
