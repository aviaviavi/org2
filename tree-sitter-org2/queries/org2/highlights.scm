; Org2 Tree-sitter highlights
;
; This grammar is intentionally minimal; these queries aim to provide
; reasonable defaults for early experimentation.

; Headline: stars + title
(headline
  stars: (stars) @punctuation.special
  title: (title) @markup.heading)

; Paragraph/text
(text) @markup
