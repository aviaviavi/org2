
@main struct LinkMarkupRegression {
  @MainActor static func main() {
    let cases = [
      ("[[id:coffee-id][Coffee ☕]]", "id:coffee-id", "Coffee ☕"),
      ("[[id:coffee-id]]", "id:coffee-id", "id:coffee-id"),
      ("[[file:notes/My Recipes.org::*Coffee ☕][Recipe]]", "file:notes/My Recipes.org::*Coffee ☕", "Recipe"),
      ("[Recipe](notes/recipes.org::#coffee)", "notes/recipes.org::#coffee", "Recipe"),
      ("[Source](/Users/avi/avi.org2/notes/recipes.org:12)", "/Users/avi/avi.org2/notes/recipes.org:12", "Source · L12"),
    ]
    for (text, target, label) in cases {
      let rendered = MobileRemoteMessageMarkup.attributedString(for: text)
      precondition(String(rendered.characters) == label, "Link label was not rendered: \(text)")
      let urls = rendered.runs.compactMap { $0.link }
      precondition(!urls.isEmpty, "Entry link has no tappable attribute: \(text)")
      let citation = MobileRemoteMessageMarkup.fileCitation(from: urls[0])
      precondition(citation?.target == target, "Link target changed in transport")
      precondition(citation?.documentLink != nil, "Link did not resolve to document transport")
    }
    let code = MobileRemoteMessageMarkup.attributedString(for: "#+begin_src text\n[[id:coffee-id][Coffee]]\n#+end_src")
    precondition(code.runs.allSatisfy { $0.link == nil }, "Source examples must remain literal")
    let web = MobileRemoteMessageMarkup.attributedString(for: "[[https://example.com/notes.org][Website]]")
    precondition(web.runs.compactMap { $0.link }.first?.scheme == "https", "Web link was intercepted as a corpus path")
    let tableBlocks = MobileRemoteMessageMarkup.renderedBlocks(for: "Before\n| Name | State |\n|------+-------|\n| iOS | Done |\nAfter")
    precondition(tableBlocks.count == 3, "Org table was not split into a native render block")
    guard case .table(let table) = tableBlocks[1] else {
      preconditionFailure("Org table was left as plain text")
    }
    precondition(table.headerRowCount == 1, "Org table header rule was not recognized")
    precondition(table.rows == [["Name", "State"], ["iOS", "Done"]], "Org table cells changed during parsing")
    let literalBlocks = MobileRemoteMessageMarkup.renderedBlocks(for: "#+begin_src text\n| literal | source |\n#+end_src")
    precondition(literalBlocks.count == 1, "Source block table text must remain literal")
    let imageBlocks = MobileRemoteMessageMarkup.renderedBlocks(for: "Before\n[[file:images/chart.png][Chart]]\nAfter")
    precondition(imageBlocks.count == 3, "Standalone image links must become native render blocks")
    guard case .image(let image) = imageBlocks[1] else {
      preconditionFailure("Standalone image link was left as plain text")
    }
    precondition(image.path == "images/chart.png" && image.remoteURL == nil && image.label == "Chart", "Image link metadata changed during parsing")
    print("Native chat markup renders links and Org tables while keeping source examples literal")
  }
}
