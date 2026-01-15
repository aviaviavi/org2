// Intentionally minimal, non-normative grammar scaffold.
// Org2's canonical meaning is defined by its AST + fixtures/spec,
// not by this Tree-sitter grammar.

module.exports = grammar({
  name: 'org2',

  extras: $ => [/[ \t]/],

  rules: {
    source_file: $ => repeat($._element),

    _element: $ => choice($.headline, $.paragraph, $.blank_line),

    blank_line: _ => /\n+/,

    headline: $ => seq(
      field('stars', $.stars),
      ' ',
      field('title', $.title),
      optional(/\n+/)
    ),

    // One or more '*' characters.
    stars: _ => token(/\*+/),

    // Headline title text up to end-of-line.
    title: _ => token(/[^\n]+/),

    // One or more non-headline lines (doesn't start with "* ").
    paragraph: $ => seq(
      field('line', $.text),
      repeat(seq(/\n/, field('line', $.text))),
      optional(/\n+/)
    ),

    text: _ => token(/(?!\*+\s)[^\n]+/)
  }
});
