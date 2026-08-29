// Intentionally minimal, non-normative grammar scaffold.
// Org2's canonical meaning is defined by its AST + fixtures/spec,
// not by this Tree-sitter grammar.

module.exports = grammar({
  name: 'org2',

  extras: $ => [/[ \t]/],

  rules: {
    source_file: $ => repeat($._element),

    _element: $ => choice(
      $.headline,
      $.block_marker,
      $.dynamic_block_marker,
      $.latex_environment_marker,
      $.drawer_line,
      $.table_row,
      $.table_formula,
      $.list_item,
      $.footnote_definition,
      $.fixed_width,
      $.horizontal_rule,
      $.diary_sexp,
      $.keyword_line,
      $.comment_line,
      $.paragraph,
      $.blank_line
    ),

    blank_line: _ => /\n+/,

    headline: $ => seq(
      field('stars', $.stars),
      ' ',
      field('title', $.title)
    ),

    // One or more '*' characters.
    stars: _ => token(/\*+/),

    // Headline title text up to end-of-line.
    title: _ => token(/[^\n]+/),

    block_marker: _ => token(/#\+(?:begin|end)_[A-Za-z0-9_-]+[^\n]*/),
    dynamic_block_marker: _ => token(/#\+(?:begin|end):[^\n]*/),
    latex_environment_marker: _ => token(/\\(?:begin|end)\{[^}\n]+\}[^\n]*/),
    drawer_line: _ => token(/:[A-Za-z0-9_@#%+.-]+:[^\n]*/),
    table_row: _ => token(/\|[^\n]*\|/),
    table_formula: _ => token(/#\+[Tt][Bb][Ll][Ff][Mm]:[^\n]*/),
    // Column-zero `* ` is a headline in Org. Keeping whole-line list tokens at
    // lower lexical priority lets `stars` win that ambiguity while indented
    // star bullets remain list items after extras consume their indentation.
    list_item: _ => token(prec(-1, /(?:[-+*]|[0-9]+[.)])\s+[^\n]+/)),
    footnote_definition: _ => token(/\[fn:[^\]\s:]+\](?:\s+[^\n]*)?/),
    fixed_width: _ => token(/:\s[^\n]*/),
    horizontal_rule: _ => token(/-{5,}/),
    diary_sexp: _ => token(/%%\([^\n]+\)/),
    keyword_line: _ => token(/#\+[A-Za-z0-9_-]+:[^\n]*/),
    comment_line: _ => token(/#[^+\n][^\n]*/),

    // One or more non-headline lines (doesn't start with "* ").
    paragraph: $ => seq(
      field('line', $.text),
      repeat(seq(/\n/, field('line', $.text)))
    ),

    // Structural rules above win ties; this low-priority fallback keeps the
    // scaffold compatible with Tree-sitter's Rust-regex lexer (no lookahead).
    text: _ => token(prec(-1, /[^\n]+/))
  }
});
