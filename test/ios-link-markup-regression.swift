
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
    print("Native chat markup renders tappable entry links, preserves labels/targets, and keeps source examples literal")
  }
}
