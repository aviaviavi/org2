; Org2 Tree-sitter highlights
;
; This grammar is intentionally minimal; these queries aim to provide
; reasonable defaults for early experimentation.

; Headline: stars + title
(headline
  stars: (stars) @punctuation.special
  title: (title) @markup.heading)

; Structural elements
(block_marker) @keyword.directive
(dynamic_block_marker) @keyword.directive
(latex_environment_marker) @markup.raw
(drawer_line) @property
(table_row) @markup.raw
(table_formula) @function.macro
(list_item) @markup.list
(footnote_definition) @markup.footnote
(fixed_width) @markup.raw
(horizontal_rule) @punctuation.special
(diary_sexp) @function.macro
(keyword_line) @keyword.directive
(comment_line) @comment

; Paragraph/text
(text) @markup
